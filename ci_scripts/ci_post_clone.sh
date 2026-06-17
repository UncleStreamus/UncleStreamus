#!/bin/sh
#
# ci_post_clone.sh — Xcode Cloud post-clone hook.
#
# Xcode Cloud performs a *shallow* clone (a single commit, no prior tags). The
# iOS "What's New" build phase (Scripts/generate_release_notes.sh) derives its
# notes from the commit range since the *previous* release tag — which a shallow
# clone hides. With only HEAD visible (the version-bump commit, itself a
# backend-scoped commit that gets filtered out), the sheet ends up empty.
#
# Deepen the history and fetch tags here, in the unsandboxed post-clone
# environment (full git + network), so the previous tag and its commit range are
# visible when the build phase runs.
#
# Best-effort: this must never fail the Xcode Cloud build, so every step is
# guarded and the script always exits 0.

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}"
cd "$REPO" 2>/dev/null || true

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  # Fetch full history + all tags so `git tag --no-contains HEAD` can find the
  # previous release tag. Fall back to a bounded deepen if --unshallow is refused.
  git fetch --unshallow --tags 2>/dev/null \
    || git fetch --deepen=500 --tags 2>/dev/null \
    || true
else
  # Already a full clone; just make sure tags are present.
  git fetch --tags 2>/dev/null || true
fi

exit 0
