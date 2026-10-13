import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Export-time caption overlay. All layout is precomputed at init; `image(at:)` only places
/// prepared lines, so concurrent calls share nothing mutable.
struct CaptionRenderer: Sendable {
    /// Core Text font and line objects are immutable and documented as safe to use from
    /// multiple threads; this box only exposes them read-only.
    private final class PreparedGroup: @unchecked Sendable {
        let group: CaptionGroup
        let lines: [CTLine]
        let widths: [Double]
        /// Start x of each word relative to the full line's left text edge.
        let offsets: [Double]
        let fullWidth: Double
        let fontSize: Double
        let ascent: Double
        let descent: Double

        init(group: CaptionGroup, font: CTFont, fontSize: Double) {
            self.group = group
            self.fontSize = fontSize
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
            func line(_ text: String) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
            }
            lines = group.words.map { line($0.text) }
            widths = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }
            let space = CTLineGetTypographicBounds(line(" "), nil, nil, nil)
            var x = 0.0
            var offsets: [Double] = []
            for width in widths {
                offsets.append(x)
                x += width + space
            }
            self.offsets = offsets
            fullWidth = max(0, x - space)
            ascent = CTFontGetAscent(font)
            descent = CTFontGetDescent(font)
        }

        var paddingX: Double { fontSize * 0.5 }
        var paddingY: Double { fontSize * 0.25 }
        var boxHeight: Double { ascent + descent + 2 * paddingY }
        var cornerRadius: Double { fontSize * 0.35 }
    }

    let configuration: CaptionConfiguration
    let width: Int
    let height: Int
    private let groups: [PreparedGroup]
    private let textColor: (red: Double, green: Double, blue: Double)
    private let backgroundColor: (red: Double, green: Double, blue: Double)

    init(track: CaptionTrack, configuration: CaptionConfiguration, outputSize: CGSize) {
        let config = (try? configuration.validate()) == nil ? CaptionConfiguration() : configuration
        self.configuration = config
        width = max(1, Int(outputSize.width.rounded()))
        height = max(1, Int(outputSize.height.rounded()))
        textColor = CaptionConfiguration.rgb(config.color) ?? (1, 1, 1)
        backgroundColor = CaptionConfiguration.rgb(config.backgroundColor) ?? (0, 0, 0)
        let baseSize = config.sizeRatio * Double(height)
        let stageWidth = Double(width) * (1 - 2 * CaptionConfiguration.stageInset)
        let groups = config.enabled ? CaptionLayoutPlanner.groups(for: track, configuration: config) : []
        self.groups = groups.map { group in
            let prepared = PreparedGroup(group: group, font: Self.font(config.font, size: baseSize), fontSize: baseSize)
            let needed = prepared.fullWidth + 2 * prepared.paddingX
            guard needed > stageWidth, needed > 0 else { return prepared }
            // Lines wider than the stage shrink rather than leave it.
            let size = baseSize * stageWidth / needed
            return PreparedGroup(group: group, font: Self.font(config.font, size: size), fontSize: size)
        }
    }

    static func font(_ family: CaptionConfiguration.Font, size: Double) -> CTFont {
        let design: NSFontDescriptor.SystemDesign = switch family {
        case .sansSerif: .default
        case .serif: .serif // New York
        case .mono: .monospaced // SF Mono
        }
        let base = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        let descriptor = base.withDesign(design) ?? base
        return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
    }

    /// Most recent group visible at `timeMs`.
    private func activeGroup(at timeMs: Double) -> PreparedGroup? {
        guard timeMs.isFinite else { return nil }
        var low = 0, high = groups.count
        while low < high {
            let mid = (low + high) / 2
            if groups[mid].group.startMs <= timeMs { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = groups[low - 1]
        return candidate.group.isVisible(at: timeMs) ? candidate : nil
    }

    /// Transparent premultiplied sRGB overlay of the output size, or nil when no caption is
    /// visible (nothing to composite).
    func cgImage(at timeMs: Double) -> CGImage? {
        guard let prepared = activeGroup(at: timeMs) else { return nil }
        let visible = prepared.group.visibleWordIndices(at: timeMs, reveal: configuration.wordsReveal)
        guard let first = visible.first, let last = visible.last else { return nil }

        // Place the box in top-left unit space inside the 10 %-inset stage, then flip to Core Graphics.
        let inset = CaptionConfiguration.stageInset
        let stageX = Double(width) * inset, stageY = Double(height) * inset
        let stageWidth = Double(width) * (1 - 2 * inset), stageHeight = Double(height) * (1 - 2 * inset)
        func boxX(forWidth boxWidth: Double) -> Double {
            stageX + configuration.position.x * max(0, stageWidth - boxWidth)
        }
        let padX = prepared.paddingX
        let fullBoxWidth = prepared.fullWidth + 2 * padX
        let visibleStart = prepared.offsets[first]
        let visibleWidth = prepared.offsets[last] + prepared.widths[last] - visibleStart
        let boxWidth: Double
        let left: Double
        /// Maps a word's full-line offset to output x.
        let textOrigin: Double
        if configuration.wordsReveal == .wordByWord {
            boxWidth = visibleWidth + 2 * padX
            left = boxX(forWidth: boxWidth)
            textOrigin = left + padX - visibleStart
        } else {
            switch configuration.effectiveLineGrowth {
            case .entireLine:
                boxWidth = fullBoxWidth
                left = boxX(forWidth: fullBoxWidth)
            case .leftAnchored:
                boxWidth = visibleWidth + 2 * padX
                left = boxX(forWidth: fullBoxWidth)
            case .centered:
                boxWidth = visibleWidth + 2 * padX
                left = boxX(forWidth: boxWidth)
            }
            textOrigin = left + padX - (configuration.effectiveLineGrowth == .entireLine ? 0 : visibleStart)
        }
        let boxHeight = prepared.boxHeight
        let top = stageY + configuration.position.y * max(0, stageHeight - boxHeight)
        let bottom = Double(height) - top - boxHeight

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setShouldSubpixelQuantizeFonts(false)

        let box = CGRect(x: left, y: bottom, width: boxWidth, height: boxHeight)
        let radius = min(prepared.cornerRadius, boxHeight / 2, boxWidth / 2)
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(srgbRed: backgroundColor.red, green: backgroundColor.green,
                                     blue: backgroundColor.blue, alpha: configuration.backgroundOpacity))
        context.fillPath()

        let baseline = bottom + prepared.paddingY + prepared.descent
        for index in visible {
            let word = prepared.group.words[index]
            let opacity = CaptionPresentation.wordOpacity(word, at: timeMs, configuration: configuration)
            guard opacity > 0 else { continue }
            let offset = CaptionPresentation.wordOffset(word, at: timeMs, configuration: configuration)
            context.setFillColor(CGColor(srgbRed: textColor.red, green: textColor.green, blue: textColor.blue, alpha: opacity))
            context.textPosition = CGPoint(x: textOrigin + prepared.offsets[index] + offset, y: baseline)
            CTLineDraw(prepared.lines[index], context)
        }
        return context.makeImage()
    }

    func image(at timeMs: Double) -> CIImage? {
        cgImage(at: timeMs).map { CIImage(cgImage: $0) }
    }
}
