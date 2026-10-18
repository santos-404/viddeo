import SwiftUI

struct RecordingView: View {
    @Bindable var viewModel: RecordingViewModel

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Viddeo")
                .font(.largeTitle)

            Picker("Recording source", selection: $viewModel.recordingSourceKind) {
                Text("Display").tag(RecordingSourceKind.display)
                Text("Window").tag(RecordingSourceKind.window)
                Text("Area").tag(RecordingSourceKind.area)
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isBusy)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Display")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        Task { await viewModel.refreshDisplays() }
                    }
                    .disabled(viewModel.isRefreshing || viewModel.isBusy)
                }

                Picker("Display", selection: $viewModel.selectedDisplayID) {
                    Text("Select a display")
                        .tag(UInt32?.none)
                    ForEach(viewModel.displays) { display in
                        Text(display.description)
                            .tag(Optional(display.id))
                    }
                }
                .labelsHidden()
                .disabled(viewModel.displays.isEmpty || viewModel.isBusy)
            }

            if viewModel.recordingSourceKind == .window {
                Picker("Window", selection: $viewModel.selectedWindowID) {
                    Text("Select a window").tag(CGWindowID?.none)
                    ForEach(viewModel.windows) { window in
                        Text(window.description).tag(Optional(window.id))
                    }
                }
                .disabled(viewModel.windows.isEmpty || viewModel.isBusy)
            } else if viewModel.recordingSourceKind == .area {
                Text("Area on the selected display, in points from its top-left corner")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        numberField("X", value: $viewModel.areaX)
                        numberField("Y", value: $viewModel.areaY)
                    }
                    GridRow {
                        numberField("Width", value: $viewModel.areaWidth)
                        numberField("Height", value: $viewModel.areaHeight)
                    }
                }
                .disabled(viewModel.isBusy)
            }

            HStack {
                Toggle("System Audio", isOn: $viewModel.capturesSystemAudio)
                Toggle("Microphone", isOn: $viewModel.capturesMicrophone)
            }
            .disabled(viewModel.isBusy)

            Toggle("Camera overlay", isOn: $viewModel.capturesWebcam)
                .disabled(viewModel.isBusy)

            HStack {
                Toggle("Smooth rendered cursor", isOn: $viewModel.rendersCursor)
                Toggle("Hide cursor while typing", isOn: $viewModel.capturesTypingTiming)
                    .disabled(!viewModel.rendersCursor)
            }
            .disabled(viewModel.isBusy)
            if viewModel.rendersCursor && viewModel.capturesTypingTiming {
                Text("Records key-down times only to hide the cursor while typing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Record keyboard shortcuts", isOn: $viewModel.capturesShortcuts)
                .disabled(viewModel.isBusy)
            if viewModel.capturesShortcuts {
                Text("Stores only shortcuts (⌘, ⌥ or ⌃ combinations and keys like Esc, Return or arrows) with their times, never typed text.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Show click effects in export", isOn: $viewModel.showsClickEffects)
                .disabled(viewModel.isBusy)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Export preset", selection: $viewModel.selectedPresetID) {
                    ForEach(viewModel.presets, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .disabled(viewModel.isBusy)
                Text(viewModel.presetSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Start") { viewModel.startRecording() }
                    .disabled(!viewModel.canStart)
                Button("Stop") { viewModel.stopRecording() }
                    .disabled(!viewModel.canStop)
                Spacer()
                if viewModel.phase == .exporting {
                    Button("Cancel Export") { viewModel.cancelExport() }
                }
                Button("Copy to Clipboard") { viewModel.exportRecording(target: .clipboard) }
                    .disabled(!viewModel.canExport)
                Button("Export") { viewModel.exportRecording() }
                    .disabled(!viewModel.canExport)
            }

            HStack {
                Button("Load Session…") { viewModel.loadSession() }
                    .disabled(viewModel.isBusy)
                Button("Show Recording") { viewModel.revealSession() }
                    .disabled(viewModel.sessionDirectory == nil)
                if viewModel.exportedURL != nil {
                    Button("Show in Finder") { viewModel.revealExport() }
                }
            }

            if viewModel.isBusy && viewModel.phase != .recording {
                ProgressView().controlSize(.small)
            }

            Text(viewModel.status)
                .foregroundStyle(.secondary)

            if let refreshError = viewModel.refreshError {
                Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Screen Recording Settings") { viewModel.openPrivacySettings() }
            }

            if let operationError = viewModel.operationError {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let session = viewModel.session {
                Text("\(session.width) × \(session.height) · \(session.events.count) pointer events · \(session.droppedFrames) skipped samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let audio = session.audio {
                    Text("Audio samples: system \(audio.systemAudioSamples) · mic \(audio.microphoneSamples) · skipped \(audio.systemAudioDroppedSamples + audio.microphoneDroppedSamples)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let editor = viewModel.editor {
                Divider()
                EditorView(editor: editor, presetID: viewModel.selectedPresetID,
                           settings: viewModel.selectedPreset.settings, showsClickEffects: viewModel.showsClickEffects)
                    .disabled(viewModel.phase != .idle || editor.isWorking)
            }
        }
        .padding(24)
        }
        .task {
            await viewModel.refreshDisplays()
        }
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 48, alignment: .leading)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
        }
    }
}
