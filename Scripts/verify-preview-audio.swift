import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Verifies the editor preview's audio against the exporter, with a synthetic recording whose system
/// track switches tone at 4 s (440 Hz, then 660 Hz) and whose microphone track is a constant 1000 Hz:
/// the preview mix has the export's duration and, at known playback times, the expected source tone
/// and energy (trim, reorder, speed change and ramp, per-segment gain, mutes); it matches the exported
/// MP4's audio; recordings without audio stay silent; the sync rules and the player/model behave.
@main
@MainActor
struct VerifyPreviewAudio {
    private static var checks = 0
    private static let amplitude = 10_000.0 / 32_768   // peak of every fixture tone
    private static let toneRMS = amplitude / 2.0.squareRoot()

    private static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        guard condition() else { throw VerificationError.failed(message()) }
        checks += 1
    }

    static func main() async throws {
        let duration = 8.0
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-preview-audio-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leftovers = previewAudioFiles()

        let toned = try await makeSession(root: root, name: "toned", duration: duration, tones: true)
        let silent = try await makeSession(root: root, name: "silent", duration: duration, tones: false)
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)

        try verifySyncRules()
        try await verifyNoAudio(silent: silent, settings: settings, duration: duration)
        try await verifyEditedMix(toned: toned, settings: settings, duration: duration)
        try await verifyMatchesExport(toned: toned, settings: settings, duration: duration)
        try await verifyModel(toned: toned, silent: silent, settings: settings, duration: duration)
        try check(previewAudioFiles().subtracting(leftovers).isEmpty,
                  "temporary preview audio was left behind: \(previewAudioFiles().subtracting(leftovers))")
        print("Preview audio verified: \(checks) checks")
    }

    // MARK: Sync rules (pure)

    private static func verifySyncRules() throws {
        func command(_ playhead: Double, _ audio: Double, playing: Bool = true, wants: Bool = true,
                     length: Double = 10) -> PreviewAudioSync.Command {
            PreviewAudioSync.command(playhead: playhead, audioPosition: audio, audioIsPlaying: playing,
                                     wantsPlayback: wants, audioDuration: length)
        }
        func expect(_ actual: PreviewAudioSync.Command, _ expected: PreviewAudioSync.Command, _ name: String) throws {
            try check(actual == expected, "\(name): \(actual), expected \(expected)")
        }
        do {
            try expect(command(2, 0, playing: false), .start(at: 2), "play starts at the playhead")
            try expect(command(2, 2.03), .none, "drift under 60 ms is left alone")
            try expect(command(2, 1.95), .none, "negative drift under 60 ms is left alone")
            try expect(command(2, 2.2), .seek(to: 2), "audio ahead by 200 ms is re-seeked")
            try expect(command(2, 1.7), .seek(to: 2), "audio behind by 300 ms is re-seeked")
            try expect(command(2, 2, wants: false), .pause, "pause stops a running player")
            try expect(command(2, 2, playing: false, wants: false), .none, "pause with a stopped player is a no-op")
            try expect(command(10, 10), .pause, "the end stops the player")
            try expect(command(10, 10, playing: false), .none, "playing past the end does not restart")
            try expect(command(0, 0, playing: false, length: 0), .none, "no audio loaded does nothing")
            try expect(command(.nan, 1), .pause, "a non-finite playhead stops audio")
            try expect(command(-1, 0, playing: false), .start(at: 0), "a negative playhead starts at 0")
        }
    }

    // MARK: No audio

    /// A recording with no audio tracks (and no click or music) produces no preview audio at all, with
    /// or without an edit; click sounds alone are still heard, as in the export.
    private static func verifyNoAudio(silent: Fixture, settings: ExportSettings, duration: Double) async throws {
        let plain = try await ExportAudioPreparation.previewMix(session: silent.session, directory: silent.directory,
                                                                settings: settings, edit: nil)
        try check(plain == nil, "a recording without audio produced preview audio")
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 4)
        let edited = try await ExportAudioPreparation.previewMix(
            session: silent.session, directory: silent.directory, settings: settings, edit: ExportEdit(timeline: timeline))
        try check(edited == nil, "an edited recording without audio produced preview audio")
        var mix = AudioMixConfiguration()
        mix.clickSoundEffect = .crispClick
        mix.clickSoundEffectVolume = 1
        let clicks = try await ExportAudioPreparation.previewMix(
            session: silent.session, directory: silent.directory, settings: settings,
            edit: ExportEdit(timeline: timeline, audio: mix))
        try check(clicks != nil && abs(clicks!.duration - timeline.playbackDuration) < 0.01,
                  "click sounds alone should give a preview mix of the playback duration")
        let click = try measure(clicks!, from: 0.9, to: 1.3), quiet = try measure(clicks!, from: 2.0, to: 2.5)
        try check(click.rms > 0.01 && quiet.rms < 0.0005, "click audio energy \(click) near the click, \(quiet) away from it")
    }

    // MARK: Edited mix

    private static func verifyEditedMix(toned: Fixture, settings: ExportSettings, duration: Double) async throws {
        func mix(_ edit: ExportEdit) async throws -> PCMAudio {
            guard let audio = try await ExportAudioPreparation.previewMix(
                session: toned.session, directory: toned.directory, settings: settings, edit: edit) else {
                throw VerificationError.failed("the preview mix is missing")
            }
            return audio
        }
        var micMuted = AudioMixConfiguration()
        micMuted.microphonePreset = .off
        micMuted.muteMicrophone = true

        // Unedited: the whole recording; both tones sum, so the energy is √2 × one tone.
        let unedited = try await mix(ExportEdit(timeline: TimelineModel(sourceDuration: duration)))
        try check(abs(unedited.duration - duration) < 0.02, "unedited preview mix lasts \(unedited.duration) s of \(duration)")
        let both = try measure(unedited, from: 1, to: 3)
        try check(abs(both.rms / (toneRMS * 2.0.squareRoot()) - 1) < 0.1, "two summed tones measure \(both)")

        // Speed change: [0,4) at 2x (2 s of 440 Hz, pitch preserved), then [4,8) at 1x (660 Hz).
        var speed = TimelineModel(sourceDuration: duration)
        try speed.split(atSource: 4)
        try speed.setTimeScale(segmentID: speed.segments[0].id, to: 0.5)
        let speedEdit = ExportEdit(timeline: speed, audio: micMuted)
        let fast = try await mix(speedEdit)
        try check(abs(fast.duration - speed.playbackDuration) < 0.02 && abs(speed.playbackDuration - 6) < 1e-6,
                  "sped-up preview mix lasts \(fast.duration) s, the export \(speed.playbackDuration)")
        let early = try measure(fast, from: 0.4, to: 1.6), late = try measure(fast, from: 2.5, to: 5.5)
        try check(abs(early.frequency - 440) < 30 && abs(late.frequency - 660) < 30,
                  "tones at 1 s / 4 s of playback are \(early.frequency) / \(late.frequency) Hz, expected 440 / 660")
        try check(abs(early.rms / toneRMS - 1) < 0.2 && abs(late.rms / toneRMS - 1) < 0.1,
                  "muted-microphone energy \(early.rms) / \(late.rms), expected \(toneRMS)")
        let withMic = try await mix(ExportEdit(timeline: speed))
        let micLate = try measure(withMic, from: 2.5, to: 5.5)
        try check(abs(micLate.rms / (toneRMS * 2.0.squareRoot()) - 1) < 0.1,
                  "unmuted microphone energy \(micLate.rms), expected \(toneRMS * 2.0.squareRoot())")

        // Trim + reorder: keep [2,4) and [4,8), play [4,8) first. Playback 0...4 is 660 Hz, 4...6 is 440 Hz.
        var order = TimelineModel(sourceDuration: duration)
        let head = order.segments[0].id
        try order.trim(segmentID: head, newStart: 2, newEnd: 8)
        let tail = try order.split(atSource: 4)
        try order.move(segmentID: tail, toIndex: 0)
        let reordered = try await mix(ExportEdit(timeline: order, audio: micMuted))
        try check(abs(reordered.duration - 6) < 0.02, "trimmed + reordered mix lasts \(reordered.duration) s, expected 6")
        let first = try measure(reordered, from: 0.5, to: 3.5), second = try measure(reordered, from: 4.3, to: 5.7)
        try check(abs(first.frequency - 660) < 30 && abs(second.frequency - 440) < 30,
                  "reordered tones are \(first.frequency) / \(second.frequency) Hz, expected 660 / 440")

        // Per-segment system volume and master volume.
        var gain = order
        try gain.setSystemVolume(segmentID: gain.segments[1].id, to: 0.5)
        var master = micMuted
        master.volume = 0.5
        let quiet = try await mix(ExportEdit(timeline: gain, audio: master))
        let loud = try measure(quiet, from: 0.5, to: 3.5), soft = try measure(quiet, from: 4.3, to: 5.7)
        try check(abs(loud.rms / (toneRMS * 0.5) - 1) < 0.1 && abs(soft.rms / (toneRMS * 0.25) - 1) < 0.15,
                  "segment/master gains measure \(loud.rms) / \(soft.rms), expected \(toneRMS * 0.5) / \(toneRMS * 0.25)")

        // Continuous speed ramp on [4,8): slows from 1x to 2x duration. The mix still has the playback duration.
        var ramp = TimelineModel(sourceDuration: duration)
        try ramp.split(atSource: 4)
        try ramp.setSpeedKeyframes(segmentID: ramp.segments[1].id, to: [
            SpeedKeyframe(sourceOffset: 0, timeScale: 1), SpeedKeyframe(sourceOffset: 4, timeScale: 2)])
        let ramped = try await mix(ExportEdit(timeline: ramp, audio: micMuted))
        try check(abs(ramped.duration - ramp.playbackDuration) < 0.02 && abs(ramp.playbackDuration - 10) < 1e-6,
                  "ramped preview mix lasts \(ramped.duration) s, the export \(ramp.playbackDuration)")
        let ramping = try measure(ramped, from: 6, to: 9)
        try check(abs(ramping.frequency - 660) < 40 && abs(ramping.rms / toneRMS - 1) < 0.2,
                  "audio inside the ramp measures \(ramping)")
    }

    // MARK: Matches the export

    private static func verifyMatchesExport(toned: Fixture, settings: ExportSettings, duration: Double) async throws {
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 4)
        try timeline.setTimeScale(segmentID: timeline.segments[0].id, to: 0.5)
        var single = AudioMixConfiguration()
        single.microphonePreset = .off
        single.muteMicrophone = true
        single.mixdownSingleTrack = true
        for (name, edit, tracks) in [
            ("single-track", ExportEdit(timeline: timeline, audio: single), 1),
            ("two-track", ExportEdit(timeline: timeline), 2)
        ] {
            let url = toned.directory.appendingPathComponent("export-\(name).mp4")
            try await OfflineExporter().export(session: toned.session, directory: toned.directory, destination: url,
                                               showsClickEffects: false, settings: settings, edit: edit)
            let exported = AVURLAsset(url: url)
            let audioTracks = try await exported.loadTracks(withMediaType: .audio)
            try check(audioTracks.count == tracks, "\(name) export has \(audioTracks.count) audio tracks, expected \(tracks)")
            var decoded: [PCMAudio] = []
            for track in audioTracks { decoded.append(try await decodeAudio(asset: exported, track: track)) }
            guard let preview = try await ExportAudioPreparation.previewMix(
                session: toned.session, directory: toned.directory, settings: settings, edit: edit) else {
                throw VerificationError.failed("\(name): no preview mix")
            }
            let exportedDuration = try await audioTracks[0].load(.timeRange).duration.seconds
            try check(abs(preview.duration - exportedDuration) < 0.08 && abs(preview.duration - timeline.playbackDuration) < 0.02,
                      "\(name): preview mix \(preview.duration) s, exported audio \(exportedDuration) s, playback \(timeline.playbackDuration) s")
            for window in [(0.4, 1.6), (2.4, 3.5), (4.0, 5.5)] {
                let heard = try measure(preview, from: window.0, to: window.1)
                // The export's tracks play together: powers add.
                let power = try decoded.reduce(0.0) { sum, track in
                    let level = try measure(track, from: window.0, to: window.1).rms
                    return sum + level * level
                }
                let exportedRMS = power.squareRoot()
                try check(abs(heard.rms / exportedRMS - 1) < 0.1,
                          "\(name): preview energy \(heard.rms) vs exported \(exportedRMS) at \(window)")
            }
        }
    }

    // MARK: Model and player

    private static func verifyModel(toned: Fixture, silent: Fixture, settings: ExportSettings, duration: Double) async throws {
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 4)
        try timeline.setTimeScale(segmentID: timeline.segments[0].id, to: 0.5)
        var micMuted = AudioMixConfiguration()
        micMuted.microphonePreset = .off
        micMuted.muteMicrophone = true
        let edit = ExportEdit(timeline: timeline, audio: micMuted)

        let model = EditorPreviewModel()
        await model.prepare(session: toned.session, directory: toned.directory, settings: settings, edit: edit,
                            showsClickEffects: false)
        await model.prepareAudio(session: toned.session, directory: toned.directory, settings: settings, edit: edit)
        try check(model.hasAudio && model.audioError == nil && !model.isPreparingAudio, "audio did not load: \(model.audioError ?? "-")")
        try check(abs(model.audioPlayer.duration - model.duration) < 0.05,
                  "player lasts \(model.audioPlayer.duration) s, the preview \(model.duration) s")
        let firstFile = model.audioPlayer.fileURL
        try check(firstFile.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the mixed audio file is missing")

        // Latest wins: a cancelled build leaves nothing; a newer build replaces and deletes the old file.
        let cancelled = Task { await model.prepareAudio(session: toned.session, directory: toned.directory, settings: settings, edit: edit) }
        cancelled.cancel()
        await cancelled.value
        try check(!model.hasAudio || model.audioPlayer.fileURL != firstFile, "a cancelled build kept the old audio")
        await model.prepareAudio(session: toned.session, directory: toned.directory, settings: settings, edit: edit)
        try check(model.hasAudio, "audio did not reload after a cancelled build")
        try check(firstFile.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "the superseded audio file was not deleted")

        // Scrubbing positions the audio without playing it; mute sets the volume without stopping it.
        model.scrub(to: 3)
        try check(abs(model.audioPlayer.position - 3) < 0.05 && !model.audioPlayer.isPlaying,
                  "scrub left the audio at \(model.audioPlayer.position) s, playing \(model.audioPlayer.isPlaying)")
        model.isAudioMuted = true
        try check(model.audioPlayer.isMuted, "mute did not reach the player")
        model.isAudioMuted = false

        // Playback: audio starts at the playhead, stays within the sync threshold, pauses with the video.
        model.scrub(to: 1)
        model.togglePlayback()
        try await Task.sleep(for: .milliseconds(900))
        if model.audioPlayer.isPlaying {
            try check(model.isPlaying && abs(model.audioPlayer.position - model.time) < 0.15,
                      "audio at \(model.audioPlayer.position) s, video at \(model.time) s")
            try check(model.audioPlayer.position > 1.4, "audio did not advance from 1.0 s (\(model.audioPlayer.position))")
            model.togglePlayback()
            try check(!model.audioPlayer.isPlaying, "audio kept playing after pause")
            model.scrub(to: 5)
            model.togglePlayback()
            try await Task.sleep(for: .milliseconds(700))
            try check(abs(model.audioPlayer.position - model.time) < 0.15 || !model.isPlaying,
                      "after a scrub audio is at \(model.audioPlayer.position) s, video at \(model.time) s")
            model.pause()
        } else {
            print("note: AVAudioPlayer produced no playback here (no output device?); player start/resync not exercised")
            model.pause()
        }

        // Rebuilt audio while playing and invalidated audio.
        model.invalidateAudio()
        try check(!model.hasAudio && !model.audioPlayer.isLoaded, "invalidateAudio kept the audio")

        // No audio: nothing loads, playback is unaffected.
        let quietModel = EditorPreviewModel()
        await quietModel.prepare(session: silent.session, directory: silent.directory, settings: settings,
                                 edit: ExportEdit(timeline: timeline), showsClickEffects: false)
        await quietModel.prepareAudio(session: silent.session, directory: silent.directory, settings: settings,
                                      edit: ExportEdit(timeline: timeline))
        try check(!quietModel.hasAudio && quietModel.audioError == nil && !quietModel.audioPlayer.isLoaded && quietModel.image != nil,
                  "a recording without audio changed the preview")
        quietModel.togglePlayback()
        try await Task.sleep(for: .milliseconds(300))
        try check(quietModel.isPlaying && quietModel.time > 0.1 && !quietModel.audioPlayer.isPlaying,
                  "video playback without audio: playing \(quietModel.isPlaying), time \(quietModel.time)")
        quietModel.stop()

        model.stop()
        try check(!model.audioPlayer.isLoaded && model.audioPlayer.fileURL == nil, "stop kept the audio loaded")
    }

    // MARK: Measuring

    private struct Tone: CustomStringConvertible {
        var rms: Double
        var frequency: Double
        var description: String { "rms \(rms), \(frequency) Hz" }
    }

    /// RMS and dominant frequency (zero crossings) of the first channel between two playback times.
    private static func measure(_ audio: PCMAudio, from start: Double, to end: Double) throws -> Tone {
        let lower = Int(start * audio.sampleRate), upper = min(audio.frameCount, Int(end * audio.sampleRate))
        guard let samples = audio.channels.first, upper - lower > 100 else {
            throw VerificationError.failed("no audio between \(start) and \(end) s (\(audio.duration) s long)")
        }
        var energy = 0.0, crossings = 0
        for index in lower..<upper {
            let value = Double(samples[index])
            energy += value * value
            if index > lower, samples[index - 1] <= 0, samples[index] > 0 { crossings += 1 }
        }
        return Tone(rms: (energy / Double(upper - lower)).squareRoot(),
                    frequency: Double(crossings) / (Double(upper - lower) / audio.sampleRate))
    }

    private static func decodeAudio(asset: AVAsset, track: AVAssetTrack) async throws -> PCMAudio {
        let reader = try AVAssetReader(asset: asset)
        // Decode at the track's own channel count: a stereo-to-mono downmix would add correlated channels.
        let description = try await track.load(.formatDescriptions).first
        let channels = max(1, Int(description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { throw VerificationError.failed("could not decode an exported audio track") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VerificationError.failed("audio reading did not start") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            guard chunk.withUnsafeMutableBytes({
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 4 * 4, destination: $0.baseAddress!)
            }) == kCMBlockBufferNoErr else { throw VerificationError.failed("could not copy decoded audio") }
            samples += channels == 1 ? chunk : stride(from: 0, to: chunk.count - channels + 1, by: channels).map { chunk[$0] }
        }
        return PCMAudio(sampleRate: 48_000, channels: [samples])
    }

    private static func previewAudioFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("viddeo-preview-audio-") && !$0.hasPrefix("viddeo-preview-audio-check-") })
    }

    // MARK: Fixtures

    private typealias Fixture = (session: RecordingSession, directory: URL)

    /// 8 s, 640×360 gray video. With `tones`: system audio 440 Hz until 4 s then 660 Hz, microphone 1000 Hz.
    /// Both sessions have a click at 1.0 s so click sounds have something to play.
    private static func makeSession(root: URL, name: String, duration: Double, tones: Bool) async throws -> Fixture {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("raw.mp4")
        try await makeVideo(url: rawURL, width: 640, height: 360, duration: duration)
        var audio: AudioCaptureMetadata?
        if tones {
            let system = directory.appendingPathComponent("system.wav"), microphone = directory.appendingPathComponent("microphone.wav")
            try writeToneWAV(to: system, duration: duration) { $0 < 4 ? 440 : 660 }
            try writeToneWAV(to: microphone, duration: duration) { _ in 1000 }
            try await muxAudio(into: rawURL, directory: directory, tones: [system, microphone], duration: duration)
            audio = AudioCaptureMetadata(systemAudioRequested: true, microphoneRequested: true,
                                         systemAudioSamples: 1, microphoneSamples: 1,
                                         systemAudioDroppedSamples: 0, microphoneDroppedSamples: 0)
        }
        let session = RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: 640, height: 360, duration: duration,
            events: [CursorEvent(time: 1.0, x: 0.5, y: 0.5, kind: .down), CursorEvent(time: 1.1, x: 0.5, y: 0.5, kind: .up)],
            droppedFrames: 0, eventCaptureAvailable: true, audio: audio)
        try session.save(in: directory)
        return (session, directory)
    }

    private static func makeVideo(url: URL, width: Int, height: Int, duration: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw VerificationError.failed("cannot add fixture video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VerificationError.failed("writer did not start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(duration * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw VerificationError.failed("no pixel buffer pool") }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else { throw VerificationError.failed("could not allocate a fixture frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let shade = UInt8(60 + frame % 120)
                memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? VerificationError.failed("writer rejected a fixture frame")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VerificationError.failed("fixture did not finish") }
    }

    /// Replaces `movie` with its video plus one audio track per WAV, in order.
    private static func muxAudio(into movie: URL, directory: URL, tones: [URL], duration: Double) async throws {
        let videoAsset = AVURLAsset(url: movie)
        let composition = AVMutableComposition()
        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTarget = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VerificationError.failed("could not create source video composition track")
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        try videoTarget.insertTimeRange(range, of: videoSource, at: .zero)
        for sourceAsset in tones.map({ AVURLAsset(url: $0) }) {
            guard let source = try await sourceAsset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VerificationError.failed("could not create an audio composition track")
            }
            try target.insertTimeRange(range, of: source, at: .zero)
        }
        let muxed = directory.appendingPathComponent("muxed.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw VerificationError.failed("could not create synthetic audio mux")
        }
        try await exporter.export(to: muxed, as: .mp4)
        try FileManager.default.removeItem(at: movie)
        try FileManager.default.moveItem(at: muxed, to: movie)
    }

    /// A mono 16-bit 48 kHz WAV whose frequency follows `frequency(time)` with continuous phase.
    private static func writeToneWAV(to url: URL, duration: Double, frequency: (Double) -> Double) throws {
        let sampleRate = 48_000
        let count = Int(Double(sampleRate) * duration)
        let dataBytes = count * 2
        var data = Data()
        func put16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        func put32(_ value: UInt32) {
            data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
        }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        var phase = 0.0
        for index in 0..<count {
            phase += 2 * Double.pi * frequency(Double(index) / Double(sampleRate)) / Double(sampleRate)
            put16(UInt16(bitPattern: Int16(sin(phase) * 10_000)))
        }
        try data.write(to: url)
    }
}

private enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let reason): reason }
    }
}
