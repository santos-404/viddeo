import SwiftUI

/// Plain controls for the implemented edit operations; processed output is reviewed after export.
struct EditorView: View {
    @Bindable var editor: EditorModel
    let presetID: String
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var splitTime = 0.0

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
            TabView {
                timeline.tabItem { Text("Timeline") }
                stage.tabItem { Text("Background") }
                captions.tabItem { Text("Captions") }
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
