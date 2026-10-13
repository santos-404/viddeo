import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Optional editing state applied by the exporter. Every field nil keeps the plain export.
///
/// Time domains: the exported movie runs in PLAYBACK time (the timeline's edit plan). Zoom
/// frames, click rings and caption cues are all stored in SOURCE time (raw.mp4 time), so each
/// output frame is looked up at `timeline.sourceTime(forPlaybackTime:)`.
struct ExportEdit: Sendable {
    var timeline: TimelineModel?
    var stage: StageStyle?
    /// Cue times are source-time milliseconds. Under a speed ramp a cue therefore stays on
    /// screen for its source duration × the segment's `timeScale` of output time, and cues
    /// inside trimmed footage never appear.
    var captions: (track: CaptionTrack, configuration: CaptionConfiguration)?

    init(timeline: TimelineModel? = nil, stage: StageStyle? = nil,
         captions: (track: CaptionTrack, configuration: CaptionConfiguration)? = nil) {
        self.timeline = timeline
        self.stage = stage
        self.captions = captions
    }

    var isEmpty: Bool { timeline == nil && stage == nil && captions == nil }

    /// Whatever the session folder has: `project.json` → its timeline, `stage-config.json` →
    /// the stage, `captions.json` (+ `captions-config.json`, defaults when absent) → captions
    /// when the configuration is enabled and the track has cues. Absent files leave the field nil;
    /// present but invalid files throw.
    static func load(from directory: URL, session: RecordingSession) throws -> ExportEdit {
        let manager = FileManager.default
        var edit = ExportEdit()
        var stageEnabled: Bool?
        if manager.fileExists(atPath: directory.appendingPathComponent(ViddeoProject.filename).path) {
            let project = try ViddeoProject.load(from: directory, session: session)
            edit.timeline = project.timeline
            stageEnabled = project.stageEnabled
        }
        if stageEnabled != false, manager.fileExists(atPath: directory.appendingPathComponent("stage-config.json").path) {
            edit.stage = try StageStyle.load(in: directory)
        }
        if let track = try CaptionTrack.load(from: directory), !track.cues.isEmpty {
            let configuration = try CaptionConfiguration.load(in: directory)
            if configuration.enabled { edit.captions = (track, configuration) }
        }
        return edit
    }
}

/// Source frames for an export. Without a timeline it is one forward `SourceFrameReader` over
/// the whole recording (the original path). With a timeline, requests are source times that may
/// jump: forward steps within `reseekDistance` keep decoding sequentially (cheapest for split or
/// sped-up segments); backward moves and longer jumps (trims, reorder) open a fresh reader that
/// starts shortly before the requested time. Only one reader is open at a time, so memory stays
/// bounded by the decoder's own small queue.
final class ExportFrameSource {
    static let reseekDistance = 1.0

    private let asset: AVAsset
    private let track: AVAssetTrack
    private let timeline: TimelineModel?
    private var reader: SourceFrameReader?
    private var lastRequest = -Double.infinity

    init(asset: AVAsset, duration: CMTime, timeline: TimelineModel?) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw OfflineExporter.ExportError.missingVideoTrack
        }
        self.asset = asset
        self.track = track
        self.timeline = timeline
        if timeline == nil {
            reader = try SourceFrameReader(asset: asset, track: track,
                                           timeRange: CMTimeRange(start: .zero, duration: duration))
        }
    }

    /// The latest decoded frame at or before `sourceTime` (or the first frame after it when none precedes it).
    func image(atSource sourceTime: Double) throws -> CIImage? {
        guard timeline != nil else { return try reader?.image(at: sourceTime) }
        if reader == nil || sourceTime < lastRequest - 1e-6 || sourceTime > lastRequest + Self.reseekDistance {
            try seek(to: sourceTime)
        }
        lastRequest = sourceTime
        return try reader?.image(at: sourceTime)
    }

    func cancel() {
        reader?.cancel()
    }

    /// Screen recordings can hold one frame for seconds, so the start margin grows until the
    /// reader's first frame is at or before the target (or the reader starts at zero).
    private func seek(to time: Double) throws {
        var margin = 0.5
        while true {
            reader?.cancel()
            let start = max(0, time - margin)
            let next = try SourceFrameReader(
                asset: asset, track: track,
                timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
            )
            reader = next
            guard let first = try next.firstFrameTime(), first > time + 1e-6, start > 0 else { return }
            margin *= 4
        }
    }
}
