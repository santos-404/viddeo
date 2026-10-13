import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
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
        case unsupportedOutput(String)
        case encodingFailed(String)
        case tooManyGIFFrames(count: Int, limit: Int)

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
            case .unsupportedOutput(let reason): "The selected export settings are unavailable: \(reason)"
            case .encodingFailed(let reason): "Encoding failed: \(reason)"
            case .tooManyGIFFrames(let count, let limit):
                "A GIF of this length needs \(count) frames; the limit is \(limit). Lower the frame rate or export MP4."
            }
        }
    }

    /// Writes the export and returns every file it created (two for the `both` codec setting).
    /// `edit` adds the timeline (output runs in playback time), stage and captions; nil, or an
    /// empty edit, renders exactly the unedited export.
    @discardableResult
    func export(session: RecordingSession, directory: URL, destination: URL,
                showsClickEffects: Bool = true, settings: ExportSettings = .mp4Default,
                edit: ExportEdit? = nil,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> [URL] {
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
        try settings.validate()
        let settings = settings.normalized()

        let sessionDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = sessionDirectory.appendingPathComponent(session.videoFilename, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard sourceURL.deletingLastPathComponent() == sessionDirectory else {
            throw ExportError.invalidSession("videoFilename must resolve inside the session directory")
        }
        let outputURL = destination.standardizedFileURL
        let outputs: [(codec: ExportCodec, url: URL)] = settings.format == .gif
            ? [(.h264, outputURL)]
            : settings.outputURLs(for: outputURL).map { ($0.codec, $0.url.standardizedFileURL) }
        for output in outputs {
            guard sourceURL != output.url,
                  sourceURL != output.url.resolvingSymlinksInPath() else {
                throw ExportError.outputWouldReplaceInput
            }
            guard !FileManager.default.fileExists(atPath: output.url.path) else {
                throw ExportError.outputExists(output.url)
            }
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

        let zoomConfiguration = try ZoomConfiguration.load(in: directory)
        try zoomConfiguration.validate()
        let clickTimeline = showsClickEffects
            ? ClickEffectTimeline(events: session.events, duration: session.duration,
                                  configuration: try ClickEffectConfiguration.load(in: directory)) : nil
        let size = settings.outputSize(sourceWidth: session.width, sourceHeight: session.height)
        if let timeline = edit?.timeline {
            do { try timeline.validate() } catch {
                throw ExportError.invalidSession("the timeline is invalid: \(error.localizedDescription)")
            }
            guard abs(timeline.sourceDuration - session.duration) <= TimelineModel.minSegmentDuration else {
                throw ExportError.invalidSession("the timeline does not match the recording's duration")
            }
        }
        let outputSize = CGSize(width: size.width, height: size.height)
        let renderer = ExportFrameRenderer(
            sourceWidth: session.width, sourceHeight: session.height,
            outputWidth: size.width, outputHeight: size.height,
            timeline: ZoomTimeline(session: session, configuration: zoomConfiguration),
            clickTimeline: clickTimeline,
            edit: edit?.timeline,
            stage: try edit?.stage.map { try StageRenderer(style: $0, outputSize: outputSize, baseDirectory: sessionDirectory) },
            captions: edit?.captions.map { CaptionRenderer(track: $0.track, configuration: $0.configuration, outputSize: outputSize) },
            sourceDuration: actualDuration
        )
        // The output runs in playback time; without a timeline that is the recording itself.
        let outputDuration = edit?.timeline.map { CMTime(seconds: $0.playbackDuration, preferredTimescale: 60_000) } ?? duration
        let frameCount = ExportFrameRenderer.frameCount(duration: outputDuration.seconds, fps: settings.fps)

        if settings.format == .gif {
            guard frameCount <= GifExporter.maximumFrames else {
                throw ExportError.tooManyGIFFrames(count: frameCount, limit: GifExporter.maximumFrames)
            }
            try await GifExporter.write(source: sourceURL, destination: outputURL, renderer: renderer,
                                        duration: outputDuration.seconds, settings: settings, progress: progress)
            return [outputURL]
        }
        let audioRoles = edit?.timeline == nil ? nil
            : try await ExportAudioTrack.roles(of: asset.loadTracks(withMediaType: .audio), session: session)

        // Render every codec to a hidden sibling first, then move all of them into place, so
        // a failure or cancellation never leaves one finished file of a requested pair.
        var temporaryURLs: [URL] = []
        var movedURLs: [URL] = []
        do {
            for (index, output) in outputs.enumerated() {
                let temporaryURL = output.url.deletingLastPathComponent()
                    .appendingPathComponent(".\(output.url.lastPathComponent).\(UUID().uuidString).partial.mp4")
                temporaryURLs.append(temporaryURL)
                let share = 1 / Double(outputs.count)
                try await Self.writeMovie(
                    source: sourceURL, destination: temporaryURL, codec: output.codec,
                    renderer: renderer, duration: outputDuration, sourceDuration: duration,
                    audioRoles: audioRoles, settings: settings,
                    progress: progress.map { report in
                        { @Sendable value in report((Double(index) + value) * share) }
                    }
                )
            }
            for (temporaryURL, output) in zip(temporaryURLs, outputs) {
                // Moving into place fails if another process created the destination while
                // encoding, so the completed render cannot replace that file either.
                try FileManager.default.moveItem(at: temporaryURL, to: output.url)
                movedURLs.append(output.url)
            }
        } catch {
            for url in temporaryURLs + movedURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        progress?(1)
        return movedURLs
    }

    /// Decodes each source audio track to PCM and re-encodes it as its own AAC track, so
    /// system audio and microphone stay separate in the export. `duration` is the output
    /// (playback) duration; `audioRoles` is non-nil exactly when the renderer has a timeline.
    private nonisolated static func writeMovie(
        source: URL, destination: URL, codec: ExportCodec, renderer: ExportFrameRenderer,
        duration: CMTime, sourceDuration: CMTime, audioRoles: [ExportAudioTrack.Role]?,
        settings: ExportSettings, progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let asset = AVURLAsset(url: source)
        let timeRange = CMTimeRange(start: .zero, duration: sourceDuration)
        let frames = try await ExportFrameSource(asset: asset, duration: sourceDuration, timeline: renderer.edit)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let width = renderer.outputWidth, height = renderer.outputHeight
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(1, settings.videoBitsPerSecond(width: width, height: height)),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec == .h265 ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ExportError.unsupportedOutput("\(codec.rawValue) cannot encode \(width)×\(height)")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(videoInput) else { throw ExportError.unsupportedOutput("cannot add a video track") }
        writer.add(videoInput)

        var audio: [ExportAudioTrack] = []
        for (index, track) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
            if let timeline = renderer.edit {
                let role = audioRoles.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? .unknown
                audio.append(try await ExportAudioTrack(track: track, role: role, plan: timeline.editPlan,
                                                        playbackDuration: duration.seconds, writer: writer))
            } else {
                audio.append(try await ExportAudioTrack(asset: asset, track: track, timeRange: timeRange, writer: writer))
            }
        }

        func cancelAll() {
            frames.cancel()
            for track in audio { track.cancel() }
            writer.cancelWriting()
        }

        do {
            guard writer.startWriting() else {
                throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "the writer did not start")
            }
            for track in audio { try track.start() }
            writer.startSession(atSourceTime: .zero)

            let context = CIContext()
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
            let frameCount = ExportFrameRenderer.frameCount(duration: duration.seconds, fps: settings.fps)
            var frameIndex = 0
            var audioFinished = Array(repeating: false, count: audio.count)
            var reported = -1.0
            while frameIndex < frameCount || audioFinished.contains(false) {
                try Task.checkCancellation()
                if writer.status == .failed {
                    throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "the writer failed")
                }
                var progressed = false
                if frameIndex < frameCount, videoInput.isReadyForMoreMediaData {
                    let time = CMTime(value: Int64(frameIndex), timescale: CMTimeScale(settings.fps))
                    let sourceTime = renderer.sourceTime(forPlaybackTime: time.seconds)
                    guard let sourceImage = try frames.image(atSource: sourceTime) else {
                        throw ExportError.encodingFailed("the raw recording has no decodable frames")
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        throw ExportError.encodingFailed("the writer did not create a pixel buffer pool")
                    }
                    var maybeBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
                          let buffer = maybeBuffer else {
                        throw ExportError.encodingFailed("could not allocate an output frame")
                    }
                    context.render(renderer.image(source: sourceImage, at: sourceTime), to: buffer,
                                   bounds: renderer.outputRect, colorSpace: colorSpace)
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "a video frame was rejected")
                    }
                    frameIndex += 1
                    if frameIndex == frameCount { videoInput.markAsFinished() }
                    progressed = true
                    let fraction = Double(frameIndex) / Double(frameCount)
                    if let progress, fraction - reported >= 0.01 {
                        reported = fraction
                        progress(min(0.99, fraction))
                    }
                }
                for (index, track) in audio.enumerated() where !audioFinished[index] {
                    var appended = 0
                    while appended < 16, track.input.isReadyForMoreMediaData {
                        guard let sample = try track.nextSampleBuffer() else {
                            track.input.markAsFinished()
                            audioFinished[index] = true
                            break
                        }
                        guard track.input.append(sample) else {
                            throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "an audio sample was rejected")
                        }
                        appended += 1
                        progressed = true
                    }
                }
                if !progressed { try await Task.sleep(for: .milliseconds(2)) }
            }
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "the writer did not finish")
            }
        } catch {
            cancelAll()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// Composes one export frame. The zoom crop and click rings are computed in source pixel
/// space; the result is then fitted into the output canvas. Without a stage, any remainder of
/// a different output aspect is solid black; with a stage, the zoomed content fills the stage
/// rect and the stage (background, padding, radius, shadow) fills the whole canvas. Captions
/// are drawn last, over the full canvas.
///
/// `image(source:at:)` takes SOURCE time: zoom, clicks and caption cues are all stored in
/// raw-recording time. Callers map each output (playback) time through `sourceTime(forPlaybackTime:)`.
struct ExportFrameRenderer: Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let timeline: ZoomTimeline
    let clickTimeline: ClickEffectTimeline?
    var edit: TimelineModel? = nil
    var stage: StageRenderer? = nil
    var captions: CaptionRenderer? = nil
    /// Mapped source times are clamped below this (the decodable media's end).
    var sourceDuration: Double = .infinity

    /// Identity without a timeline, so the unedited export samples exactly as before.
    func sourceTime(forPlaybackTime time: Double) -> Double {
        guard let edit else { return time }
        return min(edit.sourceTime(forPlaybackTime: time), sourceDuration)
    }

    var outputRect: CGRect { CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight) }

    /// Frames start at time zero and step by 1/fps while they are before the end.
    static func frameCount(duration: Double, fps: Int) -> Int {
        guard duration.isFinite, duration > 0, fps > 0 else { return 0 }
        return max(1, Int((duration * Double(fps) - 1e-6).rounded(.up)))
    }

    /// Placement of the full source frame inside the output canvas (bottom-left origin).
    var contentRect: CGRect {
        let fit = min(Double(outputWidth) / Double(sourceWidth), Double(outputHeight) / Double(sourceHeight))
        let width = Double(sourceWidth) * fit, height = Double(sourceHeight) * fit
        return CGRect(x: ((Double(outputWidth) - width) / 2).rounded(),
                      y: ((Double(outputHeight) - height) / 2).rounded(),
                      width: width, height: height)
    }

    func image(source rawSource: CIImage, at time: Double) -> CIImage {
        let frame = timeline.frame(at: time)
        let width = CGFloat(sourceWidth), height = CGFloat(sourceHeight)

        // The recorder writes identity-oriented frames. Rotated source tracks are
        // rejected before rendering until their coordinate space is verified.
        let bounds = rawSource.extent
        let normalizedSource = rawSource.transformed(
            by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        )
        // Click locations are in the original top-left source coordinate
        // space, so render them before applying the zoom transform.
        let image = clickTimeline?.image(over: normalizedSource, at: time) ?? normalizedSource
        let scale = frame.scale.isFinite ? max(1, frame.scale) : 1
        let cropWidth = width / CGFloat(scale)
        let cropHeight = height / CGFloat(scale)
        let centerX = CGFloat(frame.centerX.isFinite ? frame.centerX : 0.5) * width
        // ZoomTimeline uses a top-left normalized origin; Core Image uses bottom-left.
        let centerY = CGFloat(1 - (frame.centerY.isFinite ? frame.centerY : 0.5)) * height
        let clampedX = min(max(centerX, cropWidth / 2), width - cropWidth / 2)
        let clampedY = min(max(centerY, cropHeight / 2), height - cropHeight / 2)
        let crop = CGRect(
            x: clampedX - cropWidth / 2,
            y: clampedY - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        )

        if let stage {
            // The crop is resampled once, straight into the stage rect's pixel size (its aspect
            // matches the source up to rounding), then placed by the stage.
            let size = stage.stageRect(contentAspect: Double(sourceWidth) / Double(sourceHeight)).size
            let scaleX = size.width / crop.width, scaleY = size.height / crop.height
            let cropped = image.cropped(to: crop).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let resized = scaleY < 1
                ? cropped.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY
                ])
                : cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            let staged = stage.compose(resized.cropped(to: CGRect(origin: .zero, size: size)))
            return withCaptions(staged, at: time).cropped(to: outputRect)
        }

        // One resample maps the crop straight into the fitted content rectangle.
        let content = contentRect
        let total = content.width / crop.width
        let cropped = image.cropped(to: crop).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let resized = total < 1
            ? cropped.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: total, kCIInputAspectRatioKey: 1
            ])
            : cropped.transformed(by: CGAffineTransform(scaleX: total, y: total))
        let placed = resized
            .transformed(by: CGAffineTransform(translationX: content.minX, y: content.minY))
            .cropped(to: content)
        let background = CIImage(color: .black).cropped(to: outputRect)
        return withCaptions(placed.composited(over: background), at: time).cropped(to: outputRect)
    }

    /// Caption cues are source-time milliseconds, like zoom and click data.
    private func withCaptions(_ frame: CIImage, at sourceTime: Double) -> CIImage {
        guard let overlay = captions?.image(at: sourceTime * 1000) else { return frame }
        return overlay.composited(over: frame)
    }
}

/// Holds the latest decoded source frame at or before each requested output time, so the
/// output frame rate is independent of the recording's frame timing.
final class SourceFrameReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: (time: Double, image: CIImage)?
    private var next: (time: Double, image: CIImage)?
    private var exhausted = false

    convenience init(asset: AVAsset, timeRange: CMTimeRange) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw OfflineExporter.ExportError.missingVideoTrack
        }
        try self.init(asset: asset, track: track, timeRange: timeRange)
    }

    init(asset: AVAsset, track: AVAssetTrack, timeRange: CMTimeRange) throws {
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OfflineExporter.ExportError.unsupportedOutput("cannot decode the raw video track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OfflineExporter.ExportError.encodingFailed(reader.error?.localizedDescription ?? "video reading did not start")
        }
    }

    func image(at time: Double) throws -> CIImage? {
        if current == nil { current = try readFrame() }
        if next == nil { next = try readFrame() }
        while let candidate = next, candidate.time <= time + 1e-6 {
            current = candidate
            next = try readFrame()
        }
        return current?.image
    }

    /// Presentation time of the first decodable frame, without consuming it.
    func firstFrameTime() throws -> Double? {
        if current == nil { current = try readFrame() }
        return current?.time
    }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }

    private func readFrame() throws -> (time: Double, image: CIImage)? {
        while !exhausted {
            guard let sample = output.copyNextSampleBuffer() else {
                exhausted = true
                if reader.status == .failed {
                    throw OfflineExporter.ExportError.encodingFailed(reader.error?.localizedDescription ?? "video decoding failed")
                }
                return nil
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { continue }
            return (time, CIImage(cvPixelBuffer: buffer))
        }
        return nil
    }
}
