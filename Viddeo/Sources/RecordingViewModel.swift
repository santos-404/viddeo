import AppKit
import Foundation
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers

struct DisplayOption: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int

    var description: String { "\(name) — \(width) × \(height)" }
}

struct WindowOption: Identifiable, Equatable {
    let id: CGWindowID
    let appName: String
    let title: String
    var description: String { "\(appName) — \(title.isEmpty ? "Untitled Window" : title)" }
}

@MainActor
@Observable
final class RecordingViewModel {
    enum Phase { case idle, starting, recording, stopping, exporting }
    private(set) var displays: [DisplayOption] = []
    private(set) var windows: [WindowOption] = []
    var recordingSourceKind: RecordingSourceKind = .display
    var selectedWindowID: CGWindowID?
    var areaX = 0.0
    var areaY = 0.0
    var areaWidth = 800.0
    var areaHeight = 600.0
    var capturesSystemAudio = false
    var capturesMicrophone = false
    /// Master switch for click effects in export and preview, left on: the reference's "off" default is the
    /// new recording's `click-config.json` effect `none` (see `writeNewRecordingDefaults`), so choosing Circle or
    /// Ripple in the editor takes effect without also finding this toggle.
    var showsClickEffects = true
    var rendersCursor = true
    var capturesTypingTiming = false
    var capturesShortcuts = false
    var capturesWebcam = false
    var selectedDisplayID: UInt32?
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    private(set) var status = "Choose a display to prepare a recording."
    private(set) var phase = Phase.idle
    private(set) var session: RecordingSession?
    private(set) var sessionDirectory: URL?
    private(set) var operationError: String?
    private(set) var exportedURL: URL?
    private(set) var exportPhase = ExportPhase.idle
    private(set) var editor: EditorModel?
    private(set) var catalog = ExportPresetCatalog.builtIn
    var selectedPresetID: String {
        didSet { UserDefaults.standard.set(selectedPresetID, forKey: Self.presetDefaultsKey) }
    }
    @ObservationIgnored private static let presetDefaultsKey = "viddeo.exportPresetID"
    @ObservationIgnored private var captureDisplays: [UInt32: SCDisplay] = [:]
    @ObservationIgnored private var captureWindows: [CGWindowID: SCWindow] = [:]
    @ObservationIgnored private let recorder = ScreenRecorder()
    @ObservationIgnored private let exporter = OfflineExporter()
    @ObservationIgnored private var operation: Task<Void, Never>?

    var canStart: Bool {
        !isBusy && selectedDisplayID != nil && !isRefreshing &&
        (recordingSourceKind != .window || selectedWindowID != nil) &&
        (recordingSourceKind != .area || (areaWidth >= 2 && areaHeight >= 2 && areaX >= 0 && areaY >= 0))
    }
    var canStop: Bool { phase == .recording }
    var canExport: Bool { !isBusy && session != nil && editor != nil }
    var isBusy: Bool { phase != .idle || editor?.isWorking == true }
    var presets: [ExportPreset] { catalog.presets }

    var selectedPreset: ExportPreset {
        catalog.preset(id: selectedPresetID) ?? catalog.preset(id: catalog.defaultPresetID) ?? catalog.presets[0]
    }

    var presetSummary: String {
        let settings = selectedPreset.settings.normalized()
        let codec: String = switch settings.codec {
        case .h264: "H.264"
        case .h265: "HEVC"
        case .both: "H.264 + HEVC (2 files)"
        }
        var parts = [settings.format == .gif ? "GIF" : codec]
        if let session {
            let size = settings.outputSize(sourceWidth: session.width, sourceHeight: session.height)
            parts.append("\(size.width)×\(size.height)")
        } else {
            parts.append("\(settings.height)p")
        }
        parts.append("\(settings.fps) fps")
        parts.append(settings.quality.label)
        if settings.format == .mp4, let session {
            let size = settings.outputSize(sourceWidth: session.width, sourceHeight: session.height)
            let mbps = Double(settings.videoBitsPerSecond(width: size.width, height: size.height)) / 1_000_000
            parts.append("≈\(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        return parts.joined(separator: " · ")
    }

    init() {
        selectedPresetID = UserDefaults.standard.string(forKey: Self.presetDefaultsKey) ?? ExportPresetCatalog.builtIn.defaultPresetID
        if catalog.preset(id: selectedPresetID) == nil { selectedPresetID = catalog.defaultPresetID }
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.phase = .idle
            self.operationError = error.localizedDescription
            self.status = "Recording failed. The last completed session is still available."
        }
    }

    func refreshDisplays() async {
        guard !isRefreshing, phase == .idle else { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let refreshedDisplays = content.displays.map { display in
                DisplayOption(
                    id: display.displayID,
                    name: "Display \(display.displayID)",
                    width: display.width,
                    height: display.height
                )
            }
            displays = refreshedDisplays
            captureDisplays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            let windowOptions = content.windows.compactMap { window -> (WindowOption, SCWindow)? in
                guard window.isOnScreen, let app = window.owningApplication else { return nil }
                return (WindowOption(id: window.windowID, appName: app.applicationName,
                                     title: window.title ?? ""), window)
            }.sorted { $0.0.description.localizedCaseInsensitiveCompare($1.0.description) == .orderedAscending }
            windows = windowOptions.map(\.0)
            captureWindows = Dictionary(uniqueKeysWithValues: windowOptions.map { ($0.0.id, $0.1) })
            if let selectedWindowID, captureWindows[selectedWindowID] == nil { self.selectedWindowID = nil }
            if let selectedDisplayID, !refreshedDisplays.contains(where: { $0.id == selectedDisplayID }) {
                self.selectedDisplayID = nil
            }
            if self.selectedDisplayID == nil {
                self.selectedDisplayID = refreshedDisplays.first?.id
            }
            status = refreshedDisplays.isEmpty
                ? "No displays are currently available."
                : "Ready to record."
        } catch {
            displays = []
            captureDisplays = [:]
            windows = []
            captureWindows = [:]
            selectedDisplayID = nil
            refreshError = "Viddeo could not access shareable screen content. Allow Screen Recording in System Settings > Privacy & Security > Screen Recording, then quit and reopen Viddeo. (\(error.localizedDescription))"
            status = "Screen access needs attention."
        }
    }

    func startRecording() {
        guard canStart, let selectedDisplayID, let display = captureDisplays[selectedDisplayID] else { return }
        let window = recordingSourceKind == .window ? selectedWindowID.flatMap { captureWindows[$0] } : nil
        let captureDisplay = window.flatMap { window in
            captureDisplays.values.first { CGDisplayBounds($0.displayID).intersects(window.frame) }
        } ?? display
        let area = recordingSourceKind == .area ? CGRect(x: areaX, y: areaY, width: areaWidth, height: areaHeight) : nil
        guard preserveEdits() else { return }
        phase = .starting
        operationError = nil
        status = "Starting capture…"
        operation = Task {
            do {
                let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = root.appendingPathComponent("Viddeo/Recordings/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try ZoomConfiguration().save(in: directory)
                if rendersCursor { try CursorConfiguration().save(in: directory) }
                try await recorder.start(display: captureDisplay, window: window, areaRect: area, directory: directory,
                                         capturesSystemAudio: capturesSystemAudio,
                                         capturesMicrophone: capturesMicrophone,
                                         rendersCursor: rendersCursor, capturesKeystrokes: rendersCursor && capturesTypingTiming,
                                         capturesShortcuts: capturesShortcuts,
                                         capturesWebcam: capturesWebcam)
                guard phase == .starting else { return }
                activeDirectory = directory
                phase = .recording
                status = "Recording display \(selectedDisplayID). Click around, then press Stop."
                if let warning = recorder.webcamWarning {
                    operationError = "Recording without the camera: \(warning)"
                }
            } catch {
                phase = .idle
                operationError = error.localizedDescription
                status = "Could not start recording."
            }
        }
    }

    func stopRecording() {
        guard canStop, let directory = activeDirectory else { return }
        phase = .stopping
        status = "Finishing raw video and event sidecar…"
        operation = Task {
            do {
                let completed = try await recorder.stop()
                session = completed
                sessionDirectory = directory
                exportedURL = nil
                let defaultsError = writeNewRecordingDefaults(to: directory)
                let presetError = applyPresets(from: directory)
                let editorError = openEditor(session: completed, directory: directory)
                phase = .idle
                status = "Recorded \(completed.duration.formatted(.number.precision(.fractionLength(1)))) seconds. Ready to export."
                var warnings: [String] = []
                if !completed.eventCaptureAvailable {
                    warnings.append("Pointer monitoring was unavailable or interrupted. Allow Viddeo in System Settings > Privacy & Security > Input Monitoring and record again to enable automatic zoom and click effects. Raw video is available.")
                }
                if let audio = completed.audio {
                    if audio.systemAudioRequested && audio.systemAudioSamples == 0 {
                        warnings.append("No system audio samples were recorded. Check Screen & System Audio Recording access before recording again.")
                    }
                    if audio.microphoneRequested && audio.microphoneSamples == 0 {
                        warnings.append("No microphone samples were recorded. Check Microphone permission and your input device before recording again.")
                    }
                }
                if let webcamWarning = recorder.webcamWarning { warnings.append(webcamWarning) }
                if let defaultsError { warnings.append(defaultsError) }
                if let presetError { warnings.append(presetError) }
                if let editorError { warnings.append(editorError) }
                if completed.keystrokeCaptureAvailable == false {
                    warnings.append("Typing timing was unavailable or interrupted. Hide-while-typing needs Input Monitoring permission and a new recording.")
                }
                if completed.shortcutCaptureAvailable == false {
                    warnings.append("Keyboard shortcuts were unavailable or interrupted. Shortcut capture needs Input Monitoring permission and a new recording.")
                }
                operationError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            } catch {
                phase = .idle
                operationError = error.localizedDescription
                status = "Could not finish recording."
            }
            activeDirectory = nil
        }
    }

    func exportRecording(target: ExportTarget = .file) {
        guard canExport, let session, let directory = sessionDirectory, let editor else { return }
        let edit = editor.exportEdit
        let settings = selectedPreset.settings.normalized()
        let fileExtension = settings.format == .gif ? "gif" : "mp4"
        let destination: URL
        switch target {
        case .file:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [settings.format == .gif ? .gif : .mpeg4Movie]
            panel.nameFieldStringValue = ExportDestinationPolicy.defaultFileName(
                projectName: editor.project.name, date: Date(), format: fileExtension)
            if settings.format == .mp4 && settings.codec == .both {
                panel.message = "A second file with an -h265 suffix will be written next to the one you choose."
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        case .clipboard:
            destination = ExportDestinationPolicy.clipboardURL(date: Date(), format: fileExtension)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            } catch {
                operationError = error.localizedDescription
                status = "Could not prepare the clipboard export."
                return
            }
        }
        let outputs = settings.format == .gif ? [destination] : settings.outputURLs(for: destination).map(\.url)
        // File exports render into a staging folder and replace the chosen files only on success (the
        // save panel already confirmed any replacement); clipboard destinations are always new files.
        let staging = target == .file ? ExportDelivery.stagingDirectory(for: destination) : nil
        let renderDestination = staging?.appendingPathComponent(destination.lastPathComponent) ?? destination
        let rendered = settings.format == .gif ? [renderDestination] : settings.outputURLs(for: renderDestination).map(\.url)
        phase = .exporting
        exportPhase = .rendering
        operationError = nil
        status = "Rendering zooms, click effects and audio…"
        operation = Task {
            do {
                if let staging {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                }
                try await exporter.export(session: session, directory: directory, destination: renderDestination,
                                          showsClickEffects: showsClickEffects, settings: settings, edit: edit)
                if Task.isCancelled { throw CancellationError() }
                exportPhase = .delivering
                if let staging {
                    try ExportDelivery.commitStaged(Array(zip(rendered, outputs)).map { (staged: $0.0, final: $0.1) },
                                                    staging: staging)
                }
                exportedURL = destination
                let names = outputs.map(\.lastPathComponent).joined(separator: " and ")
                switch target {
                case .file:
                    status = "Export saved to \(names)."
                    revealExport()
                case .clipboard:
                    guard ExportDelivery.copyFileReferences(outputs, to: .general) else {
                        throw ExportDeliveryError.clipboardRejected
                    }
                    status = "Copied \(names) to the clipboard — paste it into any app that accepts files."
                }
                exportPhase = .completed
            } catch {
                ExportDelivery.removeIncompleteOutputs(staging.map { [$0] } ?? rendered)
                if error is CancellationError || Task.isCancelled {
                    exportPhase = .cancelled
                    exportedURL = nil
                    status = "Export cancelled."
                } else {
                    exportPhase = .failed
                    exportedURL = nil
                    operationError = error.localizedDescription
                    status = "Export failed. Raw recording is still available."
                }
            }
            phase = .idle
        }
    }

    /// Cancels a running export; incomplete outputs are removed once the render stops.
    func cancelExport() {
        guard phase == .exporting else { return }
        status = "Cancelling export…"
        operation?.cancel()
    }

    @ObservationIgnored private var activeDirectory: URL?

    func loadSession() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Viddeo session.json to export a saved recording."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard preserveEdits() else { return }
        do {
            let directory = url.deletingLastPathComponent()
            let loaded = try RecordingSession.load(from: directory)
            let loadedEditor = try EditorModel(session: loaded, directory: directory)
            session = loaded
            editor = loadedEditor
            sessionDirectory = directory
            exportedURL = nil
            let presetError = applyPresets(from: directory)
            if let preset = loadedEditor.project.exportPresetID, catalog.preset(id: preset) != nil { selectedPresetID = preset }
            let eventWarning = loaded.eventCaptureAvailable ? nil : "This session has incomplete pointer events; raw video remains available."
            operationError = [eventWarning, presetError].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
            status = "Loaded session \(loaded.id.uuidString.prefix(8)). Ready to export."
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Gives a just-finished recording the reference's new-project defaults (stage on over viddeo's own
    /// wallpaper with padding 0.1 and radius 0, click effect off) by writing the sidecars the editor already
    /// reads. The files are the new-versus-legacy marker: only this path writes them before a project exists, so
    /// sessions recorded earlier (no sidecars, or a saved project) keep their behaviour. Nothing is overwritten.
    private func writeNewRecordingDefaults(to directory: URL) -> String? {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.appendingPathComponent(ViddeoProject.filename).path) else { return nil }
        do {
            if !manager.fileExists(atPath: directory.appendingPathComponent("stage-config.json").path) {
                try StageStyle.writeNewRecordingDefault(in: directory)
            }
            if !manager.fileExists(atPath: directory.appendingPathComponent("click-config.json").path) {
                try ClickEffectConfiguration.newRecordingDefault.save(in: directory)
            }
            return nil
        } catch {
            return "The recording was saved, but its default look could not be written: \(error.localizedDescription)"
        }
    }

    /// Loads the session's preset catalog, keeping the built-in one on failure; returns the error text if any.
    private func applyPresets(from directory: URL) -> String? {
        var failure: String?
        do {
            catalog = try ExportPresetCatalog.load(from: directory)
        } catch {
            catalog = .builtIn
            failure = error.localizedDescription
        }
        if catalog.preset(id: selectedPresetID) == nil { selectedPresetID = catalog.defaultPresetID }
        return failure
    }

    private func openEditor(session: RecordingSession, directory: URL) -> String? {
        do {
            editor = try EditorModel(session: session, directory: directory)
            return nil
        } catch {
            editor = nil
            return "The recording was saved, but its editor could not load: \(error.localizedDescription)"
        }
    }

    private func preserveEdits() -> Bool {
        guard let editor, editor.isDirty else { return true }
        guard editor.save(presetID: selectedPresetID) else {
            operationError = editor.error
            return false
        }
        return true
    }

    func revealSession() {
        guard let sessionDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
    }

    func revealExport() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Called by the application delegate to finalize a recording before quitting.
    func finishBeforeQuit() async -> Bool {
        await operation?.value
        if canStop { stopRecording(); await operation?.value }
        await editor?.finishOperation()
        return preserveEdits()
    }
}

private enum ExportDeliveryError: LocalizedError {
    case clipboardRejected
    var errorDescription: String? { "The export was rendered but could not be placed on the clipboard." }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
