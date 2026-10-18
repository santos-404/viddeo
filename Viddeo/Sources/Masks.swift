import CoreGraphics
import CoreImage
import Foundation

enum MaskKind: String, Codable, Sendable {
    case sensitiveData = "sensitive-data"
    case highlight
}

struct TimelineMask: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var isDisabled: Bool
    /// Normalized recording-space rectangles with a top-left origin. The renderer uses the first.
    var bounds: [CGRect]
    var blur: Double
    var kind: MaskKind
    var highlightOpacity: Double

    static let minDuration = 0.5
    static let initialDuration = 3.0

    init(id: UUID = UUID(), sourceStart: Double, sourceEnd: Double, isDisabled: Bool = false,
         bounds: [CGRect] = [], blur: Double = 32, kind: MaskKind = .sensitiveData,
         highlightOpacity: Double = 0.5) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.isDisabled = isDisabled
        self.bounds = bounds
        self.blur = blur
        self.kind = kind
        self.highlightOpacity = highlightOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceStart, sourceEnd, isDisabled, bounds, blur, kind, highlightOpacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceStart = try c.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try c.decode(Double.self, forKey: .sourceEnd)
        isDisabled = try c.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        bounds = try c.decodeIfPresent([CGRect].self, forKey: .bounds) ?? []
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 32
        kind = try c.decodeIfPresent(MaskKind.self, forKey: .kind) ?? .sensitiveData
        highlightOpacity = try c.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? 0.5
    }

    /// Centered rectangle using the observed 350×80 pixel cap; returned in normalized coordinates.
    static func defaultBounds(recordingSize: CGSize) -> CGRect {
        let width = min(max(0, recordingSize.width), 350)
        let height = min(max(0, recordingSize.height), 80)
        guard recordingSize.width > 0, recordingSize.height > 0 else { return .zero }
        return CGRect(x: (recordingSize.width - width) / (2 * recordingSize.width),
                      y: (recordingSize.height - height) / (2 * recordingSize.height),
                      width: width / recordingSize.width, height: height / recordingSize.height)
    }
}

struct MaskConfiguration: Codable, Sendable, Equatable {
    var version: Int
    var masks: [TimelineMask]

    init(version: Int = 1, masks: [TimelineMask] = []) {
        self.version = version
        self.masks = masks
    }

    private enum CodingKeys: String, CodingKey { case version, masks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        masks = try c.decodeIfPresent([TimelineMask].self, forKey: .masks) ?? []
    }

    static func load(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("masks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("masks.json"), options: .atomic)
    }
}

struct MaskFrameState: Sendable, Equatable {
    var rect: CGRect
    var kind: MaskKind
    var highlightOpacity: Double
    var opacity: Double
    var blur: Double
}

/// Source-time mask selection and deterministic presentation. Evaluations are seekable and do not
/// depend on frame order. Apply its state to the source footage before zoom/crop to keep it attached
/// to source pixels; ExportFrameRenderer needs only `state(atSource:)` and `MaskRenderer.apply`.
struct MaskTimeline: Sendable {
    private struct Item: Sendable {
        var mask: TimelineMask
        var isGreedy: Bool
    }

    private let items: [Item]

    init(configuration: MaskConfiguration) {
        items = configuration.masks.filter(Self.valid).sorted {
            $0.sourceStart == $1.sourceStart ? $0.id.uuidString < $1.id.uuidString : $0.sourceStart < $1.sourceStart
        }.map { Item(mask: $0, isGreedy: !$0.isDisabled && $0.kind == .sensitiveData && !$0.bounds.isEmpty) }
    }

    func state(atSource t: Double) -> MaskFrameState? {
        guard t.isFinite else { return nil }
        let active = items.filter { !$0.mask.isDisabled && !$0.mask.bounds.isEmpty && $0.mask.sourceStart <= t && t <= $0.mask.sourceEnd }
        var selected = active.first(where: \.isGreedy)
        if selected == nil {
            let nextGreedy = items.first { item in
                item.isGreedy && item.mask.sourceStart > t &&
                    Self.showStart(item) <= t && t <= item.mask.sourceEnd + 0.2
            }
            selected = nextGreedy
            if selected == nil && active.isEmpty {
                let previous = items.last { $0.mask.sourceEnd < t && Self.canShow($0) }
                let next = items.first { $0.mask.sourceStart > t && Self.canShow($0) }
                if let previous, let next, next.mask.sourceStart - previous.mask.sourceEnd < 0.4 {
                    selected = next
                } else {
                    selected = active.first ?? items.last { item in
                        Self.canShow(item) && Self.showStart(item) <= t && t <= item.mask.sourceEnd + 0.2
                    }
                }
            } else if selected == nil {
                selected = active.first
            }
        }
        guard let item = selected, Self.canShow(item), let target = item.mask.bounds.first else { return nil }

        let showStart = Self.showStart(item)
        let end = item.mask.sourceEnd
        let opacity: Double
        if t < item.mask.sourceStart {
            opacity = Self.easeOut((t - showStart) / max(0.001, item.mask.sourceStart - showStart))
        } else if t <= end {
            opacity = 1
        } else {
            opacity = 1 - Self.easeOut((t - end) / 0.2)
        }

        var rect = target
        if let predecessor = items.last(where: { Self.canShow($0) && $0.mask.sourceEnd <= item.mask.sourceStart }),
           item.mask.sourceStart - predecessor.mask.sourceEnd < 0.4,
           let previousRect = predecessor.mask.bounds.first {
            let duration = max(0.001, item.mask.sourceStart - predecessor.mask.sourceEnd + (item.isGreedy ? 0 : 0.2))
            let progress = Self.easeOut((t - (item.mask.sourceStart - duration)) / duration)
            rect = Self.interpolate(previousRect, target, progress: progress)
        }
        return MaskFrameState(rect: rect, kind: item.mask.kind,
                              highlightOpacity: min(1, max(0, item.mask.highlightOpacity)),
                              opacity: min(1, max(0, opacity)), blur: max(0, item.mask.blur))
    }

    private static func valid(_ mask: TimelineMask) -> Bool {
        mask.sourceStart.isFinite && mask.sourceEnd.isFinite && mask.sourceStart <= mask.sourceEnd &&
            mask.bounds.allSatisfy { rect in
                [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) &&
                    rect.width >= 0 && rect.height >= 0
            }
    }

    private static func canShow(_ item: Item) -> Bool {
        !item.mask.isDisabled && !item.mask.bounds.isEmpty
    }

    private static func showStart(_ item: Item) -> Double {
        item.mask.sourceStart - (item.isGreedy ? 0.2 : 0)
    }

    private static func easeOut(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return 1 - pow(1 - x, 3)
    }

    private static func interpolate(_ a: CGRect, _ b: CGRect, progress p: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
               width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }
}

enum MaskRenderer {
    /// Composites a source-space mask. `blur` is interpreted as a Gaussian radius scaled by
    /// sourceHeight/1080 (viddeo choice); radius 16 is the observed rounded-rect border radius.
    static func apply(_ state: MaskFrameState, to image: CIImage, sourceExtent: CGRect) -> CIImage {
        guard state.opacity > 0, sourceExtent.width > 0, sourceExtent.height > 0 else { return image }
        let normalized = state.rect.standardized
        let rect = CGRect(x: sourceExtent.minX + normalized.minX * sourceExtent.width,
                          y: sourceExtent.maxY - normalized.maxY * sourceExtent.height,
                          width: normalized.width * sourceExtent.width,
                          height: normalized.height * sourceExtent.height)
        let radius = min(16, min(rect.width, rect.height) / 2)
        guard let shape = roundedMask(extent: sourceExtent, rect: rect, radius: radius,
                                      opacity: state.opacity) else { return image }
        switch state.kind {
        case .sensitiveData:
            let blurRadius = min(128, max(0, state.blur * sourceExtent.height / 1080))
            guard blurRadius > 0 else { return image }
            let clamped = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: sourceExtent)
            let blended = clamped.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image.cropped(to: sourceExtent),
                kCIInputMaskImageKey: shape
            ])
            return blended.cropped(to: sourceExtent)
        case .highlight:
            guard let outside = roundedMask(extent: sourceExtent, rect: rect, radius: radius,
                                            opacity: state.opacity, outside: true) else { return image }
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0,
                                                alpha: min(1, max(0, state.highlightOpacity))))
                .cropped(to: sourceExtent)
            let blackLayer = black.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: sourceExtent),
                kCIInputMaskImageKey: outside
            ])
            return blackLayer.composited(over: image.cropped(to: sourceExtent)).cropped(to: sourceExtent)
        }
    }

    private static func roundedMask(extent: CGRect, rect: CGRect, radius: CGFloat, opacity: Double,
                                    outside: Bool = false) -> CIImage? {
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let r = Double(radius)
        let box = rect.offsetBy(dx: -extent.minX, dy: -extent.minY)
        for y in 0..<height {
            for x in 0..<width {
                // Rect conversion above already maps top-left normalized bounds to CI bottom-left.
                let localY = Double(y) + 0.5 - Double(box.minY)
                let px = Double(x) + 0.5 - Double(box.minX)
                let qx = abs(px - Double(box.width) / 2) - (Double(box.width) / 2 - r)
                let qy = abs(localY - Double(box.height) / 2) - (Double(box.height) / 2 - r)
                let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
                let insideCoverage = min(1, max(0, 0.5 - distance))
                let coverage = (outside ? 1 - insideCoverage : insideCoverage) * opacity
                let index = (y * width + x) * 4
                let value = UInt8((coverage * 255).rounded())
                bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value; bytes[index + 3] = value
            }
        }
        let data = Data(bytes)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIImage(bitmapData: data, bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
