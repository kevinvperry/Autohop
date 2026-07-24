# Autohop Whole-Project Assessment — 2026-07-24

<!--
AI CONTEXT — ASSESSMENT_2026-07-24.md
Current source-based engineering, product, interface, sync, privacy, security,
documentation, onboarding, iOS and tvOS assessment. This is a point-in-time
review, not a behavioural source of truth. Re-locate every symbol and re-check
the current implementation before applying a recommendation. FEATURES.md owns
behaviour/defaults, PAGES.md owns visible names/navigation, DESIGN.md owns visual
patterns, SYNC_DESIGN.md owns CloudKit, and VERSION_1.4.md owns the post-1.3
implementation ledger. Internal `Queue*` names are intentional legacy symbols;
the visible page name is Up Next.
-->

## 1. Executive assessment

Autohop is a capable, unusually well-instrumented podcast player with a coherent
download-first product model. The current architecture is substantially stronger
than the historical reports imply: AppState has been decomposed into domain
coordinators/workflows, feed selection and parsing have bounded recovery paths,
download intent is durable, background scheduling avoids the moving-horizon
replacement bug, CloudKit writes use explicit conflict policies, and source files
already carry extensive machine-oriented context.

No embedded production secret, advertising tracker, behavioural analytics SDK,
or obvious credential leak was found. The highest remaining risks are not
emergency defects. They are compatibility/security trade-offs around arbitrary
HTTP feeds, conflict limitations in whole-list sync records, oversized source
units that increase regression risk, accessibility and layout consistency gaps,
and public wording that can accidentally over-promise background execution.

The checked-in shipping configuration is **iPhone Version 1.3 build 4**. The
repository also contains implemented Version 1.4 work and development-gated
tvOS, Autohop Pro, and Relay code. Documentation and public website claims must
continue to distinguish “implemented in source” from “available in the App
Store.”

## 2. Scope and method

The review covered:

- 216 Swift source/test files (approximately 69,000 lines), project generation
  settings, plists, entitlements, privacy manifests, assets and StoreKit config.
- iPhone navigation, Player panels, Up Next, Priority, Discover/Search, podcast
  and episode detail, Settings, per-podcast Settings, Downloads, History, Stats,
  widgets, CarPlay, onboarding, notifications, audio and video playback.
- tvOS browse, search, library materialisation, Up Next, playback and CloudKit/
  Relay development paths.
- feed parsing/repair, refresh selection, background tasks, URLSession downloads,
  persistence, diagnostics, artwork caching, auto-archive and Play Instant.
- CloudKit data projections, conflict resolution, queue/order singletons,
  materialisation, private-data boundaries and device-local exceptions.
- the six canonical documents requested, onboarding plans, the in-app Support
  model, and the Autohop features/support/privacy/intelligence website pages.

This was static review plus build/test verification. Exact energy impact,
background scheduling frequency, route stability and memory peaks still require
physical-device traces; iOS controls background launch opportunities and a
source review cannot guarantee their timing.

## 3. Changes made during this assessment

- Added the missing AI CONTEXT header to
  `Tests/RefreshStatsPersistenceTests.swift`; all Swift files now have machine
  context or are generated/project artefacts.
- Updated stale user-facing Queue-page language to **Up Next** while retaining
  internal Queue type, database, log and sync names.
- Clarified global Downloading copy: background starts and feed checks are
  opportunistic under iOS, not guaranteed timers.
- Clarified per-podcast automation copy: Inactive feeds move to the bottom, are
  excluded from automatic/Refresh All checks, but retain explicit single-feed
  refresh.
- Added Feed/Copy Link explanatory copy.
- Revalidated and updated README, DESIGN, FEATURES, PAGES, SYNC_DESIGN and
  project_autohop; linked this report as the current assessment.
- Corrected website privacy and Intelligence claims, replaced stale Queue-page
  naming, prioritised Release Radar near the top of the feature list, removed
  absolute background promises, and removed the stale hard-coded Support version.
- Added section-level AI context to the public Autohop pages and generated
  `llms.txt` facts that distinguish local learning from optional private iCloud.
- Added website response hardening: CSP, MIME sniffing protection, referrer
  policy, permissions policy and frame-ancestor blocking.

## 4. Architecture and performance

### P1 — High: physical-device background and energy validation remains essential

The design now has separate BGAppRefresh, power-required BGProcessing,
background-audio refresh and foreground/manual paths. Recent fixes address
moving-horizon scheduling, feed starvation, parse amplification, transfer retry
resurrection and watchdog double-cancel. That is strong implementation work, but
no code can force iOS to launch a suspended app.

Recommendation: maintain a repeatable device matrix covering unplugged audio,
locked screen, Wi-Fi/cellular transitions, Low Power Mode, thermal pressure,
charging overnight and large backlogs. Report feed age, selected/deferred counts,
successful material changes, transfer starts/completions, CPU, footprint and
battery delta by execution context. Product copy must say “when iOS grants
background time,” never “every N minutes.”

### P2 — Medium: several source units remain too large

`Models/Subscription.swift`, `Views/PlayerView.swift`,
`Playback/PlaybackEngine.swift`, `Persistence/SubscriptionStore.swift`,
`Views/StatsView.swift`, `Persistence/CloudSyncEngine.swift`,
`Views/SubscriptionSettingsView.swift`, `App/FeedRefreshCycleWorkflow.swift`,
`Downloads/DownloadManager.swift`, `Views/SettingsView.swift` and the tvOS app
model remain large. Their comments are good, but size increases merge conflict,
compile and regression surface.

Recommendation: use behaviour-preserving extractions only. Split rendering
subviews from state owners; split Codable models by domain extension; extract
audio route, graph and metadata helpers behind tested protocols; split tvOS
CloudKit/materialisation, Relay and playback ownership. Do not create a second
parallel state model or re-aggregate the coordinators into AppState.

### P3 — Medium: manual refresh and large-feed regression budgets need automation

The parser now limits retained episodes, uses conditional requests, streams
malformed-ampersand repair, records growth/repair metrics and quarantines repeated
high-memory feeds. Those fixes should be protected by performance fixtures.

Recommendation: add deterministic 3–10 MB malformed feeds, 10,000-item feeds,
large descriptions and entity-heavy XML to CI. Assert retained item caps, peak
temporary bytes where measurable, cancellation, quarantine persistence and
conditional-request behaviour. Keep the deliberate 74-feed device test in the
release checklist.

### P4 — Medium: background transfer decisions must stay generation-safe

The watchdog now has generation/decision guards and rechecks task progress, while
durable episode/host cooldowns prevent refresh resurrection. Future edits could
easily reintroduce duplicate cancellation or clear a newer retry state.

Recommendation: preserve “one terminal decision per task generation,” require a
post-`getAllTasks` progress/completion check, and add stress tests for delegate
delivery after process suspension. Manual user action may bypass cooldown;
ordinary four-minute refresh must not.

### P5 — Low: use instrumentation selectively

Diagnostics are comprehensive, redacted and gated, but verbose refresh tracing,
resource sampling and main-thread watchdogs alter the system being measured.

Recommendation: keep normal diagnostics low-volume, retain trace as an explicit
short-lived mode, show trace state prominently, and include build/configuration
metadata in every export. Do not add analytics to solve an observability problem.

### P6 — Low: one Accelerate call uses a deprecated interface

The verified iOS build reports `cblas_scopy` in `PlaybackEngine.swift` as
deprecated since iOS 16.4 because Accelerate provides an updated ILP64-capable
CBLAS interface. It still compiles and the current frame counts are far below
32-bit limits, so this is maintenance debt rather than a playback defect.

Recommendation: adopt the current Accelerate compile definitions/interface in a
separate audio regression change, then compare mono duplication, route changes,
Trim Silence and Vocal Boost on device before removing the old call.

## 5. Reliability and correctness

### R1 — Medium: whole-record sync domains can overwrite concurrent edits

Priority order and Up Next are intentionally coherent whole-list LWW records.
That avoids mixed generations but means two devices editing the same list
concurrently cannot merge; one complete generation wins.

Recommendation: document this precisely in user support. Keep deterministic
generation/timestamp tie-breaking and stale-ack protection. If concurrent editing
becomes common, consider an operation log for manual pins/order edits, but only
with tombstones and bounded compaction; do not casually field-merge an ordered
list.

### R2 — Medium: global app settings and Release Radar learning are device-local

Most per-podcast settings, subscriptions, order, history, position, Stats and Up
Next roam. Global defaults, network preferences, onboarding state and learned
refresh observations do not. This is defensible—network and launch preferences
can be device-specific—but “all settings sync” is false.

Recommendation: keep the explicit sync matrix in SYNC_DESIGN and Support. If
global settings are later added, classify each as roamable or device-specific
instead of syncing the entire AppSettings blob.

### R3 — Medium: old played/archived key history remains a migration limitation

CloudKit episode records and current Up Next filtering protect active surfaces,
but historic pre-projection played/archive key sets are not a clean cross-device
set merge. Union would prevent removals; LWW could lose concurrent additions.

Recommendation: leave unchanged until semantics are chosen. A compact
per-episode event/tombstone model is safer than syncing two mutable sets.

### R4 — Low: multiple-scene declaration should be intentional

The plist declares multiple scene support while playback, downloads and many
coordinators are process-singleton services.

Recommendation: either test two simultaneous windows and define route/editor
ownership, or disable multiple-window presentation. Avoid implying independent
players per scene.

## 6. Security and privacy

### S1 — Medium: global ATS exception is a real compatibility trade-off

iOS and tvOS set `NSAllowsArbitraryLoads=true` so legacy HTTP podcast feeds and
media remain usable. The project comments correctly explain why granular media
exceptions do not cover RSS. This permits clear-text requests and broadens the
network attack surface.

Recommendation: prefer HTTPS, visibly warn before adding an HTTP feed, never send
credentials/tokens over HTTP, reject URL user-info, and consider blocking
loopback/link-local/private-network hosts unless the user explicitly confirms a
local feed. Keep Relay, CloudKit and Apple endpoints HTTPS-only. Reassess whether
the remaining HTTP feed population still justifies the global exception each
release.

### S2 — Medium: development APNs entitlements must be release-validated

Checked-in entitlements use `aps-environment=development`. Signing can replace
this for distribution, but an archive mistake would silently break push-related
development features.

Recommendation: add an archive CI/release check that inspects the signed
entitlements and fails if the App Store artifact is not production. Because Relay
is gated off in the current release, do not describe developer-operated push as a
shipping dependency.

### S3 — Medium: Relay entitlement verification is not production-ready

The source header explicitly notes that server-side App Store transaction JWS
verification is currently a decode-only placeholder. The feature gates prevent
production use, which is the correct control.

Recommendation: never enable Pro/Relay in production until the server verifies
the complete Apple certificate chain, bundle/product/environment, signed date,
revocation/expiry and transaction status. Rotate/revoke device credentials and
rate-limit registration/nudges.

### S4 — Low: diagnostics remain potentially sensitive even when redacted

Feed hosts, episode/show titles, timing and behavior can reveal listening habits.
The logger redacts credentials and exports only on user action, but exported files
leave the app sandbox.

Recommendation: keep titles bounded, maintain token/query redaction tests, explain
the sensitivity before sharing, and avoid copying full feed URLs with secrets to
logs. The new Feed Copy Link action is explicit user intent and is appropriate.

### S5 — Website hardening applied

The generated Worker previously returned content/cache headers only. It now adds
CSP, `nosniff`, referrer policy, permissions policy and `frame-ancestors 'none'`.
The CSP allows current inline styles/scripts and the contact form target; reduce
`unsafe-inline` if assets are later externalised or hashed.

## 7. Design, layout and accessibility

### U1 — Medium: Settings information density is high

The global and per-podcast Settings pages are coherent but long. Global Settings
mix runtime controls, defaults, library management, storage, contact and hidden
diagnostics. Per-podcast Settings mixes identity, filters, DSP, automation,
archive, chapters and feed maintenance.

Recommendation: retain current labels/defaults, but consider stable subpages for
Playback Defaults, Automation/Background and Data/Sync. Keep frequently changed
controls near the top and destructive actions last. Search is preferable to more
collapsed disclosure if the list grows.

### U2 — Medium: Dynamic Type and text fit need a dedicated pass

Many polished surfaces use fixed system point sizes and fixed card geometry.
That is appropriate for transport icons but can truncate titles, metadata pills,
settings explanations and Stats labels at accessibility sizes.

Recommendation: use semantic fonts for body/settings text, `@ScaledMetric` for
deliberate geometry, allow multiline labels, and test the two largest Dynamic
Type categories plus Bold Text, Button Shapes and Increased Contrast. Preserve
minimum 44-point hit targets.

### U3 — Medium: visual consistency spans three systems

iOS 17–25 uses dark translucent cards, iOS 26 uses system glass, and tvOS has
focus-driven cards. The code already centralises many components, but custom
cards and native Form rows can still resolve at different shades and spacing.

Recommendation: continue using named DESIGN patterns and shared components.
Create snapshot/reference captures for Player, Priority, Up Next, Settings and
Podcast Settings on iOS 17 and iOS 26, plus focused/unfocused tvOS. Avoid adding
one-off blur/material recipes.

### U4 — Low: page naming is now consistent

The visible playback-order page is **Up Next**. Generic prose may describe a
playback queue, and internal `QueueSheetView`, QueueSnapshot, database keys and
diagnostic event names remain valid. Future user-facing IDs, accessibility labels
and deep links should use `up-next`.

### U5 — Medium: tvOS is a development companion, not parity UI

tvOS intentionally has fewer controls and relies on synced library/Up Next data.
It should not be documented as feature parity with iPhone. A television is also
poorly suited to configuring dense per-podcast rules.

Recommendation: define an explicit tvOS support matrix: browse/search, play,
resume, Up Next and basic transport on TV; configuration on iPhone. Add empty,
signed-out, CloudKit-unavailable and stale-snapshot states before release.

## 8. Onboarding assessment

The current onboarding reflects the product:

1. A true new user with no real subscriptions sees the Welcome carousel.
2. It teaches subscribe/download/Up Next, per-podcast audio controls, Sleep
   Schedule and Shared Listening.
3. Find Shows, OPML import and explore-without-import routes are available.
4. Existing users are reconciled without being forced through Welcome.
5. The first deliberate single subscription presents the “You’re all set” card,
   ensures the newest episode is downloading, and starts playback only after the
   user taps Play; bulk imports remain quiet.
6. Empty states, at most three coach marks per session and the Getting Started
   checklist provide progressive help without launch-time permission prompts.

Release Radar scheduling is automatic; there is no current user-facing Radar
sensitivity control. Recommended refinements: add a short optional “How
background updates work” support link after the first subscription, not another blocking card; test Voice
Over reading order and large text; ensure import summaries never trigger the
single-show card; and keep screenshots/copy synchronized with Player panel and
Up Next terminology. Do not promise exact background times.

## 9. Menu and settings copy assessment

Current global groups—Startup, Release Radar, Auto Archive, Downloading,
Controls, Default Playback, Default Episode Trim, Subscriptions, Sync, Storage,
Contact, About and hidden Diagnostics—match the code. Current per-podcast
groups—Podcast, Download Feed Filters, Playback, Episode Trim, Automation, Auto
Archive, Chapter Filter, Feed and Unsubscribe—also match.

Descriptions were corrected where behavior was easy to misread:

- Background checks/transfers are best effort under iOS.
- Excluding a podcast affects automatic and Refresh All selection, but explicit
  single-feed refresh remains.
- Inactive timing starts from download activity, not publication date.
- Filter rules affect automatic downloads; manual actions remain available.
- Feed Copy Link copies the publisher RSS URL.
- iCloud Sync covers the documented matrix, not every global preference or media
  file.

## 10. Website assessment

The features page now leads with the product-defining Priority Stack and Release
Radar, then the strongest automation/audio tools. It does not present tvOS, Pro
or Relay as shipping. Background behavior is qualified by iOS execution policy.

Support uses Up Next consistently as the page name, has no stale hard-coded app
version, and explains current settings. Privacy now distinguishes:

- developer collection (no account, ads or behavioral analytics),
- necessary requests to Apple, feed, artwork and media providers,
- optional private CloudKit sync,
- local diagnostics and user-initiated export.

Intelligence now distinguishes on-device Release Radar learning from listening
records that can roam through optional private iCloud. Absolute “never leaves
this device” and “never configure it” claims were removed. Every major public
Autohop section has an AI CONTEXT comment, and `llms.txt` carries the same
boundaries.

## 11. Prioritised next work

1. Run the physical-device background/energy matrix and set budgets by execution
   context; avoid tuning from one anecdotal capture.
2. Add archive-time entitlement checks and keep Pro/Relay disabled until
   transaction verification is cryptographic and complete.
3. Add malformed/large-feed memory fixtures and watchdog-generation stress tests
   to CI.
4. Decide whether unsupported multiple-window behavior should be disabled or
   fully tested.
5. Perform Dynamic Type, VoiceOver, contrast and tvOS focus audits with reference
   screenshots.
6. Add explicit HTTP-feed warning/private-network policy while preserving legacy
   feed compatibility.
7. Continue small, tested extractions from the largest files; do not perform a
   broad architecture rewrite.
8. Keep public docs and VERSION_1.4 updated in the same change as every
   user-visible behavior/default.

## 12. Release gate

Before the next public build:

- build iOS and tvOS schemes from a clean generated project;
- run the full test suite and website generator/syntax checks;
- inspect signed production entitlements and privacy manifest;
- exercise fresh install, existing-user upgrade, OPML import, first subscription,
  iCloud off/on, two-device conflict, HTTP/HTTPS feed, locked-screen audio,
  unplugged background refresh, large malformed feed, CarPlay and widget actions;
- compare website/support/privacy claims against the exact release feature gates;
- update MARKETING_VERSION/build number only when the release scope is decided.
