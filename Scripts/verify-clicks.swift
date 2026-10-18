import CoreGraphics
import CoreImage
import Foundation

@main
struct VerifyClicks {
    static func main() throws {
        let width = 640, height = 360
        for (p, expected) in [(0.0, 1.28), (0.25, 11.64), (0.5, 16.96), (1.0, 19.2)] {
            let actual = ClickEffectTimeline.radius(progress: p, width: Double(width))
            guard abs(actual - expected) < 0.02 else { throw Failure("radius formula mismatch at progress \(p)") }
        }
        guard ClickEffectTimeline.fade(progress: 0) == 0,
              ClickEffectTimeline.fade(progress: 0.9) == 0,
              ClickEffectTimeline.fade(progress: 1) == 0,
              ClickEffectTimeline.fade(progress: 0.15) > ClickEffectTimeline.fade(progress: 0.3) else {
            throw Failure("fade curve endpoints or peak are incorrect")
        }

        let events = [
            CursorEvent(time: 0.1, x: 0.1, y: 0.1, kind: .down),
            CursorEvent(time: 0.2, x: 0.2, y: 0.2, kind: .down),
            CursorEvent(time: 0.3, x: 0.3, y: 0.3, kind: .down),
            CursorEvent(time: 0.4, x: 0.4, y: 0.4, kind: .down),
            CursorEvent(time: 0.4, x: 0.75, y: 0.75, kind: .up),
            CursorEvent(time: .nan, x: 0.5, y: 0.5, kind: .down),
            CursorEvent(time: 0.4, x: 1.2, y: 0.5, kind: .down)
        ]
        let timeline = ClickEffectTimeline(events: events, duration: 3)
        let blank = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let frame = timeline.image(over: blank, at: 0.5)
        let progress = (0.5 - 0.4) / 0.45
        let radius = ClickEffectTimeline.radius(progress: progress, width: Double(width))
        // Interior over black: sRGB-encoded linear 0.7569 gray × overlay alpha 0.6 × fade.
        let encodedFill = 1.055 * pow(0.7569, 1 / 2.4) - 0.055
        let expectedFill = encodedFill * 0.6 * ClickEffectTimeline.fade(progress: progress)
        let fill = try pixel(frame, x: 0.4, y: 0.4, width: width, height: height)
        guard abs(Double(fill.0) - expectedFill) < 0.02, abs(fill.0 - fill.1) < 0.01 else {
            throw Failure("disc interior is \(fill.0), expected \(expectedFill)")
        }
        // At the radius the 0.5-alpha dark rim and the antialiased edge blend toward black.
        let rim = try pixel(frame, x: 0.4 + (radius - 0.5) / Double(width), y: 0.4,
                            width: width, height: height)
        guard rim.0 > 0.02, Double(rim.0) < 0.6 * expectedFill else {
            throw Failure("rim is \(rim.0), expected darker than the interior \(expectedFill)")
        }
        let outside = try pixel(frame, x: 0.4 + (radius + 4) / Double(width), y: 0.4,
                                width: width, height: height)
        guard outside.0 < 0.005 else { throw Failure("disc appeared outside radius and rim") }
        let oldest = try pixel(frame, x: 0.1, y: 0.1, width: width, height: height)
        guard oldest.0 < 0.005 else { throw Failure("fourth recent click was not limited to three slots") }
        for (x, y) in [(0.2, 0.2), (0.3, 0.3)] {
            let slot = try pixel(frame, x: x, y: y, width: width, height: height)
            // These clicks are 300/200 ms old, still inside 450 ms and the three-slot window.
            let age = 0.5 - (x * 1.0)
            let expected = encodedFill * 0.6 * ClickEffectTimeline.fade(progress: age / 0.45)
            guard abs(Double(slot.0) - expected) < 0.03 else {
                throw Failure("slot at \(x) is \(slot.0), expected \(expected)")
            }
        }
        let up = try pixel(frame, x: 0.75, y: 0.75, width: width, height: height)
        guard up.0 < 0.005 else { throw Failure("up event incorrectly produced an effect") }

        let before = timeline.image(over: blank, at: 0.39)
        let expired = timeline.image(over: blank, at: 0.86)
        guard brightness(try pixel(before, x: 0.4, y: 0.4, width: width, height: height)) < 0.005,
              brightness(try pixel(expired, x: 0.4, y: 0.4, width: width, height: height)) < 0.005 else {
            throw Failure("effect visible before click or after lifetime")
        }
        let repeatFrame = timeline.image(over: blank, at: 0.5)
        let repeatPixel = try pixel(repeatFrame, x: 0.4, y: 0.4, width: width, height: height)
        guard abs(brightness(repeatPixel) - brightness(fill)) < 0.01 else {
            throw Failure("arbitrary seek produced nondeterministic effect")
        }

        let scale = CGFloat(2)
        let crop = CGRect(x: 0, y: 180, width: 320, height: 180)
        let zoomed = frame.cropped(to: crop).transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: -crop.minX * scale, ty: -crop.minY * scale
        ))
        // The click at 256 px, 144 px from the top lands at 512 px, 288 px after the 2× crop.
        let zoomPixel = try pixel(zoomed, x: 0.8, y: 0.8, width: width, height: height)
        guard abs(Double(zoomPixel.0) - expectedFill) < 0.02 else {
            throw Failure("effect did not follow the zoom crop (\(zoomPixel.0))")
        }
        try verifyRippleConfiguration()
        try verifyRippleRendering()
        try verifyRippleMath()
        try verifyNewRecordingDefault(events: events, blank: blank, width: width, height: height)
        print("Ripple verified: config decode/encode/legacy, damped-sine envelope, slot limit, pull scaling, rendered displacement and chromatic split.")
        print("Click effects verified: radius/fade formulas, filled disc and rim, three slots, down-only, filtering, expiry, seek determinism and zoom mapping.")
    }

    /// New recordings start with the reference's `clickEffect: null` (off); sessions without a
    /// click-config.json (legacy) keep the circle, and a saved choice always wins.
    private static func verifyNewRecordingDefault(events: [CursorEvent], blank: CIImage, width: Int, height: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-click-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard try ClickEffectConfiguration.load(in: directory).effect == .circle,
              ClickEffectConfiguration().effect == .circle else { throw Failure("legacy (no sidecar) default is no longer circle") }
        let fresh = ClickEffectConfiguration.newRecordingDefault
        guard fresh.effect == .none, fresh.visibleDuration == 0, (try? fresh.validate()) != nil else {
            throw Failure("new-recording click default is not an off effect")
        }
        try fresh.save(in: directory)
        guard try ClickEffectConfiguration.load(in: directory) == fresh else { throw Failure("off default did not round-trip") }
        var other = ClickEffectConfiguration()
        other.effect = .circle
        let off = ClickEffectTimeline(events: events, duration: 3, configuration: fresh).image(over: blank, at: 0.5)
        let on = ClickEffectTimeline(events: events, duration: 3, configuration: other).image(over: blank, at: 0.5)
        let offPixel = try pixel(off, x: 0.4, y: 0.4, width: width, height: height)
        let onPixel = try pixel(on, x: 0.4, y: 0.4, width: width, height: height)
        guard offPixel.0 < 0.01, offPixel.1 < 0.01, offPixel.2 < 0.01, onPixel.0 > 0.05 else {
            throw Failure("off effect drew a ring (\(offPixel.0)) or circle did not (\(onPixel.0))")
        }
    }

    private static func verifyRippleConfiguration() throws {
        // Legacy files (no effect key) mean circle and keep their values.
        let legacy = Data(#"{"durationMs":450,"maxSlots":2,"lookbackMs":1000}"#.utf8)
        let old = try JSONDecoder().decode(ClickEffectConfiguration.self, from: legacy)
        guard old.effect == .circle, old.pullSize01 == 0.04, old.maxSlots == 2, old.rippleDurationMs == 1000 else {
            throw Failure("legacy click-config.json did not decode as circle with defaults")
        }
        let empty = try JSONDecoder().decode(ClickEffectConfiguration.self, from: Data("{}".utf8))
        guard empty.effect == .circle, ClickEffectConfiguration().effect == .circle, (try? empty.validate()) != nil else {
            throw Failure("empty click configuration is not the circle default")
        }
        var ripple = ClickEffectConfiguration()
        ripple.effect = .ripple
        ripple.pullSize01 = 0.07
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ripple)
        let back = try JSONDecoder().decode(ClickEffectConfiguration.self, from: data)
        guard back == ripple, String(decoding: data, as: UTF8.self).contains(#""effect":"ripple""#) else {
            throw Failure("ripple configuration did not round-trip")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-click-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard try ClickEffectConfiguration.load(in: directory).effect == .circle else {
            throw Failure("missing click-config.json is not the circle default")
        }
        try ripple.save(in: directory)
        guard try ClickEffectConfiguration.load(in: directory) == ripple else { throw Failure("saved ripple did not load back") }
        for mutate in [{ (c: inout ClickEffectConfiguration) in c.pullSize01 = 0.2 },
                       { $0.pullSize01 = -0.01 }, { $0.pullSize01 = .nan }, { $0.rippleDurationMs = 0 },
                       { $0.rippleChromaticSplit = 1 }, { $0.rippleCycles = 0 }] {
            var bad = ClickEffectConfiguration()
            mutate(&bad)
            guard (try? bad.validate()) == nil else { throw Failure("invalid ripple configuration was accepted") }
        }
    }

    private static func verifyRippleMath() throws {
        var config = ClickEffectConfiguration()
        config.effect = .ripple
        guard ClickEffectTimeline.rippleEnvelope(progress: 0, configuration: config) == 0,
              ClickEffectTimeline.rippleEnvelope(progress: 1, configuration: config) == 0,
              ClickEffectTimeline.rippleEnvelope(progress: 1.5, configuration: config) == 0,
              config.rippleDurationMs == 1000, config.visibleDuration == 1,
              (0..<100).contains(where: { abs(ClickEffectTimeline.rippleEnvelope(progress: Double($0) / 100, configuration: config)) > 0.5 }) else {
            throw Failure("ripple envelope endpoints or amplitude are wrong")
        }
        // The envelope changes sign (the pull oscillates) and decays.
        let samples = (1..<100).map { ClickEffectTimeline.rippleEnvelope(progress: Double($0) / 100, configuration: config) }
        guard samples.contains(where: { $0 > 0.1 }), samples.contains(where: { $0 < -0.1 }),
              abs(samples[84]) < abs(samples[9]) else { throw Failure("ripple envelope does not oscillate and decay") }
        // Peak displacement is pullSize01 * width * envelope, so it scales with both.
        func peak(_ pull: Double, _ width: Double) -> Double {
            var c = config
            c.pullSize01 = pull
            let progress = 0.1
            let front = ClickEffectTimeline.rippleFront(progress: progress, width: width, configuration: c)
            return ClickEffectTimeline.rippleDisplacement(distance: front, progress: progress, width: width, configuration: c)
        }
        let base = peak(0.04, 640)
        guard base != 0, abs(peak(0.08, 640) / base - 2) < 1e-9, abs(peak(0.04, 1280) / base - 2) < 1e-9,
              peak(0, 640) == 0,
              abs(base - 0.04 * 640 * ClickEffectTimeline.rippleEnvelope(progress: 0.1, configuration: config)) < 1e-9 else {
            throw Failure("ripple pull does not scale with pullSize01 and width")
        }
        // Slots: four clicks 100 ms apart, only the newest three within 1000 ms are active; a click
        // older than 1000 ms is dropped.
        // Click ages at t = 2.0 are 700, 500, 300 and 100 ms; the envelope is far from a zero crossing there.
        let events = [1.3, 1.5, 1.7, 1.9].enumerated().map {
            CursorEvent(time: $1, x: 0.15 + Double($0) * 0.2, y: 0.5, kind: .down)
        }
        let timeline = ClickEffectTimeline(events: events, duration: 5, configuration: config)
        let source = gradient(width: 640, height: 360)
        let frame = timeline.image(over: source, at: 2.0)
        let plain = timeline.image(over: source, at: 1.3)
        func moved(_ image: CIImage, atX x: Double) throws -> Bool {
            let a = try row(image, y: 180, from: Int(x * 640) - 8, to: Int(x * 640) + 8)
            let b = try row(source, y: 180, from: Int(x * 640) - 8, to: Int(x * 640) + 8)
            return zip(a, b).contains { abs(Int($0) - Int($1)) > 2 }
        }
        guard try !moved(plain, atX: 0.15) else { throw Failure("ripple moved pixels at the instant of the click") }
        // Probe each retained ring front, not its click center. The sampled points are outside the
        // spatial support of the older, dropped ring, which can overlap the other rings near center.
        let m35 = try moved(frame, atX: 0.425), m55 = try moved(frame, atX: 0.595)
        let m75 = try (moved(frame, atX: 0.765) || moved(frame, atX: 0.735))
        let retained = ClickEffectTimeline(events: Array(events.dropFirst()), duration: 5, configuration: config)
            .image(over: source, at: 2.0)
        let droppedRegion = try row(frame, y: 180, from: 18, to: 40)
        let retainedRegion = try row(retained, y: 180, from: 18, to: 40)
        guard m35, m55, m75, droppedRegion == retainedRegion else {
            throw Failure("ripple slots are not the newest three (retained fronts: \(m35), \(m55), \(m75))")
        }
        let late = timeline.image(over: source, at: 3.0)
        let l = try [0.15, 0.35, 0.55, 0.75].map { try moved(late, atX: $0) }
        guard !l.contains(true) else {
            throw Failure("ripple still active after 1000 ms")
        }
        var off = config
        off.effect = .none
        let none = ClickEffectTimeline(events: events, duration: 5, configuration: off)
            .image(over: source, at: 2.0)
        guard try !moved(none, atX: 0.425) else { throw Failure("effect none changed pixels") }
    }

    /// Horizontal gradient: the green value encodes x, so a sampling offset shows up as a value change.
    private static func gradient(width: Int, height: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let v = UInt8(40 + Double(x) / Double(width) * 170)
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: nil)
    }

    private static func row(_ image: CIImage, y: Int, from: Int, to: Int) throws -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(image, from: image.extent), let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { throw Failure("could not render test image") }
        return (from..<to).flatMap { x -> [UInt8] in
            let o = y * cg.bytesPerRow + x * 4
            return [bytes[o], bytes[o + 1], bytes[o + 2]]
        }
    }

    /// The rendered displacement matches the model: on a gradient the green sampling offset at the ring
    /// front equals the formula, red and blue are pulled 1 ± split times as far, and it scales with pullSize01.
    private static func verifyRippleRendering() throws {
        let width = 640, height = 360
        let source = gradient(width: width, height: height)
        let progress = 0.1
        func measure(pull: Double) throws -> (r: Double, g: Double, b: Double, expected: Double) {
            var config = ClickEffectConfiguration()
            config.effect = .ripple
            config.pullSize01 = pull
            let timeline = ClickEffectTimeline(events: [CursorEvent(time: 1, x: 0.5, y: 0.5, kind: .down)],
                                               duration: 5, configuration: config)
            let frame = timeline.image(over: source, at: 1 + progress)
            let front = ClickEffectTimeline.rippleFront(progress: progress, width: Double(width), configuration: config)
            let expected = ClickEffectTimeline.rippleDisplacement(distance: front, progress: progress,
                                                                  width: Double(width), configuration: config)
            let x = 320 + Int(front.rounded())
            let rendered = try row(frame, y: 180, from: x, to: x + 1)
            let original = try row(source, y: 180, from: x, to: x + 1)
            // 170 gray levels span the width: one level is width / 170 pixels of sampling offset.
            let perLevel = Double(width) / 170
            return (Double(Int(rendered[0]) - Int(original[0])) * perLevel,
                    Double(Int(rendered[1]) - Int(original[1])) * perLevel,
                    Double(Int(rendered[2]) - Int(original[2])) * perLevel, expected)
        }
        let a = try measure(pull: 0.04)
        guard a.expected > 10, abs(a.g - a.expected) < 4 else {
            throw Failure("rendered green offset \(a.g) px, expected \(a.expected) px")
        }
        guard a.r > a.g + 2, a.b < a.g - 2, abs(a.r / a.g - 1.35) < 0.25, abs(a.b / a.g - 0.65) < 0.25 else {
            throw Failure("chromatic split is wrong: r \(a.r), g \(a.g), b \(a.b)")
        }
        let b = try measure(pull: 0.02)
        guard abs(b.g * 2 - a.g) < 5 else { throw Failure("rendered pull does not scale with pullSize01 (\(b.g) vs \(a.g))") }
    }

    private static func pixel(_ image: CIImage, x: Double, y: Double,
                              width: Int, height: Int) throws -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(image, from: image.extent),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { throw Failure("could not render test image") }
        let px = min(width - 1, max(0, Int(x * Double(width))))
        let py = min(height - 1, max(0, Int(y * Double(height))))
        let offset = py * cg.bytesPerRow + px * 4
        return (CGFloat(bytes[offset]) / 255, CGFloat(bytes[offset + 1]) / 255,
                CGFloat(bytes[offset + 2]) / 255, CGFloat(bytes[offset + 3]) / 255)
    }

    private static func brightness(_ value: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGFloat {
        max(value.0, max(value.1, value.2))
    }
}

private enum Failure: LocalizedError {
    case failed(String)
    init(_ message: String) { self = .failed(message) }
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}
