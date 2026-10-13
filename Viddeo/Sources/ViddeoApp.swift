import AppKit
import SwiftUI

@main
struct ViddeoApp: App {
    @NSApplicationDelegateAdaptor(ViddeoApplicationDelegate.self) private var delegate
    @State private var recordingViewModel = RecordingViewModel()

    var body: some Scene {
        WindowGroup {
            RecordingView(viewModel: recordingViewModel)
                .frame(minWidth: 520, minHeight: 360)
                .onAppear { delegate.viewModel = recordingViewModel }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class ViddeoApplicationDelegate: NSObject, NSApplicationDelegate {
    var viewModel: RecordingViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isBusy else { return .terminateNow }
        Task {
            await viewModel.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
