import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Observation
import SwiftUI

/// Pure rules that keep the preview's audio player on the video playhead. Video is authoritative: it
/// follows the wall clock, and audio is started, paused or re-seeked to match it. A drift above
/// `maxDrift` is corrected; smaller drift is left alone because a seek is itself audible.
enum PreviewAudioSync {
    /// Largest tolerated difference between the audio position and the playhead, in seconds.
    static let maxDrift = 0.06

    enum Command: Equatable {
        case none
        case start(at: Double)
        case seek(to: Double)
        case pause
    }

    /// What to do with the audio player given the video `playhead` (playback seconds), the player's
    /// own `audioPosition`, whether it is running, whether the preview wants playback and the audio's
    /// length. Past the end of the audio (or when the preview is paused) a running player is paused.
    static func command(playhead: Double, audioPosition: Double, audioIsPlaying: Bool,
                        wantsPlayback: Bool, audioDuration: Double) -> Command {
        guard playhead.isFinite, audioDuration > 0 else { return audioIsPlaying ? .pause : .none }
        guard wantsPlayback, playhead < audioDuration else { return audioIsPlaying ? .pause : .none }
        guard audioIsPlaying else { return .start(at: max(0, playhead)) }
        return abs(audioPosition - playhead) > maxDrift ? .seek(to: playhead) : .none
    }
}

/// Plays the preview's mixed audio file with `AVAudioPlayer`. The mix is rendered offline in playback
/// time, so playback position equals preview time and no scheduling beyond `PreviewAudioSync` is needed.
@MainActor
final class PreviewAudioPlayer {
    private var player: AVAudioPlayer?
    private(set) var fileURL: URL?

    /// Volume 0 keeps the player running (and in sync) while muted.
    var isMuted = false { didSet { player?.volume = isMuted ? 0 : 1 } }
    var isLoaded: Bool { player != nil }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var duration: Double { player?.duration ?? 0 }
    var position: Double { player?.currentTime ?? 0 }

    /// Opens `url` (a temporary file this player now owns and deletes when replaced), replacing any
    /// previous file. Returns false and deletes `url` when it cannot be played.
    @discardableResult
    func load(_ url: URL) -> Bool {
        unload()
        guard let next = try? AVAudioPlayer(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        next.volume = isMuted ? 0 : 1
        next.prepareToPlay()
        player = next
        fileURL = url
        return true
    }

    /// Stops playback and deletes the temporary file.
    func unload() {
        player?.stop()
        player = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    func setPosition(_ seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), max(0, player.duration - 0.001))
    }

    func apply(_ command: PreviewAudioSync.Command) {
        guard let player else { return }
        switch command {
        case .none: break
        case .pause: player.pause()
        case .seek(let time): setPosition(time)
        case .start(let time):
            setPosition(time)
            player.play()
        }
    }

    func pause() { player?.pause() }
}

/// Builds the preview's audio file off the main actor.
enum PreviewAudioFile {
    /// Renders the export mix for `edit` into a temporary CAF and returns its URL, or nil when the
    /// recording and edit have no audio. Throws `CancellationError` (and leaves no file) when cancelled.
    nonisolated static func build(session: RecordingSession, directory: URL, settings: ExportSettings,
                                  edit: ExportEdit) async throws -> URL? {
        guard let mix = try await ExportAudioPreparation.previewMix(session: session, directory: directory,
                                                                    settings: settings, edit: edit) else { return nil }
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-preview-audio-\(UUID().uuidString).caf", isDirectory: false)
        do {
            try AudioFileIO.write(mix, to: url)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }
}

/// Renders processed preview frames with the export's own `ExportFrameRenderer` (built by
/// `OfflineExporter.makeRenderer`), at a reduced size. An actor owns the stateful decoders, so every
/// frame request is serialized and runs off the main actor. Requests are PLAYBACK times, like the
/// exported movie; each is mapped to source time for the screen and camera frames.
///
/// Audio is not rendered here: `PreviewAudioPlayer` plays the export's mix (`ExportAudioPreparation.previewMix`)
/// beside the frames. Sources are seekable (`ExportFrameSource` reseeks on backward moves
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
        let image = renderer.image(source: source, at: sourceTime, camera: cameraFrame,
                                       beforeTime: renderer.previousSourceTime(forPlaybackTime: playback))
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
/// playback follows the wall clock, so a slow frame makes it skip ahead instead of lag. The audio (the
/// export's own mix) is rebuilt separately by `prepareAudio`, started and re-seeked with the playhead,
/// and corrected whenever it drifts from the video by more than `PreviewAudioSync.maxDrift`.
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
    /// True when the current edit has audio loaded for playback.
    private(set) var hasAudio = false
    private(set) var isPreparingAudio = false
    private(set) var audioError: String?
    /// Silences the preview only; the export is unaffected.
    var isAudioMuted = false { didSet { audioPlayer.isMuted = isAudioMuted } }
    @ObservationIgnored let audioPlayer = PreviewAudioPlayer()
    @ObservationIgnored private var audioGeneration = 0
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

    /// Builds the export's audio mix for `edit` and loads it for playback; latest wins (a newer call or
    /// cancelling this task abandons the build, and a superseded file is deleted). Playback is silent
    /// until the mix is ready, and a recording without audio stays silent exactly as before.
    func prepareAudio(session: RecordingSession, directory: URL, settings: ExportSettings, edit: ExportEdit) async {
        audioGeneration += 1
        let generation = audioGeneration
        audioPlayer.unload()
        hasAudio = false
        audioError = nil
        isPreparingAudio = true
        defer { if generation == audioGeneration { isPreparingAudio = false } }
        do {
            let url = try await PreviewAudioFile.build(session: session, directory: directory, settings: settings, edit: edit)
            guard let url else { return }
            guard !Task.isCancelled, generation == audioGeneration else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard audioPlayer.load(url) else {
                audioError = "the mixed audio could not be opened"
                return
            }
            hasAudio = true
            audioPlayer.setPosition(time)
            if isPlaying { syncAudio(to: time) }
        } catch is CancellationError {
        } catch {
            guard generation == audioGeneration else { return }
            audioError = error.localizedDescription
        }
    }

    /// Drops the loaded mix at once (an edit made it stale); `prepareAudio` loads the new one.
    func invalidateAudio() {
        audioGeneration += 1
        audioPlayer.unload()
        hasAudio = false
    }

    /// Applies the sync rules for the video playhead `playhead`.
    private func syncAudio(to playhead: Double) {
        audioPlayer.apply(PreviewAudioSync.command(
            playhead: playhead, audioPosition: audioPlayer.position, audioIsPlaying: audioPlayer.isPlaying,
            wantsPlayback: isPlaying, audioDuration: audioPlayer.duration))
    }

    /// Moves the playhead (pausing playback) and renders that frame.
    func scrub(to newTime: Double) {
        pause()
        time = min(max(0, newTime), duration)
        audioPlayer.setPosition(time)
        show(at: time)
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func pause() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
        audioPlayer.pause()
    }

    /// Cancels playback and queued frames, and releases the decoders.
    func stop() {
        pause()
        renderTask?.cancel()
        if let renderer { Task { await renderer.close() } }
        renderer = nil
        audioGeneration += 1
        audioPlayer.unload()
        hasAudio = false
        isPreparingAudio = false
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
        syncAudio(to: startTime)
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
                    syncAudio(to: target)
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                    isPlaying = false
                    audioPlayer.pause()
                    return
                }
                if target >= duration { isPlaying = false; audioPlayer.pause(); return }
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
/// play/pause and a mute switch. Audio is the export's own mix (trims, speed, per-segment gains, cleanup,
/// master volume/mutes, click sounds, background music), played in sync with the frames.
struct EditorPreview: View {
    let editor: EditorModel
    let settings: ExportSettings
    let showsClickEffects: Bool
    /// Owned by the editor, which reads the playhead for "add at playhead" actions.
    let model: EditorPreviewModel

    /// Everything that changes the picture; audio settings are not part of it. `webcam` carries the layout
    /// options and the layout changes, so editing either rebuilds the preview.
    private struct Key: Equatable {
        var timeline: TimelineModel
        var stage: StageStyle
        var stageEnabled: Bool
        var captions: CaptionTrack
        var captionConfiguration: CaptionConfiguration
        var webcam: WebcamConfiguration
        var shortcuts: ShortcutOverlayConfiguration
        var motionBlurAmount: Double
        var settings: ExportSettings
        var showsClickEffects: Bool
        var clickEffect: ClickEffectConfiguration
        var masks: MaskConfiguration
        var zoomItems: ZoomItemConfiguration
    }

    /// Everything that changes the sound: the edit plan and the audio mix. Picture-only settings do not.
    private struct AudioKey: Equatable {
        var timeline: TimelineModel
        var audio: AudioMixConfiguration
    }

    private var audioKey: AudioKey { AudioKey(timeline: editor.state.timeline, audio: editor.state.audio) }

    private var key: Key {
        Key(timeline: editor.state.timeline, stage: editor.state.stage, stageEnabled: editor.state.stageEnabled,
            captions: editor.state.captions, captionConfiguration: editor.state.captionConfiguration,
            webcam: editor.state.webcam, shortcuts: editor.state.shortcuts,
            motionBlurAmount: editor.state.motionBlurAmount, settings: settings, showsClickEffects: showsClickEffects,
            clickEffect: editor.state.clickEffect, masks: editor.state.masks, zoomItems: editor.state.zoomItems)
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
                Toggle(isOn: Binding(get: { model.isAudioMuted }, set: { model.isAudioMuted = $0 })) {
                    Image(systemName: model.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .toggleStyle(.button)
                .help(model.hasAudio ? "Mute preview audio (the export is unaffected)" : "This edit has no audio")
                .disabled(!model.hasAudio)
                Slider(value: Binding(get: { model.time }, set: { model.scrub(to: $0) }),
                       in: 0...max(model.duration, 0.001))
                    .disabled(model.duration <= 0)
                Text("\(Self.format(model.time)) / \(Self.format(model.duration))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text("Preview unavailable: \(error)").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = model.audioError {
                Text("Preview audio unavailable: \(error)").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.isPreparingAudio
                     ? "Preview renders with the export renderer at reduced size. Mixing audio\u{2026}"
                     : "Preview renders with the export renderer at reduced size; audio is the export mix.")
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
        .onChange(of: audioKey) { model.invalidateAudio() }
        .task(id: audioKey) {
            // Mixing decodes every audio track, so wait out slider drags a little longer than the picture does.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.prepareAudio(session: editor.session, directory: editor.directory, settings: settings,
                                     edit: editor.exportEdit)
        }
        .onDisappear { model.stop() }
    }

    private static func format(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return "\(tenths / 600):\(String(format: "%02d", tenths / 10 % 60)).\(tenths % 10)"
    }
}
