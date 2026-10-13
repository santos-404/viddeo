import Foundation

struct Failure: Error, CustomStringConvertible {
    var description: String
}

@main
struct VerifyTimeline {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            checks += 1
            guard condition else { throw Failure(description: "FAILED: \(message)") }
        }
        func expectError<E: Error & Equatable>(_ expected: E, _ message: String, _ body: () throws -> Void) throws {
            do {
                try body()
                try expect(false, "\(message) (no error thrown)")
            } catch let error as E {
                try expect(error == expected, "\(message) (got \(error))")
            }
        }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
            guard let a else { return false }
            return abs(a - b) <= tolerance
        }

        // Default model
        var model = TimelineModel(sourceDuration: 10)
        try model.validate()
        try expect(model.segments.count == 1, "default has one segment")
        let first = model.segments[0]
        try expect(first.sourceStart == 0 && first.sourceEnd == 10, "default covers the recording")
        try expect(first.timeScale == 1 && first.volume == 1 && first.systemVolume == 1 && !first.hideCursor, "default properties")
        try expect(model.playbackDuration == 10 && first.speed == 1, "default playback duration")

        // Split at playback, inheritance and insertion
        try model.setVolume(segmentID: first.id, to: 0.5)
        try model.setSystemVolume(segmentID: first.id, to: 0.25)
        try model.setHideCursor(segmentID: first.id, to: true)
        let splitID = try model.split(atPlayback: 4)
        try expect(model.segments.count == 2, "split creates a second segment")
        try expect(model.segments[0].id == first.id && model.segments[1].id == splitID && splitID != first.id, "original keeps id, new segment inserted after")
        try expect(model.segments[0].sourceEnd == 4 && model.segments[1].sourceStart == 4 && model.segments[1].sourceEnd == 10, "split ranges")
        try expect(model.segments[1].volume == 0.5 && model.segments[1].systemVolume == 0.25 && model.segments[1].hideCursor, "split inherits properties")
        try expect(model.playbackDuration == 10, "split keeps playback duration")

        // Split rejections
        var before = model
        try expectError(TimelineError.invalidSplitPoint, "split with first half < 0.1 s") { try model.split(atPlayback: 0.05) }
        try expectError(TimelineError.invalidSplitPoint, "split with second half < 0.1 s") { try model.split(atSource: 9.95) }
        try expectError(TimelineError.invalidSplitPoint, "split exactly 0.05 after boundary") { try model.split(atSource: 4.05) }
        try expectError(TimelineError.invalidSplitPoint, "split at playback end") { try model.split(atPlayback: 10) }
        try expectError(TimelineError.invalidSplitPoint, "split at NaN") { try model.split(atPlayback: .nan) }
        try expect(model == before, "failed splits leave the model unchanged")
        let sourceSplit = try model.split(atSource: 7)
        try expect(model.segments.map(\.sourceStart) == [0, 4, 7] && model.segments[2].id == sourceSplit, "split at source")
        try expect(model.segments[0].sourceEnd == 4 && model.segments[1].sourceEnd == 7, "split at source ranges")
        let exactlyMinimum = try model.split(atSource: 7.1)
        try expect(model.segments[2].sourceDuration >= 0.1 - 1e-9, "a half of exactly 0.1 s is allowed")
        try model.delete(segmentID: exactlyMinimum, closeGap: true)
        try expect(model.segments.count == 3 && model.segments[2].sourceEnd == 10, "closeGap restores the deleted range")
        try expectError(TimelineError.invalidSplitPoint, "split in trimmed footage") {
            var gap = TimelineModel(sourceDuration: 10)
            try gap.trim(segmentID: gap.segments[0].id, newStart: 2, newEnd: 10)
            try gap.split(atSource: 1)
        }

        // Trim
        model = TimelineModel(sourceDuration: 10)
        let a = model.segments[0].id
        let b = try model.split(atSource: 4)
        try model.trim(segmentID: b, newStart: 5, newEnd: 12)
        try expect(model.segments[1].sourceStart == 5 && model.segments[1].sourceEnd == 10, "trim clamps to recording end")
        try model.trim(segmentID: a, newStart: -1, newEnd: 6)
        try expect(model.segments[0].sourceStart == 0 && model.segments[0].sourceEnd == 5, "trim clamps to 0 and to the source neighbor")
        before = model
        try expectError(TimelineError.overlappingSegments, "trim entirely past the neighbor") { try model.trim(segmentID: a, newStart: 6, newEnd: 8) }
        try expectError(TimelineError.belowMinimumDuration, "trim below 0.1 s") { try model.trim(segmentID: b, newStart: 9.95, newEnd: 10) }
        try expectError(TimelineError.belowMinimumDuration, "inverted trim") { try model.trim(segmentID: b, newStart: 8, newEnd: 7) }
        try expectError(TimelineError.nonFiniteValue, "non-finite trim") { try model.trim(segmentID: b, newStart: .infinity, newEnd: 7) }
        try expectError(TimelineError.segmentNotFound, "trim unknown segment") { try model.trim(segmentID: UUID(), newStart: 1, newEnd: 2) }
        try expect(model == before, "failed trims leave the model unchanged")

        // Delete
        var single = TimelineModel(sourceDuration: 10)
        try expectError(TimelineError.lastSegment, "last segment is protected") { try single.delete(segmentID: single.segments[0].id) }
        try expect(single.segments.count == 1, "last segment still present")
        var three = TimelineModel(sourceDuration: 10)
        let t1 = three.segments[0].id
        let t2 = try three.split(atSource: 3)
        let t3 = try three.split(atSource: 6)
        var open = three
        try open.delete(segmentID: t2)
        try expect(open.segments.map(\.id) == [t1, t3] && open.playbackDuration == 7, "delete without closeGap leaves a source gap")
        try expect(open.playbackTime(forSourceTime: 4) == nil, "deleted source time is trimmed out")
        var closed = three
        try closed.delete(segmentID: t2, closeGap: true)
        try expect(closed.segments[0].sourceEnd == 6 && closed.playbackDuration == 10, "closeGap extends the previous neighbor")

        // Merge
        var merged = three
        try merged.merge(segmentID: t1, with: .next)
        try expect(merged.segments.count == 2 && merged.segments[0].id == t1, "merge next keeps the target")
        try expect(merged.segments[0].sourceStart == 0 && merged.segments[0].sourceEnd == 6, "merge next absorbs the range")
        merged = three
        try merged.merge(segmentID: t3, with: .previous)
        try expect(merged.segments.map(\.id) == [t1, t3] && merged.segments[1].sourceStart == 3 && merged.segments[1].sourceEnd == 10, "merge previous")
        try expectError(TimelineError.noNeighbor, "merge before the first segment") { try merged.merge(segmentID: t1, with: .previous) }
        var crossing = three
        try crossing.move(segmentID: t3, toIndex: 1)
        before = crossing
        try expectError(TimelineError.overlappingSegments, "merge that would swallow a third segment") { try crossing.merge(segmentID: t1, with: .next) }
        try expect(crossing == before, "failed merge leaves the model unchanged")

        // removeTrim
        var trimmed = open
        try trimmed.trim(segmentID: t1, newStart: 1, newEnd: 2)
        try trimmed.trim(segmentID: t3, newStart: 7, newEnd: 9)
        var restored = trimmed
        try restored.removeTrim(segmentID: t1, edge: .start)
        try expect(restored.segments[0].sourceStart == 0 && restored.segments[0].sourceEnd == 2, "removeTrim start goes to source start")
        try restored.removeTrim(segmentID: t1, edge: .end)
        try expect(restored.segments[0].sourceEnd == 7, "removeTrim end goes to the neighbor's start")
        restored = trimmed
        try restored.removeTrim(segmentID: t3, edge: .both)
        try expect(restored.segments[1].sourceStart == 2 && restored.segments[1].sourceEnd == 10, "removeTrim both")

        // Reorder and mappings: A[0,2] B[3,5]×2 C[6,10], played C, A, B
        var ordered = TimelineModel(sourceDuration: 10)
        let segA = ordered.segments[0].id
        let gap1 = try ordered.split(atSource: 2)
        let segB = try ordered.split(atSource: 3)
        let gap2 = try ordered.split(atSource: 5)
        let segC = try ordered.split(atSource: 6)
        try ordered.delete(segmentID: gap1)
        try ordered.delete(segmentID: gap2)
        try expect(ordered.playbackDuration == 8, "two gaps removed")
        try ordered.setTimeScale(segmentID: segB, to: 2)
        try expect(ordered.playbackDuration == 10, "timeScale 2 doubles B")
        try ordered.move(segmentID: segC, toIndex: 0)
        try expect(ordered.segments.map(\.id) == [segC, segA, segB], "move reorders")
        try expectError(TimelineError.invalidIndex, "move out of range") { try ordered.move(segmentID: segC, toIndex: 3) }
        try expect(near(ordered.playbackTime(forSourceTime: 7), 1), "C maps first")
        try expect(near(ordered.playbackTime(forSourceTime: 0), 4), "A starts after C")
        try expect(near(ordered.playbackTime(forSourceTime: 4), 8), "B at half speed")
        try expect(ordered.playbackTime(forSourceTime: 2.5) == nil, "trimmed-out time is nil")
        try expect(ordered.playbackTime(forSourceTime: 11) == nil && ordered.playbackTime(forSourceTime: .nan) == nil, "outside recording is nil")
        try expect(near(ordered.playbackTime(forSourceTime: 10), 4), "exact segment end maps to its playback end")
        try expect(near(ordered.playbackTime(forSourceTime: 2), 6), "A's exact end")
        try expect(near(ordered.sourceTime(forPlaybackTime: 4), 0), "playback boundary belongs to the next segment")
        try expect(near(ordered.sourceTime(forPlaybackTime: -5), 6) && near(ordered.sourceTime(forPlaybackTime: 100), 5), "sourceTime clamps")
        try expect(ordered.segmentIndex(atPlayback: 5) == 1 && ordered.segmentIndex(atPlayback: 10) == 2 && ordered.segmentIndex(atPlayback: 10.5) == nil, "segmentIndex")
        var roundTrips = 0
        for k in 0...997 {
            let playback = ordered.playbackDuration * Double(k) / 997
            let source = ordered.sourceTime(forPlaybackTime: playback)
            guard near(ordered.playbackTime(forSourceTime: source), playback) else {
                throw Failure(description: "FAILED: playback round trip at \(playback)")
            }
            roundTrips += 1
        }
        try expect(roundTrips == 998, "playback→source→playback round trip")
        roundTrips = 0
        for k in 0...1000 {
            let source = 10 * Double(k) / 1000
            // Kept times are half-open: a segment's exact end can share its playback time with
            // the start of the next played segment, which is a different source time.
            guard ordered.segments.contains(where: { source >= $0.sourceStart && source < $0.sourceEnd }) else {
                try expect(ordered.playbackTime(forSourceTime: source) == nil || ordered.segments.contains { $0.sourceEnd == source },
                           "only kept times or segment ends map at \(source)")
                continue
            }
            guard let playback = ordered.playbackTime(forSourceTime: source) else {
                throw Failure(description: "FAILED: kept source \(source) did not map")
            }
            guard near(ordered.sourceTime(forPlaybackTime: playback), source) else {
                throw Failure(description: "FAILED: source round trip at \(source)")
            }
            roundTrips += 1
        }
        try expect(roundTrips == 800, "source→playback→source round trip over kept times")
        let ranges = ordered.playbackRange(forSourceRange: 1...7)
        try expect(ranges.count == 3, "source range over three segments maps to three ranges")
        try expect(ranges.count == 3 && near(ranges[0].lowerBound, 0) && near(ranges[0].upperBound, 1)
                   && near(ranges[1].lowerBound, 5) && near(ranges[1].upperBound, 6)
                   && near(ranges[2].lowerBound, 6) && near(ranges[2].upperBound, 10), "mapped range values")
        try expect(ordered.playbackRange(forSourceRange: 2.2...2.8).isEmpty, "trimmed range maps to nothing")
        let plan = ordered.editPlan
        try expect(plan.map(\.segmentID) == [segC, segA, segB], "edit plan order")
        try expect(plan[0].sourceStart == 6 && plan[0].playbackStart == 0 && plan[0].playbackEnd == 4, "edit plan first item")
        try expect(plan[2].timeScale == 2 && plan[2].playbackStart == 6 && plan[2].playbackEnd == 10, "edit plan scaled item")
        try expect(plan.last?.playbackEnd == ordered.playbackDuration, "edit plan covers playback")
        let events = [
            CursorEvent(time: 0.5, x: 0.1, y: 0.1, kind: .down),
            CursorEvent(time: 2.5, x: 0.2, y: 0.2, kind: .move),
            CursorEvent(time: 6.5, x: 0.3, y: 0.3, kind: .move),
            CursorEvent(time: 4, x: 0.4, y: 0.4, kind: .up),
            CursorEvent(time: 11, x: 0.5, y: 0.5, kind: .move),
        ]
        let mapped = ordered.mapEvents(events)
        try expect(mapped.map(\.time) == [0.5, 4.5, 8], "mapEvents drops trimmed events and sorts by playback time")
        try expect(mapped.map(\.kind) == [.move, .down, .up] && mapped[0].x == 0.3, "mapEvents keeps event data")

        // Speed
        var speed = TimelineModel(sourceDuration: 10)
        let speedID = try speed.split(atSource: 6)
        try speed.setTimeScale(segmentID: speedID, to: 0.5)
        try expect(speed.segments[1].speed == 2 && speed.playbackDuration == 8, "timeScale 0.5 doubles speed")
        try expect(speed.playbackDuration == speed.segments.reduce(0) { $0 + $1.sourceDuration * $1.timeScale }, "playback = Σ source × scale")
        before = speed
        try expectError(TimelineError.invalidTimeScale, "timeScale below range") { try speed.setTimeScale(segmentID: speedID, to: 0.01) }
        try expectError(TimelineError.invalidTimeScale, "timeScale above range") { try speed.setTimeScale(segmentID: speedID, to: 11) }
        try expectError(TimelineError.invalidVolume, "negative volume") { try speed.setVolume(segmentID: speedID, to: -1) }
        try expectError(TimelineError.nonFiniteValue, "NaN volume") { try speed.setSystemVolume(segmentID: speedID, to: .nan) }
        try expect(speed == before, "failed property edits leave the model unchanged")

        // validate()
        func invalid(_ segments: [TimelineSegment], duration: Double = 10) -> TimelineModel {
            TimelineModel(sourceDuration: duration, segments: segments)
        }
        try expectError(TimelineError.empty, "validate empty") { try invalid([]).validate() }
        try expectError(TimelineError.nonFiniteValue, "validate NaN") { try invalid([.init(sourceStart: .nan, sourceEnd: 1)]).validate() }
        try expectError(TimelineError.nonFiniteValue, "validate infinite duration") { try invalid([.init(sourceStart: 0, sourceEnd: 1)], duration: .infinity).validate() }
        try expectError(TimelineError.outOfBounds, "validate past end") { try invalid([.init(sourceStart: 0, sourceEnd: 11)]).validate() }
        try expectError(TimelineError.outOfBounds, "validate before start") { try invalid([.init(sourceStart: -1, sourceEnd: 1)]).validate() }
        try expectError(TimelineError.belowMinimumDuration, "validate short segment") { try invalid([.init(sourceStart: 0, sourceEnd: 0.05)]).validate() }
        try expectError(TimelineError.invalidTimeScale, "validate timeScale") { try invalid([.init(sourceStart: 0, sourceEnd: 1, timeScale: 20)]).validate() }
        try expectError(TimelineError.overlappingSegments, "validate overlap") {
            try invalid([.init(sourceStart: 0, sourceEnd: 5), .init(sourceStart: 4, sourceEnd: 10)]).validate()
        }
        let duplicate = UUID()
        try expectError(TimelineError.duplicateSegmentID, "validate duplicate ids") {
            try invalid([.init(id: duplicate, sourceStart: 0, sourceEnd: 1), .init(id: duplicate, sourceStart: 2, sourceEnd: 3)]).validate()
        }
        try expectError(TimelineError.belowMinimumDuration, "too-short recording") { try TimelineModel(sourceDuration: 0.05).validate() }
        let encoded = try JSONEncoder().encode(ordered)
        try expect(try JSONDecoder().decode(TimelineModel.self, from: encoded) == ordered, "timeline JSON roundtrip")

        // EditHistory
        var history = EditHistory(initial: 0)
        try expect(!history.canUndo && !history.canRedo && history.state == 0, "empty history")
        history.record(1, at: 0)
        history.record(2, at: 0.01)
        try expect(history.undoDepth == 2, "uncoalesced edits are separate steps")
        try expect(history.undo() == 1 && history.undo() == 0 && history.undo() == nil, "undo walks back")
        try expect(history.redo() == 1 && history.redoDepth == 1, "redo walks forward")
        history.record(5, at: 1)
        try expect(history.state == 5 && !history.canRedo && history.undoDepth == 2, "new edit truncates the redo tail")
        try expect(history.redo() == nil, "no redo after truncation")
        history.record(5, at: 2)
        try expect(history.undoDepth == 2, "equal state is a no-op")
        history.record(6, coalescingKey: "drag", at: 3)
        history.record(7, coalescingKey: "drag", at: 3.05)
        history.record(8, coalescingKey: "drag", at: 3.12)
        try expect(history.undoDepth == 3 && history.state == 8, "edits inside the window merge into one step")
        try expect(history.undo() == 5, "one undo reverts the whole gesture")
        try expect(history.redo() == 8, "redo restores the whole gesture")
        history.record(9, coalescingKey: "drag", at: 3.3)
        try expect(history.undoDepth == 4, "edit outside the window is a new step")
        history.record(10, coalescingKey: "volume", at: 3.32)
        try expect(history.undoDepth == 5, "different key is a new step")
        history.record(11, at: 3.33)
        history.record(12, at: 3.34)
        try expect(history.undoDepth == 7, "nil key never coalesces")
        history.undo()
        history.record(13, coalescingKey: nil, at: 3.35)
        try expect(history.state == 13 && history.redoDepth == 0 && history.undoDepth == 7, "edit after undo replaces the tail")
        var gesture = EditHistory(initial: 0)
        gesture.record(1, coalescingKey: "k", at: 0)
        gesture.record(0, coalescingKey: "k", at: 0.05)
        try expect(gesture.undoDepth == 0 && gesture.state == 0, "gesture back to start leaves no step")
        var capped = EditHistory(initial: 0, limit: 5)
        for value in 1...8 { capped.record(value, at: Double(value)) }
        try expect(capped.undoDepth == 5 && capped.state == 8, "history is capped at the limit")
        while capped.undo() != nil {}
        try expect(capped.state == 3, "the oldest steps were dropped")
        var timelineHistory = EditHistory(initial: TimelineModel(sourceDuration: 10))
        var edited = timelineHistory.state
        try edited.split(atPlayback: 5)
        timelineHistory.record(edited, at: 0)
        try expect(timelineHistory.undo()?.segments.count == 1, "history works with timeline snapshots")

        // Project
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-timeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Recording 1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: 1920, height: 1080,
                                       duration: 10, events: [], droppedFrames: 0, eventCaptureAvailable: true)
        try session.save(in: directory)
        var project = ViddeoProject.create(from: session, name: "Demo")
        try expect(project.version == 1 && project.name == "Demo" && project.lastSavedAt == nil && project.sessionID == session.id, "create")
        try expect(project.timeline == TimelineModel(sourceDuration: 10).withIDs(of: project.timeline), "create uses the default timeline")
        try project.save(to: directory)
        let projectURL = directory.appendingPathComponent("project.json")
        try expect(project.lastSavedAt != nil && FileManager.default.fileExists(atPath: projectURL.path), "save writes and stamps lastSavedAt")
        try expect(try ViddeoProject.load(from: directory) == project, "save/load roundtrip")
        let text = try String(contentsOf: projectURL, encoding: .utf8)
        try expect(text.contains("\n  \"createdAt\" : \"") && text.contains("Z\""), "pretty sorted ISO 8601 JSON")
        var updated = project.timeline
        try updated.split(atPlayback: 3)
        try project.apply(updated, now: Date().addingTimeInterval(5))
        try expect(project.updatedAt > project.createdAt, "apply updates updatedAt")
        try project.save(to: directory)
        let reloaded = try ViddeoProject.load(from: directory)
        try expect(reloaded == project && reloaded.timeline.segments.count == 2, "atomic overwrite roundtrip")
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("backup").path), "no backup for same version")
        var wrongDuration = project.timeline
        wrongDuration.sourceDuration = 20
        wrongDuration.segments = [TimelineSegment(sourceStart: 0, sourceEnd: 20)]
        try expectError(ProjectError.durationMismatch, "apply rejects another recording's timeline") { try project.apply(wrongDuration) }

        func rewrite(_ change: (inout [String: Any]) -> Void) throws -> Data {
            let data = try Data(contentsOf: projectURL)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(description: "not an object") }
            change(&object)
            let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: projectURL)
            return output
        }
        let oldData = try rewrite { $0["version"] = 0 }
        try expectError(ProjectError.invalidVersion, "version 0 rejected") { _ = try ViddeoProject.load(from: directory) }
        try project.save(to: directory)
        let backupURL = directory.appendingPathComponent("backup/migrations/0/project.json")
        try expect(try Data(contentsOf: backupURL) == oldData, "older file backed up before overwrite")
        try expect(try ViddeoProject.load(from: directory).version == 1, "overwrite writes the current version")
        _ = try rewrite { $0.removeValue(forKey: "version") }
        try expectError(ProjectError.invalidVersion, "missing version rejected") { _ = try ViddeoProject.load(from: directory) }
        try project.save(to: directory)
        let futureData = try rewrite { $0["version"] = 2 }
        try expectError(ProjectError.unsupportedVersion(2), "future version rejected") { _ = try ViddeoProject.load(from: directory) }
        try expectError(ProjectError.unsupportedVersion(2), "future version never overwritten") { try project.save(to: directory) }
        try expect(try Data(contentsOf: projectURL) == futureData, "future file unchanged")
        try FileManager.default.removeItem(at: projectURL)
        try project.save(to: directory)
        var longer = session
        longer.duration = 10.5
        try expectError(ProjectError.durationMismatch, "session duration mismatch") { _ = try ViddeoProject.load(from: directory, session: longer) }
        longer.duration = 10.05
        try expect(try ViddeoProject.load(from: directory, session: longer) == project, "mismatch within 0.1 s accepted")
        var other = session
        other.id = UUID()
        try expectError(ProjectError.sessionMismatch, "other session rejected") { _ = try ViddeoProject.load(from: directory, session: other) }
        _ = try rewrite { object in
            if var timeline = object["timeline"] as? [String: Any] {
                timeline["segments"] = [] as [Any]
                object["timeline"] = timeline
            }
        }
        try expectError(TimelineError.empty, "load validates the timeline") { _ = try ViddeoProject.load(from: directory) }
        try Data("{not json".utf8).write(to: projectURL)
        try expectError(ProjectError.corrupt, "corrupt JSON") { _ = try ViddeoProject.load(from: directory) }
        try Data("{\"version\": 1, \"name\": 3}".utf8).write(to: projectURL)
        try expectError(ProjectError.corrupt, "wrong schema") { _ = try ViddeoProject.load(from: directory) }
        let empty = root.appendingPathComponent("Recording 2", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try expectError(ProjectError.notFound, "missing project") { _ = try ViddeoProject.load(from: empty) }
        let created = try ViddeoProject.loadOrCreate(for: session, in: empty)
        try expect(created.name == "Recording 2" && created.lastSavedAt != nil, "loadOrCreate creates and saves")
        try expect(try ViddeoProject.loadOrCreate(for: session, in: empty) == created, "loadOrCreate loads existing")
        try expectError(ProjectError.sessionUnreadable, "project without session.json") { _ = try ViddeoProject.load(from: empty) }
        try FileManager.default.removeItem(at: root)
        try expect(!FileManager.default.fileExists(atPath: root.path), "temp dir cleaned up")

        print("Timeline verified: \(checks) checks")
    }
}

extension TimelineModel {
    /// Copies segment ids so freshly generated default timelines can be compared.
    func withIDs(of other: TimelineModel) -> TimelineModel {
        var copy = self
        for index in copy.segments.indices where other.segments.indices.contains(index) {
            copy.segments[index].id = other.segments[index].id
        }
        return copy
    }
}
