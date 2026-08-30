#!/bin/bash
set -euo pipefail

# AI CONTEXT — Runs as the final app-target build phase, after the generated
# product Info.plist exists and before Xcode signs the product. project.yml must
# keep that plist in this phase's inputFiles or Xcode may schedule
# ProcessInfoPlistFile afterward and overwrite every value set here. It embeds
# the exact checked-out commit, a dirty-tree marker, and a
# source fingerprint in the built Info.plist so diagnostic launch records can
# establish build boundaries without assuming that HEAD describes local edits.
# Source/generated plists are never mutated. Non-git source exports retain the
# explicit `unavailable` fallback instead of failing a user build.

repo_root="${SRCROOT:-$(pwd)}"
built_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
commit="unavailable"
working_tree_dirty="unknown"
source_fingerprint="unavailable"
build_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

if command -v git >/dev/null 2>&1 \
  && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  commit="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || true)"
  [[ -n "$commit" ]] || commit="unavailable"
  working_tree_dirty="false"
  if ! git -C "$repo_root" diff --quiet --ignore-submodules -- \
    || ! git -C "$repo_root" diff --cached --quiet --ignore-submodules -- \
    || [[ -n "$(git -C "$repo_root" ls-files --others --exclude-standard)" ]]; then
    working_tree_dirty="true"
  fi

  fingerprint_material="$(mktemp "${TMPDIR:-/tmp}/autohop-source.XXXXXX")"
  trap 'rm -f "$fingerprint_material"' EXIT
  printf 'HEAD=%s\n' "$commit" > "$fingerprint_material"
  git -C "$repo_root" diff --no-ext-diff --binary HEAD -- \
    >> "$fingerprint_material"
  while IFS= read -r untracked_file; do
    [[ -n "$untracked_file" ]] || continue
    printf 'UNTRACKED=%s\n' "$untracked_file" >> "$fingerprint_material"
    shasum -a 256 "$repo_root/$untracked_file" >> "$fingerprint_material"
  done < <(
    git -C "$repo_root" ls-files --others --exclude-standard \
      | LC_ALL=C sort
  )
  source_fingerprint="$(
    shasum -a 256 "$fingerprint_material" \
      | awk '{ print substr($1, 1, 16) }'
  )"
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
/usr/libexec/PlistBuddy -c "Set :GitWorkingTreeDirty $working_tree_dirty" "$built_plist" \
  >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :GitWorkingTreeDirty string $working_tree_dirty" "$built_plist"
/usr/libexec/PlistBuddy -c "Set :SourceFingerprint $source_fingerprint" "$built_plist" \
  >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :SourceFingerprint string $source_fingerprint" "$built_plist"

# Declaring and materialising a phase output keeps the modern Xcode build graph
# ordered: product plist generation → provenance mutation → code signing.
if [[ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]]; then
  mkdir -p "$(dirname "$SCRIPT_OUTPUT_FILE_0")"
  touch "$SCRIPT_OUTPUT_FILE_0"
fi

echo "Embedded GitCommitSHA=$commit GitWorkingTreeDirty=$working_tree_dirty SourceFingerprint=$source_fingerprint BuildTimestampUTC=$build_timestamp"
