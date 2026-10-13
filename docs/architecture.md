# viddeo — Architecture

Swift 6 + SwiftUI, macOS 26+. One native process captures raw video and a pointer
sidecar, then renders zoom offline. This is viddeo's design; the reference helper
fleet does not establish an identical original pipeline.

## Process model

`RecordingViewModel` is the main-actor state boundary for displays, capture,
completed-session loading and export. It serializes user actions, retains a
previous completed session on capture failure, and surfaces permission errors.

`ScreenRecorder` owns SCStream lifecycle. A serial sample queue confines writer
state. Complete screen frames feed AVAssetWriter H.264. Stream/writer failures
converge on cleanup. First capture is capped to even dimensions within 3840×2160.

`CursorRecorder` owns a pointer-only listen-only CGEvent tap. Locked storage maps
host timestamps to first-frame time and display-relative coordinates. Denied or
interrupted monitoring is surfaced; raw screen capture can still finish.

`RecordingSession` is the Codable capture contract. Raw video remains immutable;
JSON can be loaded separately for future editor/export work.

`ZoomTimeline` is independent of capture/media APIs. It plans click windows,
spatial groups and physical transitions once, then supplies immutable frame
lookup for concurrent composition callbacks and arbitrary seeks.

`OfflineExporter` validates media metadata, loads zoom configuration, applies
Core Image crop/scale through AVVideoComposition, and writes MP4 with
AVAssetExportSession. Failed export output is removed.

## Module layout

Sources are in `Viddeo/Sources`; project `Viddeo/Viddeo.xcodeproj` links Apple
frameworks directly. No third-party runtime/media engine. `Scripts/build.sh`
builds and ad hoc signs. Standalone zoom and synthetic-export verifiers validate
math and media independently of screen permissions.

## Planned seams

The editor will own Project and source-to-playback mapping; rendering will consume
edit plans, independent of SwiftUI state. Captions will use an on-device Apple
Speech service reading selected audio tracks and returning editable cues.
Backgrounds/effects/webcam/audio add render layers/tracks. These are planned
interfaces, not implemented features; each gets milestone acceptance checks.
