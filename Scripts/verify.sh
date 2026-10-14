#!/bin/sh
set -eu

VIDDEO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$VIDDEO_ROOT"
mkdir -p .build
VIDDEO_TARGET="$(uname -m)-apple-macosx26.0"

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/ZoomTimeline.swift \
  Scripts/verify-zoom.swift -o .build/verify-zoom
.build/verify-zoom

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/CursorRecorder.swift \
  Viddeo/Sources/ScreenRecorder.swift Viddeo/Sources/WebcamRecorder.swift Viddeo/Sources/WebcamOverlay.swift Scripts/verify-capture.swift \
  -o .build/verify-capture
.build/verify-capture

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/ZoomTimeline.swift \
  Viddeo/Sources/ClickEffects.swift Viddeo/Sources/ExportPreset.swift Viddeo/Sources/GifExporter.swift \
  Viddeo/Sources/CursorModel.swift Viddeo/Sources/CursorRenderer.swift \
  Viddeo/Sources/OfflineExporter.swift Viddeo/Sources/ExportEdit.swift Viddeo/Sources/ExportAudio.swift Viddeo/Sources/AudioProcessing.swift Viddeo/Sources/ClickSounds.swift \
  Viddeo/Sources/WebcamExport.swift Viddeo/Sources/WebcamOverlay.swift Viddeo/Sources/SilenceDetector.swift \
  Viddeo/Sources/TimelineModel.swift Viddeo/Sources/Project.swift \
  Viddeo/Sources/StageStyle.swift Viddeo/Sources/StageRenderer.swift \
  Viddeo/Sources/Captions.swift Viddeo/Sources/CaptionRenderer.swift Scripts/verify-export.swift \
  -o .build/verify-export
.build/verify-export

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/CursorRecorder.swift \
  Viddeo/Sources/ScreenRecorder.swift Viddeo/Sources/WebcamRecorder.swift Viddeo/Sources/WebcamOverlay.swift Scripts/verify-audio.swift \
  -o .build/verify-audio
.build/verify-audio

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/ClickEffects.swift \
  Scripts/verify-clicks.swift -o .build/verify-clicks
.build/verify-clicks

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/ExportPreset.swift Scripts/verify-presets.swift -o .build/verify-presets
.build/verify-presets

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Scripts/compare/ClipComparison.swift Scripts/verify-compare.swift -o .build/verify-compare
.build/verify-compare

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/TimelineModel.swift \
  Viddeo/Sources/EditHistory.swift Viddeo/Sources/Project.swift Scripts/verify-timeline.swift \
  -o .build/verify-timeline
.build/verify-timeline

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/StageStyle.swift Viddeo/Sources/StageRenderer.swift Scripts/verify-stage.swift \
  -o .build/verify-stage
.build/verify-stage

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/Captions.swift \
  Viddeo/Sources/CaptionRenderer.swift Viddeo/Sources/SpeechCaptionProvider.swift \
  Scripts/verify-captions.swift -o .build/verify-captions
.build/verify-captions

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/TimelineModel.swift \
  Viddeo/Sources/SilenceDetector.swift Viddeo/Sources/TimelineSilence.swift \
  Scripts/verify-silence.swift -o .build/verify-silence
.build/verify-silence

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/WebcamOverlay.swift \
  Viddeo/Sources/WebcamRecorder.swift Scripts/verify-webcam.swift -o .build/verify-webcam
.build/verify-webcam

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/AudioProcessing.swift \
  Viddeo/Sources/ClickSounds.swift Scripts/verify-audio-processing.swift \
  -o .build/verify-audio-processing
.build/verify-audio-processing

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/CursorModel.swift \
  Viddeo/Sources/CursorRenderer.swift Scripts/verify-cursor.swift -o .build/verify-cursor
.build/verify-cursor

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/ZoomTimeline.swift \
  Viddeo/Sources/ClickEffects.swift Viddeo/Sources/ExportPreset.swift Viddeo/Sources/GifExporter.swift \
  Viddeo/Sources/CursorModel.swift Viddeo/Sources/CursorRenderer.swift \
  Viddeo/Sources/OfflineExporter.swift Viddeo/Sources/ExportEdit.swift Viddeo/Sources/ExportAudio.swift Viddeo/Sources/AudioProcessing.swift Viddeo/Sources/ClickSounds.swift \
  Viddeo/Sources/WebcamExport.swift Viddeo/Sources/WebcamOverlay.swift \
  Viddeo/Sources/TimelineModel.swift Viddeo/Sources/Project.swift Viddeo/Sources/EditHistory.swift \
  Viddeo/Sources/StageStyle.swift Viddeo/Sources/StageRenderer.swift \
  Viddeo/Sources/Captions.swift Viddeo/Sources/CaptionRenderer.swift Viddeo/Sources/SpeechCaptionProvider.swift \
  Viddeo/Sources/SilenceDetector.swift Viddeo/Sources/TimelineSilence.swift \
  Viddeo/Sources/EditorModel.swift Scripts/verify-editor.swift -o .build/verify-editor
.build/verify-editor

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/CursorRecorder.swift \
  Scripts/verify-events.swift -o .build/verify-events
.build/verify-events
