import Accelerate
import AVFoundation
import Foundation

/// Observed microphone presets (`voice`, `noise-reduction`, `podcast`) plus an explicit bypass.
enum MicrophonePreset: String, Codable, Sendable, CaseIterable {
    case voice
    case noiseReduction = "noise-reduction"
    case podcast
    case off
}

/// Mirrors the observed audio block (master volume, mutes, mic preset, background music, click
/// sound) and adds viddeo's own final-stage parameters (`limiterCeilingDB`, `targetLoudnessLUFS`).
struct AudioMixConfiguration: Codable, Sendable, Equatable {
    var volume = 1.0
    var muteMicrophone = false
    var muteSystemAudio = false
    var microphonePreset = MicrophonePreset.voice
    /// A plain file name inside the session directory; never a path.
    var backgroundAudioFileName: String? = nil
    var backgroundAudioVolume = 0.05
    var muteBackgroundAudio = false
    var clickSoundEffect: ClickSoundSet? = nil
    var clickSoundEffectVolume = 0.25
    var limiterCeilingDB = -1.0
    var targetLoudnessLUFS: Double? = nil
    /// Export one stereo AAC track (every edited source summed, optionally loudness-normalized, then
    /// limited) instead of one track per source. MP4 only.
    var mixdownSingleTrack = false

    enum CodingKeys: String, CodingKey {
        case volume, muteMicrophone, muteSystemAudio, microphonePreset, backgroundAudioFileName,
             backgroundAudioVolume, muteBackgroundAudio, clickSoundEffect, clickSoundEffectVolume,
             limiterCeilingDB, targetLoudnessLUFS, mixdownSingleTrack
    }

    func validate() throws {
        let volumes = [volume, backgroundAudioVolume, clickSoundEffectVolume]
        guard volumes.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 4 }),
              limiterCeilingDB.isFinite, limiterCeilingDB >= -20, limiterCeilingDB <= 0
        else { throw AudioProcessingError.invalidConfiguration }
        if let target = targetLoudnessLUFS {
            guard target.isFinite, target >= -40, target <= -5 else { throw AudioProcessingError.invalidConfiguration }
        }
        if let name = backgroundAudioFileName, !Self.isSafeFileName(name) {
            throw AudioProcessingError.invalidBackgroundAudioFileName
        }
    }

    /// Accepts only a single relative path component: no separators, traversal, hidden or control names.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".") && !name.hasPrefix("~") &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
            !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// True when exporting with this configuration would not change the recorded audio: master volume,
    /// mutes, microphone preset, click sounds, background music (unmuted) and the mixdown are all at
    /// their no-op values. The limiter and loudness target only act inside the mixdown.
    var isExportNeutral: Bool {
        volume == 1 && !muteMicrophone && !muteSystemAudio && microphonePreset == .off && clickSoundEffect == nil
            && !hasActiveBackgroundMusic && !mixdownSingleTrack
    }

    /// Music is chosen and not muted.
    var hasActiveBackgroundMusic: Bool { backgroundAudioFileName != nil && !muteBackgroundAudio }

    /// viddeo's starting point for a project without `audio-config.json`: the observed defaults,
    /// except that microphone cleanup is off (a design choice — it is lossy and opt-in).
    static var editorDefault: Self {
        var configuration = Self()
        configuration.microphonePreset = .off
        return configuration
    }

    func backgroundAudioURL(in directory: URL) -> URL? {
        guard let name = backgroundAudioFileName, Self.isSafeFileName(name) else { return nil }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("audio-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("audio-config.json"), options: .atomic)
    }
}

extension AudioMixConfiguration {
    /// Missing keys fall back to defaults so older or hand-written files stay loadable.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? volume
        muteMicrophone = try container.decodeIfPresent(Bool.self, forKey: .muteMicrophone) ?? muteMicrophone
        muteSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .muteSystemAudio) ?? muteSystemAudio
        microphonePreset = try container.decodeIfPresent(MicrophonePreset.self, forKey: .microphonePreset) ?? microphonePreset
        backgroundAudioFileName = try container.decodeIfPresent(String.self, forKey: .backgroundAudioFileName)
        backgroundAudioVolume = try container.decodeIfPresent(Double.self, forKey: .backgroundAudioVolume) ?? backgroundAudioVolume
        muteBackgroundAudio = try container.decodeIfPresent(Bool.self, forKey: .muteBackgroundAudio) ?? muteBackgroundAudio
        clickSoundEffect = try container.decodeIfPresent(ClickSoundSet.self, forKey: .clickSoundEffect)
        clickSoundEffectVolume = try container.decodeIfPresent(Double.self, forKey: .clickSoundEffectVolume) ?? clickSoundEffectVolume
        limiterCeilingDB = try container.decodeIfPresent(Double.self, forKey: .limiterCeilingDB) ?? limiterCeilingDB
        targetLoudnessLUFS = try container.decodeIfPresent(Double.self, forKey: .targetLoudnessLUFS)
        mixdownSingleTrack = try container.decodeIfPresent(Bool.self, forKey: .mixdownSingleTrack) ?? false
    }
}

enum AudioProcessingError: LocalizedError {
    case invalidConfiguration
    case invalidBackgroundAudioFileName
    case missingBackgroundAudio(String)
    case missingAudioTrack(String)
    case unreadableAudio(String)
    case unwritableAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Audio settings contain invalid volume, limiter or loudness values."
        case .invalidBackgroundAudioFileName: "The background audio must be a file name inside the session folder."
        case .missingBackgroundAudio(let name): "The background music file \"\(name)\" was not found in the session folder."
        case .missingAudioTrack(let name): "The audio track \(name) was not found."
        case .unreadableAudio(let detail): "Audio could not be read: \(detail)"
        case .unwritableAudio(let detail): "Audio could not be written: \(detail)"
        }
    }
}

/// De-interleaved float samples. All processing runs at 48 kHz.
struct PCMAudio: Sendable, Equatable {
    var sampleRate: Double
    var channels: [[Float]]
    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: Double { Double(frameCount) / sampleRate }
}

enum AudioFileIO {
    static let sampleRate = 48_000.0

    /// Decodes (and resamples to 48 kHz) the first audio track, or the track whose common title
    /// matches `trackTitle` — raw.mp4 names its AAC tracks "System Audio" and "Microphone".
    static func read(_ url: URL, trackTitle: String? = nil, maxChannels: Int = 2) async throws -> PCMAudio {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch {
            throw AudioProcessingError.unreadableAudio(error.localizedDescription)
        }
        var selected = trackTitle == nil ? tracks.first : nil
        if let trackTitle {
            search: for track in tracks {
                let metadata = try await track.load(.commonMetadata)
                for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
                where try await item.load(.stringValue) == trackTitle {
                    selected = track
                    break search
                }
            }
        }
        guard let track = selected else { throw AudioProcessingError.missingAudioTrack(trackTitle ?? "audio") }
        return try await decode(asset: asset, track: track, maxChannels: maxChannels)
    }

    /// Decodes one track to 48 kHz float PCM. Sample timestamps are ignored: the first decoded sample
    /// is frame 0, so callers that care about a track's start offset must account for it themselves.
    static func decode(asset: AVAsset, track: AVAssetTrack, maxChannels: Int = 2) async throws -> PCMAudio {
        let descriptions = try await track.load(.formatDescriptions)
        let sourceChannels = descriptions.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let channelCount = max(1, min(max(1, maxChannels), Int(sourceChannels)))
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw AudioProcessingError.unreadableAudio(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioProcessingError.unreadableAudio("Unsupported audio format.") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioProcessingError.unreadableAudio(reader.error?.localizedDescription ?? "Reading failed.")
        }
        var interleaved: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = interleaved.count
            interleaved.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            let status = interleaved.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                  destination: base + start * MemoryLayout<Float>.size)
            }
            guard status == kCMBlockBufferNoErr else { throw AudioProcessingError.unreadableAudio("Sample copy failed.") }
        }
        guard reader.status == .completed else {
            throw AudioProcessingError.unreadableAudio(reader.error?.localizedDescription ?? "Reading did not finish.")
        }
        let frames = interleaved.count / channelCount
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<frames { channels[channel][frame] = interleaved[frame * channelCount + channel] }
        }
        return PCMAudio(sampleRate: sampleRate, channels: channels)
    }

    /// Writes 16-bit little-endian integer PCM; the container follows the extension (`.caf` or `.wav`).
    /// viddeo writes CAF by default: lossless, no 4 GB RIFF limit, and native to AVFoundation.
    static func write(_ audio: PCMAudio, to url: URL) throws {
        let channelCount = audio.channels.count
        guard channelCount > 0, audio.channels.allSatisfy({ $0.count == audio.frameCount }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate,
                                         channels: AVAudioChannelCount(channelCount), interleaved: false)
        else { throw AudioProcessingError.unwritableAudio("Invalid channel layout.") }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw AudioProcessingError.unwritableAudio(error.localizedDescription) }
        let chunk = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let data = buffer.floatChannelData
        else { throw AudioProcessingError.unwritableAudio("Buffer allocation failed.") }
        var offset = 0
        while offset < audio.frameCount {
            let count = min(chunk, audio.frameCount - offset)
            for channel in 0..<channelCount {
                audio.channels[channel].withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    data[channel].update(from: base + offset, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            do { try file.write(from: buffer) } catch { throw AudioProcessingError.unwritableAudio(error.localizedDescription) }
            offset += count
        }
        file.close()
    }
}

/// Microphone cleanup. Screen Studio runs a bundled neural speech-enhancement model for these
/// presets; that model is not available to viddeo, so each preset is a classical, deterministic DSP
/// chain (biquads, envelope dynamics, STFT spectral subtraction) — a deliberate design choice.
///
/// - `voice`: 4th-order 80 Hz high-pass → light downward expander → gentle 2:1 compressor → broad
///   +2 dB presence bell at 3 kHz (wide enough to lift intelligibility, low enough to leave the
///   5–8 kHz sibilance band alone, so no de-esser is needed).
/// - `noiseReduction`: high-pass → spectral subtraction → the rest of the `voice` chain. Denoising
///   runs before dynamics so the expander and compressor see the cleaned floor.
/// - `podcast`: `noiseReduction` with a 4:1 compressor, +6 dB makeup, +3.5 dB presence and a
///   look-ahead brick-wall limiter at `limiterCeilingDB`.
/// - `off`: passthrough.
///
/// Output is 48 kHz 16-bit PCM with the input's channel count (mono stays mono, >2 is downmixed to
/// stereo). A 48 kHz input yields exactly the same sample count; other rates are resampled first.
enum VoiceCleanup {
    static func process(inputURL: URL, outputURL: URL, preset: MicrophonePreset,
                        limiterCeilingDB: Double = -1,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        progress?(0)
        let input = try await AudioFileIO.read(inputURL)
        try Task.checkCancellation()
        progress?(0.1)
        let output = try process(input, preset: preset, limiterCeilingDB: limiterCeilingDB) { progress?(0.1 + 0.85 * $0) }
        try AudioFileIO.write(output, to: outputURL)
        progress?(1)
    }

    /// Pure and deterministic: identical input yields identical samples.
    static func process(_ audio: PCMAudio, preset: MicrophonePreset, limiterCeilingDB: Double = -1,
                        progress: (Double) -> Void = { _ in }) throws -> PCMAudio {
        guard preset != .off, audio.frameCount > 0 else { progress(1); return audio }
        let rate = audio.sampleRate
        var channels = audio.channels
        let heavy = preset == .podcast
        for index in channels.indices {
            Biquad.highPass(frequency: 80, q: 0.541_196_1, sampleRate: rate).process(&channels[index])
            Biquad.highPass(frequency: 80, q: 1.306_563, sampleRate: rate).process(&channels[index])
        }
        progress(0.1)
        if preset != .voice {
            for index in channels.indices {
                try Task.checkCancellation()
                channels[index] = SpectralNoiseReducer.process(channels[index], sampleRate: rate)
                progress(0.1 + 0.6 * Double(index + 1) / Double(channels.count))
            }
        }
        try Task.checkCancellation()
        Dynamics.expand(&channels, sampleRate: rate, thresholdDB: -50, ratio: 2, rangeDB: 18)
        Dynamics.compress(&channels, sampleRate: rate, thresholdDB: heavy ? -24 : -18, ratio: heavy ? 4 : 2,
                          kneeDB: 6, attack: heavy ? 0.005 : 0.010, release: heavy ? 0.100 : 0.150,
                          makeupDB: heavy ? 6 : 0)
        progress(0.85)
        for index in channels.indices {
            Biquad.peaking(frequency: 3_000, q: 0.9, gainDB: heavy ? 3.5 : 2, sampleRate: rate).process(&channels[index])
        }
        if heavy { Limiter.process(&channels, ceilingDB: limiterCeilingDB, sampleRate: rate) }
        progress(1)
        return PCMAudio(sampleRate: rate, channels: channels)
    }
}

/// RBJ cookbook biquad, transposed direct form II in double precision.
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Self {
        let w = 2 * Double.pi * frequency / sampleRate, cosW = cos(w), alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Self(b0: (1 + cosW) / 2 / a0, b1: -(1 + cosW) / a0, b2: (1 + cosW) / 2 / a0,
                    a1: -2 * cosW / a0, a2: (1 - alpha) / a0)
    }

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Self {
        let w = 2 * Double.pi * frequency / sampleRate, cosW = cos(w), alpha = sin(w) / (2 * q)
        let a = pow(10, gainDB / 40), a0 = 1 + alpha / a
        return Self(b0: (1 + alpha * a) / a0, b1: -2 * cosW / a0, b2: (1 - alpha * a) / a0,
                    a1: -2 * cosW / a0, a2: (1 - alpha / a) / a0)
    }

    func process(_ samples: inout [Float]) {
        var z1 = 0.0, z2 = 0.0
        for index in samples.indices {
            let x = Double(samples[index])
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[index] = Float(y)
        }
    }
}

/// Stereo-linked envelope dynamics: one detector drives every channel to keep the image stable.
enum Dynamics {
    private static func coefficient(_ seconds: Double, _ rate: Double) -> Double { exp(-1 / (seconds * rate)) }

    private static func peakLevel(_ channels: [[Float]], _ index: Int) -> Double {
        var level: Float = 0
        for channel in channels { level = max(level, abs(channel[index])) }
        return Double(level)
    }

    /// Downward expander: below the threshold each dB of input drops `ratio` dB, limited to `rangeDB`.
    static func expand(_ channels: inout [[Float]], sampleRate: Double, thresholdDB: Double,
                       ratio: Double, rangeDB: Double) {
        let frames = channels.first?.count ?? 0
        let attack = coefficient(0.001, sampleRate), release = coefficient(0.060, sampleRate)
        let open = coefficient(0.002, sampleRate), close = coefficient(0.030, sampleRate)
        var envelope = 0.0, gainDB = 0.0
        for index in 0..<frames {
            let level = peakLevel(channels, index)
            let a = level > envelope ? attack : release
            envelope = a * envelope + (1 - a) * level
            let levelDB = 20 * log10(max(envelope, 1e-9))
            let target = levelDB < thresholdDB ? max(-rangeDB, (levelDB - thresholdDB) * (ratio - 1)) : 0
            let g = target > gainDB ? open : close
            gainDB = g * gainDB + (1 - g) * target
            let gain = Float(pow(10, gainDB / 20))
            for channel in channels.indices { channels[channel][index] *= gain }
        }
    }

    /// Feed-forward soft-knee compressor on a peak envelope.
    static func compress(_ channels: inout [[Float]], sampleRate: Double, thresholdDB: Double, ratio: Double,
                         kneeDB: Double, attack: Double, release: Double, makeupDB: Double) {
        let frames = channels.first?.count ?? 0
        let attackCoefficient = coefficient(attack, sampleRate), releaseCoefficient = coefficient(release, sampleRate)
        let slope = 1 / ratio - 1
        var envelope = 0.0
        for index in 0..<frames {
            let level = peakLevel(channels, index)
            let a = level > envelope ? attackCoefficient : releaseCoefficient
            envelope = a * envelope + (1 - a) * level
            let over = 20 * log10(max(envelope, 1e-9)) - thresholdDB
            let reduction: Double
            if 2 * over < -kneeDB {
                reduction = 0
            } else if 2 * abs(over) <= kneeDB {
                reduction = slope * (over + kneeDB / 2) * (over + kneeDB / 2) / (2 * kneeDB)
            } else {
                reduction = slope * over
            }
            let gain = Float(pow(10, (reduction + makeupDB) / 20))
            for channel in channels.indices { channels[channel][index] *= gain }
        }
    }
}

/// Offline look-ahead brick-wall limiter. The gain at every sample is provably ≤ the gain that
/// sample needs (sliding minimum over the look-ahead, then a box average of the same length), and a
/// final clamp keeps 16-bit rounding under the ceiling.
enum Limiter {
    static func process(_ channels: inout [[Float]], ceilingDB: Double, sampleRate: Double,
                        lookahead: Double = 0.005, release: Double = 0.080) {
        let frames = channels.first?.count ?? 0
        guard frames > 0 else { return }
        let ceilingDB = ceilingDB.isFinite ? min(0, max(-20, ceilingDB)) : -1
        // Two 16-bit LSBs of headroom so quantization never rounds above the ceiling.
        let ceiling = pow(10, ceilingDB / 20) - 2.0 / 32_768
        var required = [Double](repeating: 1, count: frames)
        for index in 0..<frames {
            var peak: Float = 0
            for channel in channels { peak = max(peak, abs(channel[index])) }
            if Double(peak) > ceiling { required[index] = ceiling / Double(peak) }
        }
        let window = max(1, Int(lookahead * sampleRate))
        // Forward-looking sliding minimum (van Herk / Gil-Werman), padded with unity gain.
        let padded = required + [Double](repeating: 1, count: window)
        var prefix = padded, suffix = padded
        for index in padded.indices where index % window != 0 { prefix[index] = min(prefix[index - 1], padded[index]) }
        for index in stride(from: padded.count - 2, through: 0, by: -1) where (index + 1) % window != 0 {
            suffix[index] = min(suffix[index + 1], padded[index])
        }
        var held = [Double](repeating: 1, count: frames)
        for index in 0..<frames { held[index] = min(suffix[index], prefix[index + window - 1]) }
        // Backward box average: every averaged value comes from a window that covers this sample.
        // Before the first sample the window is filled with held[0], which also covers it.
        var sum = held[0] * Double(window)
        var smoothed = [Double](repeating: 1, count: frames)
        for index in 0..<frames {
            sum += held[index] - (index >= window ? held[index - window] : held[0])
            smoothed[index] = sum / Double(window)
        }
        let releaseCoefficient = exp(-1 / (release * sampleRate))
        var gain = 1.0
        for index in 0..<frames {
            let target = smoothed[index]
            gain = target < gain ? target : releaseCoefficient * gain + (1 - releaseCoefficient) * target
            let limit = Float(ceiling)
            for channel in channels.indices {
                channels[channel][index] = min(limit, max(-limit, channels[channel][index] * Float(gain)))
            }
        }
    }
}

/// Spectral subtraction (power domain) with a √Hann STFT, N = 1024, hop = 256 (75 % overlap,
/// perfect reconstruction at unity gain). The noise profile is the mean power spectrum of the
/// quietest ≈ 0.5 s of frames; gain = √max(1 − α·N/P, β²) with α = 1.5 and β = 0.1, smoothed over
/// time (fast open, slow close) and across neighbouring bins to suppress musical noise.
enum SpectralNoiseReducer {
    static let frameLength = 1024
    static let hop = 256

    static func process(_ samples: [Float], sampleRate: Double, oversubtraction: Float = 1.5,
                        spectralFloor: Float = 0.1, profileSeconds: Double = 0.5) -> [Float] {
        let n = frameLength, half = n / 2, length = samples.count
        guard length >= n,
              let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(n), .INVERSE)
        else { return samples }
        defer { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }
        let window = (0..<n).map { Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)))) }
        let padded = [Float](repeating: 0, count: n) + samples + [Float](repeating: 0, count: n + hop)
        let starts = Array(stride(from: 0, through: padded.count - n, by: hop))
        var frame = [Float](repeating: 0, count: n)
        var inReal = [Float](repeating: 0, count: half), inImag = inReal, outReal = inReal, outImag = inReal

        func analyze(_ start: Int) {
            padded.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                vDSP_vmul(base + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            for k in 0..<half { inReal[k] = frame[2 * k]; inImag[k] = frame[2 * k + 1] }
            vDSP_DFT_Execute(forward, inReal, inImag, &outReal, &outImag)
        }
        func power(_ k: Int) -> Float {
            k == 0 ? outReal[0] * outReal[0] : k == half ? outImag[0] * outImag[0]
                : outReal[k] * outReal[k] + outImag[k] * outImag[k]
        }

        // Noise profile from the quietest interior frames; digital silence carries no noise information.
        let interior = starts.filter { $0 >= n && $0 + n <= n + length }
        var energies: [(start: Int, energy: Float)] = interior.map { start in
            var energy: Float = 0
            padded.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                vDSP_svesq(base + start, 1, &energy, vDSP_Length(n))
            }
            return (start, energy / Float(n))
        }
        let audible = energies.filter { $0.energy > 1e-10 }
        if !audible.isEmpty { energies = audible }
        energies.sort { $0.energy == $1.energy ? $0.start < $1.start : $0.energy < $1.energy }
        let profileCount = max(1, min(energies.count, Int((profileSeconds * sampleRate / Double(hop)).rounded())))
        var noise = [Float](repeating: 0, count: half + 1)
        for entry in energies.prefix(profileCount) {
            analyze(entry.start)
            for k in 0...half { noise[k] += power(k) / Float(profileCount) }
        }

        var output = [Float](repeating: 0, count: padded.count)
        var previous = [Float](repeating: 1, count: half + 1)
        var gains = previous, smoothed = previous
        let floorSquared = spectralFloor * spectralFloor
        let scale = 1 / Float(2 * n) / 2 // round-trip DFT scale (2N) and √Hann² overlap sum (2)
        for start in starts {
            analyze(start)
            for k in 0...half {
                let p = power(k)
                let ratio = p > 0 ? noise[k] / p : 1
                let gain = sqrt(max(1 - oversubtraction * ratio, floorSquared))
                let a: Float = gain > previous[k] ? 0.3 : 0.7
                gains[k] = a * previous[k] + (1 - a) * gain
            }
            previous = gains
            for k in 0...half {
                let lower = gains[max(0, k - 1)], upper = gains[min(half, k + 1)]
                smoothed[k] = max(spectralFloor, 0.25 * lower + 0.5 * gains[k] + 0.25 * upper)
            }
            outReal[0] *= smoothed[0]
            outImag[0] *= smoothed[half]
            for k in 1..<half { outReal[k] *= smoothed[k]; outImag[k] *= smoothed[k] }
            vDSP_DFT_Execute(inverse, outReal, outImag, &inReal, &inImag)
            for k in 0..<half {
                output[start + 2 * k] += inReal[k] * window[2 * k] * scale
                output[start + 2 * k + 1] += inImag[k] * window[2 * k + 1] * scale
            }
        }
        return Array(output[n..<(n + length)])
    }
}

/// ITU-R BS.1770-4 integrated loudness (K-weighting, 400 ms blocks, 75 % overlap, −70 LUFS absolute
/// and −10 LU relative gates). The K-weighting coefficients are the published 48 kHz values.
enum LoudnessMeter {
    static func integratedLoudness(_ audio: PCMAudio) -> Double? {
        guard audio.sampleRate == 48_000, audio.frameCount > 0 else { return nil }
        let weighted = audio.channels.map { channel -> [Float] in
            var samples = channel
            Biquad(b0: 1.535_124_859_586_97, b1: -2.691_696_189_406_38, b2: 1.198_392_810_852_85,
                   a1: -1.690_659_293_182_41, a2: 0.732_480_774_215_85).process(&samples)
            Biquad(b0: 1, b1: -2, b2: 1, a1: -1.990_047_454_833_98, a2: 0.990_072_250_366_21).process(&samples)
            return samples
        }
        let block = 19_200, step = 4_800
        guard audio.frameCount >= block else { return nil }
        var powers: [Double] = []
        for start in stride(from: 0, through: audio.frameCount - block, by: step) {
            var total = 0.0
            for channel in weighted {
                var sum: Float = 0
                channel.withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    vDSP_svesq(base + start, 1, &sum, vDSP_Length(block))
                }
                total += Double(sum) / Double(block)
            }
            powers.append(total)
        }
        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let absolute = powers.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

struct MixTrack: Sendable {
    enum Kind: String, Sendable { case microphone, systemAudio, backgroundAudio, clickSounds }
    var url: URL
    var gain: Double
    /// Timeline position of the source's first sample; negative values trim the source's head.
    var startOffset: Double
    var kind: Kind
    /// Optional timeline-time gain segments, applied with `AudioMixer.perSegmentGains`.
    var segments: [(start: Double, end: Double, gain: Double)] = []
}

enum AudioMixer {
    static let crossfade = 0.010

    /// Pure gain/mute math: master volume × source volume × track gain. Muted or silent sources are
    /// dropped. Click tracks are expected at unit volume; `clickSoundEffectVolume` is applied here.
    static func mixdown(tracks: [MixTrack], plan: AudioMixConfiguration) -> [MixTrack] {
        tracks.compactMap { track in
            var mixed = track
            mixed.gain = effectiveGain(track, plan: plan)
            return mixed.gain > 0 ? mixed : nil
        }
    }

    static func effectiveGain(_ track: MixTrack, plan: AudioMixConfiguration) -> Double {
        let source: Double = switch track.kind {
        case .microphone: plan.muteMicrophone ? 0 : 1
        case .systemAudio: plan.muteSystemAudio ? 0 : 1
        case .backgroundAudio: plan.muteBackgroundAudio ? 0 : plan.backgroundAudioVolume
        case .clickSounds: plan.clickSoundEffect == nil ? 0 : plan.clickSoundEffectVolume
        }
        let gain = plan.volume * source * track.gain
        return gain.isFinite ? max(0, gain) : 0
    }

    /// Per-sample gain envelope: a step function (later segments win, uncovered time uses
    /// `defaultGain`) convolved with a centered 10 ms box, i.e. linear 10 ms crossfades at every
    /// boundary that stay monotonic and within the segment gains even when segments are short.
    static func perSegmentGains(_ segments: [(start: Double, end: Double, gain: Double)], frameCount: Int,
                                sampleRate: Double = AudioFileIO.sampleRate, defaultGain: Double = 1,
                                timeOffset: Double = 0) -> [Float] {
        guard frameCount > 0 else { return [] }
        var steps = [Double](repeating: defaultGain, count: frameCount)
        for segment in segments where segment.start.isFinite && segment.end.isFinite && segment.gain.isFinite {
            let lower = max(0, Int(((segment.start - timeOffset) * sampleRate).rounded()))
            let upper = min(frameCount, Int(((segment.end - timeOffset) * sampleRate).rounded()))
            guard upper > lower else { continue }
            for index in lower..<upper { steps[index] = max(0, segment.gain) }
        }
        let radius = max(1, Int((crossfade * sampleRate / 2).rounded()))
        var prefix = [Double](repeating: 0, count: frameCount + 1)
        for index in 0..<frameCount { prefix[index + 1] = prefix[index] + steps[index] }
        func value(_ index: Int) -> Double { steps[min(frameCount - 1, max(0, index))] }
        return (0..<frameCount).map { index in
            let lower = index - radius, upper = index + radius - 1
            var sum = prefix[min(frameCount, upper + 1)] - prefix[max(0, lower)]
            if lower < 0 { sum += Double(-lower) * value(0) }
            if upper >= frameCount { sum += Double(upper - frameCount + 1) * value(frameCount - 1) }
            return Float(sum / Double(2 * radius))
        }
    }

    /// Sums decoded sources onto a 48 kHz stereo timeline. Mono sources feed both channels.
    static func sum(_ sources: [(audio: PCMAudio, track: MixTrack)], frameCount: Int) -> PCMAudio {
        var output = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: 2)
        for (audio, track) in sources where audio.frameCount > 0 && track.gain.isFinite && track.startOffset.isFinite {
            let offset = Int((track.startOffset * AudioFileIO.sampleRate).rounded())
            let first = max(0, offset), last = min(frameCount, offset + audio.frameCount)
            guard last > first else { continue }
            let envelope = track.segments.isEmpty ? nil
                : perSegmentGains(track.segments, frameCount: frameCount)
            let gain = Float(track.gain)
            for channel in 0..<2 {
                let source = audio.channels[min(channel, audio.channels.count - 1)]
                for index in first..<last {
                    output[channel][index] += source[index - offset] * gain * (envelope?[index] ?? 1)
                }
            }
        }
        return PCMAudio(sampleRate: AudioFileIO.sampleRate, channels: output)
    }

    /// Offline mixdown to one 48 kHz stereo 16-bit file: sum → optional loudness normalization →
    /// brick-wall limiter. Pass tracks already resolved by `mixdown(tracks:plan:)`.
    static func render(tracks: [MixTrack], outputURL: URL, limiterCeilingDB: Double = -1,
                       targetLoudnessLUFS: Double? = nil, duration: Double? = nil) async throws {
        var sources: [(audio: PCMAudio, track: MixTrack)] = []
        for track in tracks {
            try Task.checkCancellation()
            sources.append((try await AudioFileIO.read(track.url), track))
        }
        let end = duration ?? sources.map { $0.track.startOffset + $0.audio.duration }.max() ?? 0
        let frameCount = max(0, Int((min(12 * 60 * 60, end.isFinite ? end : 0) * AudioFileIO.sampleRate).rounded()))
        guard frameCount > 0 else { throw AudioProcessingError.unwritableAudio("The mix is empty.") }
        var mix = sum(sources, frameCount: frameCount)
        finalize(&mix, limiterCeilingDB: limiterCeilingDB, targetLoudnessLUFS: targetLoudnessLUFS)
        try AudioFileIO.write(mix, to: outputURL)
    }

    /// Optional integrated-loudness normalization (at most +24 dB), then the brick-wall limiter.
    static func finalize(_ mix: inout PCMAudio, limiterCeilingDB: Double, targetLoudnessLUFS: Double?) {
        if let target = targetLoudnessLUFS, target.isFinite, let measured = LoudnessMeter.integratedLoudness(mix) {
            let gain = Float(pow(10, min(24, target - measured) / 20))
            for channel in mix.channels.indices { vDSP.multiply(gain, mix.channels[channel], result: &mix.channels[channel]) }
        }
        Limiter.process(&mix.channels, ceilingDB: limiterCeilingDB, sampleRate: mix.sampleRate)
    }
}

/// Background music in playback time (a viddeo design choice; Screen Studio only exposes the file,
/// volume and mute): it starts at playback time 0, loops to fill the edited duration, ignores
/// trims and speed ramps (it follows playback time, not source time) and fades out linearly over
/// the last second. Each loop seam gets a 5 ms fade-out/fade-in so the wrap never clicks.
enum BackgroundMusic {
    static let fadeOutSeconds = 1.0
    static let seamSeconds = 0.005

    /// `source` tiled to `frameCount` frames with `gain` applied. Empty when the source is empty.
    static func render(_ source: PCMAudio, frameCount: Int, gain: Float, fadeOutSeconds: Double = fadeOutSeconds) -> PCMAudio {
        let length = source.frameCount
        guard length > 0, frameCount > 0, !source.channels.isEmpty else {
            return PCMAudio(sampleRate: source.sampleRate, channels: source.channels.map { _ in [] })
        }
        let seam = min(Int(seamSeconds * source.sampleRate), length / 2)
        let fade = min(frameCount, max(0, Int(fadeOutSeconds * source.sampleRate)))
        let channels = source.channels.map { input -> [Float] in
            var output = [Float](repeating: 0, count: frameCount)
            for index in 0..<frameCount {
                let position = index % length
                var value = input[position] * gain
                if seam > 0 {
                    // Seam fades only where another loop follows or precedes this one.
                    if index >= length, position < seam { value *= Float(position) / Float(seam) }
                    let remaining = length - position
                    if remaining <= seam, index + remaining < frameCount { value *= Float(remaining) / Float(seam) }
                }
                if fade > 0, index >= frameCount - fade { value *= Float(frameCount - index) / Float(fade) }
                output[index] = value
            }
            return output
        }
        return PCMAudio(sampleRate: source.sampleRate, channels: channels)
    }
}
