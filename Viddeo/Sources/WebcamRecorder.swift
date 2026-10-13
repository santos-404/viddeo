import AVFoundation
import CoreMedia
import Foundation

/// Sidecar description of `camera.mov`. `firstPTS` is seconds from the screen recording's
/// first-frame epoch (host clock) to the first camera frame; it is never below
/// `-WebcamRecorder.epochTolerance`. Without an epoch it is 0 and `firstHostTime` alone
/// anchors the file.
struct WebcamCaptureMetadata: Codable, Sendable, Equatable {
    var filename: String
    var firstPTS: Double
    var duration: Double
    var width: Int
    var height: Int
    var droppedFrames: Int
    var deviceName: String
    /// Host-clock seconds of the first written frame, for alignment done after recording.
    var firstHostTime: Double
}

/// Records the camera (video only) to HEVC `camera.mov` with `AVCaptureVideoDataOutput` and
/// `AVAssetWriter`, keeping host-clock timing so the exporter can align it with the screen.
///
/// Concurrency: all session state is confined to `controlQueue`; `start` and `stop` hop onto
/// it, so calls are serialized and a second `start` fails with `alreadyRecording`. Sample
/// buffers are handled by `WebcamWriterPipeline` on its own serial queue. Both types are
/// `@unchecked Sendable` because of that queue confinement.
final class WebcamRecorder: @unchecked Sendable {
    static let filename = "camera.mov"
    /// Frames earlier than the screen epoch minus this many seconds are discarded.
    static let epochTolerance = 0.1
    /// Observed webcam channel encoding: HEVC at quality 0.6.
    static let quality = 0.6

    private enum State { case idle, recording, stopping }

    private let controlQueue = DispatchQueue(label: "com.viddeo.webcam-recorder.control")
    private var state = State.idle
    private var session: AVCaptureSession?
    private var pipeline: WebcamWriterPipeline?
    private var observers: [NSObjectProtocol] = []

    /// `epoch` is the host-clock PTS of the screen recording's first frame, if known.
    /// `deviceID` selects an `AVCaptureDevice.uniqueID`; nil uses the system default camera.
    func start(directory: URL, epoch: CMTime?, deviceID: String? = nil) async throws {
        try await Self.authorize()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    try self.startOnQueue(directory: directory, epoch: epoch, deviceID: deviceID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Finalizes `camera.mov`. After a mid-recording device loss the partial file is still
    /// finalized and its metadata is carried by `WebcamError.deviceDisconnected`.
    func stop() async throws -> WebcamCaptureMetadata {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async { self.stopOnQueue(continuation) }
        }
    }

    private static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw WebcamError.permissionDenied }
        default:
            throw WebcamError.permissionDenied
        }
    }

    private func startOnQueue(directory: URL, epoch: CMTime?, deviceID: String?) throws {
        guard state == .idle else { throw WebcamError.alreadyRecording }
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        else { throw WebcamError.noDevice }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw WebcamError.captureFailed(error.localizedDescription)
        }
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let url = directory.appendingPathComponent(Self.filename)
        try? FileManager.default.removeItem(at: url)
        let pipeline = WebcamWriterPipeline(url: url, epoch: epoch, clock: session.synchronizationClock,
                                            deviceName: device.localizedName)
        output.setSampleBufferDelegate(pipeline, queue: pipeline.sampleQueue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw WebcamError.captureFailed("The camera input or output could not be configured.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                pipeline.fail(.deviceDisconnected(partial: nil))
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                pipeline.fail(.captureFailed(error?.localizedDescription ?? "Unknown capture session error."))
            }
        ]
        session.startRunning()
        guard session.isRunning else {
            removeObservers()
            throw WebcamError.captureFailed("The camera session did not start.")
        }
        self.session = session
        self.pipeline = pipeline
        state = .recording
    }

    private func stopOnQueue(_ continuation: CheckedContinuation<WebcamCaptureMetadata, Error>) {
        guard state == .recording, let session, let pipeline else {
            continuation.resume(throwing: WebcamError.notRecording)
            return
        }
        state = .stopping
        session.stopRunning()
        removeObservers()
        pipeline.finish { result in
            self.controlQueue.async {
                self.session = nil
                self.pipeline = nil
                self.state = .idle
                continuation.resume(with: result)
            }
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// Sample-buffer delegate and writer. Every mutable property is confined to `sampleQueue`
/// (the capture output's delegate queue); `fail` and `finish` marshal onto it.
final class WebcamWriterPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.viddeo.webcam-recorder.samples")

    private let url: URL
    private let epoch: CMTime?
    private let clock: CMClock?
    private let deviceName: String
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var firstHostPTS: CMTime?
    private var lastPTS: CMTime?
    private var lastFrameDuration = CMTime.invalid
    private var width = 0
    private var height = 0
    private var droppedFrames = 0
    private var failure: WebcamError?
    private var isFinishing = false

    init(url: URL, epoch: CMTime?, clock: CMClock?, deviceName: String) {
        self.url = url
        self.epoch = epoch.flatMap { $0.isValid && $0.isNumeric ? $0 : nil }
        self.clock = clock
        self.deviceName = deviceName
    }

    func fail(_ error: WebcamError) {
        sampleQueue.async {
            if self.failure == nil { self.failure = error }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if firstPTS != nil, !isFinishing { droppedFrames += 1 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isFinishing, failure == nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return }
        let hostPTS = hostTime(pts)
        if firstPTS == nil, let epoch,
           CMTimeCompare(hostPTS, CMTimeSubtract(epoch, CMTime(seconds: WebcamRecorder.epochTolerance, preferredTimescale: 1_000_000))) < 0 {
            return
        }
        if writer == nil {
            do { try startWriter(for: sampleBuffer, at: pts) } catch {
                failure = error as? WebcamError ?? .writerFailed(error.localizedDescription)
                return
            }
            firstHostPTS = hostPTS
        }
        guard let writer, let input else { return }
        guard input.isReadyForMoreMediaData else { droppedFrames += 1; return }
        guard input.append(sampleBuffer) else {
            failure = .writerFailed(writer.error?.localizedDescription ?? "A camera frame could not be appended.")
            return
        }
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, duration > .zero { lastFrameDuration = duration }
        lastPTS = pts
    }

    /// Ends the writer session one frame after the last appended frame and reports the result.
    func finish(_ completion: @escaping @Sendable (Result<WebcamCaptureMetadata, Error>) -> Void) {
        sampleQueue.async {
            self.isFinishing = true
            guard let writer = self.writer, let input = self.input,
                  let firstPTS = self.firstPTS, let lastPTS = self.lastPTS else {
                self.writer?.cancelWriting()
                completion(.failure(self.failure ?? .noFrames))
                return
            }
            let frame = self.lastFrameDuration.isValid ? self.lastFrameDuration : CMTime(value: 1, timescale: 30)
            let end = CMTimeAdd(lastPTS, frame)
            input.markAsFinished()
            writer.endSession(atSourceTime: end)
            let metadata = self.metadata(duration: CMTimeSubtract(end, firstPTS).seconds)
            let failure = self.failure
            writer.finishWriting {
                // The writer is read back on the confining queue rather than captured.
                self.sampleQueue.async { self.complete(metadata: metadata, failure: failure, completion) }
            }
        }
    }

    private func complete(metadata: WebcamCaptureMetadata, failure: WebcamError?,
                          _ completion: @Sendable (Result<WebcamCaptureMetadata, Error>) -> Void) {
        if let writer, writer.status != .completed {
            completion(.failure(WebcamError.writerFailed(writer.error?.localizedDescription ?? "Unknown writer error.")))
        } else if case .deviceDisconnected = failure {
            completion(.failure(WebcamError.deviceDisconnected(partial: metadata)))
        } else if let failure {
            completion(.failure(failure))
        } else {
            completion(.success(metadata))
        }
    }

    private func startWriter(for sampleBuffer: CMSampleBuffer, at pts: CMTime) throws {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw WebcamError.captureFailed("A camera frame had no format description.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw WebcamError.captureFailed("A camera frame had invalid dimensions.")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: WebcamRecorder.quality]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw WebcamError.writerFailed("The HEVC writer input could not be configured.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw WebcamError.writerFailed(writer.error?.localizedDescription ?? "The camera writer could not start.")
        }
        // Starting the session at the first frame's PTS rebases the movie timeline to zero.
        writer.startSession(atSourceTime: pts)
        self.writer = writer
        self.input = input
        firstPTS = pts
        width = Int(dimensions.width)
        height = Int(dimensions.height)
    }

    /// Capture PTS are on the session's synchronization clock; convert to the host clock.
    private func hostTime(_ pts: CMTime) -> CMTime {
        guard let clock else { return pts }
        let converted = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        return converted.isValid && converted.isNumeric ? converted : pts
    }

    private func metadata(duration: Double) -> WebcamCaptureMetadata {
        let host = firstHostPTS ?? firstPTS ?? .zero
        let offset = epoch.map { max(-WebcamRecorder.epochTolerance, CMTimeSubtract(host, $0).seconds) } ?? 0
        return WebcamCaptureMetadata(filename: WebcamRecorder.filename, firstPTS: offset,
                                     duration: max(0, duration), width: width, height: height,
                                     droppedFrames: droppedFrames, deviceName: deviceName,
                                     firstHostTime: host.seconds)
    }
}
