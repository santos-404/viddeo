import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// Colour round trip of the MP4 export. A synthetic session (solid-colour raw recording, solid stage
/// background) is exported; the file is decoded two ways (AVAssetImageGenerator, and AVAssetReader ->
/// CIImage -> sRGB) and compared with the intended sRGB values for the stage background (renderer
/// intent) and the screen content (fixture pixel -> exported pixel). Fixtures are written untagged and
/// tagged BT.709, like the real ScreenCaptureKit recordings.
///
/// Tolerances: neutral greys <= 3/255 (8-bit BGRA -> 8-bit limited-range YCbCr -> 8-bit is +-1 per
/// quantisation step plus H.264 rounding; any transfer or matrix mismatch is >= 10/255 on these
/// values). Saturated colours <= 8/255 because chroma is 4:2:0 and limited-range clipping of
/// the Cb/Cr step is amplified by the matrix inverse.
@main
struct VerifyColor {
    struct Case { var name: String; var stage: String; var content: (UInt8, UInt8, UInt8) }

    static func main() async throws {
        let width = 640, height = 360
        let cases = [
            Case(name: "dark", stage: "#101010", content: (0x10, 0x10, 0x10)),
            Case(name: "mid-grey", stage: "#808080", content: (0x80, 0x80, 0x80)),
            Case(name: "light-grey", stage: "#e0e0e0", content: (0xe0, 0xe0, 0xe0)),
            Case(name: "navy", stage: "#204060", content: (0x20, 0x40, 0x60)),
            Case(name: "saturated", stage: "#c06030", content: (0x00, 0xa0, 0xff)),
            Case(name: "orange", stage: "#ff8000", content: (0xc0, 0x30, 0x90))
        ]
        var failures: [String] = []
        for tagged in [false, true] {
            for item in cases {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("viddeo-color-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                try await makeFixture(url: directory.appendingPathComponent("raw.mp4"), width: width, height: height,
                                      color: item.content, tagged: tagged)
                let session = RecordingSession(id: UUID(), createdAt: Date(), displayID: 1, width: width, height: height,
                                               duration: 1, events: [], droppedFrames: 0, eventCaptureAvailable: true)
                try session.save(in: directory)
                var stage = StageStyle()
                stage.cornerRadius = 0
                stage.shadow.intensity = 0
                stage.background = .color(item.stage)
                let output = directory.appendingPathComponent("out.mp4")
                try await OfflineExporter().export(session: session, directory: directory, destination: output,
                                                   settings: ExportSettings(fps: 10, height: 720),
                                                   edit: ExportEdit(stage: stage))
                let rgb = StageStyle.rgba(hex: item.stage)!
                let stageWant = [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) }
                let contentWant = [Int(item.content.0), Int(item.content.1), Int(item.content.2)]
                let asset = AVURLAsset(url: output)
                let generated = try await generatorPixels(asset: asset)
                let read = try await readerPixels(asset: asset)
                for (method, pixels) in [("AVAssetImageGenerator", generated), ("AVAssetReader+CIImage", read)] {
                    for (label, got, want) in [("stage", pixels.stage, stageWant), ("content", pixels.content, contentWant)] {
                        // An untagged H.264 stream has no matrix tag, so the decoder guesses BT.601 and shifts
                        // saturated colours (a fixture artefact: real recordings are tagged BT.709, checked by the
                        // tagged pass). Greys are matrix independent and stay asserted.
                        let asserted = tagged || label == "stage" || isNeutral(want)
                        let error = zip(got, want).map { abs($0 - $1) }.max() ?? 0
                        print("\(tagged ? "tagged  " : "untagged") \(item.name) \(label) via \(method): got \(got) want \(want) err \(error)\(asserted ? "" : " (not asserted)")")
                        let allowed = isNeutral(want) ? 3 : 8
                        if asserted && error > allowed {
                            failures.append("\(tagged ? "tagged" : "untagged") \(item.name) \(label) via \(method) is \(got), expected \(want) (error \(error) > \(allowed))")
                        }
                    }
                }
            }
        }
        guard failures.isEmpty else {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("Colour round trip verified: stage background and screen content survive the MP4 export within 3/255 (greys) and 8/255 (saturated), decoded via AVAssetImageGenerator and AVAssetReader+CIImage, for untagged (greys) and BT.709-tagged recordings (as ScreenRecorder writes them).")
    }

    static func isNeutral(_ value: [Int]) -> Bool { Set(value).count == 1 }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Samples the stage corner and the content centre of the frame at 0.5 s as sRGB 8-bit.
    static func generatorPixels(asset: AVAsset) async throws -> (stage: [Int], content: [Int]) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let stage = try samplePixel(image, x: Int(Double(image.width) * 0.03), y: Int(Double(image.height) * 0.03))
        let content = try samplePixel(image, x: image.width / 2, y: image.height / 2)
        return (stage, content)
    }

    static func samplePixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        guard ok else { throw Failure.failed("could not create a sampling context") }
        return pixel.prefix(3).map(Int.init)
    }

    static func readerPixels(asset: AVAsset) async throws -> (stage: [Int], content: [Int]) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.failed("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        reader.add(output)
        guard reader.startReading() else { throw Failure.failed("reader did not start") }
        var buffer: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds >= 0.5 { buffer = CMSampleBufferGetImageBuffer(sample); break }
        }
        guard let buffer else { throw Failure.failed("no frame at 0.5 s") }
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        func sample(_ x: Int, _ y: Int) -> [Int] {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: sRGB)
            return pixel.prefix(3).map(Int.init)
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        return (sample(Int(Double(w) * 0.03), Int(Double(h) * 0.97)), sample(w / 2, h / 2))
    }

    static func makeFixture(url: URL, width: Int, height: Int, color: (UInt8, UInt8, UInt8), tagged: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.failed("writer did not start") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var maybe: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe) == kCVReturnSuccess,
                  let buffer = maybe else { throw Failure.failed("no fixture buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * stride + x * 4
                    p[0] = color.2; p[1] = color.1; p[2] = color.0; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if tagged {
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? Failure.failed("fixture frame rejected")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed("fixture did not finish") }
    }

    enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let reason) = self { return reason }; return nil }
    }
}
