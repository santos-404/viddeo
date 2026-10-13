import AVFoundation
import CoreGraphics
import Foundation
import Synchronization

@MainActor
@main
struct VerifyCaptions {
    static var checks = 0

    static func main() async throws {
        try testNormalization()
        try testTrackPersistence()
        try testEditOperations()
        try testRegenerateMerge()
        try testConfiguration()
        try testGrouping()
        try testPresentation()
        try await testRenderer()
        try await testServiceFlow()
        // Compile-only: the real recognizer is a live-checklist item.
        let _: any CaptionTranscriptionProvider = AppleSpeechCaptionProvider()
        print("Captions verified: \(checks) checks")
    }

    // MARK: Normalization

    private static func testNormalization() throws {
        let cues = CaptionTrack.normalize(rawWords: [
            (" Hel", 0.0, 0.2, 0.9), ("lo", 0.2, 0.4, 0.7), (" world", 0.5, 0.9, nil),
            (" Hi ", 1.0, 1.1, nil), ("there", 1.2, 1.3, nil),
            (" [music", 2.0, 2.5, nil), (" playing]", 2.5, 3.0, nil),
            (" (laughs)", 3.5, 3.8, nil), ("   ", 4.0, 4.1, nil), (" bad", .nan, 5, nil), (" neg", -1, 0.5, nil)
        ])
        try expect(cues.map(\.text) == ["Hello", "world", "Hi", "there", "[music playing]", "(laughs)"],
                   "sub-word merge, bracket runs and invalid tokens: \(cues.map(\.text))")
        try expectClose(cues[0].startMs, 0, "seconds become ms (start)")
        try expectClose(cues[0].endMs, 400, "merged sub-word extends the previous word's end")
        try expect(cues[0].confidence == 0.7, "merged confidence keeps the lower value")
        try expect(cues[1].confidence == nil && cues[1].kind == .word, "plain word cue")
        try expect(cues[4].kind == .soundLabel && cues[4].startMs == 2000 && cues[4].endMs == 3000, "bracket run is one sound label")
        try expect(cues[5].kind == .soundLabel, "parenthesized word is a sound label")
        try expect(cues.allSatisfy { !$0.edited }, "generated cues are not edited")
        let first = CaptionTrack.normalize(rawWords: [("So", 0.1, 0.1, nil)])
        try expect(first.count == 1 && first[0].endMs > first[0].startMs, "first token without space starts a word; zero span gets an end")
    }

    // MARK: Persistence

    private static func testTrackPersistence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(try CaptionTrack.load(from: directory) == nil, "missing captions load as nil")
        let track = sampleTrack()
        try track.save(to: directory)
        let loaded = try CaptionTrack.load(from: directory)
        try expect(loaded == track, "JSON roundtrip is lossless")
        let json = try String(contentsOf: directory.appendingPathComponent("captions.json"), encoding: .utf8)
        try expect(json.contains("\n") && json.range(of: "\"cues\"")!.lowerBound < json.range(of: "\"generator\"")!.lowerBound,
                   "captions.json is pretty-printed with sorted keys")
        try expect(json.contains("\"apple-speech\""), "generator is apple-speech")

        func rejects(_ body: String, _ expected: CaptionError?, _ message: String) throws {
            try body.write(to: directory.appendingPathComponent("captions.json"), atomically: true, encoding: .utf8)
            do {
                _ = try CaptionTrack.load(from: directory)
                try fail(message)
            } catch let error as CaptionError {
                if let expected { try expect(error == expected, "\(message): \(error)") } else {
                    guard case .invalidTrack = error else { return try fail("\(message): \(error)") }
                    checks += 1
                }
            }
        }
        let id1 = UUID().uuidString, id2 = UUID().uuidString
        func cue(_ id: String, _ start: Double, _ end: Double) -> String {
            "{\"id\":\"\(id)\",\"startMs\":\(start),\"endMs\":\(end),\"text\":\"x\",\"kind\":\"word\",\"edited\":false}"
        }
        try rejects("{\"version\":2,\"somethingNew\":true}", .unsupportedVersion(2), "future version rejected")
        try rejects("{\"version\":1,\"locale\":\"en\",\"generator\":\"apple-speech\",\"cues\":[\(cue(id1, 500, 500))]}", nil, "start == end rejected")
        try rejects("{\"version\":1,\"locale\":\"en\",\"generator\":\"apple-speech\",\"cues\":[\(cue(id1, 900, 1000)),\(cue(id2, 100, 200))]}", nil, "unsorted rejected")
        try rejects("{\"version\":1,\"locale\":\"en\",\"generator\":\"apple-speech\",\"cues\":[\(cue(id1, -5, 10))]}", nil, "negative rejected")
        try rejects("{\"version\":1,\"locale\":\"en\",\"generator\":\"apple-speech\",\"cues\":[\(cue(id1, 0, 10)),\(cue(id1, 20, 30))]}", nil, "duplicate id rejected")
        var nan = track
        nan.cues[0].endMs = .infinity
        try expectThrows("non-finite cue rejected") { try nan.validate() }
    }

    // MARK: Editing

    private static func testEditOperations() throws {
        var track = sampleTrack()
        let ids = track.cues.map(\.id)
        try track.updateText(cueID: ids[0], to: "  Howdy ")
        try expect(track.cues[0].text == "Howdy" && track.cues[0].edited, "updateText trims and marks edited")
        try expect(!track.cues[1].edited, "other cues stay unedited")
        try expectError(.emptyText, "empty text rejected") { try track.updateText(cueID: ids[1], to: "  ") }
        try expectError(.cueNotFound, "unknown cue rejected") { try track.updateText(cueID: UUID(), to: "x") }

        // cues: 1000-1400, 1500-1900, 2000-2600
        try track.retime(cueID: ids[1], start: 1399, end: 2001)
        try expect(track.cues[1].startMs == 1399 && track.cues[1].endMs == 2001 && track.cues[1].edited,
                   "retime within 1 ms tolerance is accepted and marks edited")
        try expectThrows("overlap with previous beyond 1 ms rejected") { try track.retime(cueID: ids[1], start: 1398, end: 1900) }
        try expectThrows("overlap with next beyond 1 ms rejected") { try track.retime(cueID: ids[1], start: 1500, end: 2002) }
        try expectThrows("cue shorter than 20 ms rejected") { try track.retime(cueID: ids[1], start: 1500, end: 1519) }
        try expectThrows("reordering rejected") { try track.retime(cueID: ids[2], start: 900, end: 950) }
        try expectThrows("non-finite retime rejected") { try track.retime(cueID: ids[2], start: .nan, end: 2600) }
        try track.retime(cueID: ids[1], start: 1500, end: 1520)
        try expect(track.cues[1].endMs - track.cues[1].startMs == 20, "exactly 20 ms is allowed")
        try track.validate()

        try expectError(.notAdjacent, "non-adjacent merge rejected") { try track.merge(cueID: ids[0], withNext: ids[2]) }
        try track.merge(cueID: ids[1], withNext: ids[2])
        try expect(track.cues.count == 2 && track.cues[1].id == ids[1] && track.cues[1].text == "world again." &&
                   track.cues[1].startMs == 1500 && track.cues[1].endMs == 2600 && track.cues[1].edited,
                   "merge joins text, spans both and keeps the first id")
        try track.delete(cueID: ids[0])
        try expect(track.cues.map(\.id) == [ids[1]], "delete removes the cue")
        try expectError(.cueNotFound, "delete of missing cue rejected") { try track.delete(cueID: ids[0]) }
    }

    private static func testRegenerateMerge() throws {
        var old = sampleTrack()
        try old.updateText(cueID: old.cues[1].id, to: "World")
        let editedID = old.cues[1].id
        let regenerated = CaptionTrack(locale: "en-US", cues: [
            CaptionCue(startMs: 1000, endMs: 1400, text: "Hello"),
            CaptionCue(startMs: 1450, endMs: 1700, text: "wor"),
            CaptionCue(startMs: 1700, endMs: 1950, text: "ld"),
            CaptionCue(startMs: 2000, endMs: 2600, text: "again!"),
            CaptionCue(startMs: 3000, endMs: 3300, text: "More")
        ])
        let merged = old.merging(regenerated: regenerated)
        try expect(merged.cues.map(\.text) == ["Hello", "World", "again!", "More"], "edited cue replaces overlapping regenerated cues: \(merged.cues.map(\.text))")
        try expect(merged.cues[1].id == editedID && merged.cues[1].edited, "edited cue keeps its id")
        try expect(merged.cues[0].id == regenerated.cues[0].id, "unedited cues come from the regenerated track")
        try expect(merged.locale == "en-US", "regenerated metadata wins")
        try merged.validate()
    }

    // MARK: Configuration

    private static func testConfiguration() throws {
        let config = CaptionConfiguration()
        try expect(config.enabled && !config.showSoundLabels && config.font == .sansSerif && config.sizeRatio == 0.05 &&
                   config.color == "#ffffff" && config.backgroundColor == "#000000" &&
                   config.position == .init(x: 0.5, y: 1.0) && config.wordsReveal == .lineByLine &&
                   config.lineGrowth == .leftAnchored && config.wordEntrance == .appear &&
                   config.slideInPixels == 40 && config.fadeInStartOpacity == 0.5, "defaults equal observed values")
        try expect(config.maxCharsPerLine == 42 && config.maxLineDurationSeconds == 5 && config.gapBreakSeconds == 0.8 &&
                   config.backgroundOpacity == 0.6, "viddeo design defaults")
        try config.validate()
        let encoded = try String(data: JSONEncoder().encode(config), encoding: .utf8) ?? ""
        try expect(["\"sans-serif\"", "\"line-by-line\"", "\"left-anchored\"", "\"appear\""].allSatisfy(encoded.contains),
                   "options serialize with observed raw values")
        var fade = config
        fade.wordEntrance = .fadeIn
        try expect(fade.effectiveLineGrowth == .entireLine, "fade-in forces entire-line growth")

        let invalid: [(String, (inout CaptionConfiguration) -> Void)] = [
            ("bad color", { $0.color = "white" }), ("bad background", { $0.backgroundColor = "#00000" }),
            ("zero size", { $0.sizeRatio = 0 }), ("nan size", { $0.sizeRatio = .nan }),
            ("position", { $0.position.x = 1.5 }), ("fade start", { $0.fadeInStartOpacity = 2 }),
            ("max chars", { $0.maxCharsPerLine = 0 }), ("duration", { $0.maxLineDurationSeconds = 0 }),
            ("gap", { $0.gapBreakSeconds = -1 }), ("opacity", { $0.backgroundOpacity = 1.1 }), ("slide", { $0.slideInPixels = -1 })
        ]
        for (name, mutate) in invalid {
            var bad = config
            mutate(&bad)
            try expectThrows("invalid configuration rejected: \(name)") { try bad.validate() }
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(try CaptionConfiguration.load(in: directory) == config, "missing config loads defaults")
        var custom = config
        custom.font = .mono
        custom.wordsReveal = .wordByWord
        try custom.save(in: directory)
        try expect(try CaptionConfiguration.load(in: directory) == custom, "config roundtrip")
        var bad = config
        bad.color = "red"
        try bad.save(in: directory)
        try expectThrows("persisted invalid config rejected") { _ = try CaptionConfiguration.load(in: directory) }
    }

    // MARK: Grouping and presentation

    private static func words(_ items: [(String, Double, Double)], kind: CaptionCue.Kind = .word) -> [CaptionCue] {
        items.map { CaptionCue(startMs: $0.1, endMs: $0.2, text: $0.0, kind: kind) }
    }

    private static func testGrouping() throws {
        let config = CaptionConfiguration()
        let gap = CaptionLayoutPlanner.groups(for: words([("a", 0, 100), ("b", 900, 1000), ("c", 1901, 2000)]), configuration: config)
        try expect(gap.map(\.text) == ["a b", "c"], "gap of exactly 0.8 s stays; above breaks: \(gap.map(\.text))")
        let sentence = CaptionLayoutPlanner.groups(for: words([("Hi.", 0, 100), ("there", 200, 300), ("you?\"", 400, 500), ("ok", 600, 700)]), configuration: config)
        try expect(sentence.map(\.text) == ["Hi.", "there you?\"", "ok"], "sentence-final punctuation breaks: \(sentence.map(\.text))")
        let chars = CaptionLayoutPlanner.groups(for: words((0..<10).map { ("abcde", Double($0) * 100, Double($0) * 100 + 50) }), configuration: config)
        try expect(chars.map(\.words.count) == [7, 3] && chars[0].text.count == 41, "42-character line limit")
        let long = CaptionLayoutPlanner.groups(for: words((0..<8).map { ("w", Double($0) * 1000, Double($0) * 1000 + 500) }), configuration: config)
        try expect(long.map(\.words.count) == [5, 3], "5 s line duration limit: \(long.map(\.words.count))")
        let mixed = words([("one", 0, 100)]) + words([("[music]", 200, 400)], kind: .soundLabel) + words([("two", 500, 600)])
        try expect(CaptionLayoutPlanner.groups(for: mixed, configuration: config).map(\.text) == ["one two"], "sound labels hidden by default")
        var shown = config
        shown.showSoundLabels = true
        try expect(CaptionLayoutPlanner.groups(for: mixed, configuration: shown).map(\.text) == ["one", "[music]", "two"],
                   "shown sound labels are their own line")
    }

    private static func testPresentation() throws {
        let group = CaptionGroup(words: sampleTrack().cues) // 1000-1400, 1500-1900, 2000-2600
        try expect(!group.isVisible(at: 999.9) && group.isVisible(at: 1000) && group.isVisible(at: 2599) && !group.isVisible(at: 2600),
                   "group visible from first start to last end")
        try expect([999, 1000, 1450, 1500, 2599].map(group.presentWordCount) == [0, 1, 1, 2, 3], "presentWordCount counts started words")
        try expect(group.visibleWordIndices(at: 1600, reveal: .lineByLine) == 0..<2, "line-by-line shows started words")
        try expect(group.visibleWordIndices(at: 1600, reveal: .wordByWord) == 1..<2, "word-by-word shows only the current word")
        try expect(group.visibleWordIndices(at: 2700, reveal: .lineByLine).isEmpty, "nothing after the group ends")
        let word = group.words[0]
        var config = CaptionConfiguration()
        try expect(CaptionPresentation.wordOpacity(word, at: 999, configuration: config) == 0 &&
                   CaptionPresentation.wordOpacity(word, at: 1000, configuration: config) == 1, "appear is a step at start")
        config.wordEntrance = .fadeIn
        try expectClose(CaptionPresentation.wordOpacity(word, at: 1000, configuration: config), 0.5, "fade-in starts at 0.5")
        try expectClose(CaptionPresentation.wordOpacity(word, at: 1200, configuration: config), 0.75, "fade-in interpolates over the word")
        try expectClose(CaptionPresentation.wordOpacity(word, at: 1500, configuration: config), 1, "fade-in ends opaque")
        try expect(CaptionPresentation.wordOpacity(word, at: 999, configuration: config) == 0, "fade-in hidden before start")
        config.wordEntrance = .slideIn
        try expectClose(CaptionPresentation.wordOffset(word, at: 1000, configuration: config), 40, "slide-in starts 40 px away")
        try expectClose(CaptionPresentation.wordOffset(word, at: 1200, configuration: config), 20, "slide-in halfway")
        try expectClose(CaptionPresentation.wordOffset(word, at: 1400, configuration: config), 0, "slide-in settles")
        try expect(CaptionPresentation.wordOffset(word, at: 1200, configuration: .init()) == 0, "appear never offsets")
    }

    // MARK: Renderer

    private struct Pixels {
        let width: Int, height: Int, bytesPerRow: Int
        let bytes: [UInt8]
        init(_ image: CGImage) throws {
            guard let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else { throw Failure("unreadable image") }
            width = image.width; height = image.height; bytesPerRow = image.bytesPerRow
            bytes = [UInt8](data)
        }
        /// RGBA at top-left-origin coordinates.
        func at(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = y * bytesPerRow + x * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
        func bounds(_ test: ((r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var result: (Int, Int, Int, Int)?
            for y in 0..<height { for x in 0..<width where test(at(x, y)) {
                if let r = result { result = (min(r.0, x), max(r.1, x), min(r.2, y), max(r.3, y)) } else { result = (x, x, y, y) }
            } }
            return result.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
        }
    }

    private static let size = CGSize(width: 1280, height: 720)

    private static func render(_ config: CaptionConfiguration, at time: Double) throws -> Pixels? {
        try CaptionRenderer(track: sampleTrack(), configuration: config, outputSize: size).cgImage(at: time).map(Pixels.init)
    }

    private static func pill(_ config: CaptionConfiguration, at time: Double) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        guard let pixels = try render(config, at: time), let bounds = pixels.bounds({ $0.a > 0 }) else { throw Failure("no caption at \(time)") }
        return bounds
    }

    private static func testRenderer() async throws {
        let config = CaptionConfiguration()
        let renderer = CaptionRenderer(track: sampleTrack(), configuration: config, outputSize: size)
        try expect(renderer.image(at: 999) == nil && renderer.image(at: 2600) == nil && renderer.image(at: 9000) == nil,
                   "nothing before the first word or after the last word")
        guard let image = renderer.image(at: 1200) else { return try fail("caption image while speaking") }
        try expect(image.extent == CGRect(origin: .zero, size: size), "overlay covers the output")

        guard let pixels = try render(config, at: 1200), let box = pixels.bounds({ $0.a > 0 }),
              let text = pixels.bounds({ $0.a > 200 && $0.r > 200 })
        else { return try fail("visible caption pixels") }
        // Stage is inset 10 %: x 128...1152, y 72...648; position y = 1 sits on the stage bottom.
        try expect(box.minX >= 128 && box.maxX <= 1152 && box.maxY <= 648 && box.maxY >= 645 && box.minY >= 560,
                   "caption box inside the bottom of the inset stage: \(box)")
        try expect(text.minX > box.minX && text.maxX < box.maxX && text.minY > box.minY && text.maxY < box.maxY,
                   "text pixels sit inside the pill")
        let edge = pixels.at(box.minX + 2, (box.minY + box.maxY) / 2)
        try expect((152...154).contains(edge.a) && edge.r == 0 && edge.g == 0 && edge.b == 0,
                   "pill is black at 0.6 opacity: \(edge)")
        try expect(pixels.at(10, 10).a == 0 && pixels.at(640, 300).a == 0, "outside the caption is transparent")

        // Left-anchored: the left edge holds while the right edge grows; full line ends centered.
        let left = try [1200.0, 1600, 2100].map { try pill(config, at: $0) }
        try expect(left[0].minX == left[1].minX && left[1].minX == left[2].minX, "left-anchored keeps its left edge")
        try expect(left[0].maxX < left[1].maxX && left[1].maxX < left[2].maxX, "left-anchored widens as words appear")
        try expect(abs(Double(left[2].minX + left[2].maxX) / 2 - 640) <= 1.5, "complete line is centered at x = 0.5")

        var centered = config
        centered.lineGrowth = .centered
        let center = try [1200.0, 1600, 2100].map { try pill(centered, at: $0) }
        try expect(center.allSatisfy { abs(Double($0.minX + $0.maxX) / 2 - 640) <= 1.5 }, "centered growth stays centered")
        try expect(center[0].maxX - center[0].minX < center[2].maxX - center[2].minX, "centered growth widens")

        var entire = config
        entire.lineGrowth = .entireLine
        try expect(try pill(entire, at: 1000) == pill(entire, at: 2100), "entire-line pill is the full line from the start")

        var byWord = config
        byWord.wordsReveal = .wordByWord
        let single = try pill(byWord, at: 1600)
        try expect(single.maxX - single.minX < left[1].maxX - left[1].minX &&
                   abs(Double(single.minX + single.maxX) / 2 - 640) <= 1.5, "word-by-word shows one centered word")

        var slide = config
        slide.wordEntrance = .slideIn
        guard let early = try render(slide, at: 1500)?.bounds({ $0.a > 200 && $0.r > 200 }),
              let settled = try render(slide, at: 1899)?.bounds({ $0.a > 200 && $0.r > 200 }),
              let plain = try render(config, at: 1899)?.bounds({ $0.a > 200 && $0.r > 200 })
        else { return try fail("slide-in pixels") }
        try expect(early.maxX - settled.maxX >= 37 && early.maxX - settled.maxX <= 41, "slide-in starts ~40 px right: \(early.maxX - settled.maxX)")
        try expect(abs(settled.maxX - plain.maxX) <= 1, "slide-in settles where appear draws")

        var fade = config
        fade.wordEntrance = .fadeIn
        fade.backgroundOpacity = 0
        let fadeStart = try render(fade, at: 1000)?.bytes.enumerated().filter { $0.offset % 4 == 3 }.map(\.element).max() ?? 0
        let fadeEnd = try render(fade, at: 1399)?.bytes.enumerated().filter { $0.offset % 4 == 3 }.map(\.element).max() ?? 0
        try expect((125...131).contains(fadeStart) && fadeEnd >= 250, "fade-in text alpha 0.5 → 1: \(fadeStart) \(fadeEnd)")

        var labels = config
        labels.showSoundLabels = true
        var withLabel = sampleTrack()
        withLabel.cues.append(CaptionCue(startMs: 4000, endMs: 4500, text: "[music]", kind: .soundLabel))
        try expect(CaptionRenderer(track: withLabel, configuration: config, outputSize: size).image(at: 4200) == nil &&
                   CaptionRenderer(track: withLabel, configuration: labels, outputSize: size).image(at: 4200) != nil,
                   "sound labels render only when enabled")
        for font in CaptionConfiguration.Font.allCases {
            var styled = config
            styled.font = font
            try expect(try render(styled, at: 2100) != nil, "\(font.rawValue) renders")
        }

        // Determinism: repeat, fresh instance, and concurrent calls produce identical bytes.
        let reference = try render(config, at: 2100)?.bytes ?? []
        try expect(try render(config, at: 2100)?.bytes == reference && !reference.isEmpty, "identical bytes on repeat")
        let shared = CaptionRenderer(track: sampleTrack(), configuration: config, outputSize: size)
        let concurrent = await withTaskGroup(of: [UInt8].self) { group in
            for _ in 0..<8 { group.addTask { (try? shared.cgImage(at: 2100).map(Pixels.init))??.bytes ?? [] } }
            var all: [[UInt8]] = []
            for await bytes in group { all.append(bytes) }
            return all
        }
        try expect(concurrent.allSatisfy { $0 == reference }, "concurrent renders are identical")
    }

    // MARK: Service flow

    private final class Log<Value: Sendable>: Sendable {
        let values = Mutex<[Value]>([])
        func append(_ value: Value) { values.withLock { $0.append(value) } }
        var all: [Value] { values.withLock { $0 } }
    }

    private struct FakeProvider: CaptionTranscriptionProvider {
        let seen = Log<URL>()

        func transcribe(audioURL: URL, locale: Locale, progress: @Sendable (Double) -> Void) async throws -> [CaptionCue] {
            seen.append(audioURL)
            let file = try AVAudioFile(forReading: audioURL)
            let format = file.processingFormat
            guard format.channelCount == 1, format.sampleRate == 16_000 else { throw Failure("extracted audio must be 16 kHz mono") }
            let seconds = Double(file.length) / format.sampleRate
            guard abs(seconds - 1.5) < 0.1 else { throw Failure("extracted audio lasts \(seconds) s") }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0]
            else { throw Failure("unreadable extracted audio") }
            var sum = 0.0
            for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i] * samples[i]) }
            let rms = (sum / Double(max(1, buffer.frameLength))).squareRoot()
            guard rms > 0.2 else { throw Failure("extracted audio is not the microphone tone (rms \(rms))") }
            progress(0.5)
            progress(1)
            return CaptionTrack.normalize(rawWords: [(" Hello", 0.1, 0.4, 0.9), (" wor", 0.5, 0.7, 0.8), ("ld.", 0.7, 0.9, 0.95)])
        }
    }

    private static func testServiceFlow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Microphone first, system second: selection must use the track title, not order.
        try await writeMovie(to: directory.appendingPathComponent("raw.mp4"), tracks: [("Microphone", 0.5), ("System Audio", 0)])
        let audio = AudioCaptureMetadata(systemAudioRequested: true, microphoneRequested: true, systemAudioSamples: 100,
                                         microphoneSamples: 100, systemAudioDroppedSamples: 0, microphoneDroppedSamples: 0)
        let session = RecordingSession(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), displayID: 1, width: 1280, height: 720,
                                       duration: 1.5, events: [], droppedFrames: 0, eventCaptureAvailable: true, audio: audio)
        try session.save(in: directory)
        let provider = FakeProvider()
        let service = CaptionService(provider: provider)
        let progress = Log<Double>()
        let track = try await service.generate(sessionDirectory: directory, session: session, locale: Locale(identifier: "en_US"),
                                               progress: { progress.append($0) })
        try expect(track.cues.map(\.text) == ["Hello", "world."] && track.cues[1].endMs == 900, "service returns normalized cues")
        try expect(track.locale == "en-US" && track.generator == "apple-speech", "track records BCP-47 locale and generator")
        try expect(try CaptionTrack.load(from: directory) == track, "captions.json saved beside session.json")
        try expect(progress.all == [0.5, 1], "progress is forwarded")
        let temp = provider.seen.all
        try expect(temp.count == 1 && !FileManager.default.fileExists(atPath: temp[0].path), "temporary audio removed")

        var edited = track
        try edited.updateText(cueID: track.cues[1].id, to: "World!")
        try edited.save(to: directory)
        let again = try await service.generate(sessionDirectory: directory, session: session, locale: Locale(identifier: "en_US"))
        try expect(again.cues.map(\.text) == ["Hello", "World!"] && again.cues[1].id == track.cues[1].id &&
                   again.cues[0].id != track.cues[0].id, "regeneration keeps edited cues and replaces the rest")

        var silent = session
        silent.audio?.microphoneRequested = false
        try await expectAsyncError(.noMicrophoneAudio, "session without microphone audio rejected") {
            _ = try await service.generate(sessionDirectory: directory, session: silent, locale: Locale(identifier: "en_US"))
        }
        let future = "{\"version\":9}"
        try future.write(to: directory.appendingPathComponent("captions.json"), atomically: true, encoding: .utf8)
        try await expectAsyncError(.unsupportedVersion(9), "future captions file is not overwritten") {
            _ = try await service.generate(sessionDirectory: directory, session: session, locale: Locale(identifier: "en_US"))
        }
        try expect(try String(contentsOf: directory.appendingPathComponent("captions.json"), encoding: .utf8) == future,
                   "future captions file left untouched")
    }

    /// Writes AAC tracks like ScreenRecorder (48 kHz stereo, title metadata); amplitude 0 is silence, else a 440 Hz tone.
    private static func writeMovie(to url: URL, tracks: [(title: String, amplitude: Float)]) async throws {
        let scratch = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var feeds: [(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput, reader: AVAssetReader, done: Bool)] = []
        for (index, track) in tracks.enumerated() {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 72_000),
                  let channels = buffer.floatChannelData else { throw Failure("PCM buffer") }
            buffer.frameLength = 72_000
            for frame in 0..<72_000 {
                let value = track.amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000))
                channels[0][frame] = value
                channels[1][frame] = value
            }
            let wav = scratch.appendingPathComponent("\(index).wav")
            do {
                let file = try AVAudioFile(forWriting: wav, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }
            let asset = AVURLAsset(url: wav)
            let reader = try AVAssetReader(asset: asset)
            let source = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = source.first else { throw Failure("wav track") }
            let output = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = track.title as NSString
            input.metadata = [title]
            writer.add(input)
            guard reader.startReading() else { throw Failure("wav reader") }
            feeds.append((input, output, reader, false))
        }
        guard writer.startWriting() else { throw writer.error ?? Failure("writer") }
        writer.startSession(atSourceTime: .zero)
        while feeds.contains(where: { !$0.done }) {
            for index in feeds.indices where !feeds[index].done && feeds[index].input.isReadyForMoreMediaData {
                if let sample = feeds[index].output.copyNextSampleBuffer() {
                    guard feeds[index].input.append(sample) else { throw writer.error ?? Failure("append") }
                } else {
                    feeds[index].input.markAsFinished()
                    feeds[index].done = true
                }
            }
            try await Task.sleep(nanoseconds: 100_000)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure("finish") }
    }

    // MARK: Helpers

    private static func sampleTrack() -> CaptionTrack {
        CaptionTrack(locale: "en-US", cues: [
            CaptionCue(startMs: 1000, endMs: 1400, text: "Hello", confidence: 0.9),
            CaptionCue(startMs: 1500, endMs: 1900, text: "world"),
            CaptionCue(startMs: 2000, endMs: 2600, text: "again.")
        ])
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verify-captions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func fail(_ message: String) throws { throw Failure("FAILED: \(message)") }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure("FAILED: \(message)") }
        checks += 1
    }

    private static func expectClose(_ value: Double, _ expected: Double, _ message: String) throws {
        try expect(abs(value - expected) < 0.0001, "\(message) (got \(value), expected \(expected))")
    }

    private static func expectThrows(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw Failure("FAILED: \(message)")
    }

    private static func expectError(_ expected: CaptionError, _ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch let error as CaptionError where error == expected { checks += 1; return } catch {
            throw Failure("FAILED: \(message): \(error)")
        }
        throw Failure("FAILED: \(message)")
    }

    private static func expectAsyncError(_ expected: CaptionError, _ message: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch let error as CaptionError where error == expected { checks += 1; return } catch {
            throw Failure("FAILED: \(message): \(error)")
        }
        throw Failure("FAILED: \(message)")
    }
}
