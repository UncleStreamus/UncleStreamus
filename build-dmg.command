#!/bin/bash
# build-dmg.command — Create and upload a ZappaStream release DMG
#
# Usage: drag ZappaStream.app onto the Terminal window after the script path
#   ./build-dmg.command /path/to/ZappaStream.app
#
# Before running:
#   Xcode → Product → Archive → Distribute App → Copy App → save somewhere

set -e

cd "$(dirname "$0")"

APP_PATH="$1"

if [ -z "$APP_PATH" ]; then
  echo "Usage: $0 <path-to-ZappaStream.app>"
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Error: App not found at '$APP_PATH'"
  exit 1
fi

if ! command -v create-dmg &> /dev/null; then
  echo "Error: create-dmg not found. Install with: brew install create-dmg"
  exit 1
fi

VERSION=$(grep "MARKETING_VERSION" ZappaStream.xcodeproj/project.pbxproj | head -1 | sed 's/.*= //;s/;//;s/ //')
OUTPUT="$(dirname "$APP_PATH")/ZappaStream-${VERSION}.dmg"

echo "Building DMG for ZappaStream ${VERSION}..."

create-dmg \
  --volname "ZappaStream" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "ZappaStream.app" 175 190 \
  --hide-extension "ZappaStream.app" \
  --app-drop-link 425 190 \
  "$OUTPUT" \
  "$APP_PATH"

echo ""
echo "DMG created: $OUTPUT"
echo ""
echo "To upload to the GitHub release:"
echo "  gh release upload v${VERSION} \"$OUTPUT\""
