import Foundation

/// One word-level caption cue. Times are milliseconds from the first encoded video frame,
/// matching the observed `{index,startMs,endMs,text}` cue shape; `id` replaces the index so
/// edits survive regeneration.
struct CaptionCue: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case word, soundLabel }
    var id: UUID
    var startMs: Double
    var endMs: Double
    var text: String
    var kind: Kind
    var confidence: Double?
    var edited: Bool

    init(id: UUID = UUID(), startMs: Double, endMs: Double, text: String,
         kind: Kind = .word, confidence: Double? = nil, edited: Bool = false) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.kind = kind
        self.confidence = confidence
        self.edited = edited
    }

    func overlaps(_ other: CaptionCue) -> Bool {
        startMs < other.endMs && other.startMs < endMs
    }
}

enum CaptionError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidTrack(String)
    case cueNotFound
    case invalidTiming(String)
    case emptyText
    case notAdjacent
    case invalidConfiguration(String)
    case noMicrophoneAudio
    case audioExportFailed(String)
    case unsupportedLocale(String)
    case speechUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Captions file version \(version) is newer than this version of Viddeo supports."
        case .invalidTrack(let reason): "Captions file is invalid: \(reason)."
        case .cueNotFound: "The caption cue no longer exists."
        case .invalidTiming(let reason): "Caption timing is invalid: \(reason)."
        case .emptyText: "Caption text cannot be empty."
        case .notAdjacent: "Only a caption and the caption directly after it can be merged."
        case .invalidConfiguration(let reason): "Caption settings are invalid: \(reason)."
        case .noMicrophoneAudio: "This recording has no microphone audio to caption."
        case .audioExportFailed(let reason): "Microphone audio could not be prepared for captioning: \(reason)."
        case .unsupportedLocale(let locale): "On-device speech recognition does not support \(locale)."
        case .speechUnavailable(let reason): "On-device speech recognition is unavailable: \(reason)."
        }
    }
}

struct CaptionTrack: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let filename = "captions.json"
    static let minimumCueMs = 20.0
    static let overlapToleranceMs = 1.0

    var version = CaptionTrack.currentVersion
    var locale: String
    var generator = "apple-speech"
    var cues: [CaptionCue]

    init(locale: String, generator: String = "apple-speech", cues: [CaptionCue]) {
        self.locale = locale
        self.generator = generator
        self.cues = cues
    }

    func validate() throws {
        guard version <= Self.currentVersion else { throw CaptionError.unsupportedVersion(version) }
        guard version >= 1 else { throw CaptionError.invalidTrack("version \(version)") }
        var previousStart = 0.0
        var ids = Set<UUID>()
        for cue in cues {
            guard cue.startMs.isFinite, cue.endMs.isFinite else { throw CaptionError.invalidTrack("non-finite cue time") }
            guard cue.startMs >= 0 else { throw CaptionError.invalidTrack("negative cue time") }
            guard cue.startMs < cue.endMs else { throw CaptionError.invalidTrack("cue ends before it starts") }
            guard cue.startMs >= previousStart else { throw CaptionError.invalidTrack("cues are not sorted") }
            guard cue.confidence.map({ $0.isFinite }) ?? true else { throw CaptionError.invalidTrack("non-finite confidence") }
            guard ids.insert(cue.id).inserted else { throw CaptionError.invalidTrack("duplicate cue id") }
            previousStart = cue.startMs
        }
    }

    /// Returns nil when the session has no captions yet.
    static func load(from directory: URL) throws -> Self? {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        // Check the version first so future files report a version error, not a shape error.
        struct Header: Decodable { var version: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.version <= currentVersion else { throw CaptionError.unsupportedVersion(header.version) }
        let track = try JSONDecoder().decode(Self.self, from: data)
        try track.validate()
        return track
    }

    func save(to directory: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    // MARK: Editing

    private func index(of cueID: UUID) throws -> Int {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { throw CaptionError.cueNotFound }
        return index
    }

    mutating func updateText(cueID: UUID, to text: String) throws {
        let index = try index(of: cueID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptionError.emptyText }
        cues[index].text = trimmed
        cues[index].edited = true
    }

    /// Neighbors may overlap by at most `overlapToleranceMs`; order is never changed.
    mutating func retime(cueID: UUID, start: Double, end: Double) throws {
        let index = try index(of: cueID)
        guard start.isFinite, end.isFinite, start >= 0 else { throw CaptionError.invalidTiming("times must be finite and non-negative") }
        guard end - start >= Self.minimumCueMs else { throw CaptionError.invalidTiming("cues must last at least 20 ms") }
        if index > 0 {
            let previous = cues[index - 1]
            guard start >= previous.startMs, start >= previous.endMs - Self.overlapToleranceMs else {
                throw CaptionError.invalidTiming("cue would overlap the previous caption")
            }
        }
        if index + 1 < cues.count {
            let next = cues[index + 1]
            guard start <= next.startMs, end <= next.startMs + Self.overlapToleranceMs else {
                throw CaptionError.invalidTiming("cue would overlap the next caption")
            }
        }
        cues[index].startMs = start
        cues[index].endMs = end
        cues[index].edited = true
    }

    mutating func delete(cueID: UUID) throws {
        cues.remove(at: try index(of: cueID))
    }

    /// Merges a cue with the cue directly after it; the merged cue keeps the first id.
    mutating func merge(cueID: UUID, withNext nextID: UUID) throws {
        let index = try index(of: cueID)
        guard index + 1 < cues.count, cues[index + 1].id == nextID else {
            _ = try self.index(of: nextID)
            throw CaptionError.notAdjacent
        }
        let first = cues[index], second = cues[index + 1]
        var merged = first
        merged.text = first.text + " " + second.text
        merged.endMs = max(first.endMs, second.endMs)
        merged.kind = first.kind == .soundLabel && second.kind == .soundLabel ? .soundLabel : .word
        if let a = first.confidence, let b = second.confidence { merged.confidence = min(a, b) } else { merged.confidence = nil }
        merged.edited = true
        cues[index] = merged
        cues.remove(at: index + 1)
    }

    /// Every user-edited cue survives regeneration; regenerated cues that overlap an edited
    /// cue in time are dropped so the edit replaces them. Everything else comes from `regenerated`.
    func merging(regenerated: CaptionTrack) -> CaptionTrack {
        let kept = cues.filter(\.edited)
        let fresh = regenerated.cues.filter { cue in !kept.contains { $0.overlaps(cue) } }
        var result = regenerated
        result.cues = (kept + fresh).sorted { $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs }
        return result
    }

    // MARK: Normalization

    /// Applies the observed generator rules: tokens with no leading space (after a token with
    /// no trailing space) are sub-word continuations merged into the previous word, extending
    /// its end; `[...]`/`(...)` runs become one sound-label cue. Seconds in, milliseconds out.
    static func normalize(rawWords: [(text: String, start: Double, end: Double, confidence: Double?)]) -> [CaptionCue] {
        struct Word { var text: String; var start: Double; var end: Double; var confidence: Double? }
        var words: [Word] = []
        var previousEndedWithSpace = true
        for raw in rawWords {
            guard raw.start.isFinite, raw.end.isFinite, raw.start >= 0 else { continue }
            let trimmed = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let leadingSpace = raw.text.first?.isWhitespace ?? false
            let startMs = raw.start * 1000
            let endMs = max(raw.end * 1000, startMs + 1)
            let confidence = raw.confidence.flatMap { $0.isFinite ? $0 : nil }
            if !leadingSpace, !previousEndedWithSpace, var last = words.popLast() {
                last.text += trimmed
                last.end = max(last.end, endMs)
                if let a = last.confidence, let b = confidence { last.confidence = min(a, b) }
                words.append(last)
            } else {
                words.append(Word(text: trimmed, start: startMs, end: endMs, confidence: confidence))
            }
            previousEndedWithSpace = raw.text.last?.isWhitespace ?? false
        }
        var cues: [CaptionCue] = []
        var label: Word?
        var closing: Character = "]"
        for word in words {
            if var open = label {
                open.text += " " + word.text
                open.end = max(open.end, word.end)
                if word.text.last == closing {
                    cues.append(CaptionCue(startMs: open.start, endMs: open.end, text: open.text, kind: .soundLabel, confidence: open.confidence))
                    label = nil
                } else {
                    label = open
                }
            } else if let first = word.text.first, first == "[" || first == "(" {
                closing = first == "[" ? "]" : ")"
                if word.text.count > 1, word.text.last == closing {
                    cues.append(CaptionCue(startMs: word.start, endMs: word.end, text: word.text, kind: .soundLabel, confidence: word.confidence))
                } else {
                    label = word
                }
            } else {
                cues.append(CaptionCue(startMs: word.start, endMs: word.end, text: word.text, confidence: word.confidence))
            }
        }
        if let open = label {
            // An unterminated bracket is still a label; the transcript ended mid-annotation.
            cues.append(CaptionCue(startMs: open.start, endMs: open.end, text: open.text, kind: .soundLabel, confidence: open.confidence))
        }
        return cues.sorted { $0.startMs < $1.startMs }
    }
}

// MARK: Configuration

struct CaptionConfiguration: Codable, Sendable, Equatable {
    enum Font: String, Codable, Sendable, CaseIterable { case sansSerif = "sans-serif", serif, mono }
    enum WordsReveal: String, Codable, Sendable { case lineByLine = "line-by-line", wordByWord = "word-by-word" }
    enum LineGrowth: String, Codable, Sendable { case entireLine = "entire-line", leftAnchored = "left-anchored", centered }
    enum WordEntrance: String, Codable, Sendable { case appear, fadeIn = "fade-in", slideIn = "slide-in" }
    struct Position: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
    }

    // Observed Screen Studio defaults.
    var enabled = true
    var showSoundLabels = false
    var font = Font.sansSerif
    /// Interpretation: the observed `sizeRatio` is applied to the output HEIGHT.
    var sizeRatio = 0.05
    var color = "#ffffff"
    var backgroundColor = "#000000"
    /// Unit coordinates (top-left origin) fitting the caption box inside the 10 %-inset stage.
    var position = Position(x: 0.5, y: 1.0)
    var wordsReveal = WordsReveal.lineByLine
    var lineGrowth = LineGrowth.leftAnchored
    var wordEntrance = WordEntrance.appear
    var slideInPixels = 40.0
    var fadeInStartOpacity = 0.5

    // Viddeo design parameters (the original grouping rule is unknown).
    var maxCharsPerLine = 42
    var maxLineDurationSeconds = 5.0
    var gapBreakSeconds = 0.8
    var backgroundOpacity = 0.6

    static let filename = "captions-config.json"
    static let stageInset = 0.1

    /// Growth actually used: fade-in entrance forces entire-line growth (observed).
    var effectiveLineGrowth: LineGrowth { wordEntrance == .fadeIn ? .entireLine : lineGrowth }

    func validate() throws {
        let values = [sizeRatio, position.x, position.y, slideInPixels, fadeInStartOpacity,
                      maxLineDurationSeconds, gapBreakSeconds, backgroundOpacity]
        guard values.allSatisfy(\.isFinite) else { throw CaptionError.invalidConfiguration("values must be finite") }
        guard sizeRatio > 0, sizeRatio <= 0.5 else { throw CaptionError.invalidConfiguration("size ratio must be in (0, 0.5]") }
        guard Self.rgb(color) != nil else { throw CaptionError.invalidConfiguration("text color must be #rrggbb") }
        guard Self.rgb(backgroundColor) != nil else { throw CaptionError.invalidConfiguration("background color must be #rrggbb") }
        guard (0...1).contains(position.x), (0...1).contains(position.y) else {
            throw CaptionError.invalidConfiguration("position must be within 0...1")
        }
        guard slideInPixels >= 0, slideInPixels <= 1000 else { throw CaptionError.invalidConfiguration("slide-in distance must be 0...1000 px") }
        guard (0...1).contains(fadeInStartOpacity) else { throw CaptionError.invalidConfiguration("fade-in start opacity must be 0...1") }
        guard (1...500).contains(maxCharsPerLine) else { throw CaptionError.invalidConfiguration("max characters per line must be 1...500") }
        guard maxLineDurationSeconds > 0, maxLineDurationSeconds <= 60 else {
            throw CaptionError.invalidConfiguration("max line duration must be in (0, 60] seconds")
        }
        guard gapBreakSeconds >= 0, gapBreakSeconds <= 60 else { throw CaptionError.invalidConfiguration("gap break must be 0...60 seconds") }
        guard (0...1).contains(backgroundOpacity) else { throw CaptionError.invalidConfiguration("background opacity must be 0...1") }
    }

    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Parses `#rrggbb` into 0...1 components.
    static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.first == "#" else { return nil }
        let digits = hex.dropFirst()
        guard digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }
}

// MARK: Layout and presentation

/// One display line. Words are cues in time order; a group is visible from its first word
/// start (inclusive) to its last word end (exclusive).
struct CaptionGroup: Sendable, Equatable {
    var words: [CaptionCue]
    var startMs: Double { words.first?.startMs ?? 0 }
    var endMs: Double { words.last?.endMs ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }

    func isVisible(at timeMs: Double) -> Bool {
        !words.isEmpty && timeMs >= startMs && timeMs < endMs
    }

    /// Number of words whose start is at or before `timeMs` (binary search on start time).
    func presentWordCount(at timeMs: Double) -> Int {
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].startMs <= timeMs { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Indices of words drawn at `timeMs`: all started words, or only the current word
    /// when revealing word by word.
    func visibleWordIndices(at timeMs: Double, reveal: CaptionConfiguration.WordsReveal) -> Range<Int> {
        guard isVisible(at: timeMs) else { return 0..<0 }
        let count = presentWordCount(at: timeMs)
        guard count > 0 else { return 0..<0 }
        return reveal == .wordByWord ? (count - 1)..<count : 0..<count
    }
}

enum CaptionPresentation {
    private static func progress(_ word: CaptionCue, at timeMs: Double) -> Double {
        guard word.endMs > word.startMs else { return timeMs >= word.startMs ? 1 : 0 }
        return min(1, max(0, (timeMs - word.startMs) / (word.endMs - word.startMs)))
    }

    /// appear: 0 before start, 1 after. fade-in: start opacity → 1 across the word span.
    static func wordOpacity(_ word: CaptionCue, at timeMs: Double, configuration: CaptionConfiguration) -> Double {
        guard timeMs >= word.startMs else { return 0 }
        guard configuration.wordEntrance == .fadeIn else { return 1 }
        let start = configuration.fadeInStartOpacity
        return start + (1 - start) * progress(word, at: timeMs)
    }

    /// slide-in: horizontal offset in output pixels, `slideInPixels` → 0 across the word span.
    static func wordOffset(_ word: CaptionCue, at timeMs: Double, configuration: CaptionConfiguration) -> Double {
        guard configuration.wordEntrance == .slideIn, timeMs >= word.startMs else { return 0 }
        return configuration.slideInPixels * (1 - progress(word, at: timeMs))
    }
}

enum CaptionLayoutPlanner {
    /// Viddeo design: a new line starts after a gap > `gapBreakSeconds`, after sentence-final
    /// punctuation, or when the line would exceed `maxCharsPerLine` / `maxLineDurationSeconds`.
    /// Sound labels are their own lines and are excluded unless `showSoundLabels`.
    static func groups(for track: CaptionTrack, configuration: CaptionConfiguration) -> [CaptionGroup] {
        groups(for: track.cues, configuration: configuration)
    }

    static func groups(for cues: [CaptionCue], configuration: CaptionConfiguration) -> [CaptionGroup] {
        let gapMs = configuration.gapBreakSeconds * 1000
        let maxDurationMs = configuration.maxLineDurationSeconds * 1000
        var groups: [CaptionGroup] = []
        var current: [CaptionCue] = []
        var characters = 0
        func flush() {
            if !current.isEmpty { groups.append(CaptionGroup(words: current)) }
            current = []
            characters = 0
        }
        for cue in cues.sorted(by: { $0.startMs < $1.startMs }) {
            guard cue.startMs.isFinite, cue.endMs.isFinite, cue.endMs > cue.startMs, !cue.text.isEmpty else { continue }
            if cue.kind == .soundLabel {
                guard configuration.showSoundLabels else { continue }
                flush()
                current = [cue]
                flush()
                continue
            }
            if let last = current.last, let first = current.first {
                let joined = characters + 1 + cue.text.count
                if cue.startMs - last.endMs > gapMs || endsSentence(last.text) ||
                    joined > configuration.maxCharsPerLine || cue.endMs - first.startMs > maxDurationMs {
                    flush()
                }
            }
            characters = current.isEmpty ? cue.text.count : characters + 1 + cue.text.count
            current.append(cue)
        }
        flush()
        return groups
    }

    static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        guard let last = text.reversed().first(where: { !closers.contains($0) }) else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }
}
