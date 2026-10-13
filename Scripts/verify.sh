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
  Viddeo/Sources/ScreenRecorder.swift Scripts/verify-capture.swift \
  -o .build/verify-capture
.build/verify-capture

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/ZoomTimeline.swift \
  Viddeo/Sources/ClickEffects.swift Viddeo/Sources/OfflineExporter.swift Scripts/verify-export.swift \
  -o .build/verify-export
.build/verify-export

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/CursorRecorder.swift \
  Viddeo/Sources/ScreenRecorder.swift Scripts/verify-audio.swift \
  -o .build/verify-audio
.build/verify-audio

xcrun swiftc -swift-version 6 -target "$VIDDEO_TARGET" -parse-as-library \
  Viddeo/Sources/RecordingSession.swift Viddeo/Sources/ClickEffects.swift \
  Scripts/verify-clicks.swift -o .build/verify-clicks
.build/verify-clicks
