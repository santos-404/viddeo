import AVFoundation
import CoreImage
import CoreMedia
import Foundation

@MainActor
final class OfflineExporter {
    enum ExportError: LocalizedError {
        case invalidSession(String)
        case missingVideoTrack
        case unsupportedOrientation
        case dimensionMismatch(expected: String, actual: String)
        case durationMismatch(expected: Double, actual: Double)
        case outputExists(URL)
        case outputWouldReplaceInput
        case unsupportedOutput

        var errorDescription: String? {
            switch self {
            case .invalidSession(let reason): "The recording session is invalid: \(reason)"
            case .missingVideoTrack: "The raw recording does not contain a video track."
            case .unsupportedOrientation:
                "This export path requires raw video with an identity track transform."
            case .dimensionMismatch(let expected, let actual):
                "The raw recording dimensions/orientation (\(actual)) do not match the session (\(expected))."
            case .durationMismatch(let expected, let actual):
                "The raw recording duration (\(actual)s) does not match the session (\(expected)s)."
            case .outputExists(let url): "The export destination already exists: \(url.path)"
            case .outputWouldReplaceInput: "The export destination cannot be the raw recording."
            case .unsupportedOutput: "The H.264 MP4 export preset is unavailable for this recording."
            }
        }
    }

    func export(session: RecordingSession, directory: URL, destination: URL) async throws {
        guard session.version == 1 else {
            throw ExportError.invalidSession("unsupported session version \(session.version)")
        }
        guard (2...8192).contains(session.width), (2...8192).contains(session.height),
              session.duration.isFinite, session.duration > 0, session.duration <= 12 * 60 * 60,
              session.events.count <= 250_000 else {
            throw ExportError.invalidSession("dimensions, duration, or event count exceed supported bounds")
        }
        let filename = session.videoFilename
        guard !filename.isEmpty, filename != ".", filename != "..",
              URL(fileURLWithPath: filename).lastPathComponent == filename,
              !filename.contains("/") else {
            throw ExportError.invalidSession("videoFilename must be a simple filename in the session directory")
        }
        guard directory.isFileURL, destination.isFileURL else {
            throw ExportError.invalidSession("source and destination must be file URLs")
        }

        let sessionDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = sessionDirectory.appendingPathComponent(session.videoFilename, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard sourceURL.deletingLastPathComponent() == sessionDirectory else {
            throw ExportError.invalidSession("videoFilename must resolve inside the session directory")
        }
        let outputURL = destination.standardizedFileURL
        guard sourceURL != outputURL else { throw ExportError.outputWouldReplaceInput }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ExportError.outputExists(outputURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw ExportError.missingVideoTrack }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformTolerance: CGFloat = 0.0001
        guard abs(preferredTransform.a - 1) < transformTolerance,
              abs(preferredTransform.b) < transformTolerance,
              abs(preferredTransform.c) < transformTolerance,
              abs(preferredTransform.d - 1) < transformTolerance,
              abs(preferredTransform.tx) < transformTolerance,
              abs(preferredTransform.ty) < transformTolerance else {
            throw ExportError.unsupportedOrientation
        }
        let orientedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform).standardized
        let orientedWidth = Int(orientedBounds.width.rounded())
        let orientedHeight = Int(orientedBounds.height.rounded())
        guard orientedWidth == session.width, orientedHeight == session.height else {
            throw ExportError.dimensionMismatch(
                expected: "\(session.width)×\(session.height)",
                actual: "\(orientedWidth)×\(orientedHeight)"
            )
        }

        let duration = try await asset.load(.duration)
        let actualDuration = duration.seconds
        guard actualDuration.isFinite, actualDuration > 0 else {
            throw ExportError.invalidSession("the raw recording has no valid duration")
        }
        let durationTolerance = max(0.1, 2.0 / 30.0)
        guard abs(actualDuration - session.duration) <= durationTolerance else {
            throw ExportError.durationMismatch(expected: session.duration, actual: actualDuration)
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ), exporter.supportedFileTypes.contains(.mp4) else {
            throw ExportError.unsupportedOutput
        }

        let zoomConfiguration = try ZoomConfiguration.load(in: directory)
        try zoomConfiguration.validate()
        let timeline = ZoomTimeline(session: session, configuration: zoomConfiguration)
        let width = session.width
        let height = session.height
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).partial.mp4")
        let composition = try await AVVideoComposition(
            applyingFiltersTo: asset,
            applier: { request in
                let time = request.compositionTime.seconds
                let frame = timeline.frame(at: time)
                let outputRect = CGRect(x: 0, y: 0, width: width, height: height)

                // The recorder writes identity-oriented frames. Rotated source tracks are
                // rejected above until their CI request coordinate space is verified.
                let source = request.sourceImage
                let bounds = source.extent
                let image = source.transformed(
                    by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                )
                let scale = frame.scale.isFinite ? max(1, frame.scale) : 1
                let cropWidth = CGFloat(width) / CGFloat(scale)
                let cropHeight = CGFloat(height) / CGFloat(scale)
                let centerX = CGFloat(frame.centerX.isFinite ? frame.centerX : 0.5) * CGFloat(width)
                // ZoomTimeline uses a top-left normalized origin; Core Image uses bottom-left.
                let centerY = CGFloat(1 - (frame.centerY.isFinite ? frame.centerY : 0.5)) * CGFloat(height)
                let clampedX = min(max(centerX, cropWidth / 2), CGFloat(width) - cropWidth / 2)
                let clampedY = min(max(centerY, cropHeight / 2), CGFloat(height) - cropHeight / 2)
                let crop = CGRect(
                    x: clampedX - cropWidth / 2,
                    y: clampedY - cropHeight / 2,
                    width: cropWidth,
                    height: cropHeight
                )
                let scaled = image.cropped(to: crop).transformed(by: CGAffineTransform(
                    a: CGFloat(scale), b: 0, c: 0, d: CGFloat(scale),
                    tx: -crop.minX * CGFloat(scale), ty: -crop.minY * CGFloat(scale)
                ))
                return AVCIImageFilteringResult(
                    resultImage: scaled.cropped(to: outputRect),
                    ciContext: nil
                )
            }
        )
        exporter.videoComposition = composition

        do {
            try await exporter.export(to: temporaryURL, as: .mp4)
            // Moving into place fails if another process created the destination while
            // encoding, so the completed render cannot replace that file either.
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
