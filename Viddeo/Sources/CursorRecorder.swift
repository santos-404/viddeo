import CoreGraphics
import CoreMedia
import Foundation

/// Records pointer-only events for one display. It never installs a key event tap.
@MainActor
final class CursorRecorder {
    private let storage = CursorEventStorage()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isAvailable = false
    private var tapWasAvailableAtStart = false
    var wasAvailableForSession: Bool {
        tapWasAvailableAtStart && !storage.isTapDisabled && !storage.didOverflow
    }

    func start(displayID: CGDirectDisplayID) {
        stopTap()
        storage.reset(bounds: CGDisplayBounds(displayID))
        tapWasAvailableAtStart = false

        let eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp
        ]
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
        storage.record(type: type, location: event.location, hostSeconds: Double(event.timestamp) / 1_000_000_000)
        return Unmanaged.passUnretained(event)
    }
}

private final class CursorEventStorage: @unchecked Sendable {
    private struct RawEvent {
        let hostSeconds: Double
        let x: Double
        let y: Double
        let kind: CursorEvent.Kind
    }

    private let lock = NSLock()
    private var bounds = CGRect.zero
    private var rawEvents: [RawEvent] = []
    private var anchorHostSeconds: Double?
    private var tapWasDisabled = false
    private var eventsOverflowed = false
    private let maximumEvents = 250_000

    func reset(bounds: CGRect) {
        lock.lock()
        self.bounds = bounds
        rawEvents.removeAll(keepingCapacity: true)
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

    func record(type: CGEventType, location: CGPoint, hostSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard bounds.width > 0, bounds.height > 0,
              bounds.contains(location) else { return }
        guard rawEvents.count < maximumEvents else {
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

        return rawEvents.compactMap { event in
            let time = event.hostSeconds - anchorHostSeconds
            guard time >= 0, time <= duration else { return nil }
            return CursorEvent(time: time, x: event.x, y: event.y, kind: event.kind)
        }
    }
}
