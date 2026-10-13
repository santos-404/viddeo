import Foundation

@main
struct VerifyPresets {
    static func main() throws {
        try expect(ExportFormat.allCases.map(\.rawValue) == ["mp4", "gif"], "formats")
        try expect(ExportSettings.allowedFPS(for: .mp4) == [60, 50, 30, 25, 24, 20, 10], "mp4 fps")
        try expect(ExportSettings.allowedFPS(for: .gif) == [50, 30, 25, 20, 15, 10], "gif fps")
        try expect(ExportSettings.allowedQualities(for: .mp4) == [.studio, .socialMedia, .webHigh, .webLow], "mp4 qualities")
        try expect(ExportSettings.allowedQualities(for: .gif) == [.studio, .socialMedia], "gif qualities")
        try expect(ExportSettings.allowedHeights(for: .mp4, quality: .studio) == [720, 1080, 2160], "mp4 heights")
        try expect(ExportSettings.allowedHeights(for: .gif, quality: .studio) == [480, 720, 1080], "gif heights")
        try expect(ExportSettings.allowedHeights(for: .mp4, quality: .webHigh) == [720, 1080], "web height cap")
        try expect(ExportSettings.mp4Default == .init(), "mp4 default")
        try expect(ExportSettings.gifDefault == .init(format: .gif, quality: .studio, fps: 15, height: 480), "gif default")
        try expect(ExportSettings.shareLinkDefault.height == 1080, "share link default")

        var settings = ExportSettings(fps: 45, height: 900)
        settings = settings.normalized()
        try expect(settings.fps == 30 && settings.height == 720, "normalization chooses greatest allowed values below request")
        try expect(ExportSettings(height: 5000).normalized().height == 2160, "height upper normalization")
        try expect(ExportSettings(format: .gif, height: 1080).normalized().height == 1080, "gif 1080")
        try expect(ExportSettings(quality: .webLow, height: 2160).normalized().height == 1080, "web height normalization")
        try expect(ExportSettings(format: .gif, quality: .webHigh).normalized().quality == .studio, "quality normalization")
        try expect(ExportSettings.evenFloor(720.0000001) == 720 && ExportSettings.evenFloor(719.4) == 718, "evenFloor tolerance")

        try size(ExportSettings(height: 720), 2560, 1440, 1280, 720)
        try size(ExportSettings(height: 1080), 2560, 1440, 1920, 1080)
        try size(ExportSettings(height: 2160), 2560, 1440, 3840, 2160)
        try size(ExportSettings(height: 1080, aspectRatio: .preset(.tall)), 1, 1, 606, 1080)
        try size(ExportSettings(height: 2160, aspectRatio: .preset(.square)), 1, 1, 2160, 2160)
        try size(ExportSettings(height: 2160, aspectRatio: .preset(.fourThree)), 1, 1, 2880, 2160)
        try size(ExportSettings(height: 1080, aspectRatio: .custom(3)), 1, 1, 3240, 1080)
        try size(ExportSettings(height: 1080, aspectRatio: .custom(4)), 1, 1, 3840, 960)
        try expect(ExportSettings(quality: .socialMedia, fps: 60).videoBitsPerSecond(width: 1280, height: 720) == 2_764_800, "social bitrate")
        try expect(ExportSettings(quality: .studio, fps: 30).videoBitsPerSecond(width: 1920, height: 1080) == 18_662_400, "studio bitrate")
        try expect(ExportSettings(quality: .webLow, fps: 10).videoBitsPerSecond(width: 101, height: 99) == 749, "bitrate flooring")
        try expect(ExportQuality.allCases.map(\.referenceQuantizer) == [14, 24, 30, 42], "reference quantizers")

        let destination = URL(fileURLWithPath: "/tmp/movie.mp4")
        let both = ExportSettings(codec: .both).outputURLs(for: destination)
        try expect(both.map(\.codec) == [.h264, .h265], "both codec list")
        try expect(both.map { $0.url.lastPathComponent } == ["movie.mp4", "movie-h265.mp4"], "both URL suffix")
        try expect(ExportSettings(codec: .h265).outputURLs(for: destination).first?.url == destination, "single codec URL")
        try expect(ExportSettings(format: .gif).codecsToWrite.isEmpty, "GIF has no video codecs")

        let catalog = ExportPresetCatalog.builtIn
        for preset in catalog.presets {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(ExportPreset.self, from: data)
            try expect(decoded == preset, "preset JSON roundtrip: \(preset.id)")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-presets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try expect(try ExportPresetCatalog.load(from: temporary).presets == catalog.presets, "missing catalog fallback")
        try catalog.save(to: temporary)
        try expect(try ExportPresetCatalog.load(from: temporary).presets == catalog.presets, "catalog save/load")
        try expect(catalog.preset(id: catalog.defaultPresetID) != nil, "preset lookup")
        let file = temporary.appendingPathComponent("export-presets.json")
        let duplicate = ExportPresetCatalog(presets: [catalog.presets[0], catalog.presets[0]], defaultPresetID: catalog.presets[0].id)
        try JSONEncoder().encode(duplicate).write(to: file)
        try expectThrows("duplicate ids") { _ = try ExportPresetCatalog.load(from: temporary) }
        let invalid = #"{"presets":[{"id":"bad","name":"Bad","settings":{"format":"mp4","quality":"studio","fps":60,"height":720,"codec":"h264","aspectRatio":0,"gifDisableLoop":false}}],"defaultPresetID":"bad"}"#
        try Data(invalid.utf8).write(to: file)
        try expectThrows("invalid catalog") { _ = try ExportPresetCatalog.load(from: temporary) }
        try Data("{bad".utf8).write(to: file)
        try expectThrows("malformed catalog") { _ = try ExportPresetCatalog.load(from: temporary) }

        try expect(try JSONDecoder().decode(ExportAspectRatio.self, from: Data(#""16:9""#.utf8)) == .preset(.wide), "aspect string decode")
        try expect(try JSONDecoder().decode(ExportAspectRatio.self, from: Data("1.5".utf8)) == .custom(1.5), "aspect number decode")
        let av1 = #"{"format":"mp4","quality":"studio","fps":60,"height":720,"codec":"av1","aspectRatio":"auto","gifDisableLoop":false}"#
        try expect(try JSONDecoder().decode(ExportSettings.self, from: Data(av1.utf8)).codec == .h264, "AV1 tolerance")
        print("Export presets verified: 11 presets, 39 checks")
    }

    private static func size(_ settings: ExportSettings, _ sourceWidth: Int, _ sourceHeight: Int,
                             _ expectedWidth: Int, _ expectedHeight: Int) throws {
        let output = settings.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        try expect(output.width == expectedWidth && output.height == expectedHeight,
                   "output size expected \(expectedWidth)x\(expectedHeight), got \(output.width)x\(output.height)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationError.failed(message) }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw VerificationError.failed("expected failure: \(message)")
    }
}

enum VerificationError: Error { case failed(String) }
