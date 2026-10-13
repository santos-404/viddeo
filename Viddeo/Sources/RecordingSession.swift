import Foundation

/// All event times are seconds from the first encoded video frame.
/// Coordinates use the captured display's top-left origin, normalized to 0...1.
struct CursorEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case move, down, up }
    var time: Double
    var x: Double
    var y: Double
    var kind: Kind
}

struct RecordingSession: Codable, Sendable {
    var version = 1
    var id: UUID
    var createdAt: Date
    var displayID: UInt32
    var width: Int
    var height: Int
    var duration: Double
    var videoFilename = "raw.mp4"
    var events: [CursorEvent]
    var droppedFrames: Int
    var eventCaptureAvailable: Bool
    var audio: AudioCaptureMetadata? = nil

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    static func load(from directory: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }
}

/// Capture diagnostics for the optional, independently encoded AAC tracks in raw.mp4.
struct AudioCaptureMetadata: Codable, Sendable, Equatable {
    var systemAudioRequested: Bool
    var microphoneRequested: Bool
    var systemAudioSamples: Int
    var microphoneSamples: Int
    var systemAudioDroppedSamples: Int
    var microphoneDroppedSamples: Int
    var systemAudioTrackName = "System Audio"
    var microphoneTrackName = "Microphone"
}
