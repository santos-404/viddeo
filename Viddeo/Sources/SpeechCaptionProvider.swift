import AVFoundation
import CoreMedia
import Foundation
import Speech

protocol CaptionTranscriptionProvider: Sendable {
    /// Returns word-level cues in milliseconds relative to the start of `audioURL`.
    func transcribe(audioURL: URL, locale: Locale, progress: @Sendable (Double) -> Void) async throws -> [CaptionCue]
}

/// On-device Apple speech (macOS 26 `SpeechTranscriber` + `SpeechAnalyzer`). Nothing leaves the Mac;
/// the locale model is installed through `AssetInventory` when missing.
struct AppleSpeechCaptionProvider: CaptionTranscriptionProvider {
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func transcribe(audioURL: URL, locale: Locale, progress: @Sendable (Double) -> Void) async throws -> [CaptionCue] {
        guard SpeechTranscriber.isAvailable else { throw CaptionError.speechUnavailable("this Mac has no speech transcriber") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CaptionError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported { throw CaptionError.unsupportedLocale(supported.identifier) }
        if status < .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        progress(0.05)

        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = transcriber.results
        let feeder = Task {
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                // Ends the results sequence so the consumer below cannot wait forever.
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
        var raw: [(text: String, start: Double, end: Double, confidence: Double?)] = []
        do {
            for try await result in results where result.isFinal {
                var firstInResult = true
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    guard let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric else {
                        // Untimed runs (spaces, punctuation) belong to the previous token.
                        if !raw.isEmpty { raw[raw.count - 1].text += text }
                        continue
                    }
                    // A new result always starts a new word.
                    let token = firstInResult && !(text.first?.isWhitespace ?? false) ? " " + text : text
                    firstInResult = false
                    raw.append((token, range.start.seconds, range.end.seconds, run.transcriptionConfidence))
                }
                if duration > 0 { progress(0.05 + 0.95 * min(1, max(0, result.range.end.seconds / duration))) }
            }
        } catch {
            feeder.cancel()
            throw error
        }
        try await feeder.value
        progress(1)
        return CaptionTrack.normalize(rawWords: raw)
    }
}

/// Exports the session's microphone track to a temporary 16 kHz mono 16-bit CAF whose time 0
/// is the movie's time 0 (the first video frame), so cue times map directly to the session.
struct CaptionAudioExtractor: Sendable {
    static let sampleRate = 16_000.0

    func extractMicrophoneAudio(sessionDirectory: URL, session: RecordingSession) async throws -> URL {
        guard let audio = session.audio, audio.microphoneRequested, audio.microphoneSamples > 0 else {
            throw CaptionError.noMicrophoneAudio
        }
        let asset = AVURLAsset(url: sessionDirectory.appendingPathComponent(session.videoFilename))
        let track = try await Self.microphoneTrack(in: asset, audio: audio)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-captions-\(UUID().uuidString).caf")
        do {
            try Self.export(asset: asset, track: track, to: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The recorder titles each AAC track ("System Audio" / "Microphone") and adds the system
    /// track first, so order is the fallback when the title metadata is unavailable.
    static func microphoneTrack(in asset: AVURLAsset, audio: AudioCaptureMetadata) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        for track in tracks {
            let items = try await track.load(.commonMetadata) + track.load(.metadata)
            for item in items where item.identifier == .commonIdentifierTitle || item.commonKey == .commonKeyTitle {
                if try await item.load(.stringValue) == audio.microphoneTrackName { return track }
            }
        }
        let expected = (audio.systemAudioRequested ? 1 : 0) + 1
        guard tracks.count == expected, let last = tracks.last else { throw CaptionError.noMicrophoneAudio }
        return last
    }

    private static func export(asset: AVURLAsset, track: AVAssetTrack, to url: URL) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw CaptionError.audioExportFailed("the microphone track cannot be decoded") }
        reader.add(output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw CaptionError.audioExportFailed("no PCM format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard reader.startReading() else {
            throw CaptionError.audioExportFailed(reader.error?.localizedDescription ?? "the reader could not start")
        }
        var written: AVAudioFramePosition = 0
        while let buffer = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts.isNumeric {
                // Leading offsets and capture gaps become silence so file time stays movie time.
                let expected = AVAudioFramePosition((pts.seconds * sampleRate).rounded())
                if expected - written > AVAudioFramePosition(sampleRate / 100) {
                    try writeSilence(frames: expected - written, format: format, to: file)
                    written = expected
                }
            }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw CaptionError.audioExportFailed("no PCM buffer")
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames),
                                                                     into: pcm.mutableAudioBufferList)
            guard status == noErr else { throw CaptionError.audioExportFailed("PCM copy failed (\(status))") }
            try file.write(from: pcm)
            written += AVAudioFramePosition(frames)
        }
        guard reader.status == .completed else {
            throw CaptionError.audioExportFailed(reader.error?.localizedDescription ?? "reading stopped early")
        }
        guard written > 0 else { throw CaptionError.noMicrophoneAudio }
    }

    private static func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat, to file: AVAudioFile) throws {
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(sampleRate)))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw CaptionError.audioExportFailed("no PCM buffer")
            }
            silence.frameLength = count // AVAudioPCMBuffer memory starts zeroed.
            try file.write(from: silence)
            remaining -= AVAudioFramePosition(count)
        }
    }
}

/// Extract → transcribe → merge with user edits → persist `captions.json` beside `session.json`.
struct CaptionService: Sendable {
    var provider: any CaptionTranscriptionProvider = AppleSpeechCaptionProvider()
    var extractor = CaptionAudioExtractor()
    var generator = "apple-speech"

    func generate(sessionDirectory: URL, session: RecordingSession, locale: Locale,
                  progress: @Sendable (Double) -> Void = { _ in }) async throws -> CaptionTrack {
        // Load first: an unreadable or newer captions file must not be overwritten.
        let existing = try CaptionTrack.load(from: sessionDirectory)
        let audioURL = try await extractor.extractMicrophoneAudio(sessionDirectory: sessionDirectory, session: session)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let cues = try await provider.transcribe(audioURL: audioURL, locale: locale, progress: progress)
        let regenerated = CaptionTrack(locale: locale.identifier(.bcp47), generator: generator,
                                       cues: cues.sorted { $0.startMs < $1.startMs })
        try regenerated.validate()
        let track = existing?.merging(regenerated: regenerated) ?? regenerated
        try track.save(to: sessionDirectory)
        return track
    }
}
