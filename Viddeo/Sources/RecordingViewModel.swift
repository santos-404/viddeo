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

@MainActor
@Observable
final class RecordingViewModel {
    enum Phase { case idle, starting, recording, stopping, exporting }
    private(set) var displays: [DisplayOption] = []
    var selectedDisplayID: UInt32?
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    private(set) var status = "Choose a display to prepare a recording."
    private(set) var phase = Phase.idle
    private(set) var session: RecordingSession?
    private(set) var sessionDirectory: URL?
    private(set) var operationError: String?
    private(set) var exportedURL: URL?
    @ObservationIgnored private var captureDisplays: [UInt32: SCDisplay] = [:]
    @ObservationIgnored private let recorder = ScreenRecorder()
    @ObservationIgnored private let exporter = OfflineExporter()
    @ObservationIgnored private var operation: Task<Void, Never>?

    var canStart: Bool { phase == .idle && selectedDisplayID != nil && !isRefreshing }
    var canStop: Bool { phase == .recording }
    var canExport: Bool { phase == .idle && session != nil }
    var isBusy: Bool { phase != .idle }

    init() {
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
            selectedDisplayID = nil
            refreshError = "Viddeo could not access shareable screen content. Allow Screen Recording in System Settings > Privacy & Security > Screen Recording, then quit and reopen Viddeo. (\(error.localizedDescription))"
            status = "Screen access needs attention."
        }
    }

    func startRecording() {
        guard canStart, let selectedDisplayID, let display = captureDisplays[selectedDisplayID] else { return }
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
                try await recorder.start(display: display, directory: directory)
                guard phase == .starting else { return }
                activeDirectory = directory
                phase = .recording
                status = "Recording display \(selectedDisplayID). Click around, then press Stop."
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
                phase = .idle
                status = "Recorded \(completed.duration.formatted(.number.precision(.fractionLength(1)))) seconds. Ready to export."
                operationError = completed.eventCaptureAvailable ? nil
                    : "Pointer monitoring was unavailable or interrupted. Allow Viddeo in System Settings > Privacy & Security > Input Monitoring and record again to enable automatic zoom. Raw video is available."
            } catch {
                phase = .idle
                operationError = error.localizedDescription
                status = "Could not finish recording."
            }
            activeDirectory = nil
        }
    }

    func exportRecording() {
        guard canExport, let session, let directory = sessionDirectory else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "viddeo-\(session.id.uuidString.prefix(8)).mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        phase = .exporting
        operationError = nil
        status = "Rendering automatic zooms…"
        operation = Task {
            do {
                try await exporter.export(session: session, directory: directory, destination: destination)
                exportedURL = destination
                status = "Export saved to \(destination.lastPathComponent)."
            } catch {
                operationError = error.localizedDescription
                status = "Export failed. Raw recording is still available."
            }
            phase = .idle
        }
    }

    @ObservationIgnored private var activeDirectory: URL?

    func loadSession() {
        guard phase == .idle else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Viddeo session.json to export a saved recording."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let directory = url.deletingLastPathComponent()
            let loaded = try RecordingSession.load(from: directory)
            session = loaded
            sessionDirectory = directory
            exportedURL = nil
            operationError = loaded.eventCaptureAvailable ? nil : "This session has incomplete pointer events; raw video remains available."
            status = "Loaded session \(loaded.id.uuidString.prefix(8)). Ready to export."
        } catch {
            operationError = error.localizedDescription
        }
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
    func finishBeforeQuit() async {
        await operation?.value
        if canStop { stopRecording(); await operation?.value }
    }
}
