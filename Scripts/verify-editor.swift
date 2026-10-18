import CoreGraphics
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
        // Audio: the default is neutral (no export change); edits are undoable, validated, saved and exported.
        try check(reopened.state.audio.microphonePreset == .off && reopened.exportEdit.audio == nil, "audio defaults are export-neutral")
        reopened.edit { $0.audio.microphonePreset = .voice; $0.audio.muteSystemAudio = true }
        try check(reopened.exportEdit.audio?.microphonePreset == .voice && reopened.exportEdit.audio?.muteSystemAudio == true, "unsaved audio settings reach the export")
        let withAudio = reopened.state
        reopened.edit { $0.audio.volume = 9 }
        try check(reopened.state == withAudio && reopened.error != nil, "invalid audio volume rolls back")
        reopened.edit { $0.audio.clickSoundEffect = .softClick }
        reopened.undo()
        try check(reopened.state == withAudio, "audio undo")
        try check(reopened.save(presetID: "custom-preset"), "audio saved")
        try check(try AudioMixConfiguration.load(in: directory) == withAudio.audio, "audio-config.json roundtrip")
        try check(try ExportEdit.load(from: directory, session: session).audio == withAudio.audio, "sidecar loader reads audio")
        try check(try EditorModel(session: session, directory: directory).state.audio == withAudio.audio, "reopened editor keeps audio")
        // Background music and mixdown: the file is copied into the session under a safe name, edits are undoable and persisted.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-music-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let musicSource = outside.appendingPathComponent(".hidden: song?.wav")
        try Data("RIFF".utf8).write(to: musicSource)
        reopened.setBackgroundMusic(from: musicSource)
        let musicName = reopened.state.audio.backgroundAudioFileName
        try check(musicName.map(AudioMixConfiguration.isSafeFileName) == true && reopened.error == nil, "music gets a safe single-component name")
        try check(musicName.map { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } == true, "music is copied into the session folder")
        try check(reopened.exportEdit.audio?.backgroundAudioFileName == musicName && reopened.state.audio.backgroundAudioVolume == 0.05, "music reaches the export at volume 0.05")
        reopened.setBackgroundMusic(from: musicSource)
        try check(reopened.state.audio.backgroundAudioFileName != musicName, "a second import never overwrites the first copy")
        reopened.undo()
        try check(reopened.state.audio.backgroundAudioFileName == musicName, "music import is undoable")
        reopened.edit { $0.audio.backgroundAudioVolume = 0.3; $0.audio.muteBackgroundAudio = true; $0.audio.mixdownSingleTrack = true; $0.audio.targetLoudnessLUFS = -14 }
        let withMusic = reopened.state
        reopened.edit { $0.audio.backgroundAudioFileName = "../escape.wav" }
        try check(reopened.state == withMusic && reopened.error != nil, "unsafe music name rolls back")
        reopened.removeBackgroundMusic()
        try check(reopened.state.audio.backgroundAudioFileName == nil && reopened.exportEdit.audio?.mixdownSingleTrack == true, "music removed, mixdown kept")
        reopened.undo()
        try check(reopened.state == withMusic, "music removal is undoable")
        try check(reopened.save(presetID: "custom-preset"), "music settings saved")
        try check(try AudioMixConfiguration.load(in: directory) == withMusic.audio, "music and mixdown roundtrip through audio-config.json")
        try check(try EditorModel(session: session, directory: directory).state.audio == withMusic.audio, "reopened editor keeps music and mixdown")
        // Camera: sessions without one never export or save overlay settings; sessions with one do.
        try check(reopened.exportEdit.webcam == nil, "no camera, no overlay settings")
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("webcam-config.json").path), "no camera, no webcam-config.json")
        let cameraDirectory = directory.appendingPathComponent("with-camera", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDirectory, withIntermediateDirectories: true)
        var cameraSession = session
        cameraSession.webcam = WebcamCaptureMetadata(filename: "camera.mov", firstPTS: 0.25, duration: 7.5, width: 1280, height: 720,
                                                     droppedFrames: 0, deviceName: "Fixture", firstHostTime: 100)
        try cameraSession.save(in: cameraDirectory)
        let cameraEditor = try EditorModel(session: cameraSession, directory: cameraDirectory)
        try check(cameraEditor.exportEdit.webcam == WebcamConfiguration(), "camera session exports the default overlay")
        cameraEditor.edit { $0.webcam.hide = true; $0.webcam.position = WebcamAnchor.topLeft.point }
        try check(cameraEditor.exportEdit.webcam?.hide == true && cameraEditor.exportEdit.webcam?.anchor == .topLeft, "unsaved camera settings reach the export")
        let withCamera = cameraEditor.state
        cameraEditor.edit { $0.webcam.sizeRatio = 5 }
        try check(cameraEditor.state == withCamera && cameraEditor.error != nil, "invalid camera size rolls back")
        cameraEditor.undo()
        try check(cameraEditor.state.webcam == WebcamConfiguration(), "camera undo")
        cameraEditor.redo()
        try check(cameraEditor.save(presetID: "custom-preset"), "camera settings saved")
        try check(try WebcamConfiguration.load(in: cameraDirectory) == withCamera.webcam, "webcam-config.json roundtrip")
        try check(try ExportEdit.load(from: cameraDirectory, session: cameraSession).webcam == withCamera.webcam, "sidecar loader reads the camera settings")
        try check(try EditorModel(session: cameraSession, directory: cameraDirectory).state.webcam == withCamera.webcam, "reopened editor keeps the camera settings")
        // Layout changes: add at a time, set the layout, undo, reject overlaps and short items, persist.
        let layoutEditor = try EditorModel(session: cameraSession, directory: cameraDirectory)
        layoutEditor.edit { try $0.webcam.addLayoutItem(layout: .splitScreen, atMs: 1000, sourceDurationMs: cameraSession.duration * 1000) }
        try check(layoutEditor.state.webcam.layoutItems.count == 1 && layoutEditor.error == nil, "layout change added")
        try check(layoutEditor.exportEdit.webcam?.layout(atMs: 1500) == .splitScreen, "the layout change reaches the export")
        let itemID = layoutEditor.state.webcam.layoutItems[0].id
        layoutEditor.edit { $0.webcam.layoutItems[0].layout = .cutoutCamera }
        try check(layoutEditor.state.webcam.layoutItems[0].layout == .cutoutCamera, "layout change set")
        layoutEditor.edit { try $0.webcam.addLayoutItem(layout: .splitScreen, atMs: 1200, sourceDurationMs: 8000) }
        try check(layoutEditor.state.webcam.layoutItems.count == 1 && layoutEditor.error != nil, "an overlapping layout change is rejected")
        layoutEditor.edit { $0.webcam.layoutItems[0].endMs = $0.webcam.layoutItems[0].startMs + 100 }
        try check(layoutEditor.state.webcam.layoutItems[0].endMs > 1400 && layoutEditor.error != nil, "a layout change under 500 ms is rejected")
        layoutEditor.undo()
        try check(layoutEditor.state.webcam.layoutItems[0].layout == .splitScreen, "layout change undo")
        layoutEditor.redo()
        try check(layoutEditor.save(presetID: "custom-preset"), "layout changes saved")
        try check(try WebcamConfiguration.load(in: cameraDirectory).layoutItems.map(\.id) == [itemID], "webcam-config.json keeps the layout changes")
        let reloaded = try EditorModel(session: cameraSession, directory: cameraDirectory)
        try check(reloaded.state.webcam.layoutItems.first?.layout == .cutoutCamera, "reopened editor keeps the layout changes")
        reloaded.edit { $0.webcam.removeLayoutItem(id: itemID) }
        try check(reloaded.state.webcam.layoutItems.isEmpty, "layout change deleted")
        reloaded.undo()
        try check(reloaded.state.webcam.layoutItems.count == 1, "layout change delete undo")
        // Shortcuts: only sessions with captured presses get the tab, saved file and export overlay.
        try check(!reopened.hasShortcuts && reopened.exportEdit.shortcuts == nil, "no captured shortcuts, no overlay")
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("shortcuts-config.json").path), "no shortcuts, no shortcuts-config.json")
        let shortcutDirectory = directory.appendingPathComponent("with-shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: shortcutDirectory, withIntermediateDirectories: true)
        var shortcutSession = session
        shortcutSession.shortcuts = [ShortcutEvent(time: 1, keyCode: 8, key: "C", modifiers: .command),
                                     ShortcutEvent(time: 4, keyCode: 53, key: "escape", modifiers: [])]
        try shortcutSession.save(in: shortcutDirectory)
        let shortcutEditor = try EditorModel(session: shortcutSession, directory: shortcutDirectory)
        try check(shortcutEditor.hasShortcuts && shortcutEditor.state.shortcuts == ShortcutOverlayConfiguration() && shortcutEditor.exportEdit.shortcuts == nil,
                  "overlay is off by default")
        shortcutEditor.edit { $0.shortcuts.enabled = true; $0.shortcuts.sizeRatio = 0.15 }
        let presses = ShortcutOverlayPlanner.presses(events: shortcutSession.shortcuts ?? [])
        shortcutEditor.edit { $0.shortcuts.setHidden(true, for: presses[1]) }
        try check(shortcutEditor.exportEdit.shortcuts?.configuration.sizeRatio == 0.15 && shortcutEditor.state.shortcuts.isHidden(presses[1]), "unsaved shortcut settings reach the export")
        let withShortcuts = shortcutEditor.state
        shortcutEditor.edit { $0.shortcuts.sizeRatio = 5 }
        try check(shortcutEditor.state == withShortcuts && shortcutEditor.error != nil, "invalid shortcut size rolls back")
        shortcutEditor.undo()
        try check(!shortcutEditor.state.shortcuts.isHidden(presses[1]) && shortcutEditor.state.shortcuts.enabled, "hide is undoable")
        shortcutEditor.redo()
        try check(shortcutEditor.save(presetID: "custom-preset"), "shortcut settings saved")
        try check(try ShortcutOverlayConfiguration.load(in: shortcutDirectory) == withShortcuts.shortcuts, "shortcuts-config.json roundtrip")
        try check(try ExportEdit.load(from: shortcutDirectory, session: shortcutSession).shortcuts?.configuration == withShortcuts.shortcuts, "sidecar loader reads shortcuts")
        try check(try EditorModel(session: shortcutSession, directory: shortcutDirectory).state.shortcuts == withShortcuts.shortcuts, "reopened editor keeps shortcut settings")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        reopened.edit { try $0.timeline.trim(segmentID: $0.timeline.segments[0].id, newStart: 1, newEnd: 3) }
        try check(reopened.save(presetID: "custom-preset"), "trim saved")
        try check(try Data(contentsOf: directory.appendingPathComponent("session.json")) == bytes, "editing never alters capture sidecar")
        // Motion blur: one shared amount (default 1) in the editor state, undoable, validated, saved in cursor-config.json.
        let blurDirectory = directory.appendingPathComponent("blur-session")
        try FileManager.default.createDirectory(at: blurDirectory, withIntermediateDirectories: true)
        try session.save(in: blurDirectory)
        let blurEditor = try EditorModel(session: session, directory: blurDirectory)
        try check(blurEditor.state.motionBlurAmount == 1 && blurEditor.exportEdit.motionBlurAmount == 1, "motion blur defaults to 1")
        let beforeBlur = blurEditor.state
        blurEditor.edit { $0.motionBlurAmount = 0.4 }
        try check(blurEditor.exportEdit.motionBlurAmount == 0.4 && blurEditor.isDirty, "unsaved motion blur reaches the export")
        blurEditor.edit { $0.motionBlurAmount = 2 }
        try check(blurEditor.state.motionBlurAmount == 0.4 && blurEditor.error != nil, "invalid motion blur rolls back")
        blurEditor.undo()
        try check(blurEditor.state == beforeBlur, "motion blur undo")
        blurEditor.redo()
        var cursorConfig = CursorConfiguration()
        cursorConfig.size = 72
        try cursorConfig.save(in: blurDirectory)
        try check(blurEditor.save(presetID: "custom-preset"), "motion blur saved")
        let savedCursor = try CursorConfiguration.load(in: blurDirectory)
        try check(savedCursor.motionBlurAmount == 0.4 && savedCursor.size == 72, "motion blur saved without touching other cursor settings")
        try check(try EditorModel(session: session, directory: blurDirectory).state.motionBlurAmount == 0.4, "reopened editor keeps motion blur")
        // Masks: add at the playhead (clamped, default rectangle), edit, undo/redo, validation, save and reload.
        let maskDirectory = directory.appendingPathComponent("mask-session")
        try FileManager.default.createDirectory(at: maskDirectory, withIntermediateDirectories: true)
        try session.save(in: maskDirectory)
        let maskEditor = try EditorModel(session: session, directory: maskDirectory)
        try check(maskEditor.state.masks.masks.isEmpty && maskEditor.exportEdit.masks?.masks.isEmpty == true, "no masks by default")
        let beforeMask = maskEditor.state
        maskEditor.addMask(atSource: 2)
        let added = maskEditor.state.masks.masks.first
        try check(maskEditor.state.masks.masks.count == 1 && added?.sourceStart == 2 && added?.sourceEnd == 2 + TimelineMask.initialDuration
                  && added?.kind == .sensitiveData && added?.blur == 32 && maskEditor.error == nil, "mask added at the playhead")
        try check(added?.bounds == [TimelineMask.defaultBounds(recordingSize: CGSize(width: 640, height: 360))], "mask gets the default bounds for the recording size")
        try check(maskEditor.exportEdit.masks == maskEditor.state.masks && maskEditor.isDirty, "unsaved mask reaches the export")
        maskEditor.undo()
        try check(maskEditor.state == beforeMask && maskEditor.canRedo, "mask add undo")
        maskEditor.redo()
        try check(maskEditor.state.masks.masks.first == added, "mask add redo")
        maskEditor.addMask(atSource: 7.5)
        try check(maskEditor.state.masks.masks[1].sourceStart == 5 && maskEditor.state.masks.masks[1].sourceEnd == 8, "mask added near the end is clamped to the recording")
        maskEditor.undo()
        let maskID = maskEditor.state.masks.masks[0].id
        maskEditor.edit { state in
            state.masks.masks[0].kind = .highlight
            state.masks.masks[0].highlightOpacity = 0.7
            state.masks.masks[0].bounds = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)]
            state.masks.masks[0].isDisabled = true
            state.masks.masks[0].sourceEnd = 6
        }
        let editedMask = maskEditor.state
        try check(editedMask.masks.masks[0].kind == .highlight && editedMask.masks.masks[0].isDisabled, "mask edited")
        maskEditor.edit { $0.masks.masks[0].sourceEnd = $0.masks.masks[0].sourceStart + 0.1 }
        try check(maskEditor.state == editedMask && maskEditor.error != nil, "a mask under 0.5 s is rejected")
        maskEditor.edit { $0.masks.masks[0].sourceEnd = 9 }
        try check(maskEditor.state == editedMask && maskEditor.error != nil, "a mask past the recording end is rejected")
        maskEditor.edit { $0.masks.masks[0].bounds = [CGRect(x: 0.8, y: 0, width: 0.5, height: 0.5)] }
        try check(maskEditor.state == editedMask && maskEditor.error != nil, "a mask outside the frame is rejected")
        maskEditor.edit { $0.masks.masks[0].highlightOpacity = 2 }
        try check(maskEditor.state == editedMask && maskEditor.error != nil, "invalid highlight opacity is rejected")
        try check(!FileManager.default.fileExists(atPath: maskDirectory.appendingPathComponent("masks.json").path), "unsaved masks write nothing")
        try check(maskEditor.save(presetID: "custom-preset"), "masks saved")
        try check(try MaskConfiguration.load(from: maskDirectory) == editedMask.masks, "masks.json roundtrip")
        try check(try ExportEdit.load(from: maskDirectory, session: session).masks == editedMask.masks, "sidecar loader reads masks.json")
        let reopenedMasks = try EditorModel(session: session, directory: maskDirectory)
        try check(reopenedMasks.state.masks == editedMask.masks && !reopenedMasks.canUndo, "reopened editor keeps masks")
        reopenedMasks.edit { $0.masks.masks.removeAll { $0.id == maskID } }
        try check(reopenedMasks.exportEdit.masks?.masks.isEmpty == true, "an unsaved mask delete overrides the file for the export")
        try check(reopenedMasks.save(presetID: "custom-preset") && (try MaskConfiguration.load(from: maskDirectory)).masks.isEmpty, "mask delete saved")
        try check(try ExportEdit.load(from: maskDirectory, session: session).masks == nil, "no masks, no export masks")
        reopenedMasks.undo()
        try check(reopenedMasks.state.masks == editedMask.masks, "mask delete undo")
        // New-recording defaults versus legacy sessions: the recording flow writes the default sidecars at
        // finish time (`StageStyle.writeNewRecordingDefault`, `ClickEffectConfiguration.newRecordingDefault`).
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-editor-new-\(UUID())")
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-editor-legacy-\(UUID())")
        for url in [fresh, legacy] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { for url in [fresh, legacy] { try? FileManager.default.removeItem(at: url) } }
        try StageStyle.writeNewRecordingDefault(in: fresh)
        try ClickEffectConfiguration.newRecordingDefault.save(in: fresh)
        let newEditor = try EditorModel(session: session, directory: fresh)
        try check(newEditor.state.stageEnabled && newEditor.exportEdit.stage?.cornerRadius == 0
                  && newEditor.exportEdit.stage?.paddingRatio == 0.1 && newEditor.exportEdit.stage?.background == .wallpaper("graphite"),
                  "new recording starts on a stage: padding 0.1, radius 0, procedural system background")
        try check(newEditor.state.clickEffect.effect == .none && newEditor.exportEdit.clickEffect?.effect == ClickEffectType.none,
                  "new recording starts with click effect off")
        try check(try ExportEdit.load(from: fresh, session: session).stage?.cornerRadius == 0, "sidecar loader gives a new recording its stage")
        let legacyEditor = try EditorModel(session: session, directory: legacy)
        try check(!legacyEditor.state.stageEnabled && legacyEditor.exportEdit.stage == nil
                  && legacyEditor.state.stage.cornerRadius == 16 && legacyEditor.state.clickEffect.effect == .circle,
                  "legacy session (no sidecars) stays bare with radius 16 and circle clicks")
        try check(try ExportEdit.load(from: legacy, session: session).stage == nil, "sidecar loader leaves a legacy session bare")
        // A legacy sidecar written before radius/background keys existed keeps 16 and the observed gradient.
        try Data("{\"paddingRatio\":0.2}".utf8).write(to: legacy.appendingPathComponent("stage-config.json"))
        let legacyStaged = try EditorModel(session: session, directory: legacy)
        try check(legacyStaged.state.stageEnabled && legacyStaged.state.stage.cornerRadius == 16
                  && legacyStaged.state.stage.background == .standard, "legacy stage sidecar keeps its old defaults")
        // A saved choice wins: saved project.json with the stage off stays off even beside the default sidecars.
        newEditor.edit { $0.stageEnabled = false; $0.clickEffect.effect = .ripple }
        try check(newEditor.save(presetID: "custom-preset"), "new recording saves")
        let savedNew = try EditorModel(session: session, directory: fresh)
        try check(!savedNew.state.stageEnabled && savedNew.state.clickEffect.effect == .ripple, "saved choices are kept on reopen")
        // Zoom items: legacy seeds, unsaved exports, split/add, undo/redo, atomic sidecar, reload and explicit empty.
        let zoomDirectory = directory.appendingPathComponent("zoom-session")
        try FileManager.default.createDirectory(at: zoomDirectory, withIntermediateDirectories: true)
        var zoomSession = session
        zoomSession.events = [CursorEvent(time: 2, x: 0.7, y: 0.3, kind: .down)]
        try zoomSession.save(in: zoomDirectory)
        let zoomEditor = try EditorModel(session: zoomSession, directory: zoomDirectory)
        try check(zoomEditor.state.zoomItems.items.count == 1 && zoomEditor.state.zoomItems.items[0].mode == .autoFollow,
                  "legacy editor seeds automatic zoom items")
        try check(!FileManager.default.fileExists(atPath: zoomDirectory.appendingPathComponent(ZoomItemConfiguration.filename).path),
                  "opening legacy zooms writes nothing")
        let beforeZoom = zoomEditor.state
        zoomEditor.addZoom(atSource: 2.5)
        try check(zoomEditor.state.zoomItems.items.count == 2 && zoomEditor.state.zoomItems.items[1].sourceStart == 2.5
                  && zoomEditor.state.zoomItems.items[1].mode == .manual, "add zoom at playhead splits the automatic item")
        zoomEditor.undo()
        try check(zoomEditor.state == beforeZoom, "zoom insertion undo restores original seed and identity")
        zoomEditor.redo()
        zoomEditor.edit {
            $0.zoomItems.items[1].centerX = 0.3; $0.zoomItems.items[1].centerY = 0.7
            $0.zoomItems.items[1].scale = 3; $0.zoomItems.items[1].hasInstantAnimation = true
            $0.zoomItems.startAnimationEarly = true
        }
        let editedZoom = zoomEditor.state
        try check(zoomEditor.exportEdit.zoomItems == editedZoom.zoomItems, "unsaved manual zoom reaches export")
        zoomEditor.edit { $0.zoomItems.items[1].sourceEnd = 9 }
        try check(zoomEditor.state == editedZoom && zoomEditor.error != nil, "invalid zoom range rolls back")
        zoomEditor.edit { $0.zoomItems.items[0].sourceEnd = $0.zoomItems.items[0].sourceStart + 0.01 }
        try check(zoomEditor.state == editedZoom && zoomEditor.error != nil, "automatic range edits enforce 100 ms minimum")
        zoomEditor.edit { $0.zoomItems.items[1].centerY = 2 }
        try check(zoomEditor.state == editedZoom && zoomEditor.error != nil, "invalid manual center rolls back")
        zoomEditor.edit { $0.zoomItems.items[1].sourceStart = 1 }
        try check(zoomEditor.state == editedZoom && zoomEditor.error != nil, "overlapping zoom ranges roll back")
        try check(zoomEditor.save(presetID: "custom-preset"), "manual zoom saved")
        try check(try ZoomItemConfiguration.load(from: zoomDirectory, duration: session.duration) == editedZoom.zoomItems,
                  "zoom-items.json preserves manual center, scale, IDs and animation flags")
        try check(try ExportEdit.load(from: zoomDirectory, session: zoomSession).zoomItems == editedZoom.zoomItems,
                  "ExportEdit loader reads persisted zoom items")
        let reopenedZoom = try EditorModel(session: zoomSession, directory: zoomDirectory)
        try check(reopenedZoom.state.zoomItems == editedZoom.zoomItems && !reopenedZoom.canUndo && !reopenedZoom.isDirty,
                  "reload restores zoom edits with fresh history")
        reopenedZoom.edit { $0.zoomItems.items[1].isDisabled = true }
        try check(reopenedZoom.exportEdit.zoomItems?.items[1].isDisabled == true, "zoom enable toggle reaches export")
        reopenedZoom.undo()
        try check(reopenedZoom.state.zoomItems == editedZoom.zoomItems, "zoom toggle undo")
        reopenedZoom.regenerateAutomaticZooms()
        try check(reopenedZoom.state.zoomItems.items.count == 1 && reopenedZoom.state.zoomItems.items[0].mode == .autoFollow,
                  "regenerate replaces edited zooms")
        reopenedZoom.undo()
        try check(reopenedZoom.state.zoomItems == editedZoom.zoomItems, "regenerate is undoable")
        reopenedZoom.edit { $0.zoomItems.items.removeAll() }
        try check(reopenedZoom.exportEdit.zoomItems?.items.isEmpty == true, "unsaved empty zoom list overrides persisted zooms")
        try check(reopenedZoom.save(presetID: "custom-preset"), "empty zoom list saved")
        try check(try EditorModel(session: zoomSession, directory: zoomDirectory).state.zoomItems.items.isEmpty,
                  "reload never reseeds an explicit empty list")
        try check(try ExportEdit.load(from: zoomDirectory, session: zoomSession).zoomItems?.items.isEmpty == true,
                  "explicit empty list survives ExportEdit loader")
        let zoomSaved = try Data(contentsOf: zoomDirectory.appendingPathComponent(ViddeoProject.filename))
        try FileManager.default.removeItem(at: zoomDirectory.appendingPathComponent(ZoomItemConfiguration.filename))
        try FileManager.default.createDirectory(at: zoomDirectory.appendingPathComponent(ZoomItemConfiguration.filename), withIntermediateDirectories: true)
        reopenedZoom.undo()
        try check(!reopenedZoom.save(presetID: "custom-preset") && reopenedZoom.isDirty && reopenedZoom.error != nil,
                  "failed zoom sidecar save keeps edits dirty")
        try check(try Data(contentsOf: zoomDirectory.appendingPathComponent(ViddeoProject.filename)) == zoomSaved,
                  "project is never saved before zoom sidecar succeeds")
        // Refuse damaged/newer project files instead of silently resetting edits.
        try Data("{\"version\":99}".utf8).write(to: directory.appendingPathComponent("project.json"))
        do {
            _ = try EditorModel(session: session, directory: directory)
            throw NSError(domain: "VerifyEditor", code: 2)
        } catch ProjectError.unsupportedVersion(99) { checks += 1 }
        print("Editor verified: \(checks) checks")
    }
}
