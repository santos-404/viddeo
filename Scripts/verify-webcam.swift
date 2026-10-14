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
        try testLayoutConfiguration()
        try testLegacyDecode()
        try testLayoutItems()
        try testSplitResolver()
        try testCutoutResolver()
        try testPlainLayoutsUnchanged()
        try testSplitRendering()
        try testCutoutRendering()
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

    // MARK: - Layouts

    static let landscape = CGSize(width: 1280, height: 720)
    static let portrait = CGSize(width: 720, height: 1280)

    static func overlay(_ size: CGSize = landscape, area: CGRect? = nil, gap: Double? = nil, radius: Double = 0,
                        _ configure: (inout WebcamConfiguration) -> Void = { _ in }) -> WebcamOverlay {
        var c = WebcamConfiguration()
        configure(&c)
        return WebcamOverlay(configuration: c, outputSize: size, layoutArea: area, paneGap: gap, paneCornerRadius: radius)
    }

    static func testLayoutConfiguration() throws {
        let c = WebcamConfiguration()
        try expect(c.split == SplitScreenOptions(direction: .auto, flip: false, screenRatio: nil, enablePadding: false),
                   "observed split defaults: auto, no flip, ratio null, no padding")
        try expect(c.cutout == CutoutCameraOptions(positionX: 1, sizeRatio: 0.5, zoomedScale: 0.8, aspectRatio: nil),
                   "observed cutout defaults: x 1, size 0.5, zoomed 0.8, aspect null")
        try expect(SplitScreenOptions.defaultScreenRatio == 0.5 && c.layoutItems.isEmpty, "viddeo default ratio 0.5, no items")
        try expect(WebcamLayout.allCases.count == 5 && WebcamLayout(rawValue: "splitScreen") == .splitScreen &&
                   WebcamLayout(rawValue: "cutoutCamera") == .cutoutCamera, "five layouts")
        var full = WebcamConfiguration()
        full.layout = .splitScreen
        full.split = SplitScreenOptions(direction: .vertical, flip: true, screenRatio: 0.6, enablePadding: true)
        full.cutout = CutoutCameraOptions(positionX: 0.25, sizeRatio: 0.4, zoomedScale: 0.7, aspectRatio: .custom(1.25))
        full.layoutItems = [CameraLayoutItem(startMs: 1000, endMs: 2500, layout: .cutoutCamera)]
        try full.validate()
        try expect(try JSONDecoder().decode(WebcamConfiguration.self, from: JSONEncoder().encode(full)) == full,
                   "layout options and items round trip")
        let invalid: [(inout WebcamConfiguration) -> Void] = [
            { $0.split.screenRatio = 0.05 }, { $0.split.screenRatio = 0.95 }, { $0.split.screenRatio = .nan },
            { $0.cutout.sizeRatio = 0 }, { $0.cutout.sizeRatio = 1.5 }, { $0.cutout.zoomedScale = 0 },
            { $0.cutout.zoomedScale = 1.2 }, { $0.cutout.positionX = 2 }, { $0.cutout.positionX = -0.1 },
            { $0.cutout.aspectRatio = .custom(0) }
        ]
        for (index, mutate) in invalid.enumerated() {
            var bad = WebcamConfiguration()
            mutate(&bad)
            try expect((try? bad.validate()) == nil, "invalid layout option \(index) rejected")
        }
    }

    static func testLegacyDecode() throws {
        // A file written before the layouts existed: none of the new keys.
        let legacy = """
        {"hide":false,"mirror":true,"aspectRatio":"horizontal","sizeRatio":0.4,"paddingRatio":0.5,\
        "position":{"x":0,"y":1},"borderRadiusRatio":0.15,"shape":"circle","shadow":false,"layout":"screenOnly"}
        """
        let decoded = try JSONDecoder().decode(WebcamConfiguration.self, from: Data(legacy.utf8))
        var expected = WebcamConfiguration()
        expected.mirror = true
        expected.aspectRatio = .horizontal
        expected.sizeRatio = 0.4
        expected.position = WebcamAnchor.bottomLeft.point
        expected.shape = .circle
        expected.shadow = false
        expected.layout = .screenOnly
        try expect(decoded == expected, "legacy file decodes unchanged with default layout options")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("verify-webcam-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("webcam-config.json"))
        try expect(try WebcamConfiguration.load(in: directory) == expected, "legacy webcam-config.json loads")
        try expected.save(in: directory)
        try expect(try WebcamConfiguration.load(in: directory) == expected, "legacy config re-saves and loads")
        let missingRequired = Data("{\"hide\":false}".utf8)
        try expect((try? JSONDecoder().decode(WebcamConfiguration.self, from: missingRequired)) == nil,
                   "old required keys are still required")
    }

    static func testLayoutItems() throws {
        let item = { (start: Double, end: Double, layout: WebcamLayout) in CameraLayoutItem(startMs: start, endMs: end, layout: layout) }
        var c = WebcamConfiguration()
        c.layoutItems = [item(1000, 2000, .splitScreen), item(3000, 4000, .cutoutCamera)]
        try c.validate()
        try expect(CameraLayoutItem.minimumDurationMs == 500, "observed 500 ms minimum")
        c.layoutItems = [item(0, 500, .splitScreen)]
        try c.validate()
        c.layoutItems = [item(0, 499.9, .splitScreen)]
        try expect((try? c.validate()) == nil, "an item shorter than 500 ms is rejected")
        c.layoutItems = [item(1000, 2000, .splitScreen), item(1999, 3000, .cutoutCamera)]
        try expect((try? c.validate()) == nil, "overlapping items are rejected")
        c.layoutItems = [item(3000, 4000, .splitScreen), item(1000, 2000, .cutoutCamera)]
        try c.validate()
        c.layoutItems = [item(1000, 2000, .splitScreen), item(2000, 3000, .cutoutCamera)]
        try c.validate()
        c.layoutItems = [item(-1, 1000, .splitScreen)]
        try expect((try? c.validate()) == nil, "a negative start is rejected")
        c.layoutItems = [item(1000, .infinity, .splitScreen)]
        try expect((try? c.validate()) == nil, "a non-finite end is rejected")
        let duplicate = item(1000, 2000, .splitScreen)
        c.layoutItems = [duplicate, CameraLayoutItem(id: duplicate.id, startMs: 3000, endMs: 4000, layout: .screenOnly)]
        try expect((try? c.validate()) == nil, "duplicate ids are rejected")

        c.layoutItems = [item(1000, 2000, .splitScreen), item(3000, 4000, .cutoutCamera)]
        try expect(c.layout(atMs: 999.9) == .cameraOverlay, "before an item: the default layout")
        try expect(c.layout(atMs: 1000) == .splitScreen && c.layout(atMs: 1999.9) == .splitScreen, "start inclusive")
        try expect(c.layout(atMs: 2000) == .cameraOverlay, "end exclusive")
        try expect(c.layout(atMs: 3500) == .cutoutCamera && c.layout(atMs: 9000) == .cameraOverlay, "second item, then default")
        try expect(c.layout(atMs: .nan) == .cameraOverlay, "non-finite time: default")
        try expect(c.usedLayouts == [.cameraOverlay, .splitScreen, .cutoutCamera], "used layouts: default plus items")
        let overlay = WebcamOverlay(configuration: c, outputSize: canvas)
        let frame = solid(CIColor(red: 0, green: 1, blue: 0))
        try expect(overlay.image(camera: frame, atMs: 1500, chunks: []) == nil, "the rounded overlay is hidden inside a split item")
        try expect(overlay.image(camera: frame, atMs: 2500, chunks: []) != nil, "and visible again outside it")
        try expect(overlay.layout(atMs: 3500) == .cutoutCamera, "the overlay resolves the layout by time")

        // Adding: at the playhead, clipped by the next item and the source duration, never below 500 ms.
        var edit = WebcamConfiguration()
        edit.layoutItems = [item(5000, 6000, .screenOnly)]
        let id = try edit.addLayoutItem(layout: .splitScreen, atMs: 4000, sourceDurationMs: 20_000)
        try expect(edit.layoutItems.count == 2 && edit.layoutItems[0].id == id && edit.layoutItems[0].endMs == 5000,
                   "a new item stops at the next item: \(edit.layoutItems)")
        try edit.validate()
        let tail = try edit.addLayoutItem(layout: .cutoutCamera, atMs: 7000, sourceDurationMs: 8000)
        try expect(edit.layoutItems.last?.id == tail && edit.layoutItems.last?.endMs == 8000, "a new item stops at the source end")
        for (time, why) in [(4500.0, "inside an item"), (4800.0, "under 500 ms before the next item"), (7800.0, "under 500 ms before the end")] {
            var rejected = false
            do { try edit.addLayoutItem(layout: .splitScreen, atMs: time, sourceDurationMs: 8000) } catch WebcamError.layoutChangeNoRoom { rejected = true }
            try expect(rejected, "no room \(why)")
        }
        edit.removeLayoutItem(id: id)
        try expect(edit.layoutItems.count == 2 && !edit.layoutItems.contains { $0.id == id }, "delete removes the item")
    }

    static func testSplitResolver() throws {
        let landscapeSplit = overlay { $0.layout = .splitScreen }
        let wide = landscapeSplit.splitPanes()
        try expect(wide.screen == CGRect(x: 0, y: 0, width: 640, height: 720) &&
                   wide.camera == CGRect(x: 640, y: 0, width: 640, height: 720), "landscape auto is side by side: \(wide)")
        let resolved = landscapeSplit.resolve(layout: .splitScreen, sourceAspect: 16.0 / 9.0, cameraAspect: 4.0 / 3.0)
        try expect(resolved.screen == CGRect(x: 0, y: 180, width: 640, height: 360), "screen is fitted in its pane: \(resolved.screen)")
        try expect(resolved.camera == wide.camera, "the camera fills its pane")

        let tall = overlay(portrait) { $0.layout = .splitScreen }.splitPanes()
        try expect(tall.screen == CGRect(x: 0, y: 640, width: 720, height: 640) &&
                   tall.camera == CGRect(x: 0, y: 0, width: 720, height: 640), "portrait auto is stacked, screen on top: \(tall)")
        let tallFit = overlay(portrait) { $0.layout = .splitScreen }
            .resolve(layout: .splitScreen, sourceAspect: 16.0 / 9.0, cameraAspect: 1).screen
        try expect(tallFit.width == 720 && tallFit.height == 405 && abs(tallFit.midY - 960) <= 1, "portrait screen fitted in the top pane: \(tallFit)")
        let square = overlay(CGSize(width: 800, height: 800)) { $0.layout = .splitScreen }.splitPanes()
        try expect(square.screen.width == 400 && square.screen.height == 800, "square (aspect ≥ 1) is side by side")

        let stacked = overlay { $0.split.direction = .vertical }.splitPanes()
        try expect(stacked.screen == CGRect(x: 0, y: 360, width: 1280, height: 360) &&
                   stacked.camera == CGRect(x: 0, y: 0, width: 1280, height: 360), "explicit vertical on a landscape canvas")
        let sideways = overlay(portrait) { $0.split.direction = .horizontal }.splitPanes()
        try expect(sideways.screen == CGRect(x: 0, y: 0, width: 360, height: 1280) &&
                   sideways.camera == CGRect(x: 360, y: 0, width: 360, height: 1280), "explicit horizontal on a portrait canvas")

        let flipped = overlay { $0.split.flip = true }.splitPanes()
        try expect(flipped.camera == CGRect(x: 0, y: 0, width: 640, height: 720) &&
                   flipped.screen == CGRect(x: 640, y: 0, width: 640, height: 720), "flip puts the camera left")
        let flippedStack = overlay { $0.split.flip = true; $0.split.direction = .vertical }.splitPanes()
        try expect(flippedStack.camera.minY == 360 && flippedStack.screen.minY == 0, "flip puts the camera on top when stacked")

        let ratio = overlay { $0.split.screenRatio = 0.3 }.splitPanes()
        try expect(ratio.screen.width == 384 && ratio.camera.width == 896 && ratio.camera.minX == 384, "screen ratio 0.3 of 1280: \(ratio)")
        let defaulted = overlay { $0.split.screenRatio = 0.5 }.splitPanes()
        try expect(defaulted.screen == wide.screen && defaulted.camera == wide.camera, "nil ratio means 0.5")
        let extreme = overlay { $0.split.screenRatio = 0.9 }.splitPanes()
        try expect(extreme.screen.width == 1152 && extreme.camera.width == 128, "ratio 0.9")

        // A stage area with padding: panes inside it; enablePadding adds the gap between them.
        let area = CGRect(x: 72, y: 72, width: 1136, height: 576)
        let flush = overlay(area: area, gap: 72) { $0.layout = .splitScreen }.splitPanes()
        try expect(flush.screen == CGRect(x: 72, y: 72, width: 568, height: 576) && flush.camera.minX == 640 &&
                   flush.camera.maxX == 1208, "without enablePadding the panes touch inside the stage area: \(flush)")
        let gapped = overlay(area: area, gap: 72) { $0.split.enablePadding = true }.splitPanes()
        try expect(gapped.screen.width == 532 && gapped.camera.width == 532 &&
                   gapped.camera.minX - gapped.screen.maxX == 72 && gapped.screen.minX == 72 && gapped.camera.maxX == 1208,
                   "enablePadding leaves the stage padding as a gap: \(gapped)")
        let gappedStack = overlay(area: area, gap: 72) { $0.split.enablePadding = true; $0.split.direction = .vertical }.splitPanes()
        try expect(gappedStack.screen.minY - gappedStack.camera.maxY == 72 && gappedStack.screen.maxY == 648 &&
                   gappedStack.camera.minY == 72, "stacked gap: \(gappedStack)")
        let defaultGap = overlay { $0.split.enablePadding = true }.splitPanes()
        try expect(defaultGap.camera.minX - defaultGap.screen.maxX == (0.03 * 720).rounded(), "no stage: the gap is 3 % of the short side")
        let outside = WebcamOverlay(outputSize: canvas, layoutArea: CGRect(x: 5000, y: 5000, width: 10, height: 10))
        try expect(outside.layoutArea == CGRect(origin: .zero, size: canvas), "an area outside the canvas falls back to the canvas")
        let odd = overlay(area: CGRect(x: 10.4, y: 20.6, width: 900.7, height: 500.3)).layoutArea
        try expect(odd == odd.integral && CGRect(x: 10.4, y: 20.6, width: 900.7, height: 500.3).contains(odd), "area is shrunk to whole pixels: \(odd)")
        let oddPanes = overlay(area: CGRect(x: 0, y: 0, width: 1001, height: 700)).splitPanes()
        try expect(oddPanes.screen.width + oddPanes.camera.width == 1001 && oddPanes.screen.maxX == oddPanes.camera.minX,
                   "odd widths still tile exactly: \(oddPanes)")
    }

    static func testCutoutResolver() throws {
        let rect = overlay { $0.layout = .cutoutCamera }.resolve(layout: .cutoutCamera, sourceAspect: 16.0 / 9.0, cameraAspect: 4.0 / 3.0)
        try expect(rect.camera == CGRect(x: 920, y: 0, width: 360, height: 270) && rect.screen == CGRect(origin: .zero, size: canvas),
                   "default cutout: 0.5 × 720 square, 4:3 inside it, right and bottom: \(String(describing: rect.camera))")
        let c = overlay { _ in }
        try expect(c.cutoutRect(cameraAspect: 3.0 / 4.0).size == CGSize(width: 270, height: 360), "a portrait camera fills the height")
        try expect(c.cutoutRect(cameraAspect: .nan).size == CGSize(width: 360, height: 360), "unknown camera aspect: square")
        try expect(overlay { $0.cutout.aspectRatio = .square }.cutoutRect(cameraAspect: 4.0 / 3.0).size == CGSize(width: 360, height: 360),
                   "explicit aspect overrides the camera's")
        try expect(overlay { $0.cutout.aspectRatio = .horizontal }.cutoutRect(cameraAspect: 1).size == CGSize(width: 360, height: 202),
                   "16:9 cutout")
        try expect(overlay { $0.cutout.positionX = 0 }.cutoutRect(cameraAspect: 1).minX == 0, "position 0 is the left edge")
        try expect(overlay { $0.cutout.positionX = 0.5 }.cutoutRect(cameraAspect: 1).midX == 640, "position 0.5 centers")
        try expect(overlay { $0.cutout.sizeRatio = 0.25 }.cutoutRect(cameraAspect: 1).width == 180, "size ratio scales the short side")
        try expect(c.cutoutRect(cameraAspect: 1, zoomScale: 2).width == 288, "zoomed scale 0.8 at 2x zoom: 360 × 0.8")
        try expect(c.cutoutRect(cameraAspect: 1, zoomScale: 1.5).width == 324, "halfway through the zoom blend")
        try expect(c.cutoutRect(cameraAspect: 1, zoomScale: 5).width == 288 && c.cutoutRect(cameraAspect: 1, zoomScale: .nan).width == 360,
                   "the blend is clamped; a non-finite zoom is unzoomed")
        let staged = overlay(area: CGRect(x: 72, y: 72, width: 1136, height: 576)).cutoutRect(cameraAspect: 1)
        try expect(staged == CGRect(x: 920, y: 72, width: 288, height: 288), "inside a stage area: its bottom-right, 0.5 × 576: \(staged)")
        let tall = overlay(portrait).cutoutRect(cameraAspect: 1)
        try expect(tall == CGRect(x: 360, y: 0, width: 360, height: 360), "portrait: shortest side 720")
    }

    static func testPlainLayoutsUnchanged() throws {
        let plain = overlay { _ in }
        let r = plain.resolve(layout: .cameraOverlay, sourceAspect: 16.0 / 9.0, cameraAspect: 4.0 / 3.0)
        try expect(r.camera == plain.rect(cameraAspect: 4.0 / 3.0) && r.screen == plain.contentRect, "overlay resolves to the existing rect")
        let staged = WebcamOverlay(outputSize: canvas, contentRect: CGRect(x: 64, y: 36, width: 1152, height: 648))
        try expect(staged.resolve(layout: .cameraOverlay, sourceAspect: 1, cameraAspect: 1).screen == staged.contentRect, "screen stays at the content rect")
        try expect(plain.resolve(layout: .fullscreenCamera, sourceAspect: 1, cameraAspect: 1).camera == plain.bounds, "fullscreen camera: the canvas")
        try expect(plain.resolve(layout: .screenOnly, sourceAspect: 1, cameraAspect: 1).camera == nil, "screen-only: no camera")
        try expect(plain.layout(atMs: 12345) == .cameraOverlay, "no items: the default layout everywhere")
    }

    static func testSplitRendering() throws {
        let red = CIColor(red: 1, green: 0, blue: 0), black = CIColor(red: 0, green: 0, blue: 0)
        let o = overlay(radius: 20) { $0.layout = .splitScreen; $0.mirror = false }
        let layout = o.resolve(layout: .splitScreen, sourceAspect: 16.0 / 9.0, cameraAspect: 4.0 / 3.0)
        let screen = solid(red, width: layout.screen.width, height: layout.screen.height)
            .transformed(by: CGAffineTransform(translationX: layout.screen.minX, y: layout.screen.minY))
        let background = solid(black, width: 1280, height: 720)
        let image = o.splitFrame(layout, screen: screen, camera: twoColor(), background: background)
        try expect(image.extent == CGRect(origin: .zero, size: canvas), "split frame is canvas-sized")
        let bitmap = try render(image)
        try expect(bitmap.isColor(320, 360, 255, 0, 0), "screen colour in the left pane")
        try expect(bitmap.isColor(640 + 160, 360, 255, 0, 0) && bitmap.isColor(640 + 480, 360, 0, 0, 255),
                   "camera colours (red | blue) in the right pane")
        try expect(bitmap.isColor(320, 100, 0, 0, 0) && bitmap.isColor(320, 620, 0, 0, 0), "background above and below the fitted screen")
        try expect(bitmap.isColor(2, 2, 0, 0, 0) || !bitmap.isColor(2, 2, 255, 0, 0), "pane corners are rounded")
        try expect(bitmap.isColor(1279 - 2, 360, 0, 0, 255), "camera fills to the pane edge")
        let noCamera = try render(o.splitFrame(layout, screen: screen, camera: nil, background: background))
        try expect(noCamera.isColor(960, 360, 0, 0, 0), "no camera: the pane shows the background")
        var mirrored = WebcamConfiguration()
        mirrored.layout = .splitScreen
        mirrored.mirror = true
        let flippedOverlay = WebcamOverlay(configuration: mirrored, outputSize: canvas, paneCornerRadius: 0)
        let mirroredBitmap = try render(flippedOverlay.splitFrame(layout, screen: screen, camera: twoColor(), background: background))
        try expect(mirroredBitmap.isColor(640 + 160, 360, 0, 0, 255) && mirroredBitmap.isColor(640 + 480, 360, 255, 0, 0),
                   "mirror applies to the camera pane")
    }

    static func testCutoutRendering() throws {
        let o = overlay { $0.layout = .cutoutCamera }
        let rect = o.cutoutRect(cameraAspect: 4.0 / 3.0)
        // A mask at another size than the camera: white on its left half.
        let mask = solid(CIColor(red: 1, green: 1, blue: 1), width: 32, height: 48)
            .composited(over: solid(CIColor(red: 0, green: 0, blue: 0), width: 64, height: 48))
        let image = o.cutout(camera: twoColor(), mask: mask, rect: rect)
        try expect(image.extent == CGRect(origin: .zero, size: canvas), "cutout is canvas-sized")
        let bitmap = try render(image)
        try expect(bitmap.isColor(rect.minX + rect.width / 4, rect.midY, 255, 0, 0), "person pixels keep the camera colour")
        try expect(bitmap.isClear(rect.maxX - rect.width / 4, rect.midY), "background pixels of the mask are transparent")
        try expect(bitmap.isClear(rect.minX + 2, rect.minY + 2) == false, "no rounded corners on the cutout")
        try expect(bitmap.isClear(rect.minX - 5, rect.midY) && bitmap.isClear(10, 10), "outside the rect is transparent")
        var mirrored = WebcamConfiguration()
        mirrored.mirror = true
        let m = WebcamOverlay(configuration: mirrored, outputSize: canvas)
        let mirroredBitmap = try render(m.cutout(camera: twoColor(), mask: mask, rect: rect))
        try expect(mirroredBitmap.isClear(rect.minX + rect.width / 4, rect.midY) &&
                   mirroredBitmap.isColor(rect.maxX - rect.width / 4, rect.midY, 255, 0, 0), "mask mirrors with the camera")
        let empty = try render(o.cutout(camera: twoColor(), mask: CIImage.empty(), rect: rect))
        try expect(empty.isClear(rect.midX, rect.midY), "an empty mask draws nothing")
        let fallback = try render(o.roundedOverlay(camera: twoColor()) ?? CIImage.empty())
        let overlayRect = o.rect(cameraAspect: 4.0 / 3.0)
        try expect(fallback.pixel(overlayRect.midX, overlayRect.midY).a > 0, "the fallback overlay draws the rounded camera")
    }
}
