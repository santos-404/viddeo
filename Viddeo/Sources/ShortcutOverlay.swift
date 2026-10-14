import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

enum ShortcutOverlayError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): "Invalid shortcut overlay settings: \(reason)"
        case .unsupportedVersion(let version): "shortcuts-config.json version \(version) is newer than this app understands."
        }
    }
}

/// Editor settings for the keyboard shortcut overlay, persisted as `shortcuts-config.json`.
/// Defaults follow the observed reference: off, size ratio 0.1, no hidden shortcuts.
struct ShortcutOverlayConfiguration: Codable, Sendable, Equatable {
    static let filename = "shortcuts-config.json"
    static let currentVersion = 1
    static let sizeRatioRange = 0.03...0.3

    var version = Self.currentVersion
    var enabled = false
    /// Key cap height as a fraction of the stage (content) height.
    var sizeRatio = 0.1
    /// Keyed by the press's first key-down time in whole source milliseconds (`ShortcutPress.hiddenKey`).
    var hiddenShortcuts: [String: Bool] = [:]
    /// Kept for parity with the observed settings. Capture never stores plain characters, so this
    /// only matters for sessions produced by other tools.
    var showSingleLetters = false

    init() {}

    private enum CodingKeys: String, CodingKey { case version, enabled, sizeRatio, hiddenShortcuts, showSingleLetters }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        sizeRatio = try container.decodeIfPresent(Double.self, forKey: .sizeRatio) ?? defaults.sizeRatio
        hiddenShortcuts = try container.decodeIfPresent([String: Bool].self, forKey: .hiddenShortcuts) ?? [:]
        showSingleLetters = try container.decodeIfPresent(Bool.self, forKey: .showSingleLetters) ?? defaults.showSingleLetters
    }

    func validate() throws {
        guard version <= Self.currentVersion else { throw ShortcutOverlayError.unsupportedVersion(version) }
        guard sizeRatio.isFinite, Self.sizeRatioRange.contains(sizeRatio) else {
            throw ShortcutOverlayError.invalidConfiguration("size ratio must be \(Self.sizeRatioRange.lowerBound)...\(Self.sizeRatioRange.upperBound)")
        }
    }

    func isHidden(_ press: ShortcutPress) -> Bool { hiddenShortcuts[press.hiddenKey] == true }

    mutating func setHidden(_ hidden: Bool, for press: ShortcutPress) {
        if hidden { hiddenShortcuts[press.hiddenKey] = true } else { hiddenShortcuts.removeValue(forKey: press.hiddenKey) }
    }

    /// Absent file means defaults.
    static func load(in directory: URL) throws -> Self {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func save(in directory: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}

/// One visual key cap. `main` is centered unless `secondary` is also present, in which case the
/// main label sits above the small secondary label (key name) at the cap's bottom.
struct ShortcutKeyCap: Sendable, Equatable {
    var main: String
    var secondary: String?
    /// Cap width as a multiple of the cap height.
    var widthRatio: Double
    /// Compact text used in the editor list.
    var glyph: String
}

/// A group of identical shortcut presses, each at most `ShortcutOverlayPlanner.groupGapMs` after the previous.
struct ShortcutPress: Sendable, Equatable, Identifiable {
    var modifiers: ShortcutModifiers
    var key: String
    var firstKeyDownMs: Double
    var lastKeyDownMs: Double
    var count: Int

    var id: String { hiddenKey }
    var hiddenKey: String { String(Int(firstKeyDownMs.rounded())) }
    var caps: [ShortcutKeyCap] { ShortcutGlyphs.caps(modifiers: modifiers, key: key) }
    /// e.g. "⌘⇧4" or "⎋".
    var glyphString: String { caps.map(\.glyph).joined() }
}

/// Immutable display interval for one press group.
struct ShortcutDisplayItem: Sendable, Equatable {
    var press: ShortcutPress
    var startMs: Double
    var endMs: Double
    var caps: [ShortcutKeyCap]

    /// Within the display interval (fades included).
    func isVisible(atMs time: Double) -> Bool { time >= startMs && time < endMs }

    /// Opacity of cap `keyIndex`: eased fade-in starting `staggerMs * keyIndex` after the item
    /// starts, and eased fade-out over the last `fadeMs` of the interval.
    func opacity(atMs time: Double, keyIndex: Int = 0) -> Double {
        guard isVisible(atMs: time) else { return 0 }
        let fadeIn = ShortcutOverlayPlanner.ease((time - startMs - ShortcutOverlayPlanner.staggerMs * Double(keyIndex))
                                                 / ShortcutOverlayPlanner.fadeMs)
        let fadeOut = ShortcutOverlayPlanner.ease((endMs - time) / ShortcutOverlayPlanner.fadeMs)
        return min(fadeIn, fadeOut)
    }
}

enum ShortcutOverlayPlanner {
    // Observed in the reference.
    static let groupGapMs = 2000.0
    static let leadMs = 100.0
    static let holdMs = 1500.0
    static let staggerMs = 60.0
    // viddeo design choice: the reference's fade durations and easing are unknown.
    static let fadeMs = 150.0

    /// Smoothstep ease-in-out of a 0...1 progress (clamped).
    static func ease(_ progress: Double) -> Double {
        let p = min(max(progress.isFinite ? progress : 0, 0), 1)
        return p * p * (3 - 2 * p)
    }

    /// A shortcut is at least one of command/option/control, or a special non-text key. Plain
    /// characters (and Space alone) only count when `showSingleLetters` is on.
    static func isShortcut(_ event: ShortcutEvent, showSingleLetters: Bool) -> Bool {
        if !event.modifiers.isDisjoint(with: .primary) { return true }
        if event.key != "space", ShortcutCapture.specialKeyNames[event.keyCode] != nil { return true }
        return showSingleLetters
    }

    /// Identical presses at most `groupGapMs` apart (measured from the previous key-down) form one group.
    static func presses(events: [ShortcutEvent], showSingleLetters: Bool = false) -> [ShortcutPress] {
        var result: [ShortcutPress] = []
        for event in events.sorted(by: { $0.time < $1.time }) where event.time.isFinite && event.time >= 0 {
            guard isShortcut(event, showSingleLetters: showSingleLetters) else { continue }
            let ms = event.time * 1000
            if let last = result.last, last.modifiers == event.modifiers, last.key == event.key,
               ms - last.lastKeyDownMs <= groupGapMs {
                result[result.count - 1].lastKeyDownMs = ms
                result[result.count - 1].count += 1
            } else {
                result.append(ShortcutPress(modifiers: event.modifiers, key: event.key, firstKeyDownMs: ms,
                                            lastKeyDownMs: ms, count: 1))
            }
        }
        return result
    }

    /// Display intervals for the non-hidden presses: from `leadMs` before the first key-down to
    /// `holdMs` after the last. Intervals never overlap (viddeo design choice): a following press
    /// cuts the previous one off at its own start, and never starts before the previous last key-down.
    static func items(events: [ShortcutEvent], configuration: ShortcutOverlayConfiguration) -> [ShortcutDisplayItem] {
        let visible = presses(events: events, showSingleLetters: configuration.showSingleLetters)
            .filter { !configuration.isHidden($0) }
        var result: [ShortcutDisplayItem] = []
        for press in visible {
            var start = press.firstKeyDownMs - leadMs
            if let previous = result.last {
                start = max(start, previous.press.lastKeyDownMs)
                result[result.count - 1].endMs = min(previous.endMs, start)
            }
            result.append(ShortcutDisplayItem(press: press, startMs: start, endMs: press.lastKeyDownMs + holdMs,
                                              caps: press.caps))
        }
        return result
    }
}

/// Glyph table. Modifier order follows the observed reference: fn, caps lock, command, option, control, shift.
enum ShortcutGlyphs {
    static let modifierOrder: [(ShortcutModifiers, glyph: String, name: String?)] = [
        (.function, "fn", nil), (.capsLock, "⇪", nil), (.command, "⌘", "command"),
        (.option, "⌥", "option"), (.control, "⌃", "control"), (.shift, "⇧", "shift")
    ]
    /// main, secondary, glyph, width ratio.
    private static let named: [String: (main: String, secondary: String?, glyph: String, width: Double)] = [
        "escape": ("⎋", "esc", "⎋", 1.33), "return": ("⏎", nil, "⏎", 1.33), "enter": ("⏎", nil, "⏎", 1.33),
        "tab": ("⇥", "tab", "⇥", 1.33), "delete": ("⌫", "delete", "⌫", 1.33), "forwardDelete": ("⌦", "del", "⌦", 1.33),
        "space": ("", "space", "␣", 1.66),
        "left": ("←", nil, "←", 1), "right": ("→", nil, "→", 1), "up": ("↑", nil, "↑", 1), "down": ("↓", nil, "↓", 1),
        "home": ("Home", nil, "Home", 0), "end": ("End", nil, "End", 0), "pageUp": ("PgUp", nil, "PgUp", 0),
        "pageDown": ("PgDn", nil, "PgDn", 0), "help": ("Help", nil, "Help", 0)
    ]

    static func caps(modifiers: ShortcutModifiers, key: String) -> [ShortcutKeyCap] {
        var caps = modifierOrder.compactMap { entry in
            modifiers.contains(entry.0) ? ShortcutKeyCap(main: entry.glyph, secondary: entry.name, widthRatio: 1, glyph: entry.glyph) : nil
        }
        caps.append(keyCap(key))
        return caps
    }

    static func keyCap(_ key: String) -> ShortcutKeyCap {
        if let entry = named[key] {
            return ShortcutKeyCap(main: entry.main, secondary: entry.secondary,
                                  widthRatio: entry.width > 0 ? entry.width : textWidthRatio(entry.main), glyph: entry.glyph)
        }
        let label = key.uppercased()
        return ShortcutKeyCap(main: label, secondary: nil, widthRatio: textWidthRatio(label), glyph: label)
    }

    /// Text-only caps (F12, Home) widen with their label; one character stays square.
    private static func textWidthRatio(_ text: String) -> Double {
        text.count <= 1 ? 1 : max(1, 0.6 + 0.2 * Double(text.count))
    }
}

/// Export-time overlay. Layout is computed per call from immutable items, so concurrent calls
/// share nothing mutable. Drawing follows `CaptionRenderer`: Core Graphics/Core Text into a
/// canvas-size sRGB bitmap.
///
/// Placement (viddeo design choice, the reference position is unknown): horizontally centered
/// in the content rect, bottom edge `bottomMarginRatio` of a cap height above the content rect's bottom.
struct ShortcutOverlayRenderer: Sendable {
    static let bottomMarginRatio = 0.6
    static let gapRatio = 0.12
    static let maxWidthFraction = 0.92

    let items: [ShortcutDisplayItem]
    let configuration: ShortcutOverlayConfiguration
    let width: Int
    let height: Int
    /// Stage rect in output space, bottom-left origin.
    let contentRect: CGRect

    init(events: [ShortcutEvent], configuration: ShortcutOverlayConfiguration, outputSize: CGSize, contentRect: CGRect) {
        let config = (try? configuration.validate()) == nil ? ShortcutOverlayConfiguration() : configuration
        self.configuration = config
        width = max(1, Int(outputSize.width.rounded()))
        height = max(1, Int(outputSize.height.rounded()))
        self.contentRect = contentRect
        items = config.enabled ? ShortcutOverlayPlanner.items(events: events, configuration: config) : []
    }

    /// The item whose interval contains `timeMs`.
    func activeItem(atMs timeMs: Double) -> ShortcutDisplayItem? {
        guard timeMs.isFinite else { return nil }
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].startMs <= timeMs { low = mid + 1 } else { high = mid }
        }
        guard low > 0, items[low - 1].isVisible(atMs: timeMs) else { return nil }
        return items[low - 1]
    }

    /// Key cap rectangles (bottom-left origin) for an item at the configured size, shrunk to fit the content width.
    func layout(for item: ShortcutDisplayItem) -> (height: Double, rects: [CGRect]) {
        var capHeight = contentRect.height * configuration.sizeRatio
        var gap = capHeight * Self.gapRatio
        let ratios = item.caps.map(\.widthRatio)
        let total = capHeight * ratios.reduce(0, +) + gap * Double(max(0, ratios.count - 1))
        let limit = contentRect.width * Self.maxWidthFraction
        if total > limit, total > 0 {
            capHeight *= limit / total
            gap = capHeight * Self.gapRatio
        }
        let rowWidth = capHeight * ratios.reduce(0, +) + gap * Double(max(0, ratios.count - 1))
        var x = contentRect.midX - rowWidth / 2
        let y = contentRect.minY + capHeight * Self.bottomMarginRatio
        var rects: [CGRect] = []
        for ratio in ratios {
            rects.append(CGRect(x: x, y: y, width: capHeight * ratio, height: capHeight))
            x += capHeight * ratio + gap
        }
        return (capHeight, rects)
    }

    /// Transparent premultiplied sRGB overlay of the output size, or nil when nothing is visible.
    func cgImage(atMs timeMs: Double) -> CGImage? {
        guard let item = activeItem(atMs: timeMs) else { return nil }
        let opacities = item.caps.indices.map { item.opacity(atMs: timeMs, keyIndex: $0) }
        guard opacities.contains(where: { $0 > 0 }) else { return nil }
        let (capHeight, rects) = layout(for: item)
        guard capHeight >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setShouldSubpixelQuantizeFonts(false)
        for (index, cap) in item.caps.enumerated() where opacities[index] > 0 {
            // A small rise while fading in (and a drop while fading out).
            let rise = (1 - opacities[index]) * capHeight * 0.2
            draw(cap, in: rects[index].offsetBy(dx: 0, dy: -rise), opacity: opacities[index], context: context, space: space)
        }
        return context.makeImage()
    }

    func image(atMs timeMs: Double) -> CIImage? {
        cgImage(atMs: timeMs).map { CIImage(cgImage: $0) }
    }

    private static func color(_ hex: UInt32, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255, alpha: alpha)
    }

    private func draw(_ cap: ShortcutKeyCap, in rect: CGRect, opacity: Double, context: CGContext, space: CGColorSpace) {
        let height = rect.height
        let radius = height * 0.22
        let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // Shadow: black, alpha 0.33 (observed), soft and slightly below the cap.
        context.setShadow(offset: CGSize(width: 0, height: -height * 0.06), blur: height * 0.2, color: Self.color(0x000000, alpha: 0.33))
        context.addPath(body)
        context.setFillColor(Self.color(0x191919))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        // Dark gradient face (#2b2b2b to #191919) and #656565 rim.
        context.saveGState()
        context.addPath(body)
        context.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [Self.color(0x2b2b2b), Self.color(0x191919)] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        context.restoreGState()
        let rim = max(1, height * 0.02)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: rim / 2, dy: rim / 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(Self.color(0x656565))
        context.setLineWidth(rim)
        context.strokePath()
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        if !cap.main.isEmpty {
            let centerY = rect.midY + (cap.secondary == nil ? 0 : height * 0.1)
            drawText(cap.main, size: height * 0.33, weight: .semibold, centerX: rect.midX, centerY: centerY, context: context)
        }
        if let secondary = cap.secondary {
            drawText(secondary, size: height * 0.225, weight: .medium, centerX: rect.midX, centerY: rect.minY + height * 0.2, context: context)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// White SF Pro text centered on a point; vertical centering uses the cap height.
    private func drawText(_ text: String, size: Double, weight: NSFont.Weight, centerX: Double, centerY: Double, context: CGContext) {
        let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: centerX - textWidth / 2, y: centerY - CTFontGetCapHeight(font) / 2)
        CTLineDraw(line, context)
    }
}
