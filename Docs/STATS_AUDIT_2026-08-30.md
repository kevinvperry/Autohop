# Autohop Stats Subsystem — Independent Audit, 30 August 2026

> **IMPLEMENTED / HISTORICAL SNAPSHOT — 4 September 2026.** This document
> preserves the evidence and recommendations as they existed during the audit;
> its source excerpts, line numbers, diagnostic advice and present-tense defect
> claims are not current. Do not use it as an implementation guide without
> re-reading the live code. Canonical current behavior is documented in
> `FEATURES.md` §12, `DESIGN.md` Stats Page, `PAGES.md`, and `SYNC_DESIGN.md`.
>
> Resolution summary: R1/A1 now use backend-confirmed rendered intervals;
> L1/L2/L3/L5/L6 now have protected, checksummed JSON plus backup,
> JSON↔SQLite startup reconciliation, own-partition CloudKit recovery, durable
> pending rows, and tvOS Application Support storage; L4 now uses a
> ThisDeviceOnly Keychain identity with retired-lineage handling; A2 observes
> calendar/time-zone changes and splits intervals at local boundaries; A4 has
> iOS/tvOS fresh-start parity; A5 uses field-aware monotonic history merging;
> A3's short-range Drift presentation is retained for product relevance with
> its stale 500-entry rationale removed. For A6, the product decision is to
> preserve the **“7 Days”** label and its existing Monday-to-now behavior; the
> streak and privacy explanations were corrected. Stats Health, JSON/CSV
> export, importable backup, partial-coverage disclosures, canonical show
> identity and durable episode outcomes are implemented. The speculative new
> metrics in §8.3 remain future opportunities, not accepted requirements.

<!--
AI CONTEXT — Docs/STATS_AUDIT_2026-08-30.md
Historical research-only audit of listening-stats recording, interpretation, and backup.
Commissioned because Kevin suspects Stats data is being lost over time.

NO CODE WAS CHANGED BY THE ORIGINAL AUDIT. Items below were proposals at that
time; see the implementation-status notice above for their current disposition.

Read against the working tree at commit 9e8b68f. Every claim was derived by
reading the current source, with file:line anchors. Following the method lesson
recorded in ASSESSMENT_2026-08-30.md §14, conclusions here come from reading
code paths end-to-end, not from counting occurrences.

Verification vocabulary:
  VERIFIED MECHANISM — the code path demonstrably exists and can fire.
  NOT PROVEN         — the mechanism exists; that it HAS fired on Kevin's
                       device is unproven and needs the log check in §7.
Do not upgrade a VERIFIED MECHANISM to "this happened" without §7 evidence.
-->

## 1. Executive summary

Kevin's suspicion is well founded. **There is a verified mechanism by which the
entire local Stats history is silently and irrecoverably destroyed**, and it
leaves a distinctive fingerprint in the diagnostic log that can confirm or clear
it in about a minute (§7).

The core problem is not the arithmetic. The recording maths, the additive
cross-device merge, and the period aggregation are all careful and correct. The
problem is **failure handling at exactly one place**: `ListeningStatsStore.load()`
treats "I could not read the file" and "there is no file" as the same thing, and
the next write commits that emptiness permanently.

| # | Finding | Severity | Status |
|---|---|---|---|
| **L1** | A failed load silently yields an empty store, then `init()` immediately overwrites the real file | **Critical** | VERIFIED MECHANISM |
| **L2** | `listening-stats.json` is the only persistent store without explicit file protection, making L1 reachable before first unlock | **High** | VERIFIED |
| **L3** | A complete backup of every local day already exists in SQLite and CloudKit, and is never used for recovery | **High** (this is the fix for L1) | VERIFIED |
| **L4** | Two live devices can share a `deviceID`, making their stats partitions overwrite each other | Medium-High | VERIFIED MECHANISM |
| **R1** | **Trim Silence inflates listening time and double-counts the trimmed audio as time saved** | **Critical** | VERIFIED |
| **L5** | tvOS stats live in purgeable Caches and cannot be rebuilt from CloudKit | **High** | VERIFIED |
| **L6** | Failed sync-projection writes are retried only in-memory; no startup reconciliation | Medium-High | VERIFIED |
| **A1** | Any playback tick gap >3 s of media time is discarded outright, not clamped | Medium | VERIFIED |
| **A2** | `Calendar.current` is frozen at init; no timezone/day-change observers exist anywhere | Medium | VERIFIED |
| **A4** | tvOS records an episode start on every resume; iPhone only on a fresh start | Medium | VERIFIED |
| **A5** | Whole-record history LWW can discard a larger accumulated `listenedSeconds` | Medium | VERIFIED |
| **A6** | Three presentation defects: "7 Days" is a calendar week, streak ignores the selected period, privacy footer is unconditional | Low-Medium | VERIFIED |
| **A3** | `StatsView` still restricts a feature using a 500-entry cap that is now 5,000 | Low | VERIFIED |

**L1 + L2 + L3 are one story and should be fixed as one change.** L3 is the
reason the fix is cheap: the data needed to recover is already on disk.

**R1 is a separate and equally serious story, and it points the opposite way.**
Kevin's concern was losing data; R1 *inflates* listening time. Both are real and
independent: R1 over-counts whenever Trim Silence is on, while A1 under-counts on
delayed ticks. A user could see totals that are simultaneously too high and
built on discarded intervals. R1 was found by a parallel audit, not by this one —
see §10.

---

## 2. How stats actually flow

Establishing this first, because several findings only make sense against it.

```
0.5 s tick ─► PlaybackCoordinator ─► HistoryStatsCoordinator.recordPlaybackProgress
                                        │  guard delta > 0, delta <= 3   ◄── A1
                                        ├─► ListeningHistoryStore  (listening-history.json, 5,000-entry cap)
                                        └─► ListeningStatsStore.addListeningTime(delta / speed)
                                                │
                    in-memory data.days[dayKey] ─┤
                                                ├─► listening-stats.json   (atomic, 30 s throttle)  ◄── L1/L2
                                                └─► StatsSyncRow (SQLite)  (30 s coalesce)          ◄── L3
                                                        │
                                                        └─► CloudKit "stats:<deviceID>:<dayKey>"    ◄── L4
                                                                │
  other devices' partitions ◄── RemoteStatsRow (SQLite) ◄────────┘
```

Two facts that matter throughout:

1. **`listening-stats.json` is the sole source of truth for *this* device's
   history.** `remoteByDayKey` holds only *other* devices' partitions
   (`ListeningStatsStore.swift:360-376`), deliberately, to avoid double-counting.
   So local file loss is not covered by the remote merge.
2. **`StatsSyncRow` is a complete, current, unpruned mirror of every local day
   bucket**, written on every flush (`AutohopDatabase.swift:1226`). Nothing ever
   deletes these rows — the only `deleteAll` calls in the database are for
   `EpisodeRow`/`SubscriptionRow` in the one-time JSON import path
   (`AutohopDatabase.swift:399-400`). This mirror is the untapped recovery source.

---

## 3. Data-loss findings

### L1 — A failed load silently empties the store, then commits it *(Critical)*

```swift
// Persistence/ListeningStatsStore.swift:998
private func load() {
    guard let url = fileURL,
          FileManager.default.fileExists(atPath: url.path),
          let encoded = try? Data(contentsOf: url),
          let loaded = try? JSONDecoder().decode(ListeningStatsData.self, from: encoded)
    else { return }          // ← file exists but unreadable ⇒ indistinguishable from "no file"
    data = loaded
}
```

Both `try?` operators discard their error. If the file **exists but cannot be
read or decoded**, `load()` returns having changed nothing, leaving `data` as a
freshly constructed empty `ListeningStatsData()`. There is no log line, no
quarantine copy, no retry, and no distinction from a genuine first launch.

**The store then destroys the file immediately, inside `init()`:**

```swift
// Persistence/ListeningStatsStore.swift:491
public init(fileURL: URL?, legacyFileURL: URL?) {
    ...
    load()                        // fails silently ⇒ data is empty
    importLegacyBaselineIfNeeded()
}

// :1009
private func importLegacyBaselineIfNeeded() {
    guard data.legacyBaseline == nil, data.days.isEmpty,   // ← BOTH true after a failed load
          let legacyURL = legacyFileURL,
          FileManager.default.fileExists(atPath: legacyURL.path),
          ... else { return }
    ...
    save()                        // ← atomic overwrite of the still-good file
}
```

`save()` writes with `.atomic` (`:872`), so the overwrite is clean and complete.
**The prior contents are gone.**

This fires for any long-standing user, because the trigger condition is
`playback-stats.json` existing — and **that legacy file is never deleted**
(verified: no `removeItem` for it anywhere in the codebase; the header at `:1007`
states it is "left in place untouched"). Kevin, as a pre-daily-bucketing user,
certainly has it.

**Resulting symptom:** Stats collapse to the legacy lifetime baseline with zero
daily history — Lifetime totals survive (from the baseline), while every
heatmap, monthly trend, listening clock, streak, and per-show breakdown resets.
That is a very specific signature, and §7 says how to check for it.

Even without the legacy file, the outcome is only marginally better: the store
stays empty in memory for the whole process, and the **next** `save()` — which
happens on any playback pause (`PlaybackTransportWorkflow.swift:78`), sleep-timer
pause (`PlaybackCoordinator.swift:379`), or scene checkpoint
(`AppState.swift:1102`) — commits the emptiness anyway.

> **Note on a path I initially over-weighted.** I first suspected background
> download completions as the trigger. They are not: `recordDownload` uses
> `mutateToday(persistImmediately: false)` (`:581`), which deliberately skips the
> save. That is good defensive design and it does reduce exposure. It does not
> close L1, because `importLegacyBaselineIfNeeded()` saves unconditionally and
> the later pause/checkpoint saves do too.

### L2 — `listening-stats.json` has no explicit file protection *(High)*

This is what makes L1 reachable in practice.

The project has a dedicated helper, `Persistence/LockedDeviceFileAccess.swift`,
that stamps `completeUntilFirstUserAuthentication` so files remain readable while
the phone is locked (after first unlock). It is applied to **every** other
persistent store:

| Store | Protected |
|---|---|
| `SettingsStore` | ✅ `SettingsStore.swift:48,56` |
| `PlaybackPositionStore` | ✅ `PlaybackPositionStore.swift:191,214` |
| Queue pins | ✅ `QueueCoordinator.swift:128,321` |
| `AutohopDatabase` (SQLite) | ✅ `AutohopDatabase.swift:61,77` |
| Artwork cache | ✅ `CachedArtworkImage.swift:224,299,473,621` |
| Downloaded media | ✅ `DownloadManager.swift:620,669,679` |
| **`ListeningStatsStore`** | ❌ **none** |
| **`ListeningHistoryStore`** | ❌ **none** (`:326` writes raw) |

Both stats stores write to Application Support with `.atomic` but never call the
helper. The codebase also contains **zero** references to
`isProtectedDataAvailable`, `ProtectedDataDidBecomeAvailable`, or
`ProtectedDataWillBecomeUnavailable` (verified by grep across all sources), so
nothing anywhere defers a read until protected data is ready.

**Fairness on severity.** Autohop does not set the
`com.apple.developer.default-data-protection` entitlement (verified absent from
`Autohop.entitlements` and `project.yml`), so the platform default class already
applies, and that default is `CompleteUntilFirstUserAuthentication`. The exposure
window is therefore **after a reboot, before the user's first unlock** — not
every lock. That is narrow. But:

- `ListeningStatsStore()` is constructed **eagerly** in the composition root (`AppState.swift:538`, `AppCompositionRoot.swift:103`), so it loads on *every* launch, including background launches.
- Autohop declares four background modes (`audio`, `fetch`, `processing`, `remote-notification`), so background launches in that window are entirely possible.
- The window recurs on every reboot — iOS updates, crashes, battery-outs — over months of use.
- Relying on an implicit platform default while explicitly stamping every *other* store is precisely the inconsistency that turns a narrow window into a real incident.

### L3 — The recovery data already exists and is never consulted *(High — this is the fix)*

`StatsSyncRow` holds a full, current, unpruned copy of every one of this device's
day buckets. It lives in the SQLite database, which **is** correctly protected and
hardened. The same buckets are also in CloudKit as `stats:<deviceID>:<dayKey>`.

Yet `load()` reads only the JSON, and on failure starts from zero without ever
looking at either.

The ordering makes this slightly non-trivial but entirely tractable:
`syncDatabase` is assigned *after* construction (`:347`, a `var` with a `didSet`
that calls `reloadRemoteStats()`). So recovery cannot happen inside `init()` —
but it can happen in that `didSet`, which is exactly the moment the database
first becomes available.

**Proposed recovery, for discussion — not implemented:**
1. In `load()`, distinguish the three cases. Only "file absent" is a clean first
   run. "Read failed" and "decode failed" should each log an error with
   `alwaysPersist: true` and set a `loadFailed` flag.
2. When `loadFailed` is set, **do not save** until recovery has been attempted —
   this alone converts a permanent loss into a recoverable one.
3. Before overwriting on a decode failure, rename the unreadable file to
   `listening-stats.corrupt-<timestamp>.json` rather than destroying it.
4. In the `syncDatabase` `didSet`, if `loadFailed` or `data.days.isEmpty` while
   `StatsSyncRow` is non-empty, rebuild `data.days` from those rows.
5. Add the same `completeUntilFirstUserAuthentication` stamp both stats stores are
   currently missing, via the existing helper.

Step 4 also repairs devices that have *already* silently lost history, provided
their database survived — which it should have, being separately protected.

### L4 — Two live devices can share a `deviceID` *(Medium-High)*

```swift
// Persistence/CloudKitSyncMapping.swift:32
public enum DeviceIdentity {
    private static let key = "com.autohop.sync.deviceID"
    public static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
```

The identity lives in `UserDefaults`, **which is included in device backups and
restored**. Restoring a backup onto a new iPhone while the original remains in
use gives two live devices the same `deviceID`.

Per-device partitioning is what makes stats additive. Once two devices share an
ID, the pull path actively discards the other's data:

```swift
// Persistence/CloudSyncEngine.swift:1557
if deviceID == DeviceIdentity.current {
    // "our own per-device partition" — cache server change tag,
    // keep the local bucket dirty as the source of truth for the retry
    return .unchanged          // ← the other device's day is DROPPED
}
```

The clone then pushes its own full day bucket over the record. Both devices
ping-pong, each overwriting the other, and whichever pushed last wins. Listening
time on the loser is permanently gone. Correct for one device per ID; destructive
for two.

**Corroborating evidence this is not merely theoretical:** the engine has
purpose-built DayStats conflict-storm instrumentation —
`sync.conflictStorm`, per-`recordName` conflict trackers, and metadata carrying
`isLocalStatsPartition` and `statsConflictResolution`
(`CloudSyncEngine.swift:1618-1636`). Someone built that because DayStats
conflicts were being observed. A single device per ID should rarely produce them.
§7 says how to check.

**Proposed fix:** move the identity to the Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which is excluded from
backups. A restored device then generates a fresh ID, its partitions stay
separate, and the additive merge works as designed. Migrate the existing
`UserDefaults` value on first run so current partitions are not orphaned.

---

## 3A. Recording-correctness findings (added after cross-audit — see §10)

### R1 — Trim Silence inflates listening time and double-counts it as saved *(Critical)*

The engine reports playback position from the **source file** position, which
advances across audio that Trim Silence removed:

```swift
// Playback/PlaybackEngine.swift:1058
// The file position AFTER reading this chunk = end of this chunk in the file.
let chunkEndSeconds = Double(file.framePosition) / sampleRate
...
// :1149  (inside the .dataRendered completion)
self.engineCurrentFileSeconds = chunkEndSeconds
```

`file.framePosition` advances by the full chunk that was **read**, while
`detector.process` (`:1060`) removes silent frames so that only part of it is
**heard**. The removed frames are separately credited as time saved
(`reportTrimSilenceSaved`, `:1179`).

This is **correct for the scrubber** — the episode must reach its own end — but
it is wrong as a listening-time input, because `HistoryStatsCoordinator` treats
media-position delta ÷ speed as elapsed wall time
(`HistoryStatsCoordinator.swift:168-187`).

**Worked example**, 10 s of source containing 2 s of trimmed silence, at 1.0×:

| Quantity | Truth | Recorded |
|---|---|---|
| Wall time actually elapsed | 8 s | **10 s** (delta 10 ÷ 1.0) |
| Time saved by Trim Silence | 2 s | 2 s ✓ |

The 2 s is counted **twice** — once as listening, once as saved. Listening totals
are inflated by approximately the trim rate, which on a talk podcast at High can
be 10–20%.

**Interaction with A1.** This also makes the `delta <= 3` ceiling trip far more
often than tick delay alone would: a long trimmed gap advances the source
position several seconds within one tick, so the *whole* interval — including
genuine listening — is discarded. R1 is therefore the dominant cause of both the
over-count and the discards; A1's tick-delay analysis remains valid but is the
smaller contributor. Fixing R1 requires fixing A1's seek handling first, since
both need position deltas replaced by an explicit signal.

**Direction of the fix.** Listening time should come from a monotonic wall clock
(or rendered-frame count), not from media-position deltas. Media position,
explicit seeks, automatic skips, and trimmed frames should each be separate,
explicitly-signalled inputs. That is a real piece of work, not a patch — but the
current arithmetic cannot be made correct while a single ambiguous delta carries
four different meanings.

### L5 — tvOS stats live in purgeable Caches and cannot be rebuilt *(High)*

```swift
// TV/App/TVAppDependencies.swift:18
let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
let databaseDirectory = cachesDirectory?.appendingPathComponent("Autohop", isDirectory: true)
...
let statsStore = ListeningStatsStore(
    fileURL: databaseDirectory?.appendingPathComponent("listening-stats.json"),
    legacyFileURL: nil
)
```

The file header states the rationale: *"Rebuildable TV databases live in Caches.
CloudKit remains the sole durable cross-device transport."* For the subscription
and projection databases that is sound — they genuinely are rebuildable.

**It is not true of stats.** The Apple TV's own listening is authored only on the
Apple TV. It is pushed to CloudKit as `stats:<tvDeviceID>:<dayKey>`, and the pull
path then refuses to read it back, because the record's device ID matches the
local one (`CloudSyncEngine.swift:1557`, the same mechanism as L4). So when tvOS
purges Caches — which it does aggressively under storage pressure, on devices
with little storage — **the Apple TV's listening history is permanently lost
despite being intact in CloudKit.**

One mitigating detail: tvOS passes `legacyFileURL: nil`, so the L1
immediate-overwrite path cannot fire there.

Fixing L3 (restore from own partition when local state is missing) fixes L5 at
the same time. That is the strongest argument for doing L3 properly rather than
merely defensively.

### L6 — Failed sync writes are retried only in memory *(Medium-High)*

`pendingStatsDayKeys` is an in-process `Set<String>`
(`ListeningStatsStore.swift:386`). `flushPendingStatsDays` correctly retains only
keys whose SQLite write failed (`:449-450`) — good discipline — but that retry
list dies with the process. Nothing at startup reconciles the JSON day buckets
against `StatsSyncRow`.

Consequence: a day whose projection write failed stays locally visible but can
remain absent or stale in CloudKit **indefinitely**, because a historical day is
never mutated again and so is never re-marked pending.

The primitive needed already exists — `AutohopDatabase.pendingStatsDays()`
(`:1240`) — it is simply never used for reconciliation. The same startup pass
proposed for L3 should compare both directions and re-mark divergent days.

### A4 — tvOS records an episode start on every resume *(Medium)*

```swift
// TV/Playback/TVPlaybackModel.swift:209 — unconditional, before engine.play
statsStore.recordEpisodeStarted(subscriptionID: subscription.id, showTitle: subscription.title)
```

iPhone records it only for a genuinely fresh start:

```swift
// App/PlaybackStartWorkflow.swift:167
if start.isFreshStart {
    historyStatsCoordinator.recordEpisodeStarted(...)
}
```

So reopening or retrying an episode on Apple TV inflates `episodesStarted` and
`perShowEpisodesStarted`. Because DayStats partitions merge **additively**, this
tvOS inflation propagates into the combined cross-device figures — it is not
contained to the TV. It also skews completion rate, whose denominator is starts.

### A5 — Whole-record history LWW can discard accumulated listening *(Medium)*

```swift
// Persistence/ListeningHistoryStore.swift:297
guard normalizedRemote.lastListenedAt > entries[index].lastListenedAt else { return false }
entries[index] = normalizedRemote        // ← whole record replaced
```

`ListeningHistoryEntry` carries an accumulated `listenedSeconds`. A device that
listened briefly but *more recently* replaces a record in which another device
had accumulated far more — the larger total is silently lost.

Scope is limited: DayStats, not history, is the source for headline totals, and
it is additive per device. The loss lands on per-episode completion/cadence
evidence and the resume position. Real, but well below R1/L1.

### A6 — Three user-visible presentation defects *(Low-Medium)*

1. **"7 Days" is not seven days.** The pill labels `.thisWeek` as "7 Days" (`Views/StatsView.swift:110`), but the underlying period is `StatsPeriod.currentWeek` = `days(from: startOfCurrentWeek())` — Monday through today. On a Monday it shows **one day** of data under a "7 Days" heading. The same range's This/Last toggle correctly says "This Week"/"Last Week" (`:95`), so the app contradicts itself.
2. **The streak ignores the selected period.** `store.currentStreakDays` (`:411`) takes no period argument and always means the streak ending today/yesterday. Viewing "Last Year" still shows today's streak.
3. **The privacy footer is unconditional.** *"kept on your device and your own iCloud"* (`:1028`) is shown even when iCloud Sync is off, when nothing is in iCloud at all.

## 4. Accuracy and interpretation findings

### A1 — Tick gaps >3 s of media time are discarded, not clamped *(Medium)*

```swift
// App/HistoryStatsCoordinator.swift:168
let delta = time - lastTime
guard delta > 0, delta <= 3 else { return }
```

`delta` is **media position** movement. The ceiling exists to reject seeks — and
it has to, because **seeks do not reset tracking**. Verified: the only caller of
`resetPlaybackTracking()` is the not-playing branch at `:157`, and the only caller
of `beginPlaybackTracking()` is `PlaybackStartWorkflow.swift:182`.
`PlaybackSeekWorkflow` notifies neither. So this single heuristic is the entire
seek defence, and it cannot simply be raised.

The cost is that a *delayed tick during continuous playback* is indistinguishable
from a seek, and is dropped entirely rather than clamped. Headroom depends on
which playback path is active:

| Path | Tick source | Media delta/tick | Headroom before loss |
|---|---|---|---|
| AVPlayer | `addPeriodicTimeObserver(0.5 s)` — item timeline, so rate-independent (`PlaybackEngine.swift:789`) | ~0.5 s at any speed | ~6 missed ticks |
| **AVAudioEngine** | **GCD wall-clock timer, 0.5 s + 50 ms leeway** (`PlaybackEngine.swift:1440`) | **0.5 × speed** | **2–3 missed ticks at 2.5×** |

The engine path is not the exotic one. `shouldUseEngine` is true whenever Vocal
Boost, Trim Silence, Mono, or Volume Adjustment is active
(`PlaybackEngine.swift:355-358`), and `PlaybackPreference.newUserDefault` ships
**Strong** vocal boost (`Models/PlaybackPreference.swift:125`), while migrated
existing users were moved to 1.6× / Strong / Low. **The wall-clock timer is the
normal path for real users**, and higher speeds shrink the margin.

Losses are silent, systematic, and biased toward exactly the heavy, high-speed,
background-listening sessions Autohop is built for — so they would read as
"stats drift low over time" rather than as a visible fault.

**Proposed fix (order matters):** make seeks explicit first —
`PlaybackSeekWorkflow` calls `beginPlaybackTracking(at:)` after every seek — then
the ceiling can be raised substantially and the residual gap *clamped* (credit
`min(delta, ceiling)`) instead of dropped. Do not raise the ceiling before
seeks are explicit.

### A2 — Frozen calendar, and no timezone or day-change observers *(Medium)*

`private let calendar = Calendar.current` (`ListeningStatsStore.swift:341`)
captures the calendar — and therefore the **time zone** — once, at construction.
`dayKey(for:)` (`:965`) and `startOfWeek`/`recentDays`/`summaryCacheDayKey` all
use it.

The codebase contains **zero** observers for `NSSystemTimeZoneDidChange`,
`NSCalendarDayChanged`, or `UIApplication.significantTimeChangeNotification`
(verified by grep across all sources).

Consequences for a long-lived process — and Autohop is explicitly designed for
multi-hour background audio:
- Travelling across time zones keeps bucketing into the departure zone's days and hours until the process restarts. The 24-hour listening clock is directly wrong.
- The midnight rollover that invalidates `summaryCache` (`:636`) uses the same stale zone, so "today" can be a day behind.

Low frequency, but travel is a first-class use case for a podcast app, and the
listening clock is a marquee Stats feature.

### A3 — A live UI restriction is justified by a cap that no longer exists *(Low)*

`Views/StatsView.swift:688` reads:

> `/// "Shows You're Drifting From" — short ranges only: the 500-entry history cap`
> `/// silently truncates longer ranges, and a year-old struggle isn't actionable.`

The cap is now **5,000**, and `ListeningHistoryStore.swift:42-47` documents the
raise explicitly ("Five hundred entries could represent only weeks for a heavy
listener and silently falsified yearly/lifetime show details").

The restriction may still be right on the second ground (a year-old struggle
isn't actionable), but half its stated rationale is stale by an order of
magnitude. Worth re-deciding deliberately rather than inheriting.

Separately: history retention is still bounded, and `entries.removeLast(...)`
(`:180`, `:309`) drops the oldest. At ~10 episodes/day that is roughly 16 months.
DayStats (unbounded) is the count source, so headline totals are safe — but
per-show *outcome/cadence* detail for older periods degrades as history rolls
off. That is a deliberate trade-off; it should just be a known one.

---

## 5. What is well built — do not regress these

Stated explicitly so a future change does not "simplify" away a load-bearing
decision:

- **`DayStats.merged(with:)` (`:163`) is genuinely additive** across every field, with the comment "NEVER last-write-wins." This is the correct choice and the tests cover it (`StatsSyncTests.testMergedSumsAdditively`).
- **Remote partitions are never merged into `data.days`** (`:360-361`), which is what prevents double-counting on every read.
- **`hourSeconds` is normalised to exactly 24 buckets on decode** (`:197+`), explicitly to survive a malformed CloudKit record. Removing that reintroduces an index-out-of-range crash.
- **The variable-speed saving formula is right**, and the comment at `:513-517` pre-empts the obvious wrong "fix" (dividing by speed). `StatsWriteCoalescingTests.testVariableSpeedSavingsUseWallClockContract` locks it in.
- **`flushPendingStatsDays` retains only failed keys** (`:449-450`) so a failed write is retried rather than silently dropped — precisely the discipline `load()` lacks.
- **Stale-acknowledgement handling**: a CloudKit ack clears only the exact value sent, so an in-flight edit is not lost (`StatsSyncTests.testOldAcknowledgementLeavesNewerStatsDayPending`).
- **Writes are `.atomic`** (`:872`), so torn writes are not a realistic corruption source. I checked this before blaming write durability, and it cleared.

---

## 6. Test gaps

Existing coverage is good on merge/sync mechanics and coalescing (12 test
functions across `StatsSyncTests` and `StatsWriteCoalescingTests`). The gaps map
exactly onto the findings:

| Missing test | Guards |
|---|---|
| Corrupt/truncated `listening-stats.json` ⇒ store does **not** overwrite it | L1 |
| Unreadable file ⇒ distinguishable from absent file | L1 |
| Empty local days + populated `StatsSyncRow` ⇒ days are rebuilt | L3 |
| Two partitions with the same `deviceID` ⇒ no silent drop | L4 |
| Tick delta of 5 s during continuous playback ⇒ credited, not dropped | A1 |
| Timezone change mid-session ⇒ correct `dayKey` | A2 |

`StatsSmokeTests/main.swift` already builds a temp directory with a legacy
`playback-stats.json` (`:42`, `:128`), so the L1 fixture is largely written — a
corrupt-file case would be a small addition.

---

## 7. How to confirm on Kevin's device — do this first

These are read-only checks that convert "VERIFIED MECHANISM" into "this did or
did not happen to me." **Do these before any code change**, because they
determine whether L1 or L4 is the live problem.

1. **Has L1 fired?** Settings → tap Version ×5 → Diagnostics → View Diagnostic
   Log. Search for **`stats.legacyImport`**. That line should appear **at most
   once, ever, in the app's lifetime**. More than one occurrence — or any
   occurrence with a recent timestamp — means the empty-load path ran and
   overwrote real history. This is the single highest-value check in this
   document.
2. **Is the file readable now?** Check whether `listening-stats.json` currently
   decodes and how many `days` entries it holds. Compare that count against the
   number of `StatsSyncRow` rows in the database. **If SQLite holds materially
   more days than the JSON, L1 has already fired and the data is still
   recoverable** — capture the database before doing anything else.
3. **Has L4 fired?** Search the log for **`sync.conflictStorm`** and for
   `isLocalStatsPartition=true` on DayStats conflicts. Recurring storms on the
   same `dayKey` are the shared-`deviceID` signature. Also worth answering
   directly: has any current device been restored from another device's backup?
4. **Sanity-check A1's magnitude.** With diagnostics on, compare a known
   listening session's real duration against the day's recorded
   `wallClockSeconds`. A consistent shortfall of a few percent at high speed
   points at the dropped-tick path.
5. **Check file protection on device.** Confirm whether `listening-stats.json`
   currently carries `NSFileProtectionCompleteUntilFirstUserAuthentication`. If
   it shows `NSFileProtectionComplete`, L2's exposure window is much wider than
   the reboot case and L2 escalates to Critical alongside L1.

---

## 8. Opportunities and new data types

Separating genuine gaps from nice-to-haves.

### 8.1 Durability and trust (highest value)

- **A visible "Stats health" row.** Days recorded, first day, last sync, and any recovery event. Silent subsystems erode trust precisely because failure is invisible — this is what would have surfaced L1 to Kevin months ago.
- **Stats export (JSON/CSV).** A user-initiated export is the only backup that survives losing both the app container and the iCloud zone. It is also the honest answer to "can I trust this data" — and it costs little, since `DayStats` is already `Codable`.
- **A daily integrity checkpoint.** Once per day, compare JSON day count against `StatsSyncRow` count and log/heal any divergence. This turns L1-class problems into self-repairing ones.

### 8.2 Filling real gaps in existing data

- **Backfill `perShowTimeSaved` and `perShowEpisodes*`.** Both were added mid-life (June and August 2026 respectively), and `DayStats` documents that older buckets decode empty (`:92-97`). Per-show sums therefore *undercount* on any range spanning the introduction, with no indication in the UI. At minimum, mark affected ranges as partial rather than presenting them as complete.
- **Same for `bytesDownloaded`/`episodesDownloaded`** — explicitly forward-only from June 2026 (`:109-111`). "Data used" over Lifetime is currently a partial figure presented as a total.
- **Reconcile the legacy-baseline boundary.** The baseline is included only when a period *fully contains* it (`:717-753`), so the period straddling the June 2026 cutover silently drops it and shows a dip. Defensible ("without fabricating daily attribution"), but it should be labelled in the UI rather than looking like a quiet month.

### 8.3 New data types worth capturing

Cheap to add, since they slot into the existing per-day bucket and merge
additively for free:

| Metric | Why it is interesting | Cost |
|---|---|---|
| Seconds by **playback speed** bucket | "You listen at 1.8× on average" — directly ties to the time-saved story | Low |
| Seconds by **audio route** (AirPods / CarPlay / speaker) | Reveals *where* listening happens; CarPlay share is a genuinely novel stat | Low — route is already tracked for the Player label |
| **Completion rate** per show | Started vs completed already exist per show; the ratio is the insight and needs no new storage | None — pure derivation |
| **Time-of-day × show** | "You listen to news at 7am, comedy at 6pm" — the clock exists but is not segmented | Medium |
| **Sleep-timer / Sleep-schedule** listening | Distinguishes attentive listening from falling asleep; would also stop drowsy sessions inflating engagement | Low |
| **Skipped/archived-unplayed counts** per show | The missing half of Drift Detection — currently inferred from history, which rolls off | Low |
| **Longest unbroken session** | A natural companion to streaks, and a distinctive stat competitors do not show | Low |

### 8.4 Interpretation improvements

- **`Calendar` should be re-read, not frozen** (A2), and the store should observe `significantTimeChange`.
- **Streak definition is `≥60 s` per day** (`:471`). Reasonable, but undocumented in the UI — a user who listened for 45 seconds and lost a streak has no way to know why.
- **Per-show "listening share"** currently divides by the period's total; shows listened to before `perShowSeconds` existed distort older comparisons. Worth an explicit "since" boundary.

---

## 9. Recommended order of work

0. **Run §7 checks 1–3.** They are read-only, take minutes, and determine whether anything has actually been lost — and whether it is still recoverable.
1. **Fix R1.** It is actively corrupting every figure on the page right now, for every user with Trim Silence on — which is most of them. Unlike the loss findings, this needs no unlucky trigger; it is happening continuously. It is also the largest single piece of work, because it means replacing position-delta accounting with a monotonic clock and explicit skip/trim/seek signals.
2. **Fix L1 + L2 + L3 + L5 + L6 as one change.** Distinguish load failures, never overwrite after a failed load, preserve the corrupt file, recover from `StatsSyncRow`, and apply `LockedDeviceFileAccess` to both stats stores. This is the whole data-loss story and the recovery source already exists.
3. **Fix L4** by moving `DeviceIdentity` to the Keychain with a `ThisDeviceOnly` accessibility class, migrating the existing value.
4. **A4** (tvOS start parity) — a two-line fix with cross-device impact, so cheap it should ride along with any of the above.
5. **A6** presentation fixes — also cheap, and they are what the user actually reads.
6. **A2, A3, A5** and the §8.1 durability surfaces.
7. Then consider §8.3's new metrics — but only after the recording layer is trustworthy. New data types on an untrustworthy foundation just create more to lose.

**One sequencing warning.** A parallel audit recommends persisting download stats
immediately rather than deferring to a checkpoint (see §10). Taken in isolation
that is right — but doing it *before* L1 is fixed increases exposure, because it
adds save() calls during background wakes, which is exactly when the store may
have loaded empty. Sequence it after L1.

---

## 10. Cross-audit against a parallel review (30 August 2026)

Kevin commissioned a second, independent audit of the same subsystem. I verified
its findings against source rather than accepting or rejecting them. **It found
one Critical defect I missed, plus five other real issues.** Its findings are
integrated above as R1, L5, L6, A4, A5 and A6 rather than kept separate.

### What it caught that I did not

| Its finding | Verified how | Now filed as |
|---|---|---|
| Trim Silence corrupts listening accounting | `PlaybackEngine.swift:1058` — `chunkEndSeconds` is `file.framePosition`, the **source** position, assigned to the reported position at `:1149` while `detector.process` removes frames at `:1060` | **R1 (Critical)** |
| tvOS stats live in Caches | `TVAppDependencies.swift:18` | **L5** |
| No startup reconciliation of failed projection writes | `pendingStatsDayKeys` is in-memory (`:386`); `pendingStatsDays()` (`AutohopDatabase.swift:1240`) exists but has no reconciliation caller | **L6** |
| tvOS records starts unconditionally | `TVPlaybackModel.swift:209` vs `PlaybackStartWorkflow.swift:167` | **A4** |
| History LWW replaces the whole record | `ListeningHistoryStore.swift:297` | **A5** |
| "7 Days" is a calendar week; streak ignores period; privacy footer unconditional | `StatsView.swift:110`, `:411`, `:1028` | **A6** |

**R1 is the significant miss.** I traced the tick path from
`HistoryStatsCoordinator` outward and reasoned about *when* ticks arrive, but I
did not trace *what the position value means* back into the engine. Had I read
`PlaybackEngine`'s buffer loop rather than only its tick interval, the comment at
`:1056` ("The file position AFTER reading this chunk") would have made it
obvious. My A1 analysis was correct as far as it went, but it treated the
position signal as trustworthy and only questioned its timing.

### Where this audit went further

- **L1's actual trigger.** The other audit says a damaged file "can be silently overwritten" by "the next successful save." True, but it does not identify *why* the overwrite is near-immediate: `importLegacyBaselineIfNeeded()` calls `save()` **inside `init()`**, and its `data.days.isEmpty` guard is *satisfied by the load failure itself*. That is the difference between "eventually, on the next pause" and "before the app finishes launching."
- **L2 is absent from the other audit entirely.** It identifies the silent-load hazard but not the file-protection asymmetry that makes it reachable — `listening-stats.json` and `listening-history.json` are the only persistent stores not using `LockedDeviceFileAccess`.
- **Confirming whether it already happened.** The other audit concludes that determining real-world impact "would require a separate read-only inspection." §7 gives a concrete fingerprint instead: `stats.legacyImport` must appear at most once ever, and JSON day count versus `StatsSyncRow` count reveals both the damage and whether it is still recoverable.

### One recommendation to sequence, not adopt as-is

The other audit rates deferred download-stat persistence (`persistImmediately:
false`, `:581`) as a High crash-loss window and recommends persisting discrete
events immediately. The window is real. But that change writes the stats file
during background download completion — precisely the moment when, under L1/L2,
the store may hold an empty in-memory state. Applied before L1, it converts a
narrow crash-loss window into a wider total-loss one. Right fix, wrong order.

### Method note

Both audits independently and correctly identified: the silent-load hazard, the
`delta <= 3` discard, the `UserDefaults` device identity, and CloudKit's refusal
to restore a device's own partition. The divergence was in coverage, not
correctness — this audit went deep on the persistence layer and shallow on the
engine; the other did the reverse. The lesson generalises: when a value crosses a
subsystem boundary, audit what it *means* on the far side, not just when it
arrives.
