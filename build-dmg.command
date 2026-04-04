#!/bin/bash
# build-dmg.command — Create and upload a ZappaStream release DMG
# Double-click to run. Prompts for the exported .app via a file picker.
#
# Before running:
#   Xcode → Product → Archive → Distribute App → Copy App → save somewhere

set -e

# Change to the script's directory so we can read the project file
cd "$(dirname "$0")"

if ! command -v create-dmg &> /dev/null; then
  osascript -e 'display alert "create-dmg not found" message "Install it with: brew install create-dmg" as critical'
  exit 1
fi

# Prompt for the .app via file picker
APP_PATH=$(osascript -e 'tell app "Finder" to POSIX path of (choose file of type "app" with prompt "Select the exported ZappaStream.app:")')

if [ -z "$APP_PATH" ]; then
  echo "No file selected."
  exit 1
fi

# Trim any trailing newline/whitespace
APP_PATH="${APP_PATH%$'\n'}"

if [ ! -d "$APP_PATH" ]; then
  osascript -e "display alert \"App not found\" message \"Could not find: $APP_PATH\" as critical"
  exit 1
fi

# Read version from project file
VERSION=$(grep "MARKETING_VERSION" ZappaStream.xcodeproj/project.pbxproj | head -1 | sed 's/.*= //;s/;//;s/ //')
DMG_NAME="ZappaStream-${VERSION}.dmg"
OUTPUT="$HOME/Desktop/${DMG_NAME}"

echo "Building DMG for ZappaStream ${VERSION}..."
echo "Source: $APP_PATH"
echo "Output: $OUTPUT"
echo ""

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
echo "To upload to the GitHub release, run:"
echo "  gh release upload v${VERSION} \"$OUTPUT\""
echo ""

osascript -e "display notification \"ZappaStream-${VERSION}.dmg saved to Desktop\" with title \"DMG Ready\""
