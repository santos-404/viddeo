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
timeline, stage and source-time caption settings from the editor to the exporter.

`EditorModel` owns a complete timeline/stage/caption snapshot and `EditHistory`.
Failed edits roll back; exports consume current unsaved state. Sidecars save atomically
one at a time, with the project saved last. Switching sessions or quitting first saves
dirty state; a failure prevents that transition. Asynchronous speech/silence operations
disable capture, export and editing until they finish.

`ClickEffectTimeline` filters and sorts pointer-down events, bounds active events
by binary search, and supplies deterministic source-space rings during export.
It does not depend on recording state; overlays follow the same crop as raw video.

## Module layout

Sources are in `Viddeo/Sources`; project `Viddeo/Viddeo.xcodeproj` links Apple
frameworks directly. No third-party runtime/media engine. `Scripts/build.sh`
builds and ad hoc signs. Standalone zoom and synthetic-export verifiers validate
math and media independently of screen permissions.

## Remaining seams

The basic editor and source/playback mapping now work. `AppleSpeechCaptionProvider`
uses SpeechAnalyzer/SpeechTranscriber; caption audio extraction preserves the movie's
epoch. Webcam recorder/overlay and DSP audio cleanup/mixing/click modules are implemented
and tested independently, but still need app/export integration. Processed playback
preview, camera lifecycle integration and one mixed audio export track remain follow-ups.
