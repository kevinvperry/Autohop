# Autohop Project Brief

<!--
AI CONTEXT — project_autohop.md
Machine-oriented project brief created during the 2026-06-28 deep scan and
revalidated against the current source on 2026-09-04 after the Stats integrity
redesign. Use this
as a fast orientation file before reading the canonical docs. Do not treat it as
the source of truth when it conflicts with code: FEATURES.md owns product
behaviour, PAGES.md owns navigation/page names, DESIGN.md owns UI patterns,
SYNC_DESIGN.md owns iCloud sync. ASSESSMENT_2026-08-30.md is the latest
whole-project audit snapshot, but Version 1.6.1 source and living documents
supersede it where later work changed behavior. Keep this brief refreshed when recent UI or sync behaviour
changes so future AI agents do not inherit stale summary assumptions.
Priority Stack ordering is one UUID-addressed `SubscriptionOrder` generation,
not a set of independently authoritative `priorityRank` fields. Reorder UI drafts
active real IDs locally and commits once.
The repository contains the full iPhone and Apple TV targets. Cross-device sync
uses only the user's private iCloud account; the abandoned Autohop Pro and
Cloudflare relay prototypes have been removed.
The tvOS rebuild now renders compact purgeable Library/queue projections while
keeping its authored database and Stats JSON in durable Application Support,
streams self-contained phone-authored queue entries, loads podcast details in
bounded targeted requests, and exposes diagnostics. Automated Phase 6 gates are
present. The tvOS Version 1.6 build 13 was submitted to Apple App Review on
22 August 2026, and the iOS-family Version 1.6 build 10 was submitted on
30 August 2026. iOS 1.6 was rejected for advertising metadata; 1.6.1 is now
approved and live, confirmed by the user on 8 September 2026. tvOS approval/public release remains unconfirmed.
AppState decomposition Stages 0–14 are implementation-complete as of
2026-07-19. Domain coordinators and named workflows exclusively own
history/Stats, queue, onboarding, typed routing, downloads, feed refresh/Release
Radar, durable auto-download intents, Auto Archive, subscription import,
private iCloud sync, playback, chapters, media, runtime policy, and startup.
AppState is only the process singleton, composition root, and stable high-level
platform/UI façade. AppLifecycleCoordinator owns startup state and every
retained lifecycle/maintenance task; AppStartupWorkflow owns ordered graph
connection, migrations, restoration, and service startup.
Release update (2026-09-06): user confirmed Mac Menu crash resolved; issue closed.
User confirmed iOS-family 1.6.1 approved and live on 8 September 2026.
Its ledger is closed; all future changes belong in VERSION_1.7.md.
TV 1.6.1 (1) submitted for approval, user-confirmed 8 September 2026.
All future iOS/tvOS code changes belong together in VERSION_1.7.md.
Screenshot confirms prior TV 1.6 (15) Ready for Distribution.
-->
## tvOS release update — 8 September 2026

The user’s screenshot confirms tvOS 1.6 (15) Ready for Distribution; older
build-13 submission references below are historical. tvOS 1.6.1 (1), including
Top Shelf, is now submitted for approval (user-confirmed 8 September 2026). iOS remains 1.6.1 (17). Submission text and
validation are in [the TV package](Docs/AppStore/tvOS-1.6.1/SUBMISSION.md).
Approval of TV 1.6.1 is pending. All future iOS and tvOS code updates are
tracked together in VERSION_1.7.md; the submitted TV release scope is closed.


## Current release — 8 September 2026

Version 1.6.1 is approved and live in the App Store, confirmed by the user.
Its release ledger is complete. All future changes belong in
[Version 1.7](VERSION_1.7.md). Earlier preparation notes below are historical.

## Version 1.6.1 resubmission preparation — 6 September 2026

The iOS 1.6 rejection concerns Advertising age-rating metadata. The replacement
1.6.1 combines both release ledgers. Copy-ready release/review text and outstanding
checks are in [the submission record](Docs/AppStore/1.6.1/SUBMISSION.md).
Preparation is not an upload, submission or approval.

## Downloads list update — 6 September 2026

Artwork is centred vertically; full-width text sits above a separate lower status
band, matching the subscription-list hierarchy.

Downloads now uses shared adaptive episode-row sizing and native Play, Play Next,
Play Last and Archive swipes. Transfer controls remain inline; archive buttons
are removed. See [feature reference](FEATURES.md).

## Subscription search — 6 September 2026

The mini-player hides while subscription search has focus and returns when editing
ends, freeing room for results without interrupting playback.

The magnifying glass beside Discover searches existing subscriptions by show or
publisher name through an inline field. Results preserve priority order;
Clear restores all shows. See [feature reference](FEATURES.md).

## Podcast episode navigation update — 6 September 2026

Episode rows on the subscription page now open Episode Detail from the whole
row, including its title. Inline episode expansion is removed; swipe actions
are unchanged. See [page reference](PAGES.md).

## Episode Detail layout update — 6 September 2026

Episode artwork now scales with the available window width, and playback/queue/
archive actions are centred beneath the header. See [design reference](DESIGN.md).

## Onboarding presentation update — 6 September 2026

Quick Tips hide while the first-subscription milestone is open. That sheet now
keeps its actions below scrolling content, and long Quick Tips can grow and
scroll within their actual viewport. See [onboarding reference](ONBOARDING.md).

## September Discover and Mac implementation

Menu now receives appEnvironment(appState) inside both presentation closures;
bootstrap uses the same helper. The user reports the prior tip-only fix was
insufficient; obtain the current Mac crash report before declaring resolution.

Category charts display Top-8 episode heroes above Top-100 shows (show feature
ranks 8, 16, … 96). Episode art falls back to channel art on absence or load failure;
Apple JSON null must be decoded before choosing a fallback. Mac application menus
use DesktopCommands and DesktopCommandContext, with AppDelegate selector fallback
and RootView typed navigation. Keep a single AppState and reuse existing workflows.
The status icon/native Mac shell remains planned. Mini-player coverage and explicit
Quick Tip presentation dependencies were corrected across the shared iOS-family UI.
See the [session implementation record](Docs/SESSION_CHANGES_2026-09-06.md) for
file ownership, tests and device-validation limits.

## Identity

Autohop is a native Swift/SwiftUI iPhone podcast player for serious listeners.
Its central model is a download-first, priority-ranked automatic playback queue:
users rank subscriptions in the Priority Stack, Autohop keeps eligible episodes
downloaded, and the visible **Up Next** sheet shows what will play after the
current episode. Internal Swift names still include `QueueSheetView` and
`downloadedQueue`.

## Architecture Snapshot

The iPhone and Apple TV applications are separate targets in the same generated
project. Both synchronize exclusively through the user's private iCloud account.

- App framework: SwiftUI, iOS 17+, Xcode project generated by XcodeGen from `project.yml`.
- Composition: `App/AppCompositionRoot.swift` constructs the protocol-backed
  production graph. `AppState.bootstrap()` publishes one process singleton and
  invokes an explicit idempotent `start()`; constructed/starting/started/stopped
  are visible lifecycle states. `App/AppStartupWorkflow.swift` connects the
  already-constructed graph and performs ordered migrations, restoration,
  service startup, Radar warm-up, and launch maintenance. Dedicated coordinators
  and workflows own all domain behavior; AppState retains only side-effect-free
  compatibility projections and high-level platform/UI commands.
- Extracted application owners:
  `App/HistoryStatsCoordinator.swift` owns tick/history/Stats/checkpoint work;
  `App/QueueCoordinator.swift` owns the downloaded queue, pins, Up Next, badge,
  and changed-only queue snapshots; `App/OnboardingCoordinator.swift` owns
  first-run/milestone/tip/toast policy; `App/AppRoutingCoordinator.swift`
  provides typed commands while RootView retains its NavigationPath.
- Persistence: GRDB/SQLite through `Persistence/AutohopDatabase.swift` and
  `Persistence/SubscriptionStore.swift`; app settings are JSON through
  `Persistence/SettingsStore.swift`. Stats and Listening History use protected,
  checksummed JSON envelopes with last-known-good backups, corruption quarantine,
  SQLite reconciliation, and locked-launch write blocking.
- Playback: `App/PlaybackCoordinator.swift` owns the engine-facing session,
  PlaybackClock, sleep services, Play Instant state, and episode generation;
  DSP and transport remain in `Playback/PlaybackEngine.swift`.
- Feeds: RSS parsing/loading in `Feeds/`; pure immutable candidate planning is in
  `Feeds/ReleaseRadarCyclePlanner.swift`; `App/FeedRefreshCoordinator.swift`
  owns refresh-cycle state and planning. Diagnostics live in
  `Views/FeedRefreshScheduleView.swift`
  / `Views/SubscriptionRadarDiagnosticsView.swift`.
- Diagnostics: `Logging/AppLogger.swift` owns bounded normal/verbose persistence.
  Normal foreground/background refresh evidence is cycle/outcome based
  (`feed.refreshAll.plan`, `feed.cycleSummary`, `background.wakeSummary`);
  detailed per-feed traces require the explicit local setting. Full CPU/thread
  sampling and the UI watchdog run only during an enabled diagnostic session;
  `ResourceMonitor` otherwise retains a sparse, log-free footprint safety check.
- Downloads: `Downloads/DownloadManager.swift` uses a background URLSession and
  validates response status, MIME type, and implausibly small files before moving
  media into the local downloads directory. Narrow UI progress is isolated in
  `Downloads/DownloadProgressModel.swift`.
- Playback projections/cues: `Playback/PlaybackClock.swift` owns high-frequency
  elapsed time and `Playback/PlaybackCueService.swift` generates the existing
  Play Instant warning WAV without owning playback state.
- History: `Persistence/ListeningHistoryStore.swift` owns protected local
  listening-history JSON and its sync projection. Remote application is
  field-aware: newer navigation wins while accumulated listening and strongest
  terminal evidence remain monotonic. HistoryStatsCoordinator owns its iOS
  orchestration, rendered-interval accounting, and lifecycle checkpoints.
- Sync: `App/SyncCoordinator.swift` owns private CloudKit lifecycle, callbacks,
  and remote materialization over `Persistence/CloudSyncEngine.swift`. The
  durable schemas remain in
  `Persistence/CloudKitSyncMapping.swift`. Record types are `EpisodeState`,
  `SubscriptionState`, `SubscriptionOrder`, `HistoryEntry`, `DayStats`, and the
  existing queue singleton. Stats partitions carry generation/revision/hash,
  inherited device lineage and durable episode outcomes. `SubscriptionOrder` stores the real-subscription UUID
  list atomically; delayed save acknowledgements clear only matching field/order
  versions.
- CarPlay: read-only/downloaded playback surface in `CarPlay/`, sharing the same
  playback, Up Next, archive, speed, and shared-listening state as the iPhone app.
- Widgets: `WidgetSnapshotCoordinator` publishes a versioned, display-only,
  hash-deduplicated App Group snapshot and bounded JPEGs. `AutohopWidgets`
  renders without networking/database access. `PlayAutohopEpisodeIntent`
  revalidates stable identity through the live store and delegates to existing
  playback transport; `WidgetDeepLinkParser` emits typed navigation commands.

## Current Feature Map

- First-run onboarding: Welcome carousel, OPML import, Starter Packs, first-subscribe
  "You're all set" sheet, getting-started checklist, and coach marks.
- Discovery: Apple Podcasts charts, country picker, Top Episodes, Top Podcasts,
  Top-8 episode carousels followed by Top-100 shows for every displayed category,
  search, direct RSS add, and Recently Viewed browse subscriptions.
- Listening: download-first playback, Trim Silence, Vocal Boost, per-podcast speed
  and −3…+3 dB volume adjustment,
  start/end skip, shared debounced trim-control rows in both Podcast Settings and
  Default Playback, chapter filtering, audio/video playback, privacy-safe
  episode and podcast share cards, sleep
  timer, sleep schedule, Now Playing, and lock-screen/Control Centre commands.
- Player resume polish: the scrubber now synchronises to the restored playback
  clock on first render, so partially played episodes open with the correct thumb
  position as well as the correct elapsed/remaining labels.
- Organisation: Priority Stack with stable multi-move reorder sessions, Up Next,
  Play Next, Play Last, archive/unarchive, per-podcast settings, per-podcast
  Download Filters, auto-archive, listening history, and Stats. Stats preserves
  the **7 Days** label for its intentional Monday-to-now range, uses
  backend-confirmed rendered wall time, canonical feed identity and durable
  deduplicated episode outcomes, and exposes coverage/health plus JSON/CSV export.
- Background work: cooperative-deadline BGAppRefreshTask + BGProcessingTask feed refresh,
  Release Radar protected background slots, foreground polling, adaptive seven-feed
  background-audio cycles every four minutes (urgent hard ceiling ten), and background
  URLSession media downloads.
- BGAppRefresh uses an eight-feed protected base batch and may perform one
  deadline/resource-aware two-to-four-feed follow-up for deferred work.
  BGProcessing remains outcome-paced and charging/network constrained.
- Download watchdog ownership is split deliberately: DownloadManager owns
  absolute per-attempt first-byte/active-transfer deadlines; DownloadCoordinator
  exclusively owns generation-guarded bounded retries. Exhaustion retires the
  matching durable auto-download intent so later drains cannot create a competing
  retry path.
- Portability/privacy: OPML import/export, optional iCloud sync, on-device default
  stance, local logs, and a minimal privacy manifest.
- System discovery: interactive Home Screen Now Playing/Up Next widgets plus
  privacy-sensitive Lock Screen and StandBy accessories; downloaded-only play
  controls and validated links to Player, Up Next, Episode Detail, and Discover.

## iCloud Sync Coverage

Synced:

- Subscriptions and unsubscribe tombstones.
- Per-episode played/archive/completion state.
- Listening history, including the recency-selected `lastPositionSeconds` resume
  point plus monotonic `listenedSeconds` and terminal completion evidence.
- Atomic whole-list Priority Stack order (`SubscriptionOrder`); legacy
  per-subscription rank remains a compatibility projection.
- Most individual subscription settings: inactive/return rank, notifications,
  playback preference, auto-archive settings, chapter filter, Download Filters,
  title, and feed URL.
- Stats page data via additive installation partitions of `DayStats`, with
  account-scoped caching, generation metadata, retired-lineage suppression,
  durable outcome deduplication and own-partition recovery.

Not synced in v1:

- Global `AppSettings` such as download Wi-Fi/cellular
  toggles, skip durations, sleep schedule, recaps, launch screen, onboarding flags,
  and global Default Playback.
- Release Radar learned schedule/refresh stats.
- Downloaded files, download state, catalog metadata, and media cache.

## Build And Test Notes

- After source membership changes, regenerate the Xcode project with `xcodegen generate`.
- SwiftPM tests are available through `swift test`; in a sandboxed environment use
  temporary HOME/module-cache paths if the default user cache is not writable.
- Smoke executables include `RSSParserSmoke`, `OPMLSmoke`, `SubscriptionStoreSmoke`,
  `DownloadManagerSmoke`, and `StatsSmoke`.

## Licensing

Autohop is MIT except for four MPL-2.0 files derived from Pocket Casts for iOS:
`Playback/SilenceDetector.swift`, `Models/SilenceGapAccounting.swift`,
`Playback/PlaybackEngine.swift`, and `Models/Synced.swift`. `LICENSE-MPL-2.0.md`
and `NOTICE` also acknowledge broader Pocket Casts design ideas and inspiration
without claiming copied UI assets or strings outside the listed files.

## Navigation and Sleep Schedule — 20 September 2026

<!-- AI CONTEXT — Current implementation summary; preserve these contracts when
editing navigation or settings UI. The linked audits own detailed evidence. -->

- `RootView.swift` owns `appNavigationBackButton`: native Back for pushed pages
  on iOS 27+, branded ambient dismiss on older systems. Player's modal Podcast
  Detail/Settings roots explicitly retain dismiss. Never add a competing Back
  item or pop the outer path from a child. See
  [navigation audit](Docs/IOS27_NAVIGATION_BACK_AUDIT.md).
- Sleep Schedule uses Feed Filters/Replay glass-card styling, immediate saving,
  native hours controls, all six interval choices, configuration summary and
  expandable help. Disabled values, notification opt-in, onboarding and mini-player
  remain. Chimes overlap ongoing playback; unanswered prompts fade/pause/rewind.
  Playback services and persistence bindings are unchanged by this refresh. See
  [Sleep Schedule audit](Docs/SLEEP_SCHEDULE_DESIGN_AUDIT.md).
- Hosted simulator checks passed on iOS 26.5/27; Sleep Schedule also passed on
  iPadOS 26.5 with large text. These results do not establish physical-device,
  overnight audio, VoiceOver or notification-delivery behaviour.

## Diagnostic reliability repairs — 20 September 2026

<!-- AI CONTEXT — Keep this contract aligned with source headers and the repair record. -->

Playback resume retires stale buffer waits; Pause cancels pending recovery; EOF
uses consistent completion and render health reflects actual callbacks. Auto
Archive reads live pin IDs without repeated catalogue scans. Download completion
awaits ordered off-main stats-file persistence. First active-runtime fallback is
prompt; later retries stay bounded. Sync settings reactions are deduplicated,
foreign subscription identities remain protected, and diagnostic exports additionally
pseudonymise personal route names/arbitrary GUIDs. MetricKit disk-write reports now
carry byte counts and bounded stacks. Titles/timestamps remain diagnostic context.
See [implementation and validation](Docs/DIAGNOSTIC_REPAIRS_2026-09-20.md).


### Mini-player bottom backing — 20 September 2026

<!-- AI CONTEXT — One shared glass background extends through the bottom safe area. -->
The persistent mini-player's continuous purple glass background reaches below the
progress strip to the bottom safe-area edge, without a separate material-only band. Shared
controls and layout are preserved. Page/sheet screenshots were verified on iOS 27
and iOS 26.5 simulators; see [the audit](Docs/MINI_PLAYER_AUDIT_2026-09-06.md).
