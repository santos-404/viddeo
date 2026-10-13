import SwiftUI

struct RecordingView: View {
    @Bindable var viewModel: RecordingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Viddeo")
                .font(.largeTitle)

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

            HStack(spacing: 10) {
                Button("Start") { viewModel.startRecording() }
                    .disabled(!viewModel.canStart)
                Button("Stop") { viewModel.stopRecording() }
                    .disabled(!viewModel.canStop)
                Spacer()
                Button("Export") { viewModel.exportRecording() }
                    .disabled(!viewModel.canExport)
            }

            HStack {
                Button("Load Session…") { viewModel.loadSession() }
                    .disabled(viewModel.isBusy)
                Button("Show Recording") { viewModel.revealSession() }
                    .disabled(viewModel.sessionDirectory == nil)
                if viewModel.exportedURL != nil {
                    Button("Show Export") { viewModel.revealExport() }
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
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .task {
            await viewModel.refreshDisplays()
        }
    }
}
