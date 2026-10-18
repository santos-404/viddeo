import CoreGraphics
import Foundation

/// A point in unit coordinates with a top-left origin (x right, y down), like session
/// cursor coordinates. Renderers convert to Core Image's bottom-left origin.
struct StagePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

struct GradientStop: Codable, Sendable, Equatable {
    var color: String
    var location: Double
}

/// Observed background kinds are color, gradient, image, unsplash and system wallpaper.
/// viddeo has no network source, and `wallpaper` names viddeo's own procedural images.
enum StageBackground: Codable, Sendable, Equatable {
    case color(String)
    case gradient(stops: [GradientStop], start: StagePoint, end: StagePoint)
    /// A simple file name inside the session directory.
    case image(String)
    case wallpaper(String)

    /// Observed default gradient pair from (0,0) to (1,1). The original's default
    /// background is a bundled system wallpaper whose assets are not copied (design choice).
    static let standard = StageBackground.gradient(
        stops: [GradientStop(color: "#4776e6", location: 0), GradientStop(color: "#8e54e9", location: 1)],
        start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 1)
    )

    private enum CodingKeys: String, CodingKey { case type, color, stops, start, end, path, name }
    private enum Kind: String, Codable { case color, gradient, image, wallpaper }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .color: self = .color(try container.decode(String.self, forKey: .color))
        case .gradient:
            self = .gradient(stops: try container.decode([GradientStop].self, forKey: .stops),
                             start: try container.decode(StagePoint.self, forKey: .start),
                             end: try container.decode(StagePoint.self, forKey: .end))
        case .image: self = .image(try container.decode(String.self, forKey: .path))
        case .wallpaper: self = .wallpaper(try container.decode(String.self, forKey: .name))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .color(let hex):
            try container.encode(Kind.color, forKey: .type)
            try container.encode(hex, forKey: .color)
        case .gradient(let stops, let start, let end):
            try container.encode(Kind.gradient, forKey: .type)
            try container.encode(stops, forKey: .stops)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .image(let path):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(path, forKey: .path)
        case .wallpaper(let name):
            try container.encode(Kind.wallpaper, forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

struct StageGradientPreset: Sendable, Equatable {
    var name: String
    var stops: [GradientStop]

    var background: StageBackground {
        .gradient(stops: stops, start: StagePoint(x: 0, y: 0), end: StagePoint(x: 1, y: 1))
    }
}

/// Stage look. Lengths (`cornerRadius`, shadow distance/blur, inset size, background blur)
/// are design-choice reference pixels on a 1080-px-high canvas, scaled by outputHeight / 1080.
struct StageStyle: Codable, Sendable, Equatable {
    struct Shadow: Codable, Sendable, Equatable {
        var intensity = 0.3
        var distance = 25.0
        /// Degrees; offset = distance × (cos, sin)(angle) in top-left-origin space,
        /// so 45° casts down and to the right.
        var angle = 45.0
        /// Resolved Gaussian sigma = 8 × blur (observed factor; the sigma unit is a design choice).
        var blur = 20.0
        var isDirectional = true
    }

    struct Inset: Codable, Sendable, Equatable {
        /// Border width drawn inside the content edge; 0 disables it.
        var size = 0.0
        var alpha = 0.5
        var color = "#000000"
    }

    var paddingRatio = 0.1
    var cornerRadius = 16.0
    var shadow = Shadow()
    var inset = Inset()
    var background = StageBackground.standard
    var backgroundBlur = 0.0
    var deviceMockup = DeviceMockupConfiguration()

    private enum CodingKeys: String, CodingKey { case paddingRatio, cornerRadius, shadow, inset, background, backgroundBlur, deviceMockup }

    init(paddingRatio: Double = 0.1, cornerRadius: Double = 16, shadow: Shadow = Shadow(), inset: Inset = Inset(),
         background: StageBackground = .standard, backgroundBlur: Double = 0,
         deviceMockup: DeviceMockupConfiguration = DeviceMockupConfiguration()) {
        self.paddingRatio = paddingRatio
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.inset = inset
        self.background = background
        self.backgroundBlur = backgroundBlur
        self.deviceMockup = deviceMockup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paddingRatio = try c.decodeIfPresent(Double.self, forKey: .paddingRatio) ?? 0.1
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 16
        shadow = try c.decodeIfPresent(Shadow.self, forKey: .shadow) ?? Shadow()
        inset = try c.decodeIfPresent(Inset.self, forKey: .inset) ?? Inset()
        background = try c.decodeIfPresent(StageBackground.self, forKey: .background) ?? .standard
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        deviceMockup = try c.decodeIfPresent(DeviceMockupConfiguration.self, forKey: .deviceMockup) ?? DeviceMockupConfiguration()
    }

    /// Name of viddeo's own procedural wallpaper used as the "system" background of a new recording.
    static let newRecordingWallpaper = "graphite"

    /// The reference's declared defaults for a NEW display recording (stage-styles.md): output padding
    /// 0.1, `screenBorderRadius` 0 (full-display recordings; 16 only for window/area/external), the
    /// shadow {0.3, 25, 45 degrees, 20, directional}, inset size 0, blur 0, and a `system` background.
    /// Design choice: the original's default is a bundled macOS wallpaper whose assets are not copied,
    /// so viddeo uses its own dark procedural wallpaper (`graphite`, the nearest to the dark default).
    /// Aspect `auto` means the export preset's own aspect, so there is nothing to store here.
    /// `StageStyle()` itself stays at radius 16 for sessions that predate this default.
    static let newRecordingDefault = StageStyle(paddingRatio: 0.1, cornerRadius: 0, background: .wallpaper(newRecordingWallpaper))

    /// Writes `newRecordingDefault` as `stage-config.json`. The recording flow calls this when a capture finishes,
    /// and that is how a NEW recording is told apart from a legacy one: the editor enables the stage when
    /// `project.json` says so or, absent that flag, when `stage-config.json` exists. A brand-new session has no
    /// `project.json`, so the sidecar switches the stage on, while a legacy session (no sidecar, or a saved
    /// `stageEnabled`) is read exactly as before, and nothing here changes `StageStyle()` or the decoder defaults.
    static func writeNewRecordingDefault(in directory: URL) throws {
        try newRecordingDefault.save(in: directory)
    }

    static let referenceHeight = 1080.0
    static let wallpaperNames = ["aurora", "dusk", "mint", "graphite"]

    /// viddeo-original palettes; the first is the observed default pair.
    static let gradientPresets: [StageGradientPreset] = [
        StageGradientPreset(name: "Signal", stops: [GradientStop(color: "#4776e6", location: 0),
                                                    GradientStop(color: "#8e54e9", location: 1)]),
        StageGradientPreset(name: "Lagoon", stops: [GradientStop(color: "#0f4c5c", location: 0),
                                                    GradientStop(color: "#1f8a70", location: 0.55),
                                                    GradientStop(color: "#8fd694", location: 1)]),
        StageGradientPreset(name: "Harbor", stops: [GradientStop(color: "#1b2a41", location: 0),
                                                    GradientStop(color: "#324a5f", location: 0.5),
                                                    GradientStop(color: "#6c8ead", location: 1)]),
        StageGradientPreset(name: "Apricot", stops: [GradientStop(color: "#f28c5b", location: 0),
                                                     GradientStop(color: "#f6c177", location: 1)]),
        StageGradientPreset(name: "Orchid", stops: [GradientStop(color: "#6a3d9a", location: 0),
                                                    GradientStop(color: "#c77dce", location: 1)]),
        StageGradientPreset(name: "Moss", stops: [GradientStop(color: "#2f3e2e", location: 0),
                                                  GradientStop(color: "#5b7553", location: 0.45),
                                                  GradientStop(color: "#a3b18a", location: 1)]),
        StageGradientPreset(name: "Slate", stops: [GradientStop(color: "#2b2d42", location: 0),
                                                   GradientStop(color: "#5c677d", location: 1)]),
        StageGradientPreset(name: "Coral", stops: [GradientStop(color: "#e05561", location: 0),
                                                   GradientStop(color: "#f2a07b", location: 0.5),
                                                   GradientStop(color: "#f9d9a6", location: 1)])
    ]

    func validate() throws {
        let values = [paddingRatio, cornerRadius, shadow.intensity, shadow.distance, shadow.angle,
                      shadow.blur, inset.size, inset.alpha, backgroundBlur]
        guard values.allSatisfy(\.isFinite) else { throw StageError.invalidStyle("values must be finite") }
        guard (0...0.4).contains(paddingRatio) else { throw StageError.invalidStyle("padding must be 0–0.4") }
        guard (0...200).contains(cornerRadius) else { throw StageError.invalidStyle("corner radius must be 0–200") }
        guard (0...1).contains(shadow.intensity), (0...500).contains(shadow.distance),
              (-360...360).contains(shadow.angle), (0...100).contains(shadow.blur)
        else { throw StageError.invalidStyle("shadow values are out of range") }
        guard (0...100).contains(inset.size), (0...1).contains(inset.alpha),
              Self.rgba(hex: inset.color) != nil
        else { throw StageError.invalidStyle("inset values are out of range") }
        guard (0...100).contains(backgroundBlur) else { throw StageError.invalidStyle("background blur must be 0–100") }
        if deviceMockup.enabled {
            guard let id = deviceMockup.deviceID, DeviceFrameCatalog.geometry(deviceID: id, finish: deviceMockup.finish) != nil else {
                throw StageError.invalidStyle("unknown device frame")
            }
        }
        if let finish = deviceMockup.finish, !DeviceFrameCatalog.finishes.contains(finish) {
            throw StageError.invalidStyle("unknown device finish")
        }
        switch background {
        case .color(let hex):
            guard Self.rgba(hex: hex) != nil else { throw StageError.invalidStyle("malformed color \(hex)") }
        case .gradient(let stops, let start, let end):
            guard stops.count >= 2 else { throw StageError.invalidStyle("a gradient needs at least two stops") }
            for (index, stop) in stops.enumerated() {
                guard Self.rgba(hex: stop.color) != nil else { throw StageError.invalidStyle("malformed color \(stop.color)") }
                guard stop.location.isFinite, (0...1).contains(stop.location),
                      index == 0 || stops[index - 1].location <= stop.location
                else { throw StageError.invalidStyle("gradient stops must be sorted within 0–1") }
            }
            guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite), start != end
            else { throw StageError.invalidStyle("gradient start and end must be distinct finite points") }
        case .image(let path):
            guard Self.isSimpleFileName(path) else {
                throw StageError.invalidStyle("image must be a file name inside the session directory")
            }
        case .wallpaper(let name):
            guard Self.wallpaperNames.contains(name) else { throw StageError.invalidStyle("unknown wallpaper \(name)") }
        }
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` into sRGB components in 0…1.
    static func rgba(hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        return (Double(full >> 24 & 0xFF) / 255, Double(full >> 16 & 0xFF) / 255,
                Double(full >> 8 & 0xFF) / 255, Double(full & 0xFF) / 255)
    }

    /// A single path component: no separators, no `.`/`..`, so it cannot leave the directory.
    static func isSimpleFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0") && !name.hasPrefix("~")
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("stage-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let style = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try style.validate()
        return style
    }

    func save(in directory: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("stage-config.json"), options: .atomic)
    }
}

struct DeviceMockupConfiguration: Codable, Sendable, Equatable {
    var enabled = false
    var deviceID: String? = nil
    var finish: String? = nil
}

struct DeviceFrameGeometry: Codable, Sendable, Equatable {
    var canvasSize: CGSize
    var screenRect: CGRect
    var screenCornerRadius: CGFloat
    var bodyCornerRadius: CGFloat
    var bezelColour: String
}

enum DeviceFrameCatalog {
    static let devices = ["laptop", "desktop display", "tablet", "phone"]
    static let finishes = ["dark", "light"]
    static func geometry(deviceID: String, finish: String?) -> DeviceFrameGeometry? {
        let light = finish == "light"
        let colour = light ? "#c7cbd1" : "#252932"
        switch deviceID {
        case "laptop": return .init(canvasSize: CGSize(width: 1200, height: 760), screenRect: CGRect(x: 58, y: 34, width: 1084, height: 650), screenCornerRadius: 18, bodyCornerRadius: 30, bezelColour: colour)
        case "desktop display": return .init(canvasSize: CGSize(width: 1200, height: 900), screenRect: CGRect(x: 30, y: 28, width: 1140, height: 650), screenCornerRadius: 16, bodyCornerRadius: 28, bezelColour: colour)
        case "tablet": return .init(canvasSize: CGSize(width: 820, height: 1080), screenRect: CGRect(x: 38, y: 38, width: 744, height: 1004), screenCornerRadius: 62, bodyCornerRadius: 78, bezelColour: colour)
        case "phone": return .init(canvasSize: CGSize(width: 520, height: 1080), screenRect: CGRect(x: 34, y: 34, width: 452, height: 1012), screenCornerRadius: 58, bodyCornerRadius: 82, bezelColour: colour)
        default: return nil
        }
    }
}

enum StageError: LocalizedError {
    case invalidStyle(String)
    case invalidOutputSize
    case imageNotFound(String)
    case unreadableImage(String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidStyle(let reason): "Stage settings are invalid: \(reason)."
        case .invalidOutputSize: "The stage output size is invalid."
        case .imageNotFound(let name): "The background image \(name) was not found in the session folder."
        case .unreadableImage(let name): "The background image \(name) could not be read."
        case .renderFailed: "The stage background could not be rendered."
        }
    }
}
