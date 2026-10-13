# viddeo

Native macOS screen recording → cursor-driven automatic zoom → MP4 export.
Swift 6, SwiftUI, macOS 26+. This is an early working implementation with design
polish deferred. Screen Studio was inspected for behavioral insight using REA;
its code/assets/helper binaries are not used by viddeo.

## Build and run

Requires Xcode with a macOS 26+ SDK, selected by `xcode-select`.

```sh
./Scripts/build.sh
open .build/DerivedData/Build/Products/Debug/Viddeo.app
```

The script builds `Viddeo/Viddeo.xcodeproj` and ad hoc signs bundle `com.viddeo.app`.
No dependency installation is required. First launch may request Screen Recording
permission. Allow Viddeo in System Settings → Privacy & Security → Screen Recording
(or Screen & System Audio Recording), then reopen if macOS requests it.

For pointer tracking, allow Viddeo under **Input Monitoring**. A missing or
interrupted event tap is reported in the UI and session metadata. Raw capture can
still succeed; record again after granting permission to get automatic zooms.

Choose a display and optionally enable System Audio and Microphone → Start →
click around → Stop → Export. Microphone requests macOS permission when enabled;
if denied, grant it in Privacy & Security → Microphone or turn the option off.
Export shows expanding click rings by default; turn off Show click effects in
export for plain cursor video. Raw recordings are unchanged by that export option. Capture stores raw H.264
video and pointer JSON in `~/Library/Application Support/Viddeo/Recordings/<UUID>/`.
Use Show Recording to find it, or Load Session to reopen its `session.json`.
Exports use a chosen MP4 path and refuse to replace existing files.

Tune the generated `zoom-config.json` beside a session, then export again. Defaults
are 2× zoom, 300 ms before /2500 ms after click, 2500 ms merge gap, and a physical
spring. Raw video is preserved for future editing. The captured cursor is currently
embedded in raw video; separate smooth cursor rendering comes later.

## Verification

```sh
./Scripts/verify.sh
```

Synthetic verifiers cover zoom timing/grouping/seek stability, crop bounds,
H.264 writer output, idle-screen held-frame duration, dropped/nonmonotonic frame
handling, no-frame failure, session JSON roundtrip, measured 2× marker growth,
export dimensions/duration/filled edges and invalid-input/overwrite handling.
M3 checks cover two separate AAC tracks, preserved delayed source timing, legacy
session decoding, click fade/position/seeks and rendered zoom alignment. The export
fixture decodes both tracks to check that distinct 440/880 Hz tones survive.
Temporary media is removed on completion. The macOS 27 SDK warns that some
AVAssetWriter APIs are deprecated; those APIs remain available at the macOS 26
deployment target and the app builds successfully.

Live ScreenCaptureKit recording and UI export were confirmed after granting macOS
Screen Recording/Input Monitoring permissions on 2026-10-13. Two 2560×1440 live
sessions have valid event sidecars. Independent export checks read captured video,
verify duration and dimensions, and render the early-click session with automatic
zoom. Multi-display positions, detailed event-clock latency, denied-permission
flows and visual equivalence to Screen Studio still need acceptance checks.
Record a short clip with clicks in each display corner, idle for a few seconds,
Stop and Export; check durations, sidecar positions and framing. Also check denied
permissions and a second capture after stop. Original comparison clips are pending.

## Current scope

Implemented: native display capture, pointer sidecar, session loading, configurable
offline automatic zoom, click rings, optional microphone/system AAC capture and
H.264 export with audio. M1/M2 core runtime path is verified;
remaining fidelity and edge-case acceptance is recorded above.
M3 is partial until live dual-source sync and reference comparison pass. To check it,
enable both audio options, play a short sound while speaking/clicking, then stop
and export. Compare audio timing with the raw recording and inspect both tracks;
exports retain separate sources, with audio mixing/editing planned as a follow-up.
Test microphone denial and a second capture after granting access.

Presets/comparison (M4), the timeline, on-device captions, backgrounds/frames,
keyboard/cursor refinement, speed/silence, webcam and voice cleanup remain in scope.
Click sounds and ripple distortion also remain follow-ups.

See [plan](docs/plan.md), [spec](docs/spec.md), [architecture](docs/architecture.md),
[research ledger](docs/research/ledger.md) and [auto-zoom findings](docs/research/auto-zoom.md).
Reference findings distinguish shipped static observations, manual interpretation,
independent design choices and unresolved behavior. Research artifacts are kept
separate from application sources. Existing `brand/` assets are untouched.
