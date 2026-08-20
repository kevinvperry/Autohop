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
grep -Eq '^[[:space:]]*AutohopTVTopShelf:' "$project" || fail "Top Shelf extension target missing"
grep -Eq '^[[:space:]]*deploymentTarget: "18\.0"' "$project" || fail "tvOS minimum must be explicit"
grep -Eq '^[[:space:]]*aps-environment: development' "$project" || fail "source APNs entitlement missing"
grep -q 'com.apple.tv-top-shelf' "$project" || fail "Top Shelf extension point missing"
grep -q 'com.kevinperry.autohop.tv-navigation' "$project" || fail "tvOS Top Shelf URL route declaration missing"
grep -q 'group.com.kevinperry.autohop' "$repo_root/TV/AutohopTV.entitlements" || fail "Debug tvOS App Group missing"
grep -q 'group.com.kevinperry.autohop' "$repo_root/TV/AutohopTV.Release.entitlements" || fail "Release tvOS App Group missing"
grep -q 'group.com.kevinperry.autohop' "$repo_root/TVTopShelf/AutohopTVTopShelf.entitlements" || fail "extension App Group missing"
for entitlements in "$repo_root/TV/AutohopTV.entitlements" "$repo_root/TV/AutohopTV.Release.entitlements" "$repo_root/TVTopShelf/AutohopTVTopShelf.entitlements"; do
  grep -q 'runs-as-current-user-with-user-independent-keychain' "$entitlements" \
    || fail "current-user tvOS isolation missing from $(basename "$entitlements")"
done
if rg -n 'AI_CONTEXT\.md in Resources|README\.md in Resources' "$repo_root/Autohop.xcodeproj/project.pbxproj" >/dev/null; then
  fail "engineering Markdown is included in a shipping tvOS product"
fi
if rg -n 'import (AutohopCore|GRDB|CloudKit|AVKit)|URLSession|TVAppModel|SubscriptionStore' "$repo_root/TVTopShelf" --glob '*.swift' >/dev/null; then
  fail "Top Shelf extension crossed its domain/network dependency boundary"
fi
[[ -f "$repo_root/TV/TopShelf/Shared/TVTopShelfExtensionDiagnostic.swift" ]] \
  || fail "Top Shelf extension diagnostic heartbeat schema missing"
grep -q 'maximumEncodedBytes = 4_096' "$repo_root/TV/TopShelf/Shared/TVTopShelfExtensionDiagnostic.swift" \
  || fail "Top Shelf extension diagnostic heartbeat is not bounded"
for outcome in dynamicContentReturned appGroupUnavailable manifestMissing manifestInvalid accountScopeMismatch noRenderableContent; do
  grep -q "$outcome" "$repo_root/TV/TopShelf/Shared/TVTopShelfExtensionDiagnostic.swift" \
    || fail "Top Shelf diagnostic outcome missing: $outcome"
done
grep -q 'Refresh Top Shelf Now' "$repo_root/TV/Views/TVDiagnosticsView.swift" \
  || fail "on-device Top Shelf diagnostic refresh missing"
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
appex="$app/PlugIns/AutohopTVTopShelf.appex"
[[ -d "$appex" ]] || fail "embedded AutohopTVTopShelf.appex missing"
appex_info="$appex/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$appex_info" 2>/dev/null || true)" == "com.apple.tv-top-shelf" ]] \
  || fail "embedded extension has the wrong extension point"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$appex_info" 2>/dev/null || true)" ]] \
  || fail "embedded extension principal class missing"
asset_json="$(mktemp)"
xcrun assetutil --info "$app/Assets.car" >"$asset_json" 2>/dev/null \
  || fail "cannot inspect the compiled tvOS asset catalogue"
# Apple validates the flattened 1280x768 marketing rendition of the primary
# icon. A raw layer named "App Icon - App Store/Front/Content" is insufficient
# and was the reason multiple archives passed the old substring check but failed
# App Store validation with error 90471.
python3 - "$asset_json" "$primary_icon" <<'PY' \
  || fail "flattened 1280x768 App Store marketing icon is missing from Assets.car"
import json
import sys

entries = json.load(open(sys.argv[1], encoding="utf-8"))
primary_icon = sys.argv[2]
valid = any(
    entry.get("Name") == primary_icon
    and entry.get("Idiom") == "marketing"
    and entry.get("PixelWidth") == 1280
    and entry.get("PixelHeight") == 768
    and str(entry.get("RenditionName", "")).startswith("ZZZZFlattenedImage")
    for entry in entries
)
raise SystemExit(0 if valid else 1)
PY
rm -f "$asset_json"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
codesign -d --entitlements :- "$app" >"$tmp" 2>/dev/null || fail "cannot read signed entitlements"
env="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$tmp" 2>/dev/null || true)"
[[ "$env" == production ]] || fail "signed APNs environment is '${env:-missing}', expected production"
app_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$tmp" 2>/dev/null || true)"
[[ "$app_group" == group.com.kevinperry.autohop ]] || fail "signed tvOS app App Group is missing"
app_user_management="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.user-management:0' "$tmp" 2>/dev/null || true)"
[[ "$app_user_management" == runs-as-current-user-with-user-independent-keychain ]] \
  || fail "signed tvOS app current-user isolation is missing"
appex_entitlements="$(mktemp)"
codesign -d --entitlements :- "$appex" >"$appex_entitlements" 2>/dev/null || fail "cannot read extension entitlements"
appex_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$appex_entitlements" 2>/dev/null || true)"
appex_user_management="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.user-management:0' "$appex_entitlements" 2>/dev/null || true)"
rm -f "$appex_entitlements"
[[ "$appex_group" == group.com.kevinperry.autohop ]] || fail "signed extension App Group is missing or mismatched"
[[ "$appex_user_management" == runs-as-current-user-with-user-independent-keychain ]] \
  || fail "signed extension current-user isolation is missing"
grep -Eq '^- \[x\] Product owner physical-device sign-off' "$checklist" || fail "physical-device sign-off is incomplete"
echo "tvOS archive checks passed."
