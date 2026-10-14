import Carbon.HIToolbox
import CoreGraphics
import CoreMedia
import Foundation

/// Pointer capture with two independent keyboard opt-ins: key-down timing (no identity), and
/// shortcuts (modifier set + key identity, only for presses `ShortcutCapture` accepts). Typed text
/// is never stored by either.
@MainActor
final class CursorRecorder {
    private let storage = CursorEventStorage()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isAvailable = false
    private var tapWasAvailableAtStart = false
    private var capturesKeystrokes = false
    private var capturesShortcuts = false
    var keystrokesWereAvailableForSession: Bool { capturesKeystrokes && wasAvailableForSession }
    var shortcutsWereAvailableForSession: Bool { capturesShortcuts && wasAvailableForSession }
    var wasAvailableForSession: Bool {
        tapWasAvailableAtStart && !storage.isTapDisabled && !storage.didOverflow
    }

    func start(displayID: CGDirectDisplayID, capturesKeystrokes: Bool = false, capturesShortcuts: Bool = false) {
        stopTap()
        self.capturesKeystrokes = capturesKeystrokes
        self.capturesShortcuts = capturesShortcuts
        storage.reset(bounds: CGDisplayBounds(displayID), capturesKeystrokes: capturesKeystrokes,
                      initialLocation: CGEvent(source: nil)?.location, capturesShortcuts: capturesShortcuts)
        tapWasAvailableAtStart = false

        var eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp
        ]
        if capturesKeystrokes || capturesShortcuts { eventTypes.append(.keyDown) }
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(storage).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.handleEvent,
            userInfo: context
        ) else {
            isAvailable = false
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let source else {
            isAvailable = false
            return
        }
        tap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isAvailable = true
        tapWasAvailableAtStart = true
    }

    /// Anchors event times to the first accepted video frame.
    func anchor(presentationTime: CMTime) {
        // ScreenCaptureKit presentation timestamps use the host clock. Using the
        // PTS directly avoids adding sample callback delivery latency.
        storage.setAnchor(hostSeconds: presentationTime.seconds)
    }

    func stopCapture() {
        stopTap()
    }

    func events(through duration: Double) -> [CursorEvent] {
        storage.events(through: duration)
    }

    func keystrokes(through duration: Double) -> [KeystrokeEvent] { storage.keystrokes(through: duration) }

    func shortcuts(through duration: Double) -> [ShortcutEvent] { storage.shortcuts(through: duration) }

    private func stopTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
        isAvailable = false
    }

    private static let handleEvent: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let storage = Unmanaged<CursorEventStorage>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            storage.markTapDisabled()
            return Unmanaged.passUnretained(event)
        }
        let hostSeconds = Double(event.timestamp) / 1_000_000_000
        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let keyboardType = UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType))
            storage.recordShortcut(keyCode: keyCode, modifiers: ShortcutModifiers(event.flags), hostSeconds: hostSeconds) {
                ShortcutKeyTranslator.character(keyCode: keyCode, keyboardType: keyboardType)
            }
        }
        storage.record(type: type, location: event.location, hostSeconds: hostSeconds)
        return Unmanaged.passUnretained(event)
    }
}

/// Locked storage, internal so its clock and opt-in contract can be verified without a TCC prompt.
final class CursorEventStorage: @unchecked Sendable {
    private struct RawEvent {
        let hostSeconds: Double
        let x: Double
        let y: Double
        let kind: CursorEvent.Kind
    }

    private let lock = NSLock()
    private var bounds = CGRect.zero
    private var rawEvents: [RawEvent] = []
    private var rawKeys: [Double] = []
    private var rawShortcuts: [(hostSeconds: Double, event: ShortcutEvent)] = []
    private var capturesKeystrokes = false
    private var capturesShortcuts = false
    private var initialPosition: CGPoint?
    private var anchorHostSeconds: Double?
    private var tapWasDisabled = false
    private var eventsOverflowed = false
    private let maximumEvents = 250_000

    func reset(bounds: CGRect, capturesKeystrokes: Bool = false, initialLocation: CGPoint? = nil,
               capturesShortcuts: Bool = false) {
        lock.lock()
        self.bounds = bounds
        rawEvents.removeAll(keepingCapacity: true)
        rawKeys.removeAll(keepingCapacity: true)
        rawShortcuts.removeAll(keepingCapacity: true)
        self.capturesKeystrokes = capturesKeystrokes
        self.capturesShortcuts = capturesShortcuts
        initialPosition = initialLocation.flatMap { bounds.contains($0) ? $0 : nil }
        anchorHostSeconds = nil
        tapWasDisabled = false
        eventsOverflowed = false
        lock.unlock()
    }

    func setAnchor(hostSeconds: Double) {
        lock.lock()
        if anchorHostSeconds == nil {
            anchorHostSeconds = hostSeconds
        }
        lock.unlock()
    }

    func markTapDisabled() {
        lock.lock()
        tapWasDisabled = true
        lock.unlock()
    }

    var isTapDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tapWasDisabled
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventsOverflowed
    }

    /// Key-down hook for the shortcut opt-in. `ShortcutCapture.classify` decides what may be kept;
    /// the event's `time` field holds host seconds until `shortcuts(through:)` rebases it.
    func recordShortcut(keyCode: Int, modifiers: ShortcutModifiers, hostSeconds: Double, character: () -> String?) {
        lock.lock()
        defer { lock.unlock() }
        guard capturesShortcuts, hostSeconds.isFinite else { return }
        guard let event = ShortcutCapture.classify(keyCode: keyCode, modifiers: modifiers, time: hostSeconds,
                                                   character: character) else { return }
        guard rawShortcuts.count < maximumEvents else { eventsOverflowed = true; return }
        rawShortcuts.append((hostSeconds, event))
    }

    func record(type: CGEventType, location: CGPoint, hostSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard hostSeconds.isFinite else { return }
        if type == .keyDown {
            guard capturesKeystrokes else { return }
            guard rawKeys.count < maximumEvents else { eventsOverflowed = true; return }
            rawKeys.append(hostSeconds)
            return
        }
        guard bounds.width > 0, bounds.height > 0,
              bounds.contains(location) else { return }
        guard rawEvents.count < maximumEvents - 1 else {
            eventsOverflowed = true
            return
        }

        let kind: CursorEvent.Kind
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .up
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            kind = .move
        default:
            return
        }

        rawEvents.append(RawEvent(
            hostSeconds: hostSeconds,
            x: Double((location.x - bounds.minX) / bounds.width),
            y: Double((location.y - bounds.minY) / bounds.height),
            kind: kind
        ))
    }

    func events(through duration: Double) -> [CursorEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let anchorHostSeconds else { return [] }

        var result = rawEvents.compactMap { event -> CursorEvent? in
            let time = event.hostSeconds - anchorHostSeconds
            guard time >= 0, time <= duration else { return nil }
            return CursorEvent(time: time, x: event.x, y: event.y, kind: event.kind)
        }
        // A stationary cursor still needs a position at the first frame. Use the last
        // pre-epoch event, or the position sampled at tap installation.
        if let prior = rawEvents.last(where: { $0.hostSeconds <= anchorHostSeconds }) {
            if result.first?.time != 0 { result.insert(CursorEvent(time: 0, x: prior.x, y: prior.y, kind: .move), at: 0) }
        } else if let position = initialPosition, bounds.width > 0, bounds.height > 0, duration >= 0 {
            result.insert(CursorEvent(time: 0, x: (position.x - bounds.minX) / bounds.width,
                                      y: (position.y - bounds.minY) / bounds.height, kind: .move), at: 0)
        }
        return result
    }

    func keystrokes(through duration: Double) -> [KeystrokeEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard capturesKeystrokes, let anchorHostSeconds else { return [] }
        return rawKeys.compactMap { host in
            let time = host - anchorHostSeconds
            return time >= 0 && time <= duration ? KeystrokeEvent(time: time) : nil
        }
    }

    func shortcuts(through duration: Double) -> [ShortcutEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard capturesShortcuts, let anchorHostSeconds else { return [] }
        return rawShortcuts.compactMap { raw in
            var event = raw.event
            event.time = raw.hostSeconds - anchorHostSeconds
            return event.time >= 0 && event.time <= duration ? event : nil
        }
    }
}

extension ShortcutModifiers {
    init(_ flags: CGEventFlags) {
        var modifiers = ShortcutModifiers()
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        self = modifiers
    }
}

/// Layout-aware key identity: the character a key produces with no modifiers in the current
/// keyboard layout (UCKeyTranslate), so Cmd+Z on any layout is labelled with that layout's key.
enum ShortcutKeyTranslator {
    static func character(keyCode: Int, keyboardType: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, UInt16(truncatingIfNeeded: keyCode), UInt16(kUCKeyActionDisplay), 0, keyboardType,
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
