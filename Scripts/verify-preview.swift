import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation

/// Verifies the editor's processed preview against the exporter, with a synthetic recording:
/// same renderer (preview frame ≈ exported frame at the same scale point), unsaved edits change
/// the frame, out-of-order scrubbing returns the right source frames, reduced size keeps the aspect.
/// The fixture's moving crosshair identifies source time.
@main
@MainActor
struct VerifyPreview {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        guard condition() else { throw VerificationError.failed(message()) }
        checks += 1
    }

    static func main() async throws {
        let width = 640, height = 360
        let duration = 8.0
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-preview-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Plain session (no pointer events, so no zoom): the crosshair is a clean source-time marker.
        let plain = try await makeSession(root: root, name: "plain", width: width, height: height, duration: duration, events: [])
        // Click session: a click at 3.0 s (zoom, click ring) to exercise the full renderer.
        let clicks = try await makeSession(root: root, name: "clicks", width: width, height: height, duration: duration, events: [
            CursorEvent(time: 1.0, x: 0.25, y: 0.25, kind: .move),
            CursorEvent(time: 3.0, x: 0.75, y: 0.25, kind: .down),
            CursorEvent(time: 3.08, x: 0.75, y: 0.25, kind: .up),
            CursorEvent(time: 5.0, x: 0.75, y: 0.75, kind: .move)
        ])
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)

        try await verifyMatchesExport(session: clicks, settings: settings)
        try await verifyUnsavedEdits(session: plain, clickSession: clicks, settings: settings, duration: duration)
        try await verifyScrubbing(session: plain, settings: settings, duration: duration)
        try await verifyAspect(session: plain)
        try await verifyErrors(session: plain, settings: settings)
        print("Preview verified: \(checks) checks")
    }

    private static func makeSession(root: URL, name: String, width: Int, height: Int, duration: Double,
                                    events: [CursorEvent]) async throws -> (session: RecordingSession, directory: URL) {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await makeFixture(url: directory.appendingPathComponent("raw.mp4"), width: width, height: height, duration: duration)
        let session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height,
                                       duration: duration, events: events, droppedFrames: 0, eventCaptureAvailable: true)
        try session.save(in: directory)
        return (session, directory)
    }

    private static func preview(_ fixture: (session: RecordingSession, directory: URL), settings: ExportSettings,
                                edit: ExportEdit?, clickEffects: Bool = true,
                                width: Int = PreviewFrameRenderer.previewWidth) async throws -> PreviewFrameRenderer {
        try await PreviewFrameRenderer(session: fixture.session, directory: fixture.directory, settings: settings,
                                       edit: edit, showsClickEffects: clickEffects, previewWidth: width)
    }

    // MARK: (a) Same renderer as export

    /// A preview at the export's own size (1280 px) matches the exported MP4 frame at the same playback
    /// time; the only differences are H.264 noise and the MP4's global tone shift (removed by a per-channel fit). Different times differ far more, so the metric discriminates.
    private static func verifyMatchesExport(session fixture: (session: RecordingSession, directory: URL),
                                            settings: ExportSettings) async throws {
        var stage = StageStyle()
        stage.background = .color("#204060")
        var timeline = TimelineModel(sourceDuration: fixture.session.duration)
        try timeline.split(atSource: 4)
        let first = timeline.segments[0].id
        try timeline.setTimeScale(segmentID: first, to: 0.5)   // 2x speed over [0,4)
        var captionConfig = CaptionConfiguration()
        captionConfig.backgroundColor = "#00ffff"
        captionConfig.backgroundOpacity = 1
        let captions = CaptionTrack(locale: "en-US", cues: [CaptionCue(startMs: 1000, endMs: 3000, text: "PREVIEW")])
        let edit = ExportEdit(timeline: timeline, stage: stage, captions: (captions, captionConfig))

        let exportURL = fixture.directory.appendingPathComponent("export.mp4")
        try await OfflineExporter().export(session: fixture.session, directory: fixture.directory, destination: exportURL,
                                           settings: settings, edit: edit)
        let exported = AVURLAsset(url: exportURL)
        let renderer = try await preview(fixture, settings: settings, edit: edit, width: 1280)
        try check(renderer.width == 1280 && renderer.height == 720, "preview at the export scale is \(renderer.width)×\(renderer.height)")
        try check(abs(renderer.duration - timeline.playbackDuration) < 0.01,
                  "preview duration \(renderer.duration) differs from playback duration \(timeline.playbackDuration)")
        var cache: [Double: Pixels] = [:]
        for time in [0.0, 0.5, 1.5, 3.0, 4.2, 5.0] {
            let preview = try Pixels(await renderer.frame(atPlayback: time))
            let output = try Pixels(await exportFrame(exported, time: time))
            cache[time] = output
            let (mean, outliers) = preview.difference(to: output, calibrated: true)
            try check(mean < 4 && outliers < 0.02,
                      "preview at \(time)s differs from the export (mean \(mean), outliers \(outliers))")
        }
        // Negative control: a preview from another time is clearly different.
        let other = try Pixels(await renderer.frame(atPlayback: 0.5))
        let (controlMean, _) = other.difference(to: cache[4.2]!, calibrated: true)
        try check(controlMean > 8, "different playback times are indistinguishable (mean \(controlMean))")
        await renderer.close()
    }

    // MARK: (b) Unsaved edits change the preview

    private static func verifyUnsavedEdits(session fixture: (session: RecordingSession, directory: URL),
                                           clickSession: (session: RecordingSession, directory: URL),
                                           settings: ExportSettings, duration: Double) async throws {
        var stage = StageStyle()
        stage.background = .color("#ff0000")
        let red = try await preview(fixture, settings: settings, edit: ExportEdit(stage: stage))
        stage.background = .color("#0000ff")
        let blue = try await preview(fixture, settings: settings, edit: ExportEdit(stage: stage))
        let plain = try await preview(fixture, settings: settings, edit: nil)
        // The stage corner (padding area) shows the background color; the unstaged frame is content.
        let redCorner = try Pixels(await red.frame(atPlayback: 1)).rgb(x: 4, y: 4)
        let blueCorner = try Pixels(await blue.frame(atPlayback: 1)).rgb(x: 4, y: 4)
        let plainCorner = try Pixels(await plain.frame(atPlayback: 1)).rgb(x: 4, y: 4)
        try check(redCorner.0 > 200 && redCorner.2 < 60, "red stage corner is \(redCorner)")
        try check(blueCorner.2 > 200 && blueCorner.0 < 60, "blue stage corner is \(blueCorner)")
        try check(plainCorner != redCorner && plainCorner != blueCorner, "unstaged corner equals a stage background")
        for renderer in [red, blue, plain] { await renderer.close() }

        // Trim + reorder: keep [0,3] and [5,8], play [5,8] first. The crosshair tells the source time.
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 3)
        try timeline.split(atSource: 5)
        let middle = timeline.segments[1].id, late = timeline.segments[2].id
        try timeline.delete(segmentID: middle)
        try timeline.move(segmentID: late, toIndex: 0)
        let untouched = try await preview(fixture, settings: settings, edit: ExportEdit(timeline: TimelineModel(sourceDuration: duration)))
        let edited = try await preview(fixture, settings: settings, edit: ExportEdit(timeline: timeline))
        try check(abs(edited.duration - 6) < 0.01, "edited preview lasts \(edited.duration) s, expected 6")
        let before = try crosshairSourceTime(await untouched.frame(atPlayback: 1.3))
        let after = try crosshairSourceTime(await edited.frame(atPlayback: 1.3))
        try check(abs(before - 1.3) < 0.1 && abs(after - 6.3) < 0.1,
                  "trim/reorder: playback 1.3 s shows source \(before) unedited, \(after) edited; expected 1.3 and 6.3")
        await untouched.close()
        await edited.close()

        // The click-effect toggle changes the frame once the ring is past the fixture's own white blob (3.0-3.1 s).
        let withClicks = try await preview(clickSession, settings: settings, edit: nil, clickEffects: true)
        let withoutClicks = try await preview(clickSession, settings: settings, edit: nil, clickEffects: false)
        let ringOn = try Pixels(await withClicks.frame(atPlayback: 3.25))
        let ringOff = try Pixels(await withoutClicks.frame(atPlayback: 3.25))
        let (clickMean, _) = ringOn.difference(to: ringOff)
        try check(clickMean > 0.1, "click effects do not change the preview (mean \(clickMean))")
        await withClicks.close()
        await withoutClicks.close()
    }

    // MARK: (c) Random access and sequential speed

    private static func verifyScrubbing(session fixture: (session: RecordingSession, directory: URL),
                                        settings: ExportSettings, duration: Double) async throws {
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 3)
        try timeline.split(atSource: 5)
        let middle = timeline.segments[1].id, late = timeline.segments[2].id
        try timeline.delete(segmentID: middle)
        try timeline.move(segmentID: late, toIndex: 0)
        // Playback [0,3) shows source 5…8, [3,6) shows source 0…3.
        let edited = try await preview(fixture, settings: settings, edit: ExportEdit(timeline: timeline))
        for (playback, source) in [(5.5, 2.5), (0.5, 5.5), (4.0, 1.0), (2.0, 7.0), (3.3, 0.3), (0.2, 5.2), (5.9, 2.9), (1.3, 6.3)] {
            let measured = try crosshairSourceTime(await edited.frame(atPlayback: playback))
            try check(abs(measured - source) < 0.1, "scrub to playback \(playback) s shows source \(measured), expected \(source)")
        }
        await edited.close()

        // Without a timeline the recording plays as is, and backward scrubs still work (seekable source).
        let plain = try await preview(fixture, settings: settings, edit: nil)
        for time in [6.2, 1.0, 3.5, 0.2, 7.5, 2.2] {
            let measured = try crosshairSourceTime(await plain.frame(atPlayback: time))
            try check(abs(measured - time) < 0.1, "scrub to \(time) s shows source \(measured)")
        }
        // Sequential playback at preview size: at least 15 frames per second of render throughput.
        let count = 90
        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<count { _ = try await plain.frame(atPlayback: Double(index) / 30) }
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let fps = Double(count) / seconds
        try check(fps >= 15, "sequential preview renders \(fps) frames per second, need 15")
        print("Sequential preview throughput: \(Int(fps)) fps at \(plain.width)×\(plain.height)")
        await plain.close()
    }

    // MARK: (d) Reduced size keeps the aspect ratio

    private static func verifyAspect(session fixture: (session: RecordingSession, directory: URL)) async throws {
        let cases: [(ExportAspectRatio, Double)] = [
            (.auto, 16.0 / 9), (.preset(.square), 1), (.preset(.fourThree), 4.0 / 3), (.preset(.wide), 16.0 / 9)
        ]
        for (aspect, ratio) in cases {
            let settings = ExportSettings(fps: 30, height: 2160, codec: .h264, aspectRatio: aspect)
            let renderer = try await preview(fixture, settings: settings, edit: nil)
            try check(renderer.width == PreviewFrameRenderer.previewWidth, "preview width is \(renderer.width)")
            let actual = Double(renderer.width) / Double(renderer.height)
            try check(abs(actual - ratio) < 0.01, "preview aspect \(actual) differs from the preset's \(ratio)")
            let image = try await renderer.frame(atPlayback: 1)
            try check(image.width == renderer.width && image.height == renderer.height, "preview image is \(image.width)×\(image.height)")
            await renderer.close()
        }
    }

    // MARK: Errors are thrown, not crashes

    private static func verifyErrors(session fixture: (session: RecordingSession, directory: URL),
                                     settings: ExportSettings) async throws {
        var wrong = fixture.session
        wrong.duration = 20
        do {
            _ = try await PreviewFrameRenderer(session: wrong, directory: fixture.directory, settings: settings,
                                               edit: nil, showsClickEffects: true)
            throw VerificationError.failed("a mismatched recording duration did not throw")
        } catch is VerificationError { throw VerificationError.failed("a mismatched recording duration did not throw")
        } catch { checks += 1 }
    }

    // MARK: Helpers

    private nonisolated static func exportFrame(_ asset: AVAsset, time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// Source time of the fixture crosshair in a full-width content frame: the vertical line's x
    /// on a row near the top (source y ≈ 0.05, clear of the horizontal grid), excluding grid columns.
    private static func crosshairSourceTime(_ image: CGImage) throws -> Double {
        let pixels = try Pixels(image)
        let y = Int(0.05 * Double(pixels.height))
        var runs: [(start: Int, end: Int)] = []
        for x in 0..<pixels.width {
            let color = pixels.rgb(x: x, y: y)
            guard color.0 > 190, color.1 > 190, color.2 > 190 else { continue }
            if let last = runs.last, last.end == x - 1 { runs[runs.count - 1].end = x } else { runs.append((x, x)) }
        }
        let scale = Double(pixels.width) / 640
        let candidates = runs.map { Double($0.start + $0.end) / 2 / scale }.filter { center in
            let grid = (center / 80).rounded() * 80
            return abs(center - grid) > 5
        }
        guard candidates.count == 1 else {
            throw VerificationError.failed("expected one crosshair column, found \(candidates) among runs \(runs)")
        }
        let frame = (candidates[0] / 640 - 0.25) / 0.5 * 239
        return frame / 30
    }

    private static func makeFixture(url: URL, width: Int, height: Int, duration: Double,
                                    transform: CGAffineTransform = .identity, noise: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: noise ? 12_000_000 : 2_000_000]
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else { throw VerificationError.failed("cannot add fixture video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VerificationError.failed("writer did not start") }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * 30)
        var noiseGenerator = SystemRandomNumberGenerator()
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw writer.error ?? VerificationError.failed("fixture writer stopped")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw VerificationError.failed("writer did not create a pixel buffer pool")
            }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else {
                throw VerificationError.failed("could not allocate fixture frame")
            }
            if noise {
                paintNoise(buffer, width: width, height: height, generator: &noiseGenerator)
            } else {
                paintFixture(buffer, width: width, height: height, frameIndex: frameIndex)
            }
            let pts = CMTime(value: Int64(frameIndex), timescale: 30)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw writer.error ?? VerificationError.failed("writer rejected fixture frame")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? VerificationError.failed("fixture did not finish")
        }
    }

    private static func paintNoise(_ buffer: CVPixelBuffer, width: Int, height: Int,
                                   generator: inout SystemRandomNumberGenerator) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt64.self)
            for index in 0..<(width / 2) { row[index] = generator.next() | 0xff00_0000_ff00_0000 }
        }
    }

    private static func paintFixture(_ buffer: CVPixelBuffer, width: Int, height: Int, frameIndex: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let cursorX = Int((0.25 + 0.5 * Double(frameIndex) / 239.0) * Double(width))
        let cursorY = Int((0.25 + 0.5 * Double(frameIndex) / 239.0) * Double(height))
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let isRight = x >= width / 2
                let isBottom = y >= height / 2
                let color: (UInt8, UInt8, UInt8)
                switch (isRight, isBottom) {
                case (false, false): color = (32, 48, 230)       // blue, top-left
                case (true, false): color = (32, 220, 48)        // green, top-right
                case (false, true): color = (230, 48, 32)        // red, bottom-left
                case (true, true): color = (220, 210, 32)        // yellow, bottom-right
                }
                let isGrid = x % 80 < 2 || y % 60 < 2
                let isCrosshair = abs(x - cursorX) <= 2 || abs(y - cursorY) <= 2
                let isClick = frameIndex >= 90 && frameIndex <= 92
                    && (x - Int(0.75 * Double(width))) * (x - Int(0.75 * Double(width)))
                    + (y - Int(0.25 * Double(height))) * (y - Int(0.25 * Double(height))) < 18 * 18
                let markerDistance = hypot(Double(x - Int(0.75 * Double(width))),
                                           Double(y - Int(0.25 * Double(height))))
                let isMarker = abs(markerDistance - 20) <= 2
                let offset = x * 4
                if isMarker {
                    row[offset] = 255; row[offset + 1] = 0; row[offset + 2] = 255
                } else if isGrid || isCrosshair || isClick {
                    row[offset] = 255; row[offset + 1] = 255; row[offset + 2] = 255
                } else {
                    row[offset] = color.2; row[offset + 1] = color.1; row[offset + 2] = color.0
                }
                row[offset + 3] = 255
            }
        }
    }
}

/// 8-bit sRGB pixels (top-left origin), so frames from different decoders compare in one color space.
private struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw VerificationError.failed("could not read frame pixels") }
        self.width = width
        self.height = height
        data = bytes
    }

    func rgb(x: Int, y: Int) -> (Int, Int, Int) {
        let offset = (y * width + x) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    /// Mean absolute channel difference and the fraction of pixels with any channel off by more than 48.
    /// With `calibrated`, `other` is first mapped back through a per-channel least-squares gain and
    /// offset onto this image: the MP4 path (YCbCr range/transfer handling in the writer) shifts tone
    /// globally, which says nothing about whether the same pixels were drawn.
    func difference(to other: Pixels, calibrated: Bool = false) -> (mean: Double, outliers: Double) {
        guard width == other.width, height == other.height else { return (255, 1) }
        let count = width * height
        var gain = [Double](repeating: 1, count: 3), offset = [Double](repeating: 0, count: 3)
        if calibrated {
            for channel in 0..<3 {
                var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
                for pixel in 0..<count {
                    let x = Double(other.data[pixel * 4 + channel]), y = Double(data[pixel * 4 + channel])
                    sumX += x; sumY += y; sumXX += x * x; sumXY += x * y
                }
                let n = Double(count)
                let variance = sumXX - sumX * sumX / n
                gain[channel] = variance > 1e-6 ? (sumXY - sumX * sumY / n) / variance : 1
                offset[channel] = (sumY - gain[channel] * sumX) / n
            }
        }
        var sum = 0.0, outliers = 0
        for pixel in 0..<count {
            var worst = 0.0
            for channel in 0..<3 {
                let mapped = gain[channel] * Double(other.data[pixel * 4 + channel]) + offset[channel]
                let delta = abs(Double(data[pixel * 4 + channel]) - mapped)
                sum += delta
                worst = max(worst, delta)
            }
            if worst > 48 { outliers += 1 }
        }
        return (sum / Double(count * 3), Double(outliers) / Double(count))
    }
}

private enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let reason): reason }
    }
}
