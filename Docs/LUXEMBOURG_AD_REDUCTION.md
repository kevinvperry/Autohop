# Luxembourg ad reduction implementation — 24 October 2026

## Backup

Pre-implementation source snapshot: `06eb2004c5650da8396708bd25b33a6fcd0d76a4`, pushed to `origin/codex/backup-before-luxembourg-filter-2026-10-24` and verified using `git ls-remote`. Includes the previously uncommitted release/support changes and untracked App Store documentation. Generated build caches and ignored local Xcode state are not source backups.

## Implemented

- Off-by-default local settings, backward-compatible decoding and explicit public-show selection.
- Configurable HTTPS relay setup/check and non-synchronising device Keychain credentials.
- Both durable and active-runtime audio-download routing with canonical identity preserved. Unselected shows, video and credential-bearing source/feed URLs remain direct. Private tokenised feeds require user exclusion; the app cannot infer their privacy reliably.
- Relay response identity/final-URL checks, no silent direct fallback and restart-only transfers. Transport failures use existing bounded retry handling.
- Completed-file receipts, delivery labels, explicit normal-download action and replacement confirmation. Replacement clears saved playback position; external chapter alignment is not guaranteed.
- Relay media duration validation in foreground and after app-relaunch completion.
- Deployable dependency-free Node server: authentication, redirect-local fetching, validated and pinned DNS, local-network/metadata protection, streaming limits, per-token concurrency/start limits and disabled-by-default operation. Docker Compose with Caddy TLS and deployment/egress verification instructions.
- Support/privacy wording updated. Server deployment files excluded from the app target.

## Validation

- Node relay tests: **7 passed** (authentication/disabled state, streaming bytes, range rejection, request quotas, unsafe destinations, malformed input and method handling).
- Signed iOS 27 Simulator tests: **36 passed, 0 failed, 0 skipped**, including DownloadDeliveryTests, DownloadResponseValidationTests and AppSettingsDefaultsTests. Built on iPhone 18 Pro Simulator. Final result: `/tmp/autohop-luxembourg-build/Logs/Test/Test-Autohop-2026.10.24_09-09-42-+1100.xcresult`.
- `git diff --check` passed.
- An earlier unsigned Simulator test attempt could not launch the CloudKit-enabled host; the signed run above supersedes it.

## Not yet verified / deployment requirements

No Luxembourg server or proxy was available. No endpoint has been provisioned, no Luxembourg egress or actual ad reduction has been measured, and no physical-device/background lifecycle or UI visual validation is claimed. See `Relay/luxembourg/README.md` for provisioning, privacy, token management, costs and a controlled regional evaluation. This feature must remain opt-in/experimental until those checks are complete. A public release additionally needs installation enrolment and durable quota/revocation controls; the supplied server uses manually provisioned individual beta tokens.
