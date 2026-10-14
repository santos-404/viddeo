import CoreImage
import CoreVideo
import Foundation
import Vision

/// Quality of the on-device person segmentation: `.balanced` for exports, `.fast` for the editor preview.
enum CutoutQuality: Sendable {
    case balanced, fast
}

/// Apple Vision person segmentation (`VNGeneratePersonSegmentationRequest`), run on device.
enum PersonSegmenter {
    /// A person must cover at least this fraction of the mask for it to count; below it the frame has no person
    /// (a flat or empty frame yields an all-black mask rather than an error).
    static let minimumCoverage = 0.005

    /// A white-is-person mask (its own, smaller size) for `frame`, or nil when Vision fails or sees no person.
    static func mask(for frame: CIImage, quality: CutoutQuality) -> CIImage? {
        let extent = frame.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality == .balanced ? .balanced : .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let normalized = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        do {
            try VNImageRequestHandler(ciImage: normalized, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer, coverage(of: buffer) >= minimumCoverage else { return nil }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    }

    /// Fraction of pixels at or above 50 % in an 8-bit one-component mask; 1 for any other format (not checked).
    static func coverage(of buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return 1 }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return 0 }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var covered = 0
        for row in 0..<height {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width where line[column] >= 128 { covered += 1 }
        }
        return Double(covered) / Double(width * height)
    }
}

/// Person masks for one export (or preview), cached per camera frame. Frames are identified by their decoded
/// pixel buffer: output frames that fall on the same camera frame share one segmentation (the cache keeps the
/// buffer alive, so its identity cannot be reused). Images that are not backed by a buffer are keyed by source time
/// in whole milliseconds. A frame with no mask is cached as such and recorded in `fallbackTimes`; the renderer
/// then draws the rounded camera overlay for it. Nothing here throws.
final class CutoutMaskCache: @unchecked Sendable {
    typealias Segmenter = @Sendable (CIImage) -> CIImage?

    /// Frames kept; sequential export only ever revisits the latest few.
    static let capacity = 16
    /// Fallback times kept for reporting; `fallbackFrameCount` keeps counting past it.
    static let maximumRecordedFallbacks = 10_000

    private struct Entry {
        var buffer: CVPixelBuffer?
        var milliseconds: Int
        var mask: CIImage?
    }

    private let segmenter: Segmenter
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var runs = 0
    private var fallbackFrames = 0
    private var fallbacks: [Double] = []

    init(quality: CutoutQuality) {
        segmenter = { PersonSegmenter.mask(for: $0, quality: quality) }
    }

    /// A custom segmenter, for tests.
    init(segmenter: @escaping Segmenter) {
        self.segmenter = segmenter
    }

    /// The person mask for `camera`, shown at source time `timeMs`, or nil (recorded as a fallback).
    func mask(for camera: CIImage, atMs timeMs: Double) -> CIImage? {
        let buffer = camera.pixelBuffer
        let milliseconds = timeMs.isFinite ? Int(timeMs.rounded()) : 0
        let cached: Entry? = lock.withLock {
            entries.first { entry in
                if let buffer { return entry.buffer === buffer }
                return entry.buffer == nil && entry.milliseconds == milliseconds
            }
        }
        let mask: CIImage?
        if let cached {
            mask = cached.mask
        } else {
            mask = segmenter(camera)
            lock.withLock {
                runs += 1
                entries.append(Entry(buffer: buffer, milliseconds: milliseconds, mask: mask))
                if entries.count > Self.capacity { entries.removeFirst() }
            }
        }
        if mask == nil {
            lock.withLock {
                fallbackFrames += 1
                if fallbacks.count < Self.maximumRecordedFallbacks { fallbacks.append(timeMs) }
            }
        }
        return mask
    }

    /// Segmentation requests actually run (cache misses).
    var segmentationRuns: Int { lock.withLock { runs } }
    /// Rendered frames that used the camera-overlay fallback.
    var fallbackFrameCount: Int { lock.withLock { fallbackFrames } }
    /// Source times (ms) of the fallback frames, up to `maximumRecordedFallbacks`.
    var fallbackTimes: [Double] { lock.withLock { fallbacks } }
}
