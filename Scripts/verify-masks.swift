import CoreGraphics
import CoreImage
import Foundation

struct MaskVerificationFailure: Error, CustomStringConvertible {
    var description: String
}

@main
@MainActor
struct VerifyMasks {
    static var checks = 0

    static func main() throws {
        try testConfiguration()
        try testSpring()
        try testTimeline()
        try testRenderer()
        print("Masks verified: \(checks) checks")
    }

    static func testSpring() throws {
        let defaultSettle = SpringConfiguration.screen.settleTimeMilliseconds
        let opacitySettle = SpringConfiguration.presetQ.settleTimeMilliseconds
        print(String(format: "Spring settle times: J(default)=%.3f ms, J(Q)=%.3f ms", defaultSettle, opacitySettle))
        try expect(abs(defaultSettle - 1483.333333) < 0.01 && abs(opacitySettle - 483) < 0.01,
                   "J settle times match the decoded default and Q springs")

        let scaled = SpringConfiguration.presetQ.fitted(toDurationMilliseconds: 200)
        let factor = opacitySettle / 200
        try expect(abs(scaled.stiffness - SpringConfiguration.presetQ.stiffness * factor * factor) < 1e-9 &&
                   abs(scaled.damping - SpringConfiguration.presetQ.damping * factor) < 1e-9,
                   "duration fitting scales stiffness by k² and damping by k")
        let instant = SpringConfiguration.screen.fitted(toDurationMilliseconds: 1000.0 / 30.0)
        try expect(instant.mass == 0, "duration fitting uses instant spring at or below 33.3 ms")
        let unchanged = SpringConfiguration.screen.fitted(toDurationMilliseconds: defaultSettle)
        try expect(unchanged.stiffness == SpringConfiguration.screen.stiffness &&
                   unchanged.damping == SpringConfiguration.screen.damping,
                   "duration fitting preserves configs that already settle in time")
    }

    static func expect(_ value: Bool, _ message: String) throws {
        checks += 1
        guard value else { throw MaskVerificationFailure(description: "FAILED: \(message)") }
    }

    static func testConfiguration() throws {
        let mask = TimelineMask(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                sourceStart: 1, sourceEnd: 4, bounds: [CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.4)],
                                blur: 21, kind: .highlight, highlightOpacity: 0.7)
        let configuration = MaskConfiguration(version: 2, masks: [mask])
        let decoded = try JSONDecoder().decode(MaskConfiguration.self, from: JSONEncoder().encode(configuration))
        try expect(decoded == configuration, "configuration survives Codable round-trip")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verify-masks-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try expect(try MaskConfiguration.load(from: dir) == MaskConfiguration(), "missing masks.json loads empty configuration")
        try configuration.save(to: dir)
        try expect(try MaskConfiguration.load(from: dir) == configuration, "masks.json saves atomically and loads")

        let bounds = TimelineMask.defaultBounds(recordingSize: CGSize(width: 1000, height: 600))
        try expect(abs(bounds.width - 0.35) < 1e-9 && abs(bounds.height - 80.0 / 600) < 1e-9 &&
                   abs(bounds.midX - 0.5) < 1e-9 && abs(bounds.midY - 0.5) < 1e-9,
                   "default bounds center a 350×80 rectangle and normalize it")
        let small = TimelineMask.defaultBounds(recordingSize: CGSize(width: 200, height: 40))
        try expect(small == CGRect(x: 0, y: 0, width: 1, height: 1), "default bounds cap to smaller recording dimensions")
        try expect(TimelineMask.minDuration == 0.5 && TimelineMask.initialDuration == 3,
                   "duration constants match observed mask class")
    }

    static func testTimeline() throws {
        let rectA = CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.3)
        let rectB = CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.2)
        let a = TimelineMask(sourceStart: 1, sourceEnd: 2, bounds: [rectA])
        let b = TimelineMask(sourceStart: 2.3, sourceEnd: 3.3, bounds: [rectB])
        let timeline = MaskTimeline(configuration: MaskConfiguration(masks: [a, b]))
        try expect(timeline.state(atSource: 0.8)?.opacity == 0, "greedy show window starts opacity at zero")
        try expect(timeline.state(atSource: 0.799) == nil, "time before greedy show window has no state")
        try expect((timeline.state(atSource: 1)?.opacity ?? 0) >= 0.98, "greedy opacity settles by source start")
        try expect(timeline.state(atSource: 2)?.opacity == 1, "cover target remains visible through source end")
        try expect(timeline.state(atSource: 2.5) != nil && timeline.state(atSource: 2.5)?.kind == .sensitiveData,
                   "neighbor gap below 400 ms bridges to the next greedy mask")
        try expect(timeline.state(atSource: 3.5)?.opacity == 0, "opacity settles to zero by end plus 200 ms")
        try expect(timeline.state(atSource: 3.501) == nil, "time after show window has no state")

        let disabled = TimelineMask(sourceStart: 0, sourceEnd: 4, isDisabled: true,
                                   bounds: [rectA])
        try expect(MaskTimeline(configuration: MaskConfiguration(masks: [disabled])).state(atSource: 1) == nil,
                   "disabled masks never resolve")

        let fading = MaskTimeline(configuration: MaskConfiguration(masks: [a]))
        try expect(fading.state(atSource: 1)?.rect == rectA &&
                   fading.state(atSource: 1.2)?.opacity == 1 && fading.state(atSource: 1.2)?.rect == rectA,
                   "isolated mask bounds are instant and opacity settles")

        let highlight = TimelineMask(sourceStart: 4, sourceEnd: 5, bounds: [rectB], kind: .highlight)
        let highlightTimeline = MaskTimeline(configuration: MaskConfiguration(masks: [highlight]))
        try expect(highlightTimeline.state(atSource: 4)?.opacity == 0 &&
                   (highlightTimeline.state(atSource: 4.2)?.opacity ?? 0) >= 0.98,
                   "non-greedy highlight fades in from source start")

        let bridgeTimes = [2.0, 2.05, 2.1, 2.15, 2.2, 2.25, 2.3]
        let bridgeRects = bridgeTimes.compactMap { timeline.state(atSource: $0)?.rect }
        try expect(bridgeRects.first == rectA && abs(bridgeRects.last!.minX - rectB.minX) < 0.01 &&
                   abs(bridgeRects.last!.minY - rectB.minY) < 0.01,
                   "bridged bounds start at predecessor and arrive by successor start")
        try expect(zip(bridgeRects, bridgeRects.dropFirst()).allSatisfy { $0.minX <= $1.minX + 0.00001 },
                   "bridged bounds move monotonically toward successor")

        let seekTimeline = MaskTimeline(configuration: MaskConfiguration(masks: [a, b]))
        let times = [0.8, 1.0, 1.1, 2.0, 2.1, 2.15, 2.3, 3.3, 3.5]
        let baseline = Dictionary(uniqueKeysWithValues: times.map { ($0, seekTimeline.state(atSource: $0)) })
        let shuffled = [2.15, 0.8, 3.5, 1.1, 2.3, 1.0, 3.3, 2.0, 2.1]
        try expect(shuffled.allSatisfy { seekTimeline.state(atSource: $0) == baseline[$0] },
                   "shuffled seeks return order-independent states")
    }

    static func testRenderer() throws {
        let width = 64, height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = ((x / 2 + y / 2) % 2 == 0) ? 255 : 0
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                             size: CGSize(width: width, height: height), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let blurred = MaskRenderer.apply(MaskFrameState(rect: region, kind: .sensitiveData,
                                                        highlightOpacity: 0.5, opacity: 1, blur: 32),
                                         to: source, sourceExtent: extent)
        let originalPixels = try pixels(source, width: width, height: height)
        let blurredPixels = try pixels(blurred, width: width, height: height)
        try expect(contrast(blurredPixels, width: width, x: 24..<40, y: 24..<40) <
                   contrast(originalPixels, width: width, x: 24..<40, y: 24..<40) * 0.5,
                   "sensitive-data blur reduces high-frequency contrast inside bounds")
        try expect(blurredPixels[pixelIndex(8, 8, width)] == originalPixels[pixelIndex(8, 8, width)],
                   "sensitive-data blur leaves outside pixels unchanged")

        let highlighted = MaskRenderer.apply(MaskFrameState(rect: region, kind: .highlight,
                                                            highlightOpacity: 0.6, opacity: 1, blur: 32),
                                             to: source, sourceExtent: extent)
        let highlightPixels = try pixels(highlighted, width: width, height: height)
        let inside = pixelIndex(30, 30, width), outside = pixelIndex(8, 8, width)
        try expect(abs(Int(highlightPixels[inside]) - Int(originalPixels[inside])) <= 2,
                   "highlight leaves inside pixels unchanged")
        try expect(abs(Double(highlightPixels[outside]) / Double(originalPixels[outside]) - 0.4) < 0.04,
                   "highlight darkens outside pixels by configured opacity")
    }

    static func pixels(_ image: CIImage, width: Int, height: Int) throws -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var result = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &result, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return result
    }

    static func pixelIndex(_ x: Int, _ y: Int, _ width: Int) -> Int { (y * width + x) * 4 }

    static func contrast(_ bytes: [UInt8], width: Int, x: Range<Int>, y: Range<Int>) -> Double {
        var values: [Double] = []
        for row in y {
            for column in x { values.append(Double(bytes[pixelIndex(column, row, width)])) }
        }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }
}
