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

The script builds `Viddeo/Viddeo.xcodeproj` and uses the only valid Apple Development
identity in the keychain when exactly one is available. Otherwise it signs ad hoc.
Set `VIDDEO_SIGNING_IDENTITY` to select a specific identity when multiple are installed.
Stable signing lets macOS recognize the app across rebuilds; ad-hoc identity changes can
make Screen Recording permission appear to be missing after a rebuild. No dependency
installation is required. First launch may request Screen Recording permission. Allow
Viddeo in System Settings → Privacy & Security → Screen Recording (or Screen & System
Audio Recording), then reopen if macOS requests it.

For pointer tracking, allow Viddeo under **Input Monitoring**. A missing or
interrupted event tap is reported in the UI and session metadata. Raw capture can
still succeed; record again after granting permission to get automatic zooms.

Choose a display and optionally enable System Audio and Microphone → Start →
click around → Stop → Export. Microphone requests macOS permission when enabled;
if denied, grant it in Privacy & Security → Microphone or turn the option off.
Export shows a click disc (observed Screen Studio circle effect: width-relative growth, rim, fade)
by default; turn off Show click effects in export for plain cursor video. Tune it in the
`click-config.json` beside a session. Raw recordings are unchanged by that export option.
Pick an export preset (H.264, HEVC, both, or GIF; quality tiers, 720p–4K, aspect ratios) before
Export; custom presets load from `export-presets.json` in the session folder. Capture stores raw H.264
video and pointer JSON in `~/Library/Application Support/Viddeo/Recordings/<UUID>/`.
Use Show Recording to find it, or Load Session to reopen its `session.json`.
Exports use a chosen MP4 path and refuse to replace existing files.

Tune the generated `zoom-config.json` beside a session, then export again. Defaults
are 2× zoom, 300 ms before /2500 ms after click, 2500 ms merge gap, and a physical
spring. Raw video is preserved for future editing. New recordings default to a
smooth cursor drawn during export. Turn off Smooth rendered cursor to embed the
system cursor instead. Existing sessions keep their embedded cursor. If pointer
monitoring cannot start, capture falls back to the system cursor. Hide cursor while
typing is opt-in and records key-down timestamps only, never keys or text.
Tune the procedural arrow in `cursor-config.json`; shake removal, motion blur,
app-specific cursor shapes and shortcut overlays remain follow-ups.

After Stop or Load Session, use the editor's Timeline, Background, Captions and Audio tabs.
Trim/split/delete/reorder segments, choose speed and separate microphone/system gains,
or analyze microphone silence and apply Trim Silence / Speed Silence 4×.
Source ranges use recording seconds; the playback duration updates with edits.
Undo/Redo covers timeline, stage and captions. Generate on Device requires recorded
microphone audio; Apple may download a supported language model. Review and correct
the generated cue text before saving. Enable Background and padding to add a gradient,
padding and rounded corners. Export uses the current edits, including unsaved changes.
The Audio tab sets master volume, mutes, microphone cleanup (Voice, Noise reduction, Podcast;
viddeo's own DSP, off by default) and an optional synthesized click sound exported as an extra
audio track. The editor shows a processed preview (export renderer at reduced size, current unsaved edits) with scrubber and play/pause, without audio.

Save Project writes `project.json`, `stage-config.json`, `captions.json` and
`captions-config.json` beside the session. Edits are also saved before starting another
recording, loading a different session or quitting. A failed save leaves the editor
dirty and blocks switching/quitting. Sidecars are individually atomic, not one
multi-file transaction. Turning the stage off preserves its saved style.

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
exports retain separate sources, including per-segment gain edits.
Test microphone denial and a second capture after granting access.

The basic timeline editor, on-device caption provider, background renderer,
speed/silence actions and rendered cursor are implemented. Speech model availability,
transcription quality and the new capture controls need live acceptance.
The camera overlay (Camera overlay toggle before recording, Camera tab in the editor) and audio
mix are wired into recording and MP4/GIF export; camera permission, device behavior and sync are
live-only checks. Device mockups, shortcut overlays, continuous speed ramps and ripple distortion remain
follow-ups. All of these areas remain in scope.

M4 (export presets, GIF, side-by-side comparison tool) is implemented and verified
synthetically; original-versus-viddeo comparison clips need a live recording of Screen Studio
and are tracked in [live acceptance](docs/live-acceptance.md). Compare any two clips with
`./Scripts/compare-clips.sh left.mp4 right.mp4 out.mp4 --left-label Original --right-label Viddeo`.
`build.sh` also keeps the Xcode project's source list in sync with `Viddeo/Sources/*.swift`
(`Scripts/sync-sources.js`).

See [live acceptance](docs/live-acceptance.md), [plan](docs/plan.md), [spec](docs/spec.md), [architecture](docs/architecture.md),
[research ledger](docs/research/ledger.md) and [auto-zoom findings](docs/research/auto-zoom.md).
Reference findings distinguish shipped static observations, manual interpretation,
independent design choices and unresolved behavior. Research artifacts are kept
separate from application sources. Existing `brand/` assets are untouched.
