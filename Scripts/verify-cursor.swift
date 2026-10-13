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
        try check(c.removeShakeThresholdMs == 500 && c.motionBlurAmount == 1, "declared-only fields")
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

        var invalid = [CursorConfiguration](repeating: .init(), count: 6)
        invalid[0].size = -1
        invalid[1].stiffness = .nan
        invalid[2].hideWhileTypingKeyCount = 0
        invalid[3].mass = 0
        invalid[4].hideNotMovingAfterMs = -5
        invalid[5].maxTiltDeg = 200
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
        try check(idle.state(at: 4.5).opacity == 1, "re-shown within the threshold before the next event")
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
