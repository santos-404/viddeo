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
exported as an extra AAC track. Sources are never mixed into one track. Neutral configurations are
dropped, so the default export is byte-for-byte the previous path. Background music, the limiter
and loudness target, and `AudioMixer.render` (single mixed track) are not wired.

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
the camera. Processed playback preview, background music, one mixed (limited, loudness-normalized) audio
export track, split-screen/cutout layouts and face tracking remain follow-ups.
