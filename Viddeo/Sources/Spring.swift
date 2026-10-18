import Foundation

/// Independent scalar spring model. Times are milliseconds; velocity is value units per second.
/// See docs/research/auto-zoom.md for the decoded behavioral evidence and its limitations.
struct SpringConfiguration: Sendable, Hashable {
    var stiffness = 125.0
    var damping = 12.0
    var mass = 1.5
    var clamp = true
    var precision = 0.002

    static let screen = Self()
    // The preset names identify the decoded exports, without guessing their intended UI roles.
    static let presetDe = Self(stiffness: 170, damping: 50, mass: 3)
    static let presetFe = Self(stiffness: 470, damping: 70, mass: 3)
    static let presetQ = Self(stiffness: 530, damping: 40, mass: 1)
    static let presetPe = Self(stiffness: 340, damping: 60, mass: 3)
    static let presetMe = Self(stiffness: 1000, damping: 40, mass: 1)
    static let instant = Self(stiffness: 1, damping: 1, mass: 0)
    static let presetHe = Self(stiffness: 600, damping: 50, mass: 1)

    static let frameMilliseconds = 1000.0 / 60

    fileprivate var isValid: Bool {
        [stiffness, damping, mass, precision].allSatisfy(\.isFinite)
            && stiffness > 0 && damping >= 0 && mass >= 0 && precision > 0
    }

    /// The reference's estimate deliberately uses a different timestep from live integration.
    /// It simulates 0 -> 1000 with initial velocity 1e-6, and does not apply adaptive damping.
    var settleTimeMilliseconds: Double {
        precondition(isValid)
        if mass == 0 { return 0 }
        return SpringSettleCache.shared.value(for: self) {
            let frame = Self.frameMilliseconds
            let step = frame / 1000 * max(sqrt(stiffness / mass), damping / mass) <= 0.5 ? frame : 1
            let tolerance = Spring.restTolerance(from: 0, to: 1000, precision: precision)
            var position = 0.0, velocity = 0.000_001, elapsed = 0.0
            while position != 1000 && velocity != 0 {
                velocity += (stiffness * (1000 - position) - damping * velocity) / mass * (step / 1000)
                position += velocity * (step / 1000)
                if abs(velocity) < tolerance && abs(1000 - position) < tolerance {
                    position = 1000
                    velocity = 0
                }
                if position.isNaN || velocity.isNaN { break }
                elapsed += step
                if elapsed > 20_000 { break }
            }
            return elapsed
        }
    }

    /// Shortens a configuration only when its estimated settling exceeds the requested duration.
    func fitted(toDurationMilliseconds duration: Double) -> Self {
        precondition(duration.isFinite && duration >= 0)
        let settle = settleTimeMilliseconds
        guard settle > duration else { return self }
        guard duration > 2 * Self.frameMilliseconds else { return .instant }
        let speed = settle / duration
        var result = self
        result.stiffness *= speed * speed
        result.damping *= speed
        return result
    }
}

/// A value type so precomputation and copies never share motion state. Retargeting preserves velocity.
struct Spring: Sendable {
    private(set) var value: Double
    private(set) var velocity = 0.0
    private(set) var target: Double
    private(set) var configuration: SpringConfiguration
    private(set) var tolerance = 1.0
    private(set) var timeMilliseconds = 0.0

    init(value: Double, configuration: SpringConfiguration = .screen) {
        precondition(value.isFinite && configuration.isValid)
        self.value = value
        target = value
        self.configuration = configuration
    }

    var isAtRest: Bool { value == target && velocity == 0 }

    static func restTolerance(from value: Double, to target: Double, precision: Double) -> Double {
        value == target ? 1 : max(1, abs(target - value)) * precision
    }

    mutating func setTarget(_ target: Double) {
        precondition(target.isFinite)
        guard target != self.target else { return }
        tolerance = Self.restTolerance(from: value, to: target, precision: configuration.precision)
        self.target = target
    }

    /// Updating a config leaves motion and the current target's tolerance intact.
    mutating func updateConfiguration(_ configuration: SpringConfiguration) {
        precondition(configuration.isValid)
        self.configuration = configuration
    }

    mutating func snapToTarget() {
        value = target
        velocity = 0
    }

    mutating func advance(milliseconds: Double) {
        precondition(milliseconds.isFinite && milliseconds >= 0)
        guard milliseconds > 0 else { return }
        timeMilliseconds += milliseconds
        guard !isAtRest else { return }
        let config = configuration
        if config.mass == 0 || milliseconds >= config.settleTimeMilliseconds {
            snapToTarget()
            return
        }
        precondition(milliseconds <= 10_000, "Spring advance exceeds the simulation bound")

        // `clamp` chooses damping once per advance, independently for each scalar path.
        // It is not a position clamp: a sufficiently long advance can still cross the target.
        var damping = config.damping
        let distance = target - value
        if config.clamp && velocity * distance > 0 && abs(velocity) > abs(distance) * sqrt(config.stiffness / config.mass) {
            damping = max(damping, 2 * sqrt(config.mass * config.stiffness))
        }

        // Preserve the observed fractional-step convention: the last step uses the complement
        // to ceil(ms), not the remainder. At 60 fps this is 16 x 1ms + 1/3ms.
        let safeStep = min(0.001, damping > 0 ? 0.5 * config.mass / damping : 0.001,
                           0.5 * sqrt(config.mass / config.stiffness))
        for step in 1...Int(ceil(milliseconds)) {
            let interval = Double(step) > milliseconds ? (Double(step) - milliseconds) / 1000 : 0.001
            // Viddeo permits more extreme tuning than the shipped presets. Subdivide only when
            // their 1ms step would be unstable; confirmed presets keep the exact decoded steps.
            let subdivisions = max(1, Int(ceil(interval / safeStep)))
            let dt = interval / Double(subdivisions)
            for _ in 0..<subdivisions {
                velocity += (config.stiffness * (target - value) - damping * velocity) / config.mass * dt
                value += velocity * dt
                if abs(velocity) < tolerance && abs(target - value) < tolerance {
                    snapToTarget()
                    return
                }
            }
        }
    }
}

/// Cache synchronization is independent of spring state, including across concurrent exports.
private final class SpringSettleCache: @unchecked Sendable {
    static let shared = SpringSettleCache()
    private let lock = NSLock()
    private var values: [SpringConfiguration: Double] = [:]

    func value(for config: SpringConfiguration, calculate: () -> Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[config] { return cached }
        let result = calculate()
        values[config] = result
        return result
    }
}
