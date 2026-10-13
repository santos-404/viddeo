import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import QuartzCore

enum ClipComparisonError: LocalizedError {
    case invalid(String)
    case noVideo(URL)
    case export(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .noVideo(let url): return "input has no video track: \(url.path)"
        case .export(let message): return "comparison export failed: \(message)"
        }
    }
}

enum ClipComparison {
    enum TimeAlignment {
        case startAtZero
        case offset
    }

    struct Options {
        var leftLabel = "Left"
        var rightLabel = "Right"
        var height = 720
        var gap = 0
        var includeAudio = false
        var timeAlignment: TimeAlignment = .startAtZero
        var rightOffset: Double = 0
        var fps = 30
        var audioSide: AudioSide = .left

        enum AudioSide { case left, right }
        init() {}
    }

    static func render(left: URL, right: URL, output: URL, options: Options = .init()) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ClipComparisonError.invalid("refusing to overwrite existing output: \(output.path)")
        }
        guard FileManager.default.fileExists(atPath: left.path) else { throw ClipComparisonError.invalid("missing input: \(left.path)") }
        guard FileManager.default.fileExists(atPath: right.path) else { throw ClipComparisonError.invalid("missing input: \(right.path)") }
        guard options.height > 0, options.height.isMultiple(of: 2) else { throw ClipComparisonError.invalid("height must be a positive even number") }
        guard options.gap >= 0, options.gap.isMultiple(of: 2), options.fps > 0 else { throw ClipComparisonError.invalid("gap must be even and nonnegative; fps must be positive") }
        guard options.rightOffset.isFinite, options.rightOffset >= 0 else { throw ClipComparisonError.invalid("right offset must be finite and nonnegative") }

        let leftAsset = AVURLAsset(url: left)
        let rightAsset = AVURLAsset(url: right)
        guard let leftTrack = try await leftAsset.loadTracks(withMediaType: .video).first else { throw ClipComparisonError.noVideo(left) }
        guard let rightTrack = try await rightAsset.loadTracks(withMediaType: .video).first else { throw ClipComparisonError.noVideo(right) }
        let leftDuration = try await leftAsset.load(.duration).seconds
        let rightDuration = try await rightAsset.load(.duration).seconds
        let offset = options.timeAlignment == .offset ? options.rightOffset : 0
        let duration = min(leftDuration, rightDuration - offset)
        guard duration > 0 else { throw ClipComparisonError.invalid("right offset leaves no overlapping video") }

        let leftSize = try await orientedSize(track: leftTrack)
        let rightSize = try await orientedSize(track: rightTrack)
        let leftNaturalWidth = evenFloor(Double(options.height) * leftSize.width / leftSize.height)
        let rightNaturalWidth = evenFloor(Double(options.height) * rightSize.width / rightSize.height)
        let panelWidth = max(2, max(leftNaturalWidth, rightNaturalWidth))
        let renderSize = CGSize(width: panelWidth * 2 + options.gap, height: options.height)

        let composition = AVMutableComposition()
        guard let compLeft = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compRight = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipComparisonError.invalid("could not create composition video tracks")
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        try compLeft.insertTimeRange(range, of: leftTrack, at: .zero)
        let rightRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600), duration: range.duration)
        try compRight.insertTimeRange(rightRange, of: rightTrack, at: .zero)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let leftLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: compLeft)
        leftLayer.setTransform(panelTransform(track: leftTrack, orientedSize: leftSize, width: panelWidth, height: options.height, x: 0), at: .zero)
        let rightLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: compRight)
        rightLayer.setTransform(panelTransform(track: rightTrack, orientedSize: rightSize, width: panelWidth, height: options.height, x: panelWidth + options.gap), at: .zero)
        instruction.layerInstructions = [rightLayer, leftLayer]
        instructions.append(instruction)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        videoComposition.instructions = instructions

        let parent = CALayer()
        let video = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        video.frame = parent.bounds
        parent.addSublayer(video)
        addLabel(options.leftLabel, frame: CGRect(x: 0, y: options.height - 48, width: panelWidth, height: 48), to: parent)
        addLabel(options.rightLabel, frame: CGRect(x: panelWidth + options.gap, y: options.height - 48, width: panelWidth, height: 48), to: parent)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)

        if options.includeAudio {
            let audioAsset = options.audioSide == .left ? leftAsset : rightAsset
            let audioOffset = options.audioSide == .right ? offset : 0
            if let audio = try await audioAsset.loadTracks(withMediaType: .audio).first,
               let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let available = try await audio.load(.timeRange)
                let start = CMTime(seconds: audioOffset, preferredTimescale: 600)
                let audioRange = CMTimeRange(start: start, duration: range.duration)
                guard CMTimeRangeGetEnd(available) >= CMTimeRangeGetEnd(audioRange) else {
                    throw ClipComparisonError.invalid("selected audio track is shorter than the comparison")
                }
                try destination.insertTimeRange(audioRange, of: audio, at: .zero)
            }
        }

        do {
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ClipComparisonError.export("could not create export session")
            }
            exporter.outputURL = output
            exporter.outputFileType = .mp4
            exporter.videoComposition = videoComposition
            exporter.timeRange = range
            exporter.shouldOptimizeForNetworkUse = false
            await exporter.export()
            guard exporter.status == .completed else { throw ClipComparisonError.export(exporter.error?.localizedDescription ?? "unknown export error") }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func evenFloor(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) & ~1) }

    private static func orientedSize(track: AVAssetTrack) async throws -> CGSize {
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        return CGSize(width: abs(bounds.width), height: abs(bounds.height))
    }

    private static func panelTransform(track: AVAssetTrack, orientedSize: CGSize, width: Int, height: Int, x: Int) -> CGAffineTransform {
        let size = track.naturalSize
        let t = track.preferredTransform
        let transformed = CGRect(origin: .zero, size: size).applying(t).standardized
        let scale = min(CGFloat(width) / orientedSize.width, CGFloat(height) / orientedSize.height)
        let dx = CGFloat(x) + (CGFloat(width) - orientedSize.width * scale) / 2 - transformed.minX * scale
        let dy = (CGFloat(height) - orientedSize.height * scale) / 2 - transformed.minY * scale
        return t.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    private static func addLabel(_ text: String, frame: CGRect, to parent: CALayer) {
        let bar = CALayer()
        bar.frame = frame
        bar.backgroundColor = CGColor(gray: 0, alpha: 0.68)
        let label = CATextLayer()
        label.string = text
        label.font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        label.fontSize = 24
        label.foregroundColor = CGColor(gray: 1, alpha: 1)
        label.alignmentMode = .center
        label.contentsScale = 2
        label.frame = CGRect(x: 12, y: 10, width: max(0, frame.width - 24), height: 30)
        bar.addSublayer(label)
        parent.addSublayer(bar)
    }
}
