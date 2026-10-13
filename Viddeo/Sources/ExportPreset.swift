import Foundation

// Observed formats and option tables follow the original export settings.
enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case mp4, gif
}

enum ExportQuality: String, Codable, Sendable, CaseIterable {
    case studio, socialMedia = "social-media", webHigh = "web-high", webLow = "web-low"

    var bitsPerPixelFrame: Double {
        switch self {
        case .webLow: 0.0075
        case .webHigh: 0.0175
        case .socialMedia: 0.05
        case .studio: 0.3
        }
    }

    var referenceQuantizer: Int {
        switch self {
        case .webLow: 42
        case .webHigh: 30
        case .socialMedia: 24
        case .studio: 14
        }
    }

    var label: String {
        switch self {
        case .studio: "Studio"
        case .socialMedia: "Social Media"
        case .webHigh: "Web"
        case .webLow: "Web (Low)"
        }
    }
}

enum ExportCodec: String, Codable, Sendable, CaseIterable {
    case h264, h265, both
}

enum ExportAspectRatio: Sendable, Equatable {
    case auto, preset(Ratio), custom(Double)

    enum Ratio: String, Codable, Sendable, CaseIterable {
        case wide = "16:9", fourThree = "4:3", square = "1:1", threeFour = "3:4", tall = "9:16"
        var value: Double {
            switch self {
            case .wide: 16.0 / 9
            case .fourThree: 4.0 / 3
            case .square: 1
            case .threeFour: 3.0 / 4
            case .tall: 9.0 / 16
            }
        }
    }

    func value(sourceWidth: Int, sourceHeight: Int) -> Double {
        switch self {
        case .auto: Double(sourceWidth) / Double(sourceHeight)
        case let .preset(ratio): ratio.value
        case let .custom(value): value
        }
    }
}

extension ExportAspectRatio: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            if text == "auto" { self = .auto; return }
            if let ratio = Ratio(rawValue: text) { self = .preset(ratio); return }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown export aspect ratio.")
        }
        let number = try container.decode(Double.self)
        guard number.isFinite, number > 0 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Aspect ratio must be finite and positive.")
        }
        self = .custom(number)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case let .preset(ratio): try container.encode(ratio.rawValue)
        case let .custom(value): try container.encode(value)
        }
    }
}

struct ExportSettings: Codable, Sendable, Equatable {
    var format: ExportFormat
    var quality: ExportQuality
    var fps: Int
    var height: Int
    var codec: ExportCodec
    var aspectRatio: ExportAspectRatio
    var gifDisableLoop: Bool

    init(format: ExportFormat = .mp4, quality: ExportQuality = .socialMedia, fps: Int = 60,
         height: Int = 720, codec: ExportCodec = .h264, aspectRatio: ExportAspectRatio = .auto,
         gifDisableLoop: Bool = false) {
        self.format = format; self.quality = quality; self.fps = fps; self.height = height
        self.codec = codec; self.aspectRatio = aspectRatio; self.gifDisableLoop = gifDisableLoop
    }

    // Observed option values and normalization rules.
    static func allowedFPS(for format: ExportFormat) -> [Int] {
        format == .mp4 ? [60, 50, 30, 25, 24, 20, 10] : [50, 30, 25, 20, 15, 10]
    }

    static func allowedQualities(for format: ExportFormat) -> [ExportQuality] {
        format == .mp4 ? [.studio, .socialMedia, .webHigh, .webLow] : [.studio, .socialMedia]
    }

    static func allowedHeights(for format: ExportFormat, quality: ExportQuality) -> [Int] {
        let values = format == .mp4 ? [720, 1080, 2160] : [480, 720, 1080]
        return (quality == .webHigh || quality == .webLow) ? values.filter { $0 <= 1080 } : values
    }

    func normalized() -> ExportSettings {
        var result = self
        let qualities = Self.allowedQualities(for: format)
        if !qualities.contains(quality) { result.quality = qualities[0] }
        let fpsValues = Self.allowedFPS(for: format)
        if !fpsValues.contains(fps) {
            result.fps = fpsValues.filter { $0 <= fps }.max() ?? fpsValues.max()!
        }
        let heights = Self.allowedHeights(for: format, quality: result.quality)
        if !heights.contains(height) {
            result.height = heights.filter { $0 <= height }.max() ?? heights.max()!
        }
        if format == .mp4 && codec == .both { result.codec = .both }
        return result
    }

    // Observed even-floor and maximum-canvas sizing behavior.
    func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let ratio = aspectRatio.value(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        var h = Self.evenFloor(Double(height))
        var w = Self.evenFloor(Double(h) * ratio)
        if w > 3840 || h > 2160 {
            let scale = min(3840 / Double(w), 2160 / Double(h))
            w = Self.evenFloor(Double(w) * scale)
            h = Self.evenFloor(Double(h) * scale)
        }
        return (w, h)
    }

    static func evenFloor(_ value: Double) -> Int {
        let rounded = value.rounded()
        let integer = abs(value - rounded) < 1e-6 ? Int(rounded) : Int(floor(value))
        let even = integer.isMultiple(of: 2) ? integer : integer - 1
        return max(even, 2)
    }

    // Observed bitrate fallback formula; quantizers remain informational.
    func videoBitsPerSecond(width: Int, height: Int) -> Int {
        Int((Double(width) * Double(height) * Double(fps) * quality.bitsPerPixelFrame).rounded(.down))
    }

    var codecsToWrite: [ExportCodec] {
        guard format == .mp4 else { return [] }
        switch codec { case .h264: return [ExportCodec.h264]; case .h265: return [ExportCodec.h265]; case .both: return [ExportCodec.h264, .h265] }
    }

    func outputURLs(for destination: URL) -> [(codec: ExportCodec, url: URL)] {
        codecsToWrite.map { codec in
            guard self.codec == .both, codec == .h265 else { return (codec, destination) }
            let extensionName = destination.pathExtension
            let stem = destination.deletingPathExtension().lastPathComponent + "-h265"
            let parent = destination.deletingLastPathComponent()
            let url = extensionName.isEmpty ? parent.appendingPathComponent(stem) : parent.appendingPathComponent(stem).appendingPathExtension(extensionName)
            return (codec, url)
        }
    }

    func validate() throws {
        let values: [Double] = [Double(fps), Double(height)]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ExportSettingsError.invalidValues }
        if case let .custom(value) = aspectRatio, !value.isFinite || value <= 0 {
            throw ExportSettingsError.invalidValues
        }
        if case .auto = aspectRatio, (fps <= 0 || height <= 0) { throw ExportSettingsError.invalidValues }
    }

    static let mp4Default = ExportSettings()
    static let gifDefault = ExportSettings(format: .gif, quality: .studio, fps: 15, height: 480)
    static let shareLinkDefault = ExportSettings(format: .mp4, quality: .socialMedia, fps: 60, height: 1080)

    private enum CodingKeys: String, CodingKey { case format, quality, fps, height, codec, aspectRatio, gifDisableLoop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(ExportFormat.self, forKey: .format)
        quality = try values.decode(ExportQuality.self, forKey: .quality)
        fps = try values.decode(Int.self, forKey: .fps)
        height = try values.decode(Int.self, forKey: .height)
        let rawCodec = try values.decodeIfPresent(String.self, forKey: .codec) ?? "h264"
        codec = rawCodec == "av1" ? .h264 : (ExportCodec(rawValue: rawCodec) ?? .h264)
        aspectRatio = try values.decodeIfPresent(ExportAspectRatio.self, forKey: .aspectRatio) ?? .auto
        gifDisableLoop = try values.decodeIfPresent(Bool.self, forKey: .gifDisableLoop) ?? false
    }
}

enum ExportSettingsError: LocalizedError {
    case invalidValues
    var errorDescription: String? { "Export settings contain non-finite or non-positive values." }
}

struct ExportPreset: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var settings: ExportSettings
}

struct ExportPresetCatalog: Codable, Sendable {
    var presets: [ExportPreset]
    var defaultPresetID: String

    // These preset ids and names are viddeo design choices, separate from observed source behavior.
    static let builtIn = ExportPresetCatalog(presets: [
        .init(id: "mp4-720p-social", name: "720p Social", settings: .mp4Default),
        .init(id: "mp4-1080p-social", name: "1080p Social", settings: .init(height: 1080)),
        .init(id: "mp4-1080p-web", name: "1080p Web", settings: .init(quality: .webHigh, height: 1080)),
        .init(id: "mp4-720p-web-low", name: "720p Web (Low)", settings: .init(quality: .webLow)),
        .init(id: "mp4-2160p-studio", name: "2160p Studio", settings: .init(quality: .studio, height: 2160)),
        .init(id: "mp4-1080p-hevc", name: "1080p HEVC", settings: .init(height: 1080, codec: .h265)),
        .init(id: "mp4-1080p-both", name: "1080p H.264 + HEVC", settings: .init(height: 1080, codec: .both)),
        .init(id: "mp4-vertical-9x16-1080p", name: "1080p Vertical", settings: .init(height: 1080, aspectRatio: .preset(.tall))),
        .init(id: "mp4-square-1080p", name: "1080p Square", settings: .init(height: 1080, aspectRatio: .preset(.square))),
        .init(id: "gif-480p", name: "480p GIF", settings: .gifDefault),
        .init(id: "gif-720p-studio", name: "720p GIF Studio", settings: .init(format: .gif, quality: .studio, fps: 30, height: 720))
    ], defaultPresetID: "mp4-720p-social")

    static func load(from directory: URL) throws -> ExportPresetCatalog {
        let url = directory.appendingPathComponent("export-presets.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .builtIn }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        var ids = Set<String>()
        for preset in catalog.presets {
            guard ids.insert(preset.id).inserted else { throw ExportPresetCatalogError.duplicateID(preset.id) }
            try preset.settings.validate()
        }
        guard ids.contains(catalog.defaultPresetID) else { throw ExportPresetCatalogError.unknownDefault }
        return catalog
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("export-presets.json"), options: .atomic)
    }

    func preset(id: String) -> ExportPreset? { presets.first { $0.id == id } }
}

enum ExportPresetCatalogError: LocalizedError {
    case duplicateID(String), unknownDefault
    var errorDescription: String? {
        switch self {
        case let .duplicateID(id): "Export preset id is duplicated: \(id)"
        case .unknownDefault: "Export preset catalog references an unknown default preset id."
        }
    }
}
