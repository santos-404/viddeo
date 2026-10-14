import CoreGraphics
import Foundation

@main
struct VerifyEvents {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "VerifyEvents", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let storage = CursorEventStorage()
        let bounds = CGRect(x: -1000, y: -200, width: 1000, height: 800)
        let point = CGPoint(x: -750, y: 0)
        storage.reset(bounds: bounds, initialLocation: point)
        storage.record(type: .keyDown, location: .zero, hostSeconds: 11)
        storage.setAnchor(hostSeconds: 10)
        try check(storage.keystrokes(through: 4).isEmpty, "keys require explicit opt-in")
        try check(storage.events(through: 4) == [CursorEvent(time: 0, x: 0.25, y: 0.25, kind: .move)], "stationary pointer and negative display origins")
        storage.reset(bounds: bounds, capturesKeystrokes: true, initialLocation: point)
        storage.record(type: .mouseMoved, location: CGPoint(x: -500, y: 200), hostSeconds: 9.8)
        storage.record(type: .keyDown, location: CGPoint(x: 5000, y: 5000), hostSeconds: 9.9)
        storage.record(type: .keyDown, location: CGPoint(x: 5000, y: 5000), hostSeconds: 10.3)
        storage.record(type: .keyDown, location: .zero, hostSeconds: 11)
        storage.record(type: .keyDown, location: .zero, hostSeconds: 15)
        storage.record(type: .keyDown, location: .zero, hostSeconds: .nan)
        storage.record(type: .leftMouseDown, location: CGPoint(x: -500, y: 200), hostSeconds: 11.5)
        storage.record(type: .mouseMoved, location: .zero, hostSeconds: 12)
        storage.setAnchor(hostSeconds: 10)
        storage.setAnchor(hostSeconds: 99)
        let keys = storage.keystrokes(through: 4)
        try check(keys.count == 2 && abs(keys[0].time - 0.3) < 1e-9 && keys[1].time == 1, "clock anchor, range filtering and keys independent of pointer location")
        try check(storage.events(through: 4) == [CursorEvent(time: 0, x: 0.5, y: 0.5, kind: .move),
                                                CursorEvent(time: 1.5, x: 0.5, y: 0.5, kind: .down)], "latest pre-epoch position and display filtering")
        try check(!storage.isTapDisabled, "healthy monitoring")
        storage.markTapDisabled()
        try check(storage.isTapDisabled, "interrupted monitoring diagnostics")
        storage.reset(bounds: bounds)
        try check(!storage.isTapDisabled && storage.keystrokes(through: 4).isEmpty && storage.events(through: 4).isEmpty, "reset clears opt-in, timestamps and diagnostics")
        var session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: 640, height: 360,
                                       duration: 4, events: [], droppedFrames: 0, eventCaptureAvailable: true)
        let legacy = try JSONEncoder().encode(session)
        let loaded = try JSONDecoder().decode(RecordingSession.self, from: legacy)
        try check(loaded.cursorEmbedded == nil && loaded.keystrokes == nil, "legacy sessions keep embedded cursor and absent key stream")
        session.cursorEmbedded = false
        session.keystrokes = keys
        session.keystrokeCaptureAvailable = true
        let encoded = try JSONEncoder().encode(session)
        let roundtrip = try JSONDecoder().decode(RecordingSession.self, from: encoded)
        try check(roundtrip.cursorEmbedded == false && roundtrip.keystrokes == keys && roundtrip.keystrokeCaptureAvailable == true, "new session roundtrip")
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let keyObjects = object["keystrokes"] as! [[String: Any]]
        try check(keyObjects.allSatisfy { Set($0.keys) == Set(["time", "kind"]) }, "key identity and typed text are never serialized")
        // Shortcut opt-in: independent of key timing, privacy-filtered, layout character only for shortcuts.
        storage.reset(bounds: bounds, initialLocation: point)
        storage.recordShortcut(keyCode: 8, modifiers: .command, hostSeconds: 10.5) { "c" }
        storage.setAnchor(hostSeconds: 10)
        try check(storage.shortcuts(through: 4).isEmpty, "shortcuts require their own opt-in")
        storage.reset(bounds: bounds, initialLocation: point, capturesShortcuts: true)
        var lookups = 0
        func press(_ code: Int, _ modifiers: ShortcutModifiers, _ time: Double, _ character: String = "x") {
            storage.recordShortcut(keyCode: code, modifiers: modifiers, hostSeconds: time) { lookups += 1; return character }
        }
        for (index, letter) in "hello world".enumerated() { press(index, [], 10.1 + Double(index) * 0.1, String(letter)) }
        press(0, .shift, 11.5, "A")
        press(49, [], 11.6)
        try check(lookups == 0, "typed text never reaches the character lookup")
        press(8, .command, 10.5, "c")
        press(53, [], 11, "\u{1b}")
        press(9, [.command, .shift], 12, "v")
        press(8, .command, 99, "c")
        storage.record(type: .keyDown, location: .zero, hostSeconds: 10.2)
        storage.setAnchor(hostSeconds: 10)
        let shortcuts = storage.shortcuts(through: 4)
        try check(shortcuts.map(\.key) == ["C", "escape", "V"] && shortcuts.map(\.modifiers) == [.command, [], [.command, .shift]],
                  "only shortcuts are stored, with modifiers and key identity")
        try check(abs(shortcuts[0].time - 0.5) < 1e-9 && abs(shortcuts[2].time - 2) < 1e-9, "shortcut times use the same clock anchor")
        try check(storage.keystrokes(through: 4).isEmpty, "shortcut capture does not enable key timing")
        storage.reset(bounds: bounds)
        try check(storage.shortcuts(through: 4).isEmpty, "reset clears shortcuts")
        session.shortcuts = shortcuts
        session.shortcutCaptureAvailable = true
        let shortcutRoundtrip = try JSONDecoder().decode(RecordingSession.self, from: JSONEncoder().encode(session))
        try check(shortcutRoundtrip.shortcuts == shortcuts && shortcutRoundtrip.shortcutCaptureAvailable == true && loaded.shortcuts == nil
                  && loaded.shortcutCaptureAvailable == nil, "shortcuts roundtrip; legacy sessions decode without them")
        let shortcutObjects = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any])["shortcuts"] as! [[String: Any]]
        try check(shortcutObjects.allSatisfy { Set($0.keys) == Set(["time", "keyCode", "key", "modifiers"]) }, "shortcut events serialize only time, key code, key and modifiers")
        print("Event capture verified: \(checks) checks")
    }
}
