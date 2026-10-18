import CoreGraphics
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

extension ZoomFrame {
    /// Visible source rectangle (bottom-left origin, like Core Image) for a `width` x `height`
    /// source: `1/scale` of it, centred on the normalized top-left-origin centre and kept inside.
    func cropRect(width: CGFloat, height: CGFloat) -> CGRect {
        let scale = self.scale.isFinite ? max(1, self.scale) : 1
        let cropWidth = width / CGFloat(scale)
        let cropHeight = height / CGFloat(scale)
        let centerX = CGFloat(self.centerX.isFinite ? self.centerX : 0.5) * width
        // ZoomTimeline uses a top-left normalized origin; Core Image uses bottom-left.
        let centerY = CGFloat(1 - (self.centerY.isFinite ? self.centerY : 0.5)) * height
        let clampedX = min(max(centerX, cropWidth / 2), width - cropWidth / 2)
        let clampedY = min(max(centerY, cropHeight / 2), height - cropHeight / 2)
        return CGRect(x: clampedX - cropWidth / 2, y: clampedY - cropHeight / 2,
                      width: cropWidth, height: cropHeight)
    }
}

/// Screen / zoom motion blur: the shutter math, independent of any renderer. The same
/// `motionBlurAmount` as the cursor (see `CursorConfiguration`): `strength = amount x fps / 60`, the
/// trail runs from `lerp(now, before, strength)` to `now` (backward only) where `before` is the zoom
/// crop one frame earlier, so the shutter is `amount / 60` s at any fps. The renderer averages one
/// resample per returned crop with equal weights; a single crop means the plain, unblurred path.
struct ScreenMotionBlur: Sendable, Equatable {
    /// Reference sample caps (16 export, 6 interactive); spans are viddeo design choices, like the cursor's.
    static let exportSamples = 16, previewSamples = 6
    static let exportSpanPixels = 4.0, previewSpanPixels = 16.0
    /// Below this much edge travel (output pixels) the frame is left alone.
    static let minimumMotionPixels = 0.5

    var amount = 1.0
    var fps = 60.0
    var maxSamples = exportSamples
    var spanPixels = exportSpanPixels

    static func preview(amount: Double = 1, fps: Double = 60) -> Self {
        Self(amount: amount, fps: fps, maxSamples: previewSamples, spanPixels: previewSpanPixels)
    }

    var strength: Double {
        guard amount.isFinite, amount > 0, fps.isFinite, fps > 0 else { return 0 }
        return amount * fps / 60
    }

    /// Crops to resample and average, oldest first (midpoints of equal trail slices). `[now]` when
    /// there is no blur or the travel of any crop edge, scaled by `outputScale` (output pixels per
    /// source pixel), is below half a pixel. The sample count is `ceil(travel / spanPixels)`,
    /// clamped to `2...maxSamples`.
    func crops(now: CGRect, before: CGRect, outputScale: Double) -> [CGRect] {
        let strength = self.strength
        guard strength > 0, maxSamples > 1, outputScale.isFinite, outputScale > 0 else { return [now] }
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
        let start = CGRect(x: mix(now.minX, before.minX, strength), y: mix(now.minY, before.minY, strength),
                           width: mix(now.width, before.width, strength), height: mix(now.height, before.height, strength))
        let travel = max(abs(start.minX - now.minX), abs(start.maxX - now.maxX),
                         abs(start.minY - now.minY), abs(start.maxY - now.maxY)) * outputScale
        guard travel.isFinite, travel >= Self.minimumMotionPixels, start.width > 0, start.height > 0 else { return [now] }
        let count = min(maxSamples, max(2, Int(ceil(travel / max(0.5, spanPixels)))))
        return (0..<count).map { k in
            let t = (Double(k) + 0.5) / Double(count)   // 0 = trail start, 1 = now
            return CGRect(x: mix(start.minX, now.minX, t), y: mix(start.minY, now.minY, t),
                          width: mix(start.width, now.width, t), height: mix(start.height, now.height, t))
        }
    }
}

struct ZoomRange: Sendable, Equatable {
    var start: Double
    var end: Double
}

/// All sizes use the same resolved output coordinate system, except `sourceSize` (source pixels).
/// The visible part is capped per axis at the whole source, as in the reference layout resolver.
struct ZoomVisibleGeometry: Sendable {
    var sourceSize: CGSize
    var viewportSize: CGSize
    var unzoomedScreenSize: CGSize

    func visibleSourceSize(atZoom scale: Double) -> CGSize {
        CGSize(width: sourceSize.width * min(1, viewportSize.width / (unzoomedScreenSize.width * scale)),
               height: sourceSize.height * min(1, viewportSize.height / (unzoomedScreenSize.height * scale)))
    }
}

/// Pure offline analysis. Grouping and physical smoothing are independent of the media API.
struct ZoomTimeline: Sendable {
    let ranges: [ZoomRange]
    private let frames: [ZoomFrame]
    private let fps: Double

    /// Used only while assembling a renderer, before its resolved stage and webcam plan exist.
    static let unzoomed = Self()

    private init() {
        ranges = []
        frames = [ZoomFrame(time: 0, scale: 1, centerX: 0.5, centerY: 0.5)]
        fps = 60
    }

    /// The provider receives each range's SOURCE start time (seconds) and selected zoom, and
    /// returns the visible source width/height in source pixels. It is consumed during construction;
    /// no closure or renderer state survives in the immutable sample table. Nil preserves the
    /// legacy full-source viewport for callers without resolved geometry.
    init(session: RecordingSession, configuration: ZoomConfiguration = .init(),
         items: ZoomItemConfiguration? = nil,
         visibleSourceSize: ((Double, Double) -> CGSize)? = nil) {
        // Export validates user configuration; pure callers get safe defaults.
        let config = (try? configuration.validate()) == nil ? ZoomConfiguration() : configuration
        fps = config.framesPerSecond
        let duration = session.duration.isFinite ? min(12 * 60 * 60, max(0, session.duration)) : 0
        let events = Self.validEvents(session: session, duration: duration)
        let requested = items ?? Self.automaticItems(session: session, configuration: config)
        let resolvedItems = (try? requested.validate(duration: duration)) == nil ? ZoomItemConfiguration() : requested
        let ordered = resolvedItems.items.sorted { $0.sourceStart < $1.sourceStart }
        let enabled = ordered.filter { !$0.isDisabled }
        ranges = enabled.map { ZoomRange(start: $0.sourceStart, end: $0.sourceEnd) }
        let groups = enabled.map { item -> [Group] in
            if item.mode == .manual { return [Group(start: item.sourceStart, x: item.centerX, y: item.centerY)] }
            let fallback = CGSize(width: Double(session.width) / item.scale, height: Double(session.height) / item.scale)
            let resolved = visibleSourceSize?(item.sourceStart, item.scale) ?? fallback
            let valid = resolved.width.isFinite && resolved.height.isFinite && resolved.width > 0 && resolved.height > 0
            return Self.groups(events: events, range: ZoomRange(start: item.sourceStart, end: item.sourceEnd),
                               session: session, visibleSourceSize: valid ? resolved : fallback)
        }
        let springConfig = SpringConfiguration(stiffness: config.stiffness, damping: config.damping, mass: config.mass)
        var x = Spring(value: 0.5, configuration: springConfig)
        var y = Spring(value: 0.5, configuration: springConfig)
        var scale = Spring(value: 1, configuration: springConfig)
        var samples: [ZoomFrame] = []
        var rangeIndex = 0
        let stepMilliseconds = 1000 / fps
        let maximumScale = enabled.map(\.scale).max() ?? 1
        let leadIn = resolvedItems.startAnimationEarly ? 0.35 : 0
        let instant = enabled.filter(\.hasInstantAnimation)
        var instantIndex = 0
        let count = Int(ceil(duration * fps)) + 1
        for index in 0..<count {
            let time = Double(index) / fps
            while rangeIndex < enabled.count && time > enabled[rangeIndex].sourceEnd { rangeIndex += 1 }
            let active = rangeIndex < enabled.count && time >= enabled[rangeIndex].sourceStart
                - (enabled[rangeIndex].hasInstantAnimation ? 0 : leadIn)
            let candidates = active ? groups[rangeIndex] : []
            let group = candidates.last(where: { $0.start <= time }) ?? candidates.first
            let targetScale = group == nil ? 1 : enabled[rangeIndex].scale
            let targetX = group?.x ?? 0.5
            let targetY = group?.y ?? 0.5
            if index > 0 {
                // Like the reference animation timeline: advance toward the previous frame's
                // targets, then install this frame's targets without clearing velocity.
                x.advance(milliseconds: stepMilliseconds)
                y.advance(milliseconds: stepMilliseconds)
                scale.advance(milliseconds: stepMilliseconds)
            }
            x.setTarget(targetX)
            y.setTarget(targetY)
            scale.setTarget(targetScale)
            while instantIndex < instant.count && time > instant[instantIndex].sourceEnd + 0.05 { instantIndex += 1 }
            let motion = instantIndex < instant.count && time >= instant[instantIndex].sourceStart
                ? SpringConfiguration.instant : springConfig
            x.updateConfiguration(motion)
            y.updateConfiguration(motion)
            scale.updateConfiguration(motion)
            let visibleScale = min(maximumScale, max(1, scale.value))
            let margin = 0.5 / visibleScale
            samples.append(ZoomFrame(time: time, scale: visibleScale,
                                     centerX: min(1 - margin, max(margin, x.value)),
                                     centerY: min(1 - margin, max(margin, y.value))))
        }
        frames = samples
    }

    /// Generates ranges only; targets are resolved later using each renderer's visible geometry.
    static func automaticItems(session: RecordingSession, configuration: ZoomConfiguration = .init()) -> ZoomItemConfiguration {
        let config = (try? configuration.validate()) == nil ? ZoomConfiguration() : configuration
        let duration = session.duration.isFinite ? min(12 * 60 * 60, max(0, session.duration)) : 0
        let events = validEvents(session: session, duration: duration)
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
        return ZoomItemConfiguration(items: merged.map {
            ZoomItem(sourceStart: $0.start, sourceEnd: $0.end, scale: config.scale)
        })
    }

    private static func validEvents(session: RecordingSession, duration: Double) -> [CursorEvent] {
        session.events.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite &&
            $0.time >= 0 && $0.time <= duration &&
            (0...1).contains($0.x) && (0...1).contains($0.y)
        }.sorted { $0.time < $1.time }
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
                               session: RecordingSession, visibleSourceSize: CGSize) -> [Group] {
        let maxWidth = 0.5 * min(1, Double(visibleSourceSize.width) / max(1, Double(session.width)))
        let maxHeight = 0.5 * min(1, Double(visibleSourceSize.height) / max(1, Double(session.height)))
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
            if !current.isEmpty && (newMaxX - newMinX > maxWidth || newMaxY - newMinY > maxHeight) {
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
