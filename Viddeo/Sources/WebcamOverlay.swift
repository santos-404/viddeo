import CoreGraphics
import CoreImage
import Foundation

/// Camera aspect presets (observed: `original`, `square`, `horizontal` 16:9, `vertical` 9:16;
/// the observed persisted default is the number `1`). Presets encode by name, other ratios as
/// a number; numbers equal to a preset decode as that preset.
enum WebcamAspectRatio: Codable, Sendable, Equatable {
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

/// Observed layout names. `split-screen` and `cutout-camera` are NOT implemented.
enum WebcamLayout: String, Codable, Sendable {
    case cameraOverlay, screenOnly, fullscreenCamera
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
    /// Observed default layout `camera-overlay`.
    var layout = WebcamLayout.cameraOverlay

    /// Scale applied to `paddingRatio` (viddeo interpretation, see `paddingRatio`).
    static let paddingUnit = 0.1

    var anchor: WebcamAnchor { WebcamAnchor.nearest(to: position) }

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

enum WebcamError: LocalizedError {
    case invalidConfiguration
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

    let configuration: WebcamConfiguration
    let bounds: CGRect
    let contentRect: CGRect

    /// `contentRect` is the stage content rect, or nil for the whole canvas. Invalid
    /// configurations fall back to the defaults (export validates user configuration).
    init(configuration: WebcamConfiguration = .init(), outputSize: CGSize, contentRect: CGRect? = nil) {
        self.configuration = (try? configuration.validate()) == nil ? .init() : configuration
        let width = outputSize.width.isFinite ? max(0, outputSize.width.rounded()) : 0
        let height = outputSize.height.isFinite ? max(0, outputSize.height.rounded()) : 0
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = (contentRect ?? bounds).standardized.intersection(bounds)
        self.contentRect = clipped.isNull || clipped.isEmpty ? bounds : clipped
    }

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
        configuration.hide || configuration.layout != .cameraOverlay ||
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
