import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@main
struct VerifyCapture {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-capture-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let width = 160
        let height = 90
        let firstPTS = CMTimeSubtract(CMSyncGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 1, preferredTimescale: 1_000_000_000))
        let stopPTS = CMTimeAdd(firstPTS, CMTime(seconds: 2, preferredTimescale: 1_000_000_000))
        let pipeline = ScreenWriterPipeline()
        let rawURL = directory.appendingPathComponent("raw.mp4")
        try await pipeline.prepare(url: rawURL, width: width, height: height)

        let first = try makeFrame(width: width, height: height, pts: firstPTS, status: .complete)
        let secondPTS = CMTimeAdd(firstPTS, CMTime(value: 1, timescale: 20))
        let second = try makeFrame(width: width, height: height, pts: secondPTS, status: .complete)
        let duplicate = try makeFrame(width: width, height: height, pts: secondPTS, status: .complete)
        let incomplete = try makeFrame(width: width, height: height,
                                       pts: CMTimeAdd(secondPTS, CMTime(value: 1, timescale: 20)),
                                       status: .idle)
        pipeline.sampleQueue.sync {
            pipeline.consume(first)
            pipeline.consume(second)
            pipeline.consume(duplicate)
            pipeline.consume(incomplete)
        }

        let result = try await pipeline.finish(atHostTime: stopPTS)
        try expect(result.droppedFrames == 2, "duplicate PTS and incomplete sample should be counted as dropped")
        try expect(result.duration >= 1, "held final frame should extend the result through stop time")

        let asset = AVURLAsset(url: rawURL)
        let assetDuration = try await asset.load(.duration).seconds
        try expect(abs(assetDuration - result.duration) <= (1.0 / 60.0) + 0.002,
                   "MP4 duration \(assetDuration) should match pipeline duration \(result.duration)")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VerificationError.failed("MP4 has no video track") }
        let naturalSize = try await track.load(.naturalSize)
        try expect(Int(naturalSize.width) == width && Int(naturalSize.height) == height,
                   "MP4 dimensions should be 160×90, got \(naturalSize)")
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw VerificationError.failed("MP4 has no video format description")
        }
        try expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264,
                   "MP4 codec should be H.264")

        let sessionDirectory = directory.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let session = RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height,
            duration: result.duration,
            events: [CursorEvent(time: result.duration - 0.01, x: 0.25, y: 0.75, kind: .down)],
            droppedFrames: result.droppedFrames,
            eventCaptureAvailable: true
        )
        try session.save(in: sessionDirectory)
        let loaded = try RecordingSession.load(from: sessionDirectory)
        try expect(loaded.id == session.id && loaded.width == width && loaded.height == height,
                   "session JSON should preserve identity and dimensions")
        try expect(abs(loaded.duration - result.duration) < 0.000_001 && loaded.events == session.events,
                   "session JSON should preserve final duration and cursor events")

        let noFramePipeline = ScreenWriterPipeline()
        try await noFramePipeline.prepare(url: directory.appendingPathComponent("empty.mp4"), width: width, height: height)
        do {
            _ = try await noFramePipeline.finish(atHostTime: stopPTS)
            throw VerificationError.failed("finishing without a frame should fail")
        } catch ScreenRecorder.RecorderError.noFrames {
            // Expected: the capture must contain a complete screen frame.
        }
        await noFramePipeline.abort()

        print("Capture verification passed: H.264 output, stop-time hold, dropped samples, no-frame error, session JSON")
    }

    private static func makeFrame(width: Int, height: Int, pts: CMTime, status: SCFrameStatus) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes, &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw VerificationError.failed("could not allocate a BGRA frame")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x40, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw VerificationError.failed("could not create the frame format description")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
            throw VerificationError.failed("could not create the timed screen sample")
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        dictionary[SCStreamFrameInfo.status] = NSNumber(value: status.rawValue)
        return sampleBuffer
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

private enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
