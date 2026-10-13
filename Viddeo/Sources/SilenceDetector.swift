import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Observed (reference): `project.silenceChunks` takes `threshold`, `minSilenceDuration` and
/// `windowSize` and returns `{startMs, endMs, avgAmplitude, durationMs}` chunks. The reference's
/// definition of `threshold` is unknown; viddeo defines it as a ratio of the file's peak window RMS.
struct SilenceOptions: Codable, Sendable, Equatable {
    /// Observed webcam-hiding value. Viddeo definition: a window is silent when its RMS is at most
    /// `threshold` × the loudest window's RMS (0 only matches digital silence, 1 matches everything).
    var threshold = 0.1
    /// Viddeo default; the reference derives it from the consumer.
    var minSilenceDurationMs = 500.0
    /// Observed window size.
    var windowMs = 50.0

    static let windowRange = 1.0...1000.0

    func validate() throws {
        guard threshold.isFinite, minSilenceDurationMs.isFinite, windowMs.isFinite,
              (0...1).contains(threshold), minSilenceDurationMs >= 0, Self.windowRange.contains(windowMs)
        else { throw SilenceError.invalidOptions }
    }
}

/// Times are milliseconds from the start of the analyzed audio (the movie's time 0), exact multiples
/// of the window size; `endMs` is exclusive.
struct SilenceDetectionChunk: Codable, Sendable, Equatable {
    var startMs: Double
    var endMs: Double
    /// Mean window RMS of the chunk, in full-scale units (1 = a full-scale square wave).
    var avgAmplitude: Double
    var durationMs: Double
}

enum SilenceTrackSelection: Sendable, Equatable {
    /// The audio track titled `title`; the last audio track when no title matches (the recorder
    /// adds the system track first and the microphone last).
    case microphone(title: String)
    case lastAudioTrack
    case index(Int)
}

enum SilenceError: LocalizedError, Equatable {
    case invalidOptions
    case noAudioTrack
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidOptions: "Silence detection needs a threshold from 0 to 1, a non-negative minimum duration and a window of 1–1000 ms."
        case .noAudioTrack: "The recording has no audio track to analyze."
        case .readFailed(let reason): "The audio could not be analyzed: \(reason)"
        }
    }
}

enum SilenceDetector {
    static let analysisSampleRate = 16_000.0

    /// Pure core. A window is silent when its RMS ≤ `threshold` × the peak window RMS, so a
    /// constant-level signal is never silent unless it is exactly zero (peak 0 ⇒ everything is silent).
    /// Consecutive silent windows merge; chunks shorter than `minSilenceDurationMs` are dropped.
    static func chunks(rms: [Float], windowMs: Double, options: SilenceOptions) -> [SilenceDetectionChunk] {
        guard windowMs.isFinite, windowMs > 0, (try? options.validate()) != nil,
              let peak = rms.max(), peak.isFinite
        else { return [] }
        let limit = options.threshold * Double(peak)
        var result: [SilenceDetectionChunk] = []
        var runStart: Int?
        func close(at end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let durationMs = Double(end - start) * windowMs
            guard durationMs >= options.minSilenceDurationMs - 1e-9 else { return }
            let sum = rms[start..<end].reduce(0.0) { $0 + Double($1) }
            result.append(SilenceDetectionChunk(startMs: Double(start) * windowMs, endMs: Double(end) * windowMs,
                                                avgAmplitude: sum / Double(end - start), durationMs: durationMs))
        }
        for (index, value) in rms.enumerated() {
            if Double(value) <= limit {
                if runStart == nil { runStart = index }
            } else {
                close(at: index)
            }
        }
        close(at: rms.count)
        return result
    }

    static func detect(audioURL: URL, trackSelection: SilenceTrackSelection = .microphone(title: "Microphone"),
                       options: SilenceOptions = .init()) async throws -> [SilenceDetectionChunk] {
        try options.validate()
        let asset = AVURLAsset(url: audioURL)
        let track = try await selectTrack(in: asset, selection: trackSelection)
        let rms = try await windowRMS(asset: asset, track: track, windowMs: options.windowMs)
        return chunks(rms: rms, windowMs: options.windowMs, options: options)
    }

    static func selectTrack(in asset: AVURLAsset, selection: SilenceTrackSelection) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let last = tracks.last else { throw SilenceError.noAudioTrack }
        switch selection {
        case .lastAudioTrack:
            return last
        case .index(let index):
            guard tracks.indices.contains(index) else { throw SilenceError.noAudioTrack }
            return tracks[index]
        case .microphone(let title):
            for track in tracks {
                let items = try await track.load(.commonMetadata) + track.load(.metadata)
                for item in items where item.identifier == .commonIdentifierTitle || item.commonKey == .commonKeyTitle {
                    if try await item.load(.stringValue) == title { return track }
                }
            }
            return last
        }
    }

    /// RMS per complete `windowMs` window of the track, mono-mixed at 16 kHz and streamed buffer by
    /// buffer. Time 0 is the movie's time 0: leading offsets and capture gaps count as digital silence
    /// and a trailing partial window is dropped.
    static func windowRMS(asset: AVURLAsset, track: AVAssetTrack, windowMs: Double) async throws -> [Float] {
        let rate = analysisSampleRate
        let windowSamples = max(1, Int((windowMs * rate / 1000).rounded()))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw SilenceError.readFailed("the audio track cannot be decoded") }
        reader.add(output)
        guard reader.startReading() else {
            throw SilenceError.readFailed(reader.error?.localizedDescription ?? "the reader could not start")
        }
        var accumulator = WindowRMSAccumulator(windowSamples: windowSamples)
        var scratch = [Float](repeating: 0, count: 8192)
        var buffers = 0
        while let buffer = output.copyNextSampleBuffer() {
            buffers += 1
            if buffers % 256 == 0 { await Task.yield() }
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts.isNumeric {
                let expected = Int((pts.seconds * rate).rounded())
                if expected - accumulator.totalSamples > Int(rate / 100) {
                    accumulator.appendSilence(count: expected - accumulator.totalSamples)
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let samples = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard samples > 0 else { continue }
            if scratch.count < samples { scratch = [Float](repeating: 0, count: samples) }
            let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                guard let destination = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples * MemoryLayout<Float>.size,
                                                  destination: destination)
            }
            guard status == kCMBlockBufferNoErr else { throw SilenceError.readFailed("sample copy failed (\(status))") }
            scratch.withUnsafeBufferPointer { accumulator.append(UnsafeBufferPointer(rebasing: $0[0..<samples])) }
        }
        guard reader.status == .completed else {
            throw SilenceError.readFailed(reader.error?.localizedDescription ?? "reading stopped early")
        }
        return accumulator.rms
    }
}

/// Streaming window RMS: constant memory apart from the output (one value per window).
struct WindowRMSAccumulator {
    let windowSamples: Int
    private(set) var rms: [Float] = []
    private(set) var totalSamples = 0
    private var sumSquares = 0.0
    private var filled = 0

    init(windowSamples: Int) {
        self.windowSamples = max(1, windowSamples)
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        var offset = 0
        while offset < samples.count {
            let take = min(windowSamples - filled, samples.count - offset)
            var energy: Float = 0
            vDSP_svesq(base + offset, 1, &energy, vDSP_Length(take))
            sumSquares += Double(energy)
            advance(by: take)
            offset += take
        }
    }

    mutating func appendSilence(count: Int) {
        var remaining = count
        while remaining > 0 {
            let take = min(windowSamples - filled, remaining)
            advance(by: take)
            remaining -= take
        }
    }

    private mutating func advance(by count: Int) {
        filled += count
        totalSamples += count
        if filled == windowSamples {
            rms.append(Float((sumSquares / Double(windowSamples)).squareRoot()))
            sumSquares = 0
            filled = 0
        }
    }
}
