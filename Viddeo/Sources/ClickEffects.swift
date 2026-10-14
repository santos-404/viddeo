import CoreGraphics
import CoreImage
import Foundation

/// Which effect a click produces. `none` is viddeo's spelling of the observed `null` (off). Files
/// written before the ripple existed have no `effect` key and decode as `circle`.
enum ClickEffectType: String, Codable, Sendable, CaseIterable {
    case none, circle, ripple
}

struct ClickEffectConfiguration: Codable, Sendable, Equatable {
    var effect = ClickEffectType.circle
    /// Observed: ripple pull size as a fraction of video width, default 0.04. Editor range 0...0.1.
    var pullSize01 = 0.04
    // Viddeo design choices for the ripple (the observed facts are only the 1000 ms lifetime and
    // pullSize01); all tunable in click-config.json.
    /// Observed lifetime of the ripple.
    var rippleDurationMs = 1000.0
    /// Where the ring stops, as a fraction of video width. The front moves at a constant
    /// `rippleReachFraction * width / duration` pixels per second.
    var rippleReachFraction = 0.15
    /// Gaussian half-width of the displaced ring band, as a fraction of video width.
    var rippleBandFraction = 0.02
    /// Sine cycles over the lifetime.
    var rippleCycles = 2.5
    /// Exponential damping rate over the lifetime (`exp(-damping * progress)`).
    var rippleDamping = 2.5
    /// Red and blue are displaced by `1 + split` and `1 - split` times the green pull.
    var rippleChromaticSplit = 0.35

    var durationMs = 450.0
    var minRadiusFraction = 0.002
    var maxRadiusFraction = 0.03
    var fillGrayLinear = 0.7569
    var rimGrayLinear = 0.0
    var rimWidthFraction = 0.0007
    var rimAlpha = 0.5
    var overlayAlpha = 0.6
    var fadeInEnd = 0.15
    var fadeOutEnd = 0.9
    var maxSlots = 3
    var lookbackMs = 1000.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        effect = try c.decodeIfPresent(ClickEffectType.self, forKey: .effect) ?? d.effect
        pullSize01 = try c.decodeIfPresent(Double.self, forKey: .pullSize01) ?? d.pullSize01
        rippleDurationMs = try c.decodeIfPresent(Double.self, forKey: .rippleDurationMs) ?? d.rippleDurationMs
        rippleReachFraction = try c.decodeIfPresent(Double.self, forKey: .rippleReachFraction) ?? d.rippleReachFraction
        rippleBandFraction = try c.decodeIfPresent(Double.self, forKey: .rippleBandFraction) ?? d.rippleBandFraction
        rippleCycles = try c.decodeIfPresent(Double.self, forKey: .rippleCycles) ?? d.rippleCycles
        rippleDamping = try c.decodeIfPresent(Double.self, forKey: .rippleDamping) ?? d.rippleDamping
        rippleChromaticSplit = try c.decodeIfPresent(Double.self, forKey: .rippleChromaticSplit) ?? d.rippleChromaticSplit
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? d.durationMs
        minRadiusFraction = try c.decodeIfPresent(Double.self, forKey: .minRadiusFraction) ?? d.minRadiusFraction
        maxRadiusFraction = try c.decodeIfPresent(Double.self, forKey: .maxRadiusFraction) ?? d.maxRadiusFraction
        fillGrayLinear = try c.decodeIfPresent(Double.self, forKey: .fillGrayLinear) ?? d.fillGrayLinear
        rimGrayLinear = try c.decodeIfPresent(Double.self, forKey: .rimGrayLinear) ?? d.rimGrayLinear
        rimWidthFraction = try c.decodeIfPresent(Double.self, forKey: .rimWidthFraction) ?? d.rimWidthFraction
        rimAlpha = try c.decodeIfPresent(Double.self, forKey: .rimAlpha) ?? d.rimAlpha
        overlayAlpha = try c.decodeIfPresent(Double.self, forKey: .overlayAlpha) ?? d.overlayAlpha
        fadeInEnd = try c.decodeIfPresent(Double.self, forKey: .fadeInEnd) ?? d.fadeInEnd
        fadeOutEnd = try c.decodeIfPresent(Double.self, forKey: .fadeOutEnd) ?? d.fadeOutEnd
        maxSlots = try c.decodeIfPresent(Int.self, forKey: .maxSlots) ?? d.maxSlots
        lookbackMs = try c.decodeIfPresent(Double.self, forKey: .lookbackMs) ?? d.lookbackMs
    }

    func validate() throws {
        let values = [pullSize01, rippleDurationMs, rippleReachFraction, rippleBandFraction,
                      rippleCycles, rippleDamping, rippleChromaticSplit, durationMs, minRadiusFraction, maxRadiusFraction, fillGrayLinear,
                      rimGrayLinear, rimWidthFraction, rimAlpha, overlayAlpha, fadeInEnd,
                      fadeOutEnd, lookbackMs]
        guard values.allSatisfy(\.isFinite), durationMs > 0, durationMs <= 10_000,
              (0...0.1).contains(pullSize01), rippleDurationMs > 0, rippleDurationMs <= 10_000,
              rippleReachFraction > 0, rippleReachFraction <= 0.5,
              rippleBandFraction > 0, rippleBandFraction <= 0.2,
              (0.25...10).contains(rippleCycles), (0...20).contains(rippleDamping),
              (0...0.9).contains(rippleChromaticSplit),
              minRadiusFraction >= 0, minRadiusFraction <= 0.1,
              maxRadiusFraction >= minRadiusFraction, maxRadiusFraction <= 0.5,
              (0...1).contains(fillGrayLinear), (0...1).contains(rimGrayLinear),
              rimWidthFraction >= 0, rimWidthFraction <= 0.1,
              (0...1).contains(rimAlpha), (0...1).contains(overlayAlpha),
              fadeInEnd > 0, fadeInEnd < fadeOutEnd, fadeOutEnd <= 1,
              (1...32).contains(maxSlots), lookbackMs >= durationMs, lookbackMs <= 60_000
        else { throw ClickEffectError.invalidConfiguration }
    }

    /// How long one click of the selected effect stays visible; slots older than this are dropped.
    var visibleDuration: Double {
        switch effect {
        case .none: 0
        case .circle: durationMs / 1000
        case .ripple: rippleDurationMs / 1000
        }
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("click-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("click-config.json"), options: .atomic)
    }
}

enum ClickEffectError: LocalizedError {
    case invalidConfiguration
    var errorDescription: String? { "Click effect settings contain invalid values." }
}

/// Source-space click discs. Session coordinates are normalized from the top-left;
/// Core Image coordinates have a bottom-left origin.
struct ClickEffectTimeline: Sendable {
    /// Samples a local radial wave from the source image. Core Image's warp kernel lets the wave
    /// vary with both the distance from the click and its age without allocating a displacement map.
    private static let rippleKernel = CIWarpKernel(source: """
        kernel vec2 radialRipple(vec2 center, float front, float sigma, float amplitude) {
            vec2 point = destCoord();
            vec2 delta = point - center;
            float distance = length(delta);
            if (distance < 0.0001) return point;
            float band = (distance - front) / sigma;
            float displacement = amplitude * exp(-0.5 * band * band);
            return point + normalize(delta) * displacement;
        }
        """)

    private struct Click: Sendable {
        var time: Double
        var x: Double
        var y: Double
    }

    static let duration = 0.45
    private let clicks: [Click]
    private let configuration: ClickEffectConfiguration

    init(events: [CursorEvent], duration: Double, configuration: ClickEffectConfiguration = .init()) {
        self.configuration = (try? configuration.validate()) == nil ? .init() : configuration
        clicks = events.compactMap { event in
            guard event.kind == .down,
                  event.time.isFinite, event.time >= 0, event.time <= duration,
                  event.x.isFinite, event.y.isFinite,
                  (0...1).contains(event.x), (0...1).contains(event.y) else { return nil }
            return Click(time: event.time, x: event.x, y: event.y)
        }.sorted { $0.time < $1.time }
    }

    static func radius(progress: Double, width: Double,
                       configuration: ClickEffectConfiguration = .init()) -> Double {
        let p = min(1, max(0, progress))
        let eased = 1 - pow(1 - p, 3)
        return width * (configuration.minRadiusFraction +
                        (configuration.maxRadiusFraction - configuration.minRadiusFraction) * eased)
    }

    static func fade(progress: Double,
                     configuration: ClickEffectConfiguration = .init()) -> Double {
        let p = min(1, max(0, progress))
        return smoothstep(0, configuration.fadeInEnd, p) *
            (1 - smoothstep(configuration.fadeInEnd, configuration.fadeOutEnd, p))
    }

    /// Draw active clicks with binary searches, so frame order does not affect output.
    func image(over source: CIImage, at time: Double) -> CIImage {
        guard time.isFinite, !clicks.isEmpty, configuration.effect != .none else { return source }
        let ripple = configuration.effect == .ripple
        let lower = lowerBound(time - (ripple ? configuration.visibleDuration : configuration.lookbackMs / 1000))
        let upper = upperBound(time)
        guard lower < upper else { return source }
        // The newest `maxSlots` clicks inside the window, shared by both effects.
        let eligible = Array(clicks[lower..<upper].suffix(configuration.maxSlots))
        if ripple { return rippleImage(over: source, clicks: eligible, at: time) }
        let bounds = source.extent.integral
        let width = Double(bounds.width), height = Double(bounds.height)
        guard width > 0, height > 0 else { return source }
        var result = source
        for click in eligible {
            let age = time - click.time
            let progress = age / (configuration.durationMs / 1000)
            guard age >= 0, progress <= 1 else { continue }
            let radius = Self.radius(progress: progress, width: width, configuration: configuration)
            let rimWidth = width * configuration.rimWidthFraction
            let aa = 1.0
            let extent = radius + rimWidth + aa + 1
            let side = max(1, Int(ceil(extent * 2)))
            guard let context = CGContext(data: nil, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            let center = Double(side) / 2
            let fade = Self.fade(progress: progress, configuration: configuration)
            let factor = configuration.overlayAlpha * fade
            // fillGrayLinear is declared linear-light; encode it to sRGB for this 8-bit patch.
            let fillGray = configuration.fillGrayLinear <= 0.0031308
                ? 12.92 * configuration.fillGrayLinear
                : 1.055 * pow(configuration.fillGrayLinear, 1 / 2.4) - 0.055
            for y in 0..<side {
                for x in 0..<side {
                    let dx = Double(x) + 0.5 - center
                    let dy = Double(y) + 0.5 - center
                    let distance = hypot(dx, dy)
                    let fill = 1 - Self.smoothstep(radius - aa, radius + aa, distance)
                    let rim = 1 - Self.smoothstep(rimWidth, rimWidth + aa, abs(distance - radius))
                    let rimCoverage = rim * configuration.rimAlpha
                    let shapeAlpha = rimCoverage + fill * (1 - rimCoverage)
                    let alpha = shapeAlpha * factor
                    let color = configuration.rimGrayLinear * rimCoverage +
                        fillGray * fill * (1 - rimCoverage)
                    let offset = (y * side + x) * 4
                    bytes[offset] = UInt8((min(1, max(0, color * factor)) * 255).rounded())
                    bytes[offset + 1] = bytes[offset]
                    bytes[offset + 2] = bytes[offset]
                    bytes[offset + 3] = UInt8((min(1, max(0, alpha)) * 255).rounded())
                }
            }
            guard let overlay = context.makeImage() else { continue }
            let centerX = CGFloat(bounds.minX) + CGFloat(click.x * width)
            let centerY = CGFloat(bounds.minY) + CGFloat((1 - click.y) * height)
            let effect = CIImage(cgImage: overlay).transformed(by: CGAffineTransform(
                translationX: centerX - CGFloat(center), y: centerY - CGFloat(center)
            ))
            result = effect.composited(over: result)
        }
        return result
    }

    // MARK: Ripple

    /// Damped-sine envelope of the ripple (viddeo design): `sin(2π·cycles·p)·exp(-damping·p)`, faded to
    /// exactly zero by a smoothstep window over the last 30 % so the effect ends cleanly at the lifetime.
    /// It is 0 at p = 0 and for p >= 1; the sign flips each half cycle (pull in, then out).
    static func rippleEnvelope(progress: Double,
                               configuration: ClickEffectConfiguration = .init()) -> Double {
        guard progress > 0, progress < 1 else { return 0 }
        return sin(2 * .pi * configuration.rippleCycles * progress) *
            exp(-configuration.rippleDamping * progress) * (1 - smoothstep(0.7, 1, progress))
    }

    /// Ring front radius in source pixels: constant speed from the click to the reach at the lifetime end.
    static func rippleFront(progress: Double, width: Double,
                            configuration: ClickEffectConfiguration = .init()) -> Double {
        width * configuration.rippleReachFraction * min(1, max(0, progress))
    }

    /// Signed radial sampling offset in source pixels at `distance` from the click (positive samples
    /// farther out, so content looks pulled toward the click). Peak magnitude is
    /// `pullSize01 * width * |envelope|`; the Gaussian band follows the ring front.
    static func rippleDisplacement(distance: Double, progress: Double, width: Double,
                                   configuration: ClickEffectConfiguration = .init()) -> Double {
        let sigma = width * configuration.rippleBandFraction
        let offset = (distance - rippleFront(progress: progress, width: width, configuration: configuration)) / sigma
        return configuration.pullSize01 * width *
            rippleEnvelope(progress: progress, configuration: configuration) * exp(-0.5 * offset * offset)
    }

    /// Each click is a local radial displacement of the source pixels (CIDisplacementDistortion with a
    /// generated float map, one pass per colour channel, recombined with a per-channel maximum). Red and
    /// blue are pulled `1 + split` and `1 - split` times as far as green, so the split follows the envelope.
    private func rippleImage(over source: CIImage, clicks eligible: [Click], at time: Double) -> CIImage {
        let bounds = source.extent.integral
        let width = Double(bounds.width), height = Double(bounds.height)
        guard width > 0, height > 0, configuration.pullSize01 > 0 else { return source }
        var result = source
        let split = configuration.rippleChromaticSplit
        let factors = [1 + split, 1, 1 - split]
        let masks = [CIVector(x: 1, y: 0, z: 0, w: 0), CIVector(x: 0, y: 1, z: 0, w: 0),
                     CIVector(x: 0, y: 0, z: 1, w: 0)]
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        for click in eligible {
            let progress = (time - click.time) / (configuration.rippleDurationMs / 1000)
            guard progress > 0, progress < 1 else { continue }
            let envelope = Self.rippleEnvelope(progress: progress, configuration: configuration)
            guard abs(envelope) > 1e-4 else { continue }
            let front = Self.rippleFront(progress: progress, width: width, configuration: configuration)
            let sigma = width * configuration.rippleBandFraction
            let half = Int(ceil(front + 3 * sigma)) + 2
            let side = half * 2
            let cx = Double(bounds.minX) + click.x * width, cy = Double(bounds.minY) + (1 - click.y) * height
            let originX = (cx - Double(half)).rounded(), originY = (cy - Double(half)).rounded()
            let patch = CGRect(x: originX, y: originY, width: Double(side), height: Double(side))
            guard patch.intersects(bounds) else { continue }
            let output = patch.intersection(bounds)
            var combined: CIImage?
            for (index, factor) in factors.enumerated() {
                let amplitude = configuration.pullSize01 * width * envelope * factor
                guard let moved = Self.rippleKernel?.apply(
                    extent: output,
                    roiCallback: { _, rect in rect.insetBy(dx: -abs(amplitude), dy: -abs(amplitude)) },
                    image: result.clampedToExtent(),
                    arguments: [CIVector(x: cx, y: cy), front, sigma, amplitude]
                ) else { continue }
                let channel = moved.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": index == 0 ? masks[0] : zero,
                    "inputGVector": index == 1 ? masks[1] : zero,
                    "inputBVector": index == 2 ? masks[2] : zero,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                combined = combined.map { channel.applyingFilter("CIMaximumCompositing", parameters: [
                    kCIInputBackgroundImageKey: $0
                ]) } ?? channel
            }
            if let combined { result = combined.cropped(to: output).composited(over: result) }
        }
        return result
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let s = min(1, max(0, (value - a) / (b - a)))
        return s * s * (3 - 2 * s)
    }

    private func lowerBound(_ value: Double) -> Int {
        var low = 0, high = clicks.count
        while low < high {
            let mid = (low + high) / 2
            if clicks[mid].time < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func upperBound(_ value: Double) -> Int {
        var low = 0, high = clicks.count
        while low < high {
            let mid = (low + high) / 2
            if clicks[mid].time <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
