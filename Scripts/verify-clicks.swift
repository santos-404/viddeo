import CoreGraphics
import CoreImage
import Foundation

@main
struct VerifyClicks {
    static func main() throws {
        let width = 640, height = 360
        let events = [
            CursorEvent(time: 1, x: 0.25, y: 0.25, kind: .down),
            CursorEvent(time: 1, x: 0.75, y: 0.75, kind: .up),
            CursorEvent(time: .nan, x: 0.5, y: 0.5, kind: .down),
            CursorEvent(time: 1, x: 1.2, y: 0.5, kind: .down)
        ]
        let timeline = ClickEffectTimeline(events: events, duration: 3)
        let blank = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let before = timeline.image(over: blank, at: 0.99)
        let atCenter = timeline.image(over: blank, at: 1.05)
        let outside = timeline.image(over: blank, at: 1.05)
        let faded = timeline.image(over: blank, at: 1.46)
        let seekAgain = timeline.image(over: blank, at: 1.05)

        // At 50 ms the ring radius is about 15 px; sample its visible stroke at
        // that offset while retaining the recorded click center as the anchor.
        let ringX = 0.25 + 15.0 / Double(width)
        let centerPixel = try pixel(atCenter, x: ringX, y: 0.25, width: width, height: height)
        guard brightness(centerPixel) > 0.4 else { throw Failure("down click ring missing at event center") }
        let upPixel = try pixel(outside, x: 0.75 + 15.0 / Double(width), y: 0.75,
                                width: width, height: height)
        guard brightness(upPixel) < 0.1 else { throw Failure("up event incorrectly produced a ring") }
        let outsidePixel = try pixel(atCenter, x: 0.55, y: 0.25, width: width, height: height)
        guard brightness(outsidePixel) < 0.1 else { throw Failure("ring appeared away from the click") }
        let expiredPixel = try pixel(faded, x: ringX, y: 0.25, width: width, height: height)
        guard brightness(expiredPixel) < 0.1 else { throw Failure("ring did not fade by its lifetime") }
        let beforePixel = try pixel(before, x: ringX, y: 0.25, width: width, height: height)
        guard brightness(beforePixel) < 0.1 else { throw Failure("ring appeared before the event") }
        let repeatPixel = try pixel(seekAgain, x: ringX, y: 0.25, width: width, height: height)
        guard abs(brightness(repeatPixel) - brightness(centerPixel)) < 0.01 else {
            throw Failure("arbitrary seek produced nondeterministic effect")
        }

        // Exercise the actual source crop/scale, then sample the visible ring.
        let scale = CGFloat(2)
        let crop = CGRect(x: 0, y: 180, width: 320, height: 180)
        let zoomed = atCenter.cropped(to: crop).transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: -crop.minX * scale, ty: -crop.minY * scale
        ))
        let zoomPixel = try pixel(zoomed, x: 0.5 + 30.0 / Double(width), y: 0.5,
                                  width: width, height: height)
        guard brightness(zoomPixel) > 0.4 else { throw Failure("rendered ring did not follow the zoom crop") }
        let fadedActive = timeline.image(over: blank, at: 1.35)
        let fadingRadius = 12.0 + 30.0 * (0.35 / 0.45)
        let fadingPixel = try pixel(fadedActive, x: 0.25 + fadingRadius / Double(width),
                                    y: 0.25, width: width, height: height)
        guard brightness(fadingPixel) > 0.02, brightness(fadingPixel) < brightness(centerPixel) else {
            throw Failure("active ring did not fade at its moving radius")
        }
        print("Click effects verified: down-only, position, expiry, seek determinism and zoom mapping.")
    }

    private static func pixel(_ image: CIImage, x: Double, y: Double,
                              width: Int, height: Int) throws -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(image, from: image.extent),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { throw Failure("could not render test image") }
        // CGImage rows are top-down; effect coordinates are specified top-left.
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
