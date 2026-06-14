# Autohop — Cross-Device Sync Design

Design + status for opt-in iCloud (CloudKit) sync across devices. Derived from a
review of the Pocket Casts iOS sync engine — its conflict-resolution discipline
applied on top of CloudKit.

## Guiding principles
1. **Opt-in**, off by default (`AppSettings.iCloudSyncEnabled`). On-device privacy
   stance holds until the user enables sync.
2. **Local store is the source of truth** (GRDB/SQLite); CloudKit is a sidecar.
3. **Sync mutable user-state, never the catalog.** Episode title/description/
   artwork rehydrate from the feed. Stable identity = `guid` (episodes) /
   `subscriptionID` (subscriptions); the local episode UUID regenerates.
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

## `@Synced` wrapper + sync-state projections
`Synced<T>` (Models/Synced.swift) auto-stamps `modifiedAt` on change → free
dirty-tracking; nil stamp = clean. Projections (Models/SyncState.swift):
- `EpisodeSyncState` (key `guid`): playedState, wasCompleted, lastPlayedAt.
- `SubscriptionSyncState` (key `subscriptionID`): subscribed, title, priorityRank,
  notificationsEnabled, excludeFromAutoFeedRefresh, playbackPreference,
  autoArchiveSettings, chapterFilter, + constant `feedURL`.

Dirty-tracking is maintained centrally in `AutohopDatabase.persist` — domain
models are untouched. Pristine never-touched episodes are skipped; unsubscribe
leaves a `subscribed = false` tombstone.

## Field-level merge (`merged(withRemote:)`)
Per field: a non-nil local stamp wins only if strictly newer than the remote's;
otherwise the remote value is adopted clean (server authoritative). Settings
sub-structs (playbackPreference/autoArchiveSettings/chapterFilter) merge at
struct level (deliberate v1 simplification).

## Build status
1. ✅ **GRDB store migration** behind the SubscriptionStore facade.
2. ✅ **`@Synced` + sync-state projections**, dirty-tracking in `persist`.
3. ✅ **Episode user-state over CloudKit** — `CloudKitSync` mapper (EpisodeState,
   recordName = guid), `CloudSyncEngine` (CKSyncEngine delegate): push pending
   states, pull → `applyRemoteEpisodeState` (merge into projection + domain),
   serverRecordChanged/zoneNotFound handling, cached CKRecord system fields
   (migration v3), persisted change token, opt-in toggle in Settings → Sync.
   **Verified on a real device** (push creates EpisodeState records; Simulator
   cannot test CloudKit). Account-status guard prevents a retry-storm when no
   iCloud account.
4. ✅ **Subscription + per-podcast settings over CloudKit** — `SubscriptionState`
   record type (recordName = subscriptionID), all settings + `feedURL`; engine
   handles both record types; `applyRemoteSubscriptionState` updates settings /
   processes unsubscribe / signals `.needsMaterialization`;
   `AppState.materializeRemoteSubscription` fetches the feed via FeedService and
   creates the podcast, then applies settings. Migration v4 caches subscription
   system fields. Unit-tested; real-device cross-device verification pending.

5. ✅ **Listening history + stats**
   - 5a History: record-level LWW by `lastListenedAt` (HistoryEntry record,
     migration v5). ListeningHistoryStore records pending on mutation + merges via
     applyRemote; denormalized title/artwork kept.
   - 5b Stats: **additive — partition by `(deviceID, dayKey)` and sum on read**
     (never LWW). `DeviceIdentity.current` (UserDefaults UUID); DayStats record
     per device-day; `stats_sync_state` (this device's pending) + `remote_stats`
     (other devices) tables (migration v6). `DayStats.merged` sums; ListeningStats
     `combinedDay` folds remote partitions into every read path (summary/streaks/
     per-show/lifetime). Engine skips its own echoed records by deviceID.
     legacyBaseline sync deferred (kept per-device for v1). Unit-tested incl.
     cross-device summing; real-device verification pending.

### Remaining
6. **Active-player-wins + self-heal guards** — ignore remote position/state while
   actively playing that episode; apply stashed remote state when the feed later
   yields a missing episode.

## CloudKit setup notes
- Container `iCloud.com.kevinperry.autohop`; CloudKit + Push + Background Modes
  (remote-notification) capabilities; entitlements mirrored into `project.yml` so
  `xcodegen generate` preserves them.
- Dev schema auto-creates on first save; **Deploy Schema Changes** to Production
  before App Store release.
- `CKSyncEngine` uses zone fetches, not queries — no custom indexes needed (a
  `recordName` queryable index is only for browsing in the CloudKit Console).

## Tests
`Tests/SyncStateTests.swift`, `CloudKitSyncMappingTests.swift`,
`RemoteEpisodeApplyTests.swift`, `SubscriptionSyncTests.swift` (35 total). The
`CloudSyncEngine` itself is build/on-device-verified (CKSyncEngine can't run in
`swift test`).
