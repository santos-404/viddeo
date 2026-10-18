import AppKit
import Foundation

/// Where a finished export goes. Cloud links are intentionally not offered.
enum ExportTarget: Sendable, Equatable {
    case file
    case clipboard
}

/// Progress of one export from the delivery point of view.
enum ExportPhase: Sendable, Equatable {
    case idle, rendering, delivering, completed, cancelled, failed
}

/// Destination names and locations for exports.
///
/// Screen Studio names exports `<project name> YYYY-MM-DD HH:mm:ss`. macOS Finder displays a
/// `:` in a file name as `/`, so viddeo deviates and writes the time as `HH.mm.ss`.
enum ExportDestinationPolicy {
    static let fallbackName = "Viddeo Recording"

    /// Removes path separators (`/`, `:`, `\`), control characters and leading dots, collapses
    /// whitespace runs to one space and trims. Returns `fallbackName` when nothing is left.
    static func sanitizedName(_ name: String) -> String {
        let forbidden: Set<Unicode.Scalar> = ["/", ":", "\\"]
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !forbidden.contains(scalar) {
            if scalar.properties.generalCategory == .control {
                // Tabs and newlines separate words; other controls are dropped.
                if scalar.properties.isWhitespace { scalars.append(" ") }
                continue
            }
            scalars.append(scalar)
        }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var result = Substring(words)
        while result.first == "." { result = result.dropFirst() }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallbackName : trimmed
    }

    /// `YYYY-MM-DD HH.mm.ss` in `timeZone`, Gregorian calendar and POSIX digits.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// `<sanitized name> YYYY-MM-DD HH.mm.ss.<format>`; `format` is a file extension such as `mp4` or `gif`.
    static func defaultFileName(projectName: String, date: Date, format: String,
                                timeZone: TimeZone = .current) -> String {
        "\(sanitizedName(projectName)) \(timestamp(date, timeZone: timeZone)).\(format)"
    }

    /// `<base>/Viddeo/Clipboard Exports/Clipboard-<timestamp>.<format>`, with ` 2`, ` 3`… appended to the
    /// stem while that file exists. Does not create anything on disk.
    static func clipboardURL(date: Date, format: String,
                             baseDirectory: URL = FileManager.default.temporaryDirectory,
                             timeZone: TimeZone = .current) -> URL {
        let directory = baseDirectory
            .appendingPathComponent("Viddeo", isDirectory: true)
            .appendingPathComponent("Clipboard Exports", isDirectory: true)
        let stem = "Clipboard-\(timestamp(date, timeZone: timeZone))"
        var candidate = directory.appendingPathComponent("\(stem).\(format)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter).\(format)")
            counter += 1
        }
        return candidate
    }
}

enum ExportDelivery {
    /// Replaces the pasteboard contents with file references (not movie bytes) so Finder-style
    /// pasting works in apps that accept files.
    @discardableResult
    static func copyFileReferences(_ urls: [URL], to pasteboard: NSPasteboard) -> Bool {
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0.standardizedFileURL as NSURL })
    }

    /// Deletes outputs of a failed or cancelled export. Missing files are ignored.
    static func removeIncompleteOutputs(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A hidden staging directory next to `destination` (same volume, so the final move is a rename).
    /// The exporter never overwrites, so a file export renders here and `commitStaged` replaces the
    /// user's chosen files only after the render succeeded; a failed export leaves them untouched.
    static func stagingDirectory(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".viddeo-export-\(UUID().uuidString)", isDirectory: true)
    }

    /// Moves each staged file over its final URL (replacing an existing file), then removes `staging`.
    static func commitStaged(_ pairs: [(staged: URL, final: URL)], staging: URL) throws {
        defer { try? FileManager.default.removeItem(at: staging) }
        for pair in pairs {
            if FileManager.default.fileExists(atPath: pair.final.path) {
                _ = try FileManager.default.replaceItemAt(pair.final, withItemAt: pair.staged)
            } else {
                try FileManager.default.moveItem(at: pair.staged, to: pair.final)
            }
        }
    }
}
