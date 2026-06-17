#!/bin/sh
#
# generate_release_notes.sh
#
# Run as an Xcode "Run Script" build phase (iOS target), ordered AFTER
# "Copy Bundle Resources". Generates ReleaseNotes.json into the built app's
# Resources folder from git commit subjects, using the same categorization as
# .github/workflows/release.yml (Add: -> new, Improve: -> improved, Fix: -> fixed).
#
# Unlike release.yml, this sheet is tester-facing, so backend/dev commits are
# filtered OUT: any commit scoped as backend (e.g. "Fix(ci): ...") and any commit
# whose subject matches the backend keyword denylist (CI, signing, notarize, DMG,
# workflow, .md, etc.) is excluded. See the python block below.
#
# The app reads this bundled JSON on launch to show a "What's New" sheet after a
# build update. All failures degrade gracefully to empty arrays, so a missing git
# history or tooling never breaks the build or shows a sheet.

set -eu

# When invoked outside Xcode, SRCROOT may be unset; fall back to the script's repo.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRCROOT"

# Commit range: everything since the previous *marketing-version* tag (all commits
# if no tags). We deliberately skip same-version tags so a re-cut of the current
# release (e.g. build 20260617 -> 20260617.1, still 1.4.7) shows everything since
# the last real release (1.4.6) instead of an empty "since the last build" diff.
# --no-contains HEAD also skips a tag sitting on HEAD itself (fresh release/archive
# builds tag HEAD) — otherwise the range would be "thisTag..HEAD" = empty.
#
# NOTE: this needs real history + tags. Xcode Cloud clones shallow (HEAD only),
# which hides prior tags and makes notes come out empty; ci_scripts/
# ci_post_clone.sh deepens the clone and fetches tags before this build phase runs.
CUR_VER="${MARKETING_VERSION:-}"
PREV_TAG=""
for t in $(git tag --no-contains HEAD --sort=-creatordate 2>/dev/null || true); do
  tver=$(printf '%s' "$t" | sed -E 's/^v//; s/-build.*$//')   # v1.4.6-build20260614-2 -> 1.4.6
  if [ -z "$CUR_VER" ] || [ "$tver" != "$CUR_VER" ]; then
    PREV_TAG="$t"
    break
  fi
done
if [ -z "${PREV_TAG:-}" ]; then
  COMMITS=$(git log --pretty=format:'%s' --no-merges 2>/dev/null || true)
else
  COMMITS=$(git log "${PREV_TAG}..HEAD" --pretty=format:'%s' --no-merges 2>/dev/null || true)
fi

# Destination: the built product's Resources folder (set by Xcode). Fall back to a
# local path for standalone testing.
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
else
  DEST="${DEST:-./build/ReleaseNotesOut}"
fi
mkdir -p "$DEST"

# Categorize, filter, and assemble JSON. python3 ships on macOS build hosts and
# handles string escaping. Raw commit subjects are passed in via $COMMITS.
COMMITS="$COMMITS" \
BUILD="${CURRENT_PROJECT_VERSION:-}" VERSION="${MARKETING_VERSION:-}" \
python3 - "$DEST/ReleaseNotes.json" <<'PY'
import json, os, re, sys

# Backend/dev scopes: a commit prefixed "Type(scope): ..." with one of these
# scopes is excluded from the tester-facing sheet.
BACKEND_SCOPES = {
    "ci", "cd", "ci-cd", "build", "dev", "docs", "doc", "test", "tests",
    "chore", "deps", "dep", "infra", "release", "tooling", "project", "repo", "meta",
}

# Case-insensitive substrings that mark a commit as backend/dev. Tuned to the
# project's actual infra commits; deliberately specific to avoid dropping real
# features (e.g. NO bare "build"/"bump"/"migration"/"binary").
BACKEND_KEYWORDS = [
    "(ci)", "in ci", "ci archive", "github actions", "actions/", "xcode cloud",
    "notariz", "provisioning", "developer id", "code sign", "codesign", "signing",
    "entitlement", "xcframework", "pbxproj", "xcodeproj", "gitignore", "dmg",
    "testflight", "workflow", "app store connect", "arm64", "x86_64",
    "universal binary", "allowprovisioning", ".md", "readme", "changelog",
]

LINE = re.compile(r"^(Add|Improve|Fix)(?:\(([^)]+)\))?:\s+(.*)$")
buckets = {"Add": [], "Improve": [], "Fix": []}

for raw in os.environ.get("COMMITS", "").splitlines():
    m = LINE.match(raw.strip())
    if not m:
        continue
    kind, scope, desc = m.group(1), (m.group(2) or "").strip().lower(), m.group(3).strip()
    if not desc:
        continue
    if scope in BACKEND_SCOPES:
        continue
    low = raw.lower()
    if any(k in low for k in BACKEND_KEYWORDS):
        continue
    buckets[kind].append(desc)

data = {
    "build": os.environ.get("BUILD", ""),
    "version": os.environ.get("VERSION", ""),
    "new": sorted(buckets["Add"]),
    "improved": sorted(buckets["Improve"]),
    "fixed": sorted(buckets["Fix"]),
}
with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=2)
PY

echo "Wrote release notes to $DEST/ReleaseNotes.json"
