import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Animated GIF export through ImageIO. Frames are the same composited zoom/click/stage/caption
/// frames as MP4 (including timeline edits), sampled at the preset frame rate; GIFs carry no audio.
enum GifExporter {
    /// Bounds memory and file size; longer recordings must lower the frame rate or use MP4.
    static let maximumFrames = 3000

    /// GIF delays are whole centiseconds. Each delay is the difference of rounded ideal
    /// timestamps, so 30 fps alternates 3/4 cs and the total duration stays exact.
    static func delays(frameCount: Int, fps: Int) -> [Int] {
        (0..<frameCount).map { index in
            let start = (Double(index) * 100 / Double(fps)).rounded()
            let end = (Double(index + 1) * 100 / Double(fps)).rounded()
            return max(1, Int(end - start))
        }
    }

    static func write(source: URL, destination: URL, renderer: ExportFrameRenderer, duration: Double,
                      settings: ExportSettings, progress: (@Sendable (Double) -> Void)?) async throws {
        let frameCount = ExportFrameRenderer.frameCount(duration: duration, fps: settings.fps)
        guard frameCount <= maximumFrames else {
            throw OfflineExporter.ExportError.tooManyGIFFrames(count: frameCount, limit: maximumFrames)
        }
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial.gif")
        do {
            try await encode(source: source, destination: temporaryURL, renderer: renderer,
                             duration: duration, frameCount: frameCount, settings: settings, progress: progress)
            // Moving fails if the destination appeared during encoding, so it is never replaced.
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        progress?(1)
    }

    private static func encode(source: URL, destination: URL, renderer: ExportFrameRenderer, duration: Double,
                               frameCount: Int, settings: ExportSettings,
                               progress: (@Sendable (Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: source)
        // Without a timeline `duration` is the recording's; with one it is the playback duration
        // and the source reader spans the whole recording.
        let sourceDuration = renderer.edit == nil ? CMTime(seconds: duration, preferredTimescale: 600)
            : try await asset.load(.duration)
        let frames = try await ExportFrameSource(asset: asset, duration: sourceDuration, timeline: renderer.edit)
        defer { frames.cancel() }
        var cameraFrames: WebcamFrameSource?
        if let plan = renderer.webcam { cameraFrames = try await WebcamFrameSource(plan: plan, timeline: renderer.edit) }
        defer { cameraFrames?.cancel() }
        guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                        frameCount, nil) else {
            throw OfflineExporter.ExportError.unsupportedOutput("ImageIO cannot create a GIF here")
        }
        // Loop count 0 repeats forever; omitting the NETSCAPE2.0 loop block plays once.
        let fileProperties: [CFString: Any] = settings.gifDisableLoop
            ? [:]
            : [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(gif, fileProperties as CFDictionary)

        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let delays = delays(frameCount: frameCount, fps: settings.fps)
        var reported = -1.0
        for index in 0..<frameCount {
            try Task.checkCancellation()
            // Yield between frames so cancellation and UI progress stay responsive.
            await Task.yield()
            let time = renderer.sourceTime(forPlaybackTime: Double(index) / Double(settings.fps))
            guard let sourceImage = try frames.image(atSource: time) else {
                throw OfflineExporter.ExportError.encodingFailed("the raw recording has no decodable frames")
            }
            try autoreleasepool {
                let camera = try cameraFrames?.image(atSource: time)
                guard let frame = context.createCGImage(renderer.image(source: sourceImage, at: time, camera: camera),
                                                        from: renderer.outputRect, format: .RGBA8,
                                                        colorSpace: colorSpace) else {
                    throw OfflineExporter.ExportError.encodingFailed("could not render GIF frame \(index)")
                }
                // The small epsilon keeps ImageIO's seconds-to-centiseconds conversion exact.
                let delay = Double(delays[index]) / 100 + 0.0001
                let properties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]]
                CGImageDestinationAddImage(gif, frame, properties as CFDictionary)
            }
            let fraction = Double(index + 1) / Double(frameCount)
            if let progress, fraction - reported >= 0.01 {
                reported = fraction
                progress(min(0.99, fraction))
            }
        }
        guard CGImageDestinationFinalize(gif) else {
            throw OfflineExporter.ExportError.encodingFailed("ImageIO could not finalize the GIF")
        }
    }
}
