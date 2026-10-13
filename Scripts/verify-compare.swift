import AVFoundation
import CoreVideo
import Foundation

@main
struct VerifyCompare {
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-comparison-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let left = dir.appendingPathComponent("left.mp4"), right = dir.appendingPathComponent("right.mp4")
        let output = dir.appendingPathComponent("comparison.mp4"), offsetOutput = dir.appendingPathComponent("offset.mp4")
        try await fixture(left, width: 320, height: 180, seconds: 2, color: (230, 30, 25))
        try await fixture(right, width: 240, height: 240, seconds: 3, color: (25, 210, 40))
        var options = ClipComparison.Options()
        options.height = 120
        options.leftLabel = "Red Source"
        options.rightLabel = "Green Source"
        try await ClipComparison.render(left: left, right: right, output: output, options: options)
        let asset = AVURLAsset(url: output)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("output has no video") }
        let size = try await track.load(.naturalSize)
        let expectedPanelWidth = max(2, max(Int((120.0 * 320 / 180).rounded(.down)) & ~1, Int((120.0 * 240 / 240).rounded(.down)) & ~1))
        guard Int(size.width) == expectedPanelWidth * 2, Int(size.height) == 120 else { throw failure("unexpected output size \(size)") }
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - 2) < 0.15 else { throw failure("duration \(duration), expected about 2s") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        guard let leftPixel = pixel(image, x: expectedPanelWidth / 2, y: 55),
              let rightPixel = pixel(image, x: expectedPanelWidth + expectedPanelWidth / 2, y: 55) else { throw failure("could not sample output pixels") }
        guard Double(leftPixel.0) > Double(leftPixel.1) * 1.8, Double(rightPixel.1) > Double(rightPixel.0) * 1.8 else { throw failure("panel colors wrong: \(leftPixel), \(rightPixel)") }
        guard let labelPixel = pixel(image, x: expectedPanelWidth / 2, y: 20) else { throw failure("could not sample label bar") }
        guard labelPixel != leftPixel else { throw failure("label bar did not change pixels") }

        do {
            try await ClipComparison.render(left: left, right: right, output: output, options: options)
            throw failure("overwrite was accepted")
        } catch let error as ClipComparisonError {
            guard error.localizedDescription.contains("overwrite") else { throw error }
        }
        do {
            try await ClipComparison.render(left: dir.appendingPathComponent("missing.mp4"), right: right, output: dir.appendingPathComponent("missing-out.mp4"), options: options)
            throw failure("missing input was accepted")
        } catch let error as ClipComparisonError {
            guard error.localizedDescription.contains("missing") else { throw error }
        }
        options.timeAlignment = .offset
        options.rightOffset = 0.5
        try await ClipComparison.render(left: left, right: right, output: offsetOutput, options: options)
        let offsetDuration = try await AVURLAsset(url: offsetOutput).load(.duration).seconds
        guard abs(offsetDuration - 2) < 0.15 else { throw failure("right offset duration was \(offsetDuration), expected 2s") }
        print("Clip comparison verified: \(Int(size.width))×\(Int(size.height)), duration \(String(format: "%.2f", duration))s, colors/labels/validation passed")
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: "VerifyCompare", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    private static func fixture(_ url: URL, width: Int, height: Int, seconds: Double, color: (UInt8, UInt8, UInt8)) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? failure("writer did not start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw failure("no pixel buffer pool") }
            var maybe: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe) == kCVReturnSuccess, let buffer = maybe else { throw failure("pixel allocation failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                for y in 0..<height {
                    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { let p = x * 4; row[p] = color.2; row[p + 1] = color.1; row[p + 2] = color.0; row[p + 3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? failure("append failed") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? failure("fixture failed") }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytes = image.bitsPerPixel / 8, index = y * image.bytesPerRow + x * bytes
        guard index + 2 < CFDataGetLength(data) else { return nil }
        return (Int(ptr[index + 2]), Int(ptr[index + 1]), Int(ptr[index]))
    }
}
