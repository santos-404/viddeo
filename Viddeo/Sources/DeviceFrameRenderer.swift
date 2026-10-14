import CoreGraphics
import CoreImage
import Foundation

/// Draws viddeo-owned device silhouettes. All returned rectangles use Core Image's y-up space.
struct DeviceFrameRenderer: Sendable {
    let geometry: DeviceFrameGeometry

    init?(configuration: DeviceMockupConfiguration) {
        guard configuration.enabled, let id = configuration.deviceID,
              let geometry = DeviceFrameCatalog.geometry(deviceID: id, finish: configuration.finish) else { return nil }
        self.geometry = geometry
    }

    func fittedRect(in rect: CGRect) -> CGRect {
        let scale = min(rect.width / geometry.canvasSize.width, rect.height / geometry.canvasSize.height)
        let size = CGSize(width: geometry.canvasSize.width * scale, height: geometry.canvasSize.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    func apertureRect(in deviceRect: CGRect) -> CGRect {
        let sx = deviceRect.width / geometry.canvasSize.width, sy = deviceRect.height / geometry.canvasSize.height
        // Catalog geometry is top-left-origin; convert its y coordinate for CI.
        return CGRect(x: deviceRect.minX + geometry.screenRect.minX * sx,
                      y: deviceRect.minY + (geometry.canvasSize.height - geometry.screenRect.maxY) * sy,
                      width: geometry.screenRect.width * sx, height: geometry.screenRect.height * sy)
    }

    func compose(_ screen: CIImage, in bounds: CGRect, shadowIntensity: Double = 0.3,
                 shadowDistance: Double = 25, shadowAngle: Double = 45, shadowBlur: Double = 20) -> CIImage {
        let device = fittedRect(in: bounds), aperture = apertureRect(in: device)
        let sx = device.width / geometry.canvasSize.width
        let radius = geometry.bodyCornerRadius * sx
        let body = rounded(device, radius: radius, color: color(geometry.bezelColour))
        let screenRadius = geometry.screenCornerRadius * sx
        let screenMask = rounded(aperture, radius: screenRadius, color: CIColor(red: 1, green: 1, blue: 1))
        let fittedScreen = screen.transformed(by: CGAffineTransform(scaleX: aperture.width / screen.extent.width,
                                                                     y: aperture.height / screen.extent.height))
            .transformed(by: CGAffineTransform(translationX: aperture.minX, y: aperture.minY))
            .cropped(to: aperture)
        let clipped = fittedScreen.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: aperture),
            kCIInputMaskImageKey: screenMask
        ])
        var result = body
        if shadowIntensity > 0 {
            let angle = shadowAngle * .pi / 180
            let shadow = rounded(device.offsetBy(dx: shadowDistance * cos(angle), dy: -shadowDistance * sin(angle)), radius: radius,
                                 color: CIColor(red: 0, green: 0, blue: 0, alpha: shadowIntensity))
                .applyingGaussianBlur(sigma: 8 * shadowBlur).cropped(to: bounds)
            result = body.composited(over: shadow)
        }
        result = clipped.composited(over: result)
        // A subtle top edge highlight is generated from geometry, never a bitmap asset.
        let highlight = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.12))
            .cropped(to: CGRect(x: device.minX, y: device.maxY - max(1, sx), width: device.width, height: max(1, sx)))
        return highlight.composited(over: result).cropped(to: bounds)
    }

    private func rounded(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        (CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius, "inputColor": color])?.outputImage ?? CIImage(color: color)).cropped(to: rect)
    }

    private func color(_ hex: String) -> CIColor {
        guard let c = StageStyle.rgba(hex: hex) else { return .black }
        return CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
