#!/bin/bash
# build-dmg.sh — Create and upload a ZappaStream release DMG
#
# Usage:
#   ./build-dmg.sh <path-to-ZappaStream.app>
#
# Steps before running:
#   1. Xcode → Product → Archive → Distribute App → Copy App
#   2. Note the folder Xcode saves the .app to
#   3. Run: ./build-dmg.sh ~/Desktop/ZappaStream-export/ZappaStream.app

set -e

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

# Read version from project file
VERSION=$(grep "MARKETING_VERSION" ZappaStream.xcodeproj/project.pbxproj | head -1 | sed 's/.*= //;s/;//;s/ //')
DMG_NAME="ZappaStream-${VERSION}.dmg"
OUTPUT="$HOME/Desktop/${DMG_NAME}"

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
