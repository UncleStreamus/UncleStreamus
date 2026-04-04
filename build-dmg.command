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
  echo "Drag ZappaStream.app into this window and press Enter:"
  read -r APP_PATH
  APP_PATH="${APP_PATH//\\ / }"
fi

# Trim any trailing whitespace/newline
APP_PATH="${APP_PATH%"${APP_PATH##*[![:space:]]}"}"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: App not found at '$APP_PATH'"
  exit 1
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
OUTPUT="$(dirname "$APP_PATH")/ZappaStream-${VERSION}.dmg"
STAGING=$(mktemp -d)

echo "Building DMG for ZappaStream ${VERSION}..."

# Stage the .app and an Applications symlink
cp -R "$APP_PATH" "$STAGING/ZappaStream.app"
ln -s /Applications "$STAGING/Applications"

# Build compressed DMG directly with hdiutil — no AppleScript, no Finder
hdiutil create \
  -volname "ZappaStream" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUTPUT"

rm -rf "$STAGING"

echo ""
echo "DMG created: $OUTPUT"
echo ""
echo "To upload to the GitHub release:"
echo "  gh release upload v${VERSION} \"$OUTPUT\""
