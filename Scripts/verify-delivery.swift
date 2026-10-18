import AppKit
import Foundation

@main
struct VerifyDelivery {
    nonisolated(unsafe) static var checks = 0

    static func main() throws {
        let policy = ExportDestinationPolicy.self

        // Sanitization.
        try expect(policy.sanitizedName("My Demo") == "My Demo", "plain name unchanged")
        try expect(policy.sanitizedName("a/b:c\\d") == "abcd", "separators stripped")
        try expect(policy.sanitizedName("  a \t  b\n c  ") == "a b c", "whitespace collapsed and trimmed")
        try expect(policy.sanitizedName("a\u{0}b\u{7}c") == "abc", "control characters dropped")
        try expect(policy.sanitizedName("") == "Viddeo Recording", "empty falls back")
        try expect(policy.sanitizedName(" / : \\ ") == "Viddeo Recording", "only-forbidden falls back")
        try expect(policy.sanitizedName("\u{1}\n\t") == "Viddeo Recording", "only-control falls back")
        try expect(policy.sanitizedName("..hidden") == "hidden", "leading dots stripped")
        try expect(policy.sanitizedName("Café ☕ Demo") == "Café ☕ Demo", "unicode kept")

        // File names: 2026-10-18 13:05:09 UTC is 15:05:09 in Berlin (CEST).
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let date = Date(timeIntervalSince1970: 1_792_328_709)
        try expect(policy.timestamp(date, timeZone: berlin) == "2026-10-18 15.05.09", "timestamp \(policy.timestamp(date, timeZone: berlin))")
        try expect(policy.timestamp(date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-18 13.05.09", "UTC timestamp")
        try expect(policy.defaultFileName(projectName: "Launch: v2/final", date: date, format: "mp4", timeZone: berlin)
                   == "Launch v2final 2026-10-18 15.05.09.mp4", "mp4 file name")
        try expect(policy.defaultFileName(projectName: "Clip", date: date, format: "gif", timeZone: berlin)
                   == "Clip 2026-10-18 15.05.09.gif", "gif file name")
        try expect(policy.defaultFileName(projectName: "//", date: date, format: "mp4", timeZone: berlin)
                   == "Viddeo Recording 2026-10-18 15.05.09.mp4", "fallback file name")
        try expect(!policy.defaultFileName(projectName: "x", date: date, format: "mp4").contains(":"), "no colon in file name")

        // Clipboard URLs.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = policy.clipboardURL(date: date, format: "mp4", baseDirectory: base, timeZone: berlin)
        try expect(first.path == base.path + "/Viddeo/Clipboard Exports/Clipboard-2026-10-18 15.05.09.mp4", "clipboard path \(first.path)")
        try expect(policy.clipboardURL(date: date, format: "gif", baseDirectory: base, timeZone: berlin).pathExtension == "gif", "clipboard gif ext")
        try expect(!FileManager.default.fileExists(atPath: base.path), "clipboardURL creates nothing")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: first)
        let second = policy.clipboardURL(date: date, format: "mp4", baseDirectory: base, timeZone: berlin)
        try expect(second.lastPathComponent == "Clipboard-2026-10-18 15.05.09 2.mp4", "uniquified 2: \(second.lastPathComponent)")
        try Data([1]).write(to: second)
        let third = policy.clipboardURL(date: date, format: "mp4", baseDirectory: base, timeZone: berlin)
        try expect(third.lastPathComponent == "Clipboard-2026-10-18 15.05.09 3.mp4", "uniquified 3")
        let defaultBase = policy.clipboardURL(date: date, format: "mp4")
        try expect(defaultBase.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                   && defaultBase.path.hasSuffix("/Viddeo/Clipboard Exports/" + defaultBase.lastPathComponent), "default base is temp dir")

        // Pasteboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("viddeo.verify.delivery.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)
        let h265 = base.appendingPathComponent("Viddeo/Clipboard Exports/Clipboard-2026-10-18 15.05.09-h265.mp4")
        try Data([2]).write(to: h265)
        try expect(ExportDelivery.copyFileReferences([first, h265], to: pasteboard), "copy returns true")
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        try expect(read.count == 2, "two file URLs read back (\(read.count))")
        try expect(read.map(\.lastPathComponent) == [first.lastPathComponent, h265.lastPathComponent], "URLs in order")
        try expect(read.allSatisfy(\.isFileURL), "file URLs")
        try expect(pasteboard.string(forType: .string) == nil, "previous contents cleared")
        try expect(ExportDelivery.copyFileReferences([first], to: pasteboard), "single copy")
        try expect((pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 1, "single URL replaces pair")
        try expect(!ExportDelivery.copyFileReferences([], to: pasteboard), "empty copy returns false")

        // Cleanup.
        let missing = base.appendingPathComponent("never-existed.mp4")
        ExportDelivery.removeIncompleteOutputs([first, h265, missing])
        try expect(!FileManager.default.fileExists(atPath: first.path)
                   && !FileManager.default.fileExists(atPath: h265.path), "incomplete outputs removed")
        try expect(FileManager.default.fileExists(atPath: second.path), "other files untouched")
        ExportDelivery.removeIncompleteOutputs([])
        ExportDelivery.removeIncompleteOutputs([first])
        try expect(true, "tolerates missing and empty input")

        // Staged replace: the chosen file is replaced only by a committed render, the new sibling appears.
        let chosen = base.appendingPathComponent("Chosen.mp4")
        let sibling = base.appendingPathComponent("Chosen-h265.mp4")
        try Data("old".utf8).write(to: chosen)
        let staging = ExportDelivery.stagingDirectory(for: chosen)
        try expect(staging.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL
                   && staging.lastPathComponent.hasPrefix(".viddeo-export-"), "hidden staging next to destination")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedMain = staging.appendingPathComponent("Chosen.mp4")
        let stagedSibling = staging.appendingPathComponent("Chosen-h265.mp4")
        try Data("new".utf8).write(to: stagedMain)
        try Data("hevc".utf8).write(to: stagedSibling)
        try ExportDelivery.commitStaged([(staged: stagedMain, final: chosen), (staged: stagedSibling, final: sibling)],
                                        staging: staging)
        try expect((try? String(contentsOf: chosen, encoding: .utf8)) == "new", "existing file replaced")
        try expect((try? String(contentsOf: sibling, encoding: .utf8)) == "hevc", "new sibling moved")
        try expect(!FileManager.default.fileExists(atPath: staging.path), "staging removed after commit")
        let failedStaging = ExportDelivery.stagingDirectory(for: chosen)
        try FileManager.default.createDirectory(at: failedStaging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: failedStaging.appendingPathComponent("Chosen.mp4"))
        ExportDelivery.removeIncompleteOutputs([failedStaging])
        try expect(!FileManager.default.fileExists(atPath: failedStaging.path)
                   && (try? String(contentsOf: chosen, encoding: .utf8)) == "new", "failed render keeps the chosen file")

        print("verify-delivery passed (\(checks) checks)")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
