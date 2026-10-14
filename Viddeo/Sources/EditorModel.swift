import Foundation
import Observation

/// A single undo snapshot includes every setting edited by the basic editor.
struct EditorState: Sendable, Equatable {
    var timeline: TimelineModel
    var stage: StageStyle
    var stageEnabled: Bool
    var captions: CaptionTrack
    var captionConfiguration: CaptionConfiguration
    var audio: AudioMixConfiguration
    var webcam: WebcamConfiguration
}

@MainActor
@Observable
final class EditorModel {
    let session: RecordingSession
    let directory: URL
    private(set) var project: ViddeoProject
    private(set) var state: EditorState
    private(set) var error: String?
    private(set) var status = "Edits apply to export. Save Project to keep them."
    private(set) var isWorking = false
    private(set) var silence: [SilenceDetectionChunk] = []
    var selectedSegmentID: UUID?
    var localeIdentifier = "en-US"
    @ObservationIgnored private var history: EditHistory<EditorState>
    @ObservationIgnored private var savedState: EditorState
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: RecordingSession, directory: URL) throws {
        let manager = FileManager.default
        let project = manager.fileExists(atPath: directory.appendingPathComponent(ViddeoProject.filename).path)
            ? try ViddeoProject.load(from: directory, session: session)
            : ViddeoProject.create(from: session, name: directory.lastPathComponent)
        let state = EditorState(
            timeline: project.timeline, stage: try StageStyle.load(in: directory),
            stageEnabled: project.stageEnabled ?? manager.fileExists(atPath: directory.appendingPathComponent("stage-config.json").path),
            captions: try CaptionTrack.load(from: directory) ?? CaptionTrack(locale: "en-US", cues: []),
            captionConfiguration: try CaptionConfiguration.load(in: directory),
            audio: manager.fileExists(atPath: directory.appendingPathComponent("audio-config.json").path)
                ? try AudioMixConfiguration.load(in: directory) : .editorDefault,
            webcam: try WebcamConfiguration.load(in: directory))
        self.session = session
        self.directory = directory
        self.project = project
        self.state = state
        savedState = state
        history = EditHistory(initial: state)
        selectedSegmentID = state.timeline.segments.first?.id
        localeIdentifier = state.captions.locale
    }

    var isDirty: Bool { state != savedState || project.lastSavedAt == nil }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var selectedSegment: TimelineSegment? { state.timeline.segments.first { $0.id == selectedSegmentID } }
    var exportEdit: ExportEdit {
        ExportEdit(timeline: state.timeline, stage: state.stageEnabled ? state.stage : nil,
                   captions: state.captionConfiguration.enabled && !state.captions.cues.isEmpty
                    ? (state.captions, state.captionConfiguration) : nil,
                   audio: state.audio, webcam: session.webcam == nil ? nil : state.webcam)
    }

    /// Failed edits leave both state and history intact.
    func edit(_ change: (inout EditorState) throws -> Void, key: String? = nil) {
        guard !isWorking else { return }
        do {
            var candidate = state
            try change(&candidate)
            try candidate.timeline.validate()
            try candidate.stage.validate()
            try candidate.captions.validate()
            try candidate.captionConfiguration.validate()
            try candidate.audio.validate()
            try candidate.webcam.validate()
            history.record(candidate, coalescingKey: key, at: ProcessInfo.processInfo.systemUptime)
            state = candidate
            reconcileSelection()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func undo() {
        guard !isWorking, let previous = history.undo() else { return }
        state = previous
        reconcileSelection()
        error = nil
    }

    func redo() {
        guard !isWorking, let next = history.redo() else { return }
        state = next
        reconcileSelection()
        error = nil
    }

    @discardableResult
    func save(presetID: String) -> Bool {
        guard !isWorking else { return false }
        do {
            // Each sidecar is atomic. A failed multi-file save stays dirty and reports failure.
            var updated = project
            try updated.apply(state.timeline)
            updated.exportPresetID = presetID
            updated.stageEnabled = state.stageEnabled
            try state.stage.save(in: directory)
            try state.captions.save(to: directory)
            try state.captionConfiguration.save(in: directory)
            try state.audio.save(in: directory)
            if session.webcam != nil { try state.webcam.save(in: directory) }
            try updated.save(to: directory)
            project = updated
            savedState = state
            error = nil
            status = "Project saved."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Copies `url` into the session folder under a safe single-component name (never overwriting
    /// another file) and selects it as background music, as one undoable edit. The copy stays when the
    /// edit is undone, so redo and saved projects keep working.
    func setBackgroundMusic(from url: URL) {
        guard !isWorking else { return }
        do {
            let manager = FileManager.default
            var name = url.lastPathComponent.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\\", with: "-")
            while name.hasPrefix(".") || name.hasPrefix("~") { name.removeFirst() }
            name = String(name.unicodeScalars.filter { $0.properties.generalCategory != .control })
            if name.isEmpty { name = "music" }
            if !name.lowercased().hasPrefix("music-") { name = "music-" + name }
            guard AudioMixConfiguration.isSafeFileName(name) else { throw AudioProcessingError.invalidBackgroundAudioFileName }
            var destination = directory.appendingPathComponent(name, isDirectory: false)
            if destination.standardizedFileURL != url.standardizedFileURL {
                var counter = 2
                let base = destination.deletingPathExtension().lastPathComponent, ext = destination.pathExtension
                while manager.fileExists(atPath: destination.path) {
                    destination = directory.appendingPathComponent(ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)", isDirectory: false)
                    counter += 1
                }
                try manager.copyItem(at: url, to: destination)
            }
            let stored = destination.lastPathComponent
            edit { $0.audio.backgroundAudioFileName = stored }
        } catch { self.error = error.localizedDescription }
    }

    func removeBackgroundMusic() {
        edit { $0.audio.backgroundAudioFileName = nil }
    }

    func generateCaptions() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        status = "Preparing on-device captions…"
        let locale = Locale(identifier: localeIdentifier)
        task = Task {
            do {
                let audio = try await CaptionAudioExtractor().extractMicrophoneAudio(sessionDirectory: directory, session: session)
                defer { try? FileManager.default.removeItem(at: audio) }
                let cues = try await AppleSpeechCaptionProvider().transcribe(audioURL: audio, locale: locale, progress: { _ in })
                let track = CaptionTrack(locale: locale.identifier(.bcp47), cues: cues)
                // Merge with current unsaved corrections; generation never overwrites the sidecar.
                isWorking = false
                edit { $0.captions = $0.captions.merging(regenerated: track); $0.captionConfiguration.enabled = true }
                status = error == nil ? "Captions generated. Review them, then Save Project." : "Caption validation failed."
            } catch {
                self.error = error.localizedDescription
                status = "Caption generation failed."
            }
            isWorking = false
        }
    }

    func analyzeSilence() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        status = "Analyzing microphone silence…"
        task = Task {
            do {
                guard let audio = session.audio, audio.microphoneSamples > 0 else { throw CaptionError.noMicrophoneAudio }
                silence = try await SilenceDetector.detect(audioURL: directory.appendingPathComponent(session.videoFilename),
                                                           trackSelection: .microphone(title: audio.microphoneTrackName))
                status = "Found \(silence.count) silence ranges. Trim or speed them up, then review the export."
            } catch { self.error = error.localizedDescription }
            isWorking = false
        }
    }

    func applySilence(speedUp: Bool) {
        let chunks = silence
        edit {
            let report = try speedUp ? $0.timeline.speedUpSilence(chunks: chunks) : $0.timeline.trimSilence(chunks: chunks)
            status = "Edited \(report.affectedChunks) silence ranges; saved \(report.savedPlaybackSeconds.formatted(.number.precision(.fractionLength(1)))) playback seconds."
        }
    }

    func finishOperation() async { await task?.value }

    private func reconcileSelection() {
        if !state.timeline.segments.contains(where: { $0.id == selectedSegmentID }) {
            selectedSegmentID = state.timeline.segments.first?.id
        }
    }
}
