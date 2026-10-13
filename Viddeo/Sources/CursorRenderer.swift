import CoreGraphics
import CoreImage
import Foundation

/// Draws viddeo's own procedural arrow cursor as an output-sized transparent overlay.
/// Each call renders into a fresh bitmap, so the renderer is deterministic and thread-safe.
struct CursorRenderer: Sendable {
    /// Classic pointer polygon on a 24-unit grid, y down, hotspot at the tip (origin).
    private static let arrow: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 19), CGPoint(x: 4.5, y: 14.8),
        CGPoint(x: 7.4, y: 21.4), CGPoint(x: 10.6, y: 20), CGPoint(x: 7.8, y: 13.6),
        CGPoint(x: 13.6, y: 13.6)
    ]
    private static let outlineUnits = 1.25
    /// Unit bisector of the tip angle; the polygon is nudged along it by half the outline,
    /// so the hotspot pixel lands on the outline instead of outside the rounded tip.
    private static let tipBisector = CGPoint(x: 0.3827, y: 0.9239)
    private static let shadowOffsetUnits = 1.0
    private static let shadowBlurUnits = 2.4

    let configuration: CursorConfiguration
    let outputSize: CGSize

    init(configuration: CursorConfiguration = .init(), outputSize: CGSize) {
        self.configuration = (try? configuration.validate()) == nil ? .init() : configuration
        self.outputSize = outputSize
    }

    func image(for state: CursorState) -> CIImage? {
        let width = Double(outputSize.width), height = Double(outputSize.height)
        guard state.opacity.isFinite, state.opacity > 0.001,
              [state.x, state.y, state.scale, state.rotationRadians, state.blurRadius].allSatisfy(\.isFinite),
              width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        let pixels = configuration.effectiveSize / 1080 * height * max(0, state.scale)
        guard pixels > 0.5 else { return clear }
        let unit = pixels / 24
        // Session coordinates are top-left normalized; Core Graphics is bottom-left.
        let hotX = state.x * width, hotY = (1 - state.y) * height
        let c = cos(state.rotationRadians), s = sin(state.rotationRadians)
        let nudge = Self.outlineUnits / 2
        let points = Self.arrow.map { point -> CGPoint in
            let u = (point.x + Self.tipBisector.x * nudge) * unit
            let v = (point.y + Self.tipBisector.y * nudge) * unit
            return CGPoint(x: hotX + u * c - v * s, y: hotY - (u * s + v * c))
        }
        let blur = max(0, state.blurRadius) / 1080 * height
        let shadowBlur = Self.shadowBlurUnits * unit
        let margin = (Self.outlineUnits * 3 + Self.shadowOffsetUnits) * unit + shadowBlur * 2 + 2
        var bounds = CGRect(x: points[0].x, y: points[0].y, width: 0, height: 0)
        for point in points { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
        let rect = bounds.insetBy(dx: -margin, dy: -margin).integral
            .intersection(canvas.insetBy(dx: -3 * blur - margin, dy: -3 * blur - margin).integral)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                      bitsPerComponent: 8, bytesPerRow: Int(rect.width) * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return clear }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        // The outer layer fades the finished cursor; the inner one casts a single shadow, so
        // outline, fill and shadow fade together and the shadow never shows through the body.
        context.setAlpha(min(1, state.opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: CGSize(width: 0, height: -Self.shadowOffsetUnits * unit), blur: shadowBlur,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(Self.outlineUnits * 2 * unit)
        context.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        context.strokePath()
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.endTransparencyLayer()
        context.endTransparencyLayer()
        guard let cursor = context.makeImage() else { return clear }
        var overlay = CIImage(cgImage: cursor)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        if blur > 0.01 { overlay = overlay.applyingGaussianBlur(sigma: blur) }
        return overlay.cropped(to: canvas).composited(over: clear)
    }
}
