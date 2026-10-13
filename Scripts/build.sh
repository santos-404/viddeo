#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
node "$ROOT_DIR/Scripts/sync-sources.js"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/.build/DerivedData}"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/Viddeo.app"

xcodebuild \
  -project "$ROOT_DIR/Viddeo/Viddeo.xcodeproj" \
  -scheme Viddeo \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

codesign --force --deep --sign - "$APP_PATH"
