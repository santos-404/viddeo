import CoreGraphics
import CoreImage
import Foundation

@main
struct VerifyCursor {
    static func main() throws {
        let check = Checker()
        try testConfigurationDefaults(check)
        try testConfigurationPersistence(check)
        try testSpringClosedForm(check)
        try testSmoothingDisabled(check)
        try testSeekDeterminism(check)
        try testPressScale(check)
        try testVisibilityBeforeFirstEvent(check)
        try testTypingHide(check)
        try testIdleHide(check)
        try testVelocityTilt(check)
        try testDirectionalRotation(check)
        try testInvalidEventFiltering(check)
        try testRenderer(check)
        try testShakeRemoval(check)
        try testLegacyShakeKey(check)
        try testLoopWindow(check)
        try testStopMovementSpring(check)
        try testTrailStrength(check)
        try testTrailRendering(check)
        print("Cursor verified: \(check.count) checks")
    }

    // MARK: Configuration

    private static func testConfigurationDefaults(_ check: Checker) throws {
        let c = CursorConfiguration()
        try check(c.hide == false, "hide defaults off")
        try check(c.size == 48 && c.effectiveSize == 48, "size 48")
        var small = c
        small.size = 3
        try check(small.effectiveSize == 48, "size <= 12 is treated as x16")
        try check(c.smoothing && c.stiffness == 125 && c.damping == 12 && c.mass == 1.5,
                  "mouse spring 125/12/1.5")
        try check(c.pressedScale == 0.9, "pressed scale 0.9")
        try check(c.rotationMode == .velocity && c.rotateOnXMovementRatio == 0.5, "velocity mode, x ratio 0.5")
        try check(c.velocitySmoothingMs == 120 && c.tiltDegPerVelocity == 12 && c.maxTiltDeg == 20 &&
                  c.startupCalmMs == 500 && c.entryTeleportSpeedPxPerMs == 15, "velocity tilt params")
        try check(c.tiltStiffness == 120 && c.tiltDamping == 8 && c.tiltMass == 1, "tilt spring 120/8/1")
        try check(c.alignRatePerPx == 0.00005 && c.speedSaturationPxPerMs == 3 && c.angularDampingMs == 100 &&
                  c.maxTurnRateDegPerMs == 0.4 && c.maxFromNeutralDeg == 135 && c.minTravelPx == 4 &&
                  c.neutralPullHeadingDeg == -112.5, "directional params")
        try check(c.directionalStiffness == 320 && c.directionalDamping == 28 && c.directionalMass == 1,
                  "directional spring 320/28/1")
        try check(c.hideWhileTypingKeyCount == 3 && c.typingWindowMs == 1800, "typing 3 keys / 1800 ms")
        try check(c.fadeOutMs == 150 && c.fadeInMs == 150, "fade 150/150 ms")
        try check(c.hideNotMovingAfterMs == nil && c.hideBlurRadius == 10, "idle hide off, blur 10")
        try check(c.removeShakeThresholdPx == 500 && c.motionBlurAmount == 1, "shake 500 px, motion blur 1")
        try check(c.loopPositionBeforeEndMs == nil && c.stopMovementInLastPartMs == 0, "loop off, stop movement 0")
        try check((try? c.validate()) != nil, "defaults validate")
    }

    private static func testConfigurationPersistence(_ check: Checker) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try check(try CursorConfiguration.load(in: directory) == CursorConfiguration(),
                  "missing file loads defaults")
        var custom = CursorConfiguration()
        custom.rotationMode = .directional
        custom.size = 64
        custom.hideNotMovingAfterMs = 2500
        try custom.save(in: directory)
        try check(try CursorConfiguration.load(in: directory) == custom, "JSON roundtrip")
        let json = try String(contentsOf: directory.appendingPathComponent("cursor-config.json"), encoding: .utf8)
        try check(json.contains("\"rotationMode\" : \"directional\""), "mode persists as a string")

        var invalid = [CursorConfiguration](repeating: .init(), count: 12)
        invalid[0].size = -1
        invalid[1].stiffness = .nan
        invalid[2].hideWhileTypingKeyCount = 0
        invalid[3].mass = 0
        invalid[4].hideNotMovingAfterMs = -5
        invalid[5].maxTiltDeg = 200
        invalid[6].motionBlurAmount = 1.5
        invalid[7].removeShakeThresholdPx = -1
        invalid[8].loopPositionBeforeEndMs = 0
        invalid[9].stopMovementInLastPartMs = 70_000
        invalid[10].motionBlurAmount = -0.1
        invalid[11].removeShakeThresholdPx = 200_000
        try check(invalid.allSatisfy { (try? $0.validate()) == nil }, "invalid values are rejected")
        var bad = CursorConfiguration()
        bad.damping = -3
        try bad.save(in: directory)
        try check((try? CursorConfiguration.load(in: directory)) == nil, "load rejects invalid persisted values")
        try Data("{".utf8).write(to: directory.appendingPathComponent("cursor-config.json"))
        try check((try? CursorConfiguration.load(in: directory)) == nil, "load rejects malformed JSON")
    }

    // MARK: Position spring

    private static func testSpringClosedForm(_ check: Checker) throws {
        let timeline = CursorTimeline(events: [move(0.5, 0.3, 0.5), move(2.0, 0.5, 0.5)],
                                      keystrokes: [], duration: 6)
        let k = 125.0, c = 12.0, m = 1.5
        let omega = sqrt(k / m), zeta = c / (2 * sqrt(k * m))
        let omegaD = omega * sqrt(1 - zeta * zeta)
        func closed(_ t: Double) -> Double {
            0.5 - 0.2 * exp(-zeta * omega * t) * (cos(omegaD * t) + zeta * omega / omegaD * sin(omegaD * t))
        }
        try check(zeta < 1, "observed mouse spring is under-damped")
        try check(timeline.state(at: 1.9).x == 0.3, "held position stays exactly at the first target")
        var worst = 0.0
        for t in [0.05, 0.1, 0.2, 0.35, 0.5, 0.8, 1.2] {
            worst = max(worst, abs(timeline.state(at: 2 + t).x - closed(t)))
        }
        try check(worst < 0.002, "spring matches 125/12/1.5 closed form (max error \(worst))")
        var peak = 0.0
        for step in 0...3000 { peak = max(peak, timeline.state(at: 2 + Double(step) / 1000).x) }
        let overshoot = (peak - 0.5) / 0.2
        let expected = exp(-zeta * .pi / sqrt(1 - zeta * zeta))
        try check(abs(overshoot - expected) < 0.01, "overshoot \(overshoot) matches closed form \(expected)")
        try check(overshoot < 0.25, "overshoot stays bounded")
        try check(abs(timeline.state(at: 5).x - 0.5) < 0.0001, "position converges to held target")
        try check(timeline.state(at: 5).y == 0.5, "unchanged axis stays put")
    }

    private static func testSmoothingDisabled(_ check: Checker) throws {
        var config = CursorConfiguration()
        config.smoothing = false
        let timeline = CursorTimeline(events: [move(0.5, 0.3, 0.4), move(2.0, 0.7, 0.6)],
                                      keystrokes: [], duration: 4, configuration: config)
        let state = timeline.state(at: 2.0)
        try check(state.x == 0.7 && state.y == 0.6, "disabled smoothing uses raw positions")
    }

    private static func testSeekDeterminism(_ check: Checker) throws {
        let events = (0..<200).map { (i: Int) -> CursorEvent in
            let phase = Double(i)
            let kind: CursorEvent.Kind = i % 37 == 5 ? .down : (i % 37 == 9 ? .up : .move)
            return CursorEvent(time: 0.3 + phase * 0.04, x: 0.5 + 0.35 * sin(phase * 0.13),
                               y: 0.5 + 0.3 * cos(phase * 0.07), kind: kind)
        }
        let keys = [5.0, 5.2, 5.4, 5.5].map { KeystrokeEvent(time: $0) }
        let a = CursorTimeline(events: events, keystrokes: keys, duration: 9)
        let b = CursorTimeline(events: events.reversed(), keystrokes: keys.reversed(), duration: 9)
        var generator = SplitMix(seed: 42)
        let times = (0..<500).map { _ in Double(generator.next() % 9_000_000) / 1_000_000 }
        let ordered = times.indices.sorted { times[$0] < times[$1] }
        var forward = [CursorState?](repeating: nil, count: times.count)
        for index in ordered { forward[index] = a.state(at: times[index]) }
        let shuffled = times.map { a.state(at: $0) }
        try check(times.indices.allSatisfy { forward[$0] == shuffled[$0] }, "out-of-order seeks match ordered seeks")
        try check(times.allSatisfy { a.state(at: $0) == b.state(at: $0) }, "input order does not matter")
        try check(a.state(at: .nan) == a.state(at: 0), "non-finite seek falls back to the first sample")
        try check(a.state(at: 100) == a.state(at: 9), "seeks clamp to the duration")
    }

    // MARK: Press, visibility, typing

    private static func testPressScale(_ check: Checker) throws {
        let timeline = CursorTimeline(events: [
            move(0.2, 0.5, 0.5), CursorEvent(time: 1, x: 0.5, y: 0.5, kind: .down),
            CursorEvent(time: 2, x: 0.5, y: 0.5, kind: .up)
        ], keystrokes: [], duration: 4)
        try check(timeline.state(at: 0.9).scale == 1, "scale 1 before the press")
        try check(abs(timeline.state(at: 1.6).scale - 0.9) < 0.001, "scale 0.9 while pressed")
        let pressing = stride(from: 1.0, through: 1.6, by: 0.005).map { timeline.state(at: $0).scale }
        try check(zip(pressing, pressing.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 } &&
                  pressing.allSatisfy { $0 >= 0.9 - 1e-6 }, "press eases down monotonically without undershoot")
        try check(abs(timeline.state(at: 2.6).scale - 1) < 0.001, "scale returns to 1 after release")
        try check(timeline.state(at: 1.05).scale < 1 && timeline.state(at: 1.05).scale > 0.9,
                  "press is eased, not instant")
    }

    private static func testVisibilityBeforeFirstEvent(_ check: Checker) throws {
        let timeline = CursorTimeline(events: [move(1.0, 0.4, 0.4)], keystrokes: [], duration: 3)
        try check(stride(from: 0.0, to: 1.0, by: 0.01).allSatisfy { timeline.state(at: $0).opacity == 0 },
                  "hidden before the first event")
        try check(timeline.state(at: 0.5).blurRadius == 10, "hidden cursor carries the hide blur")
        try check(timeline.state(at: 1.3).opacity == 1 && timeline.state(at: 1.3).blurRadius == 0,
                  "fully visible after fade-in")
        let none = CursorTimeline(events: [], keystrokes: [], duration: 2)
        try check(none.state(at: 1).opacity == 0, "no events: never visible")
        var config = CursorConfiguration()
        config.hide = true
        let hidden = CursorTimeline(events: [move(0, 0.5, 0.5)], keystrokes: [], duration: 2, configuration: config)
        try check(hidden.state(at: 1).opacity == 0, "hide setting hides the cursor")
    }

    private static func testTypingHide(_ check: Checker) throws {
        let pointer = [move(1.0, 0.5, 0.5)]
        let three = [2.0, 2.3, 2.6].map { KeystrokeEvent(time: $0) }
        let typing = CursorTimeline(events: pointer, keystrokes: three, duration: 6)
        try check(typing.state(at: 2.55).opacity == 1, "visible before the third key")
        try check(typing.state(at: 2.8).opacity == 0, "three keys within 1.8 s hide the cursor")
        try check(typing.state(at: 2.8).blurRadius == 10, "typing hide blurs at radius 10")
        let fadeOut = stride(from: 2.6, through: 2.8, by: 0.002).map { typing.state(at: $0).opacity }
        try check(zip(fadeOut, fadeOut.dropFirst()).allSatisfy { $1 <= $0 }, "fade-out is monotone")
        try check(typing.state(at: 3.7).opacity == 0, "stays hidden inside the typing window")
        try check(typing.state(at: 4.1).opacity == 1, "re-shows once the window no longer holds three keys")
        let fadeIn = stride(from: 3.8, through: 4.0, by: 0.002).map { typing.state(at: $0).opacity }
        try check(zip(fadeIn, fadeIn.dropFirst()).allSatisfy { $1 >= $0 }, "fade-in is monotone")

        let two = CursorTimeline(events: pointer, keystrokes: [2.0, 2.3].map { KeystrokeEvent(time: $0) }, duration: 6)
        try check(stride(from: 1.2, through: 5.0, by: 0.01).allSatisfy { two.state(at: $0).opacity == 1 },
                  "two keys do not hide")
        let spread = CursorTimeline(events: pointer, keystrokes: [2.0, 3.0, 3.9].map { KeystrokeEvent(time: $0) },
                                    duration: 6)
        try check(spread.state(at: 4.0).opacity == 1, "keys spread wider than 1.8 s do not hide")
        let moved = CursorTimeline(events: pointer + [move(2.7, 0.52, 0.5)], keystrokes: three, duration: 6)
        try check(moved.state(at: 2.68).opacity < 1, "fading while typing before the move")
        try check(moved.state(at: 3.0).opacity == 1, "a mouse event after the last key re-shows")
    }

    private static func testIdleHide(_ check: Checker) throws {
        let events = [move(1.0, 0.5, 0.5), move(5.0, 0.6, 0.5)]
        let plain = CursorTimeline(events: events, keystrokes: [], duration: 7)
        try check(plain.state(at: 3).opacity == 1, "idle hide is off by default")
        var config = CursorConfiguration()
        config.hideNotMovingAfterMs = 1000
        let idle = CursorTimeline(events: events, keystrokes: [], duration: 7, configuration: config)
        try check(idle.state(at: 1.5).opacity == 1, "visible near a mouse event")
        try check(idle.state(at: 3).opacity == 0, "hidden after the idle threshold")
        try check(idle.state(at: 4.5).opacity == 0, "idle hide only looks backward: hidden before the next event")
        try check(idle.state(at: 5.5).opacity == 1, "re-shown within the threshold after an event")
        try check(idle.state(at: 6.5).opacity == 0, "hidden again after the last event")
    }

    // MARK: Rotation

    private static func testVelocityTilt(_ check: Checker) throws {
        // 0.5 px/ms to the right on a 1920-wide source after the startup calm.
        let right = sweep(from: 0.2, speedPxPerMs: 0.5, start: 1, end: 3, width: 1920)
        let rightTimeline = CursorTimeline(events: right, keystrokes: [], duration: 4)
        let tilt = degrees(rightTimeline.state(at: 2.8))
        try check(tilt > 0, "moving right tilts clockwise (\(tilt))")
        try check(abs(tilt - 6) < 0.5, "steady tilt is 12 deg per px/ms (\(tilt))")
        try check(abs(degrees(rightTimeline.state(at: 3.9))) < 0.5, "tilt settles back when the pointer stops")
        let left = sweep(from: 0.8, speedPxPerMs: -0.5, start: 1, end: 3, width: 1920)
        try check(degrees(CursorTimeline(events: left, keystrokes: [], duration: 4).state(at: 2.8)) < -5,
                  "moving left tilts counter-clockwise")
        let fast = [move(0.2, 0.05, 0.5)] + sweep(from: 0.05, speedPxPerMs: 3, start: 1, end: 1.6, width: 1920)
        let fastTimeline = CursorTimeline(events: fast, keystrokes: [], duration: 3)
        let fastTilts = stride(from: 0.0, through: 3.0, by: 0.002).map { degrees(fastTimeline.state(at: $0)) }
        try check(fastTilts.allSatisfy { abs($0) <= 20 + 1e-9 }, "tilt clamps at maxTiltDeg")
        try check((fastTilts.max() ?? 0) > 19.9, "fast motion reaches the clamp")
        let calm = sweep(from: 0.05, speedPxPerMs: 3, start: 0.1, end: 0.55, width: 1920)
        let calmTimeline = CursorTimeline(events: calm, keystrokes: [], duration: 2)
        try check(stride(from: 0.0, through: 0.6, by: 0.01).allSatisfy { calmTimeline.state(at: $0).rotationRadians == 0 },
                  "no tilt during the 500 ms startup calm")
        let teleport = CursorTimeline(events: [move(0.5, 0.1, 0.5), move(1.5, 0.6, 0.5)], keystrokes: [], duration: 3)
        try check(stride(from: 1.0, through: 3.0, by: 0.01).allSatisfy { abs(degrees(teleport.state(at: $0))) < 1e-9 },
                  "teleport jumps faster than 15 px/ms do not tilt")
    }

    private static func testDirectionalRotation(_ check: Checker) throws {
        var config = CursorConfiguration()
        config.rotationMode = .directional
        let side = 4000.0
        let right = sweep(from: 0.05, speedPxPerMs: 3, start: 1, end: 2.2, width: side)
        let rightTimeline = CursorTimeline(events: right, keystrokes: [], duration: 3, configuration: config,
                                           sourceWidth: side, sourceHeight: side)
        let heading = degrees(rightTimeline.state(at: 2.2))
        try check(abs(heading - 112.5) < 5, "moving right turns the arrow toward its heading (\(heading))")
        var down = right
        let downStart = right.last?.time ?? 2.2
        for i in 1...90 {
            down.append(move(downStart + Double(i) / 60, right.last?.x ?? 0.5,
                             0.05 + Double(i) * 3 * 1000 / 60 / side))
        }
        let downTimeline = CursorTimeline(events: down, keystrokes: [], duration: 7, configuration: config,
                                          sourceWidth: side, sourceHeight: side)
        let angles = stride(from: 0.0, through: 7.0, by: 0.002).map { degrees(downTimeline.state(at: $0)) }
        try check(angles.allSatisfy { abs($0) <= 135 + 1e-9 }, "rotation clamps at maxFromNeutralDeg")
        try check((angles.max() ?? 0) > 134, "downward heading saturates at the clamp")
        let settling = stride(from: 4.0, through: 7.0, by: 0.01).map { degrees(downTimeline.state(at: $0)) }
        try check(zip(settling, settling.dropFirst()).allSatisfy { $1 <= $0 } && (settling.last ?? 99) < 3,
                  "idle pulls back toward neutral")
        let tiny = CursorTimeline(events: [move(0.2, 0.5, 0.5), move(1.5, 0.5 + 3 / 1920, 0.5)],
                                  keystrokes: [], duration: 3, configuration: config)
        try check(stride(from: 0.0, through: 3.0, by: 0.01).allSatisfy { tiny.state(at: $0).rotationRadians == 0 },
                  "moves below minTravelPx are ignored")
        let nudge = CursorTimeline(events: [move(0.2, 0.5, 0.5), move(1.5, 0.5 + 50 / 1920, 0.5)],
                                   keystrokes: [], duration: 3, configuration: config)
        try check(abs(degrees(nudge.state(at: 1.6))) > 0.5, "a move above minTravelPx rotates")
    }

    // MARK: Filtering

    private static func testInvalidEventFiltering(_ check: Checker) throws {
        let valid = [move(0.5, 0.3, 0.3), CursorEvent(time: 1, x: 0.6, y: 0.4, kind: .down),
                     CursorEvent(time: 1.5, x: 0.6, y: 0.4, kind: .up)]
        let junk = [move(.nan, 0.5, 0.5), move(.infinity, 0.5, 0.5), move(-1, 0.5, 0.5), move(9, 0.5, 0.5),
                    move(0.7, 1.5, 0.5), move(0.8, 0.5, -0.1), move(0.9, .nan, 0.5),
                    CursorEvent(time: 1.2, x: 0.5, y: .infinity, kind: .up)]
        let keys = [KeystrokeEvent(time: .nan), KeystrokeEvent(time: -2), KeystrokeEvent(time: 50)]
        let clean = CursorTimeline(events: valid, keystrokes: [], duration: 3)
        let dirty = CursorTimeline(events: junk + valid, keystrokes: keys, duration: 3)
        try check(stride(from: 0.0, through: 3.0, by: 0.01).allSatisfy { clean.state(at: $0) == dirty.state(at: $0) },
                  "invalid events and keystrokes are ignored")
        let allJunk = CursorTimeline(events: junk, keystrokes: [], duration: 3)
        try check(allJunk.state(at: 2).opacity == 0, "only-invalid input never shows")
        let broken = CursorTimeline(events: valid, keystrokes: [], duration: .nan)
        try check(broken.state(at: 0).opacity == 0, "non-finite duration is safe")
        var badConfig = CursorConfiguration()
        badConfig.stiffness = -1
        let fallback = CursorTimeline(events: valid, keystrokes: [], duration: 3, configuration: badConfig)
        try check(fallback.state(at: 1.2) == clean.state(at: 1.2), "invalid configuration falls back to defaults")
    }

    // MARK: Renderer

    private static func testRenderer(_ check: Checker) throws {
        let width = 1280, height = 720
        let renderer = CursorRenderer(outputSize: CGSize(width: width, height: height))
        let base = CursorState(x: 640.5 / 1280, y: 360.5 / 720, scale: 1, rotationRadians: 0,
                               opacity: 1, blurRadius: 0)
        guard let image = renderer.image(for: base) else { throw Failure("visible cursor produced no image") }
        try check(image.extent == CGRect(x: 0, y: 0, width: width, height: height), "overlay matches output size")
        let bytes = try render(image, width: width, height: height)
        let tip = pixel(bytes, 640, 360, width)
        try check(tip.a > 0.6, "tip pixel is opaque at the hotspot (alpha \(tip.a))")
        let tipLuma = (tip.r + tip.g + tip.b) / 3 / max(tip.a, 0.001)
        try check(tipLuma < 0.45 || tipLuma > 0.8, "tip pixel is outline or fill color (\(tipLuma))")
        let inside = pixel(bytes, 643, 370, width)
        try check(inside.a > 0.95 && inside.r > 0.9 && inside.g > 0.9 && inside.b > 0.9, "body is white fill")
        let outside = pixel(bytes, 630, 350, width)
        try check(outside.a == 0, "up-left of the tip stays transparent")
        let box = boundingBox(bytes, width: width, height: height)
        try check(abs(box.minX - 640) <= 2 && abs(box.minY - 360) <= 2, "arrow tip is the top-left of the shape")
        // 21.4 grid units of arrow plus the outline on both ends, on a 24-unit grid.
        let expectedHeight = 48.0 / 1080 * 720 * (21.4 + 2 * 1.25) / 24
        try check(abs(box.height - expectedHeight) < 2, "arrow height follows size/1080 x output height")

        let large = CursorRenderer(configuration: sized(96), outputSize: CGSize(width: width, height: height))
        let full = boundingBox(try render(large.image(for: base), width: width, height: height), width: width, height: height)
        var pressedState = base
        pressedState.scale = 0.9
        let pressed = boundingBox(try render(large.image(for: pressedState), width: width, height: height),
                                  width: width, height: height)
        try check(abs(pressed.width / full.width - 0.9) < 0.03 && abs(pressed.height / full.height - 0.9) < 0.03,
                  "scale 0.9 shrinks the drawn box by about 10 %")

        var rotatedState = base
        rotatedState.rotationRadians = 0.5
        let rotatedBytes = try render(renderer.image(for: rotatedState), width: width, height: height)
        let rotated = boundingBox(rotatedBytes, width: width, height: height)
        try check(rotated.minX < box.minX - 3, "clockwise rotation swings the body left of the tip")
        try check(pixel(rotatedBytes, 640, 360, width).a > 0.6, "rotation pivots about the hotspot")

        var hidden = base
        hidden.opacity = 0
        try check(renderer.image(for: hidden) == nil, "opacity 0 returns nil")
        var faded = base
        faded.opacity = 0.5
        let fadedTip = pixel(try render(renderer.image(for: faded), width: width, height: height), 643, 370, width)
        try check(abs(fadedTip.a - 0.5) < 0.02, "opacity scales alpha")
        var blurred = base
        blurred.blurRadius = 10
        let blurredBytes = try render(renderer.image(for: blurred), width: width, height: height)
        let blurredBox = boundingBox(blurredBytes, width: width, height: height, threshold: 0.02)
        let sharpBox = boundingBox(bytes, width: width, height: height, threshold: 0.02)
        try check(blurredBox.width > sharpBox.width + 4, "blur radius spreads the cursor")
        try check(try render(renderer.image(for: base), width: width, height: height) == bytes,
                  "identical bytes on repeat")
        var offscreen = base
        offscreen.x = 0.999
        offscreen.y = 0.999
        try check(renderer.image(for: offscreen)?.extent == image.extent, "edge cursor is cropped to the output")
    }

    // MARK: Shake, legacy key, loop, stop

    private static func testShakeRemoval(_ check: Checker) throws {
        let w = 1920.0, h = 1080.0
        func filter(_ events: [CursorEvent], _ threshold: Double = 500) -> [CursorEvent] {
            CursorEventFilter.removingShake(events, thresholdPx: threshold, sourceWidth: w, sourceHeight: h)
        }
        let spike = [move(1, 0.1, 0.1), move(2, 0.9, 0.9), move(3, 0.1, 0.1), move(4, 0.11, 0.1)]
        try check(filter(spike).map(\.time) == [1, 3, 4], "an isolated spike (2400 px away from both neighbours) is dropped")
        try check(filter(spike, 0) == spike, "threshold 0 disables")
        try check(filter(spike, 3000) == spike, "spike below the threshold is kept")
        let step = [move(1, 0.1, 0.5), move(2, 0.1 + 400 / w, 0.5), move(3, 0.1 + 800 / w, 0.5), move(4, 0.1 + 1200 / w, 0.5)]
        try check(filter(step) == step, "400 px moves are kept")
        let near = [move(1, 0.2, 0.5), move(2, 0.2 + 499 / w, 0.5), move(3, 0.2 + 998 / w, 0.5)]
        try check(filter(near) == near, "499 px steps are not far")
        let far = [move(1, 0.2, 0.5), move(2, 0.2 + 501 / w, 0.5), move(3, 0.2 + 1002 / w, 0.5)]
        try check(filter(far).map(\.time) == [2, 3], "501 px steps are far from both next events")
        let manhattanOnly = [move(1, 0.2, 0.2), move(2, 0.2 + 300 / w, 0.2 + 300 / h), move(3, 0.2 + 300 / w, 0.2 + 300 / h)]
        try check(filter(manhattanOnly).map(\.time) == [2, 3], "300+300 px counts as 600 (Manhattan), not 424")
        let pair = [move(1, 0.1, 0.1), CursorEvent(time: 2, x: 0.9, y: 0.9, kind: .down), move(3, 0.1, 0.1),
                    CursorEvent(time: 4, x: 0.1, y: 0.1, kind: .up), move(5, 0.1, 0.1), CursorEvent(time: 6, x: 0.1, y: 0.1, kind: .up)]
        try check(filter(pair).map(\.time) == [1, 3, 5, 6], "a dropped down also drops the next up, only that one")
        let upSpike = [move(1, 0.1, 0.1), CursorEvent(time: 2, x: 0.9, y: 0.9, kind: .up), move(3, 0.1, 0.1), move(4, 0.1, 0.1)]
        try check(filter(upSpike).map(\.time) == [1, 3, 4], "a dropped up does not start pairing")
        let tail = [move(1, 0.1, 0.1), move(2, 0.1, 0.1), move(3, 0.9, 0.9)]
        try check(filter(tail) == tail, "the last two events are never dropped")
        try check(filter([]) == [] && filter([move(1, 0.5, 0.5)]).count == 1, "short inputs pass")
        let timeline = CursorTimeline(events: spike, keystrokes: [], duration: 6, configuration: sized(48))
        let peak = stride(from: 0.0, through: 6.0, by: 0.01).map { timeline.state(at: $0).x }.max() ?? 1
        try check(peak < 0.2, "a filtered spike never moves the cursor (peak \(peak))")
        var off = CursorConfiguration()
        off.removeShakeThresholdPx = 0
        let raw = CursorTimeline(events: spike, keystrokes: [], duration: 6, configuration: off)
        try check((stride(from: 0.0, through: 6.0, by: 0.01).map { raw.state(at: $0).x }.max() ?? 0) > 0.3,
                  "threshold 0 lets the spike through")
    }

    private static func testLegacyShakeKey(_ check: Checker) throws {
        let encoder = JSONEncoder()
        func decode(_ edit: (inout [String: Any]) -> Void) throws -> CursorConfiguration {
            var object = try JSONSerialization.jsonObject(with: encoder.encode(CursorConfiguration())) as? [String: Any] ?? [:]
            edit(&object)
            return try JSONDecoder().decode(CursorConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let old = try decode {
            $0["removeShakeThresholdPx"] = nil
            $0["loopPositionBeforeEndMs"] = nil
            $0["stopMovementInLastPartMs"] = nil
            $0["removeShakeThresholdMs"] = 250.0
        }
        try check(old.removeShakeThresholdPx == 250, "old removeShakeThresholdMs key decodes into the pixel field")
        try check(old.loopPositionBeforeEndMs == nil && old.stopMovementInLastPartMs == 0, "new keys default when absent")
        let both = try decode { $0["removeShakeThresholdMs"] = 250.0; $0["removeShakeThresholdPx"] = 700.0 }
        try check(both.removeShakeThresholdPx == 700, "the new key wins over the old one")
        let empty = try JSONDecoder().decode(CursorConfiguration.self, from: Data("{}".utf8))
        try check(empty == CursorConfiguration(), "an empty object decodes to defaults")
        var custom = CursorConfiguration()
        custom.loopPositionBeforeEndMs = 1500
        custom.stopMovementInLastPartMs = 800
        custom.removeShakeThresholdPx = 300
        custom.motionBlurAmount = 0.4
        try check(try JSONDecoder().decode(CursorConfiguration.self, from: encoder.encode(custom)) == custom,
                  "new fields roundtrip")
        let json = String(decoding: try encoder.encode(custom), as: UTF8.self)
        try check(!json.contains("removeShakeThresholdMs") && json.contains("removeShakeThresholdPx"), "only the new key is written")
    }

    private static func testLoopWindow(_ check: Checker) throws {
        let events = [move(0.5, 0.2, 0.2), move(2, 0.3, 0.3), move(5, 0.35, 0.35)]
        let window = CursorEventFilter.loopWindow(events, duration: 6, loopMs: 2000)
        try check(window.map(\.time) == [0, 2, 2.001], "window drops later events, re-times the first, appends the return")
        try check(window.last.map { $0.x == 0.2 && $0.y == 0.2 && $0.kind == .move } == true, "return event copies the first position")
        try check(CursorEventFilter.loopWindow(events, duration: 6, loopMs: nil) == events, "loop off leaves events alone")
        let late = CursorEventFilter.loopWindow([move(5, 0.3, 0.3)], duration: 6, loopMs: 5500)
        try check(late.map(\.time) == [0, 0.001], "no event in the window: the first event is used")
        var config = CursorConfiguration()
        config.loopPositionBeforeEndMs = 2000
        let looped = CursorTimeline(events: events, keystrokes: [], duration: 6, configuration: config)
        let startX = looped.state(at: 0).x
        try check(abs(startX - 0.2) < 1e-9 && looped.state(at: 0.3).opacity == 1, "cursor is at its start position from frame 0")
        try check(abs(looped.state(at: 6).x - 0.2) < 0.5 / 1920 && abs(looped.state(at: 6).y - 0.2) < 0.5 / 1080,
                  "cursor is back within 0.5 px of the start at the end")
        let open = CursorTimeline(events: events, keystrokes: [], duration: 6)
        try check(abs(open.state(at: 6).x - 0.35) < 0.001, "without a loop window the last event holds")
        try check(open.state(at: 0.2).opacity == 0, "without a loop window the cursor still waits for its first event")
    }

    private static func testStopMovementSpring(_ check: Checker) throws {
        let base = [move(0.5, 0.3, 0.5), move(3.0, 0.5, 0.5)]
        let click = base + [CursorEvent(time: 3.1, x: 0.5, y: 0.5, kind: .down), CursorEvent(time: 3.6, x: 0.5, y: 0.5, kind: .up)]
        var stop = CursorConfiguration()
        stop.stopMovementInLastPartMs = 3000   // stopTime = 6 - 3 = 3 s
        let plain = CursorTimeline(events: click, keystrokes: [], duration: 6)
        let stopped = CursorTimeline(events: click, keystrokes: [], duration: 6, configuration: stop)
        let times = stride(from: 3.0, through: 6.0, by: 0.01)
        try check(stride(from: 0.0, to: 3.0, by: 0.01).allSatisfy { plain.state(at: $0).x == stopped.state(at: $0).x },
                  "nothing changes before duration - N")
        try check((times.map { plain.state(at: $0).x }.max() ?? 0) > 0.52, "configured spring overshoots (under-damped)")
        try check((times.map { stopped.state(at: $0).x }.max() ?? 1) <= 0.5 + 1e-4, "click spring after the stop time does not overshoot")
        let quiet = CursorTimeline(events: base, keystrokes: [], duration: 6, configuration: stop)
        let quietPlain = CursorTimeline(events: base, keystrokes: [], duration: 6)
        try check(times.allSatisfy { quiet.state(at: $0).x == quietPlain.state(at: $0).x },
                  "no click within 175 ms of the stop time keeps the configured spring")
        let drag = [move(0.5, 0.3, 0.5), CursorEvent(time: 2, x: 0.3, y: 0.5, kind: .down), move(3.0, 0.5, 0.5)]
        let dragging = CursorTimeline(events: drag, keystrokes: [], duration: 6, configuration: stop)
        try check((times.map { dragging.state(at: $0).x }.max() ?? 1) <= 0.5 + 1e-4, "a drag in progress at the stop time uses the snap spring")
        try check(CursorTimeline(events: click, keystrokes: [], duration: 6, configuration: CursorConfiguration())
                    .state(at: 4) == plain.state(at: 4), "0 changes nothing")
    }

    // MARK: Motion blur trail

    private static func testTrailStrength(_ check: Checker) throws {
        let events = sweep(from: 0.1, speedPxPerMs: 0.2, start: 0.2, end: 5, width: 1920)
        let timeline = CursorTimeline(events: events, keystrokes: [], duration: 6)
        func length(_ timeline: CursorTimeline, fps: Double, at time: Double = 4) -> Double {
            let trail = timeline.trail(at: time, fps: fps)
            return (trail.now.x - trail.start.x) * 1920
        }
        try check(timeline.trail(at: 4, fps: 30).strength == 0.5 && timeline.trail(at: 4, fps: 60).strength == 1 &&
                  timeline.trail(at: 4, fps: 120).strength == 2, "strength = amount x fps/60")
        // 0.2 px/ms = 200 px/s: a 1/60 s shutter is 3.33 px at any fps.
        let shutter = 200.0 / 60
        for fps in [24.0, 30, 60, 120] {
            let measured = length(timeline, fps: fps)
            try check(abs(measured - shutter) < 0.03 * shutter, "shutter is 1/60 s at \(Int(fps)) fps (\(measured) px vs \(shutter))")
        }
        var half = CursorConfiguration()
        half.motionBlurAmount = 0.5
        let halfTimeline = CursorTimeline(events: events, keystrokes: [], duration: 6, configuration: half)
        try check(abs(length(halfTimeline, fps: 30) - shutter / 2) < 0.03 * shutter &&
                  abs(length(halfTimeline, fps: 60) - shutter / 2) < 0.03 * shutter, "amount 0.5 halves the shutter at 30 and 60 fps")
        var zero = CursorConfiguration()
        zero.motionBlurAmount = 0
        let zeroTimeline = CursorTimeline(events: events, keystrokes: [], duration: 6, configuration: zero)
        let none = zeroTimeline.trail(at: 4, fps: 60)
        try check(none.strength == 0 && none.start == none.now, "amount 0 gives no trail")
        let still = CursorTimeline(events: events, keystrokes: [], duration: 14).trail(at: 13.9, fps: 60)
        try check(abs(still.now.x - still.start.x) < 1e-6 && abs(still.now.y - still.start.y) < 1e-12,
                  "a stationary cursor has a zero-length trail")
        let hidden = timeline.trail(at: 0.05, fps: 60)
        try check(hidden.strength == 0 && hidden.start == hidden.now, "a hidden cursor has no trail")
        let early = timeline.trail(at: 0.3, fps: 30)
        try check(early.now.x.isFinite && early.start.x.isFinite, "the trail clamps before time 0")
        let direct = timeline.trail(at: 4, frameDuration: 1.0 / 60, strength: 0.5)
        let before = timeline.state(at: 4 - 1.0 / 60)
        try check(abs(direct.start.x - (direct.now.x + (before.x - direct.now.x) * 0.5)) < 1e-12,
                  "start = lerp(now, before, strength)")
        try check(direct.start.opacity == direct.now.opacity && direct.start.blurRadius == direct.now.blurRadius,
                  "opacity and hide blur come from now")
    }

    private static func testTrailRendering(_ check: Checker) throws {
        let width = 1280, height = 720
        let renderer = CursorRenderer(outputSize: CGSize(width: width, height: height))
        let now = CursorState(x: 700.5 / 1280, y: 360.5 / 720, scale: 1, rotationRadians: 0, opacity: 1, blurRadius: 0)
        var start = now
        start.x = (700.5 - 60) / 1280
        let trail = CursorTrail(now: now, start: start, strength: 1)
        let sharp = try render(renderer.image(for: now), width: width, height: height)
        let sharpBox = boundingBox(sharp, width: width, height: height, threshold: 0.02)
        for quality in [CursorBlurQuality.export, .preview] {
            let bytes = try render(renderer.image(for: trail, quality: quality), width: width, height: height)
            let box = boundingBox(bytes, width: width, height: height, threshold: 0.02)
            let n = Double(min(quality.maxSamples, Int(ceil(60 / quality.spanPixels))))
            try check(abs(box.minX - (sharpBox.minX - 60 * (1 - 0.5 / n))) < 6,
                      "trail extends behind the motion (minX \(box.minX), n \(Int(n)))")
            try check(box.maxX <= sharpBox.maxX + 1 && box.maxX >= sharpBox.maxX - 60 * 0.5 / n - 3,
                      "trail does not extend ahead of the cursor")
            try check(abs(box.minY - sharpBox.minY) <= 4 && abs(box.height - sharpBox.height) <= 8, "trail is horizontal only")
            func mass(_ bytes: [UInt8]) -> Double { stride(from: 3, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) / 255 } }
            try check(abs(mass(bytes) / mass(sharp) - 1) < 0.03, "stamps sum to the original alpha (\(mass(bytes) / mass(sharp)))")
        }
        let still = CursorTrail(now: now, start: now, strength: 1)
        try check(try render(renderer.image(for: still), width: width, height: height) == sharp, "stationary trail is bit-identical to the static image")
        let off = CursorTrail(now: now, start: start, strength: 0)
        try check(try render(renderer.image(for: off), width: width, height: height) == sharp, "strength 0 is bit-identical to the static image")
        var hidden = now
        hidden.opacity = 0
        try check(renderer.image(for: CursorTrail(now: hidden, start: start, strength: 1)) == nil, "invisible cursor draws nothing")
    }

    // MARK: Helpers

    private static func move(_ time: Double, _ x: Double, _ y: Double) -> CursorEvent {
        CursorEvent(time: time, x: x, y: y, kind: .move)
    }

    /// One event per 60 fps frame moving horizontally at a constant pixel speed.
    private static func sweep(from x: Double, speedPxPerMs: Double, start: Double, end: Double,
                              width: Double) -> [CursorEvent] {
        let frames = Int(((end - start) * 60).rounded())
        return (0...frames).map { i in
            move(start + Double(i) / 60, x + Double(i) * speedPxPerMs * 1000 / 60 / width, 0.5)
        }
    }

    private static func degrees(_ state: CursorState) -> Double { state.rotationRadians * 180 / .pi }

    private static func sized(_ size: Double) -> CursorConfiguration {
        var config = CursorConfiguration()
        config.size = size
        return config
    }

    private static func render(_ image: CIImage?, width: Int, height: Int) throws -> [UInt8] {
        guard let image else { throw Failure("renderer returned nil") }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                                             format: .RGBA8, colorSpace: nil),
              let data = cg.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { throw Failure("could not render test image") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<(width * 4) { bytes[row * width * 4 + column] = pointer[row * cg.bytesPerRow + column] }
        }
        return bytes
    }

    /// Pixel in top-left coordinates, premultiplied 0...1.
    private static func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, _ width: Int)
        -> (r: Double, g: Double, b: Double, a: Double) {
        let offset = (y * width + x) * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255,
                Double(bytes[offset + 2]) / 255, Double(bytes[offset + 3]) / 255)
    }

    private static func boundingBox(_ bytes: [UInt8], width: Int, height: Int,
                                    threshold: Double = 0.5) -> CGRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where Double(bytes[(y * width + x) * 4 + 3]) / 255 > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

private final class Checker {
    private(set) var count = 0

    func callAsFunction(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message) }
        count += 1
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Failure: LocalizedError {
    case failed(String)
    init(_ message: String) { self = .failed(message) }
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}
