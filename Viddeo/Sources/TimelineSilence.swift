import Foundation

struct TrimSilenceReport: Sendable, Equatable {
    /// Source seconds dropped from the kept timeline (0 for speed-ups).
    var removedSourceSeconds: Double
    /// Playback seconds the edit saved (`playbackDuration` before − after).
    var savedPlaybackSeconds: Double
    /// Chunks that changed the timeline.
    var affectedChunks: Int
    /// Chunks that were too short, invalid, already applied or outside every kept segment.
    var skippedChunks: Int
}

/// Viddeo editor actions (design choice: the reference was not observed to speed up or trim silence
/// on its own). Chunks are in SOURCE milliseconds; each chunk's inner region
/// [start + padding, end − padding] is edited and only where it lies inside existing segments.
extension TimelineModel {
    /// Removes the inner region of every chunk whose inner length is at least `minRemovedMs`.
    /// Atomic: on any error the model is unchanged.
    @discardableResult
    mutating func trimSilence(chunks: [SilenceDetectionChunk], keepPaddingMs: Double = 150,
                              minRemovedMs: Double = 300) throws -> TrimSilenceReport {
        try applySilenceEdit(chunks: chunks, keepPaddingMs: keepPaddingMs, minInnerMs: minRemovedMs, timeScale: nil)
    }

    /// Splits at the inner boundaries and sets `timeScale` on the inner segments (0.25 = 4× speed).
    /// Overrides any earlier speed of the covered footage. Inner pieces shorter than the 0.1 s
    /// minimum segment length stay untouched. Atomic.
    @discardableResult
    mutating func speedUpSilence(chunks: [SilenceDetectionChunk], timeScale: Double = 0.25,
                                 keepPaddingMs: Double = 150, minDurationMs: Double = 300) throws -> TrimSilenceReport {
        guard timeScale.isFinite else { throw TimelineError.nonFiniteValue }
        guard Self.timeScaleRange.contains(timeScale) else { throw TimelineError.invalidTimeScale }
        return try applySilenceEdit(chunks: chunks, keepPaddingMs: keepPaddingMs, minInnerMs: minDurationMs, timeScale: timeScale)
    }

    // MARK: Helpers

    private mutating func applySilenceEdit(chunks: [SilenceDetectionChunk], keepPaddingMs: Double,
                                           minInnerMs: Double, timeScale: Double?) throws -> TrimSilenceReport {
        guard keepPaddingMs.isFinite, minInnerMs.isFinite, keepPaddingMs >= 0, minInnerMs >= 0
        else { throw TimelineError.nonFiniteValue }
        try validate()
        let tolerance = Self.tolerance
        let minimum = Self.minSegmentDuration
        let keptBefore = segments.reduce(0) { $0 + $1.sourceDuration }
        let playbackBefore = playbackDuration
        var work = self
        var affected = 0
        var skipped = 0

        let ordered = chunks.sorted { $0.startMs < $1.startMs }
        for chunk in ordered {
            guard chunk.startMs.isFinite, chunk.endMs.isFinite else { skipped += 1; continue }
            let innerMs = chunk.endMs - chunk.startMs - 2 * keepPaddingMs
            guard innerMs > 0, innerMs >= minInnerMs - 1e-9 else { skipped += 1; continue }
            let low = (chunk.startMs + keepPaddingMs) / 1000
            let high = (chunk.endMs - keepPaddingMs) / 1000
            let snapshot = work
            for id in work.segments.map(\.id) {
                guard let segment = work.segments.first(where: { $0.id == id }) else { continue }
                var lower = max(low, segment.sourceStart)
                var upper = min(high, segment.sourceEnd)
                guard upper - lower > tolerance else { continue }
                // A cut strictly inside a segment must leave at least the minimum length on that side.
                if lower > segment.sourceStart + tolerance { lower = max(lower, segment.sourceStart + minimum) }
                if upper < segment.sourceEnd - tolerance { upper = min(upper, segment.sourceEnd - minimum) }
                guard upper - lower > tolerance else { continue }
                let coversStart = lower <= segment.sourceStart + tolerance
                let coversEnd = upper >= segment.sourceEnd - tolerance
                if let timeScale {
                    guard upper - lower >= minimum - tolerance else { continue }
                    var target = id
                    if coversStart && coversEnd {
                        target = id
                    } else if coversStart {
                        try work.split(atSource: upper)
                    } else if coversEnd {
                        target = try work.split(atSource: lower)
                    } else {
                        target = try work.split(atSource: lower)
                        try work.split(atSource: upper)
                    }
                    try work.setTimeScale(segmentID: target, to: timeScale)
                } else if coversStart && coversEnd {
                    guard work.segments.count > 1 else { continue }
                    try work.delete(segmentID: id)
                } else if coversStart {
                    try work.split(atSource: upper)
                    try work.delete(segmentID: id)
                } else if coversEnd {
                    try work.delete(segmentID: work.split(atSource: lower))
                } else {
                    let middle = try work.split(atSource: lower)
                    try work.split(atSource: upper)
                    try work.delete(segmentID: middle)
                }
            }
            if work == snapshot { skipped += 1 } else { affected += 1 }
        }
        try work.validate()
        let report = TrimSilenceReport(
            removedSourceSeconds: max(0, keptBefore - work.segments.reduce(0) { $0 + $1.sourceDuration }),
            savedPlaybackSeconds: playbackBefore - work.playbackDuration,
            affectedChunks: affected, skippedChunks: skipped)
        self = work
        return report
    }
}
