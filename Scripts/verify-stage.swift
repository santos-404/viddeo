import CoreGraphics
import CoreImage
import Foundation

@main
struct VerifyStage {
    nonisolated(unsafe) static var checks = 0
    static let output = CGSize(width: 1280, height: 720)
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let context = CIContext(options: [.outputColorSpace: sRGB])
    static let contentColor = (r: 0.2, g: 0.8, b: 0.4)

    static func main() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-verify-stage-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-verify-stage-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: outside)
        }
        try verifyDefaults()
        try verifyValidation()
        try verifyPersistence(in: temp)
        try verifyStageRect()
        try verifyDeviceFrames()
        try verifyComposition()
        try verifyGradients()
        try verifyWallpapers()
        try verifyImageBackground(in: temp, outside: outside)
        print("Stage verified: \(checks) checks")
    }

    // MARK: - Model

    static func verifyDefaults() throws {
        let style = StageStyle()
        try check(style.paddingRatio == 0.1, "default padding is not 0.1")
        try check(style.cornerRadius == 16, "default corner radius is not 16")
        try check(style.shadow.intensity == 0.3, "default shadow intensity is not 0.3")
        try check(style.shadow.distance == 25, "default shadow distance is not 25")
        try check(style.shadow.angle == 45, "default shadow angle is not 45")
        try check(style.shadow.blur == 20, "default shadow blur is not 20")
        try check(style.shadow.isDirectional, "default shadow is not directional")
        try check(style.inset.size == 0, "default inset size is not 0")
        try check(style.inset.alpha == 0.5, "default inset alpha is not 0.5")
        try check(style.inset.color == "#000000", "default inset color is not #000000")
        try check(style.backgroundBlur == 0, "default background blur is not 0")
        guard case .gradient(let stops, let start, let end) = style.background else {
            throw Failure("default background is not a gradient")
        }
        try check(stops.map(\.color) == ["#4776e6", "#8e54e9"] && stops.map(\.location) == [0, 1],
                  "default gradient stops differ from the observed pair")
        try check(start == StagePoint(x: 0, y: 0) && end == StagePoint(x: 1, y: 1),
                  "default gradient direction is not (0,0)→(1,1)")
        try check((try? style.validate()) != nil, "defaults do not validate")

        let presets = StageStyle.gradientPresets
        try check(presets.count == 8 && Set(presets.map(\.name)).count == 8, "expected 8 uniquely named presets")
        try check(presets.allSatisfy { (2...3).contains($0.stops.count) && (try? StageStyle(background: $0.background).validate()) != nil },
                  "a preset has an invalid stop list")
        try check(presets.contains { $0.stops.map(\.color) == ["#4776e6", "#8e54e9"] },
                  "presets do not include the default pair")
    }

    static func verifyValidation() throws {
        func rejects(_ name: String, _ edit: (inout StageStyle) -> Void) throws {
            var style = StageStyle()
            edit(&style)
            do {
                try style.validate()
                throw Failure("validation accepted \(name)")
            } catch is StageError { checks += 1 }
        }
        try rejects("padding 0.5") { $0.paddingRatio = 0.5 }
        try rejects("NaN padding") { $0.paddingRatio = .nan }
        try rejects("radius 300") { $0.cornerRadius = 300 }
        try rejects("shadow intensity 1.5") { $0.shadow.intensity = 1.5 }
        try rejects("shadow blur 150") { $0.shadow.blur = 150 }
        try rejects("background blur 150") { $0.backgroundBlur = 150 }
        try rejects("malformed inset hex") { $0.inset.color = "#zzz000" }
        try rejects("malformed color hex") { $0.background = .color("4776e6") }
        try rejects("one stop") { $0.background = .gradient(stops: [GradientStop(color: "#000000", location: 0)],
                                                             start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 1)) }
        try rejects("unsorted stops") { $0.background = .gradient(
            stops: [GradientStop(color: "#000000", location: 0.8), GradientStop(color: "#ffffff", location: 0.2)],
            start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 1)) }
        try rejects("stop outside 0–1") { $0.background = .gradient(
            stops: [GradientStop(color: "#000000", location: 0), GradientStop(color: "#ffffff", location: 1.5)],
            start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 1)) }
        try rejects("traversal image path") { $0.background = .image("../secret.png") }
        try rejects("absolute image path") { $0.background = .image("/tmp/x.png") }
        try rejects("nested image path") { $0.background = .image("a/b.png") }
        try rejects("unknown wallpaper") { $0.background = .wallpaper("san-francisco") }
    }

    static func verifyPersistence(in directory: URL) throws {
        try check(try StageStyle.load(in: directory) == StageStyle(), "absent stage-config.json did not fall back to defaults")
        let encoder = JSONEncoder()
        for background in [StageBackground.standard, .color("#112233"), .image("bg.png"), .wallpaper("dusk")] {
            let style = StageStyle(paddingRatio: 0.2, cornerRadius: 30, background: background, backgroundBlur: 5)
            let decoded = try JSONDecoder().decode(StageStyle.self, from: encoder.encode(style))
            try check(decoded == style, "JSON roundtrip changed \(background)")
        }
        var custom = StageStyle(background: .wallpaper("mint"))
        custom.shadow.isDirectional = false
        custom.inset.size = 4
        try custom.save(in: directory)
        try check(try StageStyle.load(in: directory) == custom, "saved style did not load back")

        let file = directory.appendingPathComponent("stage-config.json")
        try Data("{ not json".utf8).write(to: file)
        try check((try? StageStyle.load(in: directory)) == nil, "malformed stage-config.json was accepted")
        var invalid = String(decoding: try encoder.encode(StageStyle()), as: UTF8.self)
        invalid = invalid.replacingOccurrences(of: "\"paddingRatio\":0.1", with: "\"paddingRatio\":0.9")
        try check(invalid.contains("0.9"), "could not build the invalid fixture")
        try Data(invalid.utf8).write(to: file)
        do {
            _ = try StageStyle.load(in: directory)
            throw Failure("out-of-range stage-config.json was accepted")
        } catch is StageError { checks += 1 }
        try FileManager.default.removeItem(at: file)
    }

    // MARK: - Geometry

    static func verifyStageRect() throws {
        func rect(padding: Double, aspect: Double) throws -> CGRect {
            try StageRenderer(style: flat(padding: padding), outputSize: output).stageRect(contentAspect: aspect)
        }
        try check(try rect(padding: 0.1, aspect: 16.0 / 9) == CGRect(x: 128, y: 72, width: 1024, height: 576),
                  "16:9 at padding 0.1 should be (128,72,1024,576)")
        try check(try rect(padding: 0, aspect: 16.0 / 9) == CGRect(x: 0, y: 0, width: 1280, height: 720),
                  "16:9 at padding 0 should fill the output")
        try check(try rect(padding: 0.4, aspect: 16.0 / 9) == CGRect(x: 512, y: 288, width: 256, height: 144),
                  "16:9 at padding 0.4 should be (512,288,256,144)")
        let portrait = try rect(padding: 0.1, aspect: 9.0 / 16)
        try check(portrait == CGRect(x: 478, y: 72, width: 324, height: 576),
                  "9:16 content should be pillarboxed to (478,72,324,576), got \(portrait)")
        let wide = try rect(padding: 0.1, aspect: 4)
        try check(wide == CGRect(x: 72, y: 218, width: 1136, height: 284), "4:1 content should letterbox, got \(wide)")
        try check(try rect(padding: 0.1, aspect: .nan) == CGRect(x: 72, y: 72, width: 1136, height: 576),
                  "invalid aspect should fill the stage")
        for size in [CGSize(width: 1280, height: 720), CGSize(width: 1080, height: 1920), CGSize(width: 999, height: 999)] {
            let renderer = try StageRenderer(style: StageStyle(), outputSize: size)
            try check(renderer.compose(content(width: 640, height: 360)).extent == CGRect(origin: .zero, size: size),
                      "output extent differs from \(size)")
        }
        try check((try? StageRenderer(style: StageStyle(), outputSize: CGSize(width: 0, height: 720))) == nil,
                  "zero output size was accepted")
    }

    static func verifyDeviceFrames() throws {
        for id in DeviceFrameCatalog.devices {
            guard let geometry = DeviceFrameCatalog.geometry(deviceID: id, finish: "dark"),
                  let frame = DeviceFrameRenderer(configuration: DeviceMockupConfiguration(enabled: true, deviceID: id)) else {
                throw Failure("missing device geometry for \(id)")
            }
            let fitted = frame.fittedRect(in: CGRect(x: 72, y: 72, width: 1136, height: 576))
            let expectedScale = min(1136 / geometry.canvasSize.width, 576 / geometry.canvasSize.height)
            try check(abs(fitted.width / fitted.height - geometry.canvasSize.width / geometry.canvasSize.height) < 0.0001,
                      "\(id) device aspect changed")
            try check(fitted.width <= 1136.01 && fitted.height <= 576.01 && abs(fitted.width - geometry.canvasSize.width * expectedScale) < 0.1,
                      "\(id) does not fit stage rect")
            let aperture = frame.apertureRect(in: fitted)
            try check(fitted.contains(aperture) && aperture.width > 0 && aperture.height > 0,
                      "\(id) aperture lies outside body")
            try check(abs(aperture.width / aperture.height - geometry.screenRect.width / geometry.screenRect.height) < 0.0001,
                      "\(id) aperture aspect changed")
        }
        let legacy = String(decoding: try JSONEncoder().encode(StageStyle()), as: UTF8.self)
            .replacingOccurrences(of: ",\"deviceMockup\":{\"deviceID\":null,\"enabled\":false,\"finish\":null}", with: "")
        let decoded = try JSONDecoder().decode(StageStyle.self, from: Data(legacy.utf8))
        try check(!decoded.deviceMockup.enabled && decoded == StageStyle(), "legacy stage config did not decode with mockup disabled")
        let plain = try StageRenderer(style: StageStyle(), outputSize: output)
        let explicitlyOff = try StageRenderer(style: StageStyle(deviceMockup: DeviceMockupConfiguration(enabled: false, deviceID: "laptop")), outputSize: output)
        try check(try Bitmap(plain.compose(content(width: 640, height: 360))).bytes == Bitmap(explicitlyOff.compose(content(width: 640, height: 360))).bytes,
                  "disabled mockup changed stage pixels")
    }

    // MARK: - Composition

    static func verifyComposition() throws {
        let background = (r: 32.0 / 255, g: 48.0 / 255, b: 64.0 / 255)
        var style = flat(padding: 0.1)
        style.cornerRadius = 90 // 60 px at 720
        let renderer = try StageRenderer(style: style, outputSize: output)
        let frame = try Bitmap(renderer.compose(content(width: 640, height: 360)))
        let content = renderer.prepared(contentSize: CGSize(width: 640, height: 360)).contentRect
        for (x, y) in [(0, 0), (1279, 0), (0, 719), (1279, 719)] {
            try check(frame.matches(x, y, background), "output corner (\(x),\(y)) is not background")
        }
        try check(frame.matches(640, 360, contentColor), "center pixel is not content")
        try check(frame.matches(Int(content.minX) + 2, Int(content.minY) + 2, background),
                  "pixel just inside the stage corner is not masked to background")
        try check(frame.matches(Int(content.maxX) - 3, Int(content.maxY) - 3, background),
                  "pixel just inside the top-right stage corner is not masked")
        try check(frame.matches(Int(content.minX) + 1, Int(content.midY), contentColor),
                  "mid-edge pixel does not show content")
        try check(frame.matches(Int(content.midX), Int(content.maxY) - 2, contentColor),
                  "top mid-edge pixel does not show content")

        let first = try Bitmap(renderer.compose(self.content(width: 640, height: 360))).bytes
        let second = try Bitmap(renderer.compose(self.content(width: 640, height: 360))).bytes
        try check(first == second, "repeated compose produced different bytes")
        let results = ResultBox()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            results.append((try? Bitmap(renderer.compose(VerifyStage.content(width: 640, height: 360))).bytes) ?? [])
        }
        try check(results.values.count == 6 && results.values.allSatisfy { $0 == first },
                  "concurrent compose produced different bytes")

        // Shadow over a white background. 45° casts right and down (down = lower CI y).
        func shadowFrame(_ edit: (inout StageStyle) -> Void) throws -> Bitmap {
            var style = StageStyle(background: .color("#ffffff"))
            edit(&style)
            return try Bitmap(StageRenderer(style: style, outputSize: output).compose(self.content(width: 640, height: 360)))
        }
        let shadowed = try shadowFrame { _ in }
        let right = shadowed.luma(1157, 360), left = shadowed.luma(122, 360)
        let below = shadowed.luma(640, 66), above = shadowed.luma(640, 653)
        try check(right < 0.99 && left < 0.99, "shadow is missing around the content (\(left), \(right))")
        try check(right < left - 0.005, "shadow is not darker on the offset (right) side: right \(right), left \(left)")
        try check(below < above - 0.005, "shadow is not darker on the offset (lower) side: below \(below), above \(above)")
        let centered = try shadowFrame { $0.shadow.isDirectional = false }
        try check(abs(centered.luma(1157, 360) - centered.luma(122, 360)) < 0.006,
                  "non-directional shadow is not symmetric")
        let noShadow = try shadowFrame { $0.shadow.intensity = 0 }
        try check(noShadow.matches(1157, 360, (1, 1, 1), tolerance: 0) && noShadow.matches(640, 66, (1, 1, 1), tolerance: 0),
                  "shadow is present at intensity 0")

        var bordered = flat(padding: 0.1)
        bordered.inset.size = 6 // 4 px at 720
        let border = try Bitmap(StageRenderer(style: bordered, outputSize: output).compose(self.content(width: 640, height: 360)))
        let edge = border.luma(Int(content.minX) + 1, Int(content.midY))
        try check(edge < border.luma(640, 360) - 0.1, "inset border is not drawn at size 6")
        try check(border.matches(Int(content.minX) + 8, Int(content.midY), contentColor), "inset border is wider than its size")
        try check(frame.matches(Int(content.minX) + 1, Int(content.midY), contentColor), "inset border drawn at size 0")
    }

    static func verifyGradients() throws {
        var style = flat(padding: 0.4)
        style.background = .standard
        let diagonal = try Bitmap(StageRenderer(style: style, outputSize: output).compose(content(width: 640, height: 360)))
        try check(diagonal.matches(0, 719, hex(0x47, 0x76, 0xe6), tolerance: 4 / 255), "top-left is not the start stop")
        try check(diagonal.matches(1279, 0, hex(0x8e, 0x54, 0xe9), tolerance: 4 / 255), "bottom-right is not the end stop")

        style.background = .gradient(stops: [GradientStop(color: "#ff0000", location: 0),
                                             GradientStop(color: "#0000ff", location: 1)],
                                     start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 0))
        let horizontal = try Bitmap(StageRenderer(style: style, outputSize: output).compose(content(width: 640, height: 360)))
        try check(horizontal.matches(0, 360, (1, 0, 0), tolerance: 4 / 255), "horizontal gradient left is not red")
        try check(horizontal.matches(1279, 360, (0, 0, 1), tolerance: 4 / 255), "horizontal gradient right is not blue")
        try check(horizontal.matches(0, 0, horizontal.color(0, 719), tolerance: 1 / 255) &&
                  horizontal.matches(900, 10, horizontal.color(900, 710), tolerance: 1 / 255),
                  "horizontal gradient varies vertically")

        style.background = .gradient(stops: [GradientStop(color: "#000000", location: 0),
                                             GradientStop(color: "#00ff00", location: 0.5),
                                             GradientStop(color: "#000000", location: 1)],
                                     start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 0))
        let threeStop = try Bitmap(StageRenderer(style: style, outputSize: output).compose(content(width: 640, height: 360)))
        try check(threeStop.matches(640, 10, (0, 1, 0), tolerance: 4 / 255), "three-stop gradient middle is not the middle stop")
    }

    static func verifyWallpapers() throws {
        var images: [[UInt8]] = []
        for name in StageStyle.wallpaperNames {
            let renderer = try StageRenderer(style: StageStyle(background: .wallpaper(name)), outputSize: output)
            let image = try Bitmap(renderer.background)
            let samples = stride(from: 40, to: 1280, by: 300).flatMap { x in
                stride(from: 40, to: 720, by: 160).map { y in image.luma(x, y) }
            }
            let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
            try check(spread > 0.05 && image.color(0, 0).3 == 1, "wallpaper \(name) is uniform or not opaque (spread \(spread))")
            images.append(image.bytes)
        }
        try check(Set(images).count == images.count, "wallpapers are not distinct")
    }

    static func verifyImageBackground(in directory: URL, outside: URL) throws {
        // 100×100: bottom quarter green, middle half blue, top quarter red (CG is y-up).
        guard let bitmap = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                     space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure("could not create the fixture context") }
        for (rect, color) in [(CGRect(x: 0, y: 0, width: 100, height: 25), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                              (CGRect(x: 0, y: 25, width: 100, height: 50), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
                              (CGRect(x: 0, y: 75, width: 100, height: 25), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))] {
            bitmap.setFillColor(color)
            bitmap.fill(rect)
        }
        guard let fixture = bitmap.makeImage() else { throw Failure("could not create the fixture image") }
        try context.writePNGRepresentation(of: CIImage(cgImage: fixture), to: directory.appendingPathComponent("bg.png"),
                                           format: .RGBA8, colorSpace: sRGB)
        try context.writePNGRepresentation(of: CIImage(cgImage: fixture), to: outside.appendingPathComponent("secret.png"),
                                           format: .RGBA8, colorSpace: sRGB)

        // Aspect-fill at 1280×720 scales to 1280×1280 and crops 280 px top and bottom:
        // red keeps the top 40 rows, green the bottom 40 rows; a stretch would keep 180.
        var style = flat(padding: 0.1)
        style.background = .image("bg.png")
        let fill = try Bitmap(StageRenderer(style: style, outputSize: output, baseDirectory: directory).background)
        try check(fill.matches(2, 715, (1, 0, 0)) && fill.matches(2, 5, (0, 1, 0)), "image top/bottom bands are wrong")
        try check(fill.matches(2, 660, (0, 0, 1)) && fill.matches(2, 60, (0, 0, 1)), "image was stretched instead of aspect-filled")
        try check(fill.matches(0, 360, (0, 0, 1)) && fill.matches(1279, 360, (0, 0, 1)), "image does not fill horizontally")

        style.backgroundBlur = 10
        let blurred = try Bitmap(StageRenderer(style: style, outputSize: output, baseDirectory: directory).background)
        try check(blurred.bytes != fill.bytes, "background blur did not change the image")
        let mixed = blurred.color(2, 681)
        try check(mixed.0 > 0.15 && mixed.2 > 0.15, "blur did not mix the red/blue boundary (\(mixed))")

        func rejectsImage(_ name: String, _ base: URL?) throws {
            var style = flat(padding: 0.1)
            style.background = .image(name)
            do {
                _ = try StageRenderer(style: style, outputSize: output, baseDirectory: base)
                throw Failure("image background \(name) was accepted")
            } catch is StageError { checks += 1 }
        }
        try rejectsImage("../\(outside.lastPathComponent)/secret.png", directory)
        try rejectsImage(outside.appendingPathComponent("secret.png").path, directory)
        try rejectsImage("missing.png", directory)
        try rejectsImage("bg.png", nil)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.png"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.png"))
        try rejectsImage("link.png", directory)
        try Data("not an image".utf8).write(to: directory.appendingPathComponent("broken.png"))
        try rejectsImage("broken.png", directory)
    }

    // MARK: - Helpers

    static func flat(padding: Double) -> StageStyle {
        var style = StageStyle(paddingRatio: padding)
        style.shadow.intensity = 0
        style.background = .color("#203040")
        return style
    }

    static func content(width: Int, height: Int) -> CIImage {
        let color = CIColor(red: contentColor.r, green: contentColor.g, blue: contentColor.b, alpha: 1, colorSpace: sRGB)
            ?? CIColor(red: contentColor.r, green: contentColor.g, blue: contentColor.b)
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func hex(_ r: Int, _ g: Int, _ b: Int) -> (Double, Double, Double) {
        (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
        checks += 1
    }

    /// sRGB RGBA8 rendering; `color(x, y)` takes Core Image coordinates (bottom-left origin).
    struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CIImage) throws {
            let extent = image.extent
            guard !extent.isInfinite, extent.origin == .zero,
                  let cg = VerifyStage.context.createCGImage(image, from: extent, format: .RGBA8,
                                                             colorSpace: VerifyStage.sRGB),
                  let data = cg.dataProvider?.data, let pointer = CFDataGetBytePtr(data)
            else { throw Failure("could not render test image") }
            width = cg.width
            height = cg.height
            var packed = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                for byte in 0..<(width * 4) { packed[row * width * 4 + byte] = pointer[row * cg.bytesPerRow + byte] }
            }
            bytes = packed
        }

        func color(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let offset = ((height - 1 - y) * width + x) * 4
            return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255,
                    Double(bytes[offset + 2]) / 255, Double(bytes[offset + 3]) / 255)
        }

        func luma(_ x: Int, _ y: Int) -> Double {
            let c = color(x, y)
            return 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        }

        func matches(_ x: Int, _ y: Int, _ expected: (Double, Double, Double), tolerance: Double = 3 / 255) -> Bool {
            let c = color(x, y)
            return abs(c.0 - expected.0) <= tolerance + 1e-9 && abs(c.1 - expected.1) <= tolerance + 1e-9 &&
                abs(c.2 - expected.2) <= tolerance + 1e-9 && c.3 == 1
        }

        func matches(_ x: Int, _ y: Int, _ expected: (Double, Double, Double, Double), tolerance: Double) -> Bool {
            matches(x, y, (expected.0, expected.1, expected.2), tolerance: tolerance)
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[UInt8]] = []
    var values: [[UInt8]] { lock.withLock { storage } }
    func append(_ value: [UInt8]) { lock.withLock { storage.append(value) } }
}

private enum Failure: LocalizedError {
    case failed(String)
    init(_ message: String) { self = .failed(message) }
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}
