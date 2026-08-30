#!/bin/bash
set -euo pipefail

# AI CONTEXT — Release validation for Autohop.
# Configuration-only mode is deterministic and runs in CI without signing.
# Archive mode must be run against the exact .xcarchive intended for upload; it
# inspects the signed application entitlements, because source entitlements
# intentionally say "development" and Xcode/provisioning rewrites APNs to
# "production" only in a correctly signed distribution archive.
#
# Usage:
#   Scripts/validate-release.sh --configuration-only
#   Scripts/validate-release.sh --archive /path/to/Autohop.xcarchive

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/project.yml"
commit_script="$repo_root/Scripts/embed-git-commit.sh"
mode="${1:---configuration-only}"

fail() {
  echo "RELEASE CHECK FAILED: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$message"
  fi
}

[[ -f "$project_file" ]] || fail "Missing project.yml"
[[ -x "$commit_script" ]] \
  || fail "Git commit identity embed script is missing or not executable"

# The shipping Release configuration must not define either development-only
# compilation condition. Comments may describe them, so inspect only the actual
# Release setting value.
release_conditions="$(
  awk '
    /^[[:space:]]*Release:/ { in_release=1; next }
    in_release && /SWIFT_ACTIVE_COMPILATION_CONDITIONS:/ {
      sub(/.*SWIFT_ACTIVE_COMPILATION_CONDITIONS:[[:space:]]*/, "")
      print
      exit
    }
    in_release && /^[[:space:]]*[A-Za-z][A-Za-z0-9_-]*:/ { in_release=0 }
  ' "$project_file"
)"
[[ -n "$release_conditions" ]] \
  || fail "Could not locate the app Release SWIFT_ACTIVE_COMPILATION_CONDITIONS"
[[ "$release_conditions" == '""' ]] \
  || fail "Release compilation conditions must be empty; found: $release_conditions"

for retired_directory in "$repo_root/Relay" "$repo_root/Store"; do
  [[ ! -e "$retired_directory" ]] \
    || fail "Retired production directory has returned: ${retired_directory#$repo_root/}"
done

if rg -n 'AUTOHOP_(PRO|RELAY)_ENABLED|AutohopProStore|RelayCoordinator|RelayClient' \
  "$repo_root/App" "$repo_root/Views" "$repo_root/TV" "$project_file" 2>/dev/null; then
  fail "Retired Autohop Pro or relay production code has returned"
fi
require_literal \
  "$project_file" \
  '^[[:space:]]*GitCommitSHA:[[:space:]]+unavailable[[:space:]]*$' \
  "The generated app Info.plist lacks the explicit GitCommitSHA fallback"
require_literal \
  "$project_file" \
  '^[[:space:]]*script:[[:space:]]+Scripts/embed-git-commit\.sh[[:space:]]*$' \
  "The app target no longer embeds its Git commit identity"

if [[ "$mode" == "--configuration-only" ]]; then
  echo "Release configuration checks passed (private iCloud sync only)."
  echo "Archive APNs check not run; pass --archive <path> for upload validation."
  exit 0
fi

[[ "$mode" == "--archive" ]] \
  || fail "Unknown mode '$mode' (use --configuration-only or --archive <path>)"
archive_path="${2:-}"
[[ -n "$archive_path" && -d "$archive_path" ]] \
  || fail "--archive requires an existing .xcarchive directory"

app_path="$archive_path/Products/Applications/Autohop.app"
[[ -d "$app_path" ]] || fail "Autohop.app not found in archive: $archive_path"

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/autohop-entitlements.XXXXXX.plist")"
trap 'rm -f "$entitlements_file"' EXIT
codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null \
  || fail "Unable to read signed entitlements from $app_path"

aps_environment="$(
  /usr/libexec/PlistBuddy -c 'Print :aps-environment' "$entitlements_file" \
    2>/dev/null || true
)"
[[ "$aps_environment" == "production" ]] \
  || fail "Signed archive aps-environment must be production; found '${aps_environment:-missing}'"

if find "$archive_path/Products" -type d -name 'AutohopTV.app' -print -quit \
  | grep -q .; then
  fail "AutohopTV.app is embedded in the iPhone-only release archive"
fi

echo "Release archive checks passed:"
echo "  signed APNs environment: production"
echo "  sync transport: private iCloud only"
echo "  tvOS archive: validated separately with Scripts/validate-tvos-release.sh"
