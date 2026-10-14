# viddeo — Architecture

Swift 6 + SwiftUI, macOS 26+. One native process captures raw video and a pointer
sidecar, then renders zoom offline. This is viddeo's design; the reference helper
fleet does not establish an identical original pipeline.

## Process model

`RecordingViewModel` is the main-actor state boundary for displays, capture,
completed-session loading and export. It serializes user actions, retains a
previous completed session on capture failure, and surfaces permission errors.

`ScreenRecorder` owns SCStream lifecycle. A serial sample queue confines writer
state. Complete screen frames feed AVAssetWriter H.264; optional ScreenCaptureKit system
audio/microphone outputs feed separate AAC writer inputs on the same queue.
First accepted video PTS establishes their common movie epoch. Stream/writer failures
converge on cleanup. First capture is capped to even dimensions within 3840×2160.

`CursorRecorder` owns a listen-only CGEvent tap. Locked storage maps host timestamps
to first-frame time and display-relative coordinates, including an initial stationary
pointer sample. Optional key-down timing is explicit opt-in and stores no key identity
or text. New cursor-free capture falls back to an embedded system cursor when monitoring
cannot start; denied or interrupted monitoring is surfaced.

`RecordingSession` is the Codable capture contract. Raw video remains immutable;
JSON can be loaded separately for future editor/export work.

`ZoomTimeline` is independent of capture/media APIs. It plans click windows,
spatial groups and physical transitions once, then supplies immutable frame
lookup for concurrent composition callbacks and arbitrary seeks.

`OfflineExporter` validates media metadata, maps playback time to source time, decodes
raw frames through `ExportFrameSource` and composes cursor/click overlays before zoom
crop/scale. Stage and captions follow. AVAssetWriter writes H.264/HEVC MP4; ImageIO
writes GIF. MP4 outputs are staged to temporary siblings and moved into place only
after all requested codecs succeed. Failures remove temporary output.

`ExportAudioTrack` keeps raw sources separate. Edited tracks use AVMutableComposition
for trim/reorder and spectral time stretching, then apply per-segment PCM gains.
Silence gaps are filled to the edited playback duration. `ExportEdit` carries immutable
timeline, stage, source-time caption and audio-mix settings from the editor to the exporter.

An `AudioMixConfiguration` that changes anything (`audio-config.json`, Audio tab) adds three
things before encoding, all per source: master volume and mutes multiply each track's gain
(an audio mix in the pass-through path, the PCM gain step in the edited path); the microphone
track is run through the `VoiceCleanup` preset and re-read from a temporary CAF, delayed by the
track's start offset so it stays aligned; click sounds are rendered from the pointer events and
exported as an extra AAC track. Background music (a file copied into the session folder, named by
`backgroundAudioFileName`) is a viddeo design choice in playback time: it starts at playback 0, loops
(5 ms seam fades) to fill the edited duration, fades out linearly over the last second, ignores trims
and speed ramps, and takes master volume x music volume (default 0.05) unless muted; it is baked to a
CAF and exported as another AAC track. A missing file fails the export with an error naming it.
With `mixdownSingleTrack` (MP4 only) the per-source `ExportAudioTrack`s are created without a writer
and drained with `renderPCM()` (48 kHz, playback time, gains applied), summed with the music by
`AudioMixer.sum`, optionally loudness-normalized (`targetLoudnessLUFS`) and brick-wall limited
(`limiterCeilingDB`), then encoded as ONE stereo AAC track. The limiter runs before AAC encoding, so
the decoded peak can exceed the ceiling by a fraction of a dB. Neutral configurations (music unset or
muted, no mixdown) are dropped, so the default export is byte-for-byte the previous path.

Cursor motion: `CursorTimeline` filters its input events (`CursorEventFilter`: Manhattan-pixel shake removal,
optional loop window with a return-to-start event), springs them, and exposes `trail(at:fps:)` (now plus the state one
output frame earlier, blended by `motionBlurAmount x fps/60`). `CursorRenderer` draws the trail as 16 (export) or 6
(preview) equal-alpha stamps of one arrow bitmap; `makeRenderer` sets `cursorFPS` and the sample quality on the
`ExportFrameRenderer`. Screen/zoom motion blur uses the same `motionBlurAmount` (`cursor-config.json`, `ExportEdit.motionBlurAmount`
from the editor's Background tab): `ScreenMotionBlur` (in `ZoomTimeline.swift`) interpolates the zoom crop between the previous output
frame and now, `ExportFrameRenderer` averages one resample per crop (16 export / 6 preview), and `previousSourceTime(forPlaybackTime:)`
maps the earlier frame through the edit and returns nil across a cut. The camera overlay is not blurred. See `research/cursor-motion.md`.

`OfflineExporter.makeRenderer` builds the `ExportFrameRenderer` (validation, zoom, clicks, cursor, stage,
captions, camera plan) for both the export and the editor preview. `PreviewFrameRenderer` (an actor in
`EditorPreview.swift`) renders its frames at 640 px wide off the main actor through seekable
`ExportFrameSource`/`WebcamFrameSource`; `EditorPreviewModel` plays at up to 30 fps by wall clock (slow frames
are skipped) and cancels stale scrub requests. The preview shows the editor's unsaved state and has no audio.

`EditorModel` owns a complete timeline/stage/caption snapshot and `EditHistory`.
Failed edits roll back; exports consume current unsaved state. Sidecars save atomically
one at a time, with the project saved last. Switching sessions or quitting first saves
dirty state; a failure prevents that transition. Asynchronous speech/silence operations
disable capture, export and editing until they finish.

Keyboard shortcut overlay: `CursorRecorder` has a second opt-in beside key timing. Its listen-only tap
passes key-downs to `ShortcutCapture.classify` (pure, in `RecordingSession.swift`), which keeps a press
only when ⌘/⌥/⌃ is held or the key is a special non-text key, and looks the key's unmodified
character up (UCKeyTranslate, layout-aware) only for those; the result is `RecordingSession.shortcuts`.
`ShortcutOverlay.swift` holds the pure model (`ShortcutOverlayConfiguration`, grouping and timing in
`ShortcutOverlayPlanner`, glyph table) and `ShortcutOverlayRenderer`, which draws the key caps with
Core Graphics/Core Text into a canvas-size CIImage like `CaptionRenderer`. `ExportFrameRenderer`
composites it after the camera and before captions, in output space, so zoom never moves it; export,
GIF and the editor preview share that path. The settings are part of `EditorState` and persist as
`shortcuts-config.json`; `ExportEdit.load` reads it.

Device mockups are an opt-in part of `StageStyle`. `DeviceFrameRenderer` uses viddeo-authored geometry
and procedural Core Image shapes; the stage fits the whole device while the exporter resamples the
zoomed screen directly to its aperture. The device owns screen rounding, while stage background,
padding and shadow remain outer layers.

`ClickEffectTimeline` filters and sorts pointer-down events, bounds active events
by binary search, and supplies deterministic source-space rings during export.
It does not depend on recording state; overlays follow the same crop as raw video.

Colour: every exported pixel is sRGB-encoded. The exporter used to render through `CIContext` into the
`itur_709` colour space and tag the stream BT.709 transfer; macOS decodes that tag as a gamma ~1.96 curve,
so a #204060 stage came back as (50,83,116) instead of (32,64,96). The exporter now renders in sRGB,
tags the stream BT.709 primaries/matrix with the sRGB (IEC 61966-2-1) transfer and the same attachments
on each pixel buffer, and `SourceFrameReader` decodes raw recordings as sRGB (ScreenCaptureKit output is
sRGB content written with a BT.709 tag), so screen pixels pass through unchanged. `Scripts/verify-color.swift`
asserts the round trip (greys <= 3/255, saturated <= 8/255). GIF was already sRGB; the editor preview
keeps a BT.709-tagged CGImage, which the display colour-manages correctly.

## Module layout

Sources are in `Viddeo/Sources`; project `Viddeo/Viddeo.xcodeproj` links Apple
frameworks directly. No third-party runtime/media engine. `Scripts/build.sh`
builds and uses a unique Apple Development identity when available, with ad-hoc signing
as a fallback. Standalone zoom and synthetic-export verifiers validate
math and media independently of screen permissions.

## Remaining seams

The basic editor and source/playback mapping now work. `AppleSpeechCaptionProvider`
uses SpeechAnalyzer/SpeechTranscriber; caption audio extraction preserves the movie's
epoch. Microphone cleanup, master volume/mutes, click sounds and the camera overlay are in the export.
The camera is recorded by `WebcamRecorder` as a separate `camera.mov`, started after the screen stream
and aligned afterwards through host-clock first-frame times; `WebcamExportPlan`/`WebcamFrameSource`
decode and place it per output frame (seek-capable for edited timelines), so recording never depends on
the camera. Face tracking remains a follow-up.

Camera layouts live in `WebcamConfiguration` (`layout` is the default; `layoutItems` are source-time
`CameraLayoutItem`s that override it, at least 500 ms, non-overlapping; `split` and `cutout` hold the per-layout
options; old `webcam-config.json` files decode unchanged). `WebcamOverlay.resolve` turns a layout into a screen
rect and a camera rect from the canvas, or from the stage's padded area. For `splitScreen` the renderer fits the
zoomed, motion-blurred screen into the screen pane (`ExportFrameRenderer.splitScreenLayout`/`splitFrame`; the stage
background shows around and between the panes) and aspect-fills the camera into its pane; the stage's shadow, border
and device frame are not drawn around split panes. `cutoutCamera` runs `PersonSegmenter` (Vision
`VNGeneratePersonSegmentationRequest`, `.balanced` for export, `.fast` for the preview) through `CutoutMaskCache`,
which caches one mask per decoded camera frame and records every frame that fell back to the rounded overlay.
Layouts switch immediately at item boundaries.
