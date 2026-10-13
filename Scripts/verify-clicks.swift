import CoreGraphics
import CoreImage
import Foundation

@main
struct VerifyClicks {
    static func main() throws {
        let width = 640, height = 360
        for (p, expected) in [(0.0, 1.28), (0.25, 11.64), (0.5, 16.96), (1.0, 19.2)] {
            let actual = ClickEffectTimeline.radius(progress: p, width: Double(width))
            guard abs(actual - expected) < 0.02 else { throw Failure("radius formula mismatch at progress \(p)") }
        }
        guard ClickEffectTimeline.fade(progress: 0) == 0,
              ClickEffectTimeline.fade(progress: 0.9) == 0,
              ClickEffectTimeline.fade(progress: 1) == 0,
              ClickEffectTimeline.fade(progress: 0.15) > ClickEffectTimeline.fade(progress: 0.3) else {
            throw Failure("fade curve endpoints or peak are incorrect")
        }

        let events = [
            CursorEvent(time: 0.1, x: 0.1, y: 0.1, kind: .down),
            CursorEvent(time: 0.2, x: 0.2, y: 0.2, kind: .down),
            CursorEvent(time: 0.3, x: 0.3, y: 0.3, kind: .down),
            CursorEvent(time: 0.4, x: 0.4, y: 0.4, kind: .down),
            CursorEvent(time: 0.4, x: 0.75, y: 0.75, kind: .up),
            CursorEvent(time: .nan, x: 0.5, y: 0.5, kind: .down),
            CursorEvent(time: 0.4, x: 1.2, y: 0.5, kind: .down)
        ]
        let timeline = ClickEffectTimeline(events: events, duration: 3)
        let blank = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let frame = timeline.image(over: blank, at: 0.5)
        let progress = (0.5 - 0.4) / 0.45
        let radius = ClickEffectTimeline.radius(progress: progress, width: Double(width))
        // Interior over black: sRGB-encoded linear 0.7569 gray × overlay alpha 0.6 × fade.
        let encodedFill = 1.055 * pow(0.7569, 1 / 2.4) - 0.055
        let expectedFill = encodedFill * 0.6 * ClickEffectTimeline.fade(progress: progress)
        let fill = try pixel(frame, x: 0.4, y: 0.4, width: width, height: height)
        guard abs(Double(fill.0) - expectedFill) < 0.02, abs(fill.0 - fill.1) < 0.01 else {
            throw Failure("disc interior is \(fill.0), expected \(expectedFill)")
        }
        // At the radius the 0.5-alpha dark rim and the antialiased edge blend toward black.
        let rim = try pixel(frame, x: 0.4 + (radius - 0.5) / Double(width), y: 0.4,
                            width: width, height: height)
        guard rim.0 > 0.02, Double(rim.0) < 0.6 * expectedFill else {
            throw Failure("rim is \(rim.0), expected darker than the interior \(expectedFill)")
        }
        let outside = try pixel(frame, x: 0.4 + (radius + 4) / Double(width), y: 0.4,
                                width: width, height: height)
        guard outside.0 < 0.005 else { throw Failure("disc appeared outside radius and rim") }
        let oldest = try pixel(frame, x: 0.1, y: 0.1, width: width, height: height)
        guard oldest.0 < 0.005 else { throw Failure("fourth recent click was not limited to three slots") }
        for (x, y) in [(0.2, 0.2), (0.3, 0.3)] {
            let slot = try pixel(frame, x: x, y: y, width: width, height: height)
            // These clicks are 300/200 ms old, still inside 450 ms and the three-slot window.
            let age = 0.5 - (x * 1.0)
            let expected = encodedFill * 0.6 * ClickEffectTimeline.fade(progress: age / 0.45)
            guard abs(Double(slot.0) - expected) < 0.03 else {
                throw Failure("slot at \(x) is \(slot.0), expected \(expected)")
            }
        }
        let up = try pixel(frame, x: 0.75, y: 0.75, width: width, height: height)
        guard up.0 < 0.005 else { throw Failure("up event incorrectly produced an effect") }

        let before = timeline.image(over: blank, at: 0.39)
        let expired = timeline.image(over: blank, at: 0.86)
        guard brightness(try pixel(before, x: 0.4, y: 0.4, width: width, height: height)) < 0.005,
              brightness(try pixel(expired, x: 0.4, y: 0.4, width: width, height: height)) < 0.005 else {
            throw Failure("effect visible before click or after lifetime")
        }
        let repeatFrame = timeline.image(over: blank, at: 0.5)
        let repeatPixel = try pixel(repeatFrame, x: 0.4, y: 0.4, width: width, height: height)
        guard abs(brightness(repeatPixel) - brightness(fill)) < 0.01 else {
            throw Failure("arbitrary seek produced nondeterministic effect")
        }

        let scale = CGFloat(2)
        let crop = CGRect(x: 0, y: 180, width: 320, height: 180)
        let zoomed = frame.cropped(to: crop).transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: -crop.minX * scale, ty: -crop.minY * scale
        ))
        // The click at 256 px, 144 px from the top lands at 512 px, 288 px after the 2× crop.
        let zoomPixel = try pixel(zoomed, x: 0.8, y: 0.8, width: width, height: height)
        guard abs(Double(zoomPixel.0) - expectedFill) < 0.02 else {
            throw Failure("effect did not follow the zoom crop (\(zoomPixel.0))")
        }
        print("Click effects verified: radius/fade formulas, filled disc and rim, three slots, down-only, filtering, expiry, seek determinism and zoom mapping.")
    }

    private static func pixel(_ image: CIImage, x: Double, y: Double,
                              width: Int, height: Int) throws -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(image, from: image.extent),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { throw Failure("could not render test image") }
        let px = min(width - 1, max(0, Int(x * Double(width))))
        let py = min(height - 1, max(0, Int(y * Double(height))))
        let offset = py * cg.bytesPerRow + px * 4
        return (CGFloat(bytes[offset]) / 255, CGFloat(bytes[offset + 1]) / 255,
                CGFloat(bytes[offset + 2]) / 255, CGFloat(bytes[offset + 3]) / 255)
    }

    private static func brightness(_ value: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGFloat {
        max(value.0, max(value.1, value.2))
    }
}

private enum Failure: LocalizedError {
    case failed(String)
    init(_ message: String) { self = .failed(message) }
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}
