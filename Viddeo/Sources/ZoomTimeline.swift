import Foundation

struct ZoomConfiguration: Codable, Sendable {
    var scale = 2.0
    var beforeClick = 0.3
    var afterClick = 2.5
    var mergeGap = 2.5
    var ignoreFinalSeconds = 1.0
    var tailMargin = 0.8
    var stiffness = 125.0
    var damping = 12.0
    var mass = 1.5
    var framesPerSecond = 60.0

    func validate() throws {
        let values = [scale, beforeClick, afterClick, mergeGap, ignoreFinalSeconds,
                      tailMargin, stiffness, damping, mass, framesPerSecond]
        guard values.allSatisfy(\.isFinite), scale >= 1, scale <= 8,
              beforeClick >= 0, afterClick >= 0, mergeGap >= 0,
              ignoreFinalSeconds >= 0, tailMargin >= 0,
              stiffness > 0, stiffness <= 1000, damping > 0, damping <= 200,
              mass >= 0.1, mass <= 100, framesPerSecond >= 24, framesPerSecond <= 120
        else { throw ZoomError.invalidConfiguration }
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("zoom-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("zoom-config.json"), options: .atomic)
    }
}

enum ZoomError: LocalizedError {
    case invalidConfiguration
    var errorDescription: String? { "Zoom settings contain invalid timing or spring values." }
}

struct ZoomFrame: Sendable, Equatable {
    var time: Double
    var scale: Double
    var centerX: Double
    var centerY: Double
}

struct ZoomRange: Sendable, Equatable {
    var start: Double
    var end: Double
}

/// Pure offline analysis. Grouping and physical smoothing are independent of the media API.
struct ZoomTimeline: Sendable {
    let ranges: [ZoomRange]
    private let frames: [ZoomFrame]
    private let fps: Double

    init(session: RecordingSession, configuration: ZoomConfiguration = .init()) {
        // Export validates user configuration; pure callers get safe defaults.
        let config = (try? configuration.validate()) == nil ? ZoomConfiguration() : configuration
        fps = config.framesPerSecond
        let duration = session.duration.isFinite ? min(12 * 60 * 60, max(0, session.duration)) : 0
        let events = session.events.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite &&
            $0.time >= 0 && $0.time <= duration &&
            (0...1).contains($0.x) && (0...1).contains($0.y)
        }.sorted { $0.time < $1.time }
        var merged: [ZoomRange] = []
        for event in events where event.kind != .move && event.time < duration - config.ignoreFinalSeconds {
            let start = max(0.001, floor(event.time * 1000) / 1000 - config.beforeClick)
            let end = min(floor(event.time * 1000) / 1000 + config.afterClick, duration - config.tailMargin)
            guard end > start else { continue }
            if let previous = merged.last, start <= previous.end + config.mergeGap {
                merged[merged.count - 1].end = max(previous.end, end)
            } else {
                merged.append(ZoomRange(start: start, end: end))
            }
        }
        ranges = merged
        let groups = merged.map { Self.groups(events: events, range: $0, session: session, scale: config.scale) }
        var x = Spring(value: 0.5)
        var y = Spring(value: 0.5)
        var scale = Spring(value: 1)
        var samples: [ZoomFrame] = []
        var rangeIndex = 0
        let maxStep = min(0.001, 0.5 * config.mass / config.damping,
                          0.2 * sqrt(config.mass / config.stiffness))
        let substeps = Int(ceil(1 / fps / maxStep))
        let dt = 1 / fps / Double(substeps)
        let count = Int(ceil(duration * fps)) + 1
        for index in 0..<count {
            let time = Double(index) / fps
            while rangeIndex < merged.count && time > merged[rangeIndex].end { rangeIndex += 1 }
            let active = rangeIndex < merged.count && time >= merged[rangeIndex].start
            let candidates = active ? groups[rangeIndex] : []
            let group = candidates.last(where: { $0.start <= time }) ?? candidates.first
            let targetScale = group == nil ? 1 : config.scale
            let targetX = group?.x ?? 0.5
            let targetY = group?.y ?? 0.5
            if index > 0 {
                // Small fixed substeps keep tuning configurations stable at every output FPS.
                for _ in 0..<substeps {
                    x.advance(to: targetX, dt: dt, config: config)
                    y.advance(to: targetY, dt: dt, config: config)
                    scale.advance(to: targetScale, dt: dt, config: config)
                }
            }
            let visibleScale = min(config.scale, max(1, scale.value))
            let margin = 0.5 / visibleScale
            samples.append(ZoomFrame(time: time, scale: visibleScale,
                                     centerX: min(1 - margin, max(margin, x.value)),
                                     centerY: min(1 - margin, max(margin, y.value))))
        }
        frames = samples
    }

    func frame(at time: Double) -> ZoomFrame {
        guard time.isFinite else { return frames[0] }
        let position = min(Double(frames.count - 1), max(0, time * fps))
        let lower = Int(position)
        let upper = min(lower + 1, frames.count - 1)
        let fraction = position - Double(lower)
        let a = frames[lower], b = frames[upper]
        return ZoomFrame(time: max(0, time), scale: a.scale + (b.scale - a.scale) * fraction,
                         centerX: a.centerX + (b.centerX - a.centerX) * fraction,
                         centerY: a.centerY + (b.centerY - a.centerY) * fraction)
    }

    private struct Group {
        var start: Double
        var x: Double
        var y: Double
    }

    private static func groups(events: [CursorEvent], range: ZoomRange,
                               session: RecordingSession, scale: Double) -> [Group] {
        var selected = events.filter { $0.time >= range.start && $0.time <= range.end }
        if let previous = events.last(where: { $0.time < range.start }) {
            var boundary = previous
            boundary.time = max(0, range.start - 0.001)
            selected.insert(boundary, at: 0)
        }
        var thinned: [CursorEvent] = []
        for event in selected {
            if let last = thinned.last, event.kind == .move {
                let distance = hypot((event.x - last.x) * Double(session.width),
                                     (event.y - last.y) * Double(session.height))
                if distance < 10 { continue }
            }
            thinned.append(event)
        }
        var chunks: [[CursorEvent]] = []
        var current: [CursorEvent] = []
        var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0
        for event in thinned {
            let newMinX = min(minX, event.x), newMaxX = max(maxX, event.x)
            let newMinY = min(minY, event.y), newMaxY = max(maxY, event.y)
            if !current.isEmpty && (newMaxX - newMinX > 0.5 / scale || newMaxY - newMinY > 0.5 / scale) {
                chunks.append(current)
                current = []
                minX = event.x; maxX = event.x; minY = event.y; maxY = event.y
            } else {
                minX = newMinX; maxX = newMaxX; minY = newMinY; maxY = newMaxY
            }
            current.append(event)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.enumerated().map { index, chunk in
            let finish = index + 1 < chunks.count ? chunks[index + 1][0].time : chunk.last!.time + 0.1
            var weight = 0.0, x = 0.0, y = 0.0
            for (eventIndex, event) in chunk.enumerated() {
                let next = eventIndex + 1 < chunk.count ? chunk[eventIndex + 1].time : finish
                let dwell = max(0, next - event.time)
                weight += dwell; x += event.x * dwell; y += event.y * dwell
            }
            let fallback = chunk.last!
            return Group(start: chunk[0].time, x: weight > 0 ? x / weight : fallback.x,
                         y: weight > 0 ? y / weight : fallback.y)
        }
    }
}

private struct Spring {
    var value: Double
    var velocity = 0.0

    mutating func advance(to target: Double, dt: Double, config: ZoomConfiguration) {
        let acceleration = (config.stiffness * (target - value) - config.damping * velocity) / config.mass
        velocity += acceleration * dt
        value += velocity * dt
        if abs(target - value) < 0.00001 && abs(velocity) < 0.00001 {
            value = target
            velocity = 0
        }
    }
}
