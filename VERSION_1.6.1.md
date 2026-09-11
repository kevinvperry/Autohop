# Autohop Version 1.6.1 — Completed Release Ledger

<!--
AI CONTEXT — VERSION_1.6.1.md
Closed historical release ledger. User confirmed Version 1.6.1 approved and live
in the App Store on 8 September 2026. This is the confirmation date, not a claim
about Apple's exact approval timestamp. Preserve completed entries and historical
validation evidence. All future implementation, design, diagnostics, documentation
and user-visible changes belong in VERSION_1.7.md. Do not append new work here.
Originally labelled 1.7 during development; renamed 1.6.1 on 6 September for the
replacement iOS-family submission after the 1.6 metadata rejection. The independent
tvOS submission status is not changed by this iOS-family release confirmation.
-->

## Release status

- **Status:** Complete; ledger closed.
- **Approval:** Approved by Apple, confirmed by the user on 8 September 2026.
- **Release:** Live in the App Store, confirmed by the user on 8 September 2026.
- **Prepared iOS app/widget version:** 1.6.1 (17).
- **Future changes:** Record all new work in [VERSION_1.7.md](VERSION_1.7.md).
- Earlier preparation notes below are historical, not current submission status.

## Release metadata — 6 September 2026

Renamed the planned 1.7 ledger to 1.6.1 and updated living-document links and
historical audit pointers. Recorded the iOS 1.6 advertising rejection separately
from tvOS status. iOS app/widget versions are 1.6.1 (17), as requested by
the user following release preparation. XcodeGen regeneration
and release configuration validation pass. Combined customer release notes and
review notes are in [the submission record](Docs/AppStore/1.6.1/SUBMISSION.md).
No upload or submission performed. User confirmed the Mac Menu crash resolved;
the issue is complete (6 September 2026).

## App Store description refresh — 6 September 2026

Rewrote the full product description around automatic queueing, offline downloads
and per-show controls, incorporating completed 1.6.1 features. Retained platform
and publisher-advertising qualifications, clarified Shared Listening, and checked
the 4,000-character limit. Copy-ready text and search-positioning rationale live
in Docs/AppStore/1.6.1; companion AI context owns the header-free store payload.
No remote listing metadata was changed.

## Promotional text refresh — 6 September 2026

Added copy-ready promotional text highlighting automatic downloads, priority
playback, per-show audio, discovery, offline listening and device coverage.
Validated the 170-character limit; companion submission AI context owns the
header-free payload and records that promotional text does not affect search
ranking. No remote App Store metadata changed.

## Completed changes

### Downloads adaptive rows and standard swipes

- Follow-up layout correction: centre artwork vertically, give title/publisher/
  metadata the full adjacent column, and move media/status/re-download controls
  into a lower band. Preserve swipe and transfer behaviour. Signed iPad simulator
  build and whitespace checks pass; visual device validation remains outstanding.

- Validation: signed iPad simulator build and all eight QueueModelTests pass;
  diff whitespace checks pass. Native swipe gestures still need a device walkthrough.

- Replace custom scrolling section stacks with native List sections for swipes.
- Apply actual-width adaptive artwork targets, text and spacing to activity and
  archived rows. Replace inline Archive buttons with standard coloured Play,
  Play Next, Play Last and Archive swipes; disable full-swipe execution.
- Retain Pause/Resume/Retry/Re-download. Reuse existing download/archive/queue
  workflows, re-resolving episodes after download before play or pinning.
- Update source AI header and canonical documentation/project summaries.


### Search existing subscriptions

- Hide the full mini-player inset while inline search is focused; restore it on
  Done, Cancel or focus loss without affecting playback.


- Validation: signed iPad simulator build and whitespace checks pass after the
  inline-search revision.

- Add an icon-only search button beside Discover. The initial text-entry dialog
  was replaced with a rounded inline field below the page title.
- Filter real active/inactive shows locally by title/publisher on every keystroke,
  preserving ranks and ignoring surrounding whitespace. Provide Clear, Cancel,
  keyboard Done and no-results states.
- Keep filtering separate from reorder transactions; update the source AI header,
  canonical feature/page/design documentation and project summaries.

### Subscription episode row navigation

- Validation: signed iPad simulator build and whitespace checks pass.

- Remove the title's inline-expansion gesture/state. The full episode row now
  uses its existing NavigationLink to Episode Detail, with a rectangular hit area.
- Preserve both swipe-action blocks, compact previews and show-header expansion.
- Update source AI header and product/page/design references and project summaries.


### Responsive Episode Detail header

- Validation: signed iPad simulator build and diff whitespace checks pass.

- Scale artwork from 120–320pt using actual container width and matching cache
  target size, including iPad multitasking and resizable Mac windows.
- Centre the action group, with four columns or two at narrow widths; preserve
  state-dependent fourth-action semantics. Update AI headers and canonical docs.


### Onboarding cards: overlapping guidance and clipped buttons

- Hide Quick Tips across every host while first-subscription confirmation is
  presented, preserving page ownership and unseen state until dismissal.
- Start the first-subscription sheet at its large detent; pin Play/Add more shows
  below scrolling explanatory content so the action area is not cropped.
- Replace fixed container-relative tip height with a viewport minimum, permitting
  long content to scroll to its dismissal action. Inject the shared environment
  explicitly into the first-subscription presentation.
- Signed iPad simulator build and all four selected onboarding regressions pass.
- Add suppression/cancellation regression coverage and update source AI headers,
  onboarding/product/page/design references and the project summaries.


### Mac Menu dependency-boundary follow-up

- The user reports that the latest Mac TestFlight still crashes opening Menu;
  the earlier tip-only change did not establish resolution.
- Centralised existing app environment injection in AutohopApp.swift and applied
  it inside both Player and Subscriptions Menu presentation closures, supplying
  Menu, its mini-player and pushed destinations independently of inherited state.
- Added a complete Menu presentation integration test covering compact and regular
  layouts inside the desktop host. Updated affected AI headers and canonical docs.
- All 14 desktop tests pass after presentation-readiness waits were corrected;
  the signed Mac build succeeds.
- User confirmed the Mac Menu crash resolved on 6 September 2026; issue complete. See the
  [Mac implementation record](Docs/MAC_MENU_STAGE_1.md) for validation results.


### Discover, mini-player and Mac session — 6 September 2026

- Added category Top-8 rotating episode heroes above Top-100 shows, with show
  feature cards at ranks 8, 16, … 96; reused Discover's adaptive hero style.
- Fixed missing category artwork caused by JSON null bypassing the show cover.
  Retained show artwork as download-failure fallback and versioned category cache
  keys to refresh previously broken entries. All 10 artwork tests passed; all eight
  URLs in the sampled AU Comedy chart downloaded as images.
- Added mini-player coverage to Stats Top Shows → Show All, Add RSS Feed,
  Diagnostic Log, Release Radar Data, creator results and episode-search loading/
  unavailable states, avoiding duplicates on resolved Episode Detail.
- Implemented stage-one Mac application menus, discoverable shortcuts, typed
  navigation and scoped show/episode commands through existing workflows. Fixed
  disabled native menu items with sender-independent selectors and normal-window
  fallback. The persistent status icon/native Mac shell remains proposed.
- Fixed the TestFlight Mac Menu crash by explicitly passing the existing onboarding
  coordinator to all four Quick Tip overlays. The new regression and tip-policy
  tests passed. One combined-run navigation test failed, then passed in isolation;
  signed Mac builds succeeded. Physical Mac flow verification remains outstanding.
- Reconciled canonical docs and source/test AI headers for this session, including
  stale category depth/cadence references. No release/upload is claimed. See the
  [session record](Docs/SESSION_CHANGES_2026-09-06.md) and linked audits for evidence.


### Onboarding-tip dismissal and Feed Filter visibility

- Removed the redundant top-right close icon from Quick Tip cards. The single
  full-width **Got it — close tip** button is now the only explicit dismissal.
- Preserved child tip requests across NavigationStack appearance/disappearance
  ordering, preventing the Download Feed Filters tip from being discarded while
  the parent Podcast Settings tip is being cancelled.
- Added a coach-mark host above the Player/Up Next Podcast Settings presentation,
  so Podcast Settings and Download Feed Filters guidance cannot render behind
  that system sheet.

### Stats integrity and coverage redesign

- Preserved the existing **7 Days** label and its intentional Monday-to-now
  calendar-week behavior.
- Replaced media-position delta accounting with backend-confirmed rendered
  intervals on iOS and tvOS. Trim Silence, seeks, skips, playback speed and
  delayed callbacks can no longer inflate or discard listening time.
- Hardened Stats and Listening History JSON with explicit file protection,
  checksummed generation envelopes, last-known-good backups, corruption
  quarantine and locked-launch write blocking. Startup reconciles JSON and
  SQLite by generation/revision/hash, backfills missing projections, and can
  recover missing local days from the installation's own CloudKit partition.
- Moved the tvOS-authored database and Stats JSON from purgeable Caches to
  Application Support with copy-before-open migration. Render-only projections
  and CloudKit transport state remain caches.
- Replaced backup-restorable Stats partition identity with a ThisDeviceOnly
  Keychain installation ID, retaining old identities only as inherited lineage;
  scoped cached remote rows and sync state to the active iCloud account.
- Made completed-download accounting immediately durable and exposed JSON
  backup/import, CSV export, recorded/pending/remote day health, save/sync times
  and recovery status.
- Added calendar/time-zone-aware hour and midnight attribution, canonical show
  identity across unsubscribe/resubscribe, and durable idempotent episode
  outcomes independent of capped resume history. Duplicate terminal events are
  counted once across callbacks and device partitions.
- Made history sync preserve accumulated listening and strongest terminal
  outcomes when a newer resume snapshot contains smaller totals; only the
  merged newer navigation state may move the player.
- Matched tvOS episode-start accounting to iOS fresh-start semantics.
- Clarified that streak is all-time, made the privacy copy reflect whether
  iCloud Sync is enabled, and added visible disclosures for forward-only metrics
  and partially overlapping legacy data.
- Updated every affected source/test AI header plus the canonical product,
  design, page, sync, tvOS architecture and historical-audit documentation.

### Multi-release feed downloads

- Fixed feed refreshes that detected several new episodes but automatically
  downloaded only the newest one. Every newly observed episode that passes the
  podcast's Download Filters is now selected newest-first up to Episode Limit;
  No Limit selects the complete new batch.
- Persisted all selected download intents before asynchronous work begins and
  process them sequentially. Each exact episode is revalidated and transferred,
  preventing concurrent “newest candidate” checks from discarding the second
  release in a closely published pair.
- Preserved the existing storage contract: older catalogue entries are not
  backfilled, existing automatic downloads rotate to make room, and manual
  downloads, active playback and user-positioned queue items remain protected.
- Added regression coverage for multi-episode scans under limit 10, bounded
  limits and No Limit, plus exclusion of downloaded and completed episodes.

### Playback completion and Up Next integrity

- Fixed the 30-second forward-skip boundary across the main Player, compact
  mini-player and Menu player. When the requested skip reaches or crosses the
  end of the current episode, every surface now enters the same completion
  transaction instead of advancing the queue directly.
- Completion now clears the saved resume point and commits the episode's
  terminal subscription state before any asynchronous media deletion. This
  prevents the next episode from starting while the previous episode remains
  in Up Next at its old playback position.
- Podcasts configured with the default **After Playing** Auto Archive rule now
  settle the completed episode as archived immediately. Podcasts using a
  delayed or disabled After Played rule continue to retain the appropriate
  played state.
- Added regression coverage for both immediate-archive and retain-as-played
  completion policies.
