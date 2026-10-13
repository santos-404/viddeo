import Foundation

/// viddeo's own synthesized click sets. Screen Studio bundles recorded `down`/`up`/`click` samples
/// of two real mice; those assets are not copied — these are generated from code.
enum ClickSoundSet: String, Codable, Sendable, CaseIterable {
    case softClick
    case crispClick
}

/// Deterministic procedural click one-shots (48 kHz mono): a short enveloped noise transient plus a
/// damped sine "body", mixed at cursor event times like the original's positional click audio.
enum ClickSounds {
    enum Sound: CaseIterable, Sendable { case down, up, click }

    static let sampleRate = 48_000.0
    /// A press and release closer than this play as one combined `click` sample.
    static let clickMergeWindow = 0.05

    private struct Voice {
        var bodyFrequency: Double
        var bodyDecay: Double
        var noiseDecay: Double
        var brightness: Double
        var length: Double
        var peak: Float
        var seed: UInt32
    }

    private static func voice(_ sound: Sound, set: ClickSoundSet) -> Voice {
        switch (set, sound) {
        case (.softClick, .up): Voice(bodyFrequency: 1_900, bodyDecay: 0.006, noiseDecay: 0.0020, brightness: 0.3,
                                      length: 0.030, peak: 0.30, seed: 0x5EED_0002)
        case (.softClick, _): Voice(bodyFrequency: 1_400, bodyDecay: 0.009, noiseDecay: 0.0025, brightness: 0.3,
                                    length: 0.040, peak: 0.50, seed: 0x5EED_0001)
        case (.crispClick, .up): Voice(bodyFrequency: 3_800, bodyDecay: 0.003, noiseDecay: 0.0010, brightness: 0.9,
                                       length: 0.020, peak: 0.35, seed: 0xC815_0002)
        case (.crispClick, _): Voice(bodyFrequency: 3_000, bodyDecay: 0.004, noiseDecay: 0.0012, brightness: 0.9,
                                     length: 0.025, peak: 0.55, seed: 0xC815_0001)
        }
    }

    /// The release of a combined `click` starts this long after its press.
    private static func clickRelease(_ set: ClickSoundSet) -> Double { set == .softClick ? 0.045 : 0.035 }

    static func samples(_ sound: Sound, set: ClickSoundSet) -> [Float] {
        guard sound == .click else { return synthesize(voice(sound, set: set)) }
        let down = synthesize(voice(.down, set: set)), up = synthesize(voice(.up, set: set))
        let offset = Int((clickRelease(set) * sampleRate).rounded())
        var combined = [Float](repeating: 0, count: max(down.count, offset + up.count))
        for index in down.indices { combined[index] += down[index] }
        for index in up.indices { combined[offset + index] += up[index] }
        return combined
    }

    private static func synthesize(_ voice: Voice) -> [Float] {
        let count = Int((voice.length * sampleRate).rounded())
        let attack = 12, release = Int(0.002 * sampleRate)
        var state = voice.seed, filtered = 0.0, previous = 0.0
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            // xorshift32: fixed seed per voice, so every render is bit-identical.
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let white = Double(state) / Double(UInt32.max) * 2 - 1
            // Bright sets differentiate the noise (high-pass); soft sets low-pass it.
            filtered = voice.brightness * (white - previous) + (1 - voice.brightness) * (0.6 * filtered + 0.4 * white)
            previous = white
            let t = Double(index) / sampleRate
            let body = sin(2 * Double.pi * voice.bodyFrequency * t) * exp(-t / voice.bodyDecay)
            let transient = filtered * exp(-t / voice.noiseDecay)
            let fadeIn = min(1, Double(index) / Double(attack))
            let fadeOut = min(1, Double(count - 1 - index) / Double(release))
            output[index] = Float((0.6 * body + 0.8 * transient) * fadeIn * fadeOut)
        }
        let peak = output.map(abs).max() ?? 0
        guard peak > 0 else { return output }
        let scale = voice.peak / peak
        return output.map { $0 * scale }
    }

    /// Mono 48 kHz track of `duration` seconds with a `down` sample at each press and an `up` at each
    /// release (a press quickly followed by its release plays one `click`). Moves are ignored.
    static func render(events: [CursorEvent], set: ClickSoundSet, volume: Double, duration: Double) -> [Float] {
        guard duration.isFinite, duration > 0 else { return [] }
        var output = [Float](repeating: 0, count: Int((min(duration, 12 * 60 * 60) * sampleRate).rounded()))
        let gain = Float(volume.isFinite ? min(4, max(0, volume)) : 0)
        guard gain > 0 else { return output }
        let presses = events.enumerated()
            .filter { $0.element.kind != .move && $0.element.time.isFinite && $0.element.time >= 0 && $0.element.time < duration }
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        let down = samples(.down, set: set), up = samples(.up, set: set), click = samples(.click, set: set)
        func place(_ sample: [Float], at time: Double) {
            let start = Int((time * sampleRate).rounded())
            for index in sample.indices where start + index < output.count { output[start + index] += sample[index] * gain }
        }
        var index = 0
        while index < presses.count {
            let event = presses[index]
            if event.kind == .down, index + 1 < presses.count, presses[index + 1].kind == .up,
               presses[index + 1].time - event.time < clickMergeWindow {
                place(click, at: event.time)
                index += 2
                continue
            }
            place(event.kind == .down ? down : up, at: event.time)
            index += 1
        }
        return output.map { min(1, max(-1, $0)) }
    }

    /// Writes a rendered click track as 48 kHz mono 16-bit PCM (CAF or WAV by extension).
    static func write(_ samples: [Float], to url: URL) throws {
        try AudioFileIO.write(PCMAudio(sampleRate: sampleRate, channels: [samples]), to: url)
    }
}
