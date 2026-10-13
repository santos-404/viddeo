import Foundation
import Synchronization

@main
struct VerifyAudioProcessing {
    static let rate = 48_000.0

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = Checks()
        try testConfiguration(&checks, directory)
        try await testVoicePreset(&checks, directory)
        try await testNoiseReduction(&checks, directory)
        try await testPodcastAndDeterminism(&checks, directory)
        try testMixdownMath(&checks)
        try testSegmentGains(&checks)
        try await testRenderAndLimiter(&checks, directory)
        try await testClickSounds(&checks, directory)
        print("Audio processing verified: \(checks.count) checks")
    }

    // MARK: Configuration

    private static func testConfiguration(_ checks: inout Checks, _ directory: URL) throws {
        let defaults = AudioMixConfiguration()
        try checks.expect(defaults.volume == 1 && !defaults.muteMicrophone && !defaults.muteSystemAudio,
                          "default master volume 1 and no source mutes")
        try checks.expect(defaults.microphonePreset == .voice, "default microphone preset is voice")
        try checks.expect(defaults.backgroundAudioFileName == nil && defaults.backgroundAudioVolume == 0.05
                          && !defaults.muteBackgroundAudio, "default background audio is off at 0.05")
        try checks.expect(defaults.clickSoundEffect == nil && defaults.clickSoundEffectVolume == 0.25,
                          "default click sound is off at 0.25")
        try checks.expect(defaults.limiterCeilingDB == -1 && defaults.targetLoudnessLUFS == nil,
                          "default limiter −1 dBFS and loudness normalization off")
        try checks.expect(MicrophonePreset.noiseReduction.rawValue == "noise-reduction",
                          "noise reduction keeps the observed JSON name")

        let partial = try JSONDecoder().decode(AudioMixConfiguration.self,
                                               from: Data(#"{"microphonePreset":"noise-reduction","volume":0.5}"#.utf8))
        try checks.expect(partial.microphonePreset == .noiseReduction && partial.volume == 0.5
                          && partial.backgroundAudioVolume == 0.05, "partial JSON fills defaults")

        var custom = AudioMixConfiguration()
        custom.muteSystemAudio = true
        custom.microphonePreset = .podcast
        custom.backgroundAudioFileName = "music.m4a"
        custom.clickSoundEffect = .crispClick
        custom.targetLoudnessLUFS = -16
        let decoded = try JSONDecoder().decode(AudioMixConfiguration.self, from: JSONEncoder().encode(custom))
        try checks.expect(decoded == custom, "JSON round trip preserves every field")

        try checks.expect(try AudioMixConfiguration.load(in: directory) == defaults, "missing file loads defaults")
        try custom.save(in: directory)
        try checks.expect(try AudioMixConfiguration.load(in: directory) == custom, "save/load round trip")

        try Data(#"{"microphonePreset":"studio"}"#.utf8).write(to: directory.appendingPathComponent("audio-config.json"))
        try checks.expect((try? AudioMixConfiguration.load(in: directory)) == nil, "unknown preset is rejected")
        try Data(#"{"backgroundAudioFileName":"../../secret.m4a"}"#.utf8)
            .write(to: directory.appendingPathComponent("audio-config.json"))
        try checks.expect((try? AudioMixConfiguration.load(in: directory)) == nil, "persisted traversal name is rejected")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("audio-config.json"))

        func invalid(_ change: (inout AudioMixConfiguration) -> Void) -> Bool {
            var config = AudioMixConfiguration()
            change(&config)
            return (try? config.validate()) == nil
        }
        try checks.expect(invalid { $0.volume = -0.1 } && invalid { $0.volume = .nan }
                          && invalid { $0.backgroundAudioVolume = .infinity }, "invalid volumes are rejected")
        try checks.expect(invalid { $0.limiterCeilingDB = 0.5 } && invalid { $0.limiterCeilingDB = -40 },
                          "limiter ceiling outside −20…0 dBFS is rejected")
        try checks.expect(invalid { $0.targetLoudnessLUFS = 0 } && invalid { $0.targetLoudnessLUFS = .nan }
                          && !invalid { $0.targetLoudnessLUFS = -14 }, "loudness target range")
        let rejected = ["../music.m4a", "/etc/passwd", "a/b.mp3", "..", ".", "", ".hidden.m4a", "a\\b.wav",
                        "c:d.wav", "~music.m4a", "bad\nname.m4a"]
        try checks.expect(rejected.allSatisfy { name in invalid { $0.backgroundAudioFileName = name } },
                          "background file names with traversal, separators or absolute paths are rejected")
        var named = AudioMixConfiguration()
        named.backgroundAudioFileName = "Calm Loop (1).m4a"
        try named.validate()
        try checks.expect(named.backgroundAudioURL(in: directory)?.deletingLastPathComponent().standardizedFileURL
                          == directory.standardizedFileURL, "a simple background name resolves inside the session")
    }

    // MARK: Voice cleanup

    private static func testVoicePreset(_ checks: inout Checks, _ directory: URL) async throws {
        let rumble = directory.appendingPathComponent("rumble.caf"), rumbleOut = directory.appendingPathComponent("rumble-voice.caf")
        let tone = directory.appendingPathComponent("tone.caf"), toneOut = directory.appendingPathComponent("tone-voice.caf")
        try AudioFileIO.write(PCMAudio(sampleRate: rate, channels: [sine(30, 0.1, 3)]), to: rumble)
        try AudioFileIO.write(PCMAudio(sampleRate: rate, channels: [sine(1_000, 0.1, 3)]), to: tone)
        try await VoiceCleanup.process(inputURL: rumble, outputURL: rumbleOut, preset: .voice)
        try await VoiceCleanup.process(inputURL: tone, outputURL: toneOut, preset: .voice)
        let rumbleIn = try await AudioFileIO.read(rumble), rumbleProcessed = try await AudioFileIO.read(rumbleOut)
        let toneIn = try await AudioFileIO.read(tone), toneProcessed = try await AudioFileIO.read(toneOut)
        let rumbleDrop = db(rms(rumbleIn.channels[0], 1, 2.5) / rms(rumbleProcessed.channels[0], 1, 2.5))
        let toneChange = db(rms(toneProcessed.channels[0], 1, 2.5) / rms(toneIn.channels[0], 1, 2.5))
        print(String(format: "voice: 30 Hz rumble attenuated %.1f dB, 1 kHz tone changed %+.2f dB", rumbleDrop, toneChange))
        try checks.expect(rumbleDrop >= 12, "voice preset attenuates 30 Hz rumble by ≥ 12 dB")
        try checks.expect(abs(toneChange) <= 1.5, "voice preset passes 1 kHz within ±1.5 dB")
        try checks.expect(toneProcessed.frameCount == toneIn.frameCount && rumbleProcessed.frameCount == rumbleIn.frameCount,
                          "voice preset preserves the sample count")
        try checks.expect(toneProcessed.channels.count == 1 && toneProcessed.sampleRate == rate,
                          "mono input stays mono at 48 kHz")

        let offOut = directory.appendingPathComponent("tone-off.caf")
        try await VoiceCleanup.process(inputURL: tone, outputURL: offOut, preset: .off)
        let off = try await AudioFileIO.read(offOut)
        try checks.expect(off.channels == toneIn.channels, "off preset is a bit-exact passthrough")
    }

    private static func noisyTone(seed: UInt32, toneAmplitude: Float = 0.1, noiseRMS: Float = 0.02) -> [Float] {
        // 4 s: noise throughout, a 440 Hz tone from 1.0 s to 3.5 s (speech pauses provide the noise profile).
        var state = seed
        let tone = sine(440, Double(toneAmplitude), 4)
        return (0..<Int(4 * rate)).map { index in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let white = Float(Double(state) / Double(UInt32.max) * 2 - 1) * noiseRMS * Float(3).squareRoot()
            let time = Double(index) / rate
            return white + (time >= 1 && time < 3.5 ? tone[index] : 0)
        }
    }

    private static func testNoiseReduction(_ checks: inout Checks, _ directory: URL) async throws {
        let input = directory.appendingPathComponent("noisy.caf"), output = directory.appendingPathComponent("noisy-nr.caf")
        try AudioFileIO.write(PCMAudio(sampleRate: rate, channels: [noisyTone(seed: 0x1234_5678)]), to: input)
        try await VoiceCleanup.process(inputURL: input, outputURL: output, preset: .noiseReduction)
        let before = try await AudioFileIO.read(input), after = try await AudioFileIO.read(output)
        let inFit = toneFit(before.channels[0], 440), outFit = toneFit(after.channels[0], 440)
        let improvement = outFit.snr - inFit.snr
        let toneLoss = db(outFit.amplitude / inFit.amplitude)
        let pauseDrop = db(rms(before.channels[0], 0.2, 0.9) / rms(after.channels[0], 0.2, 0.9))
        print(String(format: "noise-reduction: SNR %.1f → %.1f dB (+%.1f dB), tone %+.2f dB, noise-only pause −%.1f dB",
                     inFit.snr, outFit.snr, improvement, toneLoss, pauseDrop))
        try checks.expect(improvement >= 6, "noise reduction improves SNR by ≥ 6 dB")
        try checks.expect(toneLoss >= -3, "noise reduction keeps the tone within 3 dB")
        try checks.expect(after.frameCount == before.frameCount, "noise reduction preserves the sample count")

        let reconstructed = SpectralNoiseReducer.process(sine(440, 0.1, 1), sampleRate: rate, oversubtraction: 0,
                                                         spectralFloor: 1)
        let error = zip(reconstructed, sine(440, 0.1, 1)).map { abs($0 - $1) }.max() ?? 1
        try checks.expect(error < 1e-5, "STFT overlap-add reconstructs exactly at unity gain")

        let stereoIn = PCMAudio(sampleRate: rate, channels: [noisyTone(seed: 7), noisyTone(seed: 11)])
        let stereoOut = try VoiceCleanup.process(stereoIn, preset: .noiseReduction)
        try checks.expect(stereoOut.channels.count == 2 && stereoOut.frameCount == stereoIn.frameCount,
                          "stereo input stays stereo with equal sample count")
    }

    private static func testPodcastAndDeterminism(_ checks: inout Checks, _ directory: URL) async throws {
        let input = directory.appendingPathComponent("loud.wav")
        try AudioFileIO.write(PCMAudio(sampleRate: rate, channels: [noisyTone(seed: 99, toneAmplitude: 0.9, noiseRMS: 0.05)]),
                              to: input)
        let first = directory.appendingPathComponent("podcast-1.caf"), second = directory.appendingPathComponent("podcast-2.caf")
        let progress = ProgressLog()
        try await VoiceCleanup.process(inputURL: input, outputURL: first, preset: .podcast) { progress.record($0) }
        try await VoiceCleanup.process(inputURL: input, outputURL: second, preset: .podcast)
        let output = try await AudioFileIO.read(first), source = try await AudioFileIO.read(input)
        let peak = output.channels[0].map(abs).max() ?? 1
        print(String(format: "podcast: output peak %.2f dBFS (ceiling −1)", db(Double(peak))))
        try checks.expect(Double(peak) <= pow(10, -1.0 / 20), "podcast output peak stays under the limiter ceiling")
        try checks.expect(output.frameCount == source.frameCount, "podcast preserves the WAV input sample count")
        try checks.expect(try Data(contentsOf: first) == Data(contentsOf: second), "podcast output is byte-identical across runs")
        let values = progress.values
        try checks.expect(values.first == 0 && values.last == 1 && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 },
                          "progress runs monotonically from 0 to 1")

        let nr1 = directory.appendingPathComponent("nr-1.caf"), nr2 = directory.appendingPathComponent("nr-2.caf")
        try await VoiceCleanup.process(inputURL: input, outputURL: nr1, preset: .noiseReduction)
        try await VoiceCleanup.process(inputURL: input, outputURL: nr2, preset: .noiseReduction)
        try checks.expect(try Data(contentsOf: nr1) == Data(contentsOf: nr2), "noise reduction is byte-identical across runs")

        var lowCeiling = try VoiceCleanup.process(source, preset: .podcast, limiterCeilingDB: -6)
        let lowPeak = lowCeiling.channels[0].map(abs).max() ?? 1
        try checks.expect(Double(lowPeak) <= pow(10, -6.0 / 20), "podcast honours a custom −6 dBFS ceiling")
        lowCeiling.channels = []
        try checks.expect((try? AudioFileIO.write(lowCeiling, to: directory.appendingPathComponent("empty.caf"))) == nil,
                          "writing audio without channels fails")
    }

    // MARK: Mixing

    private static func testMixdownMath(_ checks: inout Checks) throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let tracks = [MixTrack(url: url, gain: 1, startOffset: 0, kind: .microphone),
                      MixTrack(url: url, gain: 0.5, startOffset: 0, kind: .systemAudio),
                      MixTrack(url: url, gain: 1, startOffset: 0, kind: .backgroundAudio),
                      MixTrack(url: url, gain: 1, startOffset: 0, kind: .clickSounds)]
        var plan = AudioMixConfiguration()
        var mixed = AudioMixer.mixdown(tracks: tracks, plan: plan)
        try checks.expect(mixed.map(\.kind) == [.microphone, .systemAudio, .backgroundAudio]
                          && mixed.map(\.gain) == [1, 0.5, 0.05], "default plan: unity sources, 0.05 music, no clicks")
        plan.clickSoundEffect = .softClick
        plan.volume = 0.5
        mixed = AudioMixer.mixdown(tracks: tracks, plan: plan)
        try checks.expect(mixed.map(\.gain) == [0.5, 0.25, 0.025, 0.125], "master volume scales every source incl. clicks")
        plan.muteMicrophone = true
        plan.muteBackgroundAudio = true
        mixed = AudioMixer.mixdown(tracks: tracks, plan: plan)
        try checks.expect(mixed.map(\.kind) == [.systemAudio, .clickSounds], "muted sources are dropped")
        plan.muteSystemAudio = true
        plan.volume = 0
        try checks.expect(AudioMixer.mixdown(tracks: tracks, plan: plan).isEmpty, "zero master volume drops everything")
    }

    private static func testSegmentGains(_ checks: inout Checks) throws {
        let gains = AudioMixer.perSegmentGains([(start: 1, end: 2, gain: 0)], frameCount: Int(3 * rate))
        try checks.expect(gains.count == Int(3 * rate), "envelope has one gain per frame")
        try checks.expect(gains[Int(0.994 * rate)] == 1 && gains[Int(1.006 * rate)] == 0
                          && gains[Int(1.994 * rate)] == 0 && gains[Int(2.006 * rate)] == 1,
                          "gains are exact outside the 10 ms crossfades")
        let fadeOut = Array(gains[Int(0.99 * rate)..<Int(1.01 * rate)]), fadeIn = Array(gains[Int(1.99 * rate)..<Int(2.01 * rate)])
        try checks.expect(zip(fadeOut, fadeOut.dropFirst()).allSatisfy { $0 >= $1 }
                          && zip(fadeIn, fadeIn.dropFirst()).allSatisfy { $0 <= $1 }, "crossfades are monotonic")
        let rampSamples = fadeOut.filter { $0 > 0 && $0 < 1 }.count
        try checks.expect(abs(rampSamples - Int(0.01 * rate)) <= 2 && abs(gains[Int(rate)] - 0.5) < 0.01,
                          "crossfade lasts 10 ms centred on the boundary")
        let short = AudioMixer.perSegmentGains([(start: 0.5, end: 0.502, gain: 2)], frameCount: Int(rate))
        try checks.expect(short.allSatisfy { $0 >= 1 && $0 <= 2 }, "short segments stay within the segment gains")
        let overlap = AudioMixer.perSegmentGains([(start: 0, end: 1, gain: 0.2), (start: 0.5, end: 1, gain: 0.8)],
                                                 frameCount: Int(rate))
        try checks.expect(overlap[Int(0.25 * rate)] == 0.2 && overlap[Int(0.75 * rate)] == 0.8, "later segments win")
    }

    private static func testRenderAndLimiter(_ checks: inout Checks, _ directory: URL) async throws {
        let loud = directory.appendingPathComponent("loud-tone.caf"), mixURL = directory.appendingPathComponent("mix.caf")
        try AudioFileIO.write(PCMAudio(sampleRate: rate, channels: [sine(1_000, 0.9, 2)]), to: loud)
        try await AudioMixer.render(tracks: [MixTrack(url: loud, gain: 4, startOffset: 0.5, kind: .systemAudio)],
                                    outputURL: mixURL, duration: 3)
        let mix = try await AudioFileIO.read(mixURL)
        let peak = mix.channels.flatMap { $0 }.map(abs).max() ?? 1
        print(String(format: "limiter: +12 dB input (≈ +10 dBFS) → peak %.2f dBFS", db(Double(peak))))
        try checks.expect(Double(peak) <= pow(10, -1.0 / 20), "limiter never exceeds the ceiling with +12 dB input")
        try checks.expect(Double(peak) >= pow(10, -2.0 / 20), "limited mix stays within 1 dB of the ceiling")
        try checks.expect(mix.channels.count == 2 && mix.sampleRate == rate && mix.frameCount == Int(3 * rate),
                          "render produces 48 kHz stereo of the requested duration")
        try checks.expect(mix.channels[0][..<Int(0.5 * rate)].allSatisfy { $0 == 0 } && mix.channels[0] == mix.channels[1],
                          "start offset leaves leading silence and mono feeds both channels")

        let quiet = directory.appendingPathComponent("quiet.caf")
        let tone = sine(1_000, 0.1, 3)
        try AudioFileIO.write(PCMAudio(sampleRate: rate, channels: [tone, tone]), to: quiet)
        let measured = LoudnessMeter.integratedLoudness(PCMAudio(sampleRate: rate, channels: [tone, tone])) ?? 0
        try checks.expect(abs(measured - -20) < 0.3, "BS.1770: −20 dBFS stereo 1 kHz sine reads ≈ −20 LUFS")
        let normalized = directory.appendingPathComponent("normalized.caf")
        try await AudioMixer.render(tracks: [MixTrack(url: quiet, gain: 1, startOffset: 0, kind: .microphone)],
                                    outputURL: normalized, targetLoudnessLUFS: -16)
        let normalizedLoudness = LoudnessMeter.integratedLoudness(try await AudioFileIO.read(normalized)) ?? 0
        print(String(format: "loudness: input %.2f LUFS → normalized %.2f LUFS (target −16)", measured, normalizedLoudness))
        try checks.expect(abs(normalizedLoudness - -16) < 0.5, "loudness normalization reaches the target")

        let ducked = directory.appendingPathComponent("ducked.caf")
        var track = MixTrack(url: quiet, gain: 1, startOffset: 0, kind: .microphone)
        track.segments = [(start: 1, end: 2, gain: 0)]
        try await AudioMixer.render(tracks: [track], outputURL: ducked)
        let duckedAudio = try await AudioFileIO.read(ducked)
        try checks.expect(rms(duckedAudio.channels[0], 1.1, 1.9) == 0 && rms(duckedAudio.channels[0], 2.1, 2.9) > 0.05,
                          "segment gains silence and restore a track")
    }

    // MARK: Click sounds

    private static func testClickSounds(_ checks: inout Checks, _ directory: URL) async throws {
        for set in ClickSoundSet.allCases {
            for sound in ClickSounds.Sound.allCases {
                let samples = ClickSounds.samples(sound, set: set)
                try checks.expect((samples.map(abs).max() ?? 0) > 0.1 && samples.count < Int(0.1 * rate)
                                  && samples == ClickSounds.samples(sound, set: set),
                                  "\(set.rawValue) \(sound) is short, audible and deterministic")
            }
        }
        try checks.expect(ClickSounds.samples(.down, set: .softClick) != ClickSounds.samples(.down, set: .crispClick)
                          && ClickSounds.samples(.up, set: .softClick) != ClickSounds.samples(.up, set: .crispClick),
                          "the two sets differ")
        let events = [CursorEvent(time: 0.3, x: 0.5, y: 0.5, kind: .move),
                      CursorEvent(time: 0.5, x: 0.5, y: 0.5, kind: .down),
                      CursorEvent(time: 1.0, x: 0.5, y: 0.5, kind: .up),
                      CursorEvent(time: 1.5, x: 0.5, y: 0.5, kind: .down),
                      CursorEvent(time: 1.52, x: 0.5, y: 0.5, kind: .up),
                      CursorEvent(time: 5, x: 0.5, y: 0.5, kind: .down),
                      CursorEvent(time: .nan, x: 0.5, y: 0.5, kind: .down)]
        let track = ClickSounds.render(events: events, set: .softClick, volume: 1, duration: 2)
        try checks.expect(track.count == Int(2 * rate) && track == ClickSounds.render(events: events, set: .softClick,
                                                                                      volume: 1, duration: 2),
                          "click track has the requested length and is deterministic")
        try checks.expect(rms(track, 0.5, 0.52) > 0.02 && rms(track, 1.0, 1.02) > 0.02 && rms(track, 1.5, 1.52) > 0.02,
                          "energy at press and release times")
        try checks.expect(rms(track, 0, 0.5) == 0 && rms(track, 0.6, 1.0) == 0 && rms(track, 1.1, 1.5) == 0
                          && rms(track, 1.65, 2) == 0, "silence away from events (moves and out-of-range ignored)")
        let click = ClickSounds.samples(.click, set: .softClick), start = Int(1.5 * rate)
        try checks.expect(Array(track[start..<(start + click.count)]) == click, "a quick press+release plays one click sample")
        let half = ClickSounds.render(events: events, set: .softClick, volume: 0.5, duration: 2)
        try checks.expect(zip(half, track).allSatisfy { $0 == $1 * 0.5 }, "volume scales the track linearly")
        try checks.expect(ClickSounds.render(events: events, set: .crispClick, volume: 1, duration: 2) != track,
                          "sets render differently")
        let url = directory.appendingPathComponent("clicks.caf")
        try ClickSounds.write(track, to: url)
        let written = try await AudioFileIO.read(url)
        try checks.expect(written.channels.count == 1 && written.frameCount == track.count, "click track writes as mono 48 kHz")
    }

    // MARK: Helpers

    private static func sine(_ frequency: Double, _ amplitude: Double, _ seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private static func rms(_ samples: [Float], _ start: Double, _ end: Double) -> Double {
        let slice = samples[Int(start * rate)..<Int(end * rate)]
        return (slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
    }

    private static func db(_ ratio: Double) -> Double { 20 * log10(ratio) }

    /// Least-squares fit of the known tone over 1.5–3.0 s (660 whole cycles of 440 Hz).
    private static func toneFit(_ samples: [Float], _ frequency: Double) -> (amplitude: Double, snr: Double) {
        let range = Int(1.5 * rate)..<Int(3 * rate)
        var a = 0.0, b = 0.0
        for index in range {
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            a += Double(samples[index]) * sin(phase); b += Double(samples[index]) * cos(phase)
        }
        a *= 2 / Double(range.count); b *= 2 / Double(range.count)
        var residual = 0.0
        for index in range {
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            let error = Double(samples[index]) - a * sin(phase) - b * cos(phase)
            residual += error * error
        }
        let tonePower = (a * a + b * b) / 2
        return ((a * a + b * b).squareRoot(), 10 * log10(tonePower / (residual / Double(range.count))))
    }
}

struct Checks {
    private(set) var count = 0
    mutating func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationError.failed(message) }
        count += 1
    }
}

final class ProgressLog: Sendable {
    private let recorded = Mutex<[Double]>([])
    func record(_ value: Double) { recorded.withLock { $0.append(value) } }
    var values: [Double] { recorded.withLock { $0 } }
}

enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
