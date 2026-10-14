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

SIGNING_IDENTITY="${VIDDEO_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ] && AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null); then
  DEVELOPMENT_IDENTITIES=$(printf '%s\n' "$AVAILABLE_IDENTITIES" \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p')
  DEVELOPMENT_IDENTITY_COUNT=$(printf '%s\n' "$DEVELOPMENT_IDENTITIES" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$DEVELOPMENT_IDENTITY_COUNT" -eq 1 ]; then
    SIGNING_IDENTITY=$DEVELOPMENT_IDENTITIES
  fi
fi

if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  codesign --force --deep --sign - "$APP_PATH"
  echo "No unique Apple Development identity found; signed ad hoc. Set VIDDEO_SIGNING_IDENTITY to use a stable identity."
fi
