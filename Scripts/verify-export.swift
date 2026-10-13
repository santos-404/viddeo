import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation

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
        try await OfflineExporter().export(session: session, directory: directory, destination: outputURL)

        let outputAsset = AVURLAsset(url: outputURL)
        let outDuration = try await outputAsset.load(.duration).seconds
        guard abs(outDuration - duration) < 0.2 else {
            throw VerificationError.failed("duration is \(outDuration)s, expected \(duration)s")
        }
        let tracks = try await outputAsset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VerificationError.failed("export has no video track") }
        let naturalSize = try await track.load(.naturalSize)
        guard Int(naturalSize.width.rounded()) == width,
              Int(naturalSize.height.rounded()) == height else {
            throw VerificationError.failed("export dimensions are \(naturalSize), expected \(width)×\(height)")
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

        print("Offline export verified: H.264, \(width)×\(height), \(outDuration)s, 2× marker scale, filled edges.")
    }

    private static func makeFixture(url: URL, width: Int, height: Int, duration: Double,
                                    transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
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
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else {
                throw VerificationError.failed("writer did not create a pixel buffer pool")
            }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else {
                throw VerificationError.failed("could not allocate fixture frame")
            }
            paintFixture(buffer, width: width, height: height, frameIndex: frameIndex)
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

    func matches(_ other: RGB) -> Bool {
        abs(Int(red) - Int(other.red)) < 75
            && abs(Int(green) - Int(other.green)) < 75
            && abs(Int(blue) - Int(other.blue)) < 75
    }
}

private enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let reason): reason }
    }
}
