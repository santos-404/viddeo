import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenRecorder {
    enum RecorderError: LocalizedError {
        case alreadyRecording
        case noFrames
        case inactive
        case invalidDimensions
        case microphonePermissionDenied
        case streamFailure(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "A recording is already active."
            case .noFrames: "Screen capture stopped before a complete video frame arrived."
            case .inactive: "There is no active recording to stop."
            case .invalidDimensions: "The selected display reported invalid pixel dimensions."
            case .microphonePermissionDenied: "Microphone access is required to record microphone audio. Allow it in System Settings → Privacy & Security → Microphone."
            case .streamFailure(let message): "Screen capture failed: \(message)"
            }
        }
    }

    var onFailure: (@MainActor (Error) -> Void)?

    private var stream: SCStream?
    private var pipeline: ScreenWriterPipeline?
    private var output: ScreenStreamOutput?
    private let cursorRecorder = CursorRecorder()
    private var directory: URL?
    private var displayID: UInt32?
    private var dimensions: (width: Int, height: Int)?
    private var createdAt: Date?
    private var generation: UInt64 = 0
    private var currentGeneration: UInt64?
    private var isStarting = false
    private var isStopping = false
    private var pendingCaptureFailure: Error?
    private var audioOptions = (system: false, microphone: false)
    private var cursorEmbedded = true
    private var capturesTyping = false
    private let webcamRecorder = WebcamRecorder()
    private var webcamActive = false
    /// Why the last recording has no (or an incomplete) camera track; read after `start` and `stop`.
    private(set) var webcamWarning: String?

    /// The camera is optional: it starts after the screen stream, so a missing device or denied
    /// permission never prevents or delays the screen recording, and is reported in `webcamWarning`.
    func start(display: SCDisplay, directory: URL, capturesSystemAudio: Bool = false, capturesMicrophone: Bool = false,
               rendersCursor: Bool = false, capturesKeystrokes: Bool = false,
               capturesWebcam: Bool = false, webcamDeviceID: String? = nil) async throws {
        guard stream == nil, !isStarting, !isStopping else { throw RecorderError.alreadyRecording }
        let dimensions = try Self.captureDimensions(displayID: display.displayID)
        isStarting = true
        if capturesMicrophone {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    isStarting = false
                    throw RecorderError.microphonePermissionDenied
                }
            } else if status == .denied || status == .restricted {
                isStarting = false
                throw RecorderError.microphonePermissionDenied
            }
        }
        webcamWarning = nil
        var webcamAuthorized = false
        if capturesWebcam {
            // Asked before the stream starts so a permission prompt cannot delay the first frames.
            do { try await WebcamRecorder.authorize(); webcamAuthorized = true } catch {
                webcamWarning = error.localizedDescription
            }
        }
        generation &+= 1
        let startGeneration = generation
        currentGeneration = startGeneration
        pendingCaptureFailure = nil
        let pipeline = ScreenWriterPipeline()
        var pendingStream: SCStream?
        pipeline.onFailure = { [weak self] error in
            Task { @MainActor in await self?.handleCaptureFailure(error, generation: startGeneration) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let videoURL = directory.appendingPathComponent("raw.mp4")
            try? FileManager.default.removeItem(at: videoURL)
            try await pipeline.prepare(url: videoURL, width: dimensions.width, height: dimensions.height,
                                       capturesSystemAudio: capturesSystemAudio, capturesMicrophone: capturesMicrophone)

            let configuration = SCStreamConfiguration()
            configuration.width = dimensions.width
            configuration.height = dimensions.height
            configuration.capturesAudio = capturesSystemAudio
            configuration.captureMicrophone = capturesMicrophone
            if capturesSystemAudio || capturesMicrophone {
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
            }
            cursorRecorder.start(displayID: display.displayID, capturesKeystrokes: capturesKeystrokes)
            cursorEmbedded = !rendersCursor || !cursorRecorder.isAvailable
            capturesTyping = capturesKeystrokes
            configuration.showsCursor = cursorEmbedded
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let output = ScreenStreamOutput(pipeline: pipeline) { [weak self] error in
                Task { @MainActor in await self?.handleCaptureFailure(error, generation: startGeneration) }
            }
            output.onFirstFrame = { [cursorRecorder] presentationTime in
                Task { @MainActor in
                    cursorRecorder.anchor(presentationTime: presentationTime)
                }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            pendingStream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: pipeline.sampleQueue)
            if capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: pipeline.sampleQueue)
            }
            if capturesMicrophone {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: pipeline.sampleQueue)
            }

            self.pipeline = pipeline
            self.output = output
            self.stream = stream
            self.directory = directory
            self.displayID = display.displayID
            self.dimensions = dimensions
            self.createdAt = Date()
            self.audioOptions = (capturesSystemAudio, capturesMicrophone)

            try await stream.startCapture()
            guard currentGeneration == startGeneration, self.pipeline === pipeline else {
                throw RecorderError.streamFailure("Capture stopped while startup was completing.")
            }
            if let pendingCaptureFailure { throw pendingCaptureFailure }
            isStarting = false
            if webcamAuthorized {
                do {
                    try await webcamRecorder.start(directory: directory, epoch: nil, deviceID: webcamDeviceID)
                    webcamActive = true
                } catch { webcamWarning = error.localizedDescription }
            }
        } catch {
            if let pendingStream { try? await pendingStream.stopCapture() }
            cursorRecorder.stopCapture()
            await pipeline.drain()
            await pipeline.abort()
            clearSession(generation: startGeneration)
            throw error
        }
    }

    func stop() async throws -> RecordingSession {
        guard !isStarting, !isStopping else { throw RecorderError.inactive }
        guard let stream, let pipeline, let directory, let displayID,
              let dimensions, let createdAt else { throw RecorderError.inactive }
        guard let stopGeneration = currentGeneration else { throw RecorderError.inactive }
        isStopping = true
        let stopTime = CMSyncGetTime(CMClockGetHostTimeClock())
        cursorRecorder.stopCapture()

        do {
            try await stream.stopCapture()
            await pipeline.drain()
            if let pendingCaptureFailure { throw pendingCaptureFailure }
            let finished = try await pipeline.finish(atHostTime: stopTime)
            if let pendingCaptureFailure { throw pendingCaptureFailure }
            let webcam = await finishWebcam(screenFirstFrameHostSeconds: pipeline.firstFrameHostSeconds)
            let duration = finished.duration
            let events = cursorRecorder.events(through: duration)
            let session = RecordingSession(
                id: UUID(),
                createdAt: createdAt,
                displayID: displayID,
                width: dimensions.width,
                height: dimensions.height,
                duration: duration,
                events: events,
                droppedFrames: finished.droppedFrames,
                eventCaptureAvailable: cursorRecorder.wasAvailableForSession,
                audio: audioOptions.system || audioOptions.microphone ? finished.audio : nil,
                cursorEmbedded: cursorEmbedded,
                keystrokes: capturesTyping ? cursorRecorder.keystrokes(through: duration) : nil,
                keystrokeCaptureAvailable: capturesTyping ? cursorRecorder.keystrokesWereAvailableForSession : nil,
                webcam: webcam
            )
            clearSession(generation: stopGeneration)
            try session.save(in: directory)
            return session
        } catch {
            cursorRecorder.stopCapture()
            await discardWebcam()
            await pipeline.drain()
            await pipeline.abort()
            clearSession(generation: stopGeneration)
            throw error
        }
    }

    /// Finalizes `camera.mov` and expresses its first frame on the screen recording's clock: both
    /// movies are timestamped on the host clock, so the difference of their first-frame host times is
    /// the camera's offset (negative when the camera produced a frame before the screen did).
    private func finishWebcam(screenFirstFrameHostSeconds: Double?) async -> WebcamCaptureMetadata? {
        guard webcamActive else { return nil }
        webcamActive = false
        var metadata: WebcamCaptureMetadata
        do {
            metadata = try await webcamRecorder.stop()
        } catch WebcamError.deviceDisconnected(let partial?) {
            metadata = partial
            webcamWarning = "The camera was disconnected during the recording; the camera track ends early."
        } catch {
            webcamWarning = error.localizedDescription
            return nil
        }
        guard let screenStart = screenFirstFrameHostSeconds, metadata.firstHostTime.isFinite else {
            webcamWarning = "The camera could not be aligned with the screen recording."
            return nil
        }
        metadata.firstPTS = metadata.firstHostTime - screenStart
        return metadata
    }

    private func discardWebcam() async {
        guard webcamActive else { return }
        webcamActive = false
        _ = try? await webcamRecorder.stop()
    }

    private func handleCaptureFailure(_ error: Error, generation failureGeneration: UInt64) async {
        guard currentGeneration == failureGeneration else { return }
        if isStarting || isStopping {
            pendingCaptureFailure = pendingCaptureFailure ?? error
            return
        }
        pendingCaptureFailure = error
        isStopping = true
        cursorRecorder.stopCapture()
        await discardWebcam()
        if let stream { try? await stream.stopCapture() }
        if let pipeline {
            await pipeline.drain()
            await pipeline.abort()
        }
        clearSession(generation: failureGeneration)
        onFailure?(error)
    }

    private func clearSession(generation clearedGeneration: UInt64) {
        guard currentGeneration == clearedGeneration else { return }
        stream = nil
        output = nil
        pipeline = nil
        directory = nil
        displayID = nil
        dimensions = nil
        createdAt = nil
        currentGeneration = nil
        pendingCaptureFailure = nil
        audioOptions = (false, false)
        isStarting = false
        isStopping = false
    }

    private static func captureDimensions(displayID: CGDirectDisplayID) throws -> (width: Int, height: Int) {
        let pixelWidth = Int(CGDisplayPixelsWide(displayID))
        let pixelHeight = Int(CGDisplayPixelsHigh(displayID))
        guard pixelWidth > 0, pixelHeight > 0 else { throw RecorderError.invalidDimensions }

        let scale = min(1, 3840.0 / Double(pixelWidth), 2160.0 / Double(pixelHeight))
        let width = (Int(Double(pixelWidth) * scale) / 2) * 2
        let height = (Int(Double(pixelHeight) * scale) / 2) * 2
        guard width > 0, height > 0 else { throw RecorderError.invalidDimensions }
        return (width, height)
    }
}

// Writer, input, and timestamp state are confined to sampleQueue. Callers must
// enqueue consume there; setup, drain, finish, and abort marshal onto that queue.
final class ScreenWriterPipeline: @unchecked Sendable {
    struct Result {
        let duration: Double
        let droppedFrames: Int
        let audio: AudioCaptureMetadata
    }

    let sampleQueue = DispatchQueue(label: "com.viddeo.screen-recorder.samples")
    var onFailure: (@Sendable (Error) -> Void)?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var lastSampleBuffer: CMSampleBuffer?
    private var heldFrameForFinish: CMSampleBuffer?
    private var lastFrameDuration: CMTime?
    private var droppedFrames = 0
    private var storedError: Error?
    private var failureReported = false
    private var isFinishing = false
    private var requestedSystemAudio = false
    private var requestedMicrophone = false
    private var systemAudioSamples = 0
    private var microphoneSamples = 0
    private var systemAudioDroppedSamples = 0
    private var microphoneDroppedSamples = 0
    private var pendingAudioSamples: [(buffer: CMSampleBuffer, microphone: Bool)] = []
    private var lastSystemAudioPTS: CMTime?
    private var lastMicrophonePTS: CMTime?

    func prepare(url: URL, width: Int, height: Int, capturesSystemAudio: Bool = false, capturesMicrophone: Bool = false) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async {
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: max(4_000_000, width * height * 5),
                            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                        ]
                    ])
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else {
                        throw ScreenRecorder.RecorderError.streamFailure("The H.264 writer input could not be configured.")
                    }
                    writer.add(input)
                    func makeAudioInput(name: String) throws -> AVAssetWriterInput {
                        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48_000,
                            AVNumberOfChannelsKey: 2,
                            AVEncoderBitRateKey: 192_000
                        ])
                        audioInput.expectsMediaDataInRealTime = true
                        let title = AVMutableMetadataItem()
                        title.identifier = .commonIdentifierTitle
                        title.value = name as NSString
                        audioInput.metadata = [title]
                        guard writer.canAdd(audioInput) else {
                            throw ScreenRecorder.RecorderError.streamFailure("An AAC audio writer input could not be configured.")
                        }
                        writer.add(audioInput)
                        return audioInput
                    }
                    let systemInput = capturesSystemAudio ? try makeAudioInput(name: "System Audio") : nil
                    let microphoneInput = capturesMicrophone ? try makeAudioInput(name: "Microphone") : nil
                    guard writer.startWriting() else {
                        throw writer.error ?? ScreenRecorder.RecorderError.streamFailure("The video writer could not start.")
                    }
                    self.writer = writer
                    self.input = input
                    self.systemAudioInput = systemInput
                    self.microphoneInput = microphoneInput
                    self.requestedSystemAudio = capturesSystemAudio
                    self.requestedMicrophone = capturesMicrophone
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing else { return }
        guard isCompleteScreenFrame(sampleBuffer) else {
            droppedFrames += 1
            return
        }
        guard storedError == nil, let writer, let input,
              CMSampleBufferIsValid(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else {
            droppedFrames += 1
            return
        }
        if let lastPTS, CMTimeCompare(pts, lastPTS) <= 0 {
            droppedFrames += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        let isFirstFrame = firstPTS == nil
        if isFirstFrame {
            writer.startSession(atSourceTime: pts)
        }
        guard input.append(sampleBuffer) else {
            let error = writer.error ?? ScreenRecorder.RecorderError.streamFailure("The video writer rejected a screen frame.")
            fail(error)
            return
        }
        if isFirstFrame { firstPTS = pts }
        if isFirstFrame { flushPendingAudioSamples() }
        lastPTS = pts
        lastSampleBuffer = sampleBuffer
        let frameDuration = CMSampleBufferGetDuration(sampleBuffer)
        if frameDuration.isValid, frameDuration.isNumeric, frameDuration.seconds > 0 {
            lastFrameDuration = frameDuration
        }
    }

    func consumeAudio(_ sampleBuffer: CMSampleBuffer, microphone: Bool) {
        guard !isFinishing, writer != nil, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard (microphone ? microphoneInput : systemAudioInput) != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { countAudioDrop(microphone); return }
        let previousPTS = microphone ? lastMicrophonePTS : lastSystemAudioPTS
        guard previousPTS.map({ CMTimeCompare(pts, $0) > 0 }) ?? true else {
            countAudioDrop(microphone)
            return
        }
        if microphone { lastMicrophonePTS = pts } else { lastSystemAudioPTS = pts }
        guard firstPTS != nil else {
            // ScreenCaptureKit may deliver an initial audio packet before its first
            // screen callback. Retain a bounded startup window, then trim it once
            // the video epoch is known.
            guard pendingAudioSamples.count < 256 else { countAudioDrop(microphone); return }
            pendingAudioSamples.append((sampleBuffer, microphone))
            return
        }
        appendAudioSample(sampleBuffer, microphone: microphone)
    }

    private func flushPendingAudioSamples() {
        let pending = pendingAudioSamples
        pendingAudioSamples.removeAll(keepingCapacity: false)
        for sample in pending {
            appendAudioSample(sample.buffer, microphone: sample.microphone)
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer, microphone: Bool) {
        guard let writer, let audioInput = microphone ? microphoneInput : systemAudioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { countAudioDrop(microphone); return }
        // The movie epoch is the first accepted video frame. Samples before it cannot
        // be represented without shifting video and are discarded explicitly.
        guard let firstPTS, CMTimeCompare(pts, firstPTS) >= 0 else { countAudioDrop(microphone); return }
        guard storedError == nil, writer.status == .writing, audioInput.isReadyForMoreMediaData else {
            countAudioDrop(microphone)
            return
        }
        guard audioInput.append(sampleBuffer) else {
            let error = writer.error ?? ScreenRecorder.RecorderError.streamFailure("The audio writer rejected a capture sample.")
            fail(error)
            countAudioDrop(microphone)
            return
        }
        if microphone { microphoneSamples += 1 } else { systemAudioSamples += 1 }
    }

    private func countAudioDrop(_ microphone: Bool) {
        if microphone { microphoneDroppedSamples += 1 } else { systemAudioDroppedSamples += 1 }
    }

    /// Host-clock seconds of the first accepted video frame (the recording's time zero), after `finish`.
    var firstFrameHostSeconds: Double? {
        sampleQueue.sync { firstPTS.map { $0.seconds } }
    }

    func firstFrameAnchor() -> (host: CMTime, pts: CMTime)? {
        guard let firstPTS else { return nil }
        return (firstPTS, firstPTS)
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { continuation.resume() }
        }
    }

    func finish(atHostTime hostStopTime: CMTime) async throws -> Result {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            sampleQueue.async {
                guard let writer = self.writer, self.input != nil else {
                    continuation.resume(throwing: ScreenRecorder.RecorderError.noFrames)
                    return
                }
                if let error = self.storedError {
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                    return
                }
                guard let firstPTS = self.firstPTS, let lastPTS = self.lastPTS else {
                    writer.cancelWriting()
                    continuation.resume(throwing: ScreenRecorder.RecorderError.noFrames)
                    return
                }
                self.isFinishing = true

                let frameInterval = self.lastFrameDuration ?? CMTime(value: 1, timescale: 60)
                let stopTime = CMTimeConvertScale(hostStopTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
                var finalTime = CMTimeCompare(stopTime, lastPTS) > 0 ? stopTime : lastPTS
                let idleGap = CMTimeSubtract(stopTime, lastPTS)
                if CMTimeCompare(idleGap, frameInterval) > 0,
                   let lastSampleBuffer = self.lastSampleBuffer {
                    var timing = CMSampleTimingInfo(
                        duration: frameInterval,
                        presentationTimeStamp: stopTime,
                        decodeTimeStamp: .invalid
                    )
                    var heldFrame: CMSampleBuffer?
                    let status = CMSampleBufferCreateCopyWithNewTiming(
                        allocator: kCFAllocatorDefault,
                        sampleBuffer: lastSampleBuffer,
                        sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing,
                        sampleBufferOut: &heldFrame
                    )
                    guard status == noErr, let heldFrame else {
                        writer.cancelWriting()
                        continuation.resume(throwing: ScreenRecorder.RecorderError.streamFailure("The final held screen frame could not be timed."))
                        return
                    }
                    finalTime = stopTime
                    let endTime = CMTimeAdd(finalTime, frameInterval)
                    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                    self.heldFrameForFinish = heldFrame
                    self.appendHeldFrame(
                        firstPTS: firstPTS,
                        endTime: endTime,
                        deadline: deadline,
                        continuation: continuation
                    )
                    return
                }
                let endTime = CMTimeAdd(finalTime, frameInterval)
                self.finishWriter(firstPTS: firstPTS, endTime: endTime, continuation: continuation)
            }
        }
    }

    private func appendHeldFrame(
        firstPTS: CMTime,
        endTime: CMTime,
        deadline: UInt64,
        continuation: CheckedContinuation<Result, Error>
    ) {
        guard let writer, let input, let heldFrame = heldFrameForFinish else {
            continuation.resume(throwing: ScreenRecorder.RecorderError.streamFailure("The final held frame state was unavailable."))
            return
        }
        guard storedError == nil, writer.status == .writing else {
            let error = storedError ?? writer.error ?? ScreenRecorder.RecorderError.streamFailure("The video writer stopped before the final held frame could be appended.")
            writer.cancelWriting()
            continuation.resume(throwing: error)
            return
        }
        if input.isReadyForMoreMediaData {
            guard input.append(heldFrame) else {
                let error = writer.error ?? ScreenRecorder.RecorderError.streamFailure("The final held screen frame was rejected by the video writer.")
                writer.cancelWriting()
                continuation.resume(throwing: error)
                return
            }
            heldFrameForFinish = nil
            finishWriter(firstPTS: firstPTS, endTime: endTime, continuation: continuation)
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            writer.cancelWriting()
            continuation.resume(throwing: writer.error ?? ScreenRecorder.RecorderError.streamFailure("The video writer did not become ready for the final frame within two seconds."))
            return
        }

        sampleQueue.asyncAfter(deadline: .now() + .milliseconds(20)) {
            self.appendHeldFrame(
                firstPTS: firstPTS,
                endTime: endTime,
                deadline: deadline,
                continuation: continuation
            )
        }
    }

    private func finishWriter(
        firstPTS: CMTime,
        endTime: CMTime,
        continuation: CheckedContinuation<Result, Error>
    ) {
        guard let writer, let input else {
            continuation.resume(throwing: ScreenRecorder.RecorderError.streamFailure("The video writer was unavailable during finalization."))
            return
        }
        writer.endSession(atSourceTime: endTime)
        input.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.finishWriting {
            self.sampleQueue.async {
                guard let completedWriter = self.writer, completedWriter.status == .completed else {
                    continuation.resume(throwing: self.writer?.error ?? ScreenRecorder.RecorderError.streamFailure("The video file could not be finalized."))
                    return
                }
                let duration = max(0, CMTimeSubtract(endTime, firstPTS).seconds)
                let audio = AudioCaptureMetadata(
                    systemAudioRequested: self.requestedSystemAudio,
                    microphoneRequested: self.requestedMicrophone,
                    systemAudioSamples: self.systemAudioSamples,
                    microphoneSamples: self.microphoneSamples,
                    systemAudioDroppedSamples: self.systemAudioDroppedSamples,
                    microphoneDroppedSamples: self.microphoneDroppedSamples
                )
                continuation.resume(returning: Result(duration: duration, droppedFrames: self.droppedFrames, audio: audio))
            }
        }
    }

    func abort() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.input?.markAsFinished()
                self.writer?.cancelWriting()
                self.writer = nil
                self.input = nil
                self.systemAudioInput = nil
                self.microphoneInput = nil
                self.pendingAudioSamples.removeAll()
                self.lastSampleBuffer = nil
                self.heldFrameForFinish = nil
                continuation.resume()
            }
        }
    }

    private func fail(_ error: Error) {
        guard storedError == nil else { return }
        storedError = error
        if !failureReported {
            failureReported = true
            onFailure?(error)
        }
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return false }
        return true
    }

}

private final class ScreenStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let pipeline: ScreenWriterPipeline
    private let failureHandler: @Sendable (Error) -> Void
    private let firstFrameLock = NSLock()
    private var anchorSent = false
    var onFirstFrame: (@Sendable (CMTime) -> Void)?

    init(pipeline: ScreenWriterPipeline, failureHandler: @escaping @Sendable (Error) -> Void) {
        self.pipeline = pipeline
        self.failureHandler = failureHandler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            pipeline.consume(sampleBuffer)
        case .audio:
            pipeline.consumeAudio(sampleBuffer, microphone: false)
            return
        case .microphone:
            pipeline.consumeAudio(sampleBuffer, microphone: true)
            return
        @unknown default:
            return
        }
        firstFrameLock.lock()
        let anchor = anchorSent ? nil : pipeline.firstFrameAnchor()
        if anchor != nil { anchorSent = true }
        firstFrameLock.unlock()
        if let anchor {
            onFirstFrame?(anchor.pts)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failureHandler(error)
    }
}
