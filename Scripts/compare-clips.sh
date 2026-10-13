#!/bin/sh
# Usage: Scripts/compare-clips.sh <left> <right> <output.mp4> [--left-label X] [--right-label Y] [--height N] [--right-offset SECONDS] [--audio left|right|none]
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -parse-as-library Scripts/compare/ClipComparison.swift Scripts/compare-clips.swift -o .build/compare-clips
exec .build/compare-clips "$@"
