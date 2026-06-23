# Autohop — Cross-Device Sync Design

<!--
AI CONTEXT — SYNC_DESIGN.md
Canonical design/status note for Autohop's opt-in CloudKit sync layer. Keep this
aligned with Models/SyncState.swift, Persistence/CloudKitSyncMapping.swift,
Persistence/CloudSyncEngine.swift, Persistence/AutohopDatabase.swift, and
Persistence/SubscriptionStore.swift. Episode sync identity is subscription-scoped
(`subscriptionID|guid:<guid>`), but CloudKit record names are type-namespaced
(`episode:`, `subscription:`, `history:`, `stats:`) because record IDs are unique
across record types inside a zone. Refresh scheduling stats remain local, and
download/media state never syncs.
June 2026 diagnostic repair context lives here too: collision quarantine,
legacy pending-save retirement, full-record namespace migration, recovery from
legacy unprefixed subscription records after the sparse-record data-loss
regression, and enriched DayStats conflict/storm logging. Non-sync diagnostic
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
   last-write-wins; stats (a later step) are additive and partition per device.

## Transport: `CKSyncEngine` (not `NSPersistentCloudKitContainer`)
The container does record-level LWW with no merge hook — it would lose concurrent
edits to different fields. `CKSyncEngine` exposes serverRecord/clientRecord so we
merge per-field. Private database, custom zone `AutohopSync`.

## Local store: GRDB
`subscriptions.json` migrated one-time into GRDB rows (`AutohopDatabase`), behind
the unchanged `@MainActor SubscriptionStore` facade. Per-row incremental writes.
Release Radar refresh stats are persisted locally on the subscription row but are
not part of the CloudKit sync projection; refresh-stat-only saves publish no
`objectWillChange`, so routine polling evidence does not wake the UI or sync
engine.

## `@Synced` wrapper + sync-state projections
`Synced<T>` (Models/Synced.swift) auto-stamps `modifiedAt` on change → free
dirty-tracking; nil local stamp = clean. A nil **remote** stamp means the field
was absent from the CloudKit record and is treated as "no remote opinion" rather
than as an authoritative default. (`Synced` is a port of Pocket Casts'
`ModifiedDate` wrapper and is **MPL-2.0-covered** — see NOTICE / LICENSE-MPL-2.0.md.)
Projections (Models/SyncState.swift):
- `EpisodeSyncState` (key `subscriptionID|guid:<guid>`): playedState,
  wasCompleted, lastPlayedAt.
- `SubscriptionSyncState` (key `subscriptionID`): subscribed, title, priorityRank,
  notificationsEnabled, excludeFromAutoFeedRefresh, playbackPreference,
  autoArchiveSettings, chapterFilter, + constant `feedURL`.

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
| HistoryEntry | `history:<historyID>` | unprefixed history ID |
| DayStats | `stats:<deviceID>:<dayKey>` | unprefixed `deviceID:dayKey` |

The namespace is required because CloudKit record IDs are unique across record
types inside a zone; an old HistoryEntry record can otherwise block a later
EpisodeState save with the same record name. Decoders keep the legacy fallbacks
so existing iCloud data remains readable.

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
   settings + `feedURL` + stored `subscriptionID`; engine handles both record
   types; `applyRemoteSubscriptionState` updates settings /
   processes unsubscribe / signals `.needsMaterialization`;
   `AppState.materializeRemoteSubscription` fetches the feed via FeedService and
   creates the podcast, then applies settings. Migration v4 caches subscription
   system fields. Unit-tested; real-device cross-device verification pending.

5. ✅ **Listening history + stats**
   - 5a History: record-level LWW by `lastListenedAt` (HistoryEntry record,
     current recordName = `history:<historyID>`, migration v5).
     ListeningHistoryStore records pending on mutation + merges via applyRemote;
     denormalized title/artwork kept.
   - 5b Stats: **additive — partition by `(deviceID, dayKey)` and sum on read**
     (never LWW). `DeviceIdentity.current` (UserDefaults UUID); DayStats record
     per device-day (current recordName = `stats:<deviceID>:<dayKey>`);
     `stats_sync_state` (this device's pending) + `remote_stats` (other devices)
     tables (migration v6). `DayStats.merged` sums; ListeningStats `combinedDay`
     folds remote partitions into every read path (summary/streaks/per-show/
     lifetime). Engine skips its own echoed records by deviceID. legacyBaseline
     sync deferred (kept per-device for v1). Unit-tested incl. cross-device
     summing; real-device verification pending.

6. ✅ **Active-player-wins + self-heal guards**
   - Active-player-wins: `SubscriptionStore.nowPlayingEpisodeSyncKeyProvider`
     (set by AppState from `PlaybackEngine.currentEpisode`) — in
     `applyRemoteEpisodeState`, if the remote record is for the exact
     subscription-scoped episode loaded in the player, the local playedState is
     kept and re-stamped so it pushes back, instead of a remote played/archived
     interrupting playback.
   - Self-heal: a remote episode-state stashed before the episode existed locally
     is applied in `updateEpisodes` when the feed later brings that episode in.
   3 unit tests.

**All six sync build steps complete.** Opt-in iCloud sync covers episode
user-state, per-podcast settings + subscribe/unsubscribe, listening history, and
additive per-device stats — with field-level LWW, active-player-wins, and
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
`SyncGuardsTests.swift`, `HistorySyncTests.swift`, `StatsSyncTests.swift`, and
`CloudSyncEnginePermanentFailureTests.swift`.
The pure projection/mapping/database paths run under `swift test`; the
`CloudSyncEngine` itself is build/on-device-verified because CKSyncEngine needs
entitlements, a container, and a signed-in account.

## Diagnostics / observability
`CloudSyncEngine` is instrumented through `AppLogger` with `sync.*` event keys —
the primary way to debug sync on-device, since it can't be unit-tested. Grep the
Diagnostic Log (Settings → About → tap version 5×, then share) for `sync.`:

- **Lifecycle:** `sync.toggle`, `sync.engineActivated` (restoredState), `sync.stopped`, `sync.startAborted`/`sync.accountStatusFailed`, `sync.account*` (signIn/signOut/switch).
- **Push:** `sync.queued` (per-type counts plus quarantined count; DayStats
  entries also include day keys, cached system-field state, and record names),
  `sync.pushed` (saved count), `sync.pushFailed` (retryable CK error code — ERROR),
  `sync.pushQuarantined` (known permanent record-type collision), `sync.legacyPendingDropped`
  (restored pre-namespace save retired), `sync.zoneRecreate`, `sync.recordGone`.
- **Pull / merge:** `sync.fetched` (applied/deletions counts), `sync.conflict` (serverRecordChanged → merge+retry; DayStats conflicts include stats device ID, local device ID, day key, partition match, cached system-field state, retry status, and per-session conflict count), `sync.conflictStorm` (same record conflicts repeatedly inside a short window), `sync.materialize` (remote sub fetched locally), `sync.decodeFailed`, `sync.unknownRecordType`, `sync.legacySubscriptionRecovery*` (one-shot legacy settings recovery).
- **Local store:** `sync.dbWriteFailed` (ERROR) — a write that used to be silently `try?`-swallowed (lost system fields / never-cleared dirty stamp → record re-pushes forever); `sync.state{Save,Decode}Failed`.

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
  `engine.routeRestartScheduled` trace AirPods/Speaker route stabilization.
