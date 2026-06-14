#!/bin/sh
#
# generate_release_notes.sh
#
# Run as an Xcode "Run Script" build phase (iOS target), ordered AFTER
# "Copy Bundle Resources". Generates ReleaseNotes.json into the built app's
# Resources folder from git commit subjects, reusing the same categorization as
# .github/workflows/release.yml (Add: -> new, Improve: -> improved, Fix: -> fixed).
#
# The app reads this bundled JSON on launch to show a "What's New" sheet after a
# build update. All failures degrade gracefully to empty arrays, so a missing git
# history or tooling never breaks the build or shows a sheet.

set -eu

# When invoked outside Xcode, SRCROOT may be unset; fall back to the script's repo.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRCROOT"

# Commit range: everything since the most recent tag (all commits if no tags),
# matching the range logic in release.yml.
PREV_TAG=$(git tag --sort=-creatordate 2>/dev/null | head -1 || true)
if [ -z "${PREV_TAG:-}" ]; then
  COMMITS=$(git log --pretty=format:'%s' --no-merges 2>/dev/null || true)
else
  COMMITS=$(git log "${PREV_TAG}..HEAD" --pretty=format:'%s' --no-merges 2>/dev/null || true)
fi

NEW=$(printf '%s\n'      "$COMMITS" | grep '^Add: '     | sed 's/^Add: //'     | sort || true)
IMPROVED=$(printf '%s\n' "$COMMITS" | grep '^Improve: ' | sed 's/^Improve: //' | sort || true)
FIXED=$(printf '%s\n'    "$COMMITS" | grep '^Fix: '     | sed 's/^Fix: //'     | sort || true)

# Destination: the built product's Resources folder (set by Xcode). Fall back to a
# local path for standalone testing.
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
else
  DEST="${DEST:-./build/ReleaseNotesOut}"
fi
mkdir -p "$DEST"

# Assemble JSON with proper string escaping. python3 ships on macOS build hosts.
NEW="$NEW" IMPROVED="$IMPROVED" FIXED="$FIXED" \
BUILD="${CURRENT_PROJECT_VERSION:-}" VERSION="${MARKETING_VERSION:-}" \
python3 - "$DEST/ReleaseNotes.json" <<'PY'
import json, os, sys

def lines(name):
    return [l for l in os.environ.get(name, "").splitlines() if l.strip()]

data = {
    "build": os.environ.get("BUILD", ""),
    "version": os.environ.get("VERSION", ""),
    "new": lines("NEW"),
    "improved": lines("IMPROVED"),
    "fixed": lines("FIXED"),
}
with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=2)
PY

echo "Wrote release notes to $DEST/ReleaseNotes.json"
