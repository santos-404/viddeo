import CoreGraphics
import CoreImage
import Foundation

/// Places an already-zoomed content frame inside a padded stage over a background.
///
/// Conventions: every rect and image here uses Core Image space — origin at the bottom-left
/// of the output, y up, extent `(0, 0, outputWidth, outputHeight)`. Style values that are
/// specified top-left-first (gradient points, shadow angle) are flipped once at build time.
/// Lengths in `StageStyle` are reference pixels on a 1080-px-high canvas, scaled by
/// `outputHeight / 1080`.
///
/// The background and the blurred shadow are rendered to bitmaps once, so the per-frame work
/// in `compose` is a scale, a mask and two composites. Instances are immutable apart from a
/// lock-protected prepared-stage cache, so they are safe to share across threads.
struct StageRenderer: Sendable {
    let style: StageStyle
    let outputSize: CGSize
    /// Opaque output-size background (blur applied), origin zero.
    let background: CIImage
    private let context: CIContext
    private let cache = PreparedStageCache()
    private let paneCache = PreparedPanesCache()

    init(style: StageStyle, outputSize: CGSize, baseDirectory: URL? = nil) throws {
        try style.validate()
        let width = outputSize.width.rounded(), height = outputSize.height.rounded()
        guard width.isFinite, height.isFinite, (2...16_384).contains(width), (2...16_384).contains(height)
        else { throw StageError.invalidOutputSize }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CIContext(options: [.cacheIntermediates: false])
        let scale = Double(height) / StageStyle.referenceHeight

        var image: CIImage
        switch style.background {
        case .color(let hex):
            image = CIImage(color: Self.color(hex: hex)).cropped(to: bounds)
        case .gradient(let stops, let start, let end):
            image = try Self.gradient(stops: stops, start: start, end: end, bounds: bounds)
        case .image(let name):
            image = try Self.image(named: name, in: baseDirectory, bounds: bounds)
        case .wallpaper(let name):
            image = Self.wallpaper(named: name, bounds: bounds)
        }
        if style.backgroundBlur > 0 {
            image = image.clampedToExtent()
                .applyingGaussianBlur(sigma: style.backgroundBlur * scale)
                .cropped(to: bounds)
        }
        image = image.composited(over: CIImage(color: .black).cropped(to: bounds))
        guard let rendered = context.createCGImage(image, from: bounds, format: .RGBA8,
                                                   colorSpace: Self.sRGB)
        else { throw StageError.renderFailed }

        self.style = style
        self.outputSize = bounds.size
        self.context = context
        background = CIImage(cgImage: rendered)
    }

    /// Stage = output inset by `paddingRatio × min(width, height)` on every side (design choice;
    /// the original's exact padding math is UNKNOWN). Content is aspect-fit and centered in the
    /// stage, with edges rounded to whole pixels. Core Image coordinates (bottom-left origin);
    /// because the rect is vertically centered it is the same rect in top-left space up to
    /// one pixel of rounding. A non-positive or non-finite aspect fills the whole stage.
    func stageRect(contentAspect: Double) -> CGRect {
        let width = Double(outputSize.width), height = Double(outputSize.height)
        let padding = style.paddingRatio * min(width, height)
        let stageWidth = width - 2 * padding, stageHeight = height - 2 * padding
        var fitWidth = stageWidth, fitHeight = stageHeight
        let frame = DeviceFrameRenderer(configuration: style.deviceMockup)
        let fitAspect = frame.map { Double($0.geometry.canvasSize.width / $0.geometry.canvasSize.height) } ?? contentAspect
        if fitAspect.isFinite, fitAspect > 0 {
            if fitAspect > stageWidth / stageHeight {
                fitHeight = stageWidth / fitAspect
            } else {
                fitWidth = stageHeight * fitAspect
            }
        }
        let minX = ((width - fitWidth) / 2).rounded(), maxX = ((width + fitWidth) / 2).rounded()
        let minY = ((height - fitHeight) / 2).rounded(), maxY = ((height + fitHeight) / 2).rounded()
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    func screenRect(contentAspect: Double) -> CGRect {
        let rect = stageRect(contentAspect: contentAspect)
        guard let frame = DeviceFrameRenderer(configuration: style.deviceMockup) else { return rect }
        return frame.apertureRect(in: frame.fittedRect(in: rect))
    }

    /// Mask, shadow and border for one content size; cached for the most recent size.
    func prepared(contentSize: CGSize) -> PreparedStage {
        if let cached = cache.stage(for: contentSize) { return cached }
        let stage = makePrepared(contentSize: contentSize)
        cache.store(stage, for: contentSize)
        return stage
    }

    /// Returns an output-size image: background, shadow, content in the stage rect clipped
    /// to the rounded mask, then the inset border. Content is expected at origin zero.
    func compose(_ content: CIImage) -> CIImage {
        if let frame = DeviceFrameRenderer(configuration: style.deviceMockup) {
            let aspect = content.extent.height > 0 ? Double(content.extent.width / content.extent.height) : 0
            let rect = stageRect(contentAspect: aspect)
            // Device owns screen rounding and bezel; stage inset and screen corner radius are bypassed.
            let scale = Double(outputSize.height) / StageStyle.referenceHeight
            return frame.compose(content, in: rect, shadowIntensity: style.shadow.intensity,
                                 shadowDistance: style.shadow.isDirectional ? style.shadow.distance * scale : 0,
                                 shadowAngle: style.shadow.angle,
                                 shadowBlur: style.shadow.blur * scale)
                .composited(over: background).cropped(to: CGRect(origin: .zero, size: outputSize))
        }
        return prepared(contentSize: content.extent.size).compose(content)
    }

    private func makePrepared(contentSize: CGSize) -> PreparedStage {
        let bounds = CGRect(origin: .zero, size: outputSize)
        let aspect = contentSize.height > 0 ? Double(contentSize.width / contentSize.height) : 0
        let rect = stageRect(contentAspect: aspect)
        let radius = cornerRadius(for: rect)
        let mask = Self.roundedRect(rect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))

        var backdrop = background
        if let shape = shadowShape(for: rect, radius: radius) {
            backdrop = shape.cropped(to: bounds).composited(over: background)
            if let baked = context.createCGImage(backdrop, from: bounds, format: .RGBA8, colorSpace: Self.sRGB) {
                backdrop = CIImage(cgImage: baked)
            }
        }
        return PreparedStage(bounds: bounds, contentRect: rect, backdrop: backdrop, mask: mask,
                             border: borderImage(for: rect, radius: radius))
    }

    // MARK: - Per-rect decoration (shared by the single-content stage and the split-screen panes)

    private var scale: Double { Double(outputSize.height) / StageStyle.referenceHeight }

    /// The stage corner radius for a content rect, clamped to half its shorter side.
    private func cornerRadius(for rect: CGRect) -> Double {
        min(style.cornerRadius * scale, Double(min(rect.width, rect.height)) / 2)
    }

    /// The blurred, offset shadow of a content rect (not yet cropped to the output); nil without a shadow.
    private func shadowShape(for rect: CGRect, radius: Double) -> CIImage? {
        let shadow = style.shadow
        guard shadow.intensity > 0 else { return nil }
        let angle = shadow.angle * .pi / 180
        let distance = shadow.isDirectional ? shadow.distance * scale : 0
        // Top-left-origin offset (cos, sin) becomes (cos, -sin) with Core Image's y-up origin.
        var shape = Self.roundedRect(rect, radius: radius,
                                     color: CIColor(red: 0, green: 0, blue: 0, alpha: shadow.intensity))
            .transformed(by: CGAffineTransform(translationX: distance * cos(angle),
                                               y: -distance * sin(angle)))
        let sigma = 8 * shadow.blur * scale
        if sigma > 0 { shape = shape.applyingGaussianBlur(sigma: sigma) }
        return shape
    }

    /// The inset border ring drawn inside a content rect's edge; nil when the border is off.
    private func borderImage(for rect: CGRect, radius: Double) -> CIImage? {
        guard style.inset.size > 0, let rgba = StageStyle.rgba(hex: style.inset.color) else { return nil }
        let width = min(style.inset.size * scale, Double(min(rect.width, rect.height)) / 2)
        let color = CIColor(red: rgba.red, green: rgba.green, blue: rgba.blue,
                            alpha: rgba.alpha * style.inset.alpha, colorSpace: Self.sRGB)
            ?? CIColor(red: 0, green: 0, blue: 0, alpha: style.inset.alpha)
        let outer = Self.roundedRect(rect, radius: radius, color: color)
        let innerRect = rect.insetBy(dx: width, dy: width)
        guard innerRect.width > 0, innerRect.height > 0 else { return outer }
        let inner = Self.roundedRect(innerRect, radius: max(0, radius - width),
                                     color: CIColor(red: 1, green: 1, blue: 1))
        return outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
    }

    // MARK: - Split-screen panes

    /// One decorated content rect of a split-screen frame. `content` is already placed in `rect` (any extent that
    /// covers it). A pane with a `deviceArea` is drawn inside the stage's device frame fitted to that area (`rect` is
    /// then the device's screen aperture, see `deviceScreenRect(in:)`); every other pane gets the rounded mask, shadow
    /// and inset border of the single-content stage.
    struct Pane {
        var rect: CGRect
        var content: CIImage
        var deviceArea: CGRect? = nil
    }

    /// The device's screen aperture when the stage has a device frame and it is fitted into `area`; nil otherwise.
    func deviceScreenRect(in area: CGRect) -> CGRect? {
        guard let frame = DeviceFrameRenderer(configuration: style.deviceMockup) else { return nil }
        return frame.apertureRect(in: frame.fittedRect(in: area))
    }

    /// Background, then every pane with the same treatment `compose` gives the single content. Per-pane shadows
    /// are baked into one backdrop that is cached while the pane rects stay the same.
    func compose(panes: [Pane]) -> CIImage {
        let bounds = CGRect(origin: .zero, size: outputSize)
        let prepared = preparedPanes(for: panes)
        var result = prepared.backdrop
        let frame = DeviceFrameRenderer(configuration: style.deviceMockup)
        for (index, pane) in panes.enumerated() {
            if let area = pane.deviceArea, let frame {
                // Device owns screen rounding and bezel; compose expects the screen at the origin.
                let screen = pane.content.transformed(by: CGAffineTransform(translationX: -pane.rect.minX, y: -pane.rect.minY))
                    .cropped(to: CGRect(origin: .zero, size: pane.rect.size))
                result = frame.compose(screen, in: area, shadowIntensity: style.shadow.intensity,
                                       shadowDistance: style.shadow.isDirectional ? style.shadow.distance * scale : 0,
                                       shadowAngle: style.shadow.angle, shadowBlur: style.shadow.blur * scale)
                    .composited(over: result)
                continue
            }
            let decoration = prepared.decorations[index]
            result = pane.content.cropped(to: pane.rect)
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: decoration.mask])
                .composited(over: result)
            if let border = decoration.border { result = border.composited(over: result) }
        }
        return result.cropped(to: bounds)
    }

    private func preparedPanes(for panes: [Pane]) -> PreparedPanes {
        let key = panes.map { PaneKey(rect: $0.rect, deviceArea: $0.deviceArea) }
        if let cached = paneCache.panes(for: key) { return cached }
        let bounds = CGRect(origin: .zero, size: outputSize)
        var backdrop = background
        var shadowed = false
        var decorations: [PreparedPanes.Decoration] = []
        for pane in panes {
            let radius = cornerRadius(for: pane.rect)
            decorations.append(.init(mask: Self.roundedRect(pane.rect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1)),
                                     border: borderImage(for: pane.rect, radius: radius)))
            if pane.deviceArea == nil, let shape = shadowShape(for: pane.rect, radius: radius) {
                backdrop = shape.cropped(to: bounds).composited(over: backdrop)
                shadowed = true
            }
        }
        if shadowed, let baked = context.createCGImage(backdrop, from: bounds, format: .RGBA8, colorSpace: Self.sRGB) {
            backdrop = CIImage(cgImage: baked)
        }
        let prepared = PreparedPanes(backdrop: backdrop, decorations: decorations)
        paneCache.store(prepared, for: key)
        return prepared
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func color(hex: String, alpha: Double = 1) -> CIColor {
        guard let rgba = StageStyle.rgba(hex: hex),
              let color = CIColor(red: rgba.red, green: rgba.green, blue: rgba.blue,
                                  alpha: rgba.alpha * alpha, colorSpace: sRGB)
        else { return CIColor(red: 0, green: 0, blue: 0) }
        return color
    }

    private static func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let generated = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color
        ])?.outputImage
        return (generated ?? CIImage(color: color)).cropped(to: rect)
    }

    /// Drawn with CoreGraphics so any number of stops is exact. The bitmap context is y-up,
    /// matching Core Image, so unit point (x, y) maps to (x × width, (1 − y) × height).
    private static func gradient(stops: [GradientStop], start: StagePoint, end: StagePoint,
                                 bounds: CGRect) throws -> CIImage {
        let width = Int(bounds.width), height = Int(bounds.height)
        let colors = stops.compactMap { stop -> CGColor? in
            guard let rgba = StageStyle.rgba(hex: stop.color) else { return nil }
            return CGColor(colorSpace: sRGB, components: [rgba.red, rgba.green, rgba.blue, rgba.alpha])
        }
        guard colors.count == stops.count,
              let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray,
                                        locations: stops.map { CGFloat($0.location) }),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: sRGB,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw StageError.renderFailed }
        let point = { (unit: StagePoint) in
            CGPoint(x: unit.x * Double(width), y: (1 - unit.y) * Double(height))
        }
        bitmap.drawLinearGradient(gradient, start: point(start), end: point(end),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let image = bitmap.makeImage() else { throw StageError.renderFailed }
        return CIImage(cgImage: image)
    }

    /// Aspect-fill: scale by the larger ratio, center, crop to the output.
    private static func image(named name: String, in directory: URL?, bounds: CGRect) throws -> CIImage {
        guard let directory, StageStyle.isSimpleFileName(name) else {
            throw StageError.invalidStyle("image must be a file name inside the session directory")
        }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StageError.imageNotFound(name) }
        // Refuse symlinks that resolve outside the session directory.
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path ==
                directory.resolvingSymlinksInPath().path
        else { throw StageError.invalidStyle("image must be a file name inside the session directory") }
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              !source.extent.isInfinite, source.extent.width > 0, source.extent.height > 0
        else { throw StageError.unreadableImage(name) }
        let extent = source.extent
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let transform = CGAffineTransform(translationX: (bounds.width - extent.width * scale) / 2,
                                          y: (bounds.height - extent.height * scale) / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -extent.minX, y: -extent.minY)
        return source.clampedToExtent().transformed(by: transform).cropped(to: bounds)
    }

    private struct Glow {
        var x: Double
        var y: Double
        var radius: Double
        var color: String
        var alpha: Double
    }

    /// viddeo's own procedural wallpapers: a vertical base gradient plus soft radial glows.
    /// Glow centers are top-left-origin unit points; radii are fractions of the longer side.
    private static func wallpaper(named name: String, bounds: CGRect) -> CIImage {
        let (top, bottom, glows): (String, String, [Glow]) = switch name {
        case "aurora": ("#0b1d3a", "#123c5a", [
            Glow(x: 0.25, y: 0.3, radius: 0.6, color: "#3ddc97", alpha: 0.55),
            Glow(x: 0.75, y: 0.2, radius: 0.5, color: "#7b5cff", alpha: 0.5),
            Glow(x: 0.6, y: 0.85, radius: 0.55, color: "#23b5d3", alpha: 0.45)
        ])
        case "dusk": ("#2a1b4a", "#f08a5d", [
            Glow(x: 0.7, y: 0.75, radius: 0.35, color: "#ffd27a", alpha: 0.6),
            Glow(x: 0.2, y: 0.2, radius: 0.6, color: "#6b2d6b", alpha: 0.4)
        ])
        case "mint": ("#d8f3e6", "#7fd1b9", [
            Glow(x: 0.2, y: 0.8, radius: 0.5, color: "#ffffff", alpha: 0.5),
            Glow(x: 0.85, y: 0.25, radius: 0.6, color: "#3fa58f", alpha: 0.4)
        ])
        default: ("#2a2d33", "#121316", [
            Glow(x: 0.5, y: 0.35, radius: 0.7, color: "#5a606b", alpha: 0.5)
        ])
        }
        let base = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: bounds.height),
            "inputPoint1": CIVector(x: 0, y: 0),
            "inputColor0": color(hex: top),
            "inputColor1": color(hex: bottom)
        ])?.outputImage ?? CIImage(color: color(hex: top))
        let longest = Double(max(bounds.width, bounds.height))
        return glows.reduce(base.cropped(to: bounds)) { image, glow in
            guard let light = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: glow.x * Double(bounds.width), y: (1 - glow.y) * Double(bounds.height)),
                "inputRadius0": 0,
                "inputRadius1": glow.radius * longest,
                "inputColor0": color(hex: glow.color, alpha: glow.alpha),
                "inputColor1": color(hex: glow.color, alpha: 0)
            ])?.outputImage else { return image }
            return light.cropped(to: bounds).composited(over: image)
        }
    }
}

/// Per-content-size stage pieces. Immutable; `compose` is the cheap per-frame path.
struct PreparedStage: @unchecked Sendable {
    // @unchecked: CIImage values are immutable recipes and safe to share across threads.
    let bounds: CGRect
    /// Content placement in Core Image (bottom-left origin) output coordinates.
    let contentRect: CGRect
    /// Background with the shadow baked in.
    let backdrop: CIImage
    let mask: CIImage
    let border: CIImage?

    func compose(_ content: CIImage) -> CIImage {
        let extent = content.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return backdrop.cropped(to: bounds) }
        // Edge-clamp before scaling so resampling never pulls transparent pixels into the edges.
        let transform = CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY)
            .scaledBy(x: contentRect.width / extent.width, y: contentRect.height / extent.height)
            .translatedBy(x: -extent.minX, y: -extent.minY)
        let placed = content.clampedToExtent().transformed(by: transform).cropped(to: contentRect)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        var result = placed.composited(over: backdrop)
        if let border { result = border.composited(over: result) }
        return result.cropped(to: bounds)
    }
}

/// Backdrop (background plus pane shadows) and per-pane mask and border for one set of pane rects.
struct PreparedPanes: @unchecked Sendable {
    // @unchecked: CIImage values are immutable recipes and safe to share across threads.
    struct Decoration {
        let mask: CIImage
        let border: CIImage?
    }

    let backdrop: CIImage
    let decorations: [Decoration]
}

struct PaneKey: Equatable, Sendable {
    let rect: CGRect
    let deviceArea: CGRect?
}

private final class PreparedPanesCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (key: [PaneKey], panes: PreparedPanes)?

    func panes(for key: [PaneKey]) -> PreparedPanes? {
        lock.withLock { entry?.key == key ? entry?.panes : nil }
    }

    func store(_ panes: PreparedPanes, for key: [PaneKey]) {
        lock.withLock { entry = (key, panes) }
    }
}

private final class PreparedStageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (size: CGSize, stage: PreparedStage)?

    func stage(for size: CGSize) -> PreparedStage? {
        lock.withLock { entry?.size == size ? entry?.stage : nil }
    }

    func store(_ stage: PreparedStage, for size: CGSize) {
        lock.withLock { entry = (size, stage) }
    }
}
