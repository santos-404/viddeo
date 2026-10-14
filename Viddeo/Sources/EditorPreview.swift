import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Observation
import SwiftUI

/// Renders processed preview frames with the export's own `ExportFrameRenderer` (built by
/// `OfflineExporter.makeRenderer`), at a reduced size. An actor owns the stateful decoders, so every
/// frame request is serialized and runs off the main actor. Requests are PLAYBACK times, like the
/// exported movie; each is mapped to source time for the screen and camera frames.
///
/// The preview has no audio. Sources are seekable (`ExportFrameSource` reseeks on backward moves
/// and jumps), so scrubbing in any order and sequential playback share one code path.
actor PreviewFrameRenderer {
    /// Width of the preview canvas; the height follows the preset's output aspect ratio.
    static let previewWidth = 640

    nonisolated let width: Int
    nonisolated let height: Int
    nonisolated let duration: Double
    private let renderer: ExportFrameRenderer
    private let frames: ExportFrameSource
    private let camera: WebcamFrameSource?
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    init(session: RecordingSession, directory: URL, settings: ExportSettings, edit: ExportEdit?,
         showsClickEffects: Bool, previewWidth: Int = PreviewFrameRenderer.previewWidth) async throws {
        let prepared = try await OfflineExporter.makeRenderer(
            session: session, directory: directory, settings: settings, edit: edit,
            showsClickEffects: showsClickEffects, previewWidth: previewWidth)
        renderer = prepared.renderer
        width = prepared.renderer.outputWidth
        height = prepared.renderer.outputHeight
        duration = prepared.outputDuration.seconds
        frames = try await ExportFrameSource(asset: AVURLAsset(url: prepared.sourceURL), duration: prepared.sourceDuration,
                                             timeline: prepared.renderer.edit, seekable: true)
        if let plan = prepared.renderer.webcam {
            camera = try await WebcamFrameSource(plan: plan, timeline: prepared.renderer.edit, seekable: true)
        } else {
            camera = nil
        }
    }

    /// The frame shown at `time` seconds of playback (clamped into the playable range). Throws
    /// `CancellationError` without rendering when the requesting task was cancelled while queued.
    func frame(atPlayback time: Double) throws -> CGImage {
        try Task.checkCancellation()
        let playback = min(max(0, time.isFinite ? time : 0), max(0, duration - 0.001))
        let sourceTime = renderer.sourceTime(forPlaybackTime: playback)
        guard let source = try frames.image(atSource: sourceTime) else {
            throw OfflineExporter.ExportError.encodingFailed("the raw recording has no decodable frames")
        }
        let cameraFrame = try camera?.image(atSource: sourceTime)
        let image = renderer.image(source: source, at: sourceTime, camera: cameraFrame)
        guard let result = context.createCGImage(image, from: renderer.outputRect, format: .BGRA8, colorSpace: colorSpace) else {
            throw OfflineExporter.ExportError.encodingFailed("could not render a preview frame")
        }
        return result
    }

    /// Stops the decoders; the renderer is not used afterwards.
    func close() {
        frames.cancel()
        camera?.cancel()
    }
}

/// Preview state for the editor: the current frame, the playback position and play/pause. Rebuilt
/// by `prepare` whenever the edit, preset or click-effect toggle changes. Frame requests are
/// latest-wins: a new scrub position cancels the previous request (stale work is skipped), and
/// playback follows the wall clock, so a slow frame makes it skip ahead instead of lag.
@MainActor
@Observable
final class EditorPreviewModel {
    static let playbackFPS = 30.0

    private(set) var image: CGImage?
    /// Playback duration of the current edit (the scrubber's range).
    private(set) var duration = 0.0
    private(set) var time = 0.0
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var error: String?
    private(set) var aspectRatio = 16.0 / 9
    @ObservationIgnored private var renderer: PreviewFrameRenderer?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?

    /// Builds the renderer for the current edit and shows the frame at the current position. Cancelling
    /// the calling task (a newer edit arrived) abandons the build.
    func prepare(session: RecordingSession, directory: URL, settings: ExportSettings,
                 edit: ExportEdit, showsClickEffects: Bool) async {
        pause()
        renderTask?.cancel()
        isPreparing = true
        defer { isPreparing = false }
        do {
            let next = try await PreviewFrameRenderer(session: session, directory: directory, settings: settings,
                                                      edit: edit, showsClickEffects: showsClickEffects)
            guard !Task.isCancelled else { await next.close(); return }
            let previous = renderer
            renderer = next
            if let previous { Task { await previous.close() } }
            duration = next.duration
            aspectRatio = Double(next.width) / Double(next.height)
            time = min(time, duration)
            error = nil
            let first = try await next.frame(atPlayback: time)
            guard !Task.isCancelled else { return }
            image = first
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            renderer = nil
            image = nil
            self.error = error.localizedDescription
        }
    }

    /// Moves the playhead (pausing playback) and renders that frame.
    func scrub(to newTime: Double) {
        pause()
        time = min(max(0, newTime), duration)
        show(at: time)
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func pause() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    /// Cancels playback and queued frames, and releases the decoders.
    func stop() {
        pause()
        renderTask?.cancel()
        if let renderer { Task { await renderer.close() } }
        renderer = nil
    }

    private func show(at playback: Double) {
        guard let renderer else { return }
        renderTask?.cancel()
        renderTask = Task {
            do {
                let frame = try await renderer.frame(atPlayback: playback)
                guard !Task.isCancelled else { return }
                image = frame
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func play() {
        guard let renderer, duration > 0 else { return }
        renderTask?.cancel()
        if time >= duration - 0.01 { time = 0 }
        isPlaying = true
        let startTime = time
        let clock = ContinuousClock()
        let start = clock.now
        let interval = 1 / Self.playbackFPS
        playTask = Task {
            while !Task.isCancelled {
                let target = min(startTime + Self.seconds(clock.now - start), duration)
                do {
                    let frame = try await renderer.frame(atPlayback: target)
                    guard !Task.isCancelled else { return }
                    image = frame
                    time = target
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                    isPlaying = false
                    return
                }
                if target >= duration { isPlaying = false; return }
                // Next display tick after the render finished: frames that took too long are skipped.
                let ticks = (Self.seconds(clock.now - start) / interval).rounded(.down) + 1
                do { try await clock.sleep(until: start + .seconds(ticks * interval)) } catch { return }
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// Processed preview above the editor tabs: the frame the export would contain at the playhead
/// (stage, captions, cursor, click effects, zoom and camera), a scrubber over playback time and
/// play/pause. It has no audio.
struct EditorPreview: View {
    let editor: EditorModel
    let settings: ExportSettings
    let showsClickEffects: Bool
    @State private var model = EditorPreviewModel()

    /// Everything that changes the picture; audio settings are not part of it.
    private struct Key: Equatable {
        var timeline: TimelineModel
        var stage: StageStyle
        var stageEnabled: Bool
        var captions: CaptionTrack
        var captionConfiguration: CaptionConfiguration
        var webcam: WebcamConfiguration
        var settings: ExportSettings
        var showsClickEffects: Bool
    }

    private var key: Key {
        Key(timeline: editor.state.timeline, stage: editor.state.stage, stageEnabled: editor.state.stageEnabled,
            captions: editor.state.captions, captionConfiguration: editor.state.captionConfiguration,
            webcam: editor.state.webcam, settings: settings, showsClickEffects: showsClickEffects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
                if model.isPreparing && model.image == nil { ProgressView().controlSize(.small) }
            }
            .aspectRatio(model.aspectRatio, contentMode: .fit)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 10) {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
                    .disabled(model.duration <= 0)
                Slider(value: Binding(get: { model.time }, set: { model.scrub(to: $0) }),
                       in: 0...max(model.duration, 0.001))
                    .disabled(model.duration <= 0)
                Text("\(Self.format(model.time)) / \(Self.format(model.duration))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text("Preview unavailable: \(error)").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Preview renders with the export renderer at reduced size and has no audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) {
            // Slider drags change the edit continuously; only the last state is rendered.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await model.prepare(session: editor.session, directory: editor.directory, settings: settings,
                                edit: editor.exportEdit, showsClickEffects: showsClickEffects)
        }
        .onDisappear { model.stop() }
    }

    private static func format(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return "\(tenths / 600):\(String(format: "%02d", tenths / 10 % 60)).\(tenths % 10)"
    }
}
