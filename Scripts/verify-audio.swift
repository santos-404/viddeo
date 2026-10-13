import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Darwin

@main
struct VerifyAudio {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-audio-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let width = 160, height = 90
        let epoch = CMTime(seconds: 10, preferredTimescale: 48_000)
        let pipeline = ScreenWriterPipeline()
        let movie = directory.appendingPathComponent("raw.mp4")
        try await pipeline.prepare(url: movie, width: width, height: height, capturesSystemAudio: true, capturesMicrophone: true)

        let early = try makeAudioSample(pts: CMTimeSubtract(epoch, CMTime(value: 1, timescale: 48_000)))
        let video = try makeFrame(width: width, height: height, pts: epoch)
        let system = try makeAudioSample(pts: CMTimeAdd(epoch, CMTime(value: 1, timescale: 10)))
        let microphone = try makeAudioSample(pts: CMTimeAdd(epoch, CMTime(value: 1, timescale: 5)))
        pipeline.sampleQueue.sync {
            pipeline.consumeAudio(early, microphone: false)
            pipeline.consume(video)
            pipeline.consumeAudio(system, microphone: false)
            pipeline.consumeAudio(microphone, microphone: true)
        }
        let result = try await pipeline.finish(atHostTime: CMTimeAdd(epoch, CMTime(seconds: 1, preferredTimescale: 48_000)))
        guard result.audio.systemAudioSamples == 1, result.audio.microphoneSamples == 1,
              result.audio.systemAudioDroppedSamples == 1,
              result.audio.systemAudioRequested, result.audio.microphoneRequested else {
            throw VerifyError.failed("audio sample accounting or pre-video epoch trimming failed: \(result.audio)")
        }

        let asset = AVURLAsset(url: movie)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 2 else { throw VerifyError.failed("expected two separate AAC tracks, got \(audioTracks.count)") }
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first,
                  CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC else {
                throw VerifyError.failed("an audio track is not AAC")
            }
        }
        var audioOnsets: [Double] = []
        for track in audioTracks {
            let segments = try await track.load(.segments)
            guard let segment = segments.first(where: { !$0.isEmpty }) else {
                throw VerifyError.failed("audio track has no nonempty media segment")
            }
            audioOnsets.append(segment.timeMapping.target.start.seconds)
        }
        audioOnsets.sort()
        guard audioOnsets.count == 2,
              abs(audioOnsets[0] - 0.1) < 0.03,
              abs(audioOnsets[1] - 0.2) < 0.03 else {
            throw VerifyError.failed("audio media segment onsets \(audioOnsets) do not preserve expected 0.1s and 0.2s offsets from video")
        }


        let sessionDirectory = directory.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height,
                                       duration: result.duration, events: [], droppedFrames: 0,
                                       eventCaptureAvailable: false, audio: result.audio)
        try session.save(in: sessionDirectory)
        let loaded = try RecordingSession.load(from: sessionDirectory)
        guard loaded.audio == result.audio else { throw VerifyError.failed("audio metadata did not roundtrip") }
        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        legacyObject.removeValue(forKey: "audio")
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyObject)
        try legacyJSON.write(to: legacyDirectory.appendingPathComponent("session.json"))
        guard try RecordingSession.load(from: legacyDirectory).audio == nil else {
            throw VerifyError.failed("legacy session without audio metadata should load with audio nil")
        }

        let silentPipeline = ScreenWriterPipeline()
        try await silentPipeline.prepare(url: directory.appendingPathComponent("silent-audio.mp4"),
                                         width: width, height: height,
                                         capturesSystemAudio: true, capturesMicrophone: true)
        silentPipeline.sampleQueue.sync { silentPipeline.consume(video) }
        let silentResult = try await silentPipeline.finish(atHostTime: CMTimeAdd(epoch, CMTime(seconds: 1, preferredTimescale: 48_000)))
        guard silentResult.audio.systemAudioRequested, silentResult.audio.microphoneRequested,
              silentResult.audio.systemAudioSamples == 0, silentResult.audio.microphoneSamples == 0 else {
            throw VerifyError.failed("a silent audio source should preserve video and report zero audio samples")
        }
        print("Audio verification passed: two AAC tracks, video-epoch trim, sample/drop counts, metadata roundtrip")
    }

    private static func makeAudioSample(pts: CMTime) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else { throw VerifyError.failed("could not create audio format description") }
        let frames: CMItemCount = 480
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: Int(frames) * 4, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: Int(frames) * 4,
                                                 flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw VerifyError.failed("could not allocate PCM sample") }
        let tone = (0..<Int(frames)).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.25 }
        let copyStatus = tone.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard copyStatus == kCMBlockBufferNoErr else { throw VerifyError.failed("could not fill PCM sample") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
                                        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample else { throw VerifyError.failed("could not create PCM sample") }
        return sample
    }

    private static func makeFrame(width: Int, height: Int, pts: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixel) == kCVReturnSuccess,
              let pixel else { throw VerifyError.failed("could not allocate video frame") }
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &desc) == noErr,
              let desc else { throw VerifyError.failed("could not create video format description") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: desc,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            throw VerifyError.failed("could not create video sample")
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        dictionary[SCStreamFrameInfo.status] = NSNumber(value: SCFrameStatus.complete.rawValue)
        return sample
    }
}

private enum VerifyError: Error { case failed(String) }
