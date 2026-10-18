import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

@main
struct VerifyExport {
    static func main() async throws {
        let width = 640
        let height = 360
        let duration = 8.0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-export-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawURL = directory.appendingPathComponent("raw.mp4")
        let outputURL = directory.appendingPathComponent("export.mp4")
        try await makeFixture(url: rawURL, width: width, height: height, duration: duration)
        try await addAudioTracks(to: rawURL, directory: directory, duration: duration)

        let session = RecordingSession(
            id: UUID(),
            createdAt: Date(),
            displayID: 1,
            width: width,
            height: height,
            duration: duration,
            events: [
                CursorEvent(time: 1.0, x: 0.25, y: 0.25, kind: .move),
                CursorEvent(time: 3.0, x: 0.75, y: 0.25, kind: .down),
                CursorEvent(time: 3.08, x: 0.75, y: 0.25, kind: .up),
                CursorEvent(time: 5.0, x: 0.75, y: 0.75, kind: .move)
            ],
            droppedFrames: 0,
            eventCaptureAvailable: true
        )
        try session.save(in: directory)
        // The default preset is 720p, so this 640×360 fixture is upscaled 2× to 1280×720.
        // Relative checks (marker ratio, center color, edges) are resolution independent.
        let defaultSettings = ExportSettings.mp4Default
        let expectedSize = defaultSettings.outputSize(sourceWidth: width, sourceHeight: height)
        guard expectedSize == (1280, 720) else {
            throw VerificationError.failed("default preset size is \(expectedSize), expected 1280×720")
        }
        try await OfflineExporter().export(session: session, directory: directory, destination: outputURL,
                                           settings: defaultSettings)

        let outputAsset = AVURLAsset(url: outputURL)
        let outDuration = try await outputAsset.load(.duration).seconds
        guard abs(outDuration - duration) < 0.2 else {
            throw VerificationError.failed("duration is \(outDuration)s, expected \(duration)s")
        }
        let tracks = try await outputAsset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VerificationError.failed("export has no video track") }
        let naturalSize = try await track.load(.naturalSize)
        guard Int(naturalSize.width.rounded()) == expectedSize.width,
              Int(naturalSize.height.rounded()) == expectedSize.height else {
            throw VerificationError.failed("export dimensions are \(naturalSize), expected \(expectedSize.width)×\(expectedSize.height)")
        }
        let defaultRate = try await track.load(.nominalFrameRate)
        guard abs(Double(defaultRate) - 60) < 1.5 else {
            throw VerificationError.failed("default export frame rate is \(defaultRate), expected 60")
        }
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 2 else {
            throw VerificationError.failed("export has \(audioTracks.count) audio tracks; expected both source tracks")
        }
        for (index, audioTrack) in audioTracks.enumerated() {
            let range = try await audioTrack.load(.timeRange)
            guard abs(range.start.seconds) < 0.05,
                  abs(range.duration.seconds - duration) < 0.2 else {
                throw VerificationError.failed("audio track \(index) is not aligned to video: \(range)")
            }
        }
        let measuredFrequencies = try await decodedFrequencyPeaks(asset: outputAsset, tracks: audioTracks)
        guard measuredFrequencies.contains(where: { abs($0 - 440) < 35 }),
              measuredFrequencies.contains(where: { abs($0 - 880) < 45 }) else {
            throw VerificationError.failed("export audio frequencies \(measuredFrequencies) do not preserve the two distinct fixture tones")
        }
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first,
              CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264 else {
            throw VerificationError.failed("export video codec is not H.264")
        }

        let timeline = ZoomTimeline(session: session)
        let sampleTime = 3.5
        let expectedFrame = timeline.frame(at: sampleTime)
        guard abs(expectedFrame.scale - 2) < 0.05,
              abs(expectedFrame.centerX - 0.75) < 0.08,
              abs(expectedFrame.centerY - 0.25) < 0.08 else {
            throw VerificationError.failed(
                "fixture click did not settle near the expected 2× top-right crop "
                    + "(scale \(expectedFrame.scale), center \(expectedFrame.centerX),\(expectedFrame.centerY))"
            )
        }

        // The event is at (.75,.25), so a 2x crop should show the top-right quadrant
        // at output center. The fixture's four saturated regions survive H.264 well.
        let sourceCenter = colorQuadrant(
            x: expectedFrame.centerX,
            y: expectedFrame.centerY
        )
        let outputCenter = try await centerColor(asset: outputAsset, time: sampleTime)
        guard outputCenter.matches(sourceCenter) else {
            throw VerificationError.failed(
                "output center color \(outputCenter) does not match selected source region \(sourceCenter)"
            )
        }

        // A unique ring at the event location doubles in pixel diameter under 2x zoom.
        // Compare its measured dimensions against the same marker in the unzoomed frame.
        let baselineMarker = try await markerBounds(asset: outputAsset, time: 0.5)
        let zoomMarker = try await markerBounds(asset: outputAsset, time: sampleTime)
        let markerRatioX = Double(zoomMarker.width) / Double(baselineMarker.width)
        let markerRatioY = Double(zoomMarker.height) / Double(baselineMarker.height)
        guard (1.65...2.35).contains(markerRatioX), (1.65...2.35).contains(markerRatioY) else {
            throw VerificationError.failed(
                "marker scale measured \(markerRatioX)×\(markerRatioY), expected about 2×"
            )
        }

        // Ensure all four output edges remain filled before, during, and after the zoom.
        for time in [0.5, sampleTime, 7.8] {
            for point in [(0.03, 0.03), (0.97, 0.03), (0.03, 0.97), (0.97, 0.97)] {
                let pixel = try await sampleColor(asset: outputAsset, time: time, x: point.0, y: point.1)
                guard Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) > 100 else {
                    throw VerificationError.failed("blank or black border near \(point) at \(time)s")
                }
            }
        }
        let finalFrame = timeline.frame(at: 7.8)
        guard finalFrame.scale < 1.1 else {
            throw VerificationError.failed("zoom did not return toward 1× by 7.8s (\(finalFrame.scale))")
        }

        // A rotated track is rejected with an explicit limitation until AVFoundation's
        // filter-request orientation behavior is validated for that source type.
        let rotatedURL = directory.appendingPathComponent("rotated.mp4")
        try await makeFixture(url: rotatedURL, width: width, height: height, duration: 2,
                              transform: CGAffineTransform(rotationAngle: .pi / 2))
        let rotatedSession = RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height,
            duration: 2, events: [], droppedFrames: 0, eventCaptureAvailable: false
        )
        var rotatedSessionWithFilename = rotatedSession
        rotatedSessionWithFilename.videoFilename = "rotated.mp4"
        do {
            try await OfflineExporter().export(
                session: rotatedSessionWithFilename, directory: directory,
                destination: directory.appendingPathComponent("rotated-export.mp4")
            )
            throw VerificationError.failed("rotated source track was unexpectedly accepted")
        } catch OfflineExporter.ExportError.unsupportedOrientation {
            // Expected limitation.
        }

        // Ensure the destination is protected from accidental overwrite.
        do {
            try await OfflineExporter().export(session: session, directory: directory, destination: outputURL)
            throw VerificationError.failed("export unexpectedly overwrote an existing destination")
        } catch is OfflineExporter.ExportError {
            // Expected refusal.
        }

        var unsafeSession = session
        unsafeSession.videoFilename = "../raw.mp4"
        do {
            try await OfflineExporter().export(
                session: unsafeSession, directory: directory,
                destination: directory.appendingPathComponent("unsafe-export.mp4")
            )
            throw VerificationError.failed("path traversal in videoFilename was accepted")
        } catch OfflineExporter.ExportError.invalidSession {
            // Expected refusal before opening media outside the session directory.
        }

        var mismatchedSession = session
        mismatchedSession.duration -= 1
        do {
            try await OfflineExporter().export(
                session: mismatchedSession, directory: directory,
                destination: directory.appendingPathComponent("mismatch-export.mp4")
            )
            throw VerificationError.failed("session/media duration mismatch was accepted")
        } catch OfflineExporter.ExportError.durationMismatch {
            // Expected strict duration check.
        }

        try await verifyPresets(session: session, directory: directory, duration: duration)
        try await verifyGIF(session: session, directory: directory, duration: duration)
        try await verifyEdits(root: directory, width: width, height: height, duration: duration)
        try await verifyAudioMix(root: directory, width: width, height: height, duration: duration)
        try await verifyWebcam(root: directory, width: width, height: height, duration: duration)
        try await verifyShortcuts(root: directory, width: width, height: height, duration: duration)
        try await verifyMasks(root: directory, width: width, height: height, duration: duration)

        try await verifyScreenMotionBlur(session: session, directory: directory)
        try await verifyRenderedCursor(session: session, directory: directory)
        print("Offline export verified: H.264, \(expectedSize.width)×\(expectedSize.height) from \(width)×\(height), \(outDuration)s, two synced audio tracks, 2× marker scale, filled edges; edits: trim/split/reorder, 2× slow-down, per-segment audio, stage, source-time captions, edited GIF, ExportEdit.load; audio mix (master volume, mute, microphone cleanup, click-sound track, looping/fading background music, single-track mixdown with limiter and loudness target); camera overlay (offset, hold, trim/reorder, hide, full-screen, GIF); split-screen (direction, flip, ratio, stage gap), timed layout items, cutout (fallback, cached, injected mask); rendered cursor, typing and segment hiding; screen motion blur (smear during zoom, identity when stationary, none across a cut, speed ramp, stage); keyboard shortcut overlay (place, time window, off by default, ExportEdit.load); masks (sensitive-data blur and highlight dim inside their time range only, following a 2× zoom, masks.json via ExportEdit.load and the exporter fallback).")
    }

    /// Screen / zoom motion blur through the real renderer. The click at 3.0 s starts a fast zoom-in
    /// (from 2.7 s). Against the amount-0 render of the same frame: the zoom frames are smeared, a
    /// stationary frame is byte-identical, and a frame at a segment boundary is identical because
    /// the shutter never reaches across a cut. Also prints export time with and without blur.
    private static func verifyScreenMotionBlur(session: RecordingSession, directory: URL) async throws {
        let settings = ExportSettings(fps: 60, height: 720)
        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        struct Rig { var prepared: OfflineExporter.PreparedRender; var frames: ExportFrameSource }
        func rig(amount: Double, edit base: ExportEdit = ExportEdit()) async throws -> Rig {
            var edit = base
            edit.motionBlurAmount = amount
            let prepared = try await OfflineExporter.makeRenderer(
                session: session, directory: directory, settings: settings, edit: edit, showsClickEffects: false)
            let frames = try await ExportFrameSource(asset: AVURLAsset(url: prepared.sourceURL), duration: prepared.sourceDuration,
                                                     timeline: prepared.renderer.edit, seekable: true)
            return Rig(prepared: prepared, frames: frames)
        }
        func pixels(_ rig: Rig, playback: Double) throws -> [UInt8] {
            let renderer = rig.prepared.renderer
            let time = renderer.sourceTime(forPlaybackTime: playback)
            guard let source = try rig.frames.image(atSource: time) else { throw VerificationError.failed("no source frame") }
            let image = renderer.image(source: source, at: time, beforeTime: renderer.previousSourceTime(forPlaybackTime: playback))
            let rowBytes = renderer.outputWidth * 4
            var bytes = [UInt8](repeating: 0, count: rowBytes * renderer.outputHeight)
            context.render(image, toBitmap: &bytes, rowBytes: rowBytes, bounds: renderer.outputRect, format: .RGBA8, colorSpace: colorSpace)
            return bytes
        }
        func changed(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var count = 0
            for pixel in 0..<(a.count / 4) {
                let i = pixel * 4
                if abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) > 24 { count += 1 }
            }
            return count
        }
        func mean(_ a: [UInt8]) -> Double {
            Double(stride(from: 0, to: a.count, by: 4).reduce(0) { $0 + Int(a[$1]) + Int(a[$1 + 1]) + Int(a[$1 + 2]) }) / Double(a.count / 4 * 3)
        }
        func compare(edit: ExportEdit, label: String, stationary: [Double], cutPlayback: Double?) async throws {
            let sharp = try await rig(amount: 0, edit: edit), blurred = try await rig(amount: 1, edit: edit)
            for time in stationary where try pixels(sharp, playback: time) != pixels(blurred, playback: time) {
                throw VerificationError.failed("\(label): stationary frame at \(time) s differs with motion blur on")
            }
            var peak = 0, peakTime = 0.0
            for index in 0...40 {
                let time = 2.9 + Double(index) / 60
                let difference = changed(try pixels(sharp, playback: time), try pixels(blurred, playback: time))
                if difference > peak { peak = difference; peakTime = time }
            }
            guard peak > 2000 else { throw VerificationError.failed("\(label): zoom-in motion blur changed only \(peak) pixels") }
            let a = try pixels(sharp, playback: peakTime), b = try pixels(blurred, playback: peakTime)
            guard abs(mean(a) - mean(b)) < 20 else { throw VerificationError.failed("\(label): blurred frame brightness drifted (\(mean(a)) vs \(mean(b)) at \(peakTime), \(peak) px changed)") }
            if let cutPlayback {
                guard blurred.prepared.renderer.previousSourceTime(forPlaybackTime: cutPlayback) == nil,
                      try pixels(sharp, playback: cutPlayback) == pixels(blurred, playback: cutPlayback) else {
                    throw VerificationError.failed("\(label): the frame at the cut was blurred across it")
                }
            }
        }
        try await compare(edit: ExportEdit(), label: "plain", stationary: [0.5, 7.5], cutPlayback: nil)
        var stage = StageStyle()
        stage.shadow.intensity = 0
        stage.background = .color("#ff8000")
        try await compare(edit: ExportEdit(stage: stage), label: "stage", stationary: [0.5, 7.5], cutPlayback: nil)

        // A cut in the middle of the zoom: playback 3.0 s is the first frame of the second segment.
        var cut = TimelineModel(sourceDuration: session.duration)
        try cut.split(atSource: 3)
        try await compare(edit: ExportEdit(timeline: cut), label: "cut", stationary: [0.5, 7.5], cutPlayback: 3)
        let control = try await rig(amount: 1), controlSharp = try await rig(amount: 0)
        let controlDifference = changed(try pixels(control, playback: 3.05), try pixels(controlSharp, playback: 3.05))
        guard control.prepared.renderer.previousSourceTime(forPlaybackTime: 3.05) != nil, controlDifference > 2000 else {
            throw VerificationError.failed("the uncut control frame was not blurred (\(controlDifference) px)")
        }
        // Speed ramp: the before-time is the previous OUTPUT frame mapped through the edit, so a 2x
        // segment looks 2/60 s back in source time.
        var fast = cut
        try fast.setTimeScale(segmentID: fast.segments[1].id, to: 0.5)
        let fastRig = try await rig(amount: 1, edit: ExportEdit(timeline: fast))
        let renderer = fastRig.prepared.renderer
        guard let before = renderer.previousSourceTime(forPlaybackTime: 3.1),
              abs(renderer.sourceTime(forPlaybackTime: 3.1) - before - 2.0 / 60) < 1e-9 else {
            throw VerificationError.failed("speed ramp before-time is not one output frame earlier in source time")
        }

        // Export cost of the blur at 60 fps, 1280x720: the whole 8 s fixture (the zoom moves for about
        // a second of it) and the 0.8 s around the zoom-in alone (every frame moving).
        var zoomOnly = TimelineModel(sourceDuration: session.duration)
        try zoomOnly.trim(segmentID: zoomOnly.segments[0].id, newStart: 2.8, newEnd: 3.6)
        func exportSeconds(_ amount: Double, _ timeline: TimelineModel?, _ name: String) async throws -> Double {
            let destination = directory.appendingPathComponent("blur-time-\(name)-\(amount).mp4")
            defer { try? FileManager.default.removeItem(at: destination) }
            let start = ContinuousClock.now
            try await OfflineExporter().export(session: session, directory: directory, destination: destination,
                                              showsClickEffects: false, settings: settings,
                                              edit: ExportEdit(timeline: timeline, motionBlurAmount: amount))
            let parts = (ContinuousClock.now - start).components
            return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
        }
        var timings: [String] = []
        for (name, timeline) in [("8 s", nil), ("0.8 s zoom-in", zoomOnly)] as [(String, TimelineModel?)] {
            var off = Double.infinity, on = Double.infinity
            for _ in 0..<2 {
                off = min(off, try await exportSeconds(0, timeline, name))
                on = min(on, try await exportSeconds(1, timeline, name))
            }
            timings.append("\(name): off \(String(format: "%.2f", off)) s, on \(String(format: "%.2f", on)) s")
        }
        print("Screen motion blur export time (60 fps, 1280x720, best of 2): " + timings.joined(separator: "; "))
    }

    @MainActor
    private static func verifyRenderedCursor(session: RecordingSession, directory: URL) async throws {
        var session = session
        session.cursorEmbedded = false
        session.events = [CursorEvent(time: 0, x: 0.1, y: 0.1, kind: .move)]
        session.keystrokes = [KeystrokeEvent(time: 0.5), KeystrokeEvent(time: 0.7), KeystrokeEvent(time: 0.9)]
        var config = CursorConfiguration()
        config.size = 96
        try config.save(in: directory)
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("cursor-config.json")) }
        var timeline = TimelineModel(sourceDuration: session.duration)
        let hidden = try timeline.split(atSource: 4)
        try timeline.setHideCursor(segmentID: hidden, to: true)
        let destination = directory.appendingPathComponent("rendered-cursor.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: destination,
                                          showsClickEffects: false, settings: ExportSettings(fps: 15, height: 720),
                                          edit: ExportEdit(timeline: timeline))
        let asset = AVURLAsset(url: destination)
        for (time, visible) in [(0.2, true), (1.4, false), (3.5, true), (5.0, false)] {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let rep = NSBitmapImageRep(cgImage: image)
            var white = 0
            // No fixture grid/crosshair falls in this small region around the cursor.
            for y in Int(0.1 * Double(rep.pixelsHigh))..<Int(0.16 * Double(rep.pixelsHigh)) {
                for x in Int(0.1 * Double(rep.pixelsWide))..<Int(0.12 * Double(rep.pixelsWide)) {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.8, color.greenComponent > 0.8, color.blueComponent > 0.8 { white += 1 }
                }
            }
            guard visible ? white > 20 : white == 0 else {
                throw VerificationError.failed("rendered cursor at \(time)s has \(white) white pixels; expected visible=\(visible)")
            }
        }
        try await verifyCursorMotionBlur(session: session, directory: directory)
    }

    /// A cursor jumping across the frame leaves a trail behind its direction of motion at motion blur
    /// amount 1 and nothing at amount 0. Frames are compared against an export with the cursor
    /// hidden, so the fixture background cancels out.
    private static func verifyCursorMotionBlur(session: RecordingSession, directory: URL) async throws {
        var session = session
        session.cursorEmbedded = false
        session.keystrokes = nil
        // Step-held jump from x 0.1 to 0.5 at 1 s. At 15 fps the trail strength is 0.25, so the frames
        // within one frame of the jump carry a trail of a quarter of the jump ending at x 0.5.
        session.events = [CursorEvent(time: 0, x: 0.1, y: 0.1, kind: .move),
                          CursorEvent(time: 1, x: 0.5, y: 0.1, kind: .move),
                          CursorEvent(time: 2, x: 0.5, y: 0.1, kind: .move)]
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("cursor-config.json")) }
        func export(amount: Double, hide: Bool) async throws -> AVURLAsset {
            var config = CursorConfiguration()
            config.size = 96
            config.smoothing = false
            config.removeShakeThresholdPx = 0   // the jump is intentional
            config.hide = hide
            config.motionBlurAmount = amount
            try config.save(in: directory)
            let destination = directory.appendingPathComponent("blur-\(amount)-\(hide).mp4")
            try await OfflineExporter().export(session: session, directory: directory, destination: destination,
                                              showsClickEffects: false, settings: ExportSettings(fps: 15, height: 720))
            return AVURLAsset(url: destination)
        }
        func frame(_ asset: AVURLAsset, _ index: Int) async throws -> NSBitmapImageRep {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return NSBitmapImageRep(cgImage: try await generator.image(at: CMTime(value: CMTimeValue(index * 40), timescale: 600)).image)
        }
        /// Pixels inside the fractional box that differ from the hidden-cursor frame.
        func changed(_ rep: NSBitmapImageRep, _ base: NSBitmapImageRep, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Int {
            var count = 0
            for py in Int(y.lowerBound * Double(rep.pixelsHigh))..<Int(y.upperBound * Double(rep.pixelsHigh)) {
                for px in Int(x.lowerBound * Double(rep.pixelsWide))..<Int(x.upperBound * Double(rep.pixelsWide)) {
                    guard let a = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                          let b = base.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                        + abs(a.blueComponent - b.blueComponent) > 0.3 { count += 1 }
                }
            }
            return count
        }
        let hiddenAsset = try await export(amount: 1, hide: true)
        let blurredAsset = try await export(amount: 1, hide: false)
        let sharpAsset = try await export(amount: 0, hide: false)
        var trail = 0, sharp = 0, ahead = 0
        for index in 14...19 {   // 15 fps frames from 0.93 s to 1.27 s
            let base = try await frame(hiddenAsset, index)
            let blurred = try await frame(blurredAsset, index)
            let still = try await frame(sharpAsset, index)
            // The arrow body lies right of each stamp's tip, so x 0.41...0.48 is covered by the trail only.
            trail = max(trail, changed(blurred, base, x: 0.41...0.48, y: 0.1...0.2))
            sharp = max(sharp, changed(still, base, x: 0.41...0.48, y: 0.1...0.2))
            ahead = max(ahead, changed(blurred, base, x: 0.56...0.62, y: 0.1...0.2))
        }
        guard trail > 150, sharp < 10 else {
            throw VerificationError.failed("cursor motion blur trail changed \(trail) pixels at amount 1 and \(sharp) at amount 0")
        }
        guard ahead < 10 else { throw VerificationError.failed("cursor trail extends ahead of its motion (\(ahead) pixels)") }
    }

    private static func verifyPresets(session: RecordingSession, directory: URL, duration: Double) async throws {
        // (a) 1080p / 30 fps / HEVC.
        let hevcURL = directory.appendingPathComponent("hevc-1080p30.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: hevcURL,
                                           settings: ExportSettings(fps: 30, height: 1080, codec: .h265))
        let hevc = try await probe(hevcURL)
        guard hevc.codec == kCMVideoCodecType_HEVC, hevc.width == 1920, hevc.height == 1080,
              abs(hevc.fps - 30) < 1, abs(hevc.duration - duration) < 0.2, hevc.audioTracks == 2 else {
            throw VerificationError.failed("1080p30 HEVC export probed as \(hevc)")
        }

        // (b) `both` writes the H.264 file and an -h265 sibling, refusing if either exists.
        let bothDirectory = directory.appendingPathComponent("both", isDirectory: true)
        try FileManager.default.createDirectory(at: bothDirectory, withIntermediateDirectories: true)
        let socialSettings = ExportSettings(quality: .socialMedia, fps: 30, height: 720, codec: .both)
        let bothURL = bothDirectory.appendingPathComponent("export.mp4")
        let written = try await OfflineExporter().export(session: session, directory: directory,
                                                         destination: bothURL, settings: socialSettings)
        let h265URL = bothDirectory.appendingPathComponent("export-h265.mp4")
        guard written.map(\.lastPathComponent) == ["export.mp4", "export-h265.mp4"] else {
            throw VerificationError.failed("both-codec export returned \(written)")
        }
        let bothH264 = try await probe(bothURL)
        let bothHEVC = try await probe(h265URL)
        guard bothH264.codec == kCMVideoCodecType_H264, bothHEVC.codec == kCMVideoCodecType_HEVC,
              bothH264.width == 1280, bothHEVC.width == 1280, bothH264.height == 720, bothHEVC.height == 720,
              bothH264.audioTracks == 2, bothHEVC.audioTracks == 2 else {
            throw VerificationError.failed("both-codec outputs probed as \(bothH264) and \(bothHEVC)")
        }
        // Destination itself exists.
        do {
            try await OfflineExporter().export(session: session, directory: directory,
                                               destination: bothURL, settings: socialSettings)
            throw VerificationError.failed("both-codec export overwrote an existing H.264 destination")
        } catch OfflineExporter.ExportError.outputExists {}
        // Only the -h265 sibling exists: nothing may be written.
        let againURL = bothDirectory.appendingPathComponent("again.mp4")
        let againH265 = bothDirectory.appendingPathComponent("again-h265.mp4")
        try Data("keep".utf8).write(to: againH265)
        do {
            try await OfflineExporter().export(session: session, directory: directory,
                                               destination: againURL, settings: socialSettings)
            throw VerificationError.failed("both-codec export overwrote an existing -h265 destination")
        } catch OfflineExporter.ExportError.outputExists {}
        let leftovers = try await directoryAfterWriterCleanup(bothDirectory).sorted()
        guard leftovers == ["again-h265.mp4", "export-h265.mp4", "export.mp4"],
              try Data(contentsOf: againH265) == Data("keep".utf8) else {
            throw VerificationError.failed("refused both-codec export left \(leftovers)")
        }

        // (c) Bitrate follows the observed bits-per-pixel model. Rate control treats the value as
        // a ceiling-ish target: ordinary content must not overshoot it, and the quality tiers must
        // order by the model. (Incompressible per-frame noise was rejected as a fixture: no encoder
        // can meet a 1.4 Mb/s target on it, which says nothing about the exporter.)
        var rates: [ExportQuality: Double] = [:]
        for quality in [ExportQuality.webLow, .socialMedia, .studio] {
            let tier = ExportSettings(quality: quality, fps: 30, height: 720, codec: .h264)
            let tierURL = directory.appendingPathComponent("tier-\(quality.rawValue).mp4")
            try await OfflineExporter().export(session: session, directory: directory,
                                               destination: tierURL, settings: tier)
            let measured = try await probe(tierURL)
            let target = Double(tier.videoBitsPerSecond(width: 1280, height: 720))
            guard measured.width == 1280, measured.height == 720,
                  measured.dataRate <= 1.35 * target || quality == .webLow else {
                throw VerificationError.failed(
                    "\(quality.rawValue) video bitrate \(Int(measured.dataRate)) b/s overshoots \(Int(target)) b/s"
                )
            }
            rates[quality] = measured.dataRate
        }
        guard let low = rates[.webLow], let social = rates[.socialMedia], let studio = rates[.studio],
              low < social, social < studio, studio > 1.5 * social else {
            throw VerificationError.failed("quality tiers do not order by bitrate: \(rates)")
        }

        // (d) 9:16 keeps the 16:9 source whole, centered between black bars.
        let tallSettings = ExportSettings(fps: 30, height: 720, aspectRatio: .preset(.tall))
        let tallURL = directory.appendingPathComponent("tall.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: tallURL,
                                           settings: tallSettings)
        let tall = try await probe(tallURL)
        guard tall.width == 404, tall.height == 720, tall.codec == kCMVideoCodecType_H264 else {
            throw VerificationError.failed("9:16 export probed as \(tall), expected 404×720 H.264")
        }
        let tallAsset = AVURLAsset(url: tallURL)
        // Content is 404×227.25 centered vertically; top-left normalized y of source y=0.3.
        let contentTop = (720 - 227.25) / 2
        for time in [0.5, 3.5] {
            for y in [0.05, 0.95] {
                let bar = try await sampleColor(asset: tallAsset, time: time, x: 0.5, y: y)
                guard Int(bar.red) + Int(bar.green) + Int(bar.blue) < 45 else {
                    throw VerificationError.failed("9:16 bar at y \(y), \(time)s is \(bar), expected black")
                }
            }
        }
        let unzoomed = try await sampleColor(asset: tallAsset, time: 0.5, x: 0.3,
                                             y: (contentTop + 0.3 * 227.25) / 720)
        guard unzoomed.matches(colorQuadrant(x: 0.3, y: 0.3)) else {
            throw VerificationError.failed("9:16 unzoomed content sample is \(unzoomed), expected blue")
        }
        let zoomedCenter = try await sampleColor(asset: tallAsset, time: 3.5, x: 0.5, y: 0.5)
        guard zoomedCenter.matches(colorQuadrant(x: 0.75, y: 0.25)) else {
            throw VerificationError.failed("9:16 zoomed center is \(zoomedCenter), expected the green top-right region")
        }
        let tallMarker = try await markerBounds(asset: tallAsset, time: 3.5)
        guard tallMarker.minY > contentTop - 1, tallMarker.maxY < 720 - contentTop + 1,
              // The zoom spring is still settling at 3.5 s (the full-frame check allows ±0.08 of the
              // source); at 2× over a 404 px wide content area, ±0.04 source units is ±32 px.
              abs(tallMarker.midX - 202) < 32, abs(tallMarker.midY - 360) < 32 else {
            throw VerificationError.failed("9:16 zoomed marker is at \(tallMarker), expected centered in the content")
        }
    }

    private static func verifyGIF(session: RecordingSession, directory: URL, duration: Double) async throws {
        guard GifExporter.delays(frameCount: 30, fps: 30).reduce(0, +) == 100,
              GifExporter.delays(frameCount: 15, fps: 15).reduce(0, +) == 100 else {
            throw VerificationError.failed("GIF centisecond delays drift from the requested frame rate")
        }
        let settings = ExportSettings.gifDefault
        let expected = settings.outputSize(sourceWidth: session.width, sourceHeight: session.height)
        let expectedFrames = Int((duration * Double(settings.fps)).rounded())
        for disableLoop in [false, true] {
            var current = settings
            current.gifDisableLoop = disableLoop
            let url = directory.appendingPathComponent(disableLoop ? "once.gif" : "loop.gif")
            try await OfflineExporter().export(session: session, directory: directory, destination: url,
                                               settings: current)
            let data = try Data(contentsOf: url)
            // ImageIO labels animated output GIF87a; frame count, delays and the loop block below are
            // what actually define the animation, so either valid signature is accepted.
            guard data.prefix(6) == Data("GIF89a".utf8) || data.prefix(6) == Data("GIF87a".utf8),
                  data.count > 13 else {
                throw VerificationError.failed("GIF does not start with a GIF signature (\(data.count) bytes, prefix \(Array(data.prefix(12))))")
            }
            let screenWidth = Int(data[6]) | Int(data[7]) << 8
            let screenHeight = Int(data[8]) | Int(data[9]) << 8
            guard screenWidth == expected.width, screenHeight == expected.height,
                  screenWidth % 2 == 0, screenHeight % 2 == 0 else {
                throw VerificationError.failed("GIF canvas is \(screenWidth)×\(screenHeight), expected \(expected)")
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw VerificationError.failed("ImageIO cannot read the exported GIF")
            }
            let count = CGImageSourceGetCount(source)
            guard abs(count - expectedFrames) <= 1 else {
                throw VerificationError.failed("GIF has \(count) frames, expected \(expectedFrames)")
            }
            var total = 0.0
            for index in 0..<count {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            }
            guard abs(total - duration) <= 0.1 * duration else {
                throw VerificationError.failed("GIF plays for \(total)s, expected about \(duration)s")
            }
            let loopCount = netscapeLoopCount(data)
            if disableLoop {
                guard loopCount == nil else {
                    throw VerificationError.failed("GIF with looping disabled still has loop count \(loopCount ?? -1)")
                }
            } else {
                guard loopCount == 0 else {
                    throw VerificationError.failed("looping GIF has NETSCAPE2.0 loop count \(String(describing: loopCount))")
                }
                // Frame at 3.5 s shows the zoomed top-right (green) region at its center.
                let zoomIndex = Int(3.5 * Double(settings.fps))
                guard let image = CGImageSourceCreateImageAtIndex(source, zoomIndex, nil) else {
                    throw VerificationError.failed("could not decode GIF frame \(zoomIndex)")
                }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
                      RGB(red: UInt8(color.redComponent * 255), green: UInt8(color.greenComponent * 255),
                          blue: UInt8(color.blueComponent * 255)).matches(colorQuadrant(x: 0.75, y: 0.25)) else {
                    throw VerificationError.failed("GIF zoom frame center does not show the green region")
                }
            }
            do {
                try await OfflineExporter().export(session: session, directory: directory, destination: url,
                                                   settings: current)
                throw VerificationError.failed("GIF export overwrote an existing destination")
            } catch OfflineExporter.ExportError.outputExists {}
        }
        let partials = try await directoryAfterWriterCleanup(directory).filter { $0.contains(".partial.") }
        guard partials.isEmpty else { throw VerificationError.failed("temporary exports were left behind: \(partials)") }
    }

    private static func directoryAfterWriterCleanup(_ directory: URL) async throws -> [String] {
        // AVAssetWriter can release its .sb- scratch file shortly after finishWriting returns.
        // Keep asserting all file names, with a bounded wait for that framework-owned cleanup.
        for _ in 0..<20 {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if !names.contains(where: { $0.contains(".sb-") }) { return names }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    /// Returns the NETSCAPE2.0 application extension loop count, or nil when absent.
    private static func netscapeLoopCount(_ data: Data) -> Int? {
        let marker = Data("NETSCAPE2.0".utf8)
        guard let range = data.range(of: marker), data.count >= range.upperBound + 4,
              data[range.upperBound] == 3, data[range.upperBound + 1] == 1 else { return nil }
        return Int(data[range.upperBound + 2]) | Int(data[range.upperBound + 3]) << 8
    }

    private struct Probe: CustomStringConvertible {
        var codec: FourCharCode
        var width: Int
        var height: Int
        var fps: Double
        var dataRate: Double
        var duration: Double
        var audioTracks: Int
        var description: String {
            "codec \(codec) \(width)×\(height) \(fps) fps \(Int(dataRate)) b/s \(duration)s \(audioTracks) audio"
        }
    }

    private static func probe(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VerificationError.failed("\(url.lastPathComponent) has no video track")
        }
        let (size, rate, dataRate, descriptions) = try await track.load(
            .naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
        )
        guard let description = descriptions.first else {
            throw VerificationError.failed("\(url.lastPathComponent) has no video format")
        }
        return Probe(codec: CMFormatDescriptionGetMediaSubType(description),
                     width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                     fps: Double(rate), dataRate: Double(dataRate),
                     duration: try await asset.load(.duration).seconds,
                     audioTracks: try await asset.loadTracks(withMediaType: .audio).count)
    }

    private static func addAudioTracks(to movie: URL, directory: URL, duration: Double) async throws {
        let lowURL = directory.appendingPathComponent("tone-440.wav")
        let highURL = directory.appendingPathComponent("tone-880.wav")
        try writeToneWAV(to: lowURL, frequency: 440, duration: duration)
        try writeToneWAV(to: highURL, frequency: 880, duration: duration)
        try await muxAudio(into: movie, directory: directory, tones: [lowURL, highURL], duration: duration)
    }

    /// Replaces `movie` with its video plus one audio track per WAV, in order.
    private static func muxAudio(into movie: URL, directory: URL, tones: [URL], duration: Double) async throws {
        let videoAsset = AVURLAsset(url: movie)
        let composition = AVMutableComposition()
        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTarget = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VerificationError.failed("could not create source video composition track")
        }
        try videoTarget.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)),
                                        of: videoSource, at: .zero)
        for sourceAsset in tones.map({ AVURLAsset(url: $0) }) {
            guard let source = try await sourceAsset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VerificationError.failed("could not create an audio composition track")
            }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)),
                                       of: source, at: .zero)
        }
        let muxed = directory.appendingPathComponent("muxed.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw VerificationError.failed("could not create synthetic audio mux")
        }
        try await exporter.export(to: muxed, as: .mp4)
        try FileManager.default.removeItem(at: movie)
        try FileManager.default.moveItem(at: muxed, to: movie)
    }

    private static func writeToneWAV(to url: URL, frequency: Double, duration: Double) throws {
        let sampleRate = 48_000
        let count = Int(Double(sampleRate) * duration)
        let dataBytes = count * 2
        var data = Data()
        func put16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        func put32(_ value: UInt32) {
            data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
        }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        for index in 0..<count {
            let sample = Int16(sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)) * 10_000)
            put16(UInt16(bitPattern: sample))
        }
        try data.write(to: url)
    }

    @MainActor
    private static func decodedFrequencyPeaks(asset: AVAsset, tracks: [AVAssetTrack]) async throws -> [Double] {
        var result: [Double] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ])
            guard reader.canAdd(output) else { throw VerificationError.failed("could not decode an audio track") }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(sample) else {
                throw VerificationError.failed("could not read decoded audio samples")
            }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { throw VerificationError.failed("decoded audio has no sample data") }
            let samples = UnsafeBufferPointer(start: pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { $0 }, count: length / 4)
            guard samples.count > 100 else { throw VerificationError.failed("decoded audio sample was too short") }
            // Count sign crossings in one decoded buffer; tones are below Nyquist.
            var crossings = 0
            for index in 1..<samples.count where samples[index - 1] <= 0 && samples[index] > 0 { crossings += 1 }
            let seconds = Double(samples.count) / 48_000
            result.append(Double(crossings) / seconds)
        }
        return result
    }

    private static func makeFixture(url: URL, width: Int, height: Int, duration: Double,
                                    transform: CGAffineTransform = .identity, noise: Bool = false,
                                    checker: Bool = false) async throws {
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
            if checker {
                paintChecker(buffer, width: width, height: height)
            } else if noise {
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

    /// Black and white 8 px squares over the whole frame: the highest-contrast pattern a blur can flatten.
    private static func paintChecker(_ buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = ((x / 8) + (y / 8)) % 2 == 0 ? 0xffff_ffff : 0xff00_0000 }
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

    // MARK: Audio mix (master volume, mutes, microphone cleanup, click sounds)

    /// Constant tones: system 440 Hz, microphone 880 Hz, so levels and frequencies identify each
    /// source. Clicks at 1.0 s (separate press/release) and 3.0 s (merged click) identify click audio.
    @MainActor
    private static func verifyAudioMix(root: URL, width: Int, height: Int, duration: Double) async throws {
        let directory = root.appendingPathComponent("audio-mix-session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("raw.mp4")
        try await makeFixture(url: rawURL, width: width, height: height, duration: duration)
        let systemURL = directory.appendingPathComponent("system.wav")
        let microphoneURL = directory.appendingPathComponent("microphone.wav")
        try writeToneWAV(to: systemURL, duration: duration) { _ in 440 }
        try writeToneWAV(to: microphoneURL, duration: duration) { _ in 880 }
        try await muxAudio(into: rawURL, directory: directory, tones: [systemURL, microphoneURL], duration: duration)
        let session = RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height, duration: duration,
            events: [
                CursorEvent(time: 1.0, x: 0.5, y: 0.5, kind: .down), CursorEvent(time: 1.12, x: 0.5, y: 0.5, kind: .up),
                CursorEvent(time: 3.0, x: 0.5, y: 0.5, kind: .down), CursorEvent(time: 3.02, x: 0.5, y: 0.5, kind: .up)
            ],
            droppedFrames: 0, eventCaptureAvailable: true,
            audio: AudioCaptureMetadata(systemAudioRequested: true, microphoneRequested: true,
                                        systemAudioSamples: 1, microphoneSamples: 1,
                                        systemAudioDroppedSamples: 0, microphoneDroppedSamples: 0)
        )
        try session.save(in: directory)
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)

        func export(_ name: String, _ edit: ExportEdit?) async throws -> (asset: AVURLAsset, count: Int) {
            let url = directory.appendingPathComponent("\(name).mp4")
            try await OfflineExporter().export(session: session, directory: directory, destination: url,
                                               showsClickEffects: false, settings: settings, edit: edit)
            let asset = AVURLAsset(url: url)
            return (asset, try await asset.loadTracks(withMediaType: .audio).count)
        }
        func measure(_ exported: (asset: AVURLAsset, count: Int), _ index: Int,
                     from: Double, to: Double) async throws -> ToneMeasure {
            let track = try await exported.asset.loadTracks(withMediaType: .audio)[index]
            return analyze(try await decodeAudio(asset: exported.asset, track: track), from: from, to: to)
        }

        // A neutral configuration changes nothing: same two tracks and levels as no configuration.
        var neutral = AudioMixConfiguration()
        neutral.microphonePreset = .off
        guard ExportEdit(audio: neutral).audio == nil, ExportEdit(audio: neutral).isEmpty else {
            throw VerificationError.failed("a neutral audio configuration should be dropped from the export edit")
        }
        let baseline = try await export("audio-baseline", nil)
        guard baseline.count == 2 else { throw VerificationError.failed("baseline export lacks two audio tracks") }
        let baseSystem = try await measure(baseline, 0, from: 1, to: 5), baseMic = try await measure(baseline, 1, from: 1, to: 5)
        guard baseSystem.rms > 0.05, baseMic.rms > 0.05 else {
            throw VerificationError.failed("baseline tones are too quiet: \(baseSystem), \(baseMic)")
        }

        // Master volume 0.5 scales both sources, in the pass-through path and in the edited path.
        var half = neutral
        half.volume = 0.5
        for (name, timeline) in [("audio-half-plain", nil as TimelineModel?), ("audio-half-edited", TimelineModel(sourceDuration: duration))] {
            let exported = try await export(name, ExportEdit(timeline: timeline, audio: half))
            guard exported.count == 2 else { throw VerificationError.failed("\(name) lost an audio track") }
            let system = try await measure(exported, 0, from: 1, to: 5), mic = try await measure(exported, 1, from: 1, to: 5)
            guard abs(system.rms / baseSystem.rms - 0.5) < 0.06, abs(mic.rms / baseMic.rms - 0.5) < 0.06,
                  abs(system.frequency - 440) < 25, abs(mic.frequency - 880) < 40 else {
                throw VerificationError.failed("\(name): volume 0.5 gave system \(system), microphone \(mic); baseline \(baseSystem), \(baseMic)")
            }
        }

        // Mute + microphone cleanup (voice preset): the system track is silent, the cleaned microphone
        // keeps its tone and its timing (starts with the video, spans the whole recording).
        var voice = neutral
        voice.muteSystemAudio = true
        voice.microphonePreset = .voice
        for (name, timeline) in [("audio-voice-plain", nil as TimelineModel?), ("audio-voice-edited", TimelineModel(sourceDuration: duration))] {
            let exported = try await export(name, ExportEdit(timeline: timeline, audio: voice))
            guard exported.count == 2 else { throw VerificationError.failed("\(name) lost an audio track") }
            let system = try await measure(exported, 0, from: 1, to: 5), mic = try await measure(exported, 1, from: 1, to: 5)
            guard system.rms < 0.002, abs(mic.frequency - 880) < 40, mic.rms > 0.02, mic.rms < baseMic.rms * 1.6 else {
                throw VerificationError.failed("\(name): muted system \(system), cleaned microphone \(mic) (baseline \(baseMic))")
            }
            let range = try await exported.asset.loadTracks(withMediaType: .audio)[1].load(.timeRange)
            guard abs(range.start.seconds) < 0.05, abs(range.end.seconds - duration) < 0.15 else {
                throw VerificationError.failed("\(name): cleaned microphone spans \(range.start.seconds)…\(range.end.seconds)s of \(duration)s")
            }
            let early = try await measure(exported, 1, from: 0.1, to: 0.6), late = try await measure(exported, 1, from: duration - 0.6, to: duration - 0.1)
            guard early.rms > 0.02, late.rms > 0.02 else {
                throw VerificationError.failed("\(name): cleaned microphone is silent at the edges (\(early), \(late))")
            }
        }

        // Click sounds add a third track whose energy sits at the click times only. Trimming to the
        // first two seconds keeps the 1.0 s click and drops the 3.0 s one (source-time placement).
        var clicks = neutral
        clicks.clickSoundEffect = .crispClick
        clicks.clickSoundEffectVolume = 1
        var trimmed = TimelineModel(sourceDuration: duration)
        let tail = try trimmed.split(atSource: 2)
        try trimmed.delete(segmentID: tail)
        for (name, timeline, expectsSecond) in [("audio-clicks-plain", nil as TimelineModel?, true), ("audio-clicks-trimmed", trimmed, false)] {
            let exported = try await export(name, ExportEdit(timeline: timeline, audio: clicks))
            guard exported.count == 3 else {
                throw VerificationError.failed("\(name) has \(exported.count) audio tracks, expected the two sources plus clicks")
            }
            let first = try await measure(exported, 2, from: 0.99, to: 1.2)
            let quiet = try await measure(exported, 2, from: 1.5, to: 1.9)
            let second = try await measure(exported, 2, from: 2.99, to: 3.1)
            guard first.rms > 0.01, quiet.rms < 0.0005, expectsSecond ? second.rms > 0.01 : second.rms < 0.0005 else {
                throw VerificationError.failed("\(name): click energy at 1 s \(first), between \(quiet), at 3 s \(second)")
            }
            let sourceTone = try await measure(exported, 1, from: 0.5, to: 1.9)
            guard abs(sourceTone.rms - baseMic.rms) < baseMic.rms * 0.1 else {
                throw VerificationError.failed("\(name): microphone changed to \(sourceTone) (baseline \(baseMic))")
            }
        }

        try await verifyBackgroundMusicAndMixdown(
            directory: directory, duration: duration, neutral: neutral, baseSystem: baseSystem, baseMic: baseMic,
            export: export, measure: measure)
    }

    /// Music fixture (mono 48 kHz, 1.5 s): 1000 Hz for 0.75 s, then 1500 Hz, so loops are visible as a
    /// repeating frequency pattern. System 440 Hz / microphone 880 Hz come from the session fixture.
    @MainActor
    private static func verifyBackgroundMusicAndMixdown(
        directory: URL, duration: Double, neutral: AudioMixConfiguration, baseSystem: ToneMeasure, baseMic: ToneMeasure,
        export: (String, ExportEdit?) async throws -> (asset: AVURLAsset, count: Int),
        measure: ((asset: AVURLAsset, count: Int), Int, Double, Double) async throws -> ToneMeasure
    ) async throws {
        func fail(_ message: String) -> VerificationError { VerificationError.failed(message) }
        let musicName = "music-fixture.wav"
        try writeToneWAV(to: directory.appendingPathComponent(musicName), duration: 1.5) { $0 < 0.75 ? 1000 : 1500 }

        // Neutral-config rules and decoding.
        var music = neutral
        music.backgroundAudioFileName = musicName
        var mutedMusic = music
        mutedMusic.muteBackgroundAudio = true
        var mixdownOnly = neutral
        mixdownOnly.mixdownSingleTrack = true
        guard !music.isExportNeutral, ExportEdit(audio: music).audio != nil, mutedMusic.isExportNeutral,
              !mixdownOnly.isExportNeutral, ExportEdit(audio: mutedMusic).audio == nil else {
            throw fail("neutral-configuration rules for music / mixdown are wrong")
        }
        let decoded = try JSONDecoder().decode(AudioMixConfiguration.self, from: Data("{}".utf8))
        guard decoded.mixdownSingleTrack == false, decoded.backgroundAudioVolume == 0.05 else {
            throw fail("a missing mixdownSingleTrack key should decode to false")
        }

        // Missing music file: a clear error naming it.
        var missing = neutral
        missing.backgroundAudioFileName = "no-such-music.mp3"
        do {
            _ = try await export("audio-music-missing", ExportEdit(audio: missing))
            throw fail("an export with missing music succeeded")
        } catch let error as AudioProcessingError {
            guard error.localizedDescription.contains("no-such-music.mp3") else { throw fail("missing-music error does not name the file: \(error)") }
        }

        // Music on an edited (trimmed) timeline: playback = source 2…6 s = 4 s. Music starts at playback 0
        // (not source 2), loops (1.5 s fixture), keeps its level and fades out over the last second.
        var trimmed = TimelineModel(sourceDuration: duration)
        let tail = try trimmed.split(atSource: 6)
        try trimmed.delete(segmentID: tail)
        let head = try trimmed.split(atSource: 2)
        _ = head
        let first = trimmed.segments[0].id
        try trimmed.delete(segmentID: first)
        let playback = trimmed.playbackDuration
        guard abs(playback - 4) < 1e-6 else { throw fail("trimmed fixture should play 4 s, got \(playback)") }
        var halfMusic = music
        halfMusic.backgroundAudioVolume = 0.5
        for (name, timeline, length) in [("audio-music-edited", trimmed as TimelineModel?, playback), ("audio-music-plain", nil, duration)] {
            let exported = try await export(name, ExportEdit(timeline: timeline, audio: halfMusic))
            guard exported.count == 3 else { throw fail("\(name) has \(exported.count) audio tracks, expected two sources plus music") }
            let range = try await exported.asset.loadTracks(withMediaType: .audio)[2].load(.timeRange)
            guard abs(range.start.seconds) < 0.05, abs(range.end.seconds - length) < 0.15 else {
                throw fail("\(name): music spans \(range.start.seconds)…\(range.end.seconds)s of \(length)s")
            }
            // Loop pattern: 1000 Hz at 0.1–0.6, 1500 at 0.85–1.4, 1000 again at 1.6–2.1, 1500 at 2.35–2.9.
            let expected = [(0.1, 0.6, 1000.0), (0.85, 1.4, 1500), (1.6, 2.1, 1000), (2.35, 2.9, 1500)]
            var levels: [Double] = []
            for (from, to, frequency) in expected {
                let measured = try await measure(exported, 2, from, to)
                guard abs(measured.frequency - frequency) < 60 else { throw fail("\(name): music at \(from)s is \(measured), expected \(frequency) Hz") }
                levels.append(measured.rms)
            }
            // Level = master 1 × volume 0.5 of the same-amplitude microphone fixture tone.
            guard levels.allSatisfy({ abs($0 / baseMic.rms - 0.5) < 0.07 }) else {
                throw fail("\(name): music levels \(levels) vs 0.5 × baseline \(baseMic.rms)")
            }
            // Fade: full level before the last second, ramping to silence at the end.
            let before = try await measure(exported, 2, length - 1.4, length - 1.1)
            let middle = try await measure(exported, 2, length - 0.6, length - 0.4)
            let end = try await measure(exported, 2, length - 0.1, length - 0.02)
            guard abs(before.rms / levels[0] - 1) < 0.1, abs(middle.rms / levels[0] - 0.5) < 0.12, end.rms < levels[0] * 0.2 else {
                throw fail("\(name): fade-out levels \(before), \(middle), \(end) vs full \(levels[0])")
            }
            // The system and microphone tracks are untouched.
            let mic = try await measure(exported, 1, 1, 3)
            guard abs(mic.rms - baseMic.rms) < baseMic.rms * 0.1 else { throw fail("\(name): microphone changed to \(mic)") }
        }

        // Mixdown: exactly one stereo track holding the 440 and 880 Hz tones (and the music).
        var mixdown = neutral
        mixdown.mixdownSingleTrack = true
        for (name, timeline) in [("audio-mixdown-plain", nil as TimelineModel?), ("audio-mixdown-edited", trimmed)] {
            let exported = try await export(name, ExportEdit(timeline: timeline, audio: mixdown))
            guard exported.count == 1 else { throw fail("\(name) has \(exported.count) audio tracks, expected one") }
            let mixed = try await decodeStereo(exported.asset)
            let length = timeline?.playbackDuration ?? duration
            let channels = mixed.channels.count
            guard channels == 2, abs(mixed.duration - length) < 0.15 else {
                throw fail("\(name): mixdown has \(channels) channels and lasts \(mixed.duration)s of \(length)s")
            }
            let low = goertzel(mixed.channels[0], 440, from: 1, to: 3), high = goertzel(mixed.channels[0], 880, from: 1, to: 3)
            let other = goertzel(mixed.channels[0], 660, from: 1, to: 3)
            // Each tone has amplitude 10000/32768; the Goertzel magnitude of a unit-gain tone is that amplitude.
            guard abs(low - 0.305) < 0.04, abs(high - 0.305) < 0.04, other < 0.02 else {
                throw fail("\(name): 440 Hz \(low), 880 Hz \(high), 660 Hz \(other) (expected 0.305, 0.305, ~0)")
            }
        }
        // Volumes and mutes in the mixdown: master 0.5 halves both, muting the system leaves only 880 Hz.
        var halfMix = mixdown
        halfMix.volume = 0.5
        halfMix.muteSystemAudio = true
        do {
            let exported = try await export("audio-mixdown-mute", ExportEdit(audio: halfMix))
            let mixed = try await decodeStereo(exported.asset)
            let low = goertzel(mixed.channels[0], 440, from: 1, to: 3), high = goertzel(mixed.channels[0], 880, from: 1, to: 3)
            guard exported.count == 1, low < 0.01, abs(high - 0.1525) < 0.03 else {
                throw fail("mixdown mute/volume: 440 Hz \(low) (want 0), 880 Hz \(high) (want 0.1525)")
            }
        }
        // Music joins the mixdown (volume 1 so it is measurable): 1000 Hz first, and it follows playback time.
        var withMusic = mixdown
        withMusic.backgroundAudioFileName = musicName
        withMusic.backgroundAudioVolume = 0.5
        do {
            let exported = try await export("audio-mixdown-music", ExportEdit(timeline: trimmed, audio: withMusic))
            guard exported.count == 1 else { throw fail("mixdown with music has \(exported.count) tracks") }
            let mixed = try await decodeStereo(exported.asset)
            let early = goertzel(mixed.channels[0], 1000, from: 0.1, to: 0.6), late = goertzel(mixed.channels[0], 1500, from: 0.85, to: 1.4)
            let wrong = goertzel(mixed.channels[0], 1500, from: 0.1, to: 0.6)
            let tone = goertzel(mixed.channels[0], 880, from: 0.1, to: 0.6)
            guard abs(early - 0.1525) < 0.03, abs(late - 0.1525) < 0.03, wrong < 0.02, abs(tone - 0.305) < 0.04 else {
                throw fail("mixdown with music: 1000 Hz \(early), 1500 Hz \(late), 1500 Hz@0 \(wrong), 880 Hz \(tone)")
            }
        }
        // Limiter: master 2 would sum above full scale; the peak stays at the ceiling (AAC overshoot < 0.5 dB).
        var loud = mixdown
        loud.volume = 2
        do {
            let exported = try await export("audio-mixdown-limited", ExportEdit(audio: loud))
            let mixed = try await decodeStereo(exported.asset)
            let peak = mixed.channels.flatMap { $0 }.map { abs($0) }.max() ?? 0
            let ceiling = Float(pow(10, loud.limiterCeilingDB / 20))
            print(String(format: "mixdown limiter: peak %.4f, ceiling %.4f", peak, ceiling))
            guard peak <= ceiling * 1.06, peak > ceiling * 0.7 else {
                throw fail("limited mixdown peak \(peak) vs ceiling \(ceiling)")
            }
        }
        // Loudness: -16 and -14 LUFS are reached within 1 LU.
        for target in [-16.0, -14.0] {
            var normalized = mixdown
            normalized.targetLoudnessLUFS = target
            let exported = try await export("audio-mixdown-lufs\(Int(-target))", ExportEdit(audio: normalized))
            let mixed = try await decodeStereo(exported.asset)
            guard let measured = LoudnessMeter.integratedLoudness(mixed), abs(measured - target) <= 1 else {
                throw fail("mixdown loudness \(LoudnessMeter.integratedLoudness(mixed).map { String($0) } ?? "nil") LUFS, wanted \(target)")
            }
            let peak = mixed.channels.flatMap { $0 }.map { abs($0) }.max() ?? 0
            print(String(format: "mixdown target %.0f LUFS: measured %.2f LUFS, peak %.3f", target, measured, peak))
            guard peak <= Float(pow(10, normalized.limiterCeilingDB / 20)) * 1.06 else { throw fail("normalized mixdown peak \(peak)") }
        }
        // GIF ignores audio settings entirely (no audio track, export still succeeds is covered elsewhere).
    }

    private static func decodeStereo(_ asset: AVURLAsset) async throws -> PCMAudio {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw VerificationError.failed("no audio track") }
        return try await AudioFileIO.decode(asset: asset, track: track)
    }

    /// Single-bin DFT magnitude (amplitude of a sinusoid at `frequency`) over `from`…`to` seconds at 48 kHz.
    private static func goertzel(_ samples: [Float], _ frequency: Double, from: Double, to: Double) -> Double {
        let lower = min(samples.count, Int(from * 48_000)), upper = min(samples.count, Int(to * 48_000))
        guard upper - lower > 100 else { return 0 }
        var real = 0.0, imaginary = 0.0
        for index in lower..<upper {
            let angle = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(samples[index]) * cos(angle)
            imaginary += Double(samples[index]) * sin(angle)
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(upper - lower)
    }

    // MARK: Camera overlay

    /// A solid-color camera movie (`flipAt` seconds: magenta before, cyan from then on), 320×240, 30 fps.
    private static func makeCameraFixture(url: URL, duration: Double, flipAt: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
        ])
        guard writer.canAdd(input) else { throw VerificationError.failed("cannot add camera fixture input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VerificationError.failed("camera writer did not start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(duration * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw VerificationError.failed("no camera pixel buffer pool") }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else { throw VerificationError.failed("could not allocate a camera frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let cyan = Double(frame) / 30 >= flipAt
            for y in 0..<240 {
                for x in 0..<320 {
                    let pixel = base + y * stride + x * 4
                    pixel[0] = 255; pixel[1] = cyan ? 255 : 0; pixel[2] = cyan ? 0 : 255; pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? VerificationError.failed("camera writer rejected a frame")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VerificationError.failed("camera fixture did not finish") }
    }

    /// The camera flips magenta → cyan at camera time 1 s and starts 1 s after the screen
    /// (`firstPTS` 1), so on the screen timeline it is magenta before 2 s (held before 1 s) and cyan after.
    @MainActor
    private static func verifyWebcam(root: URL, width: Int, height: Int, duration: Double) async throws {
        let directory = root.appendingPathComponent("webcam-session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await makeFixture(url: directory.appendingPathComponent("raw.mp4"), width: width, height: height, duration: duration)
        try await makeCameraFixture(url: directory.appendingPathComponent("camera.mov"), duration: duration, flipAt: 1)
        let session = RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height, duration: duration,
            events: [], droppedFrames: 0, eventCaptureAvailable: true,
            webcam: WebcamCaptureMetadata(filename: "camera.mov", firstPTS: 1, duration: duration, width: 320, height: 240,
                                          droppedFrames: 0, deviceName: "Fixture", firstHostTime: 0)
        )
        try session.save(in: directory)
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)
        let magenta = RGB(red: 255, green: 0, blue: 255), cyan = RGB(red: 0, green: 255, blue: 255)
        // Bottom-right square: 0.35 × 1280 = 448 px, padding 0.5 × 0.1 × 448 = 22 px → center (1034, 474) of 1280×720.
        let (px, py) = (1034.0 / 1280, 474.0 / 720)

        func export(_ name: String, _ edit: ExportEdit?, settings: ExportSettings = settings) async throws -> AVURLAsset {
            let url = directory.appendingPathComponent(name)
            try await OfflineExporter().export(session: session, directory: directory, destination: url,
                                               showsClickEffects: false, settings: settings, edit: edit)
            return AVURLAsset(url: url)
        }
        func expect(_ asset: AVURLAsset, _ label: String, _ points: [(time: Double, color: RGB)],
                    x: Double = px, y: Double = py) async throws {
            for (time, color) in points {
                let pixel = try await sampleColor(asset: asset, time: time, x: x, y: y)
                guard pixel.matches(color, tolerance: 110) else {
                    throw VerificationError.failed("\(label): pixel at \(time)s is \(pixel), expected \(color)")
                }
            }
        }

        // Plain export: held first frame before the camera starts, flip at screen time 2 s.
        let plain = try await export("webcam-plain.mp4", nil)
        try await expect(plain, "camera overlay", [(0.3, magenta), (1.5, magenta), (2.6, cyan), (6.0, cyan)])

        // Timeline: playback [0,3) shows source 5…8 (cyan), [3,6) shows source 0…3 (magenta until 2 s, cyan after).
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 3)
        try timeline.split(atSource: 5)
        let middle = timeline.segments[1].id, late = timeline.segments[2].id
        try timeline.delete(segmentID: middle)
        try timeline.move(segmentID: late, toIndex: 0)
        let edited = try await export("webcam-edited.mp4", ExportEdit(timeline: timeline))
        try await expect(edited, "camera in an edited export",
                         [(0.5, cyan), (2.5, cyan), (3.5, magenta), (4.5, magenta), (5.5, cyan)])

        // Configuration: hidden, screen-only and mirrored layouts, a moved anchor, and the full-screen camera.
        var hidden = WebcamConfiguration()
        hidden.hide = true
        let hiddenAsset = try await export("webcam-hidden.mp4", ExportEdit(webcam: hidden))
        for time in [1.5, 4.0] {
            let pixel = try await sampleColor(asset: hiddenAsset, time: time, x: px, y: py)
            guard !pixel.matches(magenta, tolerance: 110), !pixel.matches(cyan, tolerance: 110) else {
                throw VerificationError.failed("hidden camera still drawn at \(time)s: \(pixel)")
            }
        }
        var screenOnly = WebcamConfiguration()
        screenOnly.layout = .screenOnly
        let screenOnlyAsset = try await export("webcam-screen-only.mp4", ExportEdit(webcam: screenOnly))
        let leftover = try await sampleColor(asset: screenOnlyAsset, time: 4.0, x: px, y: py)
        guard !leftover.matches(cyan, tolerance: 110) else { throw VerificationError.failed("screen-only layout still drew the camera") }
        var topLeft = WebcamConfiguration()
        topLeft.position = WebcamAnchor.topLeft.point
        let movedAsset = try await export("webcam-top-left.mp4", ExportEdit(webcam: topLeft))
        // Top-left square: padding 22 px, so its center is (246, 246).
        try await expect(movedAsset, "top-left camera", [(4.0, cyan)], x: 246.0 / 1280, y: 246.0 / 720)
        let vacated = try await sampleColor(asset: movedAsset, time: 4.0, x: px, y: py)
        guard !vacated.matches(cyan, tolerance: 110) else { throw VerificationError.failed("moved camera still drawn at the old anchor") }
        var fullscreen = WebcamConfiguration()
        fullscreen.layout = .fullscreenCamera
        let fullscreenAsset = try await export("webcam-fullscreen.mp4", ExportEdit(webcam: fullscreen))
        try await expect(fullscreenAsset, "full-screen camera", [(1.5, magenta), (4.0, cyan)], x: 0.1, y: 0.1)

        // A recorded camera whose file disappeared is an error that names the fix.
        let missing = directory.appendingPathComponent("camera.mov")
        let moved = directory.appendingPathComponent("camera-moved.mov")
        try FileManager.default.moveItem(at: missing, to: moved)
        do {
            _ = try await export("webcam-missing.mp4", nil)
            throw VerificationError.failed("a missing camera file was silently ignored")
        } catch let error as OfflineExporter.ExportError {
            guard error.localizedDescription.contains("camera") else {
                throw VerificationError.failed("missing camera error does not mention the camera: \(error.localizedDescription)")
            }
        }
        _ = try await export("webcam-missing-hidden.mp4", ExportEdit(webcam: hidden))
        try FileManager.default.moveItem(at: moved, to: missing)

        // GIF: the camera is composited into frames too (second frame at ≥ 2.6 s is cyan).
        let gifSettings = ExportSettings(format: .gif, fps: 10, height: 360, codec: .h264)
        let gifURL = directory.appendingPathComponent("webcam.gif")
        try await OfflineExporter().export(session: session, directory: directory, destination: gifURL,
                                           showsClickEffects: false, settings: gifSettings, edit: nil)
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil), CGImageSourceGetCount(source) > 30,
              let early = CGImageSourceCreateImageAtIndex(source, 8, nil), let late = CGImageSourceCreateImageAtIndex(source, 40, nil) else {
            throw VerificationError.failed("the camera GIF has too few frames")
        }
        for (image, color, label) in [(early, magenta, "0.8 s"), (late, cyan, "4.0 s")] {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let sampled = rep.colorAt(x: Int(px * Double(rep.pixelsWide)), y: Int(py * Double(rep.pixelsHigh)))?
                .usingColorSpace(.deviceRGB) else { throw VerificationError.failed("could not read a GIF pixel") }
            let pixel = RGB(red: UInt8(sampled.redComponent * 255), green: UInt8(sampled.greenComponent * 255),
                            blue: UInt8(sampled.blueComponent * 255))
            guard pixel.matches(color, tolerance: 110) else {
                throw VerificationError.failed("GIF camera pixel at \(label) is \(pixel), expected \(color)")
            }
        }
        try await verifyWebcamLayouts(session: session, directory: directory)
    }

    /// Split-screen, layout items and cutout on the 640×360 screen fixture (quadrants blue/green over red/yellow)
    /// with the magenta → cyan camera (cyan from screen time 2 s). Output is 1280×720; points are top-left pixels.
    @MainActor
    private static func verifyWebcamLayouts(session: RecordingSession, directory: URL) async throws {
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)
        let blue = RGB(red: 32, green: 48, blue: 230), green = RGB(red: 32, green: 220, blue: 48)
        let red = RGB(red: 230, green: 48, blue: 32), yellow = RGB(red: 220, green: 210, blue: 32)
        let magenta = RGB(red: 255, green: 0, blue: 255), cyan = RGB(red: 0, green: 255, blue: 255)
        let black = RGB(red: 0, green: 0, blue: 0), orange = RGB(red: 255, green: 128, blue: 0)

        func export(_ name: String, _ configuration: WebcamConfiguration, stage: StageStyle? = nil) async throws -> AVURLAsset {
            let url = directory.appendingPathComponent(name)
            try await OfflineExporter().export(session: session, directory: directory, destination: url, showsClickEffects: false,
                                               settings: settings, edit: ExportEdit(stage: stage, webcam: configuration))
            return AVURLAsset(url: url)
        }
        func expect(_ asset: AVURLAsset, _ label: String, _ points: [(time: Double, x: Double, y: Double, color: RGB)]) async throws {
            for (time, x, y, color) in points {
                let pixel = try await sampleColor(asset: asset, time: time, x: x / 1280, y: y / 720)
                guard pixel.matches(color, tolerance: 110) else {
                    throw VerificationError.failed("\(label): pixel (\(Int(x)), \(Int(y))) at \(time)s is \(pixel), expected \(color)")
                }
            }
        }

        // Side by side (auto, landscape): screen fitted into the left pane (x 0..640, y 180..540), camera fills the right.
        var split = WebcamConfiguration()
        split.layout = .splitScreen
        let sideBySide = try await export("webcam-split.mp4", split)
        try await expect(sideBySide, "split screen", [
            (4.0, 150, 270, blue), (4.0, 470, 270, green), (4.0, 150, 450, red), (4.0, 470, 450, yellow),
            (4.0, 960, 360, cyan), (4.0, 800, 40, cyan), (4.0, 1200, 690, cyan), (1.5, 960, 360, magenta),
            (4.0, 320, 90, black), (4.0, 320, 640, black)
        ])

        // Stacked, flipped and a ratio.
        var stacked = split
        stacked.split.direction = .vertical
        try await expect(try await export("webcam-split-stacked.mp4", stacked), "stacked split", [
            (4.0, 390, 90, blue), (4.0, 790, 270, yellow), (4.0, 640, 540, cyan), (4.0, 100, 700, cyan), (4.0, 100, 90, black)
        ])
        var flipped = split
        flipped.split.flip = true
        try await expect(try await export("webcam-split-flip.mp4", flipped), "flipped split", [
            (4.0, 160, 360, cyan), (4.0, 790, 270, blue), (4.0, 1100, 310, green), (4.0, 790, 450, red)
        ])
        var narrow = split
        narrow.split.screenRatio = 0.25
        try await expect(try await export("webcam-split-ratio.mp4", narrow), "split ratio 0.25", [
            (4.0, 75, 290, blue), (4.0, 400, 100, cyan), (4.0, 800, 360, cyan), (4.0, 160, 100, black)
        ])

        // With a stage the panes sit in the padded area (72 px); the gap is the stage background only with enablePadding.
        var stage = StageStyle()
        stage.shadow.intensity = 0
        stage.background = .color("#ff8000")
        try await expect(try await export("webcam-split-stage.mp4", split, stage: stage), "split on a stage", [
            (4.0, 36, 360, orange), (4.0, 660, 360, cyan), (4.0, 300, 300, blue), (4.0, 1100, 360, cyan), (4.0, 1250, 360, orange)
        ])
        var padded = split
        padded.split.enablePadding = true
        try await expect(try await export("webcam-split-stage-padded.mp4", padded, stage: stage), "padded split on a stage", [
            (4.0, 640, 360, orange), (4.0, 36, 360, orange), (4.0, 1000, 360, cyan), (4.0, 300, 330, blue)
        ])

        // The stage treatment applies per pane: shadow just outside each pane, the inset border inside each, and the
        // device frame around the screen pane only. Panes: screen x 72..640 / y 200..520, camera x 640..1208 / y 72..648.
        var decorated = stage
        decorated.shadow = StageStyle.Shadow(intensity: 1, distance: 0, angle: 45, blur: 2, isDirectional: false)
        decorated.inset = StageStyle.Inset(size: 12, alpha: 1, color: "#ff00ff")
        let decoratedAsset = try await export("webcam-split-stage-decorated.mp4", split, stage: decorated)
        let control = try await sampleColor(asset: decoratedAsset, time: 4.0, x: 20.0 / 1280, y: 20.0 / 720)
        guard control.matches(orange, tolerance: 40) else {
            throw VerificationError.failed("split stage background far from the panes is \(control), expected orange")
        }
        for (label, x, y) in [("left of the screen pane", 69.0, 360.0), ("above the screen pane", 300.0, 197.0),
                              ("right of the camera pane", 1211.0, 360.0), ("above the camera pane", 900.0, 69.0)] {
            let shadowed = try await sampleColor(asset: decoratedAsset, time: 4.0, x: x / 1280, y: y / 720)
            guard Int(shadowed.red) < Int(control.red) - 25, Int(shadowed.green) < Int(control.green) - 12 else {
                throw VerificationError.failed("no pane shadow \(label): \(shadowed) is not darker than the background \(control)")
            }
        }
        try await expect(decoratedAsset, "pane inset borders", [
            (4.0, 77, 360, magenta), (4.0, 1203, 360, magenta), (4.0, 300, 205, magenta),
            (4.0, 300, 300, blue), (4.0, 900, 360, cyan)
        ])

        var device = stage
        device.deviceMockup = DeviceMockupConfiguration(enabled: true, deviceID: "laptop", finish: "dark")
        let deviceAsset = try await export("webcam-split-stage-device.mp4", split, stage: device)
        // Laptop fitted into the screen pane: x 72..640, y 180..540; its aperture starts at (99.5, 196).
        let bezel = try await sampleColor(asset: deviceAsset, time: 4.0, x: 86.0 / 1280, y: 360.0 / 720)
        guard bezel.matches(RGB(red: 37, green: 41, blue: 50), tolerance: 35) else {
            throw VerificationError.failed("split device bezel pixel is \(bezel), expected the dark bezel")
        }
        try await expect(deviceAsset, "split screen in a device frame", [
            (4.0, 300, 273, blue), (4.0, 480, 273, green), (4.0, 300, 430, red),
            (4.0, 900, 360, cyan), (4.0, 20, 20, orange), (4.0, 900, 90, cyan)
        ])
        // The camera pane is a rounded rectangle, not a device: no bezel at its left edge, its corner is cut.
        let cameraEdge = try await sampleColor(asset: deviceAsset, time: 4.0, x: 650.0 / 1280, y: 360.0 / 720)
        guard cameraEdge.matches(cyan) else {
            throw VerificationError.failed("the camera pane at its edge is \(cameraEdge), expected plain camera pixels")
        }
        let cameraCorner = try await sampleColor(asset: deviceAsset, time: 4.0, x: 641.0 / 1280, y: 73.0 / 720)
        guard !cameraCorner.matches(cyan, tolerance: 60) else {
            throw VerificationError.failed("the camera pane corner is not rounded: \(cameraCorner)")
        }

        // A layout item switches the overlay to split screen and back (source time).
        var timed = WebcamConfiguration()
        timed.layoutItems = [CameraLayoutItem(startMs: 3000, endMs: 6000, layout: .splitScreen)]
        let timedAsset = try await export("webcam-layout-items.mp4", timed)
        try await expect(timedAsset, "layout item", [
            (2.6, 1034, 474, cyan), (2.6, 950, 200, green), (2.6, 310, 90, blue),
            (4.0, 950, 200, cyan), (4.0, 310, 90, black), (4.0, 150, 270, blue),
            (6.5, 950, 200, green), (6.5, 1034, 474, cyan), (6.5, 310, 90, blue)
        ])
        // The default layout can be screen-only with the camera shown only inside an item.
        var itemOnly = WebcamConfiguration()
        itemOnly.layout = .screenOnly
        itemOnly.layoutItems = [CameraLayoutItem(startMs: 3000, endMs: 6000, layout: .splitScreen)]
        try await expect(try await export("webcam-layout-item-only.mp4", itemOnly), "screen-only default with a split item", [
            (2.6, 1100, 500, yellow), (4.0, 960, 360, cyan), (6.5, 1100, 500, yellow)
        ])

        // Cutout with a synthetic camera frame (flat cyan: Vision finds no person) falls back to the rounded overlay and the
        // export succeeds. Vision may hallucinate a person in other flat colours (it does in flat magenta at .balanced),
        // so the pixel checks only run when it returns no mask for the cyan frame on this machine.
        var cutout = WebcamConfiguration()
        cutout.layout = .cutoutCamera
        let cutoutAsset = try await export("webcam-cutout-fallback.mp4", cutout)
        let flatCyan = CIImage(color: CIColor(red: 0, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let visionEmpty = PersonSegmenter.mask(for: flatCyan, quality: .balanced) == nil
        if visionEmpty {
            try await expect(cutoutAsset, "cutout fallback", [(4.0, 1034, 474, cyan), (4.0, 150, 270, blue)])
        } else {
            print("note: Vision found a person in a flat cyan frame; cutout fallback pixel checks skipped")
        }

        // The renderer directly: fallback is recorded and cached, an injected mask gives the masked composite.
        let prepared = try await OfflineExporter.makeRenderer(
            session: session, directory: directory, settings: settings, edit: ExportEdit(webcam: cutout), showsClickEffects: false)
        var renderer = prepared.renderer
        guard let cache = renderer.webcam?.cutout else {
            throw VerificationError.failed("a cutout layout builds no mask cache")
        }
        let sourceFrames = try await ExportFrameSource(asset: AVURLAsset(url: prepared.sourceURL), duration: prepared.sourceDuration, timeline: nil)
        guard let source = try sourceFrames.image(atSource: 4.0) else { throw VerificationError.failed("no fixture frame") }
        defer { sourceFrames.cancel() }
        let camera = CIImage(color: CIColor(red: 0, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let context = CIContext()
        func pixel(_ image: CIImage, _ x: Int, _ y: Int) throws -> RGB {
            guard let cg = context.createCGImage(image, from: renderer.outputRect, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
                  let sampled = NSBitmapImageRep(cgImage: cg).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                throw VerificationError.failed("could not read a rendered pixel")
            }
            return RGB(red: UInt8(sampled.redComponent * 255), green: UInt8(sampled.greenComponent * 255), blue: UInt8(sampled.blueComponent * 255))
        }
        let fallback = renderer.image(source: source, at: 4.0, camera: camera)
        let again = renderer.image(source: source, at: 4.0, camera: camera)
        if visionEmpty {
            guard try pixel(fallback, 1200, 600).matches(cyan), try pixel(again, 1200, 600).matches(cyan),
                  try pixel(fallback, 150, 270).matches(blue) else {
                throw VerificationError.failed("the cutout fallback frame is not the screen plus the rounded camera overlay")
            }
            guard cache.fallbackFrameCount == 2, cache.fallbackTimes == [4000, 4000], cache.segmentationRuns == 1 else {
                throw VerificationError.failed("fallback not recorded or not cached: \(cache.fallbackFrameCount) frames, \(cache.segmentationRuns) runs")
            }
        } else {
            guard cache.segmentationRuns == 1 else { throw VerificationError.failed("the mask was not cached: \(cache.segmentationRuns) runs") }
        }
        // A segmenter that fails (nil) always falls back, is recorded, and never throws.
        let failing = CutoutMaskCache(segmenter: { _ in nil })
        renderer.webcam?.cutout = failing
        let failed = renderer.image(source: source, at: 4.0, camera: camera)
        guard try pixel(failed, 1200, 600).matches(cyan), try pixel(failed, 150, 270).matches(blue),
              failing.fallbackFrameCount == 1, failing.fallbackTimes == [4000] else {
            throw VerificationError.failed("a failing segmenter did not fall back to the rounded overlay")
        }

        // Injected segmenter: the left half of the camera is the person; the cutout sits at the bottom right (920, 450 top-left).
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 120))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120)))
        let injected = CutoutMaskCache(segmenter: { _ in mask })
        renderer.webcam?.cutout = injected
        let masked = renderer.image(source: source, at: 4.0, camera: camera)
        guard try pixel(masked, 1000, 600).matches(cyan), try pixel(masked, 1200, 610).matches(yellow, tolerance: 60),
              try pixel(masked, 1000, 300).matches(green, tolerance: 60), try pixel(masked, 1034, 474).matches(cyan) else {
            throw VerificationError.failed("the masked cutout is not the person over the screen")
        }
        guard injected.fallbackFrameCount == 0, injected.segmentationRuns == 1 else {
            throw VerificationError.failed("the injected mask was not used")
        }
        // Not driven here (live only): Vision finding a real person in a real camera frame and the mask quality.
    }

    // MARK: Edits (timeline, audio, stage, captions)

    /// A separate session with no cursor events (so no zoom or click rings) and time-varying
    /// audio: track 1 ("system" by recorder order) is 440 Hz before 4 s and 660 Hz after; track 2
    /// ("microphone") is a constant 880 Hz. The fixture crosshair moves with the frame index, so its
    /// x position identifies which SOURCE time a rendered frame came from.
    private static func verifyEdits(root: URL, width: Int, height: Int, duration: Double) async throws {
        let directory = root.appendingPathComponent("edit-session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("raw.mp4")
        try await makeFixture(url: rawURL, width: width, height: height, duration: duration)
        let systemURL = directory.appendingPathComponent("system.wav")
        let microphoneURL = directory.appendingPathComponent("microphone.wav")
        try writeToneWAV(to: systemURL, duration: duration) { $0 < 4 ? 440 : 660 }
        try writeToneWAV(to: microphoneURL, duration: duration) { _ in 880 }
        try await muxAudio(into: rawURL, directory: directory, tones: [systemURL, microphoneURL], duration: duration)
        let session = RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height, duration: duration,
            events: [], droppedFrames: 0, eventCaptureAvailable: true,
            audio: AudioCaptureMetadata(systemAudioRequested: true, microphoneRequested: true,
                                        systemAudioSamples: 1, microphoneSamples: 1,
                                        systemAudioDroppedSamples: 0, microphoneDroppedSamples: 0)
        )
        try session.save(in: directory)
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)

        // (a) Trim + split + reorder: keep [0,3] and [5,8], play [5,8] first; mute the microphone in [0,3].
        var timeline = TimelineModel(sourceDuration: duration)
        try timeline.split(atSource: 3)
        try timeline.split(atSource: 5)
        let early = timeline.segments[0].id, middle = timeline.segments[1].id, late = timeline.segments[2].id
        try timeline.delete(segmentID: middle)
        try timeline.move(segmentID: late, toIndex: 0)
        try timeline.setVolume(segmentID: early, to: 0)
        guard timeline.segments.map(\.sourceStart) == [5, 0], abs(timeline.playbackDuration - 6) < 1e-9 else {
            throw VerificationError.failed("edit fixture timeline is \(timeline.segments)")
        }
        var captionConfig = CaptionConfiguration()
        captionConfig.backgroundColor = "#00ffff"
        captionConfig.backgroundOpacity = 1
        let captionTrack = CaptionTrack(locale: "en-US", cues: [
            CaptionCue(startMs: 3500, endMs: 4500, text: "TRIMMED"),
            CaptionCue(startMs: 5500, endMs: 6500, text: "HELLO")
        ])
        let editedURL = directory.appendingPathComponent("edited.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: editedURL, settings: settings,
                                           edit: ExportEdit(timeline: timeline, captions: (captionTrack, captionConfig)))
        let edited = AVURLAsset(url: editedURL)
        let editedDuration = try await edited.load(.duration).seconds
        guard abs(editedDuration - 6) < 0.1 else {
            throw VerificationError.failed("trimmed/reordered export lasts \(editedDuration)s, expected 6s (Σ segments)")
        }
        // Playback → source: [0,3) shows source 5…8, [3,6) shows source 0…3.
        for (playback, source) in [(0.5, 5.5), (2.0, 7.0), (3.3, 0.3), (4.0, 1.0), (5.5, 2.5)] {
            let measured = try await crosshairSourceTime(asset: edited, time: playback)
            guard abs(measured - source) < 0.1 else {
                throw VerificationError.failed("edited frame at playback \(playback)s shows source \(measured)s, expected \(source)s")
            }
            let quadrant = try await sampleColor(asset: edited, time: playback, x: 0.3, y: 0.7)
            guard quadrant.matches(colorQuadrant(x: 0.3, y: 0.7)) else {
                throw VerificationError.failed("edited frame at \(playback)s has \(quadrant) where the red quadrant belongs")
            }
        }

        // (e) Captions follow SOURCE time: HELLO (source 5.5–6.5 s) plays at 0.5–1.5 s; the cue in
        // the trimmed range never appears.
        for (playback, visible) in [(0.2, false), (1.0, true), (1.4, true), (2.0, false), (2.9, false), (4.0, false), (5.9, false)] {
            let cyan = try await captionPixels(asset: edited, time: playback)
            guard visible ? cyan > 50 : cyan == 0 else {
                throw VerificationError.failed("caption pixels at playback \(playback)s: \(cyan), expected \(visible ? "a caption" : "none")")
            }
        }

        // (c) Audio follows the plan: per track, aligned to the video within 0.1 s; the system track
        // plays the 660 Hz part first and the 440 Hz part after the reorder; the microphone is
        // audible in [0,3) and muted (volume 0) in [3,6).
        let editedAudio = try await edited.loadTracks(withMediaType: .audio)
        guard editedAudio.count == 2 else {
            throw VerificationError.failed("edited export has \(editedAudio.count) audio tracks, expected 2")
        }
        for track in editedAudio {
            let range = try await track.load(.timeRange)
            guard abs(range.start.seconds) < 0.05, abs(range.end.seconds - editedDuration) < 0.1 else {
                throw VerificationError.failed("edited audio track spans \(range.start.seconds)…\(range.end.seconds)s, video \(editedDuration)s")
            }
        }
        let system = try await decodeAudio(asset: edited, track: editedAudio[0])
        let microphone = try await decodeAudio(asset: edited, track: editedAudio[1])
        let systemFirst = analyze(system, from: 0.5, to: 2.5), systemSecond = analyze(system, from: 3.5, to: 5.5)
        let micFirst = analyze(microphone, from: 0.5, to: 2.5), micSecond = analyze(microphone, from: 3.5, to: 5.5)
        guard abs(systemFirst.frequency - 660) < 30, abs(systemSecond.frequency - 440) < 25, systemSecond.rms > 0.05 else {
            throw VerificationError.failed("reordered system audio measured \(systemFirst) then \(systemSecond); expected 660 Hz then 440 Hz")
        }
        guard abs(micFirst.frequency - 880) < 40, micFirst.rms > 0.05, micSecond.rms < 0.002 else {
            throw VerificationError.failed("microphone audio measured \(micFirst) then \(micSecond); expected 880 Hz then muted")
        }

        // (b) Speed: [0,2] at 1×, [2,4] at timeScale 2 (half speed), the rest deleted → 2 + 4 = 6 s.
        var slow = TimelineModel(sourceDuration: duration)
        try slow.split(atSource: 2)
        let rest = try slow.split(atSource: 4)
        try slow.delete(segmentID: rest)
        try slow.setTimeScale(segmentID: slow.segments[1].id, to: 2)
        let slowURL = directory.appendingPathComponent("slow.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: slowURL, settings: settings,
                                           edit: ExportEdit(timeline: slow))
        let slowAsset = AVURLAsset(url: slowURL)
        let slowDuration = try await slowAsset.load(.duration).seconds
        guard abs(slowDuration - 6) < 0.1 else {
            throw VerificationError.failed("half-speed export lasts \(slowDuration)s, expected 6s")
        }
        for (playback, source) in [(1.0, 1.0), (3.0, 2.5), (4.0, 3.0), (5.0, 3.5)] {
            let measured = try await crosshairSourceTime(asset: slowAsset, time: playback)
            guard abs(measured - source) < 0.1 else {
                throw VerificationError.failed("half-speed frame at playback \(playback)s shows source \(measured)s, expected \(source)s")
            }
        }
        let slowTracks = try await slowAsset.loadTracks(withMediaType: .audio)
        for track in slowTracks {
            let range = try await track.load(.timeRange)
            guard abs(range.end.seconds - slowDuration) < 0.1 else {
                throw VerificationError.failed("half-speed audio ends at \(range.end.seconds)s, video at \(slowDuration)s")
            }
        }
        // Pitch is preserved through the stretch (spectral time-pitch).
        let slowSystem = analyze(try await decodeAudio(asset: slowAsset, track: slowTracks[0]), from: 2.5, to: 5.5)
        guard abs(slowSystem.frequency - 440) < 25, slowSystem.rms > 0.05 else {
            throw VerificationError.failed("half-speed system audio measured \(slowSystem); expected pitch-preserved 440 Hz")
        }

        // (d) Stage on 9:16: the background replaces the black bars; padding 0.1 × 404 px puts the
        // 16:9 content in a 324×182 rect centered in the canvas.
        var stage = StageStyle()
        stage.paddingRatio = 0.1
        stage.cornerRadius = 0
        stage.shadow.intensity = 0
        stage.background = .color("#ff8000")
        let stageURL = directory.appendingPathComponent("stage.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: stageURL,
                                           settings: ExportSettings(fps: 30, height: 720, aspectRatio: .preset(.tall)),
                                           edit: ExportEdit(stage: stage))
        let stageAsset = AVURLAsset(url: stageURL)
        let orange = RGB(red: 255, green: 128, blue: 0)
        for point in [(0.03, 0.03), (0.97, 0.97), (0.5, 0.05), (0.5, 0.95), (0.05, 0.5)] {
            let pixel = try await sampleColor(asset: stageAsset, time: 1.0, x: point.0, y: point.1)
            guard pixel.matches(orange) else {
                throw VerificationError.failed("stage background at \(point) is \(pixel), expected orange")
            }
        }
        let content = (minX: 40.0, width: 324.0, minY: (720 - 182.0) / 2, height: 182.0)
        // Points clear of the fixture grid and of the crosshair at 1 s (source x 200, y 113).
        for source in [(0.2, 0.4), (0.9, 0.4), (0.2, 0.6), (0.9, 0.6)] {
            let pixel = try await sampleColor(asset: stageAsset, time: 1.0,
                                              x: (content.minX + source.0 * content.width) / 404,
                                              y: (content.minY + source.1 * content.height) / 720)
            guard pixel.matches(colorQuadrant(x: source.0, y: source.1)) else {
                throw VerificationError.failed("stage content at source \(source) is \(pixel), expected \(colorQuadrant(x: source.0, y: source.1))")
            }
        }
        for (x, y) in [(content.minX - 8, 360.0), (content.minX + content.width + 8, 360.0), (202.0, content.minY - 8)] {
            let pixel = try await sampleColor(asset: stageAsset, time: 1.0, x: x / 404, y: y / 720)
            guard pixel.matches(orange) else {
                throw VerificationError.failed("stage padding just outside the content at (\(x), \(y)) is \(pixel)")
            }
        }

        var deviceStage = stage
        deviceStage.deviceMockup = DeviceMockupConfiguration(enabled: true, deviceID: "laptop", finish: "dark")
        let deviceURL = directory.appendingPathComponent("stage-device.mp4")
        try await OfflineExporter().export(session: session, directory: directory, destination: deviceURL,
                                           settings: ExportSettings(fps: 30, height: 720, aspectRatio: .preset(.tall)),
                                           edit: ExportEdit(stage: deviceStage))
        let deviceAsset = AVURLAsset(url: deviceURL)
        let deviceRect = (minX: 40.0, width: 324.0, minY: 257.4, height: 205.2)
        let screen = (x: deviceRect.minX + deviceRect.width * 58 / 1200,
                      y: deviceRect.minY + deviceRect.height * 34 / 760,
                      width: deviceRect.width * 1084 / 1200,
                      height: deviceRect.height * 650 / 760)
        let screenPixel = try await sampleColor(asset: deviceAsset, time: 1.0,
            x: (screen.x + screen.width * 0.2) / 404, y: (screen.y + screen.height * 0.4) / 720)
        guard screenPixel.matches(colorQuadrant(x: 0.2, y: 0.4)) else {
            throw VerificationError.failed("device aperture contains \(screenPixel), expected screen fixture color")
        }
        let bezel = try await sampleColor(asset: deviceAsset, time: 1.0,
            x: (deviceRect.minX + deviceRect.width * 0.025) / 404, y: (deviceRect.minY + deviceRect.height * 0.45) / 720)
        guard bezel.matches(RGB(red: 37, green: 41, blue: 50), tolerance: 35) else {
            throw VerificationError.failed("device bezel pixel is \(bezel)")
        }
        let deviceBackground = try await sampleColor(asset: deviceAsset, time: 1.0, x: 0.03, y: 0.03)
        guard deviceBackground.matches(orange) else {
            throw VerificationError.failed("stage background outside device is \(deviceBackground)")
        }

        // GIF honors the same edit: 6 s at 15 fps, frame at playback 4 s shows source 1 s.
        let gifURL = directory.appendingPathComponent("edited.gif")
        try await OfflineExporter().export(session: session, directory: directory, destination: gifURL,
                                           settings: .gifDefault, edit: ExportEdit(timeline: timeline))
        guard let gif = CGImageSourceCreateWithURL(gifURL as CFURL, nil),
              abs(CGImageSourceGetCount(gif) - 90) <= 1,
              let gifFrame = CGImageSourceCreateImageAtIndex(gif, 60, nil) else {
            throw VerificationError.failed("edited GIF does not have the 6 s playback length")
        }
        let gifSource = try crosshairSourceTime(NSBitmapImageRep(cgImage: gifFrame))
        guard abs(gifSource - 1.0) < 0.1 else {
            throw VerificationError.failed("edited GIF frame at playback 4 s shows source \(gifSource)s, expected 1 s")
        }

        // (f) ExportEdit.load: absent files stay nil; present ones are picked up.
        let empty = try ExportEdit.load(from: directory, session: session)
        guard empty.isEmpty else { throw VerificationError.failed("ExportEdit.load invented edits for a bare session") }
        var project = ViddeoProject.create(from: session, name: "Edit")
        try project.apply(timeline)
        try project.save(to: directory)
        try stage.save(in: directory)
        try captionTrack.save(to: directory)
        let loaded = try ExportEdit.load(from: directory, session: session)
        guard loaded.timeline == timeline, loaded.stage == stage, loaded.captions?.track == captionTrack,
              loaded.captions?.configuration == CaptionConfiguration() else {
            throw VerificationError.failed("ExportEdit.load did not pick up project, stage and captions")
        }
        var disabled = captionConfig
        disabled.enabled = false
        try disabled.save(in: directory)
        guard try ExportEdit.load(from: directory, session: session).captions == nil else {
            throw VerificationError.failed("ExportEdit.load kept captions that are disabled")
        }
        try captionConfig.save(in: directory)
        guard try ExportEdit.load(from: directory, session: session).captions?.configuration == captionConfig else {
            throw VerificationError.failed("ExportEdit.load ignored captions-config.json")
        }
    }

    /// Source time of the fixture crosshair in a full-width content frame: the vertical line's x
    /// on a row near the top (source y ≈ 0.05, clear of the horizontal grid), excluding grid columns.
    private static func crosshairSourceTime(asset: AVAsset, time: Double) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        return try crosshairSourceTime(NSBitmapImageRep(cgImage: image))
    }

    private static func crosshairSourceTime(_ rep: NSBitmapImageRep) throws -> Double {
        let y = Int(0.05 * Double(rep.pixelsHigh))
        var runs: [(start: Int, end: Int)] = []
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.redComponent > 0.75, color.greenComponent > 0.75, color.blueComponent > 0.75 else { continue }
            if let last = runs.last, last.end == x - 1 { runs[runs.count - 1].end = x } else { runs.append((x, x)) }
        }
        let scale = Double(rep.pixelsWide) / 640
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

    // MARK: Keyboard shortcut overlay

    /// Exports the same fixture with and without the overlay; the frames may differ only inside the
    /// bottom-center cap row and only while the press is displayed (⌘K at 2.0 s shows 1.9–3.5 s).
    private static func verifyShortcuts(root: URL, width: Int, height: Int, duration: Double) async throws {
        let directory = root.appendingPathComponent("shortcut-session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await makeFixture(url: directory.appendingPathComponent("raw.mp4"), width: width, height: height, duration: duration)
        let events = [ShortcutEvent(time: 2.0, keyCode: 40, key: "K", modifiers: .command)]
        var session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height, duration: duration,
                                       events: [], droppedFrames: 0, eventCaptureAvailable: true)
        session.shortcuts = events
        session.shortcutCaptureAvailable = true
        try session.save(in: directory)
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)
        func export(_ name: String, _ edit: ExportEdit?) async throws -> AVURLAsset {
            let url = directory.appendingPathComponent(name)
            try await OfflineExporter().export(session: session, directory: directory, destination: url, settings: settings, edit: edit)
            return AVURLAsset(url: url)
        }
        var configuration = ShortcutOverlayConfiguration()
        let plain = try await export("shortcuts-off.mp4", ExportEdit(shortcuts: (events, configuration)))
        configuration.enabled = true
        let shown = try await export("shortcuts-on.mp4", ExportEdit(shortcuts: (events, configuration)))
        guard ExportEdit(shortcuts: (events, ShortcutOverlayConfiguration())).isEmpty else {
            throw VerificationError.failed("a disabled shortcut overlay changes the export")
        }
        // Expected cap row at 1280×720 (top-left pixel coordinates): two caps, height 72, 43 px above the bottom.
        let outputWidth = 1280.0, outputHeight = 720.0
        let capHeight = outputHeight * configuration.sizeRatio
        let rowWidth = capHeight * 2 + capHeight * ShortcutOverlayRenderer.gapRatio
        let row = CGRect(x: outputWidth / 2 - rowWidth / 2, y: outputHeight - capHeight * (1 + ShortcutOverlayRenderer.bottomMarginRatio),
                         width: rowWidth, height: capHeight)
        for (time, visible) in [(0.5, false), (1.5, false), (2.5, true), (3.2, true), (4.5, false), (6.0, false)] {
            let (inside, outside) = try await frameDifference(plain, shown, time: time, region: row.insetBy(dx: -24, dy: -24))
            if visible {
                guard inside > Int(row.width * row.height / 16 * 0.15) else {
                    throw VerificationError.failed("shortcut overlay missing at \(time)s inside the expected cap row (\(inside) changed samples)")
                }
                guard outside < 30 else {
                    throw VerificationError.failed("shortcut overlay changed \(outside) samples outside the cap row at \(time)s")
                }
            } else {
                guard inside + outside < 30 else {
                    throw VerificationError.failed("shortcut overlay visible at \(time)s, outside its display window (\(inside + outside) changed samples)")
                }
            }
        }
        // ExportEdit.load: only an enabled configuration plus captured events produce the overlay.
        guard try ExportEdit.load(from: directory, session: session).shortcuts == nil else {
            throw VerificationError.failed("ExportEdit.load enabled shortcuts without a configuration")
        }
        try configuration.save(in: directory)
        let loaded = try ExportEdit.load(from: directory, session: session)
        guard loaded.shortcuts?.events == events, loaded.shortcuts?.configuration == configuration else {
            throw VerificationError.failed("ExportEdit.load ignored shortcuts-config.json")
        }
        var noCapture = session
        noCapture.shortcuts = nil
        guard try ExportEdit.load(from: directory, session: noCapture).shortcuts == nil else {
            throw VerificationError.failed("ExportEdit.load created an overlay for a session without captured shortcuts")
        }
        configuration.enabled = false
        try configuration.save(in: directory)
        guard try ExportEdit.load(from: directory, session: session).shortcuts == nil else {
            throw VerificationError.failed("ExportEdit.load kept a disabled shortcut overlay")
        }
    }

    // MARK: Masks

    /// Luma (0...1) mean, standard deviation and maximum over `region` (normalized, top-left origin) of the frame at `time`.
    private static func lumaStats(_ asset: AVAsset, time: Double, region: CGRect) async throws -> (mean: Double, std: Double, max: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let rep = NSBitmapImageRep(cgImage: try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        var values: [Double] = []
        for y in stride(from: Int(region.minY * h), to: Int(region.maxY * h), by: 2) {
            for x in stride(from: Int(region.minX * w), to: Int(region.maxX * w), by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                values.append(0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
            }
        }
        guard !values.isEmpty else { throw VerificationError.failed("empty mask measurement region \(region)") }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot(), values.max() ?? 0)
    }

    /// Masks on a checkerboard recording (every pixel is black or white, so a blur is unmistakable):
    /// a sensitive-data mask blurs its rectangle only inside its time range; a highlight mask dims
    /// everything but its rectangle (80 % black, composited in linear light, so white lands near 0.5); a mask follows a 2x zoom; `masks.json` reaches the export through
    /// `ExportEdit.load` and the exporter's own sidecar fallback, and an explicit empty configuration overrides it.
    private static func verifyMasks(root: URL, width: Int, height: Int, duration: Double) async throws {
        let settings = ExportSettings(fps: 30, height: 720, codec: .h264)
        func makeSession(_ name: String, events: [CursorEvent]) async throws -> (RecordingSession, URL) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await makeFixture(url: directory.appendingPathComponent("raw.mp4"), width: width, height: height,
                                  duration: duration, checker: true)
            let session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height,
                                           duration: duration, events: events, droppedFrames: 0, eventCaptureAvailable: true)
            try session.save(in: directory)
            return (session, directory)
        }
        func export(_ session: RecordingSession, _ directory: URL, _ name: String, _ edit: ExportEdit?) async throws -> AVURLAsset {
            let url = directory.appendingPathComponent(name)
            try await OfflineExporter().export(session: session, directory: directory, destination: url,
                                               showsClickEffects: false, settings: settings, edit: edit)
            return AVURLAsset(url: url)
        }
        func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            guard condition else { throw VerificationError.failed("masks: \(message())") }
        }

        let (session, directory) = try await makeSession("mask-session", events: [])
        // Sensitive data over source rect x 0.25...0.5, y 0.3...0.6 for source seconds 2...4.
        let rect = CGRect(x: 0.25, y: 0.3, width: 0.25, height: 0.3)
        let inner = rect.insetBy(dx: 0.04, dy: 0.06)
        let sensitive = MaskConfiguration(masks: [TimelineMask(sourceStart: 2, sourceEnd: 4, bounds: [rect])])
        let plain = try await export(session, directory, "mask-plain.mp4", nil)
        let blurred = try await export(session, directory, "mask-sensitive.mp4", ExportEdit(masks: sensitive))
        let sharpReference = try await lumaStats(plain, time: 3, region: inner)
        try require(sharpReference.std > 0.4, "the checkerboard fixture is not high contrast (std \(sharpReference.std))")
        let inside = try await lumaStats(blurred, time: 3, region: inner)
        try require(inside.std < 0.12, "sensitive-data mask left the region sharp inside its time range (std \(inside.std))")
        let beside = try await lumaStats(blurred, time: 3, region: CGRect(x: 0.6, y: 0.3, width: 0.3, height: 0.3))
        try require(beside.std > 0.4, "sensitive-data mask blurred outside its rectangle (std \(beside.std))")
        for time in [1.0, 5.0, 7.0] {
            let outsideTime = try await lumaStats(blurred, time: time, region: inner)
            try require(outsideTime.std > 0.4, "sensitive-data mask is visible at \(time)s, outside its time range (std \(outsideTime.std))")
        }

        // Highlight: everything outside x 0.4...0.6, y 0.4...0.6 is dimmed by 0.8, the rectangle is untouched.
        let highlightRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let highlight = MaskConfiguration(masks: [TimelineMask(sourceStart: 2, sourceEnd: 4, bounds: [highlightRect],
                                                               kind: .highlight, highlightOpacity: 0.8)])
        let dimmed = try await export(session, directory, "mask-highlight.mp4", ExportEdit(masks: highlight))
        let dimOutside = try await lumaStats(dimmed, time: 3, region: CGRect(x: 0.05, y: 0.05, width: 0.25, height: 0.25))
        try require(dimOutside.mean < 0.4 && dimOutside.max < 0.7, "highlight did not darken outside its rectangle (mean \(dimOutside.mean), max \(dimOutside.max))")
        let dimInside = try await lumaStats(dimmed, time: 3, region: highlightRect.insetBy(dx: 0.03, dy: 0.04))
        try require(dimInside.std > 0.4 && dimInside.max > 0.8, "highlight darkened pixels inside its rectangle (std \(dimInside.std), max \(dimInside.max))")
        let undimmed = try await lumaStats(dimmed, time: 1, region: CGRect(x: 0.05, y: 0.05, width: 0.25, height: 0.25))
        try require(undimmed.mean > 0.45 && undimmed.max > 0.9, "highlight dims outside its time range (mean \(undimmed.mean), max \(undimmed.max))")

        // The editor's explicit empty configuration, ExportEdit.load and the exporter's masks.json fallback.
        try require(try ExportEdit.load(from: directory, session: session).masks == nil, "ExportEdit.load invented masks without masks.json")
        try sensitive.save(to: directory)
        let loaded = try ExportEdit.load(from: directory, session: session)
        try require(loaded.masks == sensitive && !loaded.isEmpty, "ExportEdit.load ignored masks.json")
        let fromSidecar = try await export(session, directory, "mask-sidecar.mp4", nil)
        let sidecarStats = try await lumaStats(fromSidecar, time: 3, region: inner)
        try require(sidecarStats.std < 0.12, "the exporter ignored masks.json without an explicit edit (std \(sidecarStats.std))")
        let overridden = try await export(session, directory, "mask-override.mp4", ExportEdit(masks: MaskConfiguration()))
        let overrideStats = try await lumaStats(overridden, time: 3, region: inner)
        try require(overrideStats.std > 0.4, "an explicit empty mask configuration did not override masks.json (std \(overrideStats.std))")

        // Zoom: the click at 3 s zooms 2x into the top-right quadrant (source x 0.5...1, y 0...0.5), so a mask over
        // source x 0.52...0.68, y 0.04...0.2 lands at output x 0.04...0.36, y 0.08...0.4, not where it sits unzoomed.
        let (zoomSession, zoomDirectory) = try await makeSession("mask-zoom-session", events: [
            CursorEvent(time: 1.0, x: 0.25, y: 0.25, kind: .move),
            CursorEvent(time: 3.0, x: 0.75, y: 0.25, kind: .down),
            CursorEvent(time: 3.08, x: 0.75, y: 0.25, kind: .up),
            CursorEvent(time: 5.0, x: 0.75, y: 0.75, kind: .move)
        ])
        let zoomFrame = ZoomTimeline(session: zoomSession).frame(at: 3.5)
        try require(abs(zoomFrame.scale - 2) < 0.05 && abs(zoomFrame.centerX - 0.75) < 0.08 && abs(zoomFrame.centerY - 0.25) < 0.08,
                    "the zoom fixture did not settle at 2x on the top-right quadrant (\(zoomFrame.scale), \(zoomFrame.centerX), \(zoomFrame.centerY))")
        let zoomRect = CGRect(x: 0.52, y: 0.04, width: 0.16, height: 0.16)
        let zoomMask = MaskConfiguration(masks: [TimelineMask(sourceStart: 2, sourceEnd: 6, bounds: [zoomRect])])
        let zoomed = try await export(zoomSession, zoomDirectory, "mask-zoom.mp4", ExportEdit(masks: zoomMask))
        let mapped = CGRect(x: 0.04, y: 0.08, width: 0.32, height: 0.32)
        let mappedStats = try await lumaStats(zoomed, time: 3.5, region: mapped.insetBy(dx: 0.05, dy: 0.06))
        try require(mappedStats.std < 0.12, "the mask did not follow the 2x zoom to the mapped output region (std \(mappedStats.std))")
        let unzoomedPlace = try await lumaStats(zoomed, time: 3.5, region: CGRect(x: 0.45, y: 0.15, width: 0.4, height: 0.3))
        try require(unzoomedPlace.std > 0.4, "the mask stayed at its unzoomed output position (std \(unzoomedPlace.std))")
        let zoomedSharp = try await lumaStats(zoomed, time: 3.5, region: CGRect(x: 0.6, y: 0.55, width: 0.3, height: 0.3))
        try require(zoomedSharp.std > 0.4, "the mask blurred outside its mapped rectangle under zoom (std \(zoomedSharp.std))")
    }

    /// Counts samples (every 4th pixel) whose luma differs by more than 40 inside and outside `region` (top-left pixels).
    private static func frameDifference(_ first: AVAsset, _ second: AVAsset, time: Double, region: CGRect) async throws -> (inside: Int, outside: Int) {
        func rep(_ asset: AVAsset) async throws -> NSBitmapImageRep {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return NSBitmapImageRep(cgImage: try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
        }
        let a = try await rep(first), b = try await rep(second)
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { throw VerificationError.failed("shortcut frames differ in size") }
        var inside = 0, outside = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: a.pixelsWide, by: 4) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let lumaP = 0.299 * p.redComponent + 0.587 * p.greenComponent + 0.114 * p.blueComponent
                let lumaQ = 0.299 * q.redComponent + 0.587 * q.greenComponent + 0.114 * q.blueComponent
                guard abs(lumaP - lumaQ) > 40.0 / 255 else { continue }
                if region.contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
            }
        }
        return (inside, outside)
    }

    /// Fully opaque cyan caption-pill pixels in the lower part of the frame (none occur in the fixture).
    private static func captionPixels(asset: AVAsset, time: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let rep = NSBitmapImageRep(cgImage: try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
        var count = 0
        for y in stride(from: rep.pixelsHigh * 3 / 4, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.35, color.greenComponent > 0.7, color.blueComponent > 0.7 { count += 1 }
            }
        }
        return count
    }

    private static func decodeAudio(asset: AVAsset, track: AVAssetTrack) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw VerificationError.failed("could not decode an audio track") }
        reader.add(output)
        guard reader.startReading() else { throw VerificationError.failed("could not start audio decoding") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            samples += chunk
        }
        guard reader.status == .completed else { throw VerificationError.failed("audio decoding did not complete") }
        return samples
    }

    private struct ToneMeasure: CustomStringConvertible {
        var frequency: Double
        var rms: Double
        var description: String { String(format: "%.0f Hz rms %.4f", frequency, rms) }
    }

    private static func analyze(_ samples: [Float], from start: Double, to end: Double) -> ToneMeasure {
        let lower = min(samples.count, Int(start * 48_000)), upper = min(samples.count, Int(end * 48_000))
        guard upper - lower > 100 else { return ToneMeasure(frequency: 0, rms: 0) }
        var crossings = 0, energy = 0.0
        for index in lower..<upper {
            energy += Double(samples[index]) * Double(samples[index])
            if index > lower, samples[index - 1] <= 0, samples[index] > 0 { crossings += 1 }
        }
        let seconds = Double(upper - lower) / 48_000
        return ToneMeasure(frequency: Double(crossings) / seconds, rms: (energy / Double(upper - lower)).squareRoot())
    }

    /// Phase-continuous mono 48 kHz tone whose frequency may change over time.
    private static func writeToneWAV(to url: URL, duration: Double, frequency: (Double) -> Double) throws {
        let sampleRate = 48_000
        let count = Int(Double(sampleRate) * duration)
        var data = Data()
        func put16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        func put32(_ value: UInt32) {
            data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
        }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(count * 2))
        var phase = 0.0
        for index in 0..<count {
            put16(UInt16(bitPattern: Int16(sin(phase) * 10_000)))
            phase += 2 * Double.pi * frequency(Double(index) / Double(sampleRate)) / Double(sampleRate)
        }
        try data.write(to: url)
    }

    private static func colorQuadrant(x: Double, y: Double) -> RGB {
        switch (x >= 0.5, y >= 0.5) {
        case (false, false): RGB(red: 32, green: 48, blue: 230)
        case (true, false): RGB(red: 32, green: 220, blue: 48)
        case (false, true): RGB(red: 230, green: 48, blue: 32)
        case (true, true): RGB(red: 220, green: 210, blue: 32)
        }
    }

    private static func centerColor(asset: AVAsset, time: Double) async throws -> RGB {
        try await sampleColor(asset: asset, time: time, x: 0.5, y: 0.5)
    }

    private static func markerBounds(asset: AVAsset, time: Double) async throws -> CGRect {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let rep = NSBitmapImageRep(cgImage: image)
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.55, color.greenComponent < 0.35, color.blueComponent > 0.55 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw VerificationError.failed("fixture marker was not found") }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func sampleColor(asset: AVAsset, time: Double, x: Double, y: Double) async throws -> RGB {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let rep = NSBitmapImageRep(cgImage: image)
        guard let color = rep.colorAt(x: Int(x * Double(rep.pixelsWide)), y: Int(y * Double(rep.pixelsHigh)))?
            .usingColorSpace(.deviceRGB) else {
            throw VerificationError.failed("could not read a sampled output pixel")
        }
        return RGB(red: UInt8(color.redComponent * 255),
                  green: UInt8(color.greenComponent * 255),
                  blue: UInt8(color.blueComponent * 255))
    }
}

private struct RGB: CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    var description: String { "rgb(\(red),\(green),\(blue))" }

    /// Saturated colors shift after YCbCr encoding, so camera checks use a looser tolerance.
    func matches(_ other: RGB, tolerance: Int = 75) -> Bool {
        abs(Int(red) - Int(other.red)) < tolerance
            && abs(Int(green) - Int(other.green)) < tolerance
            && abs(Int(blue) - Int(other.blue)) < tolerance
    }
}

private enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let reason): reason }
    }
}
