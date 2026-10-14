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
    /// Screen-recording seconds at which the first camera frame appears. Negative when the camera
    /// started first; camera time is `sourceTime - offset`.
    var offset: Double

    /// The plan for `session`'s camera, or nil when nothing should be drawn: no camera was recorded,
    /// the overlay is hidden, or the layout is screen-only. A camera that should be drawn but whose
    /// file is missing is an error, not a silent omission.
    ///
    /// `contentRect` is where the screen content sits in the output canvas (Core Image space): the
    /// stage rect when a stage is on, the fitted content rect otherwise.
    static func make(session: RecordingSession, directory: URL, configuration: WebcamConfiguration,
                     outputSize: CGSize, contentRect: CGRect) async throws -> Self? {
        guard let webcam = session.webcam, !configuration.hide, configuration.layout != .screenOnly else { return nil }
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
        if configuration.hideDuringSilenceMs != nil, configuration.layout == .cameraOverlay,
           let audio = session.audio, audio.microphoneSamples > 0 {
            let source = directory.appendingPathComponent(session.videoFilename, isDirectory: false)
            chunks = try await SilenceDetector.detect(audioURL: source, trackSelection: .microphone(title: audio.microphoneTrackName))
                .map { SilenceChunk(startMs: $0.startMs, endMs: $0.endMs) }
        }
        return Self(overlay: WebcamOverlay(configuration: configuration, outputSize: outputSize, contentRect: contentRect),
                    chunks: chunks, cameraURL: url, offset: webcam.firstPTS)
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
