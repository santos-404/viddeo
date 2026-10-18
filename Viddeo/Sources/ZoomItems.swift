import Foundation

/// Zoom edits use source seconds and a normalized top-left origin, like captured cursor events.
/// The reference stores milliseconds; seconds match viddeo's timeline and render contracts.
enum ZoomMode: String, Codable, Sendable, CaseIterable {
    case autoFollow
    case manual
}

struct ZoomItem: Codable, Sendable, Equatable, Identifiable {
    static let minDuration = 0.1
    static let initialDuration = 3.0

    var id = UUID()
    var sourceStart: Double
    var sourceEnd: Double
    var scale = 2.0
    var mode = ZoomMode.autoFollow
    var centerX = 0.5
    var centerY = 0.5
    var isDisabled = false
    var hasInstantAnimation = false
}

/// A missing sidecar means legacy automatic generation; an empty persisted list means no zooms.
/// Keeping this beside masks avoids changing the versioned project/timeline format.
struct ZoomItemConfiguration: Codable, Sendable, Equatable {
    static let filename = "zoom-items.json"
    var items: [ZoomItem] = []
    /// This is a collection setting, not a per-item flag in the reference. Lead-in is 350 ms.
    var startAnimationEarly = false

    func validate(duration: Double) throws {
        guard duration.isFinite, duration >= 0, Set(items.map(\.id)).count == items.count else {
            throw ZoomItemError.invalidItems
        }
        let ordered = items.sorted { $0.sourceStart < $1.sourceStart }
        var end = 0.0
        for item in ordered {
            guard [item.sourceStart, item.sourceEnd, item.scale, item.centerX, item.centerY].allSatisfy(\.isFinite),
                  item.sourceStart >= end, item.sourceEnd <= duration + 1e-9,
                  item.sourceEnd > item.sourceStart,
                  item.mode == .autoFollow || item.sourceEnd - item.sourceStart >= ZoomItem.minDuration - 1e-9,
                  (1...8).contains(item.scale), (0...1).contains(item.centerX), (0...1).contains(item.centerY)
            else { throw ZoomItemError.invalidItems }
            end = item.sourceEnd
        }
    }

    func validateForEditing(duration: Double, preservingLegacyItems: [ZoomItem] = []) throws {
        try validate(duration: duration)
        // Custom legacy automatic timing can produce shorter ranges. Only unchanged automatic
        // ranges may retain that duration; editing times or switching to manual enforces 100 ms.
        guard items.allSatisfy({ item in
            item.sourceEnd - item.sourceStart >= ZoomItem.minDuration - 1e-9
                || (item.mode == .autoFollow && preservingLegacyItems.contains {
                    $0.id == item.id && $0.mode == .autoFollow
                        && $0.sourceStart == item.sourceStart && $0.sourceEnd == item.sourceEnd
                })
        })
        else { throw ZoomItemError.invalidItems }
    }

    static func load(from directory: URL, duration: Double) throws -> Self? {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate(duration: duration)
        return result
    }

    func save(to directory: URL, duration: Double) throws {
        try validate(duration: duration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Inside an existing item, split at the playhead and make its right half manual.
    /// In free space, use up to three seconds, stopping at the next item or recording end.
    mutating func addManual(atSource time: Double, duration: Double) throws {
        guard time.isFinite, time >= 0, time < duration else { throw ZoomItemError.invalidItems }
        var result = self
        if let index = result.items.firstIndex(where: { $0.sourceStart <= time && $0.sourceEnd > time }) {
            let existing = result.items[index]
            var added = existing
            added.id = UUID()
            added.sourceStart = time
            added.mode = .manual
            added.isDisabled = false
            guard added.sourceEnd - time >= ZoomItem.minDuration else { throw ZoomItemError.invalidItems }
            if time > existing.sourceStart {
                guard time - existing.sourceStart >= ZoomItem.minDuration else { throw ZoomItemError.invalidItems }
                result.items[index].sourceEnd = time
            } else {
                result.items.remove(at: index)
            }
            result.items.append(added)
        } else {
            let end = min(duration, time + ZoomItem.initialDuration,
                          result.items.filter { $0.sourceStart > time }.map(\.sourceStart).min() ?? duration)
            guard end - time >= ZoomItem.minDuration else { throw ZoomItemError.invalidItems }
            result.items.append(ZoomItem(sourceStart: time, sourceEnd: end, mode: .manual))
        }
        result.items.sort { $0.sourceStart < $1.sourceStart }
        try result.validateForEditing(duration: duration, preservingLegacyItems: items)
        self = result
    }
}

enum ZoomItemError: LocalizedError {
    case invalidItems
    var errorDescription: String? {
        "Zooms need non-overlapping source ranges inside the recording, scale 1–8, and centers between 0 and 1. Edited zooms must last at least 0.1 seconds."
    }
}
