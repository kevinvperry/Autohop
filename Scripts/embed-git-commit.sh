#!/bin/bash
set -euo pipefail

# AI CONTEXT — Runs as the final app-target build phase, before Xcode signs the
# product. It embeds the exact checked-out commit in the built Info.plist so
# diagnostic launch records can establish build boundaries without inference.
# Source/generated plists are never mutated. Non-git source exports retain the
# explicit `unavailable` fallback instead of failing a user build.

repo_root="${SRCROOT:-$(pwd)}"
built_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
commit="unavailable"
build_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

if command -v git >/dev/null 2>&1 \
  && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  commit="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || true)"
  [[ -n "$commit" ]] || commit="unavailable"
fi

[[ -f "$built_plist" ]] || {
  echo "warning: Built Info.plist unavailable; GitCommitSHA was not embedded"
  exit 0
}

/usr/libexec/PlistBuddy -c "Set :GitCommitSHA $commit" "$built_plist" \
  >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :GitCommitSHA string $commit" "$built_plist"
/usr/libexec/PlistBuddy -c "Set :BuildTimestampUTC $build_timestamp" "$built_plist" \
  >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :BuildTimestampUTC string $build_timestamp" "$built_plist"

echo "Embedded GitCommitSHA=$commit BuildTimestampUTC=$build_timestamp"
