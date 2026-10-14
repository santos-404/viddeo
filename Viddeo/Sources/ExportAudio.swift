import AVFoundation
import CoreMedia
import Foundation

/// One source audio track re-encoded as its own AAC track in the export.
///
/// Without a timeline the decoded PCM is passed straight through (the original path). With a
/// timeline the track is assembled per edit plan item in an `AVMutableComposition`: each
/// segment's source range is inserted at its playback position and `scaleTimeRange` stretches
/// it to `timeScale ×` its source duration. An `AVAssetReaderAudioMixOutput` with
/// `audioTimePitchAlgorithm = .spectral` renders the stretched edits with pitch preserved
/// (the composition path was chosen over per-segment readers so speed changes need no
/// hand-written time stretching). Per-segment gain is applied to the decoded 16-bit samples
/// rather than through `AVAudioMix`, because the timeline allows boosts up to 2× and the gain
/// steps must land exactly on segment boundaries. Parts of a segment without source audio,
/// and any shortfall at the end, are filled with silence so the track ends at the playback
/// duration.
final class ExportAudioTrack {
    /// `clicks` is viddeo's synthesized click-sound track; segment volumes do not apply to it.
    enum Role: Sendable { case microphone, system, clicks, unknown }

    /// The AAC writer input; nil when the track was created without a writer to be consumed as PCM
    /// (`renderPCM()`), as the single-track mixdown does.
    let input: AVAssetWriterInput?
    /// Format of the PCM this track produces (the AAC track's format when it has a writer).
    let sampleRate: Double
    let channels: Int
    private let reader: AVAssetReader?
    private let output: AVAssetReaderOutput?
    private let edited: Edited?

    private struct Edited {
        var sampleRate: Double
        var channels: Int
        var totalFrames: Int64
        /// Playback-time frame ranges with a gain other than 1.
        var gains: [(start: Int64, end: Int64, gain: Float)]
        var format: CMAudioFormatDescription
    }

    private var framesWritten: Int64 = 0
    private var readerFinished = false
    private var pending: CMSampleBuffer?

    /// Pass-through: decodes `track` over `timeRange` exactly as before edits existed. A `gain` other
    /// than 1 (master volume or a mute) goes through an audio mix, which is the only change.
    /// A non-nil `sampleRate` forces that rate (the reader resamples), which the mixdown uses to get 48 kHz.
    init(asset: AVAsset, track: AVAssetTrack, timeRange: CMTimeRange, gain: Float = 1,
         writer: AVAssetWriter?, sampleRate forcedRate: Double? = nil) async throws {
        let (sampleRate, channels) = try await Self.format(of: track, forcedRate: forcedRate)
        self.sampleRate = sampleRate
        self.channels = channels
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output: AVAssetReaderOutput
        if gain == 1 {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings(sampleRate, channels))
        } else {
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(gain, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: Self.pcmSettings(sampleRate, channels))
            mixOutput.audioMix = mix
            output = mixOutput
        }
        output.alwaysCopiesSampleData = false
        input = try Self.addInput(to: writer, reader: reader, output: output, sampleRate: sampleRate,
                                  channels: channels, trackID: track.trackID)
        self.reader = reader
        self.output = output
        edited = nil
    }

    /// Edited: `track` assembled per `plan`, gain chosen by `role` and multiplied by `gain` (master
    /// volume or a mute), `playbackDuration` long.
    init(track: AVAssetTrack, role: Role, plan: [EditPlanItem], playbackDuration: Double, gain extraGain: Float = 1,
         writer: AVAssetWriter?, sampleRate forcedRate: Double? = nil) async throws {
        let (sampleRate, channels) = try await Self.format(of: track, forcedRate: forcedRate)
        self.sampleRate = sampleRate
        self.channels = channels
        let trackRange = try await track.load(.timeRange)
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OfflineExporter.ExportError.unsupportedOutput("cannot assemble audio track \(track.trackID)")
        }
        let scale: CMTimeScale = 48_000
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: scale) }
        var cursor = CMTime.zero
        var hasMedia = false
        var gains: [(start: Int64, end: Int64, gain: Float)] = []
        for item in plan {
            let source = CMTimeRange(start: time(item.sourceStart), end: time(item.sourceEnd))
            let available = source.intersection(trackRange)
            if available.duration > .zero {
                let lead = available.start - source.start
                let tail = source.end - available.end
                if lead > .zero { target.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: lead)) }
                try target.insertTimeRange(available, of: track, at: cursor + lead)
                if tail > .zero {
                    target.insertEmptyTimeRange(CMTimeRange(start: cursor + lead + available.duration, duration: tail))
                }
                hasMedia = true
            } else {
                target.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: source.duration))
            }
            var length = source.duration
            if abs(item.timeScale - 1) > 1e-9 {
                let scaled = time(source.duration.seconds * item.timeScale)
                target.scaleTimeRange(CMTimeRange(start: cursor, duration: source.duration), toDuration: scaled)
                length = scaled
            }
            let segmentGain: Float = switch role {
            case .system: Float(item.systemVolume)
            case .clicks: 1
            case .microphone, .unknown: Float(item.volume)
            }
            let gain = segmentGain * extraGain
            if gain != 1 {
                gains.append((Int64((cursor.seconds * sampleRate).rounded()),
                              Int64(((cursor + length).seconds * sampleRate).rounded()), gain))
            }
            cursor = cursor + length
        }

        var maybeFormat: CMAudioFormatDescription?
        var description = Self.description(sampleRate, channels)
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
                                             layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &maybeFormat) == noErr, let format = maybeFormat else {
            throw OfflineExporter.ExportError.unsupportedOutput("cannot describe PCM audio")
        }
        edited = Edited(sampleRate: sampleRate, channels: channels,
                        totalFrames: Int64((playbackDuration * sampleRate).rounded()), gains: gains, format: format)

        if hasMedia {
            let reader = try AVAssetReader(asset: composition)
            reader.timeRange = CMTimeRange(start: .zero, duration: time(playbackDuration))
            let output = AVAssetReaderAudioMixOutput(audioTracks: [target], audioSettings: Self.pcmSettings(sampleRate, channels))
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            input = try Self.addInput(to: writer, reader: reader, output: output, sampleRate: sampleRate,
                                      channels: channels, trackID: track.trackID)
            self.reader = reader
            self.output = output
        } else {
            input = try Self.addInput(to: writer, reader: nil, output: nil, sampleRate: sampleRate,
                                      channels: channels, trackID: track.trackID)
            reader = nil
            output = nil
            readerFinished = true
        }
    }

    func start() throws {
        if let reader, !reader.startReading() {
            throw OfflineExporter.ExportError.encodingFailed(reader.error?.localizedDescription ?? "audio reading did not start")
        }
    }

    /// Drains the whole track as float PCM in playback time (the same samples, gains and silence the
    /// AAC path would encode). Call after `start()`; intended for tracks created without a writer.
    func renderPCM() throws -> PCMAudio {
        var samples = [[Float]](repeating: [], count: channels)
        while let sample = try nextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block) / 2 * 2
            var data = [Int16](repeating: 0, count: length / 2)
            guard length == 0 || data.withUnsafeMutableBytes({
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }) == kCMBlockBufferNoErr else {
                throw OfflineExporter.ExportError.encodingFailed("could not copy decoded audio")
            }
            let frames = data.count / channels
            for channel in 0..<channels {
                samples[channel].reserveCapacity(samples[channel].count + frames)
                for frame in 0..<frames { samples[channel].append(Float(data[frame * channels + channel]) / 32_768) }
            }
        }
        return PCMAudio(sampleRate: sampleRate, channels: samples)
    }

    func cancel() {
        if let reader, reader.status == .reading { reader.cancelReading() }
    }

    /// The next buffer to append, or nil when the track is complete.
    func nextSampleBuffer() throws -> CMSampleBuffer? {
        guard let edited else {
            guard let output, let sample = output.copyNextSampleBuffer() else {
                if let reader, reader.status == .failed {
                    throw OfflineExporter.ExportError.encodingFailed(reader.error?.localizedDescription ?? "audio decoding failed")
                }
                return nil
            }
            return sample
        }
        while true {
            if pending == nil, !readerFinished, let output {
                pending = output.copyNextSampleBuffer()
                if pending == nil {
                    if let reader, reader.status == .failed {
                        throw OfflineExporter.ExportError.encodingFailed(reader.error?.localizedDescription ?? "audio decoding failed")
                    }
                    readerFinished = true
                }
            }
            guard let sample = pending else { break }
            let frames = Int64(CMSampleBufferGetNumSamples(sample))
            let start = Int64((CMSampleBufferGetPresentationTimeStamp(sample).seconds * edited.sampleRate).rounded())
            // A gap in the rendered audio (should the mix skip an empty edit) becomes silence;
            // the pending buffer is kept for after the gap.
            if frames > 0, start > framesWritten + 1 {
                return try silence(frames: min(start - framesWritten, 4096), edited: edited)
            }
            pending = nil
            let skip = max(0, framesWritten - start)
            let count = min(frames - skip, edited.totalFrames - framesWritten)
            guard count > 0 else { continue }
            let buffer = try retimed(sample, skip: skip, frames: count, edited: edited)
            framesWritten += count
            return buffer
        }
        guard framesWritten < edited.totalFrames else { return nil }
        return try silence(frames: min(edited.totalFrames - framesWritten, 4096), edited: edited)
    }

    // MARK: Helpers

    /// Copies `frames` frames of `sample`, after its first `skip`, to `framesWritten`, applying the segment gains.
    private func retimed(_ sample: CMSampleBuffer, skip: Int64, frames: Int64, edited: Edited) throws -> CMSampleBuffer {
        guard let source = CMSampleBufferGetDataBuffer(sample) else {
            throw OfflineExporter.ExportError.encodingFailed("decoded audio has no data")
        }
        let bytesPerFrame = edited.channels * 2
        var data = [Int16](repeating: 0, count: Int(frames) * edited.channels)
        let offset = Int(skip) * bytesPerFrame
        let length = min(Int(frames) * bytesPerFrame, CMBlockBufferGetDataLength(source) - offset)
        guard length > 0, data.withUnsafeMutableBytes({
            CMBlockBufferCopyDataBytes(source, atOffset: offset, dataLength: length, destination: $0.baseAddress!)
        }) == kCMBlockBufferNoErr else {
            throw OfflineExporter.ExportError.encodingFailed("could not copy decoded audio")
        }
        let first = framesWritten
        for range in edited.gains where range.end > first && range.start < first + frames {
            let lower = Int(max(range.start, first) - first), upper = Int(min(range.end, first + frames) - first)
            for index in (lower * edited.channels)..<(upper * edited.channels) {
                data[index] = Int16(clamping: Int((Float(data[index]) * range.gain).rounded()))
            }
        }
        return try makeBuffer(data, frames: frames, edited: edited)
    }

    private func silence(frames: Int64, edited: Edited) throws -> CMSampleBuffer {
        let buffer = try makeBuffer([Int16](repeating: 0, count: Int(frames) * edited.channels),
                                    frames: frames, edited: edited)
        framesWritten += frames
        return buffer
    }

    /// A PCM buffer stamped at `framesWritten` (callers advance it afterwards).
    private func makeBuffer(_ samples: [Int16], frames: Int64, edited: Edited) throws -> CMSampleBuffer {
        let length = samples.count * 2
        var maybeBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &maybeBlock) == kCMBlockBufferNoErr,
              let block = maybeBlock,
              samples.withUnsafeBytes({
                  CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                dataLength: length)
              }) == kCMBlockBufferNoErr else {
            throw OfflineExporter.ExportError.encodingFailed("could not allocate audio")
        }
        var maybeSample: CMSampleBuffer?
        let time = CMTime(value: framesWritten, timescale: CMTimeScale(edited.sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: edited.format,
            sampleCount: CMItemCount(frames), presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &maybeSample) == noErr, let sample = maybeSample else {
            throw OfflineExporter.ExportError.encodingFailed("could not create an audio buffer")
        }
        return sample
    }

    private static func format(of track: AVAssetTrack, forcedRate: Double? = nil) async throws -> (sampleRate: Double, channels: Int) {
        let descriptions = try await track.load(.formatDescriptions)
        let format = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sourceRate = format?.mSampleRate ?? 48_000
        let sampleRate = forcedRate ?? ([48_000.0, 44_100, 32_000, 24_000, 22_050, 16_000].contains(sourceRate) ? sourceRate : 48_000)
        return (sampleRate, min(2, max(1, Int(format?.mChannelsPerFrame ?? 2))))
    }

    private static func pcmSettings(_ sampleRate: Double, _ channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func description(_ sampleRate: Double, _ channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0
        )
    }

    private static func addInput(to writer: AVAssetWriter?, reader: AVAssetReader?, output: AVAssetReaderOutput?,
                                 sampleRate: Double, channels: Int, trackID: CMPersistentTrackID) throws -> AVAssetWriterInput? {
        guard let writer else {
            guard reader.map({ reader in output.map { reader.canAdd($0) } ?? false }) ?? true else {
                throw OfflineExporter.ExportError.unsupportedOutput("cannot decode audio track \(trackID)")
            }
            if let reader, let output { reader.add(output) }
            return nil
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000 * channels
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input), reader.map({ reader in output.map { reader.canAdd($0) } ?? false }) ?? true else {
            throw OfflineExporter.ExportError.unsupportedOutput("cannot transcode audio track \(trackID)")
        }
        if let reader, let output { reader.add(output) }
        writer.add(input)
        return input
    }

    /// Identifies tracks as the caption extractor does: by the recorder's track titles, falling
    /// back to recorder order (system first, then microphone) when the titles are missing and
    /// the session's audio metadata accounts for every track. Anything else is `.unknown`,
    /// which takes the segment's primary `volume`.
    static func roles(of tracks: [AVAssetTrack], session: RecordingSession) async throws -> [Role] {
        let audio = session.audio
        let microphoneName = audio?.microphoneTrackName ?? "Microphone"
        let systemName = audio?.systemAudioTrackName ?? "System Audio"
        var roles: [Role] = []
        for track in tracks {
            var role = Role.unknown
            let items = try await track.load(.commonMetadata) + track.load(.metadata)
            for item in items where item.identifier == .commonIdentifierTitle || item.commonKey == .commonKeyTitle {
                let title = try await item.load(.stringValue)
                if title == microphoneName { role = .microphone } else if title == systemName { role = .system }
            }
            roles.append(role)
        }
        if roles.allSatisfy({ $0 == .unknown }), let audio {
            let ordered: [Role] = (audio.systemAudioRequested ? [.system] : []) + (audio.microphoneRequested ? [.microphone] : [])
            if ordered.count == tracks.count { return ordered }
        }
        return roles
    }
}

/// Audio sources the exporter derives from an `AudioMixConfiguration` before encoding: a cleaned
/// microphone and a synthesized click track. Each is written as a temporary 48 kHz CAF in `directory`
/// and read back through AVFoundation, so the normal per-source AAC path encodes it.
enum ExportAudioPreparation {
    struct Source {
        var asset: AVURLAsset
        var track: AVAssetTrack
    }

    /// Runs `track` through the preset's DSP chain. Returns nil when the track holds no audio, in which
    /// case the original track is exported unchanged. The result is delayed by the original track's
    /// start offset, because decoding drops timestamps and the exporter addresses audio by source time.
    static func cleanedMicrophone(asset: AVAsset, track: AVAssetTrack, preset: MicrophonePreset,
                                  limiterCeilingDB: Double, directory: URL) async throws -> Source? {
        guard preset != .off else { return nil }
        var audio = try await AudioFileIO.decode(asset: asset, track: track)
        guard audio.frameCount > 0 else { return nil }
        try Task.checkCancellation()
        audio = try VoiceCleanup.process(audio, preset: preset, limiterCeilingDB: limiterCeilingDB)
        let start = try await track.load(.timeRange).start.seconds
        if start.isFinite, start > 0.0005 {
            let lead = Int((start * audio.sampleRate).rounded())
            audio.channels = audio.channels.map { [Float](repeating: 0, count: lead) + $0 }
        }
        return try await write(audio, named: "microphone-\(preset.rawValue)", directory: directory)
    }

    /// One mono track with the click set's samples at each press/release. Nil when there are no events.
    static func clickSounds(events: [CursorEvent], set: ClickSoundSet, volume: Double, duration: Double,
                            directory: URL) async throws -> Source? {
        guard events.contains(where: { $0.kind != .move }) else { return nil }
        let samples = ClickSounds.render(events: events, set: set, volume: volume, duration: duration)
        guard !samples.isEmpty else { return nil }
        return try await write(PCMAudio(sampleRate: ClickSounds.sampleRate, channels: [samples]),
                               named: "click-sounds", directory: directory)
    }

    /// The background music as 48 kHz PCM exactly `duration` (playback time) long with master volume,
    /// music volume, looping and fade-out applied (`BackgroundMusic`), or nil when there is none to
    /// play (no file, muted, or silent). A missing file is an error naming it.
    static func backgroundMusic(mix: AudioMixConfiguration, sessionDirectory: URL, duration: Double) async throws -> PCMAudio? {
        guard mix.hasActiveBackgroundMusic, let name = mix.backgroundAudioFileName else { return nil }
        guard let url = mix.backgroundAudioURL(in: sessionDirectory) else {
            throw AudioProcessingError.invalidBackgroundAudioFileName
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioProcessingError.missingBackgroundAudio(name)
        }
        let gain = AudioMixer.effectiveGain(MixTrack(url: url, gain: 1, startOffset: 0, kind: .backgroundAudio), plan: mix)
        guard gain > 0 else { return nil }
        let source = try await AudioFileIO.read(url)
        let frames = Int((duration * AudioFileIO.sampleRate).rounded())
        let music = BackgroundMusic.render(source, frameCount: frames, gain: Float(gain))
        return music.frameCount > 0 ? music : nil
    }

    /// The master volume and mute for one role. Segment volumes are applied separately, per segment.
    static func gain(for role: ExportAudioTrack.Role, mix: AudioMixConfiguration?) -> Float {
        guard let mix else { return 1 }
        let source: Double = switch role {
        case .microphone: mix.muteMicrophone ? 0 : 1
        case .system: mix.muteSystemAudio ? 0 : 1
        case .clicks, .unknown: 1
        }
        let gain = mix.volume * source
        return gain.isFinite ? Float(max(0, gain)) : 1
    }

    static func write(_ audio: PCMAudio, named name: String, directory: URL) async throws -> Source? {
        let url = directory.appendingPathComponent("\(name).caf", isDirectory: false)
        try AudioFileIO.write(audio, to: url)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        return Source(asset: asset, track: track)
    }
}
