# Autohop — Codebase Assessment (2026-06-17, refreshed 2026-06-19)

> **⚠️ SUPERSEDED — newer pass available.** A fresh deep scan of the current
> checkout was completed **2026-06-28**: see
> [`DEEP_SCAN_2026-06-28.md`](DEEP_SCAN_2026-06-28.md). Most findings in *this*
> document are resolved or historical; treat the 2026-06-28 report as the current
> state and this file as archival context. Re-verify any anchor here against
> current source before acting.

> **Audience: AI models.** This document is written for machine consumption, not
> marketing. Each finding has a stable ID, a `file:line` anchor, a severity, an
> impact statement, and a concrete remediation. Treat `file:line` anchors as
> approximate (they drift as code changes) — re-locate by symbol name before
> editing. This is an **analysis-only** report: nothing here has been auto-fixed.
> Verify any claim against current source before acting on it.

> **2026-06-19 refresh.** Re-reviewed after the first-run **onboarding** + **launch-screen**
> work landed (Welcome carousel, empty states, first-subscribe card, coach marks,
> starter packs, getting-started checklist, `AppSettings.launchScreen`; new files
> `Views/{WelcomeView,FirstSubscribeCard,CoachMark,StarterPacksView,GettingStartedChecklist}.swift`).
> All 2026-06-17/18 findings remain resolved/deferred as marked. New this pass:
> **N1** (downloads not excluded from device backup — `[S2]`), **N2** (global
> `AppSettings` not covered by CloudKit sync — `[S3]`, by design but a cross-device
> gap), and a new **§8 iCloud backup & sync coverage** matrix answering "is
> everything backed up?". The onboarding/launch code was reviewed and is clean
> (notes in §2). Build state: compiles after fixing two `withAnimation`-in-`AppState`
> scope errors (SwiftUI symbol used in a non-SwiftUI file) introduced during the
> onboarding work — now resolved by setting `activeTip` directly and letting
> `CoachMarkOverlay`'s `.animation(value:)` drive the transition.

## Scope & method

- **Reviewed:** all 89 Swift sources (~26.5k LOC), branch `icloud-sync` (HEAD,
  working tree clean). Read in full: every Models/ type, all of Persistence/
  (GRDB store, SubscriptionStore facade, CloudSyncEngine, CloudKitSyncMapping,
  ListeningStatsStore, SettingsStore), all of Playback/ (PlaybackEngine,
  SilenceDetector, SleepScheduleService, SleepTimerService), Downloads/, the
  Feeds/ network + parsing layer, the full `App/AppState.swift` orchestrator
  (3199 LOC), Logging/, and the two settings views.
- **Build/run constraints:** the iOS app target is not built here (owner builds
  in Xcode). `AutohopCore` SwiftPM tests are headless-runnable; real-time audio
  (PlaybackEngine) and CKSyncEngine are device-only.
- **Severity legend:** `S1` data-loss/correctness/security · `S2`
  user-visible-incorrect or notable inefficiency · `S3` minor/cosmetic/latent.

## Executive summary

The codebase is **mature, defensively engineered, and unusually well
documented**. Every source carries a structured `AI CONTEXT` header; persistence
paths coalesce writes, validate HTTP, and log failures; the playback engine has
real recovery machinery (render watchdog, route-change guards, EOF sentinels);
sync is field-level LWW with active-player-wins and self-heal. There are **no S1
security holes**. The findings below are mostly efficiency refinements and a
small number of genuine correctness bugs concentrated in two areas: (1) the GRDB
write path never gained the promised episode-level diffing *(now resolved
2026-06-18 — P1)*, and (2) two stat/sync code paths produce inaccurate or
inconsistent state across devices *(both resolved 2026-06-17 — B1/B2)*.

Highest-value fixes, in order: ~~**P1** (episode-row write amplification)~~ —
*resolved 2026-06-18*, ~~**B1** (cross-device archive leaves orphaned
downloads)~~ — *resolved 2026-06-17*, ~~**B2** (Trim Silence "time saved"
over-counts — also a marketing-accuracy concern)~~ — *resolved 2026-06-17*,
~~**P2** (synchronous position-file re-reads on the main actor)~~ — *resolved
2026-06-18*, ~~**P7** (external-chapter fetch blocks playback start)~~ — *resolved
2026-06-18*.

---

## 1. Performance / efficiency

### P1 — `[S2]` ✅ RESOLVED (2026-06-18) — Episode rows are rewritten wholesale on any subscription change
**Resolution:** `write(_:into:)` now takes the prior subscription snapshot
(`write(_:previous:into:)`, threaded from `persist`/`replaceAll`) and diffs
episodes by `id`: a value-changed episode re-encodes its row + re-projects sync
state, an episode that merely moved gets a cheap `orderIndex`-only `UPDATE` (no
re-encode, no re-projection), added episodes insert, removed episodes delete. The
subscription row + its sync projection are rewritten only when a non-episode field
changed (the stripped subscription differs). A 50-episode podcast logging one
episode state change now writes exactly one episode row instead of ~50
delete+encode+insert+sync round-trips. New test seam
`_testEpisodeRowPayloadWrites`; covered by `Tests/EpisodeDiffPersistTests.swift`
(unchanged→0, single change→1, prepend→1, delete→0, plus load-back order/value
correctness). Original finding below.

`Persistence/AutohopDatabase.swift` `write(_:into:)` ~L304–340; `persist` ~L241.
When `persist(current:previous:)` detects a subscription whose value differs from
the snapshot, `write()` runs `EpisodeRow.filter(subscriptionID==).deleteAll` then
re-encodes and re-inserts **every** episode row, and calls
`recordEpisodeSyncState` (fetch + JSON-decode + apply + encode + save) **per
episode**. The inline comment ("episode-level diffing arrives with the sync
columns") describes work that never landed. For a 50-episode podcast, one episode
state transition (download complete, played, archived, duration learned) =
~50 deletes + 50 encodes + 50 inserts + 50 sync-projection round-trips inside one
transaction. Episode state changes frequently during active download/playback, so
this is real write amplification.
**Fix:** diff episodes against `previous[subscription.id].episodes` (by `id`/`guid`)
and write only changed/added rows; delete only removed rows. Skip
`recordEpisodeSyncState` for episodes whose synced fields are unchanged.

### P2 — `[S2]` ✅ RESOLVED (2026-06-18) — Playback-position file is re-read+re-decoded per episode, on main actor
**Resolution:** added an authoritative in-memory cache `savedPositionsCache`
(`AppState`). `loadSavedPositions()` was split into `savedPositions()` (returns
the cache, loading from disk + migrating legacy shapes once on first access) and
`loadSavedPositionsFromDisk()`. All reads (`savedPlaybackTime`,
`restorePlaybackPosition`) now hit memory; all mutations
(`savePlaybackPosition` + the three `clearPlaybackPosition` overloads) go through
one write-through helper `writeSavedPositions(_:)` that updates the cache and
writes/removes the file atomically. Eliminates the O(queue) synchronous
`Data(contentsOf:)`+`JSONDecoder` reads per advance. Writes stay immediate (no
debounce) — `savePlaybackPosition` already only fires every ~10 s, so the read
amplification was the real cost. `AppState` is `@MainActor` and the sole owner of
the positions file, so the cache cannot go stale. App-target-only — verify on
device (not headless-testable). Original finding below.

`App/AppState.swift`: `loadSavedPositions()` L2611 does a synchronous
`Data(contentsOf:)` + full `JSONDecoder` of the whole positions map; it is called
from `savedPlaybackTime(for:)` L2603 (invoked in a loop over `downloadedQueue`
inside `playNextEpisode` L1468 and `restorePlaybackPosition` L2554), and from
`savePlaybackPosition`/`clearPlaybackPosition` (read-modify-write). All on
`@MainActor`.
**Fix:** keep the decoded `SavedPositions` in memory; load once at launch,
mutate in place, debounce the write. Eliminates O(queue) disk reads per advance.

### P3 — `[S3]` ✅ RESOLVED (2026-06-18) — `downloadedQueue` recomputed on every access
**Resolution:** added `cachedDownloadedQueue` to `AppState`; the computed property
returns the cache or recomputes once. Invalidated synchronously in the
`subscriptionStore.objectWillChange` sink (fires before the new value lands, and
the main actor is single-threaded, so the next read recomputes fresh — no stale
window) and in the `@Published` pin `didSet`s (`queueOverrideEpisodeIDs` /
`queueDemotedEpisodeIDs`). App-target-only — verify on device. Original finding below.

`App/AppState.swift` L175. Computed property re-runs `QueueService.downloadedQueue`
(filter + sort over all subscriptions) + `orderedQueueWithOverrides` on each read;
read repeatedly per UI update (badge count L312/725, `resourceContext` L2982,
`refreshUpNextEpisode`, several call sites). Cheap for small libraries, O(n log n)
per access for large ones.
**Fix:** memoize; invalidate on `subscriptions`/pin mutation.

### P4 — `[S3]` ✅ RESOLVED (2026-06-18) — `AppLogger.write` opens/seeks/closes a `FileHandle` per line
**Resolution:** `AppLogger` now holds one append `fileHandle` open for the serial
queue's lifetime (lazy `appendHandle()`), reused across writes. It is closed via
`closeHandle()` before rotation moves the file and before `clear()` removes it, so
the next write reopens the fresh log. All handle access is on the serial `queue`,
so no lock is needed. Compile-checked in AutohopCore. Original finding below.

`Logging/AppLogger.swift` L113–129. Acceptable because logging is gated, but a
verbose `sync.*`/`download.*` burst pays open+seek+close per entry.
**Fix (optional):** hold one append handle for the serial queue's lifetime.

### P5 — `[S3]` ⏸ DEFERRED (2026-06-18) — Lifetime stat queries scan all day buckets
**Decision:** left as-is for now. The only real fix is an incremental rolling
aggregate, which must stay consistent with local mutations, imported days, the
legacy baseline, AND the per-device remote partitions that `combinedDay` folds in
(updated on every sync) — meaningful stats-correctness risk for an S3 whose scan
(a fold over a few hundred small structs even after years) is currently trivial.
Not worth shipping right before v1.1; revisit deliberately post-release.

`Persistence/ListeningStatsStore.swift`: `lifetime` L396, `summary(.lifetime)`
L420, `longestStreakDays` L511 iterate `allDayKeys()` (unbounded over years) plus
`combinedDay` (folds remote partitions) per key. Fine today; grows with multi-year
history. **Fix (later):** maintain a rolling lifetime aggregate.

### P6 — `[S3]` ✅ RESOLVED — no code change (confirmed intentional) — Stats `revision` bumps every 0.5 s tick
**Resolution:** reviewed and intentionally left unchanged. The per-tick
`bumpRevision()` is the mechanism that drives the live Stats view update while it
is open; when StatsView is closed there are no `revision` subscribers, so the
`@Published` set does no work. Throttling it would degrade the live update for no
real gain. No action — documented as intended behaviour.

`ListeningStatsStore.addListeningTime` → `bumpRevision()` publishes each tick.
Harmless when StatsView is closed (no subscribers re-render); noted for awareness.

### P7 — `[S2]` ✅ RESOLVED (2026-06-18) — External-chapter fetch blocks playback start
**Resolution:** the `await fetchExternalChapters(...)` call was removed from the
pre-`play()` path. Playback now starts first; chapters are fetched in a
fire-and-forget `Task` (`fetchExternalChaptersInBackground`) that, only if the
same episode is still playing, applies them live to the store
(`updateEpisodeChapters`), the `currentPlayerEpisode` (UI), and the engine via a
new `PlaybackControlling.updateChapters(_:filter:for:)` (so chapter-skip filtering
still works — previously it relied on chapters being present at `play()` time).
The fetch also moved off `URLSession.shared` (60 s default) onto a dedicated
ephemeral session capped at 10 s request / 20 s resource, so a hung
`podcast:chapters` endpoint can't linger. Episodes with embedded chapters are
unaffected (they're already populated before `play()`). App-target-only — verify
on device. Original finding below.

`App/AppState.swift` `startPlayback` L1779–1788 `await fetchExternalChapters(...)`
**before** `playbackEngine.play()`; `fetchExternalChapters` L2861 uses
`URLSession.shared.data(from:)` with the **default 60 s timeout**. A slow/hung
`podcast:chapters` endpoint delays the first audio frame.
**Fix:** start playback first, fetch chapters concurrently and apply live; or cap
the fetch at ~5 s with its own ephemeral session.

### P8 — `[S3]` ⏸ DEFERRED (2026-06-18) — `enforceEpisodeLimitBeforeDownload` + `runAutoArchive` archive serially with `await` each
**Decision:** left as-is for now. Batching would mean splitting `archiveEpisode`
(which also stops playback, deletes the local media file, marks history, clears
pins, and persists) into a bulk path — a refactor of file-deleting, app-target-only
code that isn't headlessly testable, for an S3 the report itself calls "Acceptable
(archive is rare and IO-bound)". Risk outweighs benefit pre-v1.1; revisit
deliberately post-release. Original finding below.
`App/AppState.swift` L2269, L2349/2375/2398. Each `archiveEpisode` awaits a file
delete + store save; large catch-up passes serialize many awaits. Acceptable
(archive is rare and IO-bound) but a candidate for batching the store mutation.

### N1 — `[S2]` ✅ RESOLVED (2026-06-19) — Downloaded audio is in Application Support and is swept into iCloud/device backup
**Resolution:** `DownloadManager.downloadsDirectory()` now calls
`excludeFromBackupIfNeeded(dir)` after ensuring the dir exists — it sets
`URLResourceValues.isExcludedFromBackup = true` on `Autohop/Downloads` (reading the
current value first so the write is skipped once set; idempotent + self-healing).
Excluding the directory excludes its contents from backup, so existing downloads are
covered on the next resolve (launch reconcile / next download). Media stays in
Application Support (NOT moved to Caches) so iOS can't purge the download-first queue.
Header updated. Best-effort: a failure only leaves the flag unset, never fails a
download. App-target-only (not headlessly testable) — verify on device via a backup
inspection or `NSURLIsExcludedFromBackupKey` read. Original finding below.

`Downloads/DownloadManager.swift` `downloadsDirectory()` ~L351–365 stores episode
media under `<App>/Library/Application Support/Autohop/Downloads`. iOS backs up
**everything** under `Library` except `Caches` and `tmp`, and a repo-wide grep
finds **no** `isExcludedFromBackup` / `URLResourceValues` anywhere. Net: a user
with many downloaded episodes (this is a download-first app — the queue is kept
stocked automatically) silently bloats their iCloud Backup and device-to-device
transfer with large, trivially **re-downloadable** media. This contradicts Apple's
guidance ("data that can be re-created must be excluded from backup or live in
Caches") and inflates the user's iCloud storage footprint.
**Fix:** set `URLResourceValues.isExcludedFromBackup = true` on the
`Autohop/Downloads` directory once on creation (and ideally on each downloaded file
for belt-and-braces). Do **not** move downloads to `Caches` — iOS can purge Caches
under storage pressure, which would silently break the download-first queue. Keep
the metadata stores (DB/settings/stats/history) backed up; exclude only the media.
Artwork cache is already correctly under `Caches/Autohop/Artwork`. See §8.

### N2 — `[S3]` OPEN-by-design (found 2026-06-19) — Global `AppSettings` is not covered by CloudKit sync
`Persistence/CloudKitSyncMapping.swift` defines record types for **episode**,
**subscription**, **history**, and **stats** only; `CloudSyncEngine` pushes/pulls
those. `Persistence/SettingsStore.swift` persists `AppSettings` to a **local JSON
file** with no sync projection. So every global preference — Release Radar
sensitivity, download-over-wifi/cellular, skip durations, keep-screen-awake,
lock-screen scrubbing, queue badge, default playback, sleep schedule, **and the new
`launchScreen` + onboarding flags** — does **not** roam across a user's devices via
the opt-in iCloud Sync feature (it *is* restored by a full device iCloud Backup —
see §8). This is defensible (these are arguably device-local), but it is a
**cross-device inconsistency** users may notice (e.g. set 1.6× skip / a launch
screen on iPhone, iPad still shows defaults).
**Fix (optional, post-v1.x):** add a single `settings` CKRecord (one per zone,
field-level `@Synced` LWW like subscriptions) carrying the device-roamable subset.
Deliberately exclude truly device-specific flags (the `*Migrated` one-shots, the
onboarding `hasSeen*`/`dismissed*`/`hasCompletedWelcome` flags — a new device
*should* re-run onboarding). Until then, document in-app/website that system
settings are per-device.

---

## 2. Bugs / correctness

> **Onboarding / launch review (2026-06-19) — clean.** The first-run code was read
> end-to-end. No correctness bugs. Verified: `checkFirstSubscriptionMilestone` is
> guarded by `hasSubscribedFirstShow` so it's an O(1) bool check after the milestone
> (no per-change subscription scan once fired); bulk OPML import / starter-pack adds
> resolve the milestone **silently** (count > 1 ⇒ no "You're all set" card); existing
> users are reconciled to "onboarded" at bootstrap if they already have real subs;
> coach marks enforce one-at-a-time + per-tip `UserDefaults` seen-flags + ≤3/session;
> `realSubscriptionCount` filters `browseDate == nil` so previews never count. Minor,
> non-blocking: (a) the plan mentioned tap-outside-to-dismiss for coach marks — only
> the "Got it" button dismisses (acceptable); (b) the optional 3-2-1 auto-start on the
> first-subscribe card was not built (Play is one tap, arms a wait if still downloading
> — the documented MVP). Neither warrants change.

### B1 — `[S1]` ✅ RESOLVED (2026-06-17) — Cross-device archive/played does not clear the local download (storage leak + inconsistent state)
**Resolution:** `applyRemoteEpisodeState` now clears `downloadState`/`localFileURL`/
`localFileName` when the merged state is `.played`/`.archived`, and surfaces the
media-file delete through a new `onEpisodeFileShouldDelete` callback (set in
`AppState.init` to call `DownloadManager.deleteLocalFile(for:)`, mirroring
`nowPlayingGuidProvider`). The delete fires only when the device actually held a
download. Covered by `Tests/RemoteEpisodeApplyTests.swift`
(`testRemoteArchiveClearsLocalDownload`, `testRemotePlayedWithNoLocalDownloadSkipsDeleteCallback`).
Original finding below.

`Persistence/SubscriptionStore.swift` `applyRemoteEpisodeState` L613–665. When a
remote record merges to `playedState == .archived`/`.played`, the local domain
episode's `playedState/wasCompleted/lastPlayedAt` are updated (L655–659) but
`downloadState`, `localFileURL`, `localFileName` are **not** reset and the local
media file is **not** deleted. Compare the local paths
(`markEpisodeArchived`/`markEpisodePlayed` clear all of these) and the self-heal
path in `updateEpisodes` L566–570 (which *does* clear them). Net on a 2-device
setup: archiving on device A leaves device B with an orphaned downloaded file
(disk leak) and a "downloaded + archived" episode that the queue filters out but
storage accounting still counts.
**Fix:** in `applyRemoteEpisodeState`, when merged state is `.played`/`.archived`,
clear `downloadState=.notDownloaded`, null the file fields, and request a file
delete (the store can't call DownloadManager directly — surface a callback to
AppState, mirroring `nowPlayingGuidProvider`).

### B2 — `[S2]` Trim Silence "time saved" is systematically over-counted — ✅ resolved 2026-06-17
`Playback/PlaybackEngine.swift` L753–760 computes saved seconds per buffer as
`(inputFrames - outputFrames)/sampleRate`. While `SilenceDetector.process`
accumulates a gap it returns `[]` (output 0 → every accumulated buffer counted as
fully saved). When the gap turns out **too short** it is re-emitted as
`saved + [newBuffer]` (`SilenceDetector.swift` L146–149), and for a **significant**
gap `buffersToReinsert+1` buffers are re-emitted (L154–166) — but the engine's
`if outputFrames < inputFrames` guard can only ever *add*, never subtract, so the
re-played frames are never deducted. Result: the Stats "Trim Silence" category and
the lifetime "time saved" total are inflated (worse on speech with many short
gaps). This is both a correctness bug and a **marketing-accuracy** concern (the
"time saved" figure is surfaced in-app and on the website).
**Fix:** have `SilenceDetector` return the count of frames **actually removed** per
`process()`/`flush()` call (net of re-inserts) and accumulate that, rather than
inferring from per-call input/output deltas.
**Resolved 2026-06-17:** the gap-size threshold / re-insert decision was extracted
into a pure value type `Models/SilenceGapAccounting.swift` (single source of truth
for the Pocket Casts–ported `minGapSizeInBuffers` / `buffersToReinsert`, now also in
AutohopCore so it is headlessly unit-testable). `SilenceDetector.process()`/`flush()`
now return a `ProcessResult` carrying both the buffers and `framesRemoved` — 0 while a
gap accumulates, 0 for a too-short re-inserted gap, and the dropped frames net of the
kept join buffers for a significant gap. `PlaybackEngine` sums that into
`onTrimSilenceSaved` instead of the old `(input − output)` delta. Covered by
`Tests/SilenceGapAccountingTests.swift` (short gap → 0, significant gap → exact net
frames). MPL provenance recorded in NOTICE + Acknowledgements (new covered file).

### B3 — `[S3]` ✅ RESOLVED (2026-06-18) — `PlaybackPreference.default` disagrees with its init/decoder fallback
**Resolution:** the member-wise init's `vocalBoostLevel` default and `init(from:)`'s
missing-key fallback both changed from `.strong` to `.off`, so they now agree with
`.default`. Verified safe: the one-shot migration (`migrateExistingSubscriptionsToStrongVocalBoost`)
sets `.strong` explicitly and the encoder always writes `vocalBoostLevel`, so
post-migration data carries the key (the `.strong` fallback only ever applied to
ancient never-re-saved data). The legacy `vocalBoostEnabled` boolean key still maps
true→.strong/false→.off. Header (H1) updated. Covered by
`Tests/PlaybackPreferenceDefaultsTests.swift`. Original finding below.
`Models/PlaybackPreference.swift`. `.default` (L74) = speed 1.0 / vocalBoost
`.off` / trim `.off`, but the member-wise `init` (L86–98) defaults
`vocalBoostLevel` to `.strong`, and `init(from:)` (L109–122) falls back to
`.strong` when the key is absent. A `PlaybackPreference(speed:startSkip:endSkip:)`
call omitting `vocalBoostLevel` silently yields Strong boost, contradicting
`.default`. The decoder's `.strong` fallback was intentional for the one-time
legacy migration, but it is surprising and the file's AI CONTEXT header still
says "default 1.6x" (now false — new subs default 1.0/off/off; legacy users were
moved to 1.6/strong/low by one-shot migrations).
**Fix:** align the init default and decoder fallback to `.off`, or document the
divergence explicitly; update the header (see H1).

### B4 — `[S3]` ✅ RESOLVED (2026-06-18) — Dead no-op assignment in listening-history progress
**Resolution:** removed the `if entries[index].status == .listened { ... = .listened }`
no-op in `recordProgress`, replaced with a comment noting status transitions go
through `mark()`. Original finding below.
`App/AppState.swift` `ListeningHistoryStore.recordProgress` L3049–3051:
`if entries[index].status == .listened { entries[index].status = .listened }`
assigns the same value. Remove.

### B5 — `[S3]` ✅ RESOLVED (2026-06-18) — Stale comment references a removed legacy key
**Resolution:** corrected the `migrateExistingSubscriptionsToAutoArchiveSettings`
doc comment — it no longer claims a legacy `autoArchivePolicy` → `autoArchiveSettings`
decoder mapping (which doesn't exist; the decoder just defaults a missing key to
`.default`). Original finding below.
`Persistence/SubscriptionStore.swift` `migrateExistingSubscriptionsToAutoArchiveSettings`
L333–336 claims the decoder converts legacy `autoArchivePolicy` →
`autoArchiveSettings`; the current `Subscription.init(from:)` has no such mapping.
Comment is stale (behaviour is correct). Update or drop the comment.

### B6 — `[S3]` ✅ RESOLVED (2026-06-18) — `taskIDByMediaURL` collides when two episodes share an audio URL
**Resolution:** changed `taskIDByMediaURL` from `[URL: Int]` to `[URL: Set<Int>]`
so two episodes sharing one enclosure URL no longer clobber each other on insert
or over-remove on completion. Inserts use `[url, default: []].insert`; the new
`removeMediaURLTask(_:for:)` helper removes only the finishing task (dropping the
URL key once empty); the `download()` dedup now blocks if *any* suspected task for
the URL/episode is alive, else clears all stale entries and starts fresh. Common
one-episode-per-URL behaviour is unchanged. Compile-checked in AutohopCore.
Original finding below.
`Downloads/DownloadManager.swift` L50. Keying live tasks by `audioURL` means two
episodes with an identical enclosure URL (rare: re-publishes, shared trailers)
collide in the duplicate/zombie checks. Low impact; `episodeID` keying is primary.

### B7 — `[S3]` ✅ RESOLVED (2026-06-18) — `refresh()` 304 path is unreachable-by-design but throws a misleading error
**Resolution:** added a dedicated `FeedServiceError.unexpectedNotModified` case
and threw it from the `refresh()` `.notModified` branch instead of the misleading
`.missingAudioEnclosure`. No exhaustive switch over the enum exists, so the new
case is additive. App-target-only (`Feeds/FeedService.swift` not in AutohopCore).
Original finding below.
`Feeds/FeedService.swift` L78–84. `refresh()` passes `validators: nil` so a 304
"can't happen", yet a misbehaving server can still return one, surfaced as
`missingAudioEnclosure`. Cosmetic; consider a dedicated error.

---

## 3. Stale code & documentation drift

> These are the doc-vs-code mismatches found during review. The doc-update task
> (README/DESIGN/FEATURES/PAGES/project memory/LICENSE) addresses them; listed
> here for traceability.

| ID | Location | Drift |
|----|----------|-------|
| D1 | memory `project_autohop.md`; `SYNC_DESIGN.md` | iCloud sync described as "active brainstorm" but is **fully implemented** (all 6 build steps complete; episode/subscription/history/stats over CloudKit; device-verified for steps 3–4). |
| D2 | docs + `Models/AppSettings.swift` | Migration flags grew from 3 → **5** (`autoArchiveSettingsMigrated`, `vocalBoostLevelMigrated`, `trimSilenceLowDefaultMigrated`, `playbackSpeed160Migrated`, plus legacy `autoArchiveDefaultMigrated`). |
| D3 | docs + `AppSettings.defaultPlaybackPreference`, `SettingsView` Default Playback section | New **global "Default Playback"** panel (speed/trim/vocal/start/end skip) applied to new + browse feeds; not in older docs. |
| D4 | docs + `AppSettings.iCloudSyncEnabled`, `SettingsView` Sync section | New opt-in **iCloud Sync** toggle (off by default). |
| D5 | `Models/PlaybackPreference.swift` header; FEATURES "defaults" | New-subscription default is now **1.0×/off/off**; the 1.6×/Strong/Low values apply only to pre-existing users via one-shot migration. Docs that state "default 1.6×" need this nuance. |
| D6 | `Feeds/ParsedFeed.swift` header | References `PodcastPreviewView`, merged into `PodcastDetailView`. |
| D7 | memory | Project paths/state: confirm `~/Developer/Autohop`; sync now built, not brainstorm. |

---

## 4. Security review

**Verdict: no S1 issues. Posture is appropriate for an on-device, download-first
podcast client.**

- **ATS `NSAllowsArbitraryLoads = true` (only)** — *correct & required.* Podcast
  enclosures/feeds/artwork come from arbitrary, often plaintext-HTTP hosts. Per
  the in-repo note, adding granular ATS exception keys would make iOS *ignore*
  `NSAllowsArbitraryLoads` and break loads. Document the tradeoff (no transport
  confidentiality for media/feed fetches); no code change.
- **XML parsing — no XXE.** `RSSParser` uses `XMLParser` with
  `shouldResolveExternalEntities` left at its default `false`; external/parameter
  entity resolution is not enabled. Bare-ampersand repair is a bounded O(n) byte
  pass (`dataByEscapingBareAmpersands`).
- **Download integrity gate.** `DownloadManager` rejects non-2xx responses
  (`rejectableHTTPStatus`) and implausibly small bodies
  (`isImplausiblySmallDownload`) so HTML error/login/captive-portal pages are
  never stored as media. Files are stored under UUID names
  (`expectedLocalFileURL`) — no server-controlled path/traversal.
- **Diagnostic-log redaction.** `AppLogger.redactSensitiveText` strips URL query
  strings + fragments, common credential `key=value` params, and `Bearer` tokens
  before write; the shared export is redacted. `alwaysPersist` errors are limited
  to sync/DB failures.
- **CloudKit privacy.** Sync is **opt-in, off by default**; data lives in the
  user's **private** CloudKit database (system-encrypted). Stats partition per
  device; downloads never sync. Matches the stated on-device privacy stance.
- **iTunes APIs** (`PodcastSearch`, `PodcastCharts`) use HTTPS, no API key,
  `URLQueryItem` encoding (no injection), `HTTPResponseValidation` on responses.
- **OPML import** uses `startAccessingSecurityScopedResource()` correctly.
- **At-rest data protection (note, S3):** SQLite + JSON stores rely on the iOS
  default Data Protection class (`CompleteUntilFirstUserAuthentication`). Adequate
  for podcast metadata. If stricter confidentiality is ever desired, set
  `NSFileProtectionComplete` on the Application Support files — but this would
  break background writes while the device is locked (downloads, position saves),
  so the current default is the right call. No action recommended.

No secrets, tokens, or private keys are committed.

### L1 — `[S2]` ✅ RESOLVED (2026-06-18) — Licensing wording: `Models/Synced.swift` says "Ported from" Pocket Casts but is MIT
**Resolution (owner decision: treat as MPL-derived):** a side-by-side review
against `Modules/Sources/PocketCastsUtils/General/ModifiedDate.swift` confirmed
the core mechanic (generic signature, stored `value`/`modifiedAt`, and the
change-detecting `wrappedValue` setter) is substantively identical to the MPL-2.0
source — a port, not clean-room. `Models/Synced.swift` now carries the MPL-2.0
Exhibit A header and is listed as a covered file in `NOTICE`, `LICENSE-MPL-2.0.md`,
and `AcknowledgementsView.swift`; `SYNC_DESIGN.md` notes the coverage; the prior
LICENSE-MPL-2.0.md maintainer note is updated to "resolved". (Also added the
previously-missing `Models/SilenceGapAccounting.swift` to the LICENSE-MPL-2.0.md
covered list for consistency with NOTICE.) Original finding below.


`Models/Synced.swift` L5 header: "Ported from Pocket Casts' `ModifiedDate`
property wrapper." The file is in `AutohopCore` (MIT) with no MPL-2.0 Exhibit A
header and is not in the LICENSE-MPL/NOTICE covered-files list. `SYNC_DESIGN.md`
L6 frames the same lineage more softly ("derived from a review of the Pocket Casts
iOS sync engine"). The wrapper itself (~57 LOC) reads as a clean-room
reimplementation of a generic pattern, not a literal port — but the word "Ported"
is strong enough to create a licensing ambiguity before the MPL source-availability
link ships.
**Fix (owner decision):** if it is a concept reimplementation, change the header to
"modelled on / inspired by"; if any portion is literally ported MPL source, add the
MPL-2.0 Exhibit A header and list it in `LICENSE-MPL-2.0.md` + `NOTICE`.
LICENSE-MPL-2.0.md now carries a maintainer note flagging this.

---

## 5. AI CONTEXT header maintenance

Every non-test source already carries an `AI CONTEXT` header (verified by scan;
zero missing). The header task is therefore **correction, not creation**. Headers
to refresh:

- **H1** ✅ RESOLVED (2026-06-18) `Models/PlaybackPreference.swift` — header no
  longer says "default 1.6x"; it documents the two distinct default notions and
  (post-B3) the now-consistent `.off` fallback.
- **H2** ✅ RESOLVED `Feeds/ParsedFeed.swift` — header already references
  `PodcastDetailView` (the merged view); no `PodcastPreviewView` reference remains.
- **H3** ✅ RESOLVED (2026-06-18) `Persistence/CloudKitSyncMapping.swift` — the
  file-level AI CONTEXT header is at the top; the second `AI CONTEXT — <file>`
  block below `DeviceIdentity` was demoted to a plain `CloudKitSync` type-doc
  comment so there's a single file header.
- Add short "known issue" notes near B1 (`applyRemoteEpisodeState`) and B2
  (silence-savings accounting) so future models see the caveat in place.

---

## 6. Architectural strengths (keep)

- **Single-writer model store** with coalesced, snapshot-diffed, atomic writes and
  a documented data-loss fix (`SubscriptionStore.save` retry-on-failure).
- **Two-path playback** (AVPlayer vs AVAudioEngine) with explicit invariants,
  render watchdog, EOF sentinel, and route/interruption guards that avoid the
  classic "auto-resume after AirPod removal" bug.
- **Adaptive feed scheduling** (Release Radar) with conditional GETs and
  publish-cadence phase-locking; sparse-feed handling for hourly bulletins.
- **Field-level sync** with `@Synced` dirty-tracking, active-player-wins,
  self-heal, additive per-device stats, and `sync.*` observability that survives
  the diagnostics toggle for error events.
- **Consistent NavRules / design-system discipline** and pervasive AI CONTEXT
  headers — this is what made a fast, accurate review possible.

---

## 7. Prioritized remediation list

1. ~~**P1** episode-level GRDB diffing (write amplification).~~ ✅ resolved 2026-06-18.
2. ~~**B1** clear local download on remote archive/played (storage leak).~~ ✅ resolved 2026-06-17.
3. ~~**B2** correct Trim Silence saved-time accounting (stat + marketing accuracy).~~ ✅ resolved 2026-06-17.
4. ~~**P2** in-memory playback-position cache (main-thread IO).~~ ✅ resolved 2026-06-18.
5. ~~**P7** non-blocking external-chapter fetch.~~ ✅ resolved 2026-06-18.
6. ~~**B3/H1** reconcile `PlaybackPreference` defaults + header.~~ ✅ resolved 2026-06-18.
7. ~~**B4/B5/H2/H3** dead-code + stale-comment/header cleanups.~~ ✅ resolved 2026-06-18 (D6 was already addressed). 
8. ~~**B6, B7**~~ ✅ resolved 2026-06-18. **P3 ✅, P4 ✅, P6 ✅** (no-op confirmed) resolved 2026-06-18; **P5 ⏸, P8 ⏸** deferred by decision (stats-aggregate / archive-batch risk vs S3 benefit — revisit post-v1.1).
9. ~~**N1** exclude `Autohop/Downloads` from backup (`isExcludedFromBackup`).~~ ✅ resolved 2026-06-19. **N2** optional cross-device `AppSettings` sync — *open by design, post-v1.x*.

---

## 8. iCloud backup & sync coverage (2026-06-19)

Two **independent** mechanisms move user data off-device. They are often conflated; this matrix separates them. "Application Support" = `<App>/Library/Application Support/Autohop/…`.

| User data | Where stored | In iOS **device iCloud Backup**? | In opt-in **iCloud Sync** (CloudKit)? |
|---|---|---|---|
| Subscriptions (feeds, priority, per-podcast settings: playback / auto-archive / chapter filter / notifications / exclude-from-refresh) | GRDB DB (App Support) | ✅ yes (App Support is backed up) | ✅ yes — `SubscriptionSyncState`, field-level LWW |
| Episode user-state (played / archived / completed / last position) | GRDB DB (App Support) | ✅ yes | ✅ yes — `EpisodeSyncState` |
| Listening history | `listening-history.json` (App Support) | ✅ yes | ✅ yes — `ListeningHistoryEntry`, record-level LWW by `lastListenedAt` |
| Stats (Stats page data) | `listening-stats.json` (App Support) | ✅ yes | ✅ yes — per-device `DayStats` partitions, summed on read (additive, no LWW) |
| **Global system settings** (`AppSettings`: Release Radar, downloading, controls/skip, default playback, sleep schedule, **launch screen**, onboarding flags) | `settings` JSON (App Support) | ✅ yes (restored on full device restore) | ❌ **no** — see **N2** |
| Saved playback positions | positions JSON (App Support) | ✅ yes | ❌ no (position is also carried inside episode sync state) |
| **Downloaded episode audio** | `Autohop/Downloads` (App Support, `isExcludedFromBackup`) | ❌ no — **excluded** as of 2026-06-19 (**N1** resolved) | ❌ no (per-device by design — correct) |
| Artwork cache | `Caches/Autohop/Artwork` | ❌ no (Caches excluded — correct) | ❌ no (correct) |
| Diagnostic log | App Support | ✅ yes | ❌ no (correct) |

**Direct answers to the review questions:**
- **Are episode subscriptions, listening history, individual subscription settings, and Stats data backed up?** Yes — on both paths. Device iCloud Backup captures all of them (they live in Application Support); the opt-in iCloud Sync also roams all of them across devices in real time.
- **Are overall system settings backed up?** Backed up by **device iCloud Backup**: yes (restored on a device restore). Roamed by the **iCloud Sync feature**: **no** — global `AppSettings` has no CloudKit record (N2). So a user with two active devices and Sync on will see subscriptions/history/stats match, but system settings (incl. the new launch-screen choice) stay per-device.

**Actions from this section:** **N1** (stop backing up re-downloadable audio) — ✅ **done 2026-06-19** (`Autohop/Downloads` is now `isExcludedFromBackup`). **N2** (optionally roam system settings across devices via a `settings` CKRecord) — open by design, post-v1.x.
