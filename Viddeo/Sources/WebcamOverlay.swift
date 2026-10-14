import CoreGraphics
import CoreImage
import Foundation

/// Camera aspect presets (observed: `original`, `square`, `horizontal` 16:9, `vertical` 9:16;
/// the observed persisted default is the number `1`). Presets encode by name, other ratios as
/// a number; numbers equal to a preset decode as that preset.
enum WebcamAspectRatio: Codable, Sendable, Hashable {
    case original
    case square
    case horizontal
    case vertical
    case custom(Double)

    /// Width / height, or nil for `original` (use the camera's own aspect).
    var value: Double? {
        switch self {
        case .original: nil
        case .square: 1
        case .horizontal: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        case let .custom(ratio): ratio
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            switch name {
            case "original": self = .original
            case "square": self = .square
            case "horizontal": self = .horizontal
            case "vertical": self = .vertical
            default: throw WebcamError.invalidConfiguration
            }
            return
        }
        let ratio = try container.decode(Double.self)
        let presets: [Self] = [.square, .horizontal, .vertical]
        self = presets.first { abs(($0.value ?? 0) - ratio) < 1e-9 } ?? .custom(ratio)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .original: try container.encode("original")
        case .square: try container.encode("square")
        case .horizontal: try container.encode("horizontal")
        case .vertical: try container.encode("vertical")
        case let .custom(ratio): try container.encode(ratio)
        }
    }
}

/// The 8 observed placement anchors. Unit points use the session convention: origin at the
/// top-left, y down, so (1, 1) is bottom-right.
enum WebcamAnchor: String, CaseIterable, Codable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var point: WebcamPosition {
        switch self {
        case .topLeft: WebcamPosition(x: 0, y: 0)
        case .top: WebcamPosition(x: 0.5, y: 0)
        case .topRight: WebcamPosition(x: 1, y: 0)
        case .left: WebcamPosition(x: 0, y: 0.5)
        case .right: WebcamPosition(x: 1, y: 0.5)
        case .bottomLeft: WebcamPosition(x: 0, y: 1)
        case .bottom: WebcamPosition(x: 0.5, y: 1)
        case .bottomRight: WebcamPosition(x: 1, y: 1)
        }
    }

    /// Nearest anchor by Euclidean distance (observed "nearest of 8 anchors"). Ties, e.g. the
    /// exact center, resolve to the first case in declaration order (viddeo choice).
    static func nearest(to position: WebcamPosition) -> Self {
        var best = Self.bottomRight
        var bestDistance = Double.infinity
        for anchor in allCases {
            let dx = anchor.point.x - position.x, dy = anchor.point.y - position.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance { best = anchor; bestDistance = distance }
        }
        return best
    }
}

struct WebcamPosition: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

enum WebcamShape: String, Codable, Sendable {
    case roundedRect, circle
}

/// Observed layout names (`camera-overlay`, `split-screen`, `cutout-camera`, `screen-only`,
/// `fullscreen-camera`); viddeo persists them in camelCase.
enum WebcamLayout: String, CaseIterable, Codable, Sendable {
    case cameraOverlay, screenOnly, fullscreenCamera, splitScreen, cutoutCamera
}

/// Split-screen pane direction. `horizontal` puts the panes side by side, `vertical` stacks them
/// (screen on top unless flipped). Observed default `auto`: horizontal when the layout area's aspect
/// ratio is at least 1, vertical otherwise (viddeo evaluates the stage area, or the canvas without a stage).
enum SplitDirection: String, CaseIterable, Codable, Sendable {
    case auto, horizontal, vertical
}

/// Observed split fields `splitDirection` auto, `splitFlip` false, `splitScreenRatio01` null,
/// `enablePadding` false.
struct SplitScreenOptions: Codable, Sendable, Equatable {
    var direction = SplitDirection.auto
    /// Observed false. Flipping swaps the panes: the camera takes the left (side by side) or top (stacked) pane.
    var flip = false
    /// Screen's share of the split axis, 0.1...0.9. Observed null; the exact ratio convention is UNKNOWN.
    /// viddeo: nil means `defaultScreenRatio`, and a value is the screen pane's share of the axis
    /// (after the gap), the camera takes the rest.
    var screenRatio: Double? = nil
    /// Observed false. viddeo: true leaves a gap between the panes equal to the stage's padding
    /// (a small fixed fraction without a stage); the outer margin always comes from the stage.
    var enablePadding = false

    /// The observed default-layout compatibility path splits 0.5 / 0.5.
    static let defaultScreenRatio = 0.5
}

/// Observed cutout fields `cutoutCameraPositionX01` 1, `cutoutCameraSizeRatio01` 0.5,
/// `cutoutCameraZoomedScale` 0.8, `cutoutCameraAspectRatio` null (the camera's own aspect, then 1).
struct CutoutCameraOptions: Codable, Sendable, Equatable {
    /// Horizontal position inside the layout area, 0 (left) ... 1 (right).
    var positionX = 1.0
    /// Side of the square the cutout fits in, as a fraction of the area's shorter side.
    var sizeRatio = 0.5
    /// Observed multiplier for the zoomed camera rectangle. Whether the original switches at the
    /// start or end of a screen-moving range is unknown; Viddeo selects the zoomed rectangle as soon
    /// as the zoom timeline leaves 1× and does not invent a size interpolation curve.
    var zoomedScale = 0.8
    /// nil follows the camera's own aspect.
    var aspectRatio: WebcamAspectRatio? = nil
}

/// A time range, in SOURCE (raw recording) milliseconds like caption cues, in which `layout` replaces the
/// configuration's default layout. Observed: layouts are timeline items with a 500 ms minimum.
struct CameraLayoutItem: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var startMs: Double
    var endMs: Double
    var layout: WebcamLayout

    static let minimumDurationMs = 500.0
    static let maximumCount = 1_000

    func contains(_ timeMs: Double) -> Bool { startMs <= timeMs && timeMs < endMs }
}

/// Persisted as `webcam-config.json`. Observed defaults are marked; the rest are viddeo choices.
struct WebcamConfiguration: Codable, Sendable, Equatable {
    /// Observed `hide` false.
    var hide = false
    /// Observed `mirror` false.
    var mirror = false
    /// Observed `aspectRatio` 1.
    var aspectRatio = WebcamAspectRatio.square
    /// Observed overlay size ratio 0.35. Interpretation (not observed): camera width as a
    /// fraction of the content rect WIDTH, shrunk only when the camera plus padding would not
    /// fit the content rect.
    var sizeRatio = 0.35
    /// Observed overlay padding ratio 0.5. Its meaning is UNKNOWN. viddeo interpretation: the
    /// gap to the content edges is `paddingRatio × paddingUnit × camera shorter side`, so the
    /// default is 5 % of the camera's shorter side.
    var paddingRatio = 0.5
    /// Requested anchor, snapped to the nearest of the 8 observed anchors (default bottom-right).
    var position = WebcamAnchor.bottomRight.point
    /// Observed `cameraBorderRadiusRatio01` 0.15, as a fraction of the camera's shorter side.
    var borderRadiusRatio = 0.15
    /// Observed default null (feature off).
    var hideDuringSilenceMs: Double? = nil
    /// viddeo choice; `circle` forces a square camera rect.
    var shape = WebcamShape.roundedRect
    /// viddeo choice: soft drop shadow under the camera.
    var shadow = true
    /// Observed default layout `camera-overlay`; used outside every layout item.
    var layout = WebcamLayout.cameraOverlay
    /// Options of the `splitScreen` and `cutoutCamera` layouts (shared by the default layout and all items).
    var split = SplitScreenOptions()
    var cutout = CutoutCameraOptions()
    /// Layout changes in source time: sorted by the editor, never overlapping, each at least 500 ms.
    var layoutItems: [CameraLayoutItem] = []

    private enum CodingKeys: String, CodingKey {
        case hide, mirror, aspectRatio, sizeRatio, paddingRatio, position, borderRadiusRatio
        case hideDuringSilenceMs, shape, shadow, layout, split, cutout, layoutItems
    }

    /// Scale applied to `paddingRatio` (viddeo interpretation, see `paddingRatio`).
    static let paddingUnit = 0.1

    var anchor: WebcamAnchor { WebcamAnchor.nearest(to: position) }

    /// The layout in effect at source time `timeMs`: the item containing it, else the default layout.
    func layout(atMs timeMs: Double) -> WebcamLayout {
        guard timeMs.isFinite else { return layout }
        return layoutItems.first { $0.contains(timeMs) }?.layout ?? layout
    }

    /// Every layout the export may draw (the default plus the items').
    var usedLayouts: Set<WebcamLayout> { Set(layoutItems.map(\.layout)).union([layout]) }

    /// Adds a layout change starting at `timeMs`, up to `durationMs` long, shortened to the next item and to
    /// `sourceDurationMs`. Throws when fewer than 500 ms are free there.
    @discardableResult
    mutating func addLayoutItem(layout: WebcamLayout, atMs timeMs: Double, durationMs: Double = 3_000,
                                sourceDurationMs: Double) throws -> UUID {
        guard timeMs.isFinite, durationMs.isFinite, sourceDurationMs.isFinite else { throw WebcamError.invalidConfiguration }
        let start = max(0, timeMs)
        guard !layoutItems.contains(where: { $0.contains(start) }) else { throw WebcamError.layoutChangeNoRoom }
        let nextStart = layoutItems.filter { $0.startMs > start }.map(\.startMs).min() ?? .infinity
        let end = min(start + max(durationMs, CameraLayoutItem.minimumDurationMs), nextStart, sourceDurationMs)
        guard end - start >= CameraLayoutItem.minimumDurationMs else { throw WebcamError.layoutChangeNoRoom }
        let item = CameraLayoutItem(startMs: start, endMs: end, layout: layout)
        layoutItems.append(item)
        layoutItems.sort { $0.startMs < $1.startMs }
        return item.id
    }

    mutating func removeLayoutItem(id: UUID) { layoutItems.removeAll { $0.id == id } }

    func validate() throws {
        let values = [sizeRatio, paddingRatio, position.x, position.y, borderRadiusRatio]
        guard values.allSatisfy(\.isFinite), sizeRatio > 0, sizeRatio <= 1,
              paddingRatio >= 0, paddingRatio <= 5,
              (0...1).contains(position.x), (0...1).contains(position.y),
              (0...0.5).contains(borderRadiusRatio)
        else { throw WebcamError.invalidConfiguration }
        if let hideDuringSilenceMs {
            guard hideDuringSilenceMs.isFinite, hideDuringSilenceMs >= 0, hideDuringSilenceMs <= 3_600_000
            else { throw WebcamError.invalidConfiguration }
        }
        if case let .custom(ratio) = aspectRatio {
            guard ratio.isFinite, ratio >= 0.1, ratio <= 10 else { throw WebcamError.invalidConfiguration }
        }
        if let ratio = split.screenRatio {
            guard ratio.isFinite, (0.1...0.9).contains(ratio) else { throw WebcamError.invalidConfiguration }
        }
        guard cutout.positionX.isFinite, (0...1).contains(cutout.positionX),
              cutout.sizeRatio.isFinite, cutout.sizeRatio > 0, cutout.sizeRatio <= 1,
              cutout.zoomedScale.isFinite, cutout.zoomedScale > 0, cutout.zoomedScale <= 1
        else { throw WebcamError.invalidConfiguration }
        if case let .custom(ratio)? = cutout.aspectRatio {
            guard ratio.isFinite, ratio >= 0.1, ratio <= 10 else { throw WebcamError.invalidConfiguration }
        }
        guard layoutItems.count <= CameraLayoutItem.maximumCount else { throw WebcamError.invalidConfiguration }
        let items = layoutItems.sorted { $0.startMs < $1.startMs }
        for (index, item) in items.enumerated() {
            guard item.startMs.isFinite, item.endMs.isFinite, item.startMs >= 0,
                  item.endMs - item.startMs >= CameraLayoutItem.minimumDurationMs else { throw WebcamError.invalidConfiguration }
            if index > 0, items[index - 1].endMs > item.startMs { throw WebcamError.invalidConfiguration }
        }
        guard Set(layoutItems.map(\.id)).count == layoutItems.count else { throw WebcamError.invalidConfiguration }
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("webcam-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("webcam-config.json"), options: .atomic)
    }
}

/// Files written before the split-screen and cutout layouts have none of the new keys.
extension WebcamConfiguration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hide = try c.decode(Bool.self, forKey: .hide)
        mirror = try c.decode(Bool.self, forKey: .mirror)
        aspectRatio = try c.decode(WebcamAspectRatio.self, forKey: .aspectRatio)
        sizeRatio = try c.decode(Double.self, forKey: .sizeRatio)
        paddingRatio = try c.decode(Double.self, forKey: .paddingRatio)
        position = try c.decode(WebcamPosition.self, forKey: .position)
        borderRadiusRatio = try c.decode(Double.self, forKey: .borderRadiusRatio)
        hideDuringSilenceMs = try c.decodeIfPresent(Double.self, forKey: .hideDuringSilenceMs)
        shape = try c.decode(WebcamShape.self, forKey: .shape)
        shadow = try c.decode(Bool.self, forKey: .shadow)
        layout = try c.decode(WebcamLayout.self, forKey: .layout)
        split = try c.decodeIfPresent(SplitScreenOptions.self, forKey: .split) ?? SplitScreenOptions()
        cutout = try c.decodeIfPresent(CutoutCameraOptions.self, forKey: .cutout) ?? CutoutCameraOptions()
        layoutItems = try c.decodeIfPresent([CameraLayoutItem].self, forKey: .layoutItems) ?? []
    }
}

enum WebcamError: LocalizedError {
    case invalidConfiguration
    case layoutChangeNoRoom
    case permissionDenied
    case noDevice
    case deviceDisconnected(partial: WebcamCaptureMetadata?)
    case captureFailed(String)
    case writerFailed(String)
    case noFrames
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Webcam settings contain invalid values."
        case .layoutChangeNoRoom: "There is no room for a layout change of at least 0.5 s at this time."
        case .permissionDenied: "Viddeo does not have permission to use the camera."
        case .noDevice: "No camera is available."
        case .deviceDisconnected: "The camera was disconnected during the recording."
        case let .captureFailed(reason): "The camera capture failed: \(reason)"
        case let .writerFailed(reason): "The camera video could not be written: \(reason)"
        case .noFrames: "The camera did not deliver any frames."
        case .alreadyRecording: "The camera is already recording."
        case .notRecording: "The camera is not recording."
        }
    }
}

/// Observed silence chunk shape `{startMs, endMs, avgAmplitude, durationMs}` reduced to its range.
struct SilenceChunk: Codable, Sendable, Equatable {
    var startMs: Double
    var endMs: Double
}

/// Renders the camera overlay for one output canvas.
///
/// Conventions match `StageRenderer`: rects and images are Core Image space (origin at the
/// bottom-left of the canvas, y up, extent `(0, 0, width, height)`), while
/// `WebcamConfiguration.position` is top-left-first and is flipped here. Instances are
/// immutable values and the returned images are lazy recipes, so sharing is thread-safe.
struct WebcamOverlay: Sendable {
    /// Observed edge margin: the camera only hides more than 500 ms inside a silent chunk.
    static let silenceEdgeMs = 500.0

    /// Gap between split-screen panes without a stage, as a fraction of the area's shorter side.
    static let defaultPaneGapRatio = 0.03

    let configuration: WebcamConfiguration
    let bounds: CGRect
    let contentRect: CGRect
    /// Where the split-screen and cutout layouts work: the stage's padded area, or the whole canvas.
    let layoutArea: CGRect
    /// Split-screen gap when `enablePadding` is on, and the corner radius of the panes (output pixels).
    let paneGap: Double
    let paneCornerRadius: Double

    /// `contentRect` is the stage content rect, or nil for the whole canvas. `layoutArea` is the area the
    /// split-screen panes and the cutout fill (nil: the canvas). Invalid
    /// configurations fall back to the defaults (export validates user configuration).
    init(configuration: WebcamConfiguration = .init(), outputSize: CGSize, contentRect: CGRect? = nil,
         layoutArea: CGRect? = nil, paneGap: Double? = nil, paneCornerRadius: Double = 0) {
        self.configuration = (try? configuration.validate()) == nil ? .init() : configuration
        let width = outputSize.width.isFinite ? max(0, outputSize.width.rounded()) : 0
        let height = outputSize.height.isFinite ? max(0, outputSize.height.rounded()) : 0
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = (contentRect ?? bounds).standardized.intersection(bounds)
        self.contentRect = clipped.isNull || clipped.isEmpty ? bounds : clipped
        let area = (layoutArea ?? bounds).standardized.intersection(bounds)
        // Whole pixels, shrunk inwards, so the panes tile exactly.
        let minX = area.minX.rounded(.up), minY = area.minY.rounded(.up)
        let fitted = CGRect(x: minX, y: minY, width: area.maxX.rounded(.down) - minX, height: area.maxY.rounded(.down) - minY)
        self.layoutArea = area.isNull || fitted.width < 2 || fitted.height < 2 ? bounds : fitted
        let gap = paneGap ?? Self.defaultPaneGapRatio * min(self.layoutArea.width, self.layoutArea.height)
        self.paneGap = gap.isFinite ? max(0, gap.rounded()) : 0
        self.paneCornerRadius = paneCornerRadius.isFinite ? max(0, paneCornerRadius) : 0
    }

    /// The layout in effect at source time `time` (milliseconds).
    func layout(atMs time: Double) -> WebcamLayout { configuration.layout(atMs: time) }

    /// The observed hide rule: hidden only inside a chunk at least `hideDuringSilenceMs` long
    /// and more than 500 ms from both of its edges. nil disables the rule.
    static func isHiddenBySilence(atMs time: Double, chunks: [SilenceChunk], hideDuringSilenceMs: Double?) -> Bool {
        guard let minimum = hideDuringSilenceMs, minimum.isFinite, time.isFinite else { return false }
        return chunks.contains { chunk in
            chunk.endMs - chunk.startMs >= minimum &&
                time > chunk.startMs + silenceEdgeMs && time < chunk.endMs - silenceEdgeMs
        }
    }

    func isHidden(atMs time: Double, chunks: [SilenceChunk]) -> Bool {
        configuration.hide || layout(atMs: time) != .cameraOverlay ||
            Self.isHiddenBySilence(atMs: time, chunks: chunks, hideDuringSilenceMs: configuration.hideDuringSilenceMs)
    }

    /// Integral, even-sized camera rect at the snapped anchor inside the content rect.
    /// `cameraAspect` (width / height) is used only for the `original` aspect setting.
    func rect(cameraAspect: Double) -> CGRect {
        let fallbackAspect = cameraAspect.isFinite && cameraAspect > 0 ? min(10, max(0.1, cameraAspect)) : 1
        let aspect = configuration.shape == .circle ? 1 : configuration.aspectRatio.value ?? fallbackAspect
        var width = configuration.sizeRatio * contentRect.width
        var height = width / aspect
        var padding = configuration.paddingRatio * WebcamConfiguration.paddingUnit * min(width, height)
        // Shrink uniformly when the camera plus padding does not fit; padding scales with it.
        let fit = min(1, contentRect.width / (width + 2 * padding), contentRect.height / (height + 2 * padding))
        if fit.isFinite { width *= fit; height *= fit; padding *= fit }
        let w = max(2, (width / 2).rounded(.down) * 2), h = max(2, (height / 2).rounded(.down) * 2)
        let p = padding.rounded()
        let anchor = configuration.anchor.point
        let x: Double = switch anchor.x {
        case 0: (contentRect.minX + p).rounded(.up)
        case 1: (contentRect.maxX - p - w).rounded(.down)
        default: (contentRect.midX - w / 2).rounded()
        }
        // Top-left y = 0 is the top, i.e. the maximum Core Image y.
        let y: Double = switch anchor.y {
        case 1: (contentRect.minY + p).rounded(.up)
        case 0: (contentRect.maxY - p - h).rounded(.down)
        default: (contentRect.midY - h / 2).rounded()
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Canvas-size transparent overlay, or nil when the camera is hidden at `time` (including
    /// the `screenOnly` and `fullscreenCamera` layouts; use `fullscreen(camera:)` for the latter).
    func image(camera frame: CIImage, atMs time: Double, chunks: [SilenceChunk]) -> CIImage? {
        let extent = frame.extent
        guard !isHidden(atMs: time, chunks: chunks), !bounds.isEmpty,
              !extent.isInfinite, !extent.isEmpty else { return nil }
        return roundedOverlay(camera: frame)
    }

    /// The rounded camera overlay at its anchor, whatever the layout: the camera-overlay layout itself and
    /// the cutout layout's fallback when no person mask is available.
    func roundedOverlay(camera frame: CIImage) -> CIImage? {
        let extent = frame.extent
        guard !bounds.isEmpty, !extent.isInfinite, !extent.isEmpty else { return nil }
        let target = rect(cameraAspect: extent.width / extent.height)
        let radius = configuration.shape == .circle
            ? target.width / 2 : configuration.borderRadiusRatio * min(target.width, target.height)
        let mask = Self.roundedRect(target, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
        let camera = fill(frame, into: target)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        var result = CIImage(color: .clear).cropped(to: bounds)
        if configuration.shadow {
            let size = min(target.width, target.height)
            let shadow = Self.roundedRect(target, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                .applyingGaussianBlur(sigma: 0.03 * size)
                .transformed(by: CGAffineTransform(translationX: 0, y: -0.015 * size))
            result = shadow.composited(over: result)
        }
        return camera.composited(over: result).cropped(to: bounds)
    }

    /// The camera aspect-filled into the whole canvas, for the `fullscreenCamera` layout.
    func fullscreen(camera frame: CIImage) -> CIImage {
        let extent = frame.extent
        guard !extent.isInfinite, !extent.isEmpty else { return CIImage(color: .clear).cropped(to: bounds) }
        return fill(frame, into: bounds)
    }

    // MARK: - Layout resolver

    /// Where the screen and the camera go for one layout (Core Image space, integral).
    struct ResolvedLayout: Sendable, Equatable {
        var layout: WebcamLayout
        /// The screen content's rect: the whole content rect, or the fitted screen inside its pane for `splitScreen`.
        var screen: CGRect
        /// The camera's rect, nil when no camera is drawn (`screenOnly`).
        var camera: CGRect?
        /// Corner radius of the split panes (clamped per rect when drawn); 0 elsewhere.
        var paneRadius: Double
        /// The whole screen pane of the split layout (the screen is fitted inside it); nil elsewhere.
        var screenPane: CGRect? = nil
    }

    /// Resolves `layout` for the canvas: `sourceAspect` is the screen recording's width / height, `cameraAspect`
    /// the camera frame's, and `zoomScale` the current screen zoom (1 = unzoomed; only the cutout reads it).
    /// The overlay, fullscreen and screen-only results are exactly the pre-layout behavior.
    func resolve(layout: WebcamLayout, sourceAspect: Double, cameraAspect: Double, zoomScale: Double = 1) -> ResolvedLayout {
        switch layout {
        case .screenOnly:
            return ResolvedLayout(layout: layout, screen: contentRect, camera: nil, paneRadius: 0)
        case .cameraOverlay:
            return ResolvedLayout(layout: layout, screen: contentRect, camera: rect(cameraAspect: cameraAspect), paneRadius: 0)
        case .fullscreenCamera:
            return ResolvedLayout(layout: layout, screen: contentRect, camera: bounds, paneRadius: 0)
        case .cutoutCamera:
            return ResolvedLayout(layout: layout, screen: contentRect,
                                  camera: cutoutRect(cameraAspect: cameraAspect, zoomScale: zoomScale), paneRadius: 0)
        case .splitScreen:
            let panes = splitPanes()
            return ResolvedLayout(layout: layout, screen: Self.fit(aspect: sourceAspect, in: panes.screen),
                                  camera: panes.camera, paneRadius: paneCornerRadius, screenPane: panes.screen)
        }
    }

    /// Screen and camera panes of the split layout: the direction (auto → by the area's aspect), the screen's share
    /// of the axis after the optional gap, flip, whole pixels. The camera pane takes whatever the screen pane leaves.
    func splitPanes() -> (screen: CGRect, camera: CGRect) {
        let options = configuration.split
        let area = layoutArea
        let horizontal = options.direction == .auto ? area.width >= area.height : options.direction == .horizontal
        let gap = options.enablePadding ? paneGap : 0
        let axis = horizontal ? area.width : area.height
        let total = max(2, axis - gap)
        let screenSize = min(total - 1, max(1, (total * (options.screenRatio ?? SplitScreenOptions.defaultScreenRatio)).rounded()))
        let cameraSize = total - screenSize
        let first = options.flip ? cameraSize : screenSize, second = options.flip ? screenSize : cameraSize
        let firstRect: CGRect, secondRect: CGRect
        if horizontal {
            firstRect = CGRect(x: area.minX, y: area.minY, width: first, height: area.height)
            secondRect = CGRect(x: area.minX + first + gap, y: area.minY, width: second, height: area.height)
        } else {
            // The first pane is the top one, i.e. the maximum Core Image y.
            firstRect = CGRect(x: area.minX, y: area.maxY - first, width: area.width, height: first)
            secondRect = CGRect(x: area.minX, y: area.maxY - first - gap - second, width: area.width, height: second)
        }
        return options.flip ? (screen: secondRect, camera: firstRect) : (screen: firstRect, camera: secondRect)
    }

    /// Cutout rect: a square of `min(area) × sizeRatio`, or `zoomedScale` times that size for any zoom above 1×;
    /// the camera's aspect is fitted inside it, at `positionX` along the area and on its bottom edge.
    func cutoutRect(cameraAspect: Double, zoomScale: Double = 1) -> CGRect {
        let options = configuration.cutout
        let fallback = cameraAspect.isFinite && cameraAspect > 0 ? min(10, max(0.1, cameraAspect)) : 1
        let aspect = options.aspectRatio?.value ?? fallback
        let isZoomed = zoomScale.isFinite && zoomScale > 1
        let side = min(layoutArea.width, layoutArea.height) * options.sizeRatio * (isZoomed ? options.zoomedScale : 1)
        let width = aspect >= 1 ? side : side * aspect, height = aspect >= 1 ? side / aspect : side
        let w = min(layoutArea.width, max(2, (width / 2).rounded(.down) * 2))
        let h = min(layoutArea.height, max(2, (height / 2).rounded(.down) * 2))
        let x = (layoutArea.minX + options.positionX * (layoutArea.width - w)).rounded()
        return CGRect(x: x, y: layoutArea.minY, width: w, height: h)
    }

    /// `aspect` (width / height) fitted and centered in `pane`, whole pixels; the pane itself for a degenerate aspect.
    static func fit(aspect: Double, in pane: CGRect) -> CGRect {
        guard aspect.isFinite, aspect > 0 else { return pane }
        var width = pane.width, height = pane.width / aspect
        if height > pane.height { height = pane.height; width = pane.height * aspect }
        let w = min(pane.width, max(1, width.rounded())), h = min(pane.height, max(1, height.rounded()))
        return CGRect(x: (pane.midX - w / 2).rounded(), y: (pane.midY - h / 2).rounded(), width: w, height: h)
    }

    // MARK: - Split and cutout rendering

    /// The split-screen frame: `background`, the screen (already placed at `layout.screen`, source pixels fitted
    /// there) and the aspect-filled camera in its pane, both with rounded corners. `camera` nil leaves the pane empty.
    func splitFrame(_ layout: ResolvedLayout, screen: CIImage, camera: CIImage?, background: CIImage) -> CIImage {
        let content = splitContent(layout, screen: screen, camera: camera)
        var result = Self.rounded(content.screen, rect: layout.screen, radius: layout.paneRadius)
            .composited(over: background)
        if let image = content.camera, let rect = layout.camera {
            result = Self.rounded(image, rect: rect, radius: layout.paneRadius).composited(over: result)
        }
        return result.cropped(to: bounds)
    }

    /// The un-rounded pane contents: the screen (already placed at `layout.screen`) cropped to its rect and the camera aspect-filled into its pane
    /// (nil without a usable camera). A stage decorates these itself (`StageRenderer.compose(panes:)`).
    func splitContent(_ layout: ResolvedLayout, screen: CIImage, camera: CIImage?) -> (screen: CIImage, camera: CIImage?) {
        var filled: CIImage?
        if let camera, let rect = layout.camera, !camera.extent.isInfinite, !camera.extent.isEmpty {
            filled = fill(camera, into: rect)
        }
        return (screen.cropped(to: layout.screen), filled)
    }

    /// The camera in `rect` keyed by `mask` (white = person, any size; scaled to the camera frame): a canvas-size
    /// transparent image with no border, rounding or shadow (observed: the cutout takes no border radius).
    func cutout(camera frame: CIImage, mask: CIImage, rect: CGRect) -> CIImage {
        let extent = frame.extent, maskExtent = mask.extent
        guard !extent.isInfinite, !extent.isEmpty, !maskExtent.isInfinite, !maskExtent.isEmpty else {
            return CIImage(color: .clear).cropped(to: bounds)
        }
        let scaled = mask.transformed(by: CGAffineTransform(translationX: -maskExtent.minX, y: -maskExtent.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / maskExtent.width, y: extent.height / maskExtent.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
        let alpha = fill(scaled, into: rect).applyingFilter("CIMaskToAlpha")
        let person = fill(frame, into: rect)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha])
        return person.composited(over: CIImage(color: .clear).cropped(to: bounds)).cropped(to: bounds)
    }

    private static func rounded(_ image: CIImage, rect: CGRect, radius: Double) -> CIImage {
        let clamped = min(radius, min(rect.width, rect.height) / 2)
        guard clamped > 0 else { return image }
        return image.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: roundedRect(rect, radius: clamped, color: CIColor(red: 1, green: 1, blue: 1))
        ])
    }

    /// Aspect-fill, centered, mirrored horizontally when configured.
    private func fill(_ frame: CIImage, into target: CGRect) -> CIImage {
        let extent = frame.extent
        var image = frame
        if configuration.mirror {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.minX + extent.maxX, ty: 0))
        }
        let scale = max(target.width / extent.width, target.height / extent.height)
        let transform = CGAffineTransform(translationX: target.midX, y: target.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        return image.clampedToExtent().transformed(by: transform).cropped(to: target)
    }

    private static func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let generated = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color
        ])?.outputImage
        return (generated ?? CIImage(color: color)).cropped(to: rect)
    }
}
