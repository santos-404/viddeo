import AVFoundation
import CoreMedia
import Foundation

struct Failure: Error, CustomStringConvertible {
    var description: String
}

@MainActor
@main
struct VerifySilence {
    static var checks = 0
    static var tempFiles: [URL] = []

    static func main() async throws {
        defer { for url in tempFiles { try? FileManager.default.removeItem(at: url) } }
        try testOptions()
        try testPureChunks()
        try await testDetect()
        try testTrimSilence()
        try testSpeedUpSilence()
        print("Silence verified: \(checks) checks")
    }

    // MARK: Helpers

    static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw Failure(description: "FAILED: \(message)") }
    }

    static func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    static func expectThrows<E: Error & Equatable>(_ expected: E, _ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
            try expect(false, "\(message) (no error thrown)")
        } catch let error as E {
            try expect(error == expected, "\(message) (got \(error))")
        }
    }

    static func chunk(_ start: Double, _ end: Double) -> SilenceDetectionChunk {
        SilenceDetectionChunk(startMs: start, endMs: end, avgAmplitude: 0, durationMs: end - start)
    }

    /// Per-window RMS: `loud` windows at 1 followed by `quiet` windows at `quietLevel`, repeated.
    static func rmsPattern(_ parts: [(count: Int, level: Float)]) -> [Float] {
        parts.flatMap { Array(repeating: $0.level, count: $0.count) }
    }

    static func ranges(_ model: TimelineModel) -> [[Double]] {
        model.segments.map { [$0.sourceStart, $0.sourceEnd] }
    }

    static func sameRanges(_ model: TimelineModel, _ expected: [[Double]]) -> Bool {
        let actual = ranges(model)
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { near($0[0], $1[0], 1e-9) && near($0[1], $1[1], 1e-9) }
    }

    // MARK: Options

    static func testOptions() throws {
        let options = SilenceOptions()
        try expect(options.threshold == 0.1, "default threshold is the observed 0.1")
        try expect(options.minSilenceDurationMs == 500, "default minimum silence is 500 ms")
        try expect(options.windowMs == 50, "default window is the observed 50 ms")
        try options.validate()
        try expect(true, "defaults validate")
        for (label, mutate) in [
            ("negative threshold", { (o: inout SilenceOptions) in o.threshold = -0.1 }),
            ("threshold above 1", { $0.threshold = 1.5 }),
            ("NaN threshold", { $0.threshold = .nan }),
            ("negative minimum", { $0.minSilenceDurationMs = -1 }),
            ("infinite minimum", { $0.minSilenceDurationMs = .infinity }),
            ("zero window", { $0.windowMs = 0 }),
            ("NaN window", { $0.windowMs = .nan }),
            ("window above 1000 ms", { $0.windowMs = 1500 })
        ] as [(String, (inout SilenceOptions) -> Void)] {
            var bad = SilenceOptions()
            mutate(&bad)
            try expectThrows(SilenceError.invalidOptions, "\(label) is rejected") { try bad.validate() }
        }
        var edge = SilenceOptions()
        edge.threshold = 0
        edge.minSilenceDurationMs = 0
        edge.windowMs = 1
        try edge.validate()
        try expect(true, "boundary values 0 / 0 / 1 validate")
        let decoded = try JSONDecoder().decode(SilenceOptions.self, from: JSONEncoder().encode(options))
        try expect(decoded == options, "options survive a Codable round trip")
    }

    // MARK: Pure core

    static func testPureChunks() throws {
        let options = SilenceOptions()
        try expect(SilenceDetector.chunks(rms: [], windowMs: 50, options: options).isEmpty, "no windows → no chunks")
        try expect(SilenceDetector.chunks(rms: Array(repeating: 0.5, count: 100), windowMs: 50, options: options).isEmpty,
                   "all-loud (constant) → no chunks")

        let quiet = SilenceDetector.chunks(rms: Array(repeating: 0, count: 40), windowMs: 50, options: options)
        try expect(quiet.count == 1 && quiet[0].startMs == 0 && quiet[0].endMs == 2000 && quiet[0].durationMs == 2000,
                   "all-zero → one chunk spanning the file")
        try expect(quiet[0].avgAmplitude == 0, "all-zero chunk has zero amplitude")
        try expect(SilenceDetector.chunks(rms: Array(repeating: 0.001, count: 40), windowMs: 50, options: options).isEmpty,
                   "constant low level is not silent: threshold is relative to the peak")

        // tone · silence · tone · near-silence
        let pattern = rmsPattern([(20, 1), (20, 0), (20, 1), (20, 0.05)])
        let found = SilenceDetector.chunks(rms: pattern, windowMs: 50, options: options)
        try expect(found.count == 2, "two silent regions found")
        try expect(found[0].startMs == 1000 && found[0].endMs == 2000 && found[0].durationMs == 1000, "first chunk boundaries are exact window multiples")
        try expect(found[1].startMs == 3000 && found[1].endMs == 4000, "trailing chunk runs to the last window")
        try expect(near(found[0].avgAmplitude, 0), "first chunk avgAmplitude is the mean RMS (0)")
        try expect(near(found[1].avgAmplitude, Double(Float(0.05))), "second chunk avgAmplitude is the mean RMS (0.05)")
        let mixed = SilenceDetector.chunks(rms: rmsPattern([(2, 1), (5, 0.02), (5, 0.04), (1, 1), (10, 0)]), windowMs: 50, options: options)
        try expect(mixed.count == 2 && near(mixed[0].avgAmplitude, 0.03, 1e-6), "avgAmplitude averages differing windows")

        // Minimum duration: 450 ms dropped, 500 ms kept (inclusive), 550 ms kept.
        for (windows, kept) in [(9, false), (10, true), (11, true)] {
            let rms = rmsPattern([(4, 1), (windows, 0), (4, 1)])
            let result = SilenceDetector.chunks(rms: rms, windowMs: 50, options: options)
            try expect(result.isEmpty != kept, "\(windows * 50) ms silence \(kept ? "kept" : "dropped") at the 500 ms minimum")
        }
        var zeroMinimum = options
        zeroMinimum.minSilenceDurationMs = 0
        let single = SilenceDetector.chunks(rms: rmsPattern([(3, 1), (1, 0), (3, 1)]), windowMs: 50, options: zeroMinimum)
        try expect(single.count == 1 && single[0].startMs == 150 && single[0].endMs == 200, "minimum 0 keeps a single silent window")
        try expect(SilenceDetector.chunks(rms: rmsPattern([(3, 1), (1, 0), (3, 1)]), windowMs: 50, options: options).isEmpty,
                   "a lone silent window is below the default minimum")
        let split = SilenceDetector.chunks(rms: rmsPattern([(10, 0), (1, 1), (10, 0)]), windowMs: 50, options: options)
        try expect(split.count == 2 && split[0].endMs == 500 && split[1].startMs == 550, "one loud window separates chunks")

        // Peak-ratio semantics.
        let scaled = pattern.map { $0 * 0.001 }
        try expect(SilenceDetector.chunks(rms: scaled, windowMs: 50, options: options) .map { [$0.startMs, $0.endMs] }
                    == found.map { [$0.startMs, $0.endMs] }, "chunk positions are invariant to overall gain")
        var quarter = zeroMinimum
        quarter.threshold = 0.25
        let edgePattern: [Float] = [1, 0.25, 0.26, 1]
        let edgeChunks = SilenceDetector.chunks(rms: edgePattern, windowMs: 50, options: quarter)
        try expect(edgeChunks.count == 1 && edgeChunks[0].startMs == 50 && edgeChunks[0].endMs == 100,
                   "RMS exactly threshold × peak is silent, just above is not")
        var zero = zeroMinimum
        zero.threshold = 0
        let exactZero = SilenceDetector.chunks(rms: [1, 0, 0.001, 1], windowMs: 50, options: zero)
        try expect(exactZero.count == 1 && exactZero[0].startMs == 50 && exactZero[0].endMs == 100, "threshold 0 matches only exact zeros")
        var full = options
        full.threshold = 1
        let all = SilenceDetector.chunks(rms: [1, 0.5, 1, 0.2] + Array(repeating: 1, count: 20), windowMs: 50, options: full)
        try expect(all.count == 1 && all[0].startMs == 0 && all[0].endMs == 1200, "threshold 1 makes every window silent")
        let wide = SilenceDetector.chunks(rms: rmsPattern([(3, 1), (30, 0), (3, 1)]), windowMs: 20,
                                          options: SilenceOptions(threshold: 0.1, minSilenceDurationMs: 500, windowMs: 20))
        try expect(wide.count == 1 && wide[0].startMs == 60 && wide[0].endMs == 660, "times follow the window size (20 ms)")
        var invalid = options
        invalid.threshold = 2
        try expect(SilenceDetector.chunks(rms: pattern, windowMs: 50, options: invalid).isEmpty, "invalid options yield no chunks")
        try expect(SilenceDetector.chunks(rms: pattern, windowMs: 0, options: options).isEmpty, "zero window yields no chunks")

        let accumulator = windowAccumulatorCheck()
        try expect(accumulator, "streaming accumulator matches a direct RMS regardless of buffer splits")
    }

    static func windowAccumulatorCheck() -> Bool {
        let samples = (0..<1000).map { Float(sin(Double($0) * 0.1)) }
        var whole = WindowRMSAccumulator(windowSamples: 100)
        samples.withUnsafeBufferPointer { whole.append($0) }
        var parts = WindowRMSAccumulator(windowSamples: 100)
        for slice in [0..<37, 37..<301, 301..<302, 302..<1000] {
            samples[slice].withUnsafeBufferPointer { parts.append($0) }
        }
        let direct = (0..<10).map { window -> Float in
            let slice = samples[window * 100..<(window + 1) * 100]
            return Float((slice.reduce(0.0) { $0 + Double($1 * $1) } / 100).squareRoot())
        }
        guard whole.rms.count == 10, parts.rms.count == 10 else { return false }
        return zip(whole.rms, direct).allSatisfy { abs($0 - $1) < 1e-5 } && whole.rms == parts.rms
    }

    // MARK: Detect on synthetic audio

    static func temporaryURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-silence-\(UUID().uuidString).\(ext)")
        tempFiles.append(url)
        return url
    }

    static func tone(seconds: Double, rate: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
    }

    /// 1 s tone, 1 s silence, 1 s tone, 1 s silence.
    static func pattern(rate: Double) -> [Float] {
        tone(seconds: 1, rate: rate) + [Float](repeating: 0, count: Int(rate)) + tone(seconds: 1, rate: rate)
            + [Float](repeating: 0, count: Int(rate))
    }

    static func writeAudioFile(_ samples: [Float], rate: Double, to url: URL, settings: [String: Any]) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw Failure(description: "could not create PCM buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() { channel[index] = value }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func sampleBuffer(_ samples: ArraySlice<Float>, firstFrame: Int, rate: Double,
                             format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure(description: "block buffer \(status)") }
        let array = Array(samples)
        status = array.withUnsafeBytes { raw -> OSStatus in
            guard let source = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferReplaceDataBytes(with: source, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == noErr else { throw Failure(description: "block fill \(status)") }
        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(firstFrame), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw Failure(description: "sample buffer \(status)") }
        return buffer
    }

    /// An .mp4 with one AAC track per entry; titles go through the same writer-input metadata the recorder uses.
    static func writeMovie(tracks: [(title: String?, samples: [Float])], rate: Double, to url: URL) async throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format
        else { throw Failure(description: "no audio format description") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var inputs: [AVAssetWriterInput] = []
        for track in tracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ], sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if let title = track.title {
                let item = AVMutableMetadataItem()
                item.identifier = .commonIdentifierTitle
                item.value = title as NSString
                input.metadata = [item]
            }
            guard writer.canAdd(input) else { throw Failure(description: "writer cannot add an audio input") }
            writer.add(input)
            inputs.append(input)
        }
        guard writer.startWriting() else { throw writer.error ?? Failure(description: "writer did not start") }
        writer.startSession(atSourceTime: .zero)
        let chunkFrames = Int(rate / 2)
        let total = tracks.map(\.samples.count).max() ?? 0
        var position = 0
        while position < total {
            for (index, track) in tracks.enumerated() where position < track.samples.count {
                var waited = 0
                while !inputs[index].isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                    waited += 1
                    if waited > 5000 { throw Failure(description: "writer input never became ready") }
                }
                let end = min(track.samples.count, position + chunkFrames)
                let buffer = try sampleBuffer(track.samples[position..<end], firstFrame: position, rate: rate, format: format)
                guard inputs[index].append(buffer) else { throw writer.error ?? Failure(description: "append failed") }
            }
            position += chunkFrames
        }
        for input in inputs { input.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(description: "writer did not finish") }
    }

    static func withinOneWindow(_ chunks: [SilenceDetectionChunk], _ expected: [(Double, Double)], window: Double = 50) -> Bool {
        guard chunks.count == expected.count else { return false }
        return zip(chunks, expected).allSatisfy { abs($0.startMs - $1.0) <= window && abs($0.endMs - $1.1) <= window }
    }

    static func testDetect() async throws {
        let expected = [(1000.0, 2000.0), (3000.0, 4000.0)]

        // CAF (lossless).
        let caf = temporaryURL("caf")
        try writeAudioFile(pattern(rate: 44_100), rate: 44_100, to: caf, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let cafChunks = try await SilenceDetector.detect(audioURL: caf)
        try expect(withinOneWindow(cafChunks, expected), "CAF tone/silence/tone/silence: chunks within one window of 1–2 s and 3–4 s (got \(cafChunks.map { [$0.startMs, $0.endMs] }))")
        try expect(cafChunks.allSatisfy { $0.startMs.truncatingRemainder(dividingBy: 50) == 0 && $0.durationMs == $0.endMs - $0.startMs },
                   "detected times are window multiples and durations consistent")
        try expect(cafChunks.allSatisfy { $0.avgAmplitude < 0.05 }, "silent chunks have low amplitude")
        try expect(cafChunks.count == 2 && cafChunks[1].endMs >= 3950 && cafChunks[1].endMs <= 4000,
                   "the trailing silence ends at the last complete window (the resampler may drop the final partial window) (got \(cafChunks.map { [$0.startMs, $0.endMs] }))")

        // Peak-ratio on real audio: a quieter second tone is still loud relative to silence.
        let quietTone = temporaryURL("caf")
        try writeAudioFile(tone(seconds: 1, rate: 16_000, amplitude: 0.5) + [Float](repeating: 0, count: 16_000)
                            + tone(seconds: 1, rate: 16_000, amplitude: 0.1), rate: 16_000, to: quietTone, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let quietChunks = try await SilenceDetector.detect(audioURL: quietTone)
        try expect(withinOneWindow(quietChunks, [(1000, 2000)]), "a tone at 20% of the peak is not silent at threshold 0.1")
        var strict = SilenceOptions()
        strict.threshold = 0.3
        let strictChunks = try await SilenceDetector.detect(audioURL: quietTone, options: strict)
        try expect(strictChunks.count == 1 && strictChunks[0].startMs == 1000 && strictChunks[0].endMs == 3000,
                   "at threshold 0.3 the quieter tone merges into the silence (got \(strictChunks.map { [$0.startMs, $0.endMs] }))")

        // AAC .m4a.
        let m4a = temporaryURL("m4a")
        try writeAudioFile(pattern(rate: 44_100), rate: 44_100, to: m4a, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let m4aChunks = try await SilenceDetector.detect(audioURL: m4a)
        try expect(withinOneWindow(m4aChunks, expected), "m4a tone/silence/tone/silence within one window (got \(m4aChunks.map { [$0.startMs, $0.endMs] }))")

        // Streaming window count.
        let asset = AVURLAsset(url: caf)
        let track = try await SilenceDetector.selectTrack(in: asset, selection: .lastAudioTrack)
        let rms = try await SilenceDetector.windowRMS(asset: asset, track: track, windowMs: 50)
        try expect(rms.count >= 79 && rms.count <= 80, "4 s of audio yields 80 complete 50 ms windows (got \(rms.count))")
        try expect(near(Double(rms[5]), 0.5 / 2.0.squareRoot(), 0.02), "tone RMS is amplitude/√2 (got \(rms[5]))")

        // Two-track movies.
        let rate = 44_100.0
        let continuous = tone(seconds: 4, rate: rate)
        let speech = pattern(rate: rate)
        let systemFirst = temporaryURL("mp4")
        try await writeMovie(tracks: [("System Audio", continuous), ("Microphone", speech)], rate: rate, to: systemFirst)
        let systemTitles = try await trackTitles(systemFirst)
        try expect(systemTitles == ["System Audio", "Microphone"], "test movie carries the track titles (got \(systemTitles))")
        let byTitle = try await SilenceDetector.detect(audioURL: systemFirst)
        try expect(withinOneWindow(byTitle, expected), "[System, Microphone] picks the Microphone track by title (got \(byTitle.map { [$0.startMs, $0.endMs] }))")
        let systemOnly = try await SilenceDetector.detect(audioURL: systemFirst, trackSelection: .index(0))
        try expect(systemOnly.isEmpty, "the continuous system track has no silence")
        let microphoneFirst = temporaryURL("mp4")
        try await writeMovie(tracks: [("Microphone", speech), ("System Audio", continuous)], rate: rate, to: microphoneFirst)
        let titleBeatsOrder = try await SilenceDetector.detect(audioURL: microphoneFirst)
        try expect(withinOneWindow(titleBeatsOrder, expected), "[Microphone, System] still picks Microphone: title wins over order")
        let lastTrack = try await SilenceDetector.detect(audioURL: microphoneFirst, trackSelection: .lastAudioTrack)
        try expect(lastTrack.isEmpty, ".lastAudioTrack picks the system track here")
        let custom = try await SilenceDetector.detect(audioURL: microphoneFirst, trackSelection: .microphone(title: "System Audio"))
        try expect(custom.isEmpty, "a custom title selects that track")
        let untitled = temporaryURL("mp4")
        try await writeMovie(tracks: [(nil, continuous), (nil, speech)], rate: rate, to: untitled)
        let fallback = try await SilenceDetector.detect(audioURL: untitled)
        try expect(withinOneWindow(fallback, expected), "untitled tracks fall back to the last audio track")

        // Errors.
        var bad = SilenceOptions()
        bad.windowMs = 0
        do {
            _ = try await SilenceDetector.detect(audioURL: caf, options: bad)
            try expect(false, "invalid options must throw")
        } catch let error as SilenceError {
            try expect(error == .invalidOptions, "invalid options throw invalidOptions")
        }
        do {
            _ = try await SilenceDetector.detect(audioURL: caf, trackSelection: .index(3))
            try expect(false, "an out-of-range track index must throw")
        } catch let error as SilenceError {
            try expect(error == .noAudioTrack, "an out-of-range track index throws noAudioTrack")
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("viddeo-silence-missing-\(UUID().uuidString).caf")
        var threw = false
        do { _ = try await SilenceDetector.detect(audioURL: missing) } catch { threw = true }
        try expect(threw, "a missing file throws")
    }

    static func trackTitles(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        var titles: [String] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            var title = ""
            for item in try await track.load(.commonMetadata) + track.load(.metadata)
            where item.identifier == .commonIdentifierTitle || item.commonKey == .commonKeyTitle {
                title = try await item.load(.stringValue) ?? ""
            }
            titles.append(title)
        }
        return titles
    }

    // MARK: trimSilence

    static func testTrimSilence() throws {
        let chunks = [chunk(2000, 5000), chunk(8000, 8500), chunk(12000, 14000)]
        var model = TimelineModel(sourceDuration: 20)
        let report = try model.trimSilence(chunks: chunks)
        try model.validate()
        try expect(report.affectedChunks == 2 && report.skippedChunks == 1, "two chunks trimmed, the 200 ms inner region skipped")
        try expect(near(report.removedSourceSeconds, 4.4), "removed = Σ(chunk − 2×padding) = 4.4 s (got \(report.removedSourceSeconds))")
        try expect(near(report.savedPlaybackSeconds, 4.4), "saved playback equals removed source at 1× speed")
        try expect(near(model.playbackDuration, 20 - 4.4), "duration shrinks by Σ(removed − 2×padding)")
        try expect(sameRanges(model, [[0, 2.15], [4.85, 12.15], [13.85, 20]]), "padding of 150 ms stays on both sides of each cut (got \(ranges(model)))")

        // Kept source content keeps its identity: playback ↔ source round trips; trimmed time maps to nil.
        var keptOK = true
        for time in stride(from: 0.0, through: 19.9, by: 0.37) where model.playbackTime(forSourceTime: time) != nil {
            let playback = model.playbackTime(forSourceTime: time) ?? -1
            keptOK = keptOK && near(model.sourceTime(forPlaybackTime: playback), time, 1e-9)
        }
        try expect(keptOK, "kept source times round-trip through playback")
        try expect(model.playbackTime(forSourceTime: 3) == nil && model.playbackTime(forSourceTime: 13) == nil, "trimmed source times map to nil")
        try expect(near(model.playbackTime(forSourceTime: 1), 1) && near(model.playbackTime(forSourceTime: 6), 6 - 2.7)
                    && near(model.playbackTime(forSourceTime: 15), 15 - 4.4), "kept source times shift by exactly the removed footage before them")

        // Idempotent.
        let before = model
        let again = try model.trimSilence(chunks: chunks)
        try expect(model == before, "applying the same chunks twice changes nothing")
        try expect(again.affectedChunks == 0 && again.skippedChunks == 3 && again.removedSourceSeconds == 0, "second pass reports nothing affected")

        // Order independence, overlapping chunks.
        var shuffled = TimelineModel(sourceDuration: 20)
        try shuffled.trimSilence(chunks: chunks.reversed())
        try expect(sameRanges(shuffled, ranges(model)), "chunk order does not matter")
        var overlapping = TimelineModel(sourceDuration: 20)
        let overlapReport = try overlapping.trimSilence(chunks: [chunk(2000, 5000), chunk(4000, 6000)])
        try expect(sameRanges(overlapping, [[0, 2.15], [5.85, 20]]) && overlapReport.affectedChunks == 2,
                   "overlapping chunks merge into one cut (got \(ranges(overlapping)))")

        // Properties survive.
        var styled = TimelineModel(sourceDuration: 20)
        try styled.setVolume(segmentID: styled.segments[0].id, to: 0.5)
        try styled.setHideCursor(segmentID: styled.segments[0].id, to: true)
        try styled.trimSilence(chunks: [chunk(2000, 5000)])
        try expect(styled.segments.count == 2 && styled.segments.allSatisfy { $0.volume == 0.5 && $0.hideCursor }, "split pieces inherit segment properties")

        // Straddling a segment boundary.
        var straddle = TimelineModel(sourceDuration: 20)
        try straddle.split(atSource: 10)
        let straddleReport = try straddle.trimSilence(chunks: [chunk(9000, 11000)])
        try expect(sameRanges(straddle, [[0, 9.15], [10.85, 20]]) && near(straddleReport.removedSourceSeconds, 1.7),
                   "a chunk across a segment boundary trims both sides (got \(ranges(straddle)))")

        // Segment edge slivers: never leave a piece shorter than 0.1 s.
        var sliver = TimelineModel(sourceDuration: 10)
        let sliverReport = try sliver.trimSilence(chunks: [chunk(50, 3000)], keepPaddingMs: 0, minRemovedMs: 0)
        try expect(sameRanges(sliver, [[0, 0.1], [3, 10]]) && near(sliverReport.removedSourceSeconds, 2.9),
                   "a cut 50 ms from the start keeps the 0.1 s minimum (got \(ranges(sliver)))")
        try sliver.validate()
        try expect(true, "sliver result validates")

        // Last segment cannot be deleted.
        var whole = TimelineModel(sourceDuration: 10)
        let wholeBefore = whole
        let wholeReport = try whole.trimSilence(chunks: [chunk(0, 10_000)], keepPaddingMs: 0, minRemovedMs: 0)
        try expect(whole == wholeBefore && wholeReport.affectedChunks == 0 && wholeReport.skippedChunks == 1,
                   "removing the only segment is skipped, not an error")
        var halves = TimelineModel(sourceDuration: 10)
        try halves.split(atSource: 5)
        let halvesReport = try halves.trimSilence(chunks: [chunk(0, 10_000)], keepPaddingMs: 0, minRemovedMs: 0)
        try expect(sameRanges(halves, [[5, 10]]) && halvesReport.affectedChunks == 1, "the last remaining segment survives a full-length chunk")

        // Reordered timeline.
        var reordered = TimelineModel(sourceDuration: 20)
        let first = reordered.segments[0].id
        try reordered.split(atSource: 10)
        try reordered.move(segmentID: first, toIndex: 1)
        try expect(sameRanges(reordered, [[10, 20], [0, 10]]), "reordered fixture")
        let reorderedReport = try reordered.trimSilence(chunks: [chunk(4000, 6000), chunk(14000, 16000)])
        try expect(sameRanges(reordered, [[10, 14.15], [15.85, 20], [0, 4.15], [5.85, 10]]),
                   "reordered timeline keeps playback order, cuts at source ranges (got \(ranges(reordered)))")
        try expect(near(reordered.playbackDuration, 20 - 3.4) && reorderedReport.affectedChunks == 2, "reordered duration shrinks by the removed footage")
        try expect(near(reordered.playbackTime(forSourceTime: 16), 4.3) && near(reordered.playbackTime(forSourceTime: 1), 9.3),
                   "kept source times in the reordered timeline still map")

        // Chunks outside kept footage or invalid.
        var gaps = TimelineModel(sourceDuration: 20)
        try gaps.trimSilence(chunks: [chunk(2000, 5000)])
        let gapsBefore = gaps
        let invalidReport = try gaps.trimSilence(chunks: [chunk(30_000, 32_000), chunk(.nan, 100), chunk(9000, 8000), chunk(3000, 4000)])
        try expect(gaps == gapsBefore && invalidReport.skippedChunks == 4, "out-of-range, NaN, inverted and already-trimmed chunks are skipped")

        // Atomicity.
        var broken = TimelineModel(sourceDuration: 20)
        try broken.split(atSource: 8)
        broken.segments[1].volume = 5
        let brokenBefore = broken
        try expectThrows(TimelineError.invalidVolume, "an invalid model is rejected") { _ = try broken.trimSilence(chunks: chunks) }
        try expect(broken == brokenBefore, "a failed trim leaves the model unchanged")
        var intact = TimelineModel(sourceDuration: 20)
        let intactBefore = intact
        try expectThrows(TimelineError.nonFiniteValue, "NaN padding is rejected") { _ = try intact.trimSilence(chunks: chunks, keepPaddingMs: .nan) }
        try expectThrows(TimelineError.nonFiniteValue, "negative padding is rejected") { _ = try intact.trimSilence(chunks: chunks, keepPaddingMs: -1) }
        try expectThrows(TimelineError.nonFiniteValue, "infinite minimum is rejected") { _ = try intact.trimSilence(chunks: chunks, minRemovedMs: .infinity) }
        try expect(intact == intactBefore, "rejected arguments leave the model unchanged")
    }

    // MARK: speedUpSilence

    static func testSpeedUpSilence() throws {
        let chunks = [chunk(2000, 5000), chunk(8000, 8500), chunk(12000, 14000)]
        var model = TimelineModel(sourceDuration: 20)
        let report = try model.speedUpSilence(chunks: chunks)
        try model.validate()
        try expect(sameRanges(model, [[0, 2.15], [2.15, 4.85], [4.85, 12.15], [12.15, 13.85], [13.85, 20]]),
                   "splits land on the padded inner boundaries (got \(ranges(model)))")
        try expect(model.segments.map(\.timeScale) == [1, 0.25, 1, 0.25, 1], "only inner segments get the 4× time scale")
        let expectedDuration = 20 - 4.4 + 4.4 * 0.25
        try expect(near(model.playbackDuration, expectedDuration), "playback duration = Σ(source × scale) (got \(model.playbackDuration))")
        try expect(near(model.segments.reduce(0) { $0 + $1.sourceDuration * $1.timeScale }, expectedDuration), "Σ(source × scale) matches playbackDuration")
        try expect(report.affectedChunks == 2 && report.skippedChunks == 1 && report.removedSourceSeconds == 0, "report counts, nothing removed")
        try expect(near(report.savedPlaybackSeconds, 4.4 * 0.75), "saved playback = inner × (1 − scale)")
        try expect(near(model.playbackTime(forSourceTime: 3.0), 2.15 + 0.85 * 0.25), "source times inside a sped segment map with the time scale")
        try expect(near(model.playbackTime(forSourceTime: 6), 2.15 + 2.7 * 0.25 + (6 - 4.85)), "source times after a sped segment shift accordingly")

        let before = model
        let again = try model.speedUpSilence(chunks: chunks)
        try expect(model == before && again.affectedChunks == 0, "applying twice is a no-op")

        // Outer segments untouched, including their own speed; inner override.
        var custom = TimelineModel(sourceDuration: 20)
        try custom.split(atSource: 10)
        try custom.setTimeScale(segmentID: custom.segments[0].id, to: 0.5)
        let outerID = custom.segments[0].id
        try custom.speedUpSilence(chunks: [chunk(4000, 7000)], timeScale: 0.2)
        try expect(custom.segments.count == 4 && custom.segments[0].id == outerID && custom.segments[0].timeScale == 0.5
                    && custom.segments[0].sourceEnd == 4.15, "outer part keeps its own speed")
        try expect(custom.segments[1].timeScale == 0.2 && custom.segments[2].timeScale == 0.5 && custom.segments[3].timeScale == 1,
                   "inner part is overridden; the remaining pieces inherit the original speed")

        // Straddling a segment boundary.
        var straddle = TimelineModel(sourceDuration: 20)
        try straddle.split(atSource: 10)
        try straddle.speedUpSilence(chunks: [chunk(9000, 11000)])
        try expect(sameRanges(straddle, [[0, 9.15], [9.15, 10], [10, 10.85], [10.85, 20]])
                    && straddle.segments.map(\.timeScale) == [1, 0.25, 0.25, 1], "a chunk across a boundary speeds both sides (got \(ranges(straddle)))")

        // Reordered.
        var reordered = TimelineModel(sourceDuration: 20)
        let first = reordered.segments[0].id
        try reordered.split(atSource: 10)
        try reordered.move(segmentID: first, toIndex: 1)
        try reordered.speedUpSilence(chunks: [chunk(4000, 6000)])
        try expect(sameRanges(reordered, [[10, 20], [0, 4.15], [4.15, 5.85], [5.85, 10]])
                    && reordered.segments.map(\.timeScale) == [1, 1, 0.25, 1], "reordered timeline keeps order and speeds the inner range")

        // Padding / minimum handling.
        var padded = TimelineModel(sourceDuration: 20)
        let paddedReport = try padded.speedUpSilence(chunks: [chunk(2000, 5000)], timeScale: 0.5, keepPaddingMs: 500, minDurationMs: 0)
        try expect(sameRanges(padded, [[0, 2.5], [2.5, 4.5], [4.5, 20]]) && padded.segments[1].timeScale == 0.5 && paddedReport.affectedChunks == 1,
                   "custom padding of 500 ms respected")
        var tiny = TimelineModel(sourceDuration: 20)
        let tinyBefore = tiny
        let tinyReport = try tiny.speedUpSilence(chunks: [chunk(5000, 5090), chunk(6000, 6400)], keepPaddingMs: 0, minDurationMs: 0)
        try expect(tinyReport.skippedChunks == 1 && tinyReport.affectedChunks == 1, "an inner piece below 0.1 s is skipped")
        try expect(tiny != tinyBefore && sameRanges(tiny, [[0, 6], [6, 6.4], [6.4, 20]]), "the 400 ms chunk is still sped up")
        var tooSmall = TimelineModel(sourceDuration: 20)
        let smallBefore = tooSmall
        let smallReport = try tooSmall.speedUpSilence(chunks: [chunk(2000, 5000)], keepPaddingMs: 1600, minDurationMs: 0)
        try expect(tooSmall == smallBefore && smallReport.skippedChunks == 1, "padding larger than half the chunk leaves it alone")

        // Atomicity and argument validation.
        let model2 = TimelineModel(sourceDuration: 20)
        var untouched = model2
        try expectThrows(TimelineError.invalidTimeScale, "time scale below the range") { _ = try untouched.speedUpSilence(chunks: chunks, timeScale: 0.01) }
        try expectThrows(TimelineError.invalidTimeScale, "time scale above the range") { _ = try untouched.speedUpSilence(chunks: chunks, timeScale: 20) }
        try expectThrows(TimelineError.nonFiniteValue, "NaN time scale") { _ = try untouched.speedUpSilence(chunks: chunks, timeScale: .nan) }
        try expectThrows(TimelineError.nonFiniteValue, "NaN padding") { _ = try untouched.speedUpSilence(chunks: chunks, keepPaddingMs: .nan) }
        var broken = TimelineModel(sourceDuration: 20)
        try broken.split(atSource: 8)
        broken.segments[1].systemVolume = -1
        let brokenBefore = broken
        try expectThrows(TimelineError.invalidVolume, "an invalid model is rejected") { _ = try broken.speedUpSilence(chunks: chunks) }
        try expect(untouched == model2 && broken == brokenBefore, "failed speed-ups leave the model unchanged")

        // Trim after speed-up: both actions compose.
        var combined = TimelineModel(sourceDuration: 20)
        try combined.speedUpSilence(chunks: [chunk(2000, 5000)])
        try combined.trimSilence(chunks: [chunk(12000, 14000)])
        try combined.validate()
        try expect(near(combined.playbackDuration, 20 - 2.7 + 2.7 * 0.25 - 1.7), "speed-up and trim compose")
    }
}
