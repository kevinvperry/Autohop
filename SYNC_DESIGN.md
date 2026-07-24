# Autohop — Cross-Device Sync Design

<!--
AI CONTEXT — SYNC_DESIGN.md
Canonical design/status note for Autohop's opt-in CloudKit sync layer. Verified
again during the 2026-07-24 whole-project audit. Keep this
aligned with Models/SyncState.swift, Persistence/CloudKitSyncMapping.swift,
App/SyncCoordinator.swift, App/RelayCoordinator.swift,
Persistence/CloudSyncEngine.swift, Persistence/AutohopDatabase.swift, and
Persistence/SubscriptionStore.swift. Episode sync identity is subscription-scoped
(`subscriptionID|guid:<guid>`), but CloudKit record names are type-namespaced
(`episode:`, `subscription:`, `subscription-order:`, `history:`, `stats:`)
because record IDs are unique across record types inside a zone. Priority Stack
ordering is one atomic `SubscriptionOrder` generation; per-subscription
`priorityRank` remains a local/legacy compatibility projection. A CloudKit save
acknowledgement clears only the exact value/timestamp or order generation that
was sent, so a newer local edit cannot be lost while an older request is in
flight. Refresh scheduling stats remain local, and
download/media state never syncs. DownloadFilterSettings JOINED the sync
projection in July 2026 (Kevin's product decision) — it was local/backup-only in
v1; see "Download Filters sync" notes throughout.
June 2026 diagnostic repair context lives here too: collision quarantine,
legacy pending-save retirement, full-record namespace migration, recovery from
legacy unprefixed subscription records after the sparse-record data-loss
regression, and DayStats conflict convergence/storm logging. July 2026 added
type-aware push coalescing (fast/slow lanes — see "Push coalescing" below). Non-sync diagnostic
repairs from the same cycle are summarized in `FEATURES.md`: Release Radar
protected background refresh slots, rolling one-item feed download cleanup,
foreground/background refresh attribution, playback-tick timing, main-thread
watchdog inactive-gap classification, and AirPods/Speaker route stabilization.
-->

Design + status for opt-in iCloud (CloudKit) sync across devices. Derived from a
review of the Pocket Casts iOS sync engine — its conflict-resolution discipline
applied on top of CloudKit.

## Guiding principles
1. **Opt-in**, off by default (`AppSettings.iCloudSyncEnabled`). On-device privacy
   stance holds until the user enables sync.
2. **Local store is the source of truth** (GRDB/SQLite); CloudKit is a sidecar.
3. **Sync mutable user-state, never the catalog.** Episode title/description/
   artwork rehydrate from the feed. Stable identity = `(subscriptionID, guid)`
   for episodes and `subscriptionID` for subscriptions; the local episode UUID
   regenerates, and RSS GUIDs can collide across feeds.
4. **Downloads are per-device and never sync.**
5. **Pick the conflict strategy per domain.** Most fields are field-level
   last-write-wins; Priority Stack order is whole-list LWW; stats are additive
   and partition per device.

## Sync coverage at a glance (what roams vs. what stays on-device)
Verified against `Models/SyncState.swift`, `Persistence/CloudKitSyncMapping.swift`
(record types: `EpisodeState`, `SubscriptionState`, `SubscriptionOrder`,
`HistoryEntry`, `DayStats`, and `QueueSnapshot` — and **no global settings record
type**), and `Models/{Subscription,SubscriptionOrder,AppSettings}.swift`.

| Domain | Roams via CloudKit? | Record / projection | Notes |
|---|---|---|---|
| **Episode subscriptions** (subscribe / unsubscribe) | ✅ Yes | `SubscriptionState` | Other devices re-materialise the show by fetching its feed (`SyncCoordinator.materializeRemoteSubscription` on iOS; the tvOS sync owner mirrors that transaction); unsubscribe leaves a `subscribed=false` tombstone. |
| **Priority Stack order** | ✅ Yes | `SubscriptionOrder` singleton | One whole-list generation contains every real-subscription UUID, active first and Inactive last. It is authoritative over independently delivered legacy rank fields and prevents mixed reorder generations. |
| **Per-episode user state** (playedState, wasCompleted, lastPlayedAt) | ✅ Yes | `EpisodeState` | Field-level LWW + active-player-wins + self-heal. |
| **Listening history** (incl. `lastPositionSeconds` resume point + `listenedSeconds`) | ✅ Yes | `HistoryEntry` | Whole-entry record-level LWW by `lastListenedAt`. This is also how **playback position** roams. |
| **Individual subscription settings** | ✅ Yes | `SubscriptionState` | Synced: legacy priority rank compatibility field (+ Inactive return rank), notifications, exclude-from-auto-refresh, playbackPreference, autoArchiveSettings, chapterFilter, title, **downloadFilterSettings (since July 2026)**. The atomic `SubscriptionOrder` is authoritative for whole-list ordering. **NOT synced:** Release Radar `refreshStats` (see below). |
| **Stats page data** | ✅ Yes | `DayStats` | Additive per-device partition `(deviceID, dayKey)`; the Stats page sums across devices on read. Pre-tracking lifetime baseline stays per-device (deferred). |
| **Overall system settings** (`AppSettings`: poll interval, download Wi-Fi/cellular toggles, skip seconds, sleep schedule, global Default Playback, recaps, launch screen, onboarding flags, …) | ❌ **No** | — (no record type) | Local `UserDefaults` only; roams **only** via iCloud/device backup-restore, not live CloudKit sync. A fresh install starts from defaults until restored. |
| **Per-podcast Download Filters** (`DownloadFilterSettings`) | ✅ Yes (July 2026) | `SubscriptionState` | JSON blob + stamp on the subscription record, struct-level LWW. Was backup/local-only in v1; records written before the field existed decode with a nil stamp and never reset local filters. |
| **Release Radar learned schedule** (`refreshStats` / `releaseObservations`) | ❌ No | — | Per-device learning; relearns from the feed on each device. |
| **Downloaded media / download state / files** | ❌ No | — | Per-device by design — re-downloadable from the feed. |
| **Catalog content** (episode/show title, description, artwork, categories) | ❌ No | — | Re-hydrates from the RSS feed; never synced. |

> **Headline for a reviewer:** subscriptions, atomic Priority Stack ordering,
> listening history, per-podcast settings (including Download Filters since July
> 2026), queue state, and stats are covered. The intentional gaps to
> be aware of are **global app settings** and the per-device Release Radar
> learning, which do **not** roam. See FUTURE_VERSIONS.md if any of these should
> become a roaming setting.

## Transport: `CKSyncEngine` (not `NSPersistentCloudKitContainer`)
The container does record-level LWW with no merge hook — it would lose concurrent
edits to different fields. `CKSyncEngine` exposes serverRecord/clientRecord so we
merge per-field. Private database, custom zone `AutohopSync`.

## Local store: GRDB
`subscriptions.json` migrated one-time into GRDB rows (`AutohopDatabase`), behind
the unchanged `@MainActor SubscriptionStore` facade. Per-row incremental writes.
Migration v9 adds a singleton `subscription_order` row holding the current
generation, pending flag, and CloudKit system fields. Reorder writes are retried
with bounded exponential backoff; Done and lifecycle transitions can await
`flushPendingSaves()` before CloudKit scans for pending work.
Release Radar refresh stats are persisted locally on the subscription row but are
not part of the CloudKit sync projection; refresh-stat-only saves publish no
`objectWillChange`, so routine polling evidence does not wake the UI or sync
engine. DownloadFilterSettings is persisted on the local Subscription payload
and, since July 2026, is also part of the sync projection.

AppState decomposition Stages 0–14 did not change CloudKit schemas or merge
policy. `SyncCoordinator` owns the iOS CloudKit lifecycle, callback graph,
remote materialization, active-player identity provider, history/Stats routing,
deferred pushes, and Relay nudge connection. `PlaybackCheckpointWorkflow`
enforces playback-position → local history/Stats → deferred-push ordering.
DownloadCoordinator owns device-local transfer runtime, FeedRefreshCoordinator
owns device-local Release Radar runtime, AutoDownloadIntentWorkflow owns
device-local durable transfer intents, and AutoArchiveCoordinator owns
device-local archive activity. AppState retains only high-level lifecycle and
platform compatibility commands over these owners. Existing SubscriptionState,
episode, history, Stats, queue, and order sync boundaries remain unchanged.

## `@Synced` wrapper + sync-state projections
`Synced<T>` (Models/Synced.swift) auto-stamps `modifiedAt` on change → free
dirty-tracking; nil local stamp = clean. A nil **remote** stamp means the field
was absent from the CloudKit record and is treated as "no remote opinion" rather
than as an authoritative default. (`Synced` is a port of Pocket Casts'
`ModifiedDate` wrapper and is **MPL-2.0-covered** — see NOTICE / LICENSE-MPL-2.0.md.)
Projections (Models/SyncState.swift):
- `EpisodeSyncState` (key `subscriptionID|guid:<guid>`): playedState,
  wasCompleted, lastPlayedAt.
- `SubscriptionSyncState` (key `subscriptionID`): subscribed, title,
  legacy-compatible priorityRank,
  autoFeedRefreshReturnPriorityRank (the hidden Inactive return rank), notificationsEnabled,
  excludeFromAutoFeedRefresh, playbackPreference, autoArchiveSettings, chapterFilter,
  downloadFilterSettings (since July 2026), + constant `feedURL`. It deliberately
  excludes refreshStats (Release Radar learning).
  **Upgrade path for the July 2026 filter field:** pre-upgrade projection payloads
  no longer decode (Synced has no missing-key fallback), which deliberately routes
  through the existing decode-failure re-seed (`recordSubscriptionSyncState`
  fallback + `reseedUndecodableSyncState` at launch): each subscription re-seeds
  fully dirty and re-uploads a complete snapshot — which is also what first
  populates filters on the server. Remote records without the field decode with a
  nil stamp ("no remote opinion") and can never reset local filters to defaults.

**Atomic Priority Stack order repair (2026-07-18):** CloudKit can deliver
individual `SubscriptionState` records in arbitrary order, and a drag changes
several ranks as one logical action. Independently syncing those ranks allowed a
receiver—or a delayed acknowledgement on the sender—to observe a mixture of two
reorder generations. `SubscriptionOrderState` now represents the complete
real-subscription UUID sequence in one singleton `SubscriptionOrder` record
(`subscription-order:current`). Local `priorityRank` values are derived from that
sequence. Newly materialised subscriptions reapply the stored whole-list order;
legacy ranks are used only when no atomic order exists.

The Subscriptions page begins an ID-based reorder session containing active real
subscriptions only. Inactive and browse rows cannot corrupt filtered indices.
Remote order received during a drag is deferred. One validated Done/navigation/
background commit authors one local order generation and flushes it to SQLite.
Whole-list LWW uses `updatedAt`; `generationID` ensures an older CloudKit save
response cannot clear a newer pending reorder. Local generation timestamps advance
monotonically beyond the stored order even after a wall-clock rollback/future
remote clock, and equal timestamps use generation UUID as a deterministic tie
break.

**Acknowledgement invariant (2026-07-18):** `Synced.markClean(ifAcknowledgedBy:)`
requires an exact value+timestamp match. Episode and subscription projections
clear fields independently; history/stats/queue use their version identity; the
order singleton uses `generationID`. If anything newer remains pending,
`CloudSyncEngine` immediately requeues it. Never replace this with unconditional
`markSynced` after an asynchronous request.

**Related bug, same root cause class (found + fixed same day):** episode
played/archived state (`EpisodeSyncState`) can also arrive and stash itself
BEFORE the episode it describes exists locally (`applyRemoteEpisodeState`'s
no-local-episode-yet branch) — CloudKit doesn't guarantee episode records
arrive after their parent subscription. `updateEpisodes` (iPhone) already
self-healed from that stash; `materialize` (tvOS) didn't, so freshly-
materialized back-catalog episodes looked unplayed even when already synced
as played/archived — Up Next was full of "already finished" episodes. Fixed
by extracting the self-heal logic into a shared
`SubscriptionStore.selfHealedEpisode`, called from both paths now.

**Settings-clobber on materialize (found + fixed 2026-07-05, tvOS real-device
pass).** Same root-cause class again — materialising a subscription BEFORE its
synced projection is reflected in the created object. The engine adopts a CLEAN
remote `SubscriptionSyncState` (real user settings: playback speed, auto-archive,
chapter/download filters, notifications) into the DB, then asks the app to
materialise the feed. `materialize` used to seed DEFAULT settings; the following
`save() → recordSubscriptionSyncState` then re-`apply`'d those defaults over the
clean projection, marking each field dirty at `now`. Field-level LWW let those
fresh-default timestamps BEAT the phone's older real values and pushed them back
— "loading older info on the TV clobbers newer info on the phone." Fixed by
having `materialize` ADOPT every synced field from the existing clean projection
(when present) instead of seeding defaults, so `apply` sees no change and the
projection stays clean → nothing is pushed → the phone is preserved, and the TV
shows correct settings immediately. Guarded by
`Tests/MaterializeSettingsPreservationTests.swift`.

**2026-07-04 audit findings (second real-device pass):**
- **History persistence depended on an app callback (FIXED).** The engine's
  fetch path persisted episode/subscription/stats records directly, but
  history records only via `onRemoteHistoryEntry` — a platform that never
  wired it (the TV app) silently dropped EVERY synced resume position. The
  engine now falls back to `saveSyncedHistoryEntry` when no callback is set;
  iOS (callback wired) is unchanged.
- **Read side of cross-device resume now exists**:
  `SubscriptionStore.savedListeningPosition(for:)` (normalized; `.listened`
  entries only) and `mostRecentInProgressListeningEntry()` (the true
  cross-device Continue Listening signal, by `lastListenedAt`, requiring a
  usable position). `markEpisodePlaying` now also stamps `lastPlayedAt` (it
  never did — recency comparisons between `.playing` episodes were arbitrary).
- **OPEN GAP — `playedEpisodeKeys` / `archivedEpisodeKeys` do not sync.**
  These per-subscription key sets are the phone's LONG-TERM memory of
  finished episodes (they survive feed re-fetches and the 50-episode window;
  `updateEpisodes` uses them to re-mark returning episodes). A fresh device
  can only learn played/archived state from `EpisodeSyncState` records —
  which only exist for episodes touched since projections shipped (June
  2026). Episodes completed BEFORE that, or whose projections never pushed,
  look unplayed on a fresh TV forever. Recommended fix: add both sets to
  `SubscriptionSyncState` (same upgrade pattern as `downloadFilterSettings`);
  decide merge semantics first — field-LWW loses concurrent additions from
  two devices; set-union can't propagate unarchive removals. NOT implemented
  yet; needs that design decision.
- **RESOLVED (same day, Kevin's decision) — the queue now roams.** New
  `QueueSnapshot` record type (`queue:current`, ONE per account, whole-record
  LWW by the payload's `updatedAt` — a queue is one coherent ordered list,
  not mergeable fields). The iPhone authors it from `downloadedQueue`
  recomputes (`SubscriptionStore.updateLocalQueueSnapshot`, deduped on entry
  equality so no-change recomputes never push); entries carry the stable
  subscription-scoped episode key (`PlaybackPositionStore.key`) + subscriptionID
  + a display-fallback title. Readers (tvOS `TVAppModel.upNextEpisodes`,
  future watch) render `QueueModel.resolvedQueue(from:subscriptions:)` —
  snapshot ORDER is authoritative, unresolvable keys are skipped, and
  locally-known played/archived episodes are stale-filtered (a pre-completion
  snapshot can't resurrect a finished episode — this also largely supersedes
  the playedEpisodeKeys gap above FOR THE QUEUE SURFACE, since the phone's
  queue never contains finished episodes). Engine: fast lane push, persisted
  directly on pull (`saveSyncedQueueSnapshot`, LWW guard protects a local
  author's newer pending queue), notify-only `onRemoteQueueSnapshotChanged`.
  Storage: single-row `queue_snapshot` table (migration v8). Tested:
  `Tests/QueueSnapshotSyncTests.swift`.

  **Late queued-record rebuild fix (2026-07-12):** CKSyncEngine record construction
  reads the current queue singleton (`queueSnapshot()`), not the pending-only view.
  `pendingQueueSnapshot()` remains correct for deciding whether to enqueue a save,
  but callback ordering/retry reconciliation can ask for an already-queued
  `queue:current` after its pending flag has been cleared. The current row remains
  authoritative and must still produce a CKRecord; otherwise the request emits
  `sync.recordNotFound` and can strand Up Next propagation. Regression coverage
  verifies that marking a snapshot clean removes it from pending while preserving
  the current singleton for reconstruction.
  **Fast adoption (2026-07-04, Kevin's follow-up):** waiting for the snapshot
  to surface in the full CKSyncEngine change stream meant the TV queue cycled
  through stale episodes for ~10 min after launch. `CloudSyncEngine.fetchQueueSnapshotNow`
  does a TARGETED single-record fetch (`CKDatabase.record(for: queue:current)`)
  through the normal `applyRemote` path (so LWW + notify still apply), called
  at launch and on foreground (with a short retry loop covering the engine's
  async activation). `.unknownItem` (nothing authored yet) is silent.
  **Cold-start speedup + churn fix (2026-07-05, Kevin's round-4 findings —
  ~5-min "No Library Yet" blank AND ~10-min Up Next churn):**
  - *Blank:* `CloudSyncEngine.fetchAllSubscriptionsNow` does a targeted
    paginated ZONE query for every current subscription record and applies each
    immediately (kicking off feed materialisation), bypassing CKSyncEngine's
    cold delta stream. `TVAppModel.primeLibraryFromCloudSoon` (replaces the old
    queue-only `refreshQueueFromCloudSoon`) primes subscriptions + the queue
    snapshot once `engine.isActivated`, at launch and on foreground.
  - *Churn:* the churn was `upNextEpisodes` falling back to the locally-derived
    Priority Stack whenever the snapshot didn't fully resolve — showing wrong /
    already-finished episodes until every catalog trickled in. Now
    `QueueModel.resolvedQueueItems` returns ordered items with an OPTIONAL
    `episode` (nil = referenced but not yet materialised), and `upNextItems`
    renders STRICTLY from the snapshot (placeholder "Syncing…" rows for
    unresolved entries, non-playable until their catalog lands) — never the
    local fallback while a snapshot exists. `resolvedQueue` (episodes-only, for
    auto-advance) is now derived from `resolvedQueueItems`. The Priority-Stack
    fallback survives only for the genuinely-no-snapshot case (fresh install /
    standalone). Tested: `Tests/QueueSnapshotSyncTests.swift`.
  - *Continue Watching never populated (2026-07-05):* the paused-on-iPhone
    episode's resume position rides the SLOW lane (listening history) and, on
    TV, had no re-render trigger — `continueListening` reads the sync DB
    directly and isn't Observation-tracked, so a lone history record landing
    changed nothing on screen. Two fixes: (1) `CloudSyncEngine.fetchAllHistoryNow`
    is added to the launch/foreground prime so history arrives fast; (2) a new
    NOTIFY-ONLY `onRemoteHistoryChanged` fires after each history apply, wired on
    TV to `refreshLibrary` so Continue Watching appears the moment the position
    syncs. (Resolution itself was already correct — `episodeMatching` matches on
    the stable `PlaybackPositionStore.key`, identical on both devices.)
  - *ROUND-6b DATA-DAMAGE POSTMORTEM (2026-07-11, same day as round 6 below —
    Kevin: "sync has caused damage to my subscriptions on my phone. A large
    number of individual settings have been reset to defaults").* Root cause:
    the 2026-07-05 materialize adopt-fix only protects materialisations that
    happen AFTER the synced projection landed locally. A survival-kit PURGE
    REBUILD (TV's Caches DB purged → bootstrap refetches all feeds) runs
    against an EMPTY database — no projections — so `materialize` seeded
    DEFAULT settings and `recordSubscriptionSyncState`'s "first sighting seeds
    a fully-dirty projection" rule (correct for a genuine local subscribe)
    created dirty default projections for ALL 113 subscriptions; engine
    activation pushed them; field-LWW's fresh stamps beat the phone's older
    real values → phone-wide settings reset. THREE-PART FIX: (1) `materialize`
    now pre-seeds a CLEAN projection (markClean → "no local opinion" on every
    field) when none exists — a materialized-by-identity subscription NEVER
    originates settings; the real values win when the CloudKit record arrives.
    (2) One-shot TV launch repair (`SubscriptionStore.
    markAllPendingSubscriptionProjectionsClean`, called in TVAppModel.bootstrap
    BEFORE startCloudSync, UserDefaults-flagged) de-dirties pre-fix default
    projections still in the TV DB so they can't re-push. Safe on TV only —
    the TV never authors subscription settings. (3) Regression tests
    (MaterializeSettingsPreservationTests: purge-rebuild seeds clean; add()
    still seeds dirty; repair clears pending). RECOVERY: the phone's old
    values are unrecoverable (overwritten via LWW; CloudKit now holds the
    defaults) — Kevin re-sets affected settings manually; his newer stamps
    then win everywhere. NOTE for any future platform with a purgeable DB
    (watch): use `materialize`, never `add`, and it now inherits this
    protection automatically.
    **(4) HARD ONE-WAY RULE (same day, Kevin's directive after the damage —
    "there is no reason for the Apple TV app to be able to alter subscription
    settings on the phone"):** `CloudSyncEngine.pushesSubscriptionState`
    (constructor policy; the TV passes false). In read-only subscription-state
    mode the engine STRUCTURALLY never pushes `SubscriptionState` — settings,
    subscribed/unsubscribed, priority rank — enforced at all three push
    points: dirty rows are never queued (queuePendingLocalChanges), pending
    saves restored from persisted engine state are dropped and removed
    (nextRecordZoneChangeBatch, `sync.subscriptionPushBlocked`), and the
    legacy-recovery re-upload routine is skipped entirely. Receiving is
    unchanged; episode played-state, history, stats, and the queue snapshot
    still push (the TV's legitimate outputs). Consequence: subscribe-on-TV is
    local-only and does not roam. iOS keeps the default (true) — the phone is
    the settings author. Tested: CloudSyncEnginePermanentFailureTests'
    isSubscriptionStateChange cases (239 total).
  - *Round-6 fixes (2026-07-11, Kevin's real-device findings: ~30 s of stale Up
    Next, a month-old "Resume Playing" hero that vanished, never showing the
    phone's actual current episode):*
    1. **Prime order flipped** — `primeLibraryFromCloudSoon` now fetches the
       queue snapshot + history (one cheap targeted fetch each) and re-renders
       BEFORE the paginated `fetchAllSubscriptionsNow` sweep (113 records), so
       Up Next/Continue Listening are phone-correct within seconds.
    2. **Continue Listening renders from the history ENTRY itself**
       (`TVContinueListening`): the old code required the entry to resolve to a
       locally-materialized episode first, silently discarding the phone's true
       current episode on a cold/behind TV; and its `playedState == .playing`
       local fallback was what surfaced the month-old stale hero. The fallback
       is DELETED; the hero now shows the entry's denormalized
       title/podcast/artwork/position immediately, with a "Syncing…"
       placeholder (non-playable) until the catalog materializes — same
       pattern as the queue-snapshot churn fix.
    3. **TV listening stats now sync** — TV creates its own
       `ListeningStatsStore` (Caches JSON; new public
       `attachSyncDatabase(from:)` since AutohopDatabase is internal to the
       library), and `TVPlaybackModel` records listening time (speed-aware),
       episode started/completed, and manual skip-forward. DayStats' additive
       per-(deviceID, dayKey) partitions mean the iPhone Stats page sums TV
       consumption in with ZERO phone-side changes. Stats buckets flush before
       the checkpoint force-push, matching iOS lifecycle-flush ordering. a mid-episode PAUSE
    writes a position on the SLOW lane, which the engine holds ~60 s before
    pushing. To make a pause/exit reach the other device in seconds, both
    platforms now force-flush on pause + player-exit + app-background:
    iPhone already did (`PlaybackTransportWorkflow` pause or the scene adapter →
    `PlaybackCheckpointWorkflow`; the exact position is persisted before local
    history/Stats and the deferred push); TV now mirrors it
    (`TVPlaybackModel.checkpoint` → `onPlaybackCheckpoint` →
    `CloudSyncEngine.flushDeferredPushes`, wired on pause, `dismissedCover`, and
    the scene leaving `.active`). Playback FINISH already went out on the fast
    lane. The receiving side still uses the normal change stream (fast when the
    app is foregrounded); only the SEND side's debounce is bypassed.
- **Legacy rank-corruption safeguards (2026-07-04, retained as fallback):** (a) iPhone's
  `materializeRemoteSubscription` now passes `reindexRanks: false` to
  `addSubscription` (new parameter; local subscribe/OPML keep the default
  compaction, which is correct for them); (b) `load()` no longer compacts
  ranks at startup — a relaunch mid-initial-sync would have tied
  later-arriving absolute ranks against freshly compacted 1..n. Audit swept
  every remaining `reindexPriority`/`normalizePriorityOrder` call site: all
  others are genuine local edits where compaction is correct. Since 2026-07-18,
  the atomic `SubscriptionOrder` supersedes these per-record ranks whenever a
  whole-list generation is available; the safeguards remain for migration and
  older CloudKit data.

Dirty-tracking is maintained centrally in `AutohopDatabase.persist` — domain
models are untouched. Pristine never-touched episodes are skipped; unsubscribe
leaves a `subscribed = false` tombstone.
Migration v7 moved episode sync rows from bare GUID primary keys to
subscription-scoped keys. CloudKit record payloads still carry the local
identity, but outbound record names are now type-namespaced:

| Domain | Current record name | Legacy fallback |
|---|---|---|
| EpisodeState | `episode:<subscriptionID>|guid:<guid>` | unprefixed scoped key, or bare GUID when the record stores `subscriptionID` |
| SubscriptionState | `subscription:<subscriptionID>` | unprefixed subscription UUID |
| SubscriptionOrder | `subscription-order:current` | none; new singleton in July 2026 |
| QueueSnapshot | `queue:current` | legacy queue singleton name |
| HistoryEntry | `history:<historyID>` | unprefixed history ID |
| DayStats | `stats:<deviceID>:<dayKey>` | unprefixed `deviceID:dayKey` |

The namespace is required because CloudKit record IDs are unique across record
types inside a zone; an old HistoryEntry record can otherwise block a later
EpisodeState save with the same record name. Decoders keep the legacy fallbacks
so existing iCloud data remains readable.

## Push coalescing (fast/slow lanes, July 2026)
A 2026-07-03 diagnostic log review ("Friday log file.log") found 8 separate
CKSyncEngine pushes in ~2 minutes of playback, each saving only 1–2 records —
listening-stats day rows and listening-history rows were queued eagerly on
every debounced store change as playback dirtied them. `CloudSyncEngine`'s
queue pass is now type-aware:

**Local write coalescing (hardened 2026-07-12):** the 0.5-second playback clock no
longer performs a complete listening-history update on every tick. History samples
accumulate in memory and are applied in 30-second batches, reducing array searches,
full sorts, JSON-save checks, published-array invalidations, and SQLite pending-row
writes from roughly two per second to roughly one per ten seconds. Stats still updates
its authoritative in-memory day bucket on every tick for numerical accuracy, but its
SwiftUI `revision` publishes at most once per 10 seconds. Stats sync-row writes
use a 30-second throttle. Pause, scene background/inactive, sleep timer,
sleep schedule, episode completion, and remote-history merge are explicit flush points,
so the final position and accumulated time become durable before the slow-lane CloudKit
push is requested.

- **Fast lane** — `EpisodeState` + `SubscriptionState` + `SubscriptionOrder`
  (discrete user actions):
  queued immediately on the existing 1 s store-change debounce, unchanged.
- **Slow lane** — `HistoryEntry` + `DayStats` (continuously re-dirtied by
  playback): when a queue pass finds *only* slow-lane dirt, it schedules a
  ~60 s deferred push (`CloudSyncEngine.slowLaneDebounceSeconds`) instead of
  queueing. If fast-lane dirt is present, slow rows **piggyback** on that push
  (a CloudKit request is going out anyway).
- **Lifecycle flush** — `PlaybackCheckpointWorkflow` first saves playback
  position, then asks `HistoryStatsCoordinator.checkpoint` to save history and
  Stats/sync rows before `SyncCoordinator` requests
  `CloudSyncEngine.flushDeferredPushes(reason:)`. Pause, sleep-timer,
  sleep-schedule, and scene background/resign-active use this ordered boundary.
  Engine activation and account sign-in also flush unconditionally.

Coalescing only delays WHEN records are queued, never what they contain: dirty
rows stay pending in the local database until a push succeeds (`markSaved`), so
a killed app loses nothing — the rows are re-queued on next activation. All
other invariants (field-LWW, type-namespaced record IDs, quarantine repair,
additive stats partitions) are untouched; the quarantine filter applies per
lane before the defer decision. The pure lane policy
(`CloudSyncEngine.shouldDeferSlowLane`) is unit-tested headless in
`Tests/SyncPushCoalescingTests.swift`; the timer/flush paths need a live
CKSyncEngine and are device-verified via `sync.slowLaneDeferred` /
`sync.queued` log keys.

## Field-level merge (`merged(withRemote:)`)
Per field: a remote value is authoritative only when it carries a non-nil
`<field>ModifiedAt` stamp. A nil remote stamp means "field absent / no remote
opinion" and preserves the local value. When the remote stamp is present, a
non-nil local stamp wins only if strictly newer; otherwise the remote value is
adopted clean. Settings sub-structs
(playbackPreference/autoArchiveSettings/chapterFilter) merge at struct level
(deliberate v1 simplification).

## Build status
1. ✅ **GRDB store migration** behind the SubscriptionStore facade.
2. ✅ **`@Synced` + sync-state projections**, dirty-tracking in `persist`.
3. ✅ **Episode user-state over CloudKit** — `CloudKitSync` mapper (EpisodeState,
   current recordName = `episode:<subscriptionID>|guid:<guid>`),
   `CloudSyncEngine` (CKSyncEngine delegate): push pending
   states, pull → `applyRemoteEpisodeState` (merge into projection + domain),
   serverRecordChanged/zoneNotFound handling, cached CKRecord system fields
   (migration v3), persisted change token, opt-in toggle in Settings → Sync.
   **Verified on a real device** (push creates EpisodeState records; Simulator
   cannot test CloudKit). Account-status guard prevents a retry-storm when no
   iCloud account.
4. ✅ **Subscription + per-podcast settings over CloudKit** — `SubscriptionState`
   record type (current recordName = `subscription:<subscriptionID>`), all
   synced settings + `feedURL` + stored `subscriptionID`; engine handles both
   record types; DownloadFilterSettings joined the record in July 2026;
   `applyRemoteSubscriptionState` updates settings /
   processes unsubscribe / signals `.needsMaterialization`;
   `SyncCoordinator.materializeRemoteSubscription` fetches the feed via FeedService and
   creates the podcast, then applies settings. Migration v4 caches subscription
   system fields. Migration v9 and the `SubscriptionOrder` singleton
   (`subscription-order:current`) synchronize Priority Stack order atomically;
   materialization reapplies the stored order rather than trusting record
   arrival order. Unit-tested; real-device cross-device verification of the new
   singleton remains pending.

5. ✅ **Listening history + stats**
   - 5a History: record-level LWW by `lastListenedAt` (HistoryEntry record,
     current recordName = `history:<historyID>`, migration v5).
     ListeningHistoryStore (shared Persistence source; iOS orchestration) records pending on mutation +
     merges via applyRemote; denormalized title/artwork kept. Since tvOS Phase
     3 (2026-07-04), `SubscriptionStore.recordListeningProgress` /
     `markListeningHistoryFinished` (AutohopCore) expose the same write path
     for platforms with no local history store of their own — both use
     `PlaybackPositionStore.key(for:)` as the entry id, which is byte-for-byte
     identical to ListeningHistoryStore's private `historyKey(for:)`, so
     entries from either device collide on the same id and merge rather than
     duplicate. This is the mechanism behind a phone⇄TV resume round-trip.
   - 5b Stats: **additive — partition by `(deviceID, dayKey)` and sum on read**
     (never LWW). `DeviceIdentity.current` (UserDefaults UUID); DayStats record
     per device-day (current recordName = `stats:<deviceID>:<dayKey>`);
     `stats_sync_state` (this device's pending) + `remote_stats` (other devices)
     tables (migration v6). `DayStats.merged` sums; ListeningStats `combinedDay`
     folds remote partitions into every read path (summary/streaks/per-show/
     lifetime). Engine skips its own echoed records by deviceID, but still caches
     their server system fields/change tag; on a `serverRecordChanged` conflict
     for this device's own partition, the local full-day bucket stays dirty and
     retries with the refreshed change tag instead of repeatedly fighting the
     same stale server record. legacyBaseline sync deferred (kept per-device for
     v1). Unit-tested incl. cross-device summing; real-device verification
     pending.

6. ✅ **Active-player-wins + self-heal guards**
   - Active-player-wins: `SubscriptionStore.nowPlayingEpisodeSyncKeyProvider`
     (set by `SyncCoordinator.observePlayback(_:)` from the authoritative
     `PlaybackCoordinator` engine episode) — in
     `applyRemoteEpisodeState`, if the remote record is for the exact
     subscription-scoped episode loaded in the player, the local playedState is
     kept and re-stamped so it pushes back, instead of a remote played/archived
     interrupting playback.
   - Self-heal: a remote episode-state stashed before the episode existed locally
     is applied in `updateEpisodes` when the feed later brings that episode in.
   3 unit tests.

**All six sync build steps complete.** Opt-in iCloud sync covers episode
user-state, per-podcast settings + subscribe/unsubscribe, atomic Priority Stack
order, listening history, queue state, and additive per-device stats — with
field-level/whole-record version-aware acknowledgements, active-player-wins, and
self-heal.

## Namespace repair / collision containment
June 2026 diagnostic review found a permanent CloudKit type-collision loop: a
legacy unprefixed `HistoryEntry` record name could be retried as an `EpisodeState`
save, causing CKSyncEngine to repeatedly reject it and re-enter the hot retry
path.

Current containment and repair behavior:
- `CloudSyncEngine.isPermanentRecordTypeCollision` recognizes the narrow
  HistoryEntry → EpisodeState collision signature for `invalidArguments` /
  `serverRejectedRequest`.
- `sync.pushQuarantined` is logged once per record, the stale pending save is
  removed from CKSyncEngine state, and the local dirty row is left dirty rather
  than marked synced.
- Fresh outbound saves use the new type-prefixed record names, so the dirty row
  is projected to a non-colliding `episode:` record on the next local queue pass.
- Restored pre-namespace `.saveRecord` changes are retired by
  `isRetiredLegacyPendingSave` before sending; `.deleteRecord` changes are
  preserved so unsubscribe/history/stat tombstone behavior is not lost.
- Cached CKRecord system fields are reused only when the cached record type and
  `recordID` exactly match the outgoing namespaced record, avoiding a stale
  change-tag/record-ID mismatch during first post-migration save.
- When cached system fields are missing or still point at a legacy unprefixed
  record name, the outgoing namespaced EpisodeState/SubscriptionState record is
  treated as fresh and written as a full snapshot. Sparse dirty-field overlays
  are used only when updating an existing matching server record.
- A one-shot legacy SubscriptionState recovery query reads unprefixed
  subscription records, repairs settings for subscriptions that still exist
  locally, and queues complete `subscription:` re-uploads. It never materializes
  unknown subscriptions or processes stale legacy unsubscribes.

This is functional self-repair and recovery, not a server cleanup job. Old
unprefixed records may remain as CloudKit orphans and, for subscriptions, are
kept as recovery sources until the namespaced records are known good. A targeted
orphan-delete tool can be added later if needed; a full zone reset is
intentionally avoided because it has more cross-device risk than benefit.

## CloudKit setup notes
- Container `iCloud.com.kevinperry.autohop`; CloudKit + Push + Background Modes
  (remote-notification) capabilities; entitlements mirrored into `project.yml` so
  `xcodegen generate` preserves them.
- Dev schema auto-creates on first save; **Deploy Schema Changes** to Production
  before App Store release.
- `CKSyncEngine` uses zone fetches, not queries — no custom indexes needed (a
  `recordName` queryable index is only for browsing in the CloudKit Console).

## Tests
Sync coverage lives in `Tests/SyncStateTests.swift`,
`CloudKitSyncMappingTests.swift`, `EpisodeDiffPersistTests.swift`,
`RemoteEpisodeApplyTests.swift`, `SubscriptionSyncTests.swift`,
`SubscriptionReorderTests.swift`, `SyncGuardsTests.swift`, `HistorySyncTests.swift`, `StatsSyncTests.swift`,
`CloudSyncEnginePermanentFailureTests.swift`, and
`SyncPushCoalescingTests.swift` (slow-lane push-coalescing policy).
The pure projection/mapping/database paths run under `swift test`; the
`CloudSyncEngine` itself is build/on-device-verified because CKSyncEngine needs
entitlements, a container, and a signed-in account.

## Diagnostics / observability
`CloudSyncEngine` is instrumented through `AppLogger` with `sync.*` event keys —
the primary way to debug sync on-device, since it can't be unit-tested. Grep the
Diagnostic Log (Settings → About → tap version 5×, then share) for `sync.`:

- **Lifecycle:** `sync.toggle`, `sync.engineActivated` (restoredState), `sync.stopped`, `sync.startAborted`/`sync.accountStatusFailed`, `sync.account*` (signIn/signOut/switch).
- **Push:** `sync.queued` (per-type counts plus quarantined count and a
  `slowLane` label — `piggyback` when slow rows rode a fast-lane pass, else the
  flush reason such as `engineActivated`/`playback.pause`/`scene.background`/
  `slowLaneDebounce`; DayStats
  entries also include day keys, cached system-field state, and record names),
  `sync.slowLaneDeferred` (history/stats-only dirt held for the ~60 s slow-lane
  debounce, with per-type counts),
  `sync.pushed` (saved count), `sync.pushFailed` (retryable CK error code — ERROR),
  `sync.pushQuarantined` (known permanent record-type collision), `sync.legacyPendingDropped`
  (restored pre-namespace save retired), `sync.zoneRecreate`, `sync.recordGone`.
- **Pull / merge:** `sync.fetched` (applied/deletions counts), `sync.conflict` (serverRecordChanged → merge+retry; DayStats conflicts include stats device ID, local device ID, day key, partition match, cached system-field state, retry status, planned resolution, and per-session conflict count; this device's own DayStats partition caches the server system fields and retries the local full-day bucket), `sync.conflictStorm` (same record conflicts repeatedly inside a short window), `sync.materialize` (remote sub fetched locally), `sync.decodeFailed`, `sync.unknownRecordType`, `sync.legacySubscriptionRecovery*` (one-shot legacy settings recovery).
- **Local store:** `sync.dbWriteFailed` (ERROR) — a write that used to be silently `try?`-swallowed (lost system fields / never-cleared dirty stamp → record re-pushes forever); `sync.state{Save,Decode}Failed`.
- **Priority order/persistence:** `subscriptions.reorderBegan`,
  `subscriptions.reorderCommitted`, `subscriptions.reorderRejected`,
  `subscriptions.remoteOrderDeferred`,
  `subscriptions.deferredRemoteOrderApplied`,
  `subscriptions.persistFailed`, `subscriptions.persistRetryScheduled`, and
  `subscriptions.persistRetryExhausted`.

Verbosity is **balanced** — batch summaries, not one line per record. **ERROR**
events (`sync.pushFailed`, `sync.pushQuarantined`, `sync.dbWriteFailed`,
`sync.accountStatusFailed`) use `AppLogger.error(..., alwaysPersist: true)`, so
they are recorded even when the Diagnostics toggle is off; INFO/WARN remain
gated. The log file stays capped at ~1 MB with rotation.

Related diagnostic keys outside CloudKit:
- `feed.refreshAll.plan`, `feed.refreshAll.itemStart`,
  `feed.refreshAll.backlog`, `feed.refreshAll.checkpoint`, and
  `feed.refreshAll.cancelled` describe Release Radar selection, including
  protected background candidates for pre-window, active-window, and
  missed-release feeds. `background.refreshRequested`, `feed.foregroundPollDue`,
  `background.nextDue`, `background.schedule`, and `background.scheduleSkipped`
  distinguish true BGAppRefreshTask wakes, foreground catch-up, requested-vs-
  effective iOS wake timing, and already-pending background requests.
- `stats.pendingMarked` and `stats.flush` mark low-frequency DayStats writes into
  the sync queue, so DayStats CloudKit conflicts can be correlated with local
  playback/stat updates.
- `playback.tickSlow` and `playback.tickSummary` report expensive 0.5 s playback
  ticks and their dominant stage without logging every tick.
- `feed.cleanupSupersededLatest` records when a rolling one-item feed replaces
  its latest episode and Autohop cancels the stale pending/in-progress download.
- `ui.mainThreadHang` / `ui.mainThreadHangRecovered` remain visible-scene UI
  freeze signals; `ui.watchdogInactiveGap` is used for short watchdog delays
  while the scene is inactive/backgrounded so those gaps are not mistaken for
  user-visible freezes.
- `audio.routeLossPending`, `audio.routeLossCancelled`,
  `audio.routeLossConfirmed`, `audio.interruptionDeferred`, and
  `engine.routeRestartDeferred` / `engine.routeRestartScheduled` trace
  AirPods/Speaker route stabilization, including previous/new output metadata
  for iOS `unknown` and `categoryChange` route notifications.
  `audio.routeRestoredReassert` / `audio.routeReassertActivateFailed` /
  `nowPlaying.reasserted` trace the 2026-07-12 "audio hijack" fix: when a
  removed output returns (AirPods reinserted), the engine re-claims the audio
  session (only if our pause was route-loss-caused AND no other app is
  audibly playing) and `PlaybackPreferenceWorkflow` re-pushes the full Now
  Playing card, so an
  AirPods stem-press resumes Autohop instead of falling through to Apple
  Music. `nowPlaying.reasserted` also fires on scene foreground.
