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

# Build a stream of release "segments" newest-first, so the app can always show
# the most recent release that actually has user-facing changes — not just an empty
# "nothing changed in this exact build" message when manually opened. Each segment
# is the commit range for one release point:
#
#   • the current build (HEAD), bounded below by the previous marketing-version tag;
#   • then each older marketing version, newest first, bounded by the next older one.
#
# The python block below picks the FIRST (newest) segment with user-facing changes
# and labels the notes with that segment's version/build, plus a `current` flag
# (true only for the HEAD segment). The app shows that segment on manual open; the
# launch auto-popup is gated on `current` so a re-cut with no user-facing changes
# never pops up stale notes.
#
# Same-version tags are collapsed to their newest tag so a re-cut (e.g. build
# 20260617 -> 20260617.1, still 1.4.7) is treated as one release. --no-contains
# HEAD skips a tag sitting on HEAD itself (release/archive builds tag HEAD).
#
# NOTE: this needs real history + tags. Xcode Cloud clones shallow (HEAD only),
# which hides prior tags and makes notes come out empty; ci_scripts/
# ci_post_clone.sh (and `fetch-depth: 0` in release.yml) deepen the clone and fetch
# tags before this build phase runs.
CUR_VER="${MARKETING_VERSION:-}"
CUR_BUILD="${CURRENT_PROJECT_VERSION:-}"

# Newest tag per *version* (newest-first), excluding the current marketing version
# (HEAD already represents that release) and any tag on HEAD itself.
DISTINCT_TAGS=""
SEEN_VERS=""
OLDIFS=$IFS
IFS='
'
for t in $(git tag --no-contains HEAD --sort=-creatordate 2>/dev/null || true); do
  [ -n "$t" ] || continue
  tver=$(printf '%s' "$t" | sed -E 's/^v//; s/-build.*$//')   # v1.4.6-build20260614-2 -> 1.4.6
  if [ -n "$CUR_VER" ] && [ "$tver" = "$CUR_VER" ]; then
    continue
  fi
  case " $SEEN_VERS " in
    *" $tver "*) continue ;;                                   # already kept newest for this version
  esac
  SEEN_VERS="$SEEN_VERS $tver"
  DISTINCT_TAGS="${DISTINCT_TAGS}${t}
"
done
IFS=$OLDIFS

# Previous release tag bounds the current (HEAD) segment.
PREV_TAG=$(printf '%s' "$DISTINCT_TAGS" | sed -n '1p')

# Emit one segment: header "@@SEG<TAB>version<TAB>build<TAB>current" + commit subjects.
emit_segment() {  # $1 version  $2 build  $3 current(0/1)  $4 git-log-range (empty = all)
  printf '@@SEG\t%s\t%s\t%s\n' "$1" "$2" "$3"
  if [ -n "$4" ]; then
    git log "$4" --pretty=format:'%s' --no-merges 2>/dev/null || true
  else
    git log --pretty=format:'%s' --no-merges 2>/dev/null || true
  fi
  printf '\n'
}

SEGMENTS=$(
  # Current build (HEAD).
  if [ -n "$PREV_TAG" ]; then
    emit_segment "$CUR_VER" "$CUR_BUILD" "1" "${PREV_TAG}..HEAD"
  else
    emit_segment "$CUR_VER" "$CUR_BUILD" "1" ""
  fi

  # Older releases, newest first. For each, the older boundary is the next entry in
  # the list; the oldest uses all history up to its tag.
  newer=""; newer_ver=""; newer_build=""
  IFS='
'
  for t in $DISTINCT_TAGS; do
    [ -n "$t" ] || continue
    tver=$(printf '%s' "$t" | sed -E 's/^v//; s/-build.*$//')
    tbuild=$(printf '%s' "$t" | sed -nE 's/^.*-build([0-9].*)$/\1/p')   # "" when tag has no -build
    if [ -n "$newer" ]; then
      emit_segment "$newer_ver" "$newer_build" "0" "${t}..${newer}"
    fi
    newer="$t"; newer_ver="$tver"; newer_build="$tbuild"
  done
  IFS=$OLDIFS
  if [ -n "$newer" ]; then
    emit_segment "$newer_ver" "$newer_build" "0" "$newer"
  fi
)

# Destination: the built product's Resources folder (set by Xcode). Fall back to a
# local path for standalone testing.
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
else
  DEST="${DEST:-./build/ReleaseNotesOut}"
fi
mkdir -p "$DEST"

# Categorize, filter, and assemble JSON. python3 ships on macOS build hosts and
# handles string escaping. The newest-first segment stream is passed in via env;
# python picks the newest segment with user-facing changes.
SEGMENTS="$SEGMENTS" CUR_BUILD="$CUR_BUILD" CUR_VER="$CUR_VER" \
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


def categorize(commits):
    buckets = {"Add": [], "Improve": [], "Fix": []}
    for raw in commits:
        m = LINE.match(raw.strip())
        if not m:
            continue
        kind, scope, desc = m.group(1), (m.group(2) or "").strip().lower(), m.group(3).strip()
        if not desc:
            continue
        if scope in BACKEND_SCOPES:
            continue
        if any(k in raw.lower() for k in BACKEND_KEYWORDS):
            continue
        buckets[kind].append(desc)
    return buckets


# Parse the newest-first segment stream: "@@SEG\tversion\tbuild\tcurrent" headers
# followed by commit subjects.
segments = []
cur = None
for line in os.environ.get("SEGMENTS", "").splitlines():
    if line.startswith("@@SEG\t"):
        parts = line.split("\t")
        cur = {
            "version": parts[1] if len(parts) > 1 else "",
            "build": parts[2] if len(parts) > 2 else "",
            "current": (len(parts) > 3 and parts[3] == "1"),
            "commits": [],
        }
        segments.append(cur)
    elif cur is not None and line.strip():
        cur["commits"].append(line)

# First (newest) segment with any user-facing change wins.
chosen = None
for seg in segments:
    b = categorize(seg["commits"])
    if b["Add"] or b["Improve"] or b["Fix"]:
        chosen = (seg, b)
        break

if chosen:
    seg, b = chosen
    data = {
        "build": seg["build"],
        "version": seg["version"],
        "current": seg["current"],
        "new": sorted(b["Add"]),
        "improved": sorted(b["Improve"]),
        "fixed": sorted(b["Fix"]),
    }
else:
    # No user-facing changes anywhere — emit empty notes for the current build.
    data = {
        "build": os.environ.get("CUR_BUILD", ""),
        "version": os.environ.get("CUR_VER", ""),
        "current": True,
        "new": [], "improved": [], "fixed": [],
    }

with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=2)
PY

echo "Wrote release notes to $DEST/ReleaseNotes.json"
