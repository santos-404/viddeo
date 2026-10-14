import Foundation

/// A kept range of the raw recording. Times are seconds in raw video (source) time.
/// `timeScale` is a duration multiplier, as in the reference: playback duration is
/// source duration × timeScale, so 2 plays at half speed.
struct SpeedKeyframe: Codable, Sendable, Equatable {
    /// Seconds from this segment's sourceStart.
    var sourceOffset: Double
    /// Duration multiplier (1 / playback speed).
    var timeScale: Double
}

struct TimelineSegment: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var timeScale: Double = 1
    /// Optional source-relative knots. Missing/empty preserves version-1 constant-speed projects.
    var speedKeyframes: [SpeedKeyframe]? = nil
    var volume: Double = 1
    var systemVolume: Double = 1
    var hideCursor = false

    init(id: UUID = UUID(), sourceStart: Double, sourceEnd: Double, timeScale: Double = 1,
         volume: Double = 1, systemVolume: Double = 1, hideCursor: Bool = false,
         speedKeyframes: [SpeedKeyframe]? = nil) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.timeScale = timeScale
        self.speedKeyframes = speedKeyframes
        self.volume = volume
        self.systemVolume = systemVolume
        self.hideCursor = hideCursor
    }

    var sourceDuration: Double { sourceEnd - sourceStart }
    var playbackDuration: Double { playbackOffset(forSourceOffset: sourceDuration) }
    var speed: Double { 1 / timeScale }

    func scale(at offset: Double) -> Double {
        let knots = normalizedKnots
        guard let first = knots.first, let last = knots.last else { return timeScale }
        let x = min(sourceDuration, max(0, offset))
        if x <= first.sourceOffset { return first.timeScale }
        for (a, b) in zip(knots, knots.dropFirst()) where x <= b.sourceOffset {
            let fraction = (x - a.sourceOffset) / (b.sourceOffset - a.sourceOffset)
            return a.timeScale + (b.timeScale - a.timeScale) * fraction
        }
        return last.timeScale
    }

    /// Integral of the linearly interpolated duration multiplier, in playback seconds.
    func playbackOffset(forSourceOffset offset: Double) -> Double {
        let end = min(sourceDuration, max(0, offset))
        let knots = normalizedKnots
        guard !knots.isEmpty else { return end * timeScale }
        var total = 0.0
        var cursor = 0.0
        for knot in knots {
            if knot.sourceOffset > cursor {
                let upper = min(end, knot.sourceOffset)
                if upper > cursor {
                    let s0 = scale(at: cursor), s1 = scale(at: upper)
                    total += (upper - cursor) * (s0 + s1) / 2
                    cursor = upper
                }
            }
            if cursor >= end { return total }
        }
        if cursor < end { total += (end - cursor) * (scale(at: cursor) + scale(at: end)) / 2 }
        return total
    }

    func sourceOffset(forPlaybackOffset playback: Double) -> Double {
        let target = min(playbackDuration, max(0, playback))
        var low = 0.0, high = sourceDuration
        // Fixed iteration count makes inversion deterministic across platforms.
        for _ in 0..<52 {
            let mid = (low + high) / 2
            if playbackOffset(forSourceOffset: mid) < target { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    var normalizedKnots: [SpeedKeyframe] {
        guard let speedKeyframes, !speedKeyframes.isEmpty else { return [] }
        var result = speedKeyframes.sorted { $0.sourceOffset < $1.sourceOffset }
        if result.first?.sourceOffset != 0 { result.insert(.init(sourceOffset: 0, timeScale: timeScale), at: 0) }
        if result.last?.sourceOffset != sourceDuration { result.append(.init(sourceOffset: sourceDuration, timeScale: timeScale)) }
        return result
    }
}

/// One contiguous piece of output, in playback order. This is what an exporter consumes.
struct EditPlanItem: Sendable, Equatable {
    var segmentID: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var timeScale: Double
    var speedKeyframes: [SpeedKeyframe]?
    var playbackStart: Double
    var playbackEnd: Double
    var volume: Double
    var systemVolume: Double

    var playbackDuration: Double {
        guard let keys = speedKeyframes, !keys.isEmpty else { return (sourceEnd - sourceStart) * timeScale }
        let points = keys.sorted { $0.sourceOffset < $1.sourceOffset }
        var total = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            total += (b.sourceOffset - a.sourceOffset) * (a.timeScale + b.timeScale) / 2
        }
        return total
    }

    func scale(at offset: Double) -> Double {
        guard let keys = speedKeyframes, !keys.isEmpty else { return timeScale }
        let points = keys.sorted { $0.sourceOffset < $1.sourceOffset }
        let x = min(sourceEnd - sourceStart, max(0, offset))
        for (a, b) in zip(points, points.dropFirst()) where x <= b.sourceOffset {
            let f = (x - a.sourceOffset) / (b.sourceOffset - a.sourceOffset)
            return a.timeScale + (b.timeScale - a.timeScale) * f
        }
        return points.last?.timeScale ?? timeScale
    }
}

enum TimelineError: LocalizedError, Equatable {
    case empty
    case nonFiniteValue
    case outOfBounds
    case belowMinimumDuration
    case invalidTimeScale
    case invalidVolume
    case overlappingSegments
    case duplicateSegmentID
    case segmentNotFound
    case invalidSplitPoint
    case lastSegment
    case noNeighbor
    case invalidIndex

    var errorDescription: String? {
        switch self {
        case .empty: "The timeline must contain at least one segment."
        case .nonFiniteValue: "The timeline contains a time or value that is not a finite number."
        case .outOfBounds: "A segment extends outside the recording."
        case .belowMinimumDuration: "Segments must be at least 0.1 seconds long."
        case .invalidTimeScale: "Segment speed must keep the time scale between 0.05 and 10."
        case .invalidVolume: "Segment volume must be between 0 and 2."
        case .overlappingSegments: "Segments cannot use overlapping parts of the recording."
        case .duplicateSegmentID: "Two segments share the same identifier."
        case .segmentNotFound: "The segment no longer exists."
        case .invalidSplitPoint: "A split needs at least 0.1 seconds on both sides inside a kept segment."
        case .lastSegment: "The last remaining segment cannot be deleted."
        case .noNeighbor: "There is no neighboring segment in that direction."
        case .invalidIndex: "The requested position is outside the timeline."
        }
    }
}

/// Non-destructive edit list over the immutable raw recording. Array order is playback
/// order; source ranges never overlap, and source gaps are trimmed footage.
struct TimelineModel: Codable, Sendable, Equatable {
    enum Direction: Sendable { case next, previous }
    enum Edge: Sendable { case start, end, both }

    /// Observed reference minimum slice duration (100 ms).
    static let minSegmentDuration = 0.1
    /// Viddeo choice: the reference does not bound `timeScale`; 20× faster to 10× slower.
    static let timeScaleRange = 0.05...10.0
    /// Viddeo choice: up to +6 dB boost.
    static let volumeRange = 0.0...2.0
    static let tolerance = 1e-9

    var sourceDuration: Double
    var segments: [TimelineSegment]

    /// The observed default: one full-length segment at normal speed.
    init(sourceDuration: Double) {
        self.sourceDuration = sourceDuration
        segments = [TimelineSegment(sourceStart: 0, sourceEnd: sourceDuration)]
    }

    init(sourceDuration: Double, segments: [TimelineSegment]) {
        self.sourceDuration = sourceDuration
        self.segments = segments
    }

    var playbackDuration: Double { segments.reduce(0) { $0 + $1.playbackDuration } }

    var editPlan: [EditPlanItem] {
        var start = 0.0
        return segments.map { segment in
            defer { start += segment.playbackDuration }
            return EditPlanItem(segmentID: segment.id, sourceStart: segment.sourceStart,
                                sourceEnd: segment.sourceEnd, timeScale: segment.timeScale,
                                speedKeyframes: segment.normalizedKnots.isEmpty ? nil : segment.normalizedKnots,
                                playbackStart: start, playbackEnd: start + segment.playbackDuration,
                                volume: segment.volume, systemVolume: segment.systemVolume)
        }
    }

    func validate() throws {
        guard !segments.isEmpty else { throw TimelineError.empty }
        guard sourceDuration.isFinite else { throw TimelineError.nonFiniteValue }
        for segment in segments {
            let values = [segment.sourceStart, segment.sourceEnd, segment.timeScale,
                          segment.volume, segment.systemVolume]
            guard values.allSatisfy(\.isFinite) else { throw TimelineError.nonFiniteValue }
            guard segment.sourceStart >= 0, segment.sourceEnd <= sourceDuration + Self.tolerance
            else { throw TimelineError.outOfBounds }
            guard segment.sourceDuration >= Self.minSegmentDuration - Self.tolerance
            else { throw TimelineError.belowMinimumDuration }
            guard Self.timeScaleRange.contains(segment.timeScale) else { throw TimelineError.invalidTimeScale }
            if let keys = segment.speedKeyframes {
                var previous = -Double.infinity
                for key in keys {
                    guard key.sourceOffset.isFinite, key.timeScale.isFinite else { throw TimelineError.nonFiniteValue }
                    guard key.sourceOffset > previous, key.sourceOffset >= 0,
                          key.sourceOffset <= segment.sourceDuration else { throw TimelineError.outOfBounds }
                    guard Self.timeScaleRange.contains(key.timeScale) else { throw TimelineError.invalidTimeScale }
                    previous = key.sourceOffset
                }
            }
            guard Self.volumeRange.contains(segment.volume), Self.volumeRange.contains(segment.systemVolume)
            else { throw TimelineError.invalidVolume }
        }
        guard Set(segments.map(\.id)).count == segments.count else { throw TimelineError.duplicateSegmentID }
        let ordered = segments.sorted { $0.sourceStart < $1.sourceStart }
        for (a, b) in zip(ordered, ordered.dropFirst()) where b.sourceStart < a.sourceEnd - Self.tolerance {
            throw TimelineError.overlappingSegments
        }
    }

    // MARK: Mapping

    /// Half-open per segment, except that the very end of the timeline belongs to the last segment.
    func segmentIndex(atPlayback time: Double) -> Int? {
        guard time.isFinite, time >= 0 else { return nil }
        var start = 0.0
        for (index, segment) in segments.enumerated() {
            let end = start + segment.playbackDuration
            if time < end || (index == segments.count - 1 && time <= end + Self.tolerance) { return index }
            start = end
        }
        return nil
    }

    /// Nil when the source time was trimmed out. A time on a segment's exact end maps to that
    /// segment's playback end unless another segment starts there.
    func playbackTime(forSourceTime time: Double) -> Double? {
        guard time.isFinite else { return nil }
        var start = 0.0
        var endMatch: Double?
        for segment in segments {
            if time >= segment.sourceStart && time < segment.sourceEnd {
                return start + segment.playbackOffset(forSourceOffset: time - segment.sourceStart)
            }
            if time == segment.sourceEnd && endMatch == nil { endMatch = start + segment.playbackDuration }
            start += segment.playbackDuration
        }
        return endMatch
    }

    /// Clamped to the playback range.
    func sourceTime(forPlaybackTime time: Double) -> Double {
        guard !segments.isEmpty else { return 0 }
        let clamped = time.isFinite ? min(playbackDuration, max(0, time)) : 0
        let index = segmentIndex(atPlayback: clamped) ?? segments.count - 1
        let start = segments[..<index].reduce(0) { $0 + $1.playbackDuration }
        let segment = segments[index]
        return min(segment.sourceEnd, segment.sourceStart + segment.sourceOffset(forPlaybackOffset: max(0, clamped - start)))
    }

    /// One playback range per kept segment the source range touches, in playback order.
    func playbackRange(forSourceRange range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var start = 0.0
        for segment in segments {
            let lower = max(range.lowerBound, segment.sourceStart)
            let upper = min(range.upperBound, segment.sourceEnd)
            if lower < upper || (lower == upper && range.lowerBound == range.upperBound) {
                result.append((start + segment.playbackOffset(forSourceOffset: lower - segment.sourceStart))...(start + segment.playbackOffset(forSourceOffset: upper - segment.sourceStart)))
            }
            start += segment.playbackDuration
        }
        return result
    }

    /// Drops events in trimmed footage and rewrites times into playback time.
    func mapEvents(_ events: [CursorEvent]) -> [CursorEvent] {
        events.compactMap { event -> CursorEvent? in
            guard let time = playbackTime(forSourceTime: event.time) else { return nil }
            var mapped = event
            mapped.time = time
            return mapped
        }
        .enumerated()
        .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        .map(\.element)
    }

    // MARK: Mutations (atomic: a failed edit leaves the model unchanged)

    @discardableResult
    mutating func split(atPlayback time: Double) throws -> UUID {
        guard time.isFinite, time > 0, time < playbackDuration,
              let index = segmentIndex(atPlayback: time)
        else { throw TimelineError.invalidSplitPoint }
        let source = sourceTime(forPlaybackTime: time)
        return try split(index: index, atSource: source)
    }

    @discardableResult
    mutating func split(atSource time: Double) throws -> UUID {
        guard time.isFinite,
              let index = segments.firstIndex(where: { time > $0.sourceStart && time < $0.sourceEnd })
        else { throw TimelineError.invalidSplitPoint }
        return try split(index: index, atSource: time)
    }

    /// Clamps to the recording and to the nearest source-order neighbors; never overlaps them.
    mutating func trim(segmentID: UUID, newStart: Double, newEnd: Double) throws {
        guard newStart.isFinite, newEnd.isFinite else { throw TimelineError.nonFiniteValue }
        let index = try index(of: segmentID)
        let bounds = sourceBounds(around: index)
        guard newStart < bounds.upper, newEnd > bounds.lower else { throw TimelineError.overlappingSegments }
        let start = max(newStart, bounds.lower)
        let end = min(newEnd, bounds.upper)
        // The reference also allows a sub-minimum slice to shrink further; validated models
        // never hold sub-minimum segments, so every sub-minimum result is rejected here.
        guard end - start >= Self.minSegmentDuration - Self.tolerance else { throw TimelineError.belowMinimumDuration }
        try commit {
            $0.segments[index] = Self.reframed($0.segments[index], start: start, end: end)
        }
    }

    /// With `closeGap`, the previous source-order neighbor is extended up to the next one's
    /// start (or the recording end). Without a previous neighbor nothing is extended.
    mutating func delete(segmentID: UUID, closeGap: Bool = false) throws {
        let index = try index(of: segmentID)
        guard segments.count > 1 else { throw TimelineError.lastSegment }
        let removed = segments[index]
        let upper = sourceBounds(around: index).upper
        let previous = segments.indices
            .filter { $0 != index && segments[$0].sourceStart < removed.sourceStart }
            .max { segments[$0].sourceStart < segments[$1].sourceStart }
        try commit { model in
            if closeGap, let previous { model.segments[previous].sourceEnd = upper }
            model.segments.remove(at: index)
        }
    }

    /// Absorbs the adjacent segment (in playback order); keeps this segment's id and properties.
    mutating func merge(segmentID: UUID, with direction: Direction) throws {
        let index = try index(of: segmentID)
        let other = direction == .next ? index + 1 : index - 1
        guard segments.indices.contains(other) else { throw TimelineError.noNeighbor }
        let start = min(segments[index].sourceStart, segments[other].sourceStart)
        let end = max(segments[index].sourceEnd, segments[other].sourceEnd)
        for (position, segment) in segments.enumerated() where position != index && position != other {
            if segment.sourceStart < end - Self.tolerance && segment.sourceEnd > start + Self.tolerance {
                throw TimelineError.overlappingSegments
            }
        }
        try commit { model in
            model.segments[index] = Self.reframed(model.segments[index], start: start, end: end)
            model.segments.remove(at: other)
        }
    }

    /// Extends the chosen edge(s) to the source-order neighbor's edge or the recording bounds.
    mutating func removeTrim(segmentID: UUID, edge: Edge) throws {
        let index = try index(of: segmentID)
        let bounds = sourceBounds(around: index)
        try commit { model in
            let old = model.segments[index]
            let start = edge == .end ? old.sourceStart : bounds.lower
            let end = edge == .start ? old.sourceEnd : bounds.upper
            model.segments[index] = Self.reframed(old, start: start, end: end)
        }
    }

    /// Viddeo extension: the reference keeps slices in source order and has no reorder.
    /// Reordering only changes playback order; the source↔playback maps follow array order.
    mutating func move(segmentID: UUID, toIndex destination: Int) throws {
        let index = try index(of: segmentID)
        guard segments.indices.contains(destination) else { throw TimelineError.invalidIndex }
        try commit { model in
            let segment = model.segments.remove(at: index)
            model.segments.insert(segment, at: destination)
        }
    }

    mutating func setTimeScale(segmentID: UUID, to timeScale: Double) throws {
        let index = try index(of: segmentID)
        guard timeScale.isFinite else { throw TimelineError.nonFiniteValue }
        try commit { $0.segments[index].timeScale = timeScale; $0.segments[index].speedKeyframes = nil }
    }

    mutating func setSpeedKeyframes(segmentID: UUID, to keyframes: [SpeedKeyframe]) throws {
        let index = try self.index(of: segmentID)
        try commit { $0.segments[index].speedKeyframes = keyframes.isEmpty ? nil : keyframes }
    }

    mutating func setVolume(segmentID: UUID, to volume: Double) throws {
        let index = try index(of: segmentID)
        guard volume.isFinite else { throw TimelineError.nonFiniteValue }
        try commit { $0.segments[index].volume = volume }
    }

    mutating func setSystemVolume(segmentID: UUID, to volume: Double) throws {
        let index = try index(of: segmentID)
        guard volume.isFinite else { throw TimelineError.nonFiniteValue }
        try commit { $0.segments[index].systemVolume = volume }
    }

    mutating func setHideCursor(segmentID: UUID, to hidden: Bool) throws {
        let index = try index(of: segmentID)
        try commit { $0.segments[index].hideCursor = hidden }
    }

    // MARK: Helpers

    /// Observed: both halves must reach the minimum; the original keeps [start, t] and a
    /// clone with a new id and the same properties gets [t, end], right after it.
    private mutating func split(index: Int, atSource time: Double) throws -> UUID {
        let segment = segments[index]
        guard time - segment.sourceStart >= Self.minSegmentDuration - Self.tolerance,
              segment.sourceEnd - time >= Self.minSegmentDuration - Self.tolerance
        else { throw TimelineError.invalidSplitPoint }
        var clone = segment
        clone.id = UUID()
        clone.sourceStart = time
        let splitOffset = time - segment.sourceStart
        let atSplit = segment.scale(at: splitOffset)
        let allKeys = segment.speedKeyframes ?? []
        let leftKeys = allKeys.filter { $0.sourceOffset > 0 && $0.sourceOffset < splitOffset }
        let rightKeys = allKeys.filter { $0.sourceOffset > splitOffset }.map {
            SpeedKeyframe(sourceOffset: $0.sourceOffset - splitOffset, timeScale: $0.timeScale)
        }
        clone.timeScale = atSplit
        clone.speedKeyframes = allKeys.isEmpty ? nil : [SpeedKeyframe(sourceOffset: 0, timeScale: atSplit)] + rightKeys
        try commit { model in
            model.segments[index].sourceEnd = time
            model.segments[index].speedKeyframes = allKeys.isEmpty ? nil :
                [SpeedKeyframe(sourceOffset: 0, timeScale: segment.scale(at: 0))] + leftKeys +
                [SpeedKeyframe(sourceOffset: splitOffset, timeScale: atSplit)]
            model.segments.insert(clone, at: index + 1)
        }
        return clone.id
    }

    private func index(of id: UUID) throws -> Int {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { throw TimelineError.segmentNotFound }
        return index
    }

    /// The free source range around a segment: previous source-order end … next start.
    private func sourceBounds(around index: Int) -> (lower: Double, upper: Double) {
        let segment = segments[index]
        var lower = 0.0
        var upper = sourceDuration
        for (position, other) in segments.enumerated() where position != index {
            if other.sourceStart < segment.sourceStart {
                lower = max(lower, other.sourceEnd)
            } else {
                upper = min(upper, other.sourceStart)
            }
        }
        return (lower, upper)
    }

    private static func reframed(_ segment: TimelineSegment, start: Double, end: Double) -> TimelineSegment {
        var result = segment
        let oldStart = segment.sourceStart
        let oldEnd = segment.sourceEnd
        let startScale = start < oldStart ? segment.scale(at: 0) : segment.scale(at: start - oldStart)
        let endScale = end > oldEnd ? segment.scale(at: oldEnd - oldStart) : segment.scale(at: end - oldStart)
        let interior = (segment.speedKeyframes ?? []).filter {
            oldStart + $0.sourceOffset > start && oldStart + $0.sourceOffset < end
        }.map { SpeedKeyframe(sourceOffset: oldStart + $0.sourceOffset - start, timeScale: $0.timeScale) }
        result.sourceStart = start
        result.sourceEnd = end
        result.timeScale = startScale
        result.speedKeyframes = segment.speedKeyframes == nil ? nil :
            [SpeedKeyframe(sourceOffset: 0, timeScale: startScale)] + interior +
            [SpeedKeyframe(sourceOffset: end - start, timeScale: endScale)]
        return result
    }

    private mutating func commit(_ change: (inout TimelineModel) -> Void) throws {
        var copy = self
        change(&copy)
        try copy.validate()
        self = copy
    }
}
