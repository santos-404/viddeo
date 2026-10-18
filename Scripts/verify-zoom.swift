import CoreGraphics
import Foundation

@main
struct VerifyZoom {
    static func main() throws {
        try testExactTimingAndFinalSecond()
        try testInclusiveMergeGap()
        try testShortAndNoClickIdentity()
        try testRejectsInvalidEvents()
        try testSpatialGroupsAndDwellCentering()
        try testRandomSeekDeterminism()
        try testSmoothBoundedTransitionsAndReturn()
        try testInvalidPersistedConfiguration()
        try testExtremeValidSpringStability()
        try testScreenMotionBlurShutter()
        try testSpringSettleEstimates()
        try testSpringClamp()
        try testSpringPrecision()
        try testSpringRetargetAndConfigContinuity()
        try testSpringDurationFitting()
        try testVisibleSourceGrouping()
        try testResolvedVisibleGeometry()
        try testSpringSamplingOrder()
        print("Zoom verification passed: 18 checks")
    }

    private static func testSpringSettleEstimates() throws {
        // Independent evaluations of the decoded settle estimator, not the live stepper.
        try expectClose(SpringConfiguration.screen.settleTimeMilliseconds, 1483.3333333333344, "default settle time")
        try expectClose(SpringConfiguration.presetQ.settleTimeMilliseconds, 483, "Q settle time")
        try expectClose(SpringConfiguration.instant.settleTimeMilliseconds, 0, "instant settle time")
        try expectClose(SpringConfiguration.screen.settleTimeMilliseconds, 1483.3333333333344, "cached default estimate")
        var unclamped = SpringConfiguration.screen
        unclamped.clamp = false
        try expectClose(unclamped.settleTimeMilliseconds, SpringConfiguration.screen.settleTimeMilliseconds,
                        "clamp participates in the cache key but does not affect estimator integration")
        print("Spring settle estimates: default=\(SpringConfiguration.screen.settleTimeMilliseconds) ms, Q=\(SpringConfiguration.presetQ.settleTimeMilliseconds) ms")
    }

    private static func testSpringClamp() throws {
        for target in [-1.0, 1.0] {
            var spring = Spring(value: 0)
            spring.setTarget(target)
            var previous = 0.0
            for _ in 0..<300 {
                spring.advance(milliseconds: SpringConfiguration.frameMilliseconds)
                try expect(target > 0 ? spring.value <= target && spring.value >= previous
                                      : spring.value >= target && spring.value <= previous,
                           "a rested target step at 60 fps must approach without crossing its target")
                previous = spring.value
            }
            try expect(spring.isAtRest, "clamped spring must reach exact rest")
        }
        var config = SpringConfiguration.screen
        config.clamp = false
        var spring = Spring(value: 0, configuration: config)
        spring.setTarget(1)
        var peak = 0.0
        for _ in 0..<120 {
            spring.advance(milliseconds: SpringConfiguration.frameMilliseconds)
            peak = max(peak, spring.value)
        }
        try expect(peak > 1.1, "disabling adaptive damping preserves underdamped overshoot")
        // A literal no-crossing clamp would fail this: damping is selected only at advance start.
        var longStep = Spring(value: 0)
        longStep.setTarget(1)
        longStep.advance(milliseconds: 300)
        try expect(longStep.value > 1, "reference clamp is not an unconditional position clamp")
    }

    private static func testSpringPrecision() throws {
        try expectClose(Spring.restTolerance(from: 0, to: 1000, precision: 0.002), 2, "precision scales with distance")
        try expectClose(Spring.restTolerance(from: 0, to: 0.1, precision: 0.002), 0.002, "precision has a unit-distance floor")
        try expectClose(Spring.restTolerance(from: 3, to: 3, precision: 0.002), 1, "equal current and target uses the special tolerance")
        var tiny = Spring(value: 0)
        tiny.setTarget(0.001)
        try expect(!tiny.isAtRest, "at-rest getter requires exact target and zero velocity")
        tiny.advance(milliseconds: 1)
        try expect(tiny.isAtRest && tiny.value == 0.001 && tiny.velocity == 0, "precision snaps both position and velocity")
        var moving = Spring(value: 0)
        moving.setTarget(1)
        for _ in 0..<8 { moving.advance(milliseconds: SpringConfiguration.frameMilliseconds) }
        moving.setTarget(moving.value + 0.001)
        moving.advance(milliseconds: 1)
        try expect(!moving.isAtRest && abs(moving.velocity) > moving.tolerance,
                   "small displacement alone cannot mark a fast spring at rest")
        moving.advance(milliseconds: moving.configuration.settleTimeMilliseconds)
        try expect(moving.isAtRest, "an advance as large as the settle estimate snaps directly")
    }

    private static func testSpringRetargetAndConfigContinuity() throws {
        var spring = Spring(value: 0)
        spring.setTarget(1)
        for _ in 0..<6 { spring.advance(milliseconds: SpringConfiguration.frameMilliseconds) }
        let oldVelocity = spring.velocity, oldValue = spring.value
        try expect(oldVelocity > 0, "spring must be moving before retarget")
        spring.setTarget(-0.5)
        try expect(spring.velocity == oldVelocity && spring.value == oldValue, "retarget must preserve velocity and position exactly")
        let tolerance = spring.tolerance
        spring.updateConfiguration(.presetQ)
        try expect(spring.velocity == oldVelocity && spring.value == oldValue && spring.tolerance == tolerance,
                   "configuration changes preserve motion and the current target's precision")
        spring.advance(milliseconds: 1)
        try expect(spring.value > oldValue && spring.velocity > 0, "reverse retarget keeps existing momentum before reversing")
        let latchedTolerance = spring.tolerance
        spring.setTarget(-0.5)
        try expect(spring.tolerance == latchedTolerance, "an unchanged target must not recompute precision")
        spring.updateConfiguration(.instant)
        spring.advance(milliseconds: 1)
        try expect(spring.isAtRest && spring.value == -0.5, "mass zero snaps on advance")
    }

    private static func testSpringDurationFitting() throws {
        let config = SpringConfiguration.screen, settle = config.settleTimeMilliseconds
        try expect(config.fitted(toDurationMilliseconds: settle) == config, "no fitting when duration already accommodates settling")
        try expect(config.fitted(toDurationMilliseconds: settle * 2) == config, "long durations do not slow a spring down")
        try expect(config.fitted(toDurationMilliseconds: 2 * SpringConfiguration.frameMilliseconds) == .instant,
                   "at most two 60 fps frames uses instant configuration")
        let fitted = config.fitted(toDurationMilliseconds: settle / 2)
        try expectClose(fitted.stiffness, config.stiffness * 4, "duration fitting scales stiffness quadratically")
        try expectClose(fitted.damping, config.damping * 2, "duration fitting scales damping linearly")
        try expect(fitted.mass == config.mass && fitted.clamp == config.clamp && fitted.precision == config.precision,
                   "fitting preserves mass, clamp and precision")
        try expect(SpringConfiguration.instant.fitted(toDurationMilliseconds: 0) == .instant, "already instant config remains instant")
    }

    private static func testVisibleSourceGrouping() throws {
        let session = makeSession(duration: 8, events: [event(1, 0.35, 0.5, .down), event(2, 0.55, 0.5, .move)])
        var calls: [(Double, Double)] = []
        let landscape = ZoomTimeline(session: session, visibleSourceSize: { time, scale in
            calls.append((time, scale))
            return CGSize(width: 960, height: 540) // 16:9 visible source part at the selected zoom
        })
        let portrait = ZoomTimeline(session: session, visibleSourceSize: { _, _ in CGSize(width: 303.75, height: 540) }) // 9:16
        try expect(calls.count == 1 && abs(calls[0].0 - 0.7) < 1e-9 && calls[0].1 == 2,
                   "geometry is resolved at range start and selected zoom, once per range")
        try expect(portrait.frame(at: 3.3).centerX - landscape.frame(at: 3.3).centerX > 0.15,
                   "same trace forms separate horizontal groups in the narrower visible part")
        try expect(landscape.ranges == portrait.ranges, "geometry changes spatial grouping, not click windows")
        let invalid = ZoomTimeline(session: session, visibleSourceSize: { _, _ in CGSize(width: Double.nan, height: 0) })
        try expect(invalid.frame(at: 3.3) == landscape.frame(at: 3.3), "invalid geometry falls back to the legacy full-source viewport")
    }

    private static func testResolvedVisibleGeometry() throws {
        let source = CGSize(width: 1920, height: 1080)
        let landscape = ZoomVisibleGeometry(sourceSize: source, viewportSize: source, unzoomedScreenSize: source)
        let portrait = ZoomVisibleGeometry(sourceSize: source, viewportSize: CGSize(width: 1080, height: 1920),
                                          unzoomedScreenSize: CGSize(width: 1080, height: 607.5))
        try expect(landscape.visibleSourceSize(atZoom: 2) == CGSize(width: 960, height: 540), "landscape zoom visibility")
        try expect(portrait.visibleSourceSize(atZoom: 2) == CGSize(width: 960, height: 1080), "portrait stage exposes the entire source height")
        let split = ZoomVisibleGeometry(sourceSize: source, viewportSize: source, unzoomedScreenSize: CGSize(width: 960, height: 540))
        try expect(split.visibleSourceSize(atZoom: 2) == source, "smaller split pane increases the source visible inside the stage")
        let padded = ZoomVisibleGeometry(sourceSize: source, viewportSize: source, unzoomedScreenSize: CGSize(width: 1536, height: 864))
        try expect(padded.visibleSourceSize(atZoom: 2) == CGSize(width: 1200, height: 675), "padding affects the resolved visible source")
        let session = makeSession(duration: 8, events: [event(1, 0.5, 0.35, .down), event(2, 0.5, 0.7, .move)])
        let a = ZoomTimeline(session: session, visibleSourceSize: { _, zoom in landscape.visibleSourceSize(atZoom: zoom) })
        let b = ZoomTimeline(session: session, visibleSourceSize: { _, zoom in portrait.visibleSourceSize(atZoom: zoom) })
        try expect(a.frame(at: 3.3).centerY - b.frame(at: 3.3).centerY > 0.2,
                   "resolved portrait output groups the same vertical trace differently")
    }

    private static func testSpringSamplingOrder() throws {
        var fractional = Spring(value: 0, configuration: SpringConfiguration(stiffness: 100, damping: 10, mass: 1,
                                                                             clamp: false, precision: 1e-12))
        fractional.setTarget(1)
        fractional.advance(milliseconds: 1.25)
        // Hand-calculated 1ms then 0.75ms, specifically distinguishing the decoded convention
        // from a normal remaining-0.25ms integrator.
        try expect(abs(fractional.value - 0.000230681875) < 1e-12 && abs(fractional.velocity - 0.1742425) < 1e-12,
                   "nonintegral advances use the observed complement step")
        let timeline = ZoomTimeline(session: makeSession(duration: 8, events: [event(1, 0.6, 0.5, .down)]))
        try expectClose(timeline.frame(at: 0.7).scale, 1, "the range-start sample installs the target after advancing")
        try expect(timeline.frame(at: 0.7 + 1 / 60).scale > 1, "the next sample starts responding")
        let a = timeline.frame(at: 1), b = timeline.frame(at: 1 + 1 / 60)
        try expectClose(timeline.frame(at: 1 + 0.5 / 60).scale, (a.scale + b.scale) / 2, "fractional-frame queries interpolate samples")
    }

    /// Shutter math of the screen motion blur: same blur extent at any fps, nothing when still,
    /// sample caps, radial (scale) and directional (pan) motion.
    private static func testScreenMotionBlurShutter() throws {
        let width: CGFloat = 1920, height: CGFloat = 1080
        let timeline = ZoomTimeline(session: makeSession(duration: 8, events: [event(3, 0.75, 0.25, .down)]))
        func crops(at time: Double, fps: Double, amount: Double = 1) -> [CGRect] {
            let now = timeline.frame(at: time).cropRect(width: width, height: height)
            let before = timeline.frame(at: time - 1 / fps).cropRect(width: width, height: height)
            // Uncapped, so the extent is exact.
            return ScreenMotionBlur(amount: amount, fps: fps, maxSamples: 1000, spanPixels: 0.5)
                .crops(now: now, before: before, outputScale: 1)
        }
        /// Trail length of the crop's left edge, recovered from the midpoint samples.
        func extent(_ crops: [CGRect]) -> Double {
            guard crops.count > 1 else { return 0 }
            return Double(crops[crops.count - 1].minX - crops[0].minX) * Double(crops.count) / Double(crops.count - 1)
        }
        // Constant-velocity pan: edge travel per frame is v / fps, strength is fps / 60, so the extent is v / 60.
        let now = CGRect(x: 100, y: 100, width: 960, height: 540)
        let at30 = ScreenMotionBlur(amount: 1, fps: 30, maxSamples: 1000, spanPixels: 0.5)
            .crops(now: now, before: now.offsetBy(dx: -60, dy: 0), outputScale: 1)   // v = 1800 px/s
        let at60 = ScreenMotionBlur(amount: 1, fps: 60, maxSamples: 1000, spanPixels: 0.5)
            .crops(now: now, before: now.offsetBy(dx: -30, dy: 0), outputScale: 1)
        try expectClose(extent(at30), 30, "30 fps pan blur extent")
        try expectClose(extent(at60), 30, "60 fps pan blur extent")
        try expect(at30.last!.minX < now.minX && at30[0].minX < at30.last!.minX, "the trail is backward only")
        let half = ScreenMotionBlur(amount: 0.5, fps: 60, maxSamples: 1000, spanPixels: 0.5)
            .crops(now: now, before: now.offsetBy(dx: -30, dy: 0), outputScale: 1)
        try expectClose(extent(half), 15, "amount scales the extent")
        // The real zoom spring at its fastest: extent matches between 30 and 60 fps (the spring is smooth).
        var best = 0.0
        for time in stride(from: 3.0, to: 3.6, by: 0.01) { best = max(best, widthExtent(crops(at: time, fps: 60))) }
        try expect(best > 3, "a zoom-in must produce a measurable radial blur (\(best) px)")
        for time in [3.1, 3.2, 3.3] {
            let a = widthExtent(crops(at: time, fps: 60)), b = widthExtent(crops(at: time, fps: 30))
            try expect(abs(a - b) <= 0.15 * max(a, b) + 1, "zoom blur extent at \(time) s: 60 fps \(a), 30 fps \(b)")
        }
        // Stationary, amount 0 and sub-pixel motion are the single plain crop.
        let still = crops(at: 0.5, fps: 60)
        try expect(still.count == 1 && still[0] == timeline.frame(at: 0.5).cropRect(width: width, height: height), "stationary frame has one plain crop")
        try expect(crops(at: 3.2, fps: 60, amount: 0).count == 1, "amount 0 is unblurred")
        try expect(ScreenMotionBlur(amount: 1, fps: 60).crops(now: now, before: now.offsetBy(dx: -0.4, dy: 0), outputScale: 1).count == 1,
                   "sub-pixel travel is unblurred")
        // Sample caps and scaling with output pixels.
        let fastBefore = now.offsetBy(dx: -1000, dy: 0)
        try expect(ScreenMotionBlur(amount: 1, fps: 60).crops(now: now, before: fastBefore, outputScale: 1).count == 16, "export cap is 16")
        try expect(ScreenMotionBlur.preview().crops(now: now, before: fastBefore, outputScale: 1).count == 6, "preview cap is 6")
        let moderate = ScreenMotionBlur(amount: 1, fps: 60)
        let small = moderate.crops(now: now, before: now.offsetBy(dx: -12, dy: 0), outputScale: 1).count
        try expect(small == 3, "12 px of travel at 4 px spans is 3 samples (got \(small))")
        try expect(moderate.crops(now: now, before: now.offsetBy(dx: -12, dy: 0), outputScale: 2).count == 6, "samples scale with output pixels")
        // Equal-weight midpoints stay inside the trail and the last one is just before `now`.
        let slices = moderate.crops(now: now, before: now.offsetBy(dx: -16, dy: 0), outputScale: 1)
        try expect(slices.count == 4 && abs(slices.last!.minX - (now.minX - 2)) < 1e-9, "midpoint sampling of equal slices")
        // Scale changes are radial: the crop size interpolates as well.
        let zoomed = ScreenMotionBlur(amount: 1, fps: 60).crops(now: CGRect(x: 480, y: 270, width: 960, height: 540),
                                                                  before: CGRect(x: 400, y: 225, width: 1120, height: 630), outputScale: 1)
        try expect(zoomed.count > 1 && zoomed[0].width > zoomed.last!.width, "zoom blur interpolates the crop size")
        var disabled = ScreenMotionBlur(amount: 1, fps: 60)
        disabled.amount = .nan
        try expect(disabled.strength == 0 && disabled.crops(now: now, before: fastBefore, outputScale: 1).count == 1, "invalid amount is no blur")
    }

    /// Edge travel of the crop's width change over the whole trail (zoom is radial).
    private static func widthExtent(_ crops: [CGRect]) -> Double {
        guard crops.count > 1 else { return 0 }
        return Double(abs(crops[crops.count - 1].width - crops[0].width)) * Double(crops.count) / Double(crops.count - 1)
    }

    private static func testExtremeValidSpringStability() throws {
        var configuration = ZoomConfiguration()
        configuration.stiffness = 1000
        configuration.damping = 200
        configuration.mass = 0.1
        configuration.framesPerSecond = 100
        try configuration.validate()
        let timeline = ZoomTimeline(session: makeSession(duration: 8, events: [
            event(1, 0.75, 0.25, .down)
        ]), configuration: configuration)
        for time in stride(from: 0.0, through: 8.0, by: 0.01) {
            let frame = timeline.frame(at: time)
            try expect(frame.scale.isFinite && frame.centerX.isFinite && frame.centerY.isFinite,
                       "valid spring tuning must remain finite")
        }
        try expect(timeline.frame(at: 3).scale > 1.99, "extreme damping must still reach its target")
    }

    private static func testExactTimingAndFinalSecond() throws {
        let session = makeSession(duration: 8, events: [
            event(1, 0.3, 0.4, .down),
            event(7.0, 0.7, 0.6, .down) // final second is excluded
        ])
        let timeline = ZoomTimeline(session: session)
        try expect(timeline.ranges.count == 1, "final-second click should not create a range")
        try expectClose(timeline.ranges[0].start, 0.7, "click starts 300 ms early")
        try expectClose(timeline.ranges[0].end, 3.5, "click range ends 2.5 s after click")
    }

    private static func testInclusiveMergeGap() throws {
        let inclusive = ZoomTimeline(session: makeSession(duration: 14, events: [
            event(2.0, 0.3, 0.4, .down),
            event(7.3, 0.7, 0.6, .down) // second range starts at 7.0; exactly 2.5 s after first ends
        ]))
        try expect(inclusive.ranges.count == 1, "ranges separated by exactly mergeGap should merge")
        try expectClose(inclusive.ranges[0].start, 1.7, "merged range retains first start")
        try expectClose(inclusive.ranges[0].end, 9.8, "merged range reaches second end")

        let above = ZoomTimeline(session: makeSession(duration: 14, events: [
            event(2.0, 0.3, 0.4, .down),
            event(7.301, 0.7, 0.6, .down)
        ]))
        try expect(above.ranges.count == 2, "gap just above mergeGap should remain separate")
    }

    private static func testShortAndNoClickIdentity() throws {
        let zero = ZoomTimeline(session: makeSession(duration: 0, events: []))
        try expectClose(zero.frame(at: 0).scale, 1, "zero-duration frame should be safe and unzoomed")
        try expectClose(zero.frame(at: 1).centerX, 0.5, "zero-duration query clamps safely")

        let short = ZoomTimeline(session: makeSession(duration: 0.11, events: []))
        for time in stride(from: 0.0, through: 0.2, by: 0.01) {
            let frame = short.frame(at: time)
            try expectClose(frame.scale, 1, "no-click timeline remains at identity scale")
            try expectClose(frame.centerX, 0.5, "no-click timeline remains centered")
            try expectClose(frame.centerY, 0.5, "no-click timeline remains centered")
        }
    }

    private static func testRejectsInvalidEvents() throws {
        let session = makeSession(duration: 8, events: [
            event(1, 0.5, 0.5, .move), // pointer motion alone does not trigger a zoom
            event(2, -0.01, 0.5, .down),
            event(3, 1.01, 0.5, .up),
            event(4, 0.5, .infinity, .down),
            event(8.1, 0.5, 0.5, .down)
        ])
        let timeline = ZoomTimeline(session: session)
        try expect(timeline.ranges.isEmpty, "out-of-bounds, non-finite, late and move-only events are rejected")
    }

    private static func testSpatialGroupsAndDwellCentering() throws {
        let dwell = ZoomTimeline(session: makeSession(duration: 8, events: [
            event(1, 0.35, 0.45, .down),
            event(2, 0.55, 0.65, .move),
            event(3, 0.55, 0.65, .move)
        ]))
        let settledDwell = dwell.frame(at: 3.3)
        // The original behavior gives the last group a 100 ms fallback dwell when
        // it has no next-group finish time; this expectation preserves that rule.
        try expect(abs(settledDwell.centerX - 0.368) < 0.04,
                   "target should weight pointer positions by dwell time (got \(settledDwell.centerX))")
        try expect(abs(settledDwell.centerY - 0.468) < 0.05,
                   "vertical target should weight pointer positions by dwell time (got \(settledDwell.centerY))")

        let spatial = ZoomTimeline(session: makeSession(duration: 8, events: [
            event(1, 0.2, 0.3, .down),
            event(2, 0.3, 0.3, .move),
            event(2.4, 0.8, 0.7, .move)
        ]))
        let laterGroup = spatial.frame(at: 3.3)
        try expect(laterGroup.centerX > 0.68 && laterGroup.centerY > 0.58,
                   "large pointer displacement should start a spatial group (center \(laterGroup.centerX), \(laterGroup.centerY))")
    }

    private static func testRandomSeekDeterminism() throws {
        let timeline = ZoomTimeline(session: makeSession(duration: 9, events: [
            event(1, 0.2, 0.4, .down), event(2.1, 0.7, 0.6, .move),
            event(4, 0.8, 0.3, .up), event(6, 0.3, 0.7, .down)
        ]))
        var seed: UInt64 = 0x1234_5678_9abc_def0
        var times: [Double] = []
        for _ in 0..<500 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            times.append(Double(seed % 1_200_000) / 100_000)
        }
        let firstPass = times.map(timeline.frame(at:))
        let secondPass = times.reversed().map(timeline.frame(at:)).reversed()
        try expect(firstPass == Array(secondPass), "random-access seeks should be independent of query order")
        let rebuilt = ZoomTimeline(session: makeSession(duration: 9, events: [
            event(1, 0.2, 0.4, .down), event(2.1, 0.7, 0.6, .move),
            event(4, 0.8, 0.3, .up), event(6, 0.3, 0.7, .down)
        ]))
        try expect(firstPass == times.map(rebuilt.frame(at:)), "independent precomputation produces identical arbitrary seeks")
    }

    private static func testSmoothBoundedTransitionsAndReturn() throws {
        let timeline = ZoomTimeline(session: makeSession(duration: 9, events: [
            event(1, 0.03, 0.95, .down), event(4, 0.97, 0.05, .down)
        ]))
        var previous = timeline.frame(at: 0)
        var peakScale = previous.scale
        var peakX = previous.centerX
        var maxScaleStep = 0.0
        var maxCenterStep = 0.0
        for index in 1...540 {
            let frame = timeline.frame(at: Double(index) / 60)
            peakScale = max(peakScale, frame.scale)
            peakX = max(peakX, frame.centerX)
            maxScaleStep = max(maxScaleStep, abs(frame.scale - previous.scale))
            maxCenterStep = max(maxCenterStep, abs(frame.centerX - previous.centerX))
            let margin = 0.5 / frame.scale
            try expect(frame.scale >= 1 && frame.scale <= 2, "scale stays within configured bounds")
            try expect(frame.centerX >= margin - 1e-9 && frame.centerX <= 1 - margin + 1e-9,
                       "horizontal center stays inside visible crop bounds")
            try expect(frame.centerY >= margin - 1e-9 && frame.centerY <= 1 - margin + 1e-9,
                       "vertical center stays inside visible crop bounds")
            previous = frame
        }
        try expect(peakScale > 1.5, "clicks should cause a zoom transition")
        try expect(maxScaleStep < 0.2 && maxCenterStep < 0.2,
                   "spring transitions should move smoothly between adjacent frames")
        let duringSecond = timeline.frame(at: 5)
        let afterEnd = timeline.frame(at: 8.8)
        try expect(afterEnd.scale < duringSecond.scale, "zoom should return toward identity after the last range")
        try expect(abs(afterEnd.scale - 1) < 0.02, "zoom should settle near identity by the end")
        try expect(peakX > 0.5, "extreme pointer positions should move the crop center")
    }

    private static func testInvalidPersistedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddeo-zoom-config-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var invalid = ZoomConfiguration()
        invalid.scale = 9
        let data = try JSONEncoder().encode(invalid)
        try data.write(to: directory.appendingPathComponent("zoom-config.json"))
        do {
            _ = try ZoomConfiguration.load(in: directory)
            throw VerificationError.failed("invalid persisted configuration should throw")
        } catch ZoomError.invalidConfiguration {
            // Expected validation error.
        }
    }

    private static func makeSession(duration: Double, events: [CursorEvent]) -> RecordingSession {
        RecordingSession(
            id: UUID(), createdAt: Date(), displayID: 1, width: 1920, height: 1080,
            duration: duration, events: events, droppedFrames: 0, eventCaptureAvailable: true
        )
    }

    private static func event(_ time: Double, _ x: Double, _ y: Double, _ kind: CursorEvent.Kind) -> CursorEvent {
        CursorEvent(time: time, x: x, y: y, kind: kind)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }

    private static func expectClose(_ actual: Double, _ expected: Double, _ message: String) throws {
        guard abs(actual - expected) < 0.000_001 else {
            throw VerificationError.failed("\(message): expected \(expected), got \(actual)")
        }
    }
}

private enum VerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
