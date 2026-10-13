import Foundation

/// `project.json` beside `session.json`: the editable, versioned state of one recording.
struct ViddeoProject: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let filename = "project.json"

    var version: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var lastSavedAt: Date?
    var sessionID: UUID
    var timeline: TimelineModel
    var exportPresetID: String?
    /// Absent in older projects: enable a stage when its sidecar exists.
    var stageEnabled: Bool? = nil

    /// Dates are stored as whole-second ISO 8601, so in-memory values are truncated to match.
    static func create(from session: RecordingSession, name: String?, now: Date = Date()) -> Self {
        let date = timestamp(now)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(version: currentVersion, id: UUID(), name: trimmed.isEmpty ? "Untitled Recording" : trimmed,
                    createdAt: date, updatedAt: date, lastSavedAt: nil, sessionID: session.id,
                    timeline: TimelineModel(sourceDuration: session.duration), exportPresetID: nil)
    }

    /// Checks the project against `session`, or against `session.json` in the same folder.
    static func load(from directory: URL, session: RecordingSession? = nil) throws -> Self {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProjectError.notFound }
        let data = try Data(contentsOf: url)
        let probe: VersionProbe
        do { probe = try JSONDecoder().decode(VersionProbe.self, from: data) } catch { throw ProjectError.corrupt }
        guard let version = probe.version, version >= 1 else { throw ProjectError.invalidVersion }
        guard version <= currentVersion else { throw ProjectError.unsupportedVersion(version) }
        let project: Self
        do { project = try decoder().decode(Self.self, from: data) } catch { throw ProjectError.corrupt }
        try project.timeline.validate()
        let recording: RecordingSession
        if let session {
            recording = session
        } else {
            do { recording = try RecordingSession.load(from: directory) } catch { throw ProjectError.sessionUnreadable }
        }
        guard recording.id == project.sessionID else { throw ProjectError.sessionMismatch }
        guard abs(recording.duration - project.timeline.sourceDuration) <= TimelineModel.minSegmentDuration
        else { throw ProjectError.durationMismatch }
        return project
    }

    static func loadOrCreate(for session: RecordingSession, in directory: URL) throws -> Self {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            return try load(from: directory, session: session)
        }
        var project = create(from: session, name: directory.lastPathComponent)
        try project.save(to: directory)
        return project
    }

    /// Atomic write. An existing older-version file is first copied to
    /// `backup/migrations/<version>/project.json`, as the reference does; a newer one is never overwritten.
    mutating func save(to directory: URL, now: Date = Date()) throws {
        try timeline.validate()
        var saved = self
        saved.version = Self.currentVersion
        saved.lastSavedAt = Self.timestamp(now)
        let manager = FileManager.default
        let url = directory.appendingPathComponent(Self.filename)
        if manager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            let backup: URL?
            if let probe = try? JSONDecoder().decode(VersionProbe.self, from: existing) {
                let old = probe.version ?? 0
                guard old <= Self.currentVersion else { throw ProjectError.unsupportedVersion(old) }
                backup = old < Self.currentVersion
                    ? directory.appendingPathComponent("backup/migrations/\(old)", isDirectory: true) : nil
            } else {
                backup = directory.appendingPathComponent("backup/unreadable", isDirectory: true)
            }
            if let backup {
                try manager.createDirectory(at: backup, withIntermediateDirectories: true)
                try existing.write(to: backup.appendingPathComponent(Self.filename), options: .atomic)
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: url, options: .atomic)
        self = saved
    }

    mutating func apply(_ timeline: TimelineModel, now: Date = Date()) throws {
        try timeline.validate()
        guard abs(timeline.sourceDuration - self.timeline.sourceDuration) <= TimelineModel.minSegmentDuration
        else { throw ProjectError.durationMismatch }
        self.timeline = timeline
        updatedAt = Self.timestamp(now)
    }

    static func timestamp(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct VersionProbe: Decodable {
        var version: Int?
    }
}

enum ProjectError: LocalizedError, Equatable {
    case notFound
    case corrupt
    case invalidVersion
    case unsupportedVersion(Int)
    case sessionUnreadable
    case sessionMismatch
    case durationMismatch

    var errorDescription: String? {
        switch self {
        case .notFound: "The project file could not be found."
        case .corrupt: "The project file is damaged or not a viddeo project."
        case .invalidVersion: "The project file has no valid version."
        case .unsupportedVersion(let version): "This project was saved by a newer viddeo (format \(version)). Update viddeo to open it."
        case .sessionUnreadable: "The recording information for this project could not be read."
        case .sessionMismatch: "The project belongs to a different recording."
        case .durationMismatch: "The project timeline does not match the recording's duration."
        }
    }
}
