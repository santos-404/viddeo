import CoreGraphics
import CoreImage
import Foundation

/// Source-space click rings. Session coordinates are normalized from the top-left;
/// Core Image coordinates have a bottom-left origin.
struct ClickEffectTimeline: Sendable {
    private struct Click: Sendable {
        var time: Double
        var x: Double
        var y: Double
    }

    static let duration = 0.45
    private let clicks: [Click]

    init(events: [CursorEvent], duration: Double) {
        clicks = events.compactMap { event in
            guard event.kind == .down,
                  event.time.isFinite, event.time >= 0, event.time <= duration,
                  event.x.isFinite, event.y.isFinite,
                  (0...1).contains(event.x), (0...1).contains(event.y) else { return nil }
            return Click(time: event.time, x: event.x, y: event.y)
        }.sorted { $0.time < $1.time }
    }

    /// Draw only rings active at this time. Binary searches bound work to the
    /// events whose 450 ms lifetime overlaps the requested frame, even on seeks.
    func image(over source: CIImage, at time: Double) -> CIImage {
        guard time.isFinite, !clicks.isEmpty else { return source }
        let lower = lowerBound(time - Self.duration)
        let upper = upperBound(time)
        guard lower < upper else { return source }

        let bounds = source.extent.integral
        let width = CGFloat(bounds.width), height = CGFloat(bounds.height)
        guard width > 0, height > 0 else { return source }
        var result = source
        for click in clicks[lower..<upper] {
            let progress = min(1, max(0, (time - click.time) / Self.duration))
            let alpha = CGFloat(1 - progress)
            guard alpha > 0 else { continue }
            let radius = CGFloat(12 + 30 * progress)
            let patchSize = 100
            guard let context = CGContext(data: nil, width: patchSize, height: patchSize,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let center = CGFloat(patchSize) / 2
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            context.setLineWidth(5)
            context.strokeEllipse(in: CGRect(x: center - radius, y: center - radius,
                                             width: radius * 2, height: radius * 2))
            context.setStrokeColor(CGColor(red: 0.08, green: 0.08, blue: 0.08,
                                           alpha: alpha * 0.55))
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: center - radius, y: center - radius,
                                             width: radius * 2, height: radius * 2))
            guard let overlay = context.makeImage() else { continue }
            let centerX = bounds.minX + CGFloat(click.x) * width
            let centerY = bounds.minY + CGFloat(1 - click.y) * height
            let effect = CIImage(cgImage: overlay).transformed(by: CGAffineTransform(
                translationX: centerX - center, y: centerY - center
            ))
            result = effect.composited(over: result)
        }
        return result
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
