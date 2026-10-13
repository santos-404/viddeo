import AppKit
import SwiftUI

@main
struct ViddeoApp: App {
    @NSApplicationDelegateAdaptor(ViddeoApplicationDelegate.self) private var delegate
    @State private var recordingViewModel = RecordingViewModel()

    var body: some Scene {
        WindowGroup {
            RecordingView(viewModel: recordingViewModel)
                .frame(minWidth: 820, minHeight: 700)
                .onAppear { delegate.viewModel = recordingViewModel }
        }
        .windowResizability(.automatic)
    }
}

@MainActor
final class ViddeoApplicationDelegate: NSObject, NSApplicationDelegate {
    var viewModel: RecordingViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isBusy || viewModel.editor?.isDirty == true else { return .terminateNow }
        Task {
            let saved = await viewModel.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
