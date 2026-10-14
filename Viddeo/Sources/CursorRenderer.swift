import CoreGraphics
import CoreImage
import Foundation

/// Motion-blur sampling: the trail is drawn as `maxSamples` stamps at most, at least one per
/// `spanPixels` of travel. Caps are the reference's (16 export, 6 interactive); spans are a viddeo
/// design choice read off the reference's fetch-span table (4 and 16 texels).
struct CursorBlurQuality: Sendable, Equatable {
    var maxSamples: Int
    var spanPixels: Double
    static let export = CursorBlurQuality(maxSamples: 16, spanPixels: 4)
    static let preview = CursorBlurQuality(maxSamples: 6, spanPixels: 16)
}

/// Draws viddeo's own procedural cursors (one authored shape per `CursorKind`) as an output-sized transparent overlay.
/// Each call renders into a fresh bitmap, so the renderer is deterministic and thread-safe.
struct CursorRenderer: Sendable {
    /// Classic pointer polygon on a 24-unit grid, y down, hotspot at the tip (origin).
    /// Every kind is authored on the same 24-unit box (so one size setting fits all); see `shape(for:)`.
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

    /// Motion-blurred cursor: the arrow is rendered once and stamped `n` times at the midpoints of
    /// `n` equal slices of the trail from `start` to `now`. Every stamp has alpha 1/n (equal weights,
    /// so the stamps sum to the original alpha and a stationary cursor is unchanged); the midpoint
    /// rule centres the average on the trail's mean position. Only the hotspot motion is swept:
    /// scale and tilt differences across the shutter are small and ignored here.
    func image(for trail: CursorTrail, quality: CursorBlurQuality = .export) -> CIImage? {
        guard let sprite = sprite(for: trail.now) else { return nil }
        let width = Double(outputSize.width), height = Double(outputSize.height)
        let dx = (trail.now.x - trail.start.x) * width, dy = (trail.now.y - trail.start.y) * height
        let distance = hypot(dx, dy)
        guard trail.strength > 0, distance.isFinite, distance >= 0.5, quality.maxSamples > 1 else { return image(for: trail.now) }
        let count = min(quality.maxSamples, max(2, Int(ceil(distance / max(0.5, quality.spanPixels)))))
        let weight = CGFloat(1) / CGFloat(count)
        var sum: CIImage?
        for k in 0..<count {
            let back = 1 - (Double(k) + 0.5) / Double(count)   // fraction of the trail behind `now`
            let stamp = sprite
                .transformed(by: CGAffineTransform(translationX: -dx * back, y: dy * back))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)])
            sum = sum.map { stamp.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? stamp
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        return sum?.cropped(to: canvas).composited(over: clear)
    }

    func image(for state: CursorState) -> CIImage? {
        guard let overlay = sprite(for: state) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        return overlay.cropped(to: canvas).composited(over: clear)
    }

    /// One filled and/or stroked path in shape units (24-unit box, y down).
    private struct Layer {
        var path: CGPath
        var fill: CGColor?
        var stroke: CGColor?
        var strokeUnits = Self.outlineUnits * 2
        static let outlineUnits = 1.25
    }

    private struct Shape {
        /// Hotspot as a fraction of the 24-unit box; the recorded pointer position lands on it.
        var hotspot: CGPoint
        var layers: [Layer]
        /// Velocity tilt turns only arrow-like cursors; the others stay upright.
        var tilts = false
        /// Nudge along the tip bisector so the hotspot pixel is on the outline (sharp-tipped arrow only).
        var nudgesTip = false
    }

    private static let ink = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)
    private static let paper = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let alert = CGColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)

    static func hotspot(for kind: CursorKind) -> CGPoint { shape(for: kind).hotspot }

    private static func solid(_ path: CGPath) -> Layer { Layer(path: path, fill: paper, stroke: ink) }

    private static func rects(_ list: [CGRect], radius: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        for rect in list {
            path.addRoundedRect(in: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2))
        }
        return path
    }

    private static func doubleArrow() -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 1, y: 12), CGPoint(x: 6, y: 6.5), CGPoint(x: 6, y: 10), CGPoint(x: 18, y: 10),
                                CGPoint(x: 18, y: 6.5), CGPoint(x: 23, y: 12), CGPoint(x: 18, y: 17.5),
                                CGPoint(x: 18, y: 14), CGPoint(x: 6, y: 14), CGPoint(x: 6, y: 17.5)])
        path.closeSubpath()
        return path
    }

    private static func turned(_ path: CGPath, degrees: Double) -> CGPath {
        var t = CGAffineTransform(translationX: 12, y: 12).rotated(by: degrees * .pi / 180).translatedBy(x: -12, y: -12)
        return path.copy(using: &t) ?? path
    }

    private static func circle(_ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: 12 - radius, y: 12 - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    private static func iBeam() -> CGPath {
        rects([CGRect(x: 10.9, y: 3, width: 2.2, height: 18), CGRect(x: 7, y: 2, width: 10, height: 2),
               CGRect(x: 7, y: 20, width: 10, height: 2)])
    }

    private static func shape(for kind: CursorKind) -> Shape {
        let center = CGPoint(x: 0.5, y: 0.5)
        switch kind {
        case .arrow:
            let path = CGMutablePath()
            path.addLines(between: arrow)
            path.closeSubpath()
            return Shape(hotspot: .zero, layers: [solid(path)], tilts: true, nudgesTip: true)
        case .iBeam:
            return Shape(hotspot: center, layers: [solid(iBeam())])
        case .iBeamVertical:
            return Shape(hotspot: center, layers: [solid(turned(iBeam(), degrees: 90))])
        case .pointingHand:
            let path = rects([CGRect(x: 8, y: 1, width: 4.6, height: 14, ), CGRect(x: 5, y: 11, width: 14.5, height: 11),
                              CGRect(x: 2.6, y: 12.5, width: 5, height: 7)], radius: 2.3)
            return Shape(hotspot: CGPoint(x: 10.3 / 24, y: 1.0 / 24), layers: [solid(path)])
        case .openHand:
            let fingers = [(5.5, 4.0), (9.2, 2.0), (12.9, 2.0), (16.6, 4.0)].map { CGRect(x: $0.0, y: $0.1, width: 3.2, height: 11) }
            return Shape(hotspot: center, layers: [solid(rects(fingers + [CGRect(x: 4.5, y: 9, width: 15, height: 12.5)], radius: 1.6))])
        case .closedHand:
            let knuckles = [5.5, 9.2, 12.9, 16.6].map { CGRect(x: $0, y: 6.5, width: 3.2, height: 6) }
            return Shape(hotspot: center, layers: [solid(rects(knuckles + [CGRect(x: 4.5, y: 9, width: 15, height: 11.5)], radius: 1.6))])
        case .resizeHorizontal:
            return Shape(hotspot: center, layers: [solid(doubleArrow())])
        case .resizeVertical:
            return Shape(hotspot: center, layers: [solid(turned(doubleArrow(), degrees: 90))])
        case .resizeDiagonalNWSE:
            return Shape(hotspot: center, layers: [solid(turned(doubleArrow(), degrees: 45))])
        case .resizeDiagonalNESW:
            return Shape(hotspot: center, layers: [solid(turned(doubleArrow(), degrees: -45))])
        case .crosshair:
            return Shape(hotspot: center, layers: [solid(rects([CGRect(x: 11, y: 2, width: 2, height: 20),
                                                                CGRect(x: 2, y: 11, width: 20, height: 2)]))])
        case .notAllowed:
            let slash = CGMutablePath()
            slash.move(to: CGPoint(x: 7.8, y: 7.8))
            slash.addLine(to: CGPoint(x: 16.2, y: 16.2))
            return Shape(hotspot: center, layers: [
                solid(circle(10)),
                Layer(path: circle(6.8), fill: nil, stroke: alert, strokeUnits: 2.6),
                Layer(path: slash, fill: nil, stroke: alert, strokeUnits: 2.6)])
        case .wait:
            // A still spinner disc: ring plus a dark quarter wedge (the renderer has no animation clock).
            let wedge = CGMutablePath()
            wedge.move(to: CGPoint(x: 12, y: 12))
            wedge.addArc(center: CGPoint(x: 12, y: 12), radius: 6.6, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            wedge.closeSubpath()
            return Shape(hotspot: center, layers: [solid(circle(10)), Layer(path: wedge, fill: ink, stroke: nil)])
        }
    }

    /// The cursor at its absolute position as a bounded image (empty when too small to draw);
    /// nil when the cursor is invisible or the state is invalid.
    private func sprite(for state: CursorState) -> CIImage? {
        let width = Double(outputSize.width), height = Double(outputSize.height)
        guard state.opacity.isFinite, state.opacity > 0.001,
              [state.x, state.y, state.scale, state.rotationRadians, state.blurRadius].allSatisfy(\.isFinite),
              width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let pixels = configuration.effectiveSize / 1080 * height * max(0, state.scale)
        guard pixels > 0.5 else { return .empty() }
        let unit = pixels / 24
        // Session coordinates are top-left normalized; Core Graphics is bottom-left.
        let hotX = state.x * width, hotY = (1 - state.y) * height
        let shape = Self.shape(for: configuration.alwaysUseDefault ? .arrow : state.kind)
        let angle = shape.tilts ? state.rotationRadians : 0
        let c = cos(angle), s = sin(angle)
        let nudge = shape.nudgesTip ? Self.outlineUnits / 2 : 0
        // Shape units -> canvas: move the hotspot to the origin, scale, rotate about it, flip y, place.
        let toCanvas = CGAffineTransform(translationX: -shape.hotspot.x * 24 + Self.tipBisector.x * nudge,
                                         y: -shape.hotspot.y * 24 + Self.tipBisector.y * nudge)
            .concatenating(CGAffineTransform(a: unit * c, b: -unit * s, c: -unit * s, d: -unit * c, tx: hotX, ty: hotY))
        let layers = shape.layers.map { layer -> (layer: Layer, path: CGPath) in
            var transform = toCanvas
            return (layer, layer.path.copy(using: &transform) ?? layer.path)
        }
        let blur = max(0, state.blurRadius) / 1080 * height
        let shadowBlur = Self.shadowBlurUnits * unit
        let margin = (Self.outlineUnits * 3 + Self.shadowOffsetUnits) * unit + shadowBlur * 2 + 2
        let bounds = layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        let rect = bounds.insetBy(dx: -margin, dy: -margin).integral
            .intersection(canvas.insetBy(dx: -3 * blur - margin, dy: -3 * blur - margin).integral)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                      bitsPerComponent: 8, bytesPerRow: Int(rect.width) * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .empty() }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        // The outer layer fades the finished cursor; the inner one casts a single shadow, so
        // outline, fill and shadow fade together and the shadow never shows through the body.
        context.setAlpha(min(1, state.opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: CGSize(width: 0, height: -Self.shadowOffsetUnits * unit), blur: shadowBlur,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for (layer, path) in layers {
            if let stroke = layer.stroke {
                context.addPath(path)
                context.setLineWidth(layer.strokeUnits * unit)
                context.setStrokeColor(stroke)
                context.strokePath()
            }
            if let fill = layer.fill {
                context.addPath(path)
                context.setFillColor(fill)
                context.fillPath()
            }
        }
        context.endTransparencyLayer()
        context.endTransparencyLayer()
        guard let cursor = context.makeImage() else { return .empty() }
        var overlay = CIImage(cgImage: cursor)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        if blur > 0.01 { overlay = overlay.applyingGaussianBlur(sigma: blur) }
        return overlay
    }
}
