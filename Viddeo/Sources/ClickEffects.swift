import CoreGraphics
import CoreImage
import Foundation

struct ClickEffectConfiguration: Codable, Sendable {
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

    func validate() throws {
        let values = [durationMs, minRadiusFraction, maxRadiusFraction, fillGrayLinear,
                      rimGrayLinear, rimWidthFraction, rimAlpha, overlayAlpha, fadeInEnd,
                      fadeOutEnd, lookbackMs]
        guard values.allSatisfy(\.isFinite), durationMs > 0, durationMs <= 10_000,
              minRadiusFraction >= 0, minRadiusFraction <= 0.1,
              maxRadiusFraction >= minRadiusFraction, maxRadiusFraction <= 0.5,
              (0...1).contains(fillGrayLinear), (0...1).contains(rimGrayLinear),
              rimWidthFraction >= 0, rimWidthFraction <= 0.1,
              (0...1).contains(rimAlpha), (0...1).contains(overlayAlpha),
              fadeInEnd > 0, fadeInEnd < fadeOutEnd, fadeOutEnd <= 1,
              (1...32).contains(maxSlots), lookbackMs >= durationMs, lookbackMs <= 60_000
        else { throw ClickEffectError.invalidConfiguration }
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
        guard time.isFinite, !clicks.isEmpty else { return source }
        let lower = lowerBound(time - configuration.lookbackMs / 1000)
        let upper = upperBound(time)
        guard lower < upper else { return source }
        let eligible = Array(clicks[lower..<upper].suffix(configuration.maxSlots))
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
