import Foundation

enum CursorRotationMode: String, Codable, Sendable {
    case velocity, directional
}

/// Rendered-cursor settings. Defaults are the observed reference values unless noted.
/// Distances in px are source pixels; `size` and blur radii are points on a 1080-high canvas.
struct CursorConfiguration: Codable, Sendable, Equatable {
    var hide = false
    var size = 48.0
    var smoothing = true
    var stiffness = 125.0
    var damping = 12.0
    var mass = 1.5
    var pressedScale = 0.9
    var rotationMode = CursorRotationMode.velocity
    /// Declared only: the observed field's semantics are unknown.
    var rotateOnXMovementRatio = 0.5
    var velocitySmoothingMs = 120.0
    var tiltDegPerVelocity = 12.0
    var maxTiltDeg = 20.0
    var startupCalmMs = 500.0
    var entryTeleportSpeedPxPerMs = 15.0
    var tiltStiffness = 120.0
    var tiltDamping = 8.0
    var tiltMass = 1.0
    var alignRatePerPx = 0.00005
    var speedSaturationPxPerMs = 3.0
    var angularDampingMs = 100.0
    var maxTurnRateDegPerMs = 0.4
    var maxFromNeutralDeg = 135.0
    var minTravelPx = 4.0
    var neutralPullHeadingDeg = -112.5
    var directionalStiffness = 320.0
    var directionalDamping = 28.0
    var directionalMass = 1.0
    var hideWhileTypingKeyCount = 3
    var typingWindowMs = 1800.0
    /// Fade durations are a viddeo design choice; the reference springs opacity.
    var fadeOutMs = 150.0
    var fadeInMs = 150.0
    var hideNotMovingAfterMs: Double? = nil
    var hideBlurRadius = 10.0
    /// Shake removal: Manhattan distance |dx|+|dy| in recording pixels; an event farther than this
    /// from both of the next two events is dropped. 0 disables. (Older files call this
    /// `removeShakeThresholdMs`; it was never milliseconds and the old key is still decoded.)
    var removeShakeThresholdPx = 500.0
    /// Loop window: events in the last N ms are ignored and the cursor glides back to its first
    /// position (a copy of the first event is appended 1 ms after the last). nil = off in viddeo
    /// (the reference always appends the return event; see docs/research/cursor-motion.md).
    var loopPositionBeforeEndMs: Double? = nil
    /// Movement spring choice after `duration - N` ms (see `CursorTimeline`). 0 = off.
    var stopMovementInLastPartMs = 0.0
    /// Motion blur 0...1: strength = amount x fps/60, so the shutter is amount/60 s at any fps.
    var motionBlurAmount = 1.0

    /// Values of 12 or less are icon multipliers in the reference format (×16).
    var effectiveSize: Double { size <= 12 ? size * 16 : size }

    func validate() throws {
        let values = [size, stiffness, damping, mass, pressedScale, rotateOnXMovementRatio,
                      velocitySmoothingMs, tiltDegPerVelocity, maxTiltDeg, startupCalmMs,
                      entryTeleportSpeedPxPerMs, tiltStiffness, tiltDamping, tiltMass,
                      alignRatePerPx, speedSaturationPxPerMs, angularDampingMs, maxTurnRateDegPerMs,
                      maxFromNeutralDeg, minTravelPx, neutralPullHeadingDeg, directionalStiffness,
                      directionalDamping, directionalMass, typingWindowMs, fadeOutMs, fadeInMs,
                      hideBlurRadius, removeShakeThresholdPx, stopMovementInLastPartMs, motionBlurAmount,
                      hideNotMovingAfterMs ?? 1, loopPositionBeforeEndMs ?? 1]
        let springs = [(stiffness, damping, mass), (tiltStiffness, tiltDamping, tiltMass),
                       (directionalStiffness, directionalDamping, directionalMass)]
        guard values.allSatisfy(\.isFinite), size > 0, effectiveSize <= 512,
              springs.allSatisfy({ $0.0 > 0 && $0.0 <= 1000 && $0.1 > 0 && $0.1 <= 200 &&
                                   $0.2 >= 0.1 && $0.2 <= 100 }),
              pressedScale > 0, pressedScale <= 2, (0...10).contains(rotateOnXMovementRatio),
              velocitySmoothingMs > 0, velocitySmoothingMs <= 10_000,
              (0...360).contains(tiltDegPerVelocity), (0...90).contains(maxTiltDeg),
              (0...60_000).contains(startupCalmMs), entryTeleportSpeedPxPerMs > 0,
              (0...1).contains(alignRatePerPx), speedSaturationPxPerMs > 0,
              angularDampingMs > 0, angularDampingMs <= 10_000,
              maxTurnRateDegPerMs > 0, maxTurnRateDegPerMs <= 10,
              (0...180).contains(maxFromNeutralDeg), (0...1000).contains(minTravelPx),
              (-360...360).contains(neutralPullHeadingDeg),
              (1...100).contains(hideWhileTypingKeyCount),
              typingWindowMs > 0, typingWindowMs <= 60_000,
              (0...10_000).contains(fadeOutMs), (0...10_000).contains(fadeInMs),
              hideNotMovingAfterMs.map({ $0 > 0 && $0 <= 3_600_000 }) ?? true,
              (0...100).contains(hideBlurRadius), (0...100_000).contains(removeShakeThresholdPx),
              loopPositionBeforeEndMs.map({ $0 > 0 && $0 <= 3_600_000 }) ?? true,
              (0...60_000).contains(stopMovementInLastPartMs), (0...1).contains(motionBlurAmount)
        else { throw CursorError.invalidConfiguration }
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("cursor-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("cursor-config.json"), options: .atomic)
    }
}

extension CursorConfiguration {
    private enum LegacyKeys: String, CodingKey {
        case removeShakeThresholdMs
    }

    /// Tolerant decoding: missing keys keep their defaults, and the pre-rename shake key is read.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ path: WritableKeyPath<Self, T>) throws {
            if let value = try c.decodeIfPresent(T.self, forKey: key) { self[keyPath: path] = value }
        }
        try read(.hide, \.hide)
        try read(.size, \.size)
        try read(.smoothing, \.smoothing)
        try read(.stiffness, \.stiffness)
        try read(.damping, \.damping)
        try read(.mass, \.mass)
        try read(.pressedScale, \.pressedScale)
        try read(.rotationMode, \.rotationMode)
        try read(.rotateOnXMovementRatio, \.rotateOnXMovementRatio)
        try read(.velocitySmoothingMs, \.velocitySmoothingMs)
        try read(.tiltDegPerVelocity, \.tiltDegPerVelocity)
        try read(.maxTiltDeg, \.maxTiltDeg)
        try read(.startupCalmMs, \.startupCalmMs)
        try read(.entryTeleportSpeedPxPerMs, \.entryTeleportSpeedPxPerMs)
        try read(.tiltStiffness, \.tiltStiffness)
        try read(.tiltDamping, \.tiltDamping)
        try read(.tiltMass, \.tiltMass)
        try read(.alignRatePerPx, \.alignRatePerPx)
        try read(.speedSaturationPxPerMs, \.speedSaturationPxPerMs)
        try read(.angularDampingMs, \.angularDampingMs)
        try read(.maxTurnRateDegPerMs, \.maxTurnRateDegPerMs)
        try read(.maxFromNeutralDeg, \.maxFromNeutralDeg)
        try read(.minTravelPx, \.minTravelPx)
        try read(.neutralPullHeadingDeg, \.neutralPullHeadingDeg)
        try read(.directionalStiffness, \.directionalStiffness)
        try read(.directionalDamping, \.directionalDamping)
        try read(.directionalMass, \.directionalMass)
        try read(.hideWhileTypingKeyCount, \.hideWhileTypingKeyCount)
        try read(.typingWindowMs, \.typingWindowMs)
        try read(.fadeOutMs, \.fadeOutMs)
        try read(.fadeInMs, \.fadeInMs)
        try read(.hideNotMovingAfterMs, \.hideNotMovingAfterMs)
        try read(.hideBlurRadius, \.hideBlurRadius)
        try read(.loopPositionBeforeEndMs, \.loopPositionBeforeEndMs)
        try read(.stopMovementInLastPartMs, \.stopMovementInLastPartMs)
        try read(.motionBlurAmount, \.motionBlurAmount)
        if let value = try c.decodeIfPresent(Double.self, forKey: .removeShakeThresholdPx) {
            removeShakeThresholdPx = value
        } else if let value = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Double.self, forKey: .removeShakeThresholdMs) {
            removeShakeThresholdPx = value
        }
    }
}

enum CursorError: LocalizedError {
    case invalidConfiguration
    var errorDescription: String? { "Cursor settings contain invalid size, spring or timing values." }
}

/// Position is normalized from the top-left. Positive rotation turns clockwise on screen
/// about the hotspot; `blurRadius` is in points on a 1080-high canvas.
struct CursorState: Sendable, Equatable {
    var x: Double
    var y: Double
    var scale: Double
    var rotationRadians: Double
    var opacity: Double
    var blurRadius: Double
}

/// Cursor state now and one frame earlier, blended by the blur strength: the trail runs from
/// `start` to `now` (it only looks backwards in time). `start == now` when strength is 0.
struct CursorTrail: Sendable, Equatable {
    var now: CursorState
    var start: CursorState
    var strength: Double
}

/// Input transforms applied before the cursor is animated. Pure and deterministic.
enum CursorEventFilter {
    /// Shake removal, as in the reference: one pass; an event is dropped when both of the next two
    /// events are farther than `thresholdPx` (Manhattan, recording pixels). A dropped `.down` also
    /// drops the next `.up`. Threshold 0 (or less) returns the input.
    static func removingShake(_ events: [CursorEvent], thresholdPx: Double,
                              sourceWidth: Double, sourceHeight: Double) -> [CursorEvent] {
        guard thresholdPx > 0, events.count > 1 else { return events }
        func far(_ a: CursorEvent, _ b: CursorEvent) -> Bool {
            abs(a.x - b.x) * sourceWidth + abs(a.y - b.y) * sourceHeight > thresholdPx
        }
        var result: [CursorEvent] = []
        var dropNextUp = false
        for index in events.indices {
            let event = events[index]
            if dropNextUp && event.kind == .up {
                dropNextUp = false
                continue
            }
            if index + 2 < events.count, far(event, events[index + 1]), far(event, events[index + 2]) {
                if event.kind == .down { dropNextUp = true }
                continue
            }
            result.append(event)
        }
        return result
    }

    /// Loop window: ignores events after `duration - loopMs`, re-times the first event to 0 and
    /// appends a `.move` copy of its position 1 ms after the last kept event, so the position
    /// spring glides back to the start. Without events in the window the first event is used.
    /// (The copy is a move, not the first event's kind, so a first `.down` is not pressed twice.)
    static func loopWindow(_ events: [CursorEvent], duration: Double, loopMs: Double?) -> [CursorEvent] {
        guard let loopMs, let firstEvent = events.first else { return events }
        let end = max(0, duration - loopMs / 1000)
        var window = events.filter { $0.time <= end }
        if window.isEmpty { window = [firstEvent] }
        window[0].time = 0
        let last = window[window.count - 1].time
        window.append(CursorEvent(time: last + 0.001, x: window[0].x, y: window[0].y, kind: .move))
        return window
    }
}

/// Pure offline cursor animation. Samples are precomputed with fixed substeps, so seeks in
/// any order return identical states.
struct CursorTimeline: Sendable {
    static let framesPerSecond = 60.0
    // Press easing is a viddeo design choice: a critically damped, ~0.2 s spring.
    private static let pressStiffness = 900.0
    private static let pressDamping = 60.0
    private static let pressMass = 1.0
    // The reference's click/drag springs are unknown (their constants live in an unextracted
    // module). After `stopMovementInLastPartMs` viddeo uses the press spring for both.
    private static let snapWindow = 0.175

    private let motionBlurAmount: Double

    private let samples: [CursorState]
    private let firstEventTime: Double?
    private let hiddenBlurRadius: Double

    init(events: [CursorEvent], keystrokes: [KeystrokeEvent], duration: Double,
         configuration: CursorConfiguration = .init(),
         sourceWidth: Double = 1920, sourceHeight: Double = 1080) {
        // Export validates user configuration; pure callers get safe defaults.
        let config = (try? configuration.validate()) == nil ? CursorConfiguration() : configuration
        let fps = Self.framesPerSecond
        let duration = duration.isFinite ? min(12 * 60 * 60, max(0, duration)) : 0
        let width = sourceWidth.isFinite && sourceWidth > 0 ? sourceWidth : 1920
        let height = sourceHeight.isFinite && sourceHeight > 0 ? sourceHeight : 1080
        // Stable order keeps same-time down/up pairs in recorded order.
        var events = events.enumerated().filter { _, event in
            event.time.isFinite && event.x.isFinite && event.y.isFinite &&
            event.time >= 0 && event.time <= duration &&
            (0...1).contains(event.x) && (0...1).contains(event.y)
        }.sorted { $0.element.time < $1.element.time || ($0.element.time == $1.element.time && $0.offset < $1.offset) }
            .map(\.element)
        events = CursorEventFilter.removingShake(events, thresholdPx: config.removeShakeThresholdPx,
                                                 sourceWidth: width, sourceHeight: height)
        events = CursorEventFilter.loopWindow(events, duration: duration, loopMs: config.loopPositionBeforeEndMs)
        let eventTimes = events.map(\.time)
        let keyTimes = keystrokes.map(\.time)
            .filter { $0.isFinite && $0 >= 0 && $0 <= duration }.sorted()
        let first = events.first
        firstEventTime = first?.time
        hiddenBlurRadius = config.hideBlurRadius
        motionBlurAmount = config.motionBlurAmount

        let directional = config.rotationMode == .directional
        let rotationSpring = directional
            ? (config.directionalStiffness, config.directionalDamping, config.directionalMass)
            : (config.tiltStiffness, config.tiltDamping, config.tiltMass)
        let rotationLimit = directional ? config.maxFromNeutralDeg : config.maxTiltDeg
        let springs = [(config.stiffness, config.damping, config.mass), rotationSpring,
                       (Self.pressStiffness, Self.pressDamping, Self.pressMass)]
        let maxStep = springs.reduce(0.001) { min($0, 0.5 * $1.2 / $1.1, 0.2 * sqrt($1.2 / $1.0)) }
        let substeps = Int(ceil(1 / fps / maxStep))
        let dt = 1 / fps / Double(substeps)
        let frameMs = 1000 / fps
        let movementSpring = (config.stiffness, config.damping, config.mass)
        let snapSpring = (Self.pressStiffness, Self.pressDamping, Self.pressMass)
        // Reference: after stopTime the spring is chosen from the conditions at stopTime (a click
        // within 175 ms after it, or a drag in progress), not from the current time.
        let stopTime = duration - config.stopMovementInLastPartMs / 1000
        let stopSpring: (Double, Double, Double) = {
            guard config.stopMovementInLastPartMs > 0, config.smoothing else { return movementSpring }
            let clickSoon = events.contains { $0.kind != .move && $0.time >= stopTime && $0.time <= stopTime + Self.snapWindow }
            let dragging = events.last { $0.time <= stopTime && $0.kind != .move }?.kind == .down
            return clickSoon || dragging ? snapSpring : movementSpring
        }()

        var stepCursor = EventCursor(start: first)
        var frameCursor = EventCursor(start: first)
        var x = CursorSpring(value: first?.x ?? 0.5)
        var y = CursorSpring(value: first?.y ?? 0.5)
        var press = CursorSpring(value: 1)
        var rotation = CursorSpring(value: 0)
        var rotationTarget = 0.0
        var smoothedVelocityX = 0.0
        var angularVelocity = 0.0
        var travelX = 0.0, travelY = 0.0
        var visibility = 0.0
        var previousX = first?.x ?? 0.5, previousY = first?.y ?? 0.5
        var states: [CursorState] = []
        let count = Int(ceil(duration * fps)) + 1
        states.reserveCapacity(count)

        for index in 0..<count {
            let time = Double(index) / fps
            frameCursor.advance(to: time, in: events)
            let calm = first.map { time < $0.time + config.startupCalmMs / 1000 } ?? true
            let dxPx = (frameCursor.x - previousX) * width
            let dyPx = (frameCursor.y - previousY) * height
            previousX = frameCursor.x
            previousY = frameCursor.y
            let speed = hypot(dxPx, dyPx) / frameMs

            if directional {
                if dxPx == 0 && dyPx == 0 { travelX = 0; travelY = 0 } else { travelX += dxPx; travelY += dyPx }
                let travel = hypot(travelX, travelY)
                if calm {
                    rotationTarget = 0
                    angularVelocity = 0
                } else {
                    var error: Double
                    var gain: Double
                    if travel >= config.minTravelPx && travel > 0 {
                        // Steer toward the motion heading; idle frames pull back to neutral.
                        let heading = atan2(travelY, travelX) * 180 / .pi
                        let desired = Self.wrap(heading - config.neutralPullHeadingDeg)
                        error = Self.wrap(desired - rotationTarget)
                        gain = config.alignRatePerPx * travel * min(1, speed / config.speedSaturationPxPerMs)
                        travelX = 0
                        travelY = 0
                    } else {
                        error = -rotationTarget
                        gain = config.alignRatePerPx * max(1, config.minTravelPx)
                    }
                    angularVelocity += error * gain
                    angularVelocity *= exp(-frameMs / config.angularDampingMs)
                    angularVelocity = min(config.maxTurnRateDegPerMs,
                                          max(-config.maxTurnRateDegPerMs, angularVelocity))
                    rotationTarget += angularVelocity * frameMs
                    if abs(rotationTarget) > config.maxFromNeutralDeg {
                        rotationTarget = min(config.maxFromNeutralDeg, max(-config.maxFromNeutralDeg, rotationTarget))
                        angularVelocity = 0
                    }
                }
            } else {
                // Teleports (entry jumps) do not feed the tilt velocity.
                let rawVelocityX = speed > config.entryTeleportSpeedPxPerMs ? 0 : dxPx / frameMs
                smoothedVelocityX += (rawVelocityX - smoothedVelocityX) *
                    (1 - exp(-frameMs / config.velocitySmoothingMs))
                if calm { smoothedVelocityX = 0 }
                rotationTarget = min(config.maxTiltDeg, max(-config.maxTiltDeg,
                                                             smoothedVelocityX * config.tiltDegPerVelocity))
            }

            if index > 0 {
                let start = Double(index - 1) / fps
                // Small fixed substeps keep the springs stable and follow step-held input exactly.
                for step in 0..<substeps {
                    stepCursor.advance(to: start + Double(step) * dt, in: events)
                    if config.smoothing {
                        let spring = start + Double(step) * dt >= stopTime ? stopSpring : movementSpring
                        x.advance(to: stepCursor.x, dt: dt, spring: spring)
                        y.advance(to: stepCursor.y, dt: dt, spring: spring)
                    }
                    press.advance(to: stepCursor.pressed ? config.pressedScale : 1, dt: dt,
                                  spring: (Self.pressStiffness, Self.pressDamping, Self.pressMass))
                    rotation.advance(to: rotationTarget, dt: dt, spring: rotationSpring)
                }
            }
            stepCursor.advance(to: time, in: events)
            if !config.smoothing {
                x.value = stepCursor.x
                y.value = stepCursor.y
            }

            var visible = !config.hide && first.map { time >= $0.time } == true
            if visible && Self.isTyping(at: time, keys: keyTimes, events: eventTimes, configuration: config) {
                visible = false
            }
            if visible, let idle = config.hideNotMovingAfterMs {
                // Reference: only events at or before `time` keep the cursor visible.
                let last = Self.upperBound(eventTimes, time)
                visible = last > 0 && time - eventTimes[last - 1] <= idle / 1000
            }
            let fade = visible ? config.fadeInMs : config.fadeOutMs
            let change = fade > 0 ? frameMs / fade : 1
            visibility = visible ? min(1, visibility + change) : max(0, visibility - change)
            let opacity = visibility * visibility * (3 - 2 * visibility)

            states.append(CursorState(x: min(1, max(0, x.value)), y: min(1, max(0, y.value)),
                                      scale: press.value,
                                      rotationRadians: min(rotationLimit, max(-rotationLimit, rotation.value)) * .pi / 180,
                                      opacity: opacity, blurRadius: config.hideBlurRadius * (1 - opacity)))
        }
        samples = states
    }

    func state(at time: Double) -> CursorState {
        guard time.isFinite else { return samples[0] }
        let fps = Self.framesPerSecond
        let position = min(Double(samples.count - 1), max(0, time * fps))
        let lower = Int(position)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = position - Double(lower)
        let a = samples[lower], b = samples[upper]
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        var state = CursorState(x: mix(a.x, b.x), y: mix(a.y, b.y), scale: mix(a.scale, b.scale),
                                rotationRadians: mix(a.rotationRadians, b.rotationRadians),
                                opacity: mix(a.opacity, b.opacity), blurRadius: mix(a.blurRadius, b.blurRadius))
        if firstEventTime.map({ time < $0 }) ?? true {
            state.opacity = 0
            state.blurRadius = hiddenBlurRadius
        }
        return state
    }

    /// Shutter trail at `time`: `before` is the state one frame earlier and the trail starts at
    /// `lerp(now, before, strength)`. Strength is 0 while the cursor is hidden or `strength` is 0.
    func trail(at time: Double, frameDuration: Double, strength: Double) -> CursorTrail {
        let now = state(at: time)
        guard strength.isFinite, strength > 0, frameDuration.isFinite, frameDuration > 0,
              now.opacity > 0.001 else { return CursorTrail(now: now, start: now, strength: 0) }
        let before = state(at: max(0, time - frameDuration))
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * strength }
        var start = now
        start.x = mix(now.x, before.x)
        start.y = mix(now.y, before.y)
        start.scale = mix(now.scale, before.scale)
        start.rotationRadians = mix(now.rotationRadians, before.rotationRadians)
        return CursorTrail(now: now, start: start, strength: strength)
    }

    /// `strength = motionBlurAmount x fps / 60`, so `strength / fps = amount / 60` s at any fps.
    func trail(at time: Double, fps: Double) -> CursorTrail {
        guard fps.isFinite, fps > 0 else { return trail(at: time, frameDuration: 0, strength: 0) }
        return trail(at: time, frameDuration: 1 / fps, strength: motionBlurAmount * fps / 60)
    }

    /// Reference rule: enough key presses inside the window and no pointer event after the last key.
    private static func isTyping(at time: Double, keys: [Double], events: [Double],
                                 configuration: CursorConfiguration) -> Bool {
        let upper = upperBound(keys, time)
        let lower = upperBound(keys, time - configuration.typingWindowMs / 1000)
        guard upper - lower >= configuration.hideWhileTypingKeyCount else { return false }
        let lastKey = keys[upper - 1]
        let lastEvent = upperBound(events, time)
        return lastEvent == 0 || events[lastEvent - 1] < lastKey
    }

    private static func wrap(_ degrees: Double) -> Double {
        var value = fmod(degrees + 180, 360)
        if value < 0 { value += 360 }
        return value - 180
    }

    private static func upperBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Monotone reader of step-held pointer input.
private struct EventCursor {
    var next = 0
    var x: Double
    var y: Double
    var pressed = false

    init(start: CursorEvent?) {
        x = start?.x ?? 0.5
        y = start?.y ?? 0.5
    }

    mutating func advance(to time: Double, in events: [CursorEvent]) {
        while next < events.count && events[next].time <= time {
            let event = events[next]
            x = event.x
            y = event.y
            if event.kind == .down { pressed = true } else if event.kind == .up { pressed = false }
            next += 1
        }
    }
}

private struct CursorSpring {
    var value: Double
    var velocity = 0.0

    mutating func advance(to target: Double, dt: Double,
                          spring: (stiffness: Double, damping: Double, mass: Double)) {
        let acceleration = (spring.stiffness * (target - value) - spring.damping * velocity) / spring.mass
        velocity += acceleration * dt
        value += velocity * dt
        if abs(target - value) < 0.00001 && abs(velocity) < 0.00001 {
            value = target
            velocity = 0
        }
    }
}
