#!/bin/bash
set -euo pipefail

"$(cd "$(dirname "$0")" && pwd)/validate-tv-ai-context.sh"

# Resolve every path from the script location so the gate behaves identically
# when Xcode, CI, or a developer launches it from another working directory.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# AI CONTEXT — Architectural regression guards. The physical-TV rebuild removed
# the legacy all-library feed sweep and all prototype subscription seeds. These
# checks intentionally scan production TV Swift sources only; test fixtures and
# the explicit bounded Windows Weekly migration fallback are not subscriptions.
if rg -n 'func[[:space:]]+refreshFeeds|minimumFeedsRefreshInterval' "$repo_root/TV" --glob '*.swift' >/dev/null; then
  echo "ERROR: legacy all-library tvOS feed sweep has returned" >&2
  exit 1
fi
if rg -n 'addSubscription\(|SampleSubscriptions|seedDemo|seedTestSubscription' "$repo_root/TV" --glob '*.swift' >/dev/null; then
  echo "ERROR: prototype subscription seeding found in tvOS production sources" >&2
  exit 1
fi
playback_model="$repo_root/TV/Playback/TVPlaybackModel.swift"
rg -q 'private\(set\)[[:space:]]+var[[:space:]]+avPlayer:[[:space:]]+AVPlayer\?' "$playback_model" || {
  echo "ERROR: tvOS player must remain observable stored state" >&2
  exit 1
}
if rg -n 'var[[:space:]]+avPlayer[^\n]*engine\.avPlayer' "$playback_model" >/dev/null; then
  echo "ERROR: computed engine player bridge would strand SwiftUI in Preparing video" >&2
  exit 1
fi

# AI CONTEXT — Phase 6 deterministic tvOS release gate. Configuration checks
# run in CI; archive mode additionally inspects the signed product. Hardware
# validation is intentionally a separately signed checklist and cannot be
# inferred from a successful simulator build.
fail() { echo "TV RELEASE CHECK FAILED: $*" >&2; exit 1; }
project="$repo_root/project.yml"
checklist="$repo_root/Docs/TVOS_PHASE6_VALIDATION.md"

grep -Eq '^[[:space:]]*AutohopTV:' "$project" || fail "AutohopTV target missing"
grep -Eq '^[[:space:]]*deploymentTarget: "18\.0"' "$project" || fail "tvOS minimum must be explicit"
grep -Eq '^[[:space:]]*aps-environment: development' "$project" || fail "source APNs entitlement missing"
[[ -f "$checklist" ]] || fail "physical-device validation checklist missing"

if [[ "${1:---configuration-only}" == "--configuration-only" ]]; then
  echo "tvOS configuration checks passed; signed hardware checklist remains required for submission."
  exit 0
fi
[[ "$1" == "--archive" && -d "${2:-}" ]] || fail "use --archive <AutohopTV.xcarchive>"
app="${2}/Products/Applications/AutohopTV.app"
[[ -d "$app" ]] || fail "AutohopTV.app missing from archive"
info_plist="$app/Info.plist"
[[ -f "$info_plist" ]] || fail "AutohopTV Info.plist missing from archive"
primary_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon' "$info_plist" 2>/dev/null || true)"
[[ -n "$primary_icon" ]] || fail "App Store icon is missing from the compiled tvOS asset catalogue"
top_shelf="$(/usr/libexec/PlistBuddy -c 'Print :TVTopShelfImage:TVTopShelfPrimaryImage' "$info_plist" 2>/dev/null || true)"
[[ -n "$top_shelf" ]] || fail "standard Top Shelf image is missing from the compiled tvOS asset catalogue"
top_shelf_wide="$(/usr/libexec/PlistBuddy -c 'Print :TVTopShelfImage:TVTopShelfPrimaryImageWide' "$info_plist" 2>/dev/null || true)"
[[ -n "$top_shelf_wide" ]] || fail "wide Top Shelf image is missing from the compiled tvOS asset catalogue"
[[ -f "$app/Assets.car" ]] || fail "compiled tvOS asset catalogue is missing from archive"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
codesign -d --entitlements :- "$app" >"$tmp" 2>/dev/null || fail "cannot read signed entitlements"
env="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$tmp" 2>/dev/null || true)"
[[ "$env" == production ]] || fail "signed APNs environment is '${env:-missing}', expected production"
grep -Eq '^- \[x\] Product owner physical-device sign-off' "$checklist" || fail "physical-device sign-off is incomplete"
echo "tvOS archive checks passed."
