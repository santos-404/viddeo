import SwiftUI
import UniformTypeIdentifiers

/// Processed preview plus plain controls for the implemented edit operations.
struct EditorView: View {
    @Bindable var editor: EditorModel
    let presetID: String
    /// The selected export preset's settings and the click-effect toggle, so the preview matches the export.
    let settings: ExportSettings
    let showsClickEffects: Bool
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var splitTime = 0.0
    @State private var previewModel = EditorPreviewModel()
    @State private var newLayout = WebcamLayout.splitScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit recording").font(.headline)
                Text(editor.isDirty ? "Unsaved changes" : "Saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Undo") { editor.undo() }.disabled(!editor.canUndo)
                Button("Redo") { editor.redo() }.disabled(!editor.canRedo)
                Button("Save Project") { editor.save(presetID: presetID) }
            }
            EditorPreview(editor: editor, settings: settings, showsClickEffects: showsClickEffects, model: previewModel)
            TabView {
                timeline.tabItem { Text("Timeline") }
                stage.tabItem { Text("Background") }
                captions.tabItem { Text("Captions") }
                audio.tabItem { Text("Audio") }
                if editor.session.webcam != nil { camera.tabItem { Text("Camera") } }
                if editor.hasShortcuts { shortcuts.tabItem { Text("Shortcuts") } }
            }
            .frame(minHeight: 300)
            if editor.isWorking { ProgressView().controlSize(.small) }
            Text(editor.status).font(.caption).foregroundStyle(.secondary)
            if let error = editor.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { resetRange() }
        .onChange(of: editor.selectedSegmentID) { resetRange() }
        .onChange(of: editor.state.timeline) { resetRange() }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback: \(editor.state.timeline.playbackDuration.formatted(.number.precision(.fractionLength(2)))) s. Ranges use source seconds.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Segment", selection: $editor.selectedSegmentID) {
                ForEach(Array(editor.state.timeline.segments.enumerated()), id: \.element.id) { index, segment in
                    Text("\(index + 1): \(segment.sourceStart.formatted(.number.precision(.fractionLength(2))))–\(segment.sourceEnd.formatted(.number.precision(.fractionLength(2)))) s · \(segment.speed.formatted())×")
                        .tag(Optional(segment.id))
                }
            }
            if let segment = editor.selectedSegment {
                HStack {
                    number("Start", value: $trimStart)
                    number("End", value: $trimEnd)
                    Button("Trim") {
                        editor.edit { try $0.timeline.trim(segmentID: segment.id, newStart: trimStart, newEnd: trimEnd) }
                    }
                }
                HStack {
                    number("Split at", value: $splitTime)
                    Button("Split") { editor.edit { try $0.timeline.split(atSource: splitTime) } }
                    Button("Delete") { editor.edit { try $0.timeline.delete(segmentID: segment.id) } }
                        .disabled(editor.state.timeline.segments.count == 1)
                    Button("Earlier") { move(segment.id, offset: -1) }
                        .disabled(editor.state.timeline.segments.first?.id == segment.id)
                    Button("Later") { move(segment.id, offset: 1) }
                        .disabled(editor.state.timeline.segments.last?.id == segment.id)
                }
                HStack {
                    Picker("Speed", selection: Binding(get: { segment.timeScale }, set: { scale in
                        editor.edit { try $0.timeline.setTimeScale(segmentID: segment.id, to: scale) }
                    })) {
                        ForEach([0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 10.0], id: \.self) { scale in
                            Text("\((1 / scale).formatted())×").tag(scale)
                        }
                        if ![0.05, 0.1, 0.25, 0.5, 1, 2, 4, 10].contains(segment.timeScale) {
                            Text("\(segment.speed.formatted())×").tag(segment.timeScale)
                        }
                    }
                    Toggle("Hide rendered cursor", isOn: Binding(get: { segment.hideCursor }, set: { hidden in
                        editor.edit { try $0.timeline.setHideCursor(segmentID: segment.id, to: hidden) }
                    }))
                    .disabled(editor.session.cursorEmbedded != false)
                }
                volume("Microphone", value: segment.volume, id: segment.id, system: false)
                volume("System audio", value: segment.systemVolume, id: segment.id, system: true)
            }
            HStack {
                Button("Analyze Silence") { editor.analyzeSilence() }
                    .disabled(editor.session.audio?.microphoneSamples ?? 0 == 0)
                Button("Trim Silence") { editor.applySilence(speedUp: false) }.disabled(editor.silence.isEmpty)
                Button("Speed Silence 4×") { editor.applySilence(speedUp: true) }.disabled(editor.silence.isEmpty)
            }
        }.padding(12)
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Background and padding", isOn: Binding(get: { editor.state.stageEnabled }, set: { enabled in
                editor.edit { $0.stageEnabled = enabled }
            }))
            HStack {
                Text("Gradient")
                ForEach(StageStyle.gradientPresets, id: \.name) { preset in
                    Button(preset.name) { editor.edit { $0.stage.background = preset.background; $0.stageEnabled = true } }
                }
            }
            HStack {
                Text("Padding")
                Slider(value: Binding(get: { editor.state.stage.paddingRatio }, set: { value in
                    editor.edit({ $0.stage.paddingRatio = value }, key: "padding")
                }), in: 0...0.4)
                Text(editor.state.stage.paddingRatio.formatted(.percent.precision(.fractionLength(0))))
            }
            HStack {
                Text("Corner radius")
                Slider(value: Binding(get: { editor.state.stage.cornerRadius }, set: { value in
                    editor.edit({ $0.stage.cornerRadius = value }, key: "radius")
                }), in: 0...100)
                Text(editor.state.stage.cornerRadius.formatted(.number.precision(.fractionLength(0))))
            }
            HStack {
                Text("Device frame")
                Picker("Device frame", selection: Binding(get: {
                    editor.state.stage.deviceMockup.enabled ? (editor.state.stage.deviceMockup.deviceID ?? "none") : "none"
                }, set: { value in
                    editor.edit {
                        $0.stage.deviceMockup.enabled = value != "none"
                        $0.stage.deviceMockup.deviceID = value == "none" ? nil : value
                    }
                })) {
                    Text("None").tag("none")
                    ForEach(DeviceFrameCatalog.devices, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            if editor.state.stage.deviceMockup.enabled {
                HStack {
                    Text("Finish")
                    Picker("Finish", selection: Binding(get: { editor.state.stage.deviceMockup.finish ?? "dark" }, set: { value in
                        editor.edit { $0.stage.deviceMockup.finish = value }
                    })) {
                        ForEach(DeviceFrameCatalog.finishes, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Text("The screen aperture controls its shape; stage corner radius and inset are not applied to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Motion blur")
                Slider(value: Binding(get: { editor.state.motionBlurAmount }, set: { value in
                    editor.edit({ $0.motionBlurAmount = value }, key: "motionBlur")
                }), in: 0...1)
                Text(editor.state.motionBlurAmount.formatted(.percent.precision(.fractionLength(0))))
            }
            Text("Motion blur smears the cursor and zoom camera moves; the camera overlay is not blurred.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Backgrounds, captions and edits appear in exported MP4 and GIF files.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Language (e.g. en-US)", text: $editor.localeIdentifier).frame(width: 180)
                Button("Generate on Device") { editor.generateCaptions() }
                    .disabled(editor.session.audio?.microphoneSamples ?? 0 == 0)
                Toggle("Show captions", isOn: Binding(get: { editor.state.captionConfiguration.enabled }, set: { enabled in
                    editor.edit { $0.captionConfiguration.enabled = enabled }
                }))
            }
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(editor.state.captions.cues) { cue in
                        HStack {
                            Text("\((cue.startMs / 1000).formatted(.number.precision(.fractionLength(2)))) s").monospacedDigit().frame(width: 70)
                            TextField("Caption", text: Binding(get: {
                                editor.state.captions.cues.first { $0.id == cue.id }?.text ?? ""
                            }, set: { text in
                                editor.edit({ try $0.captions.updateText(cueID: cue.id, to: text) }, key: "cue-\(cue.id)")
                            }))
                            Button("Delete") { editor.edit { try $0.captions.delete(cueID: cue.id) } }
                        }
                    }
                    if editor.state.captions.cues.isEmpty {
                        Text("Record microphone audio to generate captions. Apple may download the selected language model.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(12)
    }

    private var shortcuts: some View {
        let presses = ShortcutOverlayPlanner.presses(events: editor.session.shortcuts ?? [],
                                                     showSingleLetters: editor.state.shortcuts.showSingleLetters)
        return VStack(alignment: .leading, spacing: 10) {
            Toggle("Show shortcuts", isOn: Binding(get: { editor.state.shortcuts.enabled }, set: { enabled in
                editor.edit { $0.shortcuts.enabled = enabled }
            }))
            HStack {
                Text("Size")
                Slider(value: Binding(get: { editor.state.shortcuts.sizeRatio }, set: { ratio in
                    editor.edit({ $0.shortcuts.sizeRatio = ratio }, key: "shortcuts-size")
                }), in: 0.05...0.2)
                Text("\(Int((editor.state.shortcuts.sizeRatio * 100).rounded())) % of height")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            }
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(presses) { press in
                        HStack {
                            Text("\((press.firstKeyDownMs / 1000).formatted(.number.precision(.fractionLength(2)))) s")
                                .monospacedDigit().frame(width: 70, alignment: .leading)
                            Text(press.glyphString).font(.title3).frame(minWidth: 90, alignment: .leading)
                            if press.count > 1 { Text("× \(press.count)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Toggle("Hide", isOn: Binding(get: { editor.state.shortcuts.isHidden(press) }, set: { hidden in
                                editor.edit { $0.shortcuts.setHidden(hidden, for: press) }
                            }))
                        }
                    }
                }
            }
            Text("Only shortcuts were recorded (⌘, ⌥ or ⌃ combinations and keys like Esc, Return or arrows), never typed text.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }

    private var audio: some View {
        let hasMicrophone = editor.session.audio?.microphoneSamples ?? 0 > 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Master volume").frame(width: 110, alignment: .leading)
                Slider(value: Binding(get: { editor.state.audio.volume }, set: { value in
                    editor.edit({ $0.audio.volume = value }, key: "audio-volume")
                }), in: 0...2)
                Text(editor.state.audio.volume.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
            }
            HStack {
                Toggle("Mute microphone", isOn: Binding(get: { editor.state.audio.muteMicrophone }, set: { muted in
                    editor.edit { $0.audio.muteMicrophone = muted }
                }))
                Toggle("Mute system audio", isOn: Binding(get: { editor.state.audio.muteSystemAudio }, set: { muted in
                    editor.edit { $0.audio.muteSystemAudio = muted }
                }))
            }
            Picker("Microphone cleanup", selection: Binding(get: { editor.state.audio.microphonePreset }, set: { preset in
                editor.edit { $0.audio.microphonePreset = preset }
            })) {
                Text("Off").tag(MicrophonePreset.off)
                Text("Voice").tag(MicrophonePreset.voice)
                Text("Noise reduction").tag(MicrophonePreset.noiseReduction)
                Text("Podcast").tag(MicrophonePreset.podcast)
            }
            .disabled(!hasMicrophone)
            Picker("Click sound", selection: Binding(get: { editor.state.audio.clickSoundEffect }, set: { set in
                editor.edit { $0.audio.clickSoundEffect = set }
            })) {
                Text("None").tag(Optional<ClickSoundSet>.none)
                Text("Soft click").tag(Optional(ClickSoundSet.softClick))
                Text("Crisp click").tag(Optional(ClickSoundSet.crispClick))
            }
            HStack {
                Text("Click volume").frame(width: 110, alignment: .leading)
                Slider(value: Binding(get: { editor.state.audio.clickSoundEffectVolume }, set: { value in
                    editor.edit({ $0.audio.clickSoundEffectVolume = value }, key: "click-volume")
                }), in: 0...1)
                Text(editor.state.audio.clickSoundEffectVolume.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
            }
            .disabled(editor.state.audio.clickSoundEffect == nil)
            Divider()
            HStack {
                Text("Background music").frame(width: 110, alignment: .leading)
                Text(editor.state.audio.backgroundAudioFileName ?? "None").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(editor.state.audio.backgroundAudioFileName == nil ? "Choose…" : "Replace…") { chooseMusic() }
                Button("Remove") { editor.removeBackgroundMusic() }
                    .disabled(editor.state.audio.backgroundAudioFileName == nil)
            }
            HStack {
                Text("Music volume").frame(width: 110, alignment: .leading)
                Slider(value: Binding(get: { editor.state.audio.backgroundAudioVolume }, set: { value in
                    editor.edit({ $0.audio.backgroundAudioVolume = value }, key: "music-volume")
                }), in: 0...1)
                Text(editor.state.audio.backgroundAudioVolume.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
                Toggle("Mute", isOn: Binding(get: { editor.state.audio.muteBackgroundAudio }, set: { muted in
                    editor.edit { $0.audio.muteBackgroundAudio = muted }
                }))
            }
            .disabled(editor.state.audio.backgroundAudioFileName == nil)
            Divider()
            Toggle("Mix everything into one audio track", isOn: Binding(get: { editor.state.audio.mixdownSingleTrack }, set: { on in
                editor.edit { $0.audio.mixdownSingleTrack = on }
            }))
            Picker("Loudness", selection: Binding(get: { editor.state.audio.targetLoudnessLUFS }, set: { target in
                editor.edit { $0.audio.targetLoudnessLUFS = target }
            })) {
                Text("Off").tag(Optional<Double>.none)
                Text("−16 LUFS").tag(Optional(-16.0))
                Text("−14 LUFS").tag(Optional(-14.0))
            }
            .disabled(!editor.state.audio.mixdownSingleTrack)
            Text("Music starts at 0:00, loops to the edited length, fades out for 1 s and ignores trims. The single track is stereo, limited to \(editor.state.audio.limiterCeilingDB.formatted(.number.precision(.fractionLength(0...1)))) dB; MP4 only.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Applied to MP4 exports: cleanup replaces the exported microphone track, click sounds add a separate track. Cleanup is viddeo's own DSP, not Screen Studio's model.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose background music"
        if panel.runModal() == .OK, let url = panel.url { editor.setBackgroundMusic(from: url) }
    }

    private var camera: some View {
        let hasMicrophone = editor.session.audio?.microphoneSamples ?? 0 > 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Show camera", isOn: Binding(get: { !editor.state.webcam.hide }, set: { shown in
                    editor.edit { $0.webcam.hide = !shown }
                }))
                Toggle("Mirror", isOn: Binding(get: { editor.state.webcam.mirror }, set: { mirrored in
                    editor.edit { $0.webcam.mirror = mirrored }
                }))
            }
            Picker("Layout", selection: Binding(get: { editor.state.webcam.layout }, set: { layout in
                editor.edit { $0.webcam.layout = layout }
            })) {
                Text("Overlay").tag(WebcamLayout.cameraOverlay)
                Text("Full-screen camera").tag(WebcamLayout.fullscreenCamera)
                Text("Screen only").tag(WebcamLayout.screenOnly)
                Text("Split screen").tag(WebcamLayout.splitScreen)
                Text("Cutout camera").tag(WebcamLayout.cutoutCamera)
            }
            Picker("Position", selection: Binding(get: { editor.state.webcam.anchor }, set: { anchor in
                editor.edit { $0.webcam.position = anchor.point }
            })) {
                ForEach(WebcamAnchor.allCases, id: \.self) { anchor in Text(anchor.rawValue).tag(anchor) }
            }
            Picker("Shape", selection: Binding(get: { editor.state.webcam.shape }, set: { shape in
                editor.edit { $0.webcam.shape = shape }
            })) {
                Text("Rounded").tag(WebcamShape.roundedRect)
                Text("Circle").tag(WebcamShape.circle)
            }
            HStack {
                Text("Size").frame(width: 60, alignment: .leading)
                Slider(value: Binding(get: { editor.state.webcam.sizeRatio }, set: { value in
                    editor.edit({ $0.webcam.sizeRatio = value }, key: "camera-size")
                }), in: 0.1...0.6)
                Text(editor.state.webcam.sizeRatio.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
            }
            Toggle("Hide while silent (2 s or longer)", isOn: Binding(get: { editor.state.webcam.hideDuringSilenceMs != nil }, set: { on in
                editor.edit { $0.webcam.hideDuringSilenceMs = on ? 2_000 : nil }
            }))
            .disabled(!hasMicrophone)
            if editor.state.webcam.usedLayouts.contains(.splitScreen) { splitOptions }
            if editor.state.webcam.usedLayouts.contains(.cutoutCamera) { cutoutOptions }
            layoutChanges
            Text("The camera is composited into MP4 and GIF exports at the position and size shown here.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }

    private var splitOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Split screen").font(.subheadline)
            Picker("Direction", selection: Binding(get: { editor.state.webcam.split.direction }, set: { value in
                editor.edit { $0.webcam.split.direction = value }
            })) {
                Text("Automatic").tag(SplitDirection.auto)
                Text("Side by side").tag(SplitDirection.horizontal)
                Text("Stacked").tag(SplitDirection.vertical)
            }
            HStack {
                Toggle("Flip", isOn: Binding(get: { editor.state.webcam.split.flip }, set: { value in
                    editor.edit { $0.webcam.split.flip = value }
                }))
                Toggle("Gap between panes", isOn: Binding(get: { editor.state.webcam.split.enablePadding }, set: { value in
                    editor.edit { $0.webcam.split.enablePadding = value }
                }))
            }
            HStack {
                Toggle("Automatic screen share", isOn: Binding(get: { editor.state.webcam.split.screenRatio == nil }, set: { auto in
                    editor.edit { $0.webcam.split.screenRatio = auto ? nil : SplitScreenOptions.defaultScreenRatio }
                }))
                if let ratio = editor.state.webcam.split.screenRatio {
                    Slider(value: Binding(get: { ratio }, set: { value in
                        editor.edit({ $0.webcam.split.screenRatio = value }, key: "split-ratio")
                    }), in: 0.1...0.9)
                    Text(ratio.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
                }
            }
        }
    }

    private var cutoutOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cutout camera").font(.subheadline)
            cutoutSlider("Position", value: editor.state.webcam.cutout.positionX, range: 0...1, key: "cutout-x") { $0.webcam.cutout.positionX = $1 }
            cutoutSlider("Size", value: editor.state.webcam.cutout.sizeRatio, range: 0.1...1, key: "cutout-size") { $0.webcam.cutout.sizeRatio = $1 }
            cutoutSlider("Zoomed", value: editor.state.webcam.cutout.zoomedScale, range: 0.2...1, key: "cutout-zoomed") { $0.webcam.cutout.zoomedScale = $1 }
            Picker("Aspect", selection: Binding(get: { editor.state.webcam.cutout.aspectRatio ?? .original }, set: { value in
                editor.edit { $0.webcam.cutout.aspectRatio = value == .original ? nil : value }
            })) {
                Text("Camera").tag(WebcamAspectRatio.original)
                Text("Square").tag(WebcamAspectRatio.square)
                Text("16:9").tag(WebcamAspectRatio.horizontal)
                Text("9:16").tag(WebcamAspectRatio.vertical)
            }
            Text("The person is cut out on this Mac with Apple Vision; frames without a person show the rounded overlay instead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cutoutSlider(_ title: String, value: Double, range: ClosedRange<Double>, key: String,
                              apply: @escaping (inout EditorState, Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { newValue in
                editor.edit({ apply(&$0, newValue) }, key: key)
            }), in: range)
            Text(value.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
        }
    }

    /// Layout changes in source time; the default layout applies outside them.
    private var layoutChanges: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Layout changes").font(.subheadline)
                Picker("New layout", selection: $newLayout) {
                    ForEach(WebcamLayout.allCases, id: \.self) { Text(Self.layoutName($0)).tag($0) }
                }
                .labelsHidden()
                Button("Add at playhead") {
                    let source = editor.state.timeline.sourceTime(forPlaybackTime: previewModel.time) * 1000
                    editor.edit { try $0.webcam.addLayoutItem(layout: newLayout, atMs: source,
                                                              sourceDurationMs: editor.session.duration * 1000) }
                }
            }
            ForEach(editor.state.webcam.layoutItems) { item in
                HStack {
                    Text("\((item.startMs / 1000).formatted(.number.precision(.fractionLength(1))))–\((item.endMs / 1000).formatted(.number.precision(.fractionLength(1)))) s")
                        .monospacedDigit().frame(width: 110, alignment: .leading)
                    Picker("Layout", selection: Binding(get: { item.layout }, set: { value in
                        editor.edit { if let index = $0.webcam.layoutItems.firstIndex(where: { $0.id == item.id }) { $0.webcam.layoutItems[index].layout = value } }
                    })) {
                        ForEach(WebcamLayout.allCases, id: \.self) { Text(Self.layoutName($0)).tag($0) }
                    }
                    .labelsHidden()
                    Button("Delete") { editor.edit { $0.webcam.removeLayoutItem(id: item.id) } }
                }
            }
            Text("Changes switch immediately (the original's transition is unknown) and use source seconds, at least 0.5 s each.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func layoutName(_ layout: WebcamLayout) -> String {
        switch layout {
        case .cameraOverlay: "Overlay"
        case .screenOnly: "Screen only"
        case .fullscreenCamera: "Full-screen camera"
        case .splitScreen: "Split screen"
        case .cutoutCamera: "Cutout camera"
        }
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); TextField(title, value: value, format: .number).frame(width: 80) }
    }

    private func volume(_ title: String, value: Double, id: UUID, system: Bool) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { value in
                editor.edit({
                    if system { try $0.timeline.setSystemVolume(segmentID: id, to: value) }
                    else { try $0.timeline.setVolume(segmentID: id, to: value) }
                }, key: "volume-\(system)-\(id)")
            }), in: 0...2)
            Text(value.formatted(.percent.precision(.fractionLength(0)))).frame(width: 45)
        }
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = editor.state.timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        editor.edit { try $0.timeline.move(segmentID: id, toIndex: index + offset) }
    }

    private func resetRange() {
        guard let segment = editor.selectedSegment else { return }
        trimStart = segment.sourceStart
        trimEnd = segment.sourceEnd
        splitTime = (trimStart + trimEnd) / 2
    }
}
