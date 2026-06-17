# Autohop — Codebase Assessment (2026-06-17)

> **Audience: AI models.** This document is written for machine consumption, not
> marketing. Each finding has a stable ID, a `file:line` anchor, a severity, an
> impact statement, and a concrete remediation. Treat `file:line` anchors as
> approximate (they drift as code changes) — re-locate by symbol name before
> editing. This is an **analysis-only** report: nothing here has been auto-fixed.
> Verify any claim against current source before acting on it.

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
write path never gained the promised episode-level diffing, and (2) two
stat/sync code paths produce inaccurate or inconsistent state across devices.

Highest-value fixes, in order: **P1** (episode-row write amplification), ~~**B1**
(cross-device archive leaves orphaned downloads)~~ — *resolved 2026-06-17*, ~~**B2**
(Trim Silence "time saved" over-counts — also a marketing-accuracy concern)~~ —
*resolved 2026-06-17*, **P2** (synchronous position-file re-reads on the main
actor), **P7** (external-chapter fetch blocks playback start).

---

## 1. Performance / efficiency

### P1 — `[S2]` Episode rows are rewritten wholesale on any subscription change
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

### P2 — `[S2]` Playback-position file is re-read+re-decoded per episode, on main actor
`App/AppState.swift`: `loadSavedPositions()` L2611 does a synchronous
`Data(contentsOf:)` + full `JSONDecoder` of the whole positions map; it is called
from `savedPlaybackTime(for:)` L2603 (invoked in a loop over `downloadedQueue`
inside `playNextEpisode` L1468 and `restorePlaybackPosition` L2554), and from
`savePlaybackPosition`/`clearPlaybackPosition` (read-modify-write). All on
`@MainActor`.
**Fix:** keep the decoded `SavedPositions` in memory; load once at launch,
mutate in place, debounce the write. Eliminates O(queue) disk reads per advance.

### P3 — `[S3]` `downloadedQueue` recomputed on every access
`App/AppState.swift` L175. Computed property re-runs `QueueService.downloadedQueue`
(filter + sort over all subscriptions) + `orderedQueueWithOverrides` on each read;
read repeatedly per UI update (badge count L312/725, `resourceContext` L2982,
`refreshUpNextEpisode`, several call sites). Cheap for small libraries, O(n log n)
per access for large ones.
**Fix:** memoize; invalidate on `subscriptions`/pin mutation.

### P4 — `[S3]` `AppLogger.write` opens/seeks/closes a `FileHandle` per line
`Logging/AppLogger.swift` L113–129. Acceptable because logging is gated, but a
verbose `sync.*`/`download.*` burst pays open+seek+close per entry.
**Fix (optional):** hold one append handle for the serial queue's lifetime.

### P5 — `[S3]` Lifetime stat queries scan all day buckets
`Persistence/ListeningStatsStore.swift`: `lifetime` L396, `summary(.lifetime)`
L420, `longestStreakDays` L511 iterate `allDayKeys()` (unbounded over years) plus
`combinedDay` (folds remote partitions) per key. Fine today; grows with multi-year
history. **Fix (later):** maintain a rolling lifetime aggregate.

### P6 — `[S3]` Stats `revision` bumps every 0.5 s tick
`ListeningStatsStore.addListeningTime` → `bumpRevision()` publishes each tick.
Harmless when StatsView is closed (no subscribers re-render); noted for awareness.

### P7 — `[S2]` External-chapter fetch blocks playback start
`App/AppState.swift` `startPlayback` L1779–1788 `await fetchExternalChapters(...)`
**before** `playbackEngine.play()`; `fetchExternalChapters` L2861 uses
`URLSession.shared.data(from:)` with the **default 60 s timeout**. A slow/hung
`podcast:chapters` endpoint delays the first audio frame.
**Fix:** start playback first, fetch chapters concurrently and apply live; or cap
the fetch at ~5 s with its own ephemeral session.

### P8 — `[S3]` `enforceEpisodeLimitBeforeDownload` + `runAutoArchive` archive serially with `await` each
`App/AppState.swift` L2269, L2349/2375/2398. Each `archiveEpisode` awaits a file
delete + store save; large catch-up passes serialize many awaits. Acceptable
(archive is rare and IO-bound) but a candidate for batching the store mutation.

---

## 2. Bugs / correctness

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

### B3 — `[S3]` `PlaybackPreference.default` disagrees with its init/decoder fallback
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

### B4 — `[S3]` Dead no-op assignment in listening-history progress
`App/AppState.swift` `ListeningHistoryStore.recordProgress` L3049–3051:
`if entries[index].status == .listened { entries[index].status = .listened }`
assigns the same value. Remove.

### B5 — `[S3]` Stale comment references a removed legacy key
`Persistence/SubscriptionStore.swift` `migrateExistingSubscriptionsToAutoArchiveSettings`
L333–336 claims the decoder converts legacy `autoArchivePolicy` →
`autoArchiveSettings`; the current `Subscription.init(from:)` has no such mapping.
Comment is stale (behaviour is correct). Update or drop the comment.

### B6 — `[S3]` `taskIDByMediaURL` collides when two episodes share an audio URL
`Downloads/DownloadManager.swift` L50. Keying live tasks by `audioURL` means two
episodes with an identical enclosure URL (rare: re-publishes, shared trailers)
collide in the duplicate/zombie checks. Low impact; `episodeID` keying is primary.

### B7 — `[S3]` `refresh()` 304 path is unreachable-by-design but throws a misleading error
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

### L1 — `[S2]` Licensing wording: `Models/Synced.swift` says "Ported from" Pocket Casts but is MIT
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

- **H1** `Models/PlaybackPreference.swift` — "default 1.6x" is stale (see B3/D5).
- **H2** `Feeds/ParsedFeed.swift` — drop the `PodcastPreviewView` reference (D6).
- **H3** `Persistence/CloudKitSyncMapping.swift` — the file-level AI CONTEXT block
  sits *below* the `DeviceIdentity` enum; move/extend it to the top so the file's
  first comment is the header (consistency only).
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

1. **P1** episode-level GRDB diffing (write amplification).
2. ~~**B1** clear local download on remote archive/played (storage leak).~~ ✅ resolved 2026-06-17.
3. ~~**B2** correct Trim Silence saved-time accounting (stat + marketing accuracy).~~ ✅ resolved 2026-06-17.
4. **P2** in-memory playback-position cache (main-thread IO).
5. **P7** non-blocking external-chapter fetch.
6. **B3/H1** reconcile `PlaybackPreference` defaults + header.
7. **B4/B5/D6/H2/H3** dead-code + stale-comment/header cleanups.
8. **P3–P6, P8, B6, B7** opportunistic.
