import AVFoundation
import CoreImage
import Foundation

/// Everything the exporter needs to composite the recorded camera. Immutable, so the frame renderer
/// that carries it stays `Sendable`; the stateful decoder is `WebcamFrameSource`.
struct WebcamExportPlan: Sendable {
    var overlay: WebcamOverlay
    /// Silence ranges in recording time (milliseconds); empty unless hide-during-silence is on.
    var chunks: [SilenceChunk]
    var cameraURL: URL
    /// Person masks for the cutout layout; nil when no layout in the configuration is `cutoutCamera`.
    var cutout: CutoutMaskCache? = nil
    /// Source aspect (width / height) of the screen recording, for fitting it into a split pane.
    var sourceAspect = 16.0 / 9.0
    /// Screen-recording seconds at which the first camera frame appears. Negative when the camera
    /// started first; camera time is `sourceTime - offset`.
    var offset: Double

    /// The plan for `session`'s camera, or nil when nothing should be drawn: no camera was recorded,
    /// the overlay is hidden, or the layout is screen-only. A camera that should be drawn but whose
    /// file is missing is an error, not a silent omission.
    ///
    /// `contentRect` is where the screen content sits in the output canvas (Core Image space): the
    /// stage rect when a stage is on, the fitted content rect otherwise. `stage` gives the split-screen and
    /// cutout layouts their area (the output inset by the stage padding), pane gap and corner radius.
    /// `cutoutQuality` is `.fast` for the editor preview.
    static func make(session: RecordingSession, directory: URL, configuration: WebcamConfiguration,
                     outputSize: CGSize, contentRect: CGRect, stage: StageRenderer? = nil,
                     cutoutQuality: CutoutQuality = .balanced) async throws -> Self? {
        // Per-layout items can show the camera even when the default layout is screen-only.
        guard let webcam = session.webcam, !configuration.hide,
              configuration.usedLayouts.contains(where: { $0 != .screenOnly }) else { return nil }
        try configuration.validate()
        guard !webcam.filename.isEmpty, webcam.filename != ".", webcam.filename != "..",
              URL(fileURLWithPath: webcam.filename).lastPathComponent == webcam.filename,
              webcam.firstPTS.isFinite else {
            throw OfflineExporter.ExportError.invalidSession("the camera file name or offset is invalid")
        }
        let url = directory.appendingPathComponent(webcam.filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OfflineExporter.ExportError.invalidSession(
                "the recorded camera video \(webcam.filename) is missing; hide the camera in the editor to export without it")
        }
        var chunks: [SilenceChunk] = []
        if configuration.hideDuringSilenceMs != nil, configuration.usedLayouts.contains(.cameraOverlay),
           let audio = session.audio, audio.microphoneSamples > 0 {
            let source = directory.appendingPathComponent(session.videoFilename, isDirectory: false)
            chunks = try await SilenceDetector.detect(audioURL: source, trackSelection: .microphone(title: audio.microphoneTrackName))
                .map { SilenceChunk(startMs: $0.startMs, endMs: $0.endMs) }
        }
        var area: CGRect?, gap: Double?, radius = 0.0
        if let stage {
            // The stage's own padding formula (`StageRenderer.stageRect`), without the aspect fit; its radius.
            let padding = stage.style.paddingRatio * min(outputSize.width, outputSize.height)
            area = CGRect(origin: .zero, size: outputSize).insetBy(dx: padding, dy: padding)
            gap = padding
            radius = stage.style.cornerRadius * Double(outputSize.height) / StageStyle.referenceHeight
        }
        let overlay = WebcamOverlay(configuration: configuration, outputSize: outputSize, contentRect: contentRect,
                                    layoutArea: area, paneGap: gap, paneCornerRadius: radius)
        return Self(overlay: overlay, chunks: chunks, cameraURL: url,
                    cutout: configuration.usedLayouts.contains(.cutoutCamera) ? CutoutMaskCache(quality: cutoutQuality) : nil,
                    sourceAspect: session.height > 0 ? Double(session.width) / Double(session.height) : 16.0 / 9.0,
                    offset: webcam.firstPTS)
    }

    /// The layout at source time `time` (seconds), resolved for the frame being drawn.
    func resolve(atSource time: Double, camera: CIImage?, zoomScale: Double) -> WebcamOverlay.ResolvedLayout {
        let extent = camera?.extent
        let cameraAspect = extent.map { $0.isInfinite || $0.isEmpty ? 1 : Double($0.width / $0.height) } ?? 1
        return overlay.resolve(layout: overlay.layout(atMs: time * 1000), sourceAspect: sourceAspect,
                               cameraAspect: cameraAspect, zoomScale: zoomScale)
    }
}

/// Decodes camera frames for the export loops: a thin time mapping over `ExportFrameSource`, so
/// timelines that jump (trim, reorder) get the same seek handling as the screen frames.
final class WebcamFrameSource {
    private let frames: ExportFrameSource
    private let offset: Double

    init(plan: WebcamExportPlan, timeline: TimelineModel?, seekable: Bool = false) async throws {
        let asset = AVURLAsset(url: plan.cameraURL)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.isNumeric, duration > .zero else {
            throw OfflineExporter.ExportError.invalidSession("the recorded camera video has no frames")
        }
        frames = try await ExportFrameSource(asset: asset, duration: duration, timeline: timeline, seekable: seekable)
        offset = plan.offset
    }

    /// The camera frame shown at screen-recording time `sourceTime`: the first frame before the
    /// camera started and the last one after it ended.
    func image(atSource sourceTime: Double) throws -> CIImage? {
        try frames.image(atSource: max(0, sourceTime - offset))
    }

    func cancel() { frames.cancel() }
}
