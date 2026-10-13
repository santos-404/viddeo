// Manual check of real on-device captioning (NOT part of verify.sh).
// Needs a session directory whose raw.mp4 has a microphone track, and Apple speech model
// assets for the locale: the first run may download them through AssetInventory.
//
// xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
//   Viddeo/Sources/RecordingSession.swift Viddeo/Sources/Captions.swift \
//   Viddeo/Sources/CaptionRenderer.swift Viddeo/Sources/SpeechCaptionProvider.swift \
//   Scripts/live-captions.swift -o .build/live-captions
// .build/live-captions <session-dir> [locale]
//
// Writes captions.json into the session directory (merging with any edited cues).
import Foundation

@main
struct LiveCaptions {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("usage: live-captions <session-dir> [locale]")
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[1])
        let locale = Locale(identifier: arguments.count >= 3 ? arguments[2] : "en_US")
        do {
            let supported = await AppleSpeechCaptionProvider.supportedLocales()
            print("Supported locales: \(supported.count)")
            let session = try RecordingSession.load(from: directory)
            let start = Date()
            let track = try await CaptionService().generate(sessionDirectory: directory, session: session, locale: locale,
                                                            progress: { print(String(format: "progress %.0f%%", $0 * 100)) })
            let words = track.cues.prefix(12).map { String(format: "%@ [%.0f–%.0f ms]", $0.text, $0.startMs, $0.endMs) }
            print("Cues: \(track.cues.count) (\(track.cues.filter { $0.kind == .soundLabel }.count) sound labels) in "
                  + String(format: "%.1f s", Date().timeIntervalSince(start)))
            print("First words: \(words.joined(separator: ", "))")
            let groups = CaptionLayoutPlanner.groups(for: track, configuration: try CaptionConfiguration.load(in: directory))
            print("Lines: \(groups.count); first: \(groups.first?.text ?? "-")")
        } catch {
            print("live-captions failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
