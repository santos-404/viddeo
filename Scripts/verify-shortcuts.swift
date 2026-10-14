import CoreGraphics
import Foundation

@main
struct VerifyShortcuts {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "VerifyShortcuts", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func event(_ time: Double, _ key: String, _ modifiers: ShortcutModifiers, code: Int = 8) -> ShortcutEvent {
            ShortcutEvent(time: time, keyCode: code, key: key, modifiers: modifiers)
        }

        // Capture classification: the privacy boundary.
        var lookups = 0
        func classify(_ code: Int, _ modifiers: ShortcutModifiers, character: String? = "c") -> ShortcutEvent? {
            ShortcutCapture.classify(keyCode: code, modifiers: modifiers, time: 1) { lookups += 1; return character }
        }
        try check(classify(8, []) == nil && lookups == 0, "plain letters are never captured and never even looked up")
        try check(classify(8, .shift) == nil && classify(8, [.shift, .capsLock]) == nil && classify(8, .function) == nil && lookups == 0,
                  "shift-only, caps-lock and fn-only typing are never captured")
        try check(classify(49, []) == nil && classify(49, .shift) == nil, "plain and shifted Space is text")
        for code in [0, 18, 29, 40, 44] { try check(classify(code, []) == nil && classify(code, .shift) == nil, "typed key \(code) is not captured") }
        try check(lookups == 0, "no character lookup for anything that is not a shortcut")
        try check(classify(8, .command)?.key == "C" && classify(8, .command)?.modifiers == .command, "cmd+C keeps modifier and uppercase layout character")
        try check(classify(8, [.command, .shift])?.modifiers == [.command, .shift], "shift is kept next to a primary modifier")
        try check(classify(6, .option, character: "z")?.key == "Z" && classify(6, .control, character: "z")?.key == "Z", "option and control count")
        try check(classify(8, [.command, .capsLock])?.modifiers == .command, "caps lock state is dropped")
        try check(classify(49, .command)?.key == "space", "space with a modifier is a shortcut")
        try check(classify(53, [])?.key == "escape" && classify(36, [])?.key == "return" && classify(48, [])?.key == "tab"
                  && classify(51, [])?.key == "delete" && classify(123, [])?.key == "left" && classify(126, [])?.key == "up"
                  && classify(122, [])?.key == "f1" && classify(111, [])?.key == "f12" && classify(115, [])?.key == "home"
                  && classify(119, [])?.key == "end" && classify(116, [])?.key == "pageUp" && classify(121, [])?.key == "pageDown",
                  "special keys are captured without modifiers")
        try check(classify(123, .function)?.modifiers == [] && classify(123, [.function, .command])?.modifiers == .command,
                  "hardware fn flag on arrows is dropped")
        try check(classify(8, .command, character: nil)?.key == "key8" && classify(8, .command, character: " ")?.key == "key8",
                  "missing layout character falls back to the key code")

        // Grouping, timing, stagger.
        let events = [
            event(1.0, "C", .command), event(2.5, "C", .command), event(4.5, "C", .command),
            event(4.6, "V", .command, code: 9), event(10.0, "4", [.command, .shift], code: 21),
            event(10.05, "escape", [], code: 53), event(20, "space", .control, code: 49)
        ]
        let presses = ShortcutOverlayPlanner.presses(events: events)
        try check(presses.map(\.count) == [3, 1, 1, 1, 1], "identical shortcuts 2000 ms apart group (boundary inclusive)")
        try check(presses[0].firstKeyDownMs == 1000 && presses[0].lastKeyDownMs == 4500, "group first/last key-down")
        let split = ShortcutOverlayPlanner.presses(events: [event(1, "C", .command), event(3.001, "C", .command)])
        try check(split.count == 2, "gap above 2000 ms starts a new group")
        try check(ShortcutOverlayPlanner.presses(events: [event(1, "C", .command), event(1.2, "C", [.command, .shift])]).count == 2,
                  "different modifier sets are different shortcuts")
        let plain = [event(1, "A", [], code: 0), event(2, "space", [], code: 49), event(3, "B", .shift, code: 11)]
        try check(ShortcutOverlayPlanner.presses(events: plain).isEmpty, "model drops non-shortcuts from foreign data")
        try check(ShortcutOverlayPlanner.presses(events: plain, showSingleLetters: true).count == 3, "showSingleLetters admits them")

        var config = ShortcutOverlayConfiguration()
        try check(!config.enabled && config.sizeRatio == 0.1 && config.hiddenShortcuts.isEmpty && !config.showSingleLetters, "defaults")
        let items = ShortcutOverlayPlanner.items(events: events, configuration: config)
        try check(items.count == 5, "one item per press group")
        let first = items[0]
        try check(first.startMs == 900, "appears 100 ms before the first key-down")
        // The paste at 4.6 s cuts the copy group (hold would reach 6000 ms) off at its own start.
        try check(abs(items[0].endMs - 4500) < 1e-6 && abs(items[1].startMs - 4500) < 1e-6, "following press cuts the previous off; start never precedes its last key-down")
        try check(abs(items[1].endMs - 6100) < 1e-6, "holds 1500 ms after the last key-down")
        try check(items[3].startMs == 10000 && abs(items[2].endMs - 10000) < 1e-6 && items[2].endMs <= items[2].press.lastKeyDownMs + 1500,
                  "overlapping press shortens the earlier item")
        for (a, b) in zip(items, items.dropFirst()) { try check(a.endMs <= b.startMs + 1e-9, "items never overlap") }
        let solo = ShortcutOverlayPlanner.items(events: [event(5, "C", .command)], configuration: config)[0]
        try check(solo.startMs == 4900 && solo.endMs == 6500, "solo item spans -100 ms to +1500 ms")
        try check(!solo.isVisible(atMs: 4899) && solo.isVisible(atMs: 4900) && solo.isVisible(atMs: 6499) && !solo.isVisible(atMs: 6500), "visibility interval")
        try check(solo.opacity(atMs: 4900) == 0 && solo.opacity(atMs: 6000) == 1 && solo.opacity(atMs: 6500) == 0 && solo.opacity(atMs: 4800) == 0,
                  "opacity outside and at fade edges")
        try check(solo.opacity(atMs: 4975) > 0.4 && solo.opacity(atMs: 4975) < 0.6 && solo.opacity(atMs: 5050) == 1, "150 ms eased fade-in")
        try check(solo.opacity(atMs: 6425) > 0.4 && solo.opacity(atMs: 6425) < 0.6, "150 ms eased fade-out")
        let multi = ShortcutOverlayPlanner.items(events: [event(5, "4", [.command, .shift], code: 21)], configuration: config)[0]
        try check(multi.caps.count == 3, "modifiers plus key make three caps")
        // Cap k starts fading in 60 ms after cap k-1.
        try check(multi.opacity(atMs: 4900 + 60, keyIndex: 0) > 0 && multi.opacity(atMs: 4900 + 60, keyIndex: 1) == 0
                  && multi.opacity(atMs: 4900 + 120, keyIndex: 1) > 0 && multi.opacity(atMs: 4900 + 120, keyIndex: 2) == 0
                  && multi.opacity(atMs: 4900 + 180, keyIndex: 2) > 0, "60 ms per-key stagger")

        // Hidden shortcuts are keyed by the first-press time in ms.
        try check(first.press.hiddenKey == "1000" && presses[2].hiddenKey == "10000", "hidden key is first press ms")
        config.setHidden(true, for: presses[1])
        try check(config.hiddenShortcuts == ["4600": true], "hide stores the key")
        let remaining = ShortcutOverlayPlanner.items(events: events, configuration: config)
        try check(remaining.count == 4 && !remaining.contains { $0.press.key == "V" }, "hidden press is not displayed")
        try check(abs(remaining[0].endMs - 6000) < 1e-6, "hidden press no longer cuts the previous one off")
        config.setHidden(false, for: presses[1])
        try check(config.hiddenShortcuts.isEmpty, "unhide removes the key")

        // Glyph strings and widths.
        func glyph(_ key: String, _ modifiers: ShortcutModifiers = []) -> String { ShortcutPress(modifiers: modifiers, key: key, firstKeyDownMs: 0, lastKeyDownMs: 0, count: 1).glyphString }
        try check(glyph("4", [.command, .shift]) == "⌘⇧4", "cmd shift 4")
        try check(glyph("K", [.control, .option, .command, .shift]) == "⌘⌥⌃⇧K", "observed modifier order")
        try check(glyph("escape") == "⎋" && glyph("return") == "⏎" && glyph("tab") == "⇥" && glyph("delete") == "⌫" && glyph("space", .command) == "⌘␣",
                  "special glyphs")
        try check(glyph("C", [.function, .capsLock, .command]) == "fn⇪⌘C" && glyph("f5") == "F5" && glyph("left") == "←", "fn, caps lock, F-key, arrow")
        try check(ShortcutGlyphs.keyCap("space").widthRatio == 1.66 && ShortcutGlyphs.keyCap("C").widthRatio == 1 && ShortcutGlyphs.keyCap("f12").widthRatio > 1,
                  "space width 1.66, letters square, wide labels widen")

        // Configuration persistence and validation.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-shortcuts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try check(try ShortcutOverlayConfiguration.load(in: directory) == ShortcutOverlayConfiguration(), "absent file means defaults")
        config.enabled = true
        config.sizeRatio = 0.14
        config.setHidden(true, for: presses[0])
        try config.save(in: directory)
        try check(try ShortcutOverlayConfiguration.load(in: directory) == config, "shortcuts-config.json roundtrip")
        try Data("{\"enabled\":true}".utf8).write(to: directory.appendingPathComponent(ShortcutOverlayConfiguration.filename))
        try check(try ShortcutOverlayConfiguration.load(in: directory).sizeRatio == 0.1, "missing keys default")
        var bad = ShortcutOverlayConfiguration()
        bad.sizeRatio = 2
        do { try bad.validate(); throw NSError(domain: "VerifyShortcuts", code: 2) } catch ShortcutOverlayError.invalidConfiguration { checks += 1 }

        // Renderer: nothing when disabled; bottom-centered when enabled.
        let content = CGRect(x: 100, y: 50, width: 800, height: 400)
        let size = CGSize(width: 1000, height: 600)
        let off = ShortcutOverlayRenderer(events: events, configuration: ShortcutOverlayConfiguration(), outputSize: size, contentRect: content)
        try check(off.items.isEmpty && off.cgImage(atMs: 1200) == nil, "disabled renders nothing")
        var enabled = ShortcutOverlayConfiguration()
        enabled.enabled = true
        let renderer = ShortcutOverlayRenderer(events: events, configuration: enabled, outputSize: size, contentRect: content)
        try check(renderer.cgImage(atMs: 500) == nil && renderer.cgImage(atMs: 1200) != nil, "renders only while visible")
        let layout = renderer.layout(for: renderer.items[0])
        try check(abs(layout.height - 40) < 1e-9 && abs((layout.rects.first!.minX + layout.rects.last!.maxX) / 2 - 500) < 1e-9 && abs(layout.rects[0].minY - (50 + 24)) < 1e-9,
                  "cap height is 10 % of stage height, centered, above the stage bottom")
        let wide = ShortcutOverlayRenderer(events: [event(1, "C", [.function, .command, .option, .control, .shift])], configuration: {
            var c = enabled; c.sizeRatio = 0.3; return c }(), outputSize: size, contentRect: content)
        let wideLayout = wide.layout(for: wide.items[0])
        try check(wideLayout.rects.last!.maxX - wideLayout.rects.first!.minX <= 800 * 0.92 + 1e-6, "wide shortcuts shrink to fit the stage")
        print("Shortcut overlay verified: \(checks) checks")
    }
}
