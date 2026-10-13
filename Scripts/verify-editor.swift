import Foundation

@main
struct VerifyEditor {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-editor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: 640, height: 360,
                                       duration: 8, events: [], droppedFrames: 0, eventCaptureAvailable: true)
        try session.save(in: directory)
        let editor = try EditorModel(session: session, directory: directory)
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "VerifyEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        try check(editor.isDirty && !editor.state.stageEnabled && !editor.canUndo, "fresh project defaults")
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.json").path), "opening does not write")
        let original = editor.state
        editor.edit { try $0.timeline.split(atSource: 3) }
        try check(editor.state.timeline.segments.count == 2 && editor.canUndo, "split is undoable")
        let split = editor.state
        editor.edit { try $0.timeline.move(segmentID: $0.timeline.segments[1].id, toIndex: 0) }
        try check(editor.state.timeline.sourceTime(forPlaybackTime: 1) == 4, "unsaved reorder maps export")
        try check(editor.exportEdit.timeline == editor.state.timeline, "export consumes current unsaved timeline")
        editor.undo()
        try check(editor.state == split && editor.canRedo, "undo restores whole snapshot")
        editor.undo()
        try check(editor.state == original, "undo to original")
        editor.redo()
        try check(editor.state == split, "redo split")
        editor.edit { $0.stageEnabled = true; $0.stage.paddingRatio = 0.2 }
        try check(!editor.canRedo && editor.exportEdit.stage?.paddingRatio == 0.2, "branching edit drops redo and exports stage")
        let valid = editor.state
        editor.edit { $0.stage.paddingRatio = -1 }
        try check(editor.state == valid && editor.error != nil, "invalid edit rolls back")
        let cue = CaptionCue(startMs: 1000, endMs: 1800, text: "hello")
        editor.edit { $0.captions = CaptionTrack(locale: "en-US", cues: [cue]) }
        editor.edit { try $0.captions.updateText(cueID: cue.id, to: "corrected") }
        try check(editor.exportEdit.captions?.track.cues.first?.text == "corrected", "unsaved caption corrections exported")
        editor.undo()
        try check(editor.state.captions.cues.first?.text == "hello", "caption undo")
        editor.redo()
        editor.edit { $0.captionConfiguration.enabled = false }
        try check(editor.exportEdit.captions == nil, "caption toggle disables overlay")
        try check(editor.save(presetID: "custom-preset") && !editor.isDirty, "save clears dirty state")
        let reopened = try EditorModel(session: session, directory: directory)
        try check(reopened.state == editor.state && reopened.project.exportPresetID == "custom-preset", "all editor settings roundtrip")
        try check(!reopened.isDirty && !reopened.canUndo, "new history after reopening")
        reopened.edit { $0.stageEnabled = false }
        try check(reopened.save(presetID: "custom-preset"), "save disabled stage")
        try check(try ExportEdit.load(from: directory, session: session).stage == nil, "sidecar loader respects disabled stage")
        try check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stage-config.json").path), "disabled stage preserves style")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        reopened.edit { try $0.timeline.trim(segmentID: $0.timeline.segments[0].id, newStart: 1, newEnd: 3) }
        try check(reopened.save(presetID: "custom-preset"), "trim saved")
        try check(try Data(contentsOf: directory.appendingPathComponent("session.json")) == bytes, "editing never alters capture sidecar")
        // Refuse damaged/newer project files instead of silently resetting edits.
        try Data("{\"version\":99}".utf8).write(to: directory.appendingPathComponent("project.json"))
        do {
            _ = try EditorModel(session: session, directory: directory)
            throw NSError(domain: "VerifyEditor", code: 2)
        } catch ProjectError.unsupportedVersion(99) { checks += 1 }
        print("Editor verified: \(checks) checks")
    }
}
