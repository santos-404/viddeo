import CoreGraphics
import CoreImage
import Foundation

@main
struct VerifyWebcam {
    nonisolated(unsafe) static var checks = 0
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let canvas = CGSize(width: 1280, height: 720)

    static func main() throws {
        try testDefaults()
        try testCodingAndValidation()
        try testLoadFallback()
        try testAnchorSnapping()
        try testRectSizeAndAspect()
        try testPlacementForEveryAnchor()
        try testHideRule()
        try testRendering()
        try testMirrorAndShapes()
        try testHiddenAndFullscreen()
        try testDeterminism()
        _ = compileOnlyRecorderReference as (WebcamRecorder) async throws -> WebcamCaptureMetadata
        print("Webcam verified: \(checks) checks")
    }

    /// Compile-only: the recorder needs a camera and permission, so it is never started here.
    static func compileOnlyRecorderReference(_ recorder: WebcamRecorder) async throws -> WebcamCaptureMetadata {
        try await recorder.start(directory: URL(fileURLWithPath: NSTemporaryDirectory()), epoch: nil)
        return try await recorder.stop()
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw Failure(message: message) }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { "FAILED: \(message)" }
    }

    // MARK: - Configuration

    static func testDefaults() throws {
        let c = WebcamConfiguration()
        try expect(c.hide == false && c.mirror == false, "observed hide/mirror default false")
        try expect(c.aspectRatio == .square && c.aspectRatio.value == 1, "observed aspectRatio 1")
        try expect(c.sizeRatio == 0.35, "observed size ratio 0.35")
        try expect(c.paddingRatio == 0.5, "observed padding ratio 0.5")
        try expect(c.borderRadiusRatio == 0.15, "observed border radius ratio 0.15")
        try expect(c.hideDuringSilenceMs == nil, "observed hideDuringSilenceMs null")
        try expect(c.position == WebcamPosition(x: 1, y: 1) && c.anchor == .bottomRight, "default bottom-right")
        try expect(c.layout == .cameraOverlay, "observed default layout camera-overlay")
        try expect(WebcamOverlay.silenceEdgeMs == 500, "observed 500 ms silence edge")
        try c.validate()
    }

    static func testCodingAndValidation() throws {
        var c = WebcamConfiguration()
        c.aspectRatio = .vertical
        c.hideDuringSilenceMs = 1500
        c.shape = .circle
        let data = try JSONEncoder().encode(c)
        try expect(try JSONDecoder().decode(WebcamConfiguration.self, from: data) == c, "JSON round trip")
        let json = try String(decoding: JSONEncoder().encode([WebcamAspectRatio.horizontal, .custom(1.5)]), as: UTF8.self)
        try expect(json == "[\"horizontal\",1.5]", "aspect presets encode by name, custom by number: \(json)")
        let decoded = try JSONDecoder().decode([WebcamAspectRatio].self, from: Data("[1, \"original\", 0.5625, 2]".utf8))
        try expect(decoded == [.square, .original, .vertical, .custom(2)], "aspect decodes names and numbers")
        try expect((try? JSONDecoder().decode([WebcamAspectRatio].self, from: Data("[\"wide\"]".utf8))) == nil,
                   "unknown aspect name rejected")
        let invalid: [(inout WebcamConfiguration) -> Void] = [
            { $0.sizeRatio = 0 }, { $0.sizeRatio = 1.5 }, { $0.sizeRatio = .nan },
            { $0.paddingRatio = -1 }, { $0.position = WebcamPosition(x: 1.2, y: 0) },
            { $0.borderRadiusRatio = 0.6 }, { $0.hideDuringSilenceMs = -1 },
            { $0.hideDuringSilenceMs = .infinity }, { $0.aspectRatio = .custom(0) }
        ]
        for (index, mutate) in invalid.enumerated() {
            var bad = WebcamConfiguration()
            mutate(&bad)
            try expect((try? bad.validate()) == nil, "invalid configuration \(index) rejected")
        }
        var bad = WebcamConfiguration()
        bad.sizeRatio = 2
        try expect(WebcamOverlay(configuration: bad, outputSize: canvas).configuration == WebcamConfiguration(),
                   "overlay falls back to defaults for invalid configuration")
    }

    static func testLoadFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("verify-webcam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(try WebcamConfiguration.load(in: directory) == WebcamConfiguration(), "missing file loads defaults")
        var c = WebcamConfiguration()
        c.mirror = true
        c.position = WebcamPosition(x: 0, y: 0)
        try c.save(in: directory)
        try expect(try WebcamConfiguration.load(in: directory) == c, "saved configuration loads back")
        var bad = WebcamConfiguration()
        bad.sizeRatio = 3
        let encoder = JSONEncoder()
        try encoder.encode(bad).write(to: directory.appendingPathComponent("webcam-config.json"))
        var rejected = false
        do { _ = try WebcamConfiguration.load(in: directory) } catch WebcamError.invalidConfiguration { rejected = true }
        try expect(rejected, "invalid persisted configuration throws invalidConfiguration")
    }

    static func testAnchorSnapping() throws {
        for anchor in WebcamAnchor.allCases {
            try expect(WebcamAnchor.nearest(to: anchor.point) == anchor, "anchor \(anchor) snaps to itself")
        }
        let cases: [(Double, Double, WebcamAnchor)] = [
            (0.4, 0.9, .bottom), (0.9, 0.1, .topRight), (0.1, 0.45, .left), (0.8, 0.6, .right),
            (0.2, 0.2, .topLeft), (0.6, 0.05, .top), (0.05, 0.95, .bottomLeft), (0.8, 0.85, .bottomRight), (0.7, 0.8, .bottom)
        ]
        for (x, y, anchor) in cases {
            try expect(WebcamAnchor.nearest(to: WebcamPosition(x: x, y: y)) == anchor, "(\(x), \(y)) snaps to \(anchor)")
        }
        try expect(WebcamAnchor.nearest(to: WebcamPosition(x: 0.5, y: 0.5)) == .top, "center tie resolves to first anchor")
    }

    // MARK: - Geometry

    static func testRectSizeAndAspect() throws {
        let overlay = WebcamOverlay(outputSize: canvas)
        let square = overlay.rect(cameraAspect: 16.0 / 9.0)
        try expect(square.width == 448 && square.height == 448, "square default is 0.35 × 1280 = 448: \(square)")
        var c = WebcamConfiguration()
        c.aspectRatio = .horizontal
        let wide = WebcamOverlay(configuration: c, outputSize: canvas).rect(cameraAspect: 1)
        try expect(wide.width == 448 && wide.height == 252, "16:9 is 448 × 252: \(wide)")
        c.aspectRatio = .original
        let original = WebcamOverlay(configuration: c, outputSize: canvas).rect(cameraAspect: 4.0 / 3.0)
        try expect(original.width == 448 && original.height == 336, "original uses camera aspect 4:3: \(original)")
        c.aspectRatio = .vertical
        let tall = WebcamOverlay(configuration: c, outputSize: canvas).rect(cameraAspect: 1)
        let tallPadding = (0.05 * tall.width).rounded()
        try expect(tall.height + 2 * tallPadding <= 720 && abs(tall.width / tall.height - 9.0 / 16.0) < 0.01,
                   "9:16 shrinks to fit the canvas with padding: \(tall)")
        c = WebcamConfiguration()
        c.shape = .circle
        c.aspectRatio = .horizontal
        let circle = WebcamOverlay(configuration: c, outputSize: canvas).rect(cameraAspect: 1)
        try expect(circle.width == circle.height, "circle forces a square rect")
        let content = CGRect(x: 64, y: 36, width: 1152, height: 648)
        let staged = WebcamOverlay(outputSize: canvas, contentRect: content).rect(cameraAspect: 1)
        try expect(abs(staged.width - 0.35 * 1152) <= 2 && staged.width == staged.height,
                   "size is a fraction of the content width: \(staged)")
    }

    static func testPlacementForEveryAnchor() throws {
        let contents = [CGRect(x: 0, y: 0, width: 1280, height: 720), CGRect(x: 64, y: 36, width: 1152, height: 648),
                        CGRect(x: 10.5, y: 20.25, width: 900.7, height: 500.3)]
        for content in contents {
            for anchor in WebcamAnchor.allCases {
                var c = WebcamConfiguration()
                c.position = anchor.point
                let rect = WebcamOverlay(configuration: c, outputSize: canvas, contentRect: content).rect(cameraAspect: 1)
                let padding = (0.5 * WebcamConfiguration.paddingUnit * 0.35 * content.width).rounded()
                let integral = rect == rect.integral && Int(rect.width) % 2 == 0 && Int(rect.height) % 2 == 0
                let inside = content.contains(rect)
                let dx: Bool = switch anchor.point.x {
                case 0: abs(rect.minX - content.minX - padding) < 1
                case 1: abs(content.maxX - rect.maxX - padding) < 1
                default: abs(rect.midX - content.midX) <= 1
                }
                let dy: Bool = switch anchor.point.y {
                case 1: abs(rect.minY - content.minY - padding) < 1
                case 0: abs(content.maxY - rect.maxY - padding) < 1
                default: abs(rect.midY - content.midY) <= 1
                }
                try expect(integral && inside && dx && dy, "\(anchor) in \(content): \(rect) padding \(padding)")
            }
        }
    }

    // MARK: - Hide rule

    static func testHideRule() throws {
        let chunk = [SilenceChunk(startMs: 1000, endMs: 4000)]
        let hidden = { (t: Double, chunks: [SilenceChunk], ms: Double?) in
            WebcamOverlay.isHiddenBySilence(atMs: t, chunks: chunks, hideDuringSilenceMs: ms)
        }
        try expect(!hidden(2500, chunk, nil), "nil hideDuringSilenceMs never hides")
        try expect(hidden(2500, chunk, 2000), "inside a long chunk, far from edges → hidden")
        try expect(hidden(2500, chunk, 3000), "chunk exactly hideDuringSilenceMs long → hidden")
        try expect(!hidden(2500, chunk, 3001), "chunk shorter than hideDuringSilenceMs → visible")
        try expect(!hidden(1400, chunk, 1000), "within 500 ms of the start → visible")
        try expect(!hidden(1500, chunk, 1000), "exactly 500 ms from the start → visible")
        try expect(hidden(1501, chunk, 1000), "just over 500 ms from the start → hidden")
        try expect(!hidden(3600, chunk, 1000), "within 500 ms of the end → visible")
        try expect(!hidden(500, chunk, 1000) && !hidden(5000, chunk, 1000), "outside every chunk → visible")
        try expect(!hidden(1000, [SilenceChunk(startMs: 0, endMs: 900)], 0), "chunk under 1 s never hides")
        let two = [SilenceChunk(startMs: 0, endMs: 1200), SilenceChunk(startMs: 5000, endMs: 9000)]
        try expect(hidden(7000, two, 2000) && !hidden(600, two, 2000), "only the long chunk hides")
    }

    // MARK: - Rendering

    static func solid(_ color: CIColor, width: Double = 640, height: Double = 480) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Left half red, right half blue.
    static func twoColor() -> CIImage {
        solid(CIColor(red: 1, green: 0, blue: 0), width: 320)
            .composited(over: solid(CIColor(red: 0, green: 0, blue: 1)))
    }

    struct Bitmap {
        let width: Int, height: Int, bytes: [UInt8]
        /// Core Image coordinates (y up).
        func pixel(_ x: Double, _ y: Double) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let row = height - 1 - Int(y), column = Int(x)
            let i = (row * width + column) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
        func isColor(_ x: Double, _ y: Double, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
            let p = pixel(x, y)
            return abs(Int(p.r) - Int(r)) <= 2 && abs(Int(p.g) - Int(g)) <= 2 && abs(Int(p.b) - Int(b)) <= 2 && p.a == 255
        }
        func isClear(_ x: Double, _ y: Double) -> Bool { pixel(x, y).a == 0 }
    }

    static func render(_ image: CIImage) throws -> Bitmap {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let cg = context.createCGImage(image, from: CGRect(origin: .zero, size: canvas), format: .RGBA8, colorSpace: sRGB)
        else { throw Failure(message: "render failed") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: sRGB,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure(message: "bitmap context failed") }
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    static func testRendering() throws {
        var c = WebcamConfiguration()
        c.shadow = false
        let overlay = WebcamOverlay(configuration: c, outputSize: canvas)
        guard let image = overlay.image(camera: solid(CIColor(red: 0, green: 1, blue: 0)), atMs: 0, chunks: []) else {
            throw Failure(message: "visible overlay returned nil")
        }
        try expect(image.extent == CGRect(origin: .zero, size: canvas), "overlay is canvas-sized: \(image.extent)")
        let rect = overlay.rect(cameraAspect: 4.0 / 3.0)
        let bitmap = try render(image)
        try expect(bitmap.isColor(rect.midX, rect.midY, 0, 255, 0), "inside the rect is the camera color")
        try expect(bitmap.isColor(rect.minX + 2, rect.midY, 0, 255, 0) && bitmap.isColor(rect.maxX - 2, rect.midY, 0, 255, 0),
                   "aspect-fill covers the full rect width")
        try expect(bitmap.isClear(10, 10) && bitmap.isClear(rect.minX - 3, rect.midY) && bitmap.isClear(rect.midX, rect.maxY + 3),
                   "outside the rect is transparent")
        try expect(bitmap.isClear(rect.minX + 2, rect.maxY - 2) && bitmap.isClear(rect.maxX - 2, rect.minY + 2),
                   "rounded corners are transparent")
        let radius = 0.15 * rect.width
        try expect(bitmap.isColor(rect.minX + radius, rect.maxY - 2, 0, 255, 0), "edge past the corner radius is opaque")

        c.shadow = true
        let shadowed = try render(WebcamOverlay(configuration: c, outputSize: canvas)
            .image(camera: solid(CIColor(red: 0, green: 1, blue: 0)), atMs: 0, chunks: []) ?? CIImage.empty())
        let below = shadowed.pixel(rect.midX, rect.minY - 4)
        try expect(below.a > 0 && below.a < 255 && below.g == 0, "shadow is a soft translucent dark edge")
        try expect(shadowed.isClear(10, 10), "shadow leaves the far canvas transparent")
    }

    static func testMirrorAndShapes() throws {
        var c = WebcamConfiguration()
        c.shadow = false
        c.aspectRatio = .original
        let plain = WebcamOverlay(configuration: c, outputSize: canvas)
        let rect = plain.rect(cameraAspect: 4.0 / 3.0)
        let normal = try render(plain.image(camera: twoColor(), atMs: 0, chunks: []) ?? CIImage.empty())
        try expect(normal.isColor(rect.minX + rect.width / 4, rect.midY, 255, 0, 0) &&
                   normal.isColor(rect.maxX - rect.width / 4, rect.midY, 0, 0, 255), "unmirrored: red left, blue right")
        c.mirror = true
        let mirrored = try render(WebcamOverlay(configuration: c, outputSize: canvas)
            .image(camera: twoColor(), atMs: 0, chunks: []) ?? CIImage.empty())
        try expect(mirrored.isColor(rect.minX + rect.width / 4, rect.midY, 0, 0, 255) &&
                   mirrored.isColor(rect.maxX - rect.width / 4, rect.midY, 255, 0, 0), "mirror flips horizontally")

        c = WebcamConfiguration()
        c.shadow = false
        c.shape = .circle
        let circleOverlay = WebcamOverlay(configuration: c, outputSize: canvas)
        let square = circleOverlay.rect(cameraAspect: 1)
        let circle = try render(circleOverlay.image(camera: solid(CIColor(red: 0, green: 1, blue: 0)), atMs: 0, chunks: [])
                                ?? CIImage.empty())
        let inset = 0.1 * square.width
        try expect(circle.isColor(square.midX, square.midY, 0, 255, 0) &&
                   circle.isColor(square.minX + 3, square.midY, 0, 255, 0), "circle center and edge midpoint are opaque")
        try expect(circle.isClear(square.minX + inset, square.minY + inset) &&
                   circle.isClear(square.maxX - inset, square.maxY - inset), "circle mask clears square corners")
    }

    static func testHiddenAndFullscreen() throws {
        let frame = solid(CIColor(red: 0, green: 1, blue: 0))
        var c = WebcamConfiguration()
        c.hide = true
        try expect(WebcamOverlay(configuration: c, outputSize: canvas).image(camera: frame, atMs: 0, chunks: []) == nil,
                   "hide → nil")
        c = WebcamConfiguration()
        c.layout = .screenOnly
        try expect(WebcamOverlay(configuration: c, outputSize: canvas).image(camera: frame, atMs: 0, chunks: []) == nil,
                   "screen-only → nil")
        c = WebcamConfiguration()
        c.hideDuringSilenceMs = 1000
        let silent = WebcamOverlay(configuration: c, outputSize: canvas)
        let chunks = [SilenceChunk(startMs: 0, endMs: 3000)]
        try expect(silent.image(camera: frame, atMs: 1500, chunks: chunks) == nil &&
                   silent.image(camera: frame, atMs: 200, chunks: chunks) != nil, "silence rule hides mid-chunk only")
        c = WebcamConfiguration()
        c.layout = .fullscreenCamera
        let full = WebcamOverlay(configuration: c, outputSize: canvas)
        try expect(full.image(camera: frame, atMs: 0, chunks: []) == nil, "fullscreen layout has no overlay")
        let filled = full.fullscreen(camera: frame)
        try expect(filled.extent == CGRect(origin: .zero, size: canvas), "fullscreen is canvas-sized")
        let bitmap = try render(filled)
        try expect([(0.0, 0.0), (1279, 0), (0, 719), (1279, 719), (640, 360)].allSatisfy { bitmap.isColor($0.0, $0.1, 0, 255, 0) },
                   "fullscreen fills the canvas")
    }

    static func testDeterminism() throws {
        var c = WebcamConfiguration()
        c.mirror = true
        let overlay = WebcamOverlay(configuration: c, outputSize: canvas)
        let first = try render(overlay.image(camera: twoColor(), atMs: 0, chunks: []) ?? CIImage.empty())
        let second = try render(overlay.image(camera: twoColor(), atMs: 0, chunks: []) ?? CIImage.empty())
        try expect(first.bytes == second.bytes, "repeat renders are byte-identical")
        try expect(overlay.rect(cameraAspect: 1) == overlay.rect(cameraAspect: 1), "rect is deterministic")
    }
}
