import Foundation

/// All event times are seconds from the first encoded video frame.
/// Coordinates use the captured display's top-left origin, normalized to 0...1.
struct CursorEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case move, down, up }
    var time: Double
    var x: Double
    var y: Double
    var kind: Kind
}

/// System cursor shapes Viddeo can draw. These are renderable session values; recording does not
/// currently capture other apps' cursor type because public AppKit cursor state is app-scoped.
enum CursorKind: String, Codable, Sendable, CaseIterable {
    case arrow, iBeam, iBeamVertical, pointingHand, openHand, closedHand
    case resizeHorizontal, resizeVertical, resizeDiagonalNWSE, resizeDiagonalNESW
    case crosshair, notAllowed, wait
}

/// A cursor shape change: `kind` is shown from `time` (seconds from the first video frame) until the next event.
struct CursorTypeEvent: Codable, Sendable, Equatable {
    var time: Double
    var kind: CursorKind
}

enum CursorTypeCapture {
    /// Change-only recording: a sample is kept when its kind differs from the previous kept one
    /// (the first sample always is). Non-finite times are skipped.
    static func changes(from samples: [(time: Double, kind: CursorKind)]) -> [CursorTypeEvent] {
        var result: [CursorTypeEvent] = []
        for sample in samples where sample.time.isFinite && sample.kind != result.last?.kind {
            result.append(CursorTypeEvent(time: sample.time, kind: sample.kind))
        }
        return result
    }
}

/// Only timing is retained, never key codes or text. Capture is opt-in.
struct KeystrokeEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case keyDown }
    var time: Double
    var kind: Kind = .keyDown
}

/// Modifier keys held while a shortcut was pressed. Caps lock is never captured (it is a state,
/// not part of a press); fn is kept only for keys where it is not set by the hardware itself.
struct ShortcutModifiers: OptionSet, Codable, Sendable, Hashable {
    let rawValue: UInt8
    static let command = ShortcutModifiers(rawValue: 1)
    static let option = ShortcutModifiers(rawValue: 2)
    static let control = ShortcutModifiers(rawValue: 4)
    static let shift = ShortcutModifiers(rawValue: 8)
    static let capsLock = ShortcutModifiers(rawValue: 16)
    static let function = ShortcutModifiers(rawValue: 32)
    /// A press with none of these (and no special key) is ordinary typing.
    static let primary: ShortcutModifiers = [.command, .option, .control]
}

/// One opt-in captured shortcut press: the modifier set and the key identity, never typed text.
/// `key` is a lowercase key name for non-text keys ("escape", "return", "left", "f5", "space", ...)
/// and the layout's unmodified character, uppercased, for everything else.
struct ShortcutEvent: Codable, Sendable, Equatable {
    var time: Double
    var keyCode: Int
    var key: String
    var modifiers: ShortcutModifiers
}

/// The privacy boundary of shortcut capture, kept pure so it can be verified without a TCC prompt.
/// Only presses with at least one of command/option/control, or a special non-text key, are ever
/// turned into an event; plain and shift-only characters (and plain Space) never are, and the
/// character lookup is not even performed for them.
enum ShortcutCapture {
    /// Virtual key codes of keys that are not text: name by key code.
    static let specialKeyNames: [Int: String] = [
        36: "return", 76: "enter", 48: "tab", 51: "delete", 117: "forwardDelete", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageUp", 121: "pageDown", 114: "help",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20"
    ]
    static let spaceKeyCode = 49
    /// The hardware sets the fn flag on these keys; it is not a user-held modifier there.
    private static let functionFlaggedKeys: Set<Int> = [
        123, 124, 125, 126, 115, 119, 116, 121, 117, 114,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    /// Cheap pre-check used before any character lookup.
    static func isCapturable(keyCode: Int, modifiers: ShortcutModifiers) -> Bool {
        if !modifiers.isDisjoint(with: .primary) { return true }
        return specialKeyNames[keyCode] != nil
    }

    /// Nil for anything that is not a shortcut. `character` (the key's unmodified character in the
    /// current layout) is only evaluated for capturable presses.
    static func classify(keyCode: Int, modifiers rawModifiers: ShortcutModifiers, time: Double,
                         character: () -> String?) -> ShortcutEvent? {
        var modifiers = rawModifiers.subtracting(.capsLock)
        if functionFlaggedKeys.contains(keyCode) { modifiers.remove(.function) }
        guard isCapturable(keyCode: keyCode, modifiers: modifiers) else { return nil }
        let key: String
        if keyCode == spaceKeyCode {
            key = "space"
        } else if let name = specialKeyNames[keyCode] {
            key = name
        } else if let first = character()?.first(where: { !$0.isWhitespace && !$0.isNewline }) {
            key = String(first).uppercased()
        } else {
            key = "key\(keyCode)"
        }
        return ShortcutEvent(time: time, keyCode: keyCode, key: key, modifiers: modifiers)
    }
}

struct RecordingSession: Codable, Sendable {
    var version = 1
    var id: UUID
    var createdAt: Date
    var displayID: UInt32
    var width: Int
    var height: Int
    var duration: Double
    var videoFilename = "raw.mp4"
    var events: [CursorEvent]
    var droppedFrames: Int
    var eventCaptureAvailable: Bool
    var audio: AudioCaptureMetadata? = nil
    /// Missing on legacy sessions means the system cursor is embedded in raw video.
    var cursorEmbedded: Bool? = nil
    var keystrokes: [KeystrokeEvent]? = nil
    var keystrokeCaptureAvailable: Bool? = nil
    /// Opt-in shortcut presses (modifier set + key identity, never plain text); absent on older sessions
    /// and when "Record keyboard shortcuts" was off.
    var shortcuts: [ShortcutEvent]? = nil
    var shortcutCaptureAvailable: Bool? = nil
    /// Cursor shape changes (see `CursorTypeCapture`); absent on older sessions, which draw the arrow throughout.
    var cursorTypes: [CursorTypeEvent]? = nil
    /// False when the system cursor image could not be read (best effort: arrow only).
    var cursorTypeCaptureAvailable: Bool? = nil
    /// Present when a camera was recorded next to the screen (`camera.mov`); absent on older sessions.
    var webcam: WebcamCaptureMetadata? = nil

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    static func load(from directory: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }
}

/// Capture diagnostics for the optional, independently encoded AAC tracks in raw.mp4.
struct AudioCaptureMetadata: Codable, Sendable, Equatable {
    var systemAudioRequested: Bool
    var microphoneRequested: Bool
    var systemAudioSamples: Int
    var microphoneSamples: Int
    var systemAudioDroppedSamples: Int
    var microphoneDroppedSamples: Int
    var systemAudioTrackName = "System Audio"
    var microphoneTrackName = "Microphone"
}

/// Sidecar description of `camera.mov`. `firstPTS` is seconds from the screen recording's
/// first-frame epoch (host clock) to the first camera frame; it is never below
/// `-WebcamRecorder.epochTolerance`. Without an epoch it is 0 and `firstHostTime` alone
/// anchors the file.
struct WebcamCaptureMetadata: Codable, Sendable, Equatable {
    var filename: String
    var firstPTS: Double
    var duration: Double
    var width: Int
    var height: Int
    var droppedFrames: Int
    var deviceName: String
    /// Host-clock seconds of the first written frame, for alignment done after recording.
    var firstHostTime: Double
}
