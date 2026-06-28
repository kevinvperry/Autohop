# Release Radar v2 — design & build reference

> AI CONTEXT — RELEASE_RADAR_V2.md documents the pure Release Radar classifier and
> scheduler implemented in `Models/Subscription.swift` and protected by
> `Tests/ReleaseRadarSchedulingTests.swift`. Keep this file aligned whenever
> window sizing, weekday watch tiers, safety sweeps, learning inputs, or diagnostic
> exports change. `FEATURES.md` §15.1 is the user-facing counterpart.

Rebuild of feed-schedule classification + windowing. Goal: stop variable publish
*times* from sinking feeds into "Random", and stop wasting refresh slots on days a
show never publishes. Decided with Kevin 2026-06-26; implemented in `AutohopCore`
(`FeedScheduleProfiler` in `Models/Subscription.swift`), tested headlessly via
`Tests/ReleaseRadarSchedulingTests.swift`.

## Core principle: split identity from scheduling
Classification and window-sizing were fused — the old profiler refused to call a feed
"daily/weekly" unless its publish *time* was already tight, which dropped ~37 of 71
real feeds to Random. v2 splits it:

- **Stage 1 — Pattern (identity):** what cadence, and which days? Publish time is
  **never** an input here.
- **Stage 2 — Window (schedule):** given the pattern, when within those days do we
  watch? Publish time only matters here.

## Agreed decisions
- **Scope:** keep the working hourly / rolling-bulletin / burst detectors untouched
  (they hit 94–97%); v2 only reworks what they don't catch (daily/weekly/multi/random).
- **Active days:** learn a per-weekday *publish probability* (fraction of observed
  weeks each weekday published), not a hard set. Labels are read-outs of the shape.
- **Watch intensity (Stage 2):** three tiers — high-probability day → full window,
  medium → light check, near-zero → skipped (this is what saves weekend slots).
- **Commit rule:** assign a pattern on a clear day+cadence signal; else stay Random.
- **Window (Stage 2):** densest-mode primary window, adaptively widened when the
  full observed spread says the feed is genuinely messy, plus a lighter *soft
  tail* / safety sweep for out-of-window releases.
- **Recency (Stage 2):** recent episodes weighted more, but all history counts.
- **DST-stable windows:** each episode's time is taken in whichever representation —
  wall-clock local vs UTC-anchored to the current offset — clusters tighter
  (`dstStableMinutes`), so a UTC-stamped feed doesn't drift ±1h across daylight-saving
  boundaries while a locally-stamped feed keeps its wall-clock time.

## Stage 1 — IMPLEMENTED ✅
`regularCadenceProfile` (runs after hourly/rolling-bulletin/burst):

1. `weekdayPublishProbabilities` → per-weekday likelihood + weeks observed. **Recency-
   weighted** (`weekdayRecencyHalfLifeWeeks` = 8): recent weeks dominate, so a stale or
   biased capture (e.g. The Daily — only its weekly "Sunday Read" was captured in older
   history, masking that it publishes 7 days/week) self-corrects as current data
   accumulates, instead of being permanently diluted by the full span.
2. Active set = weekdays with probability ≥ `activeDayThreshold` (0.6).
3. Classify on shape + cadence (NO publish-time gate):
   - 1 active day + 4–11 day gap → `.weekly`
   - 2–4 active days → `.multiSlot` ("Several times a week")
   - 5+ active days, ≤2 day gap → `.dailyWeekdays`
   - **fallback** — no active day, but one weekday holds ≥`weeklyDominantShareThreshold`
     (0.65) of all episodes on a 4–11 day cadence → `.weekly` by EPISODE SHARE (catches a
     weekly show that skips the odd week, whose per-week probability dips below the bar)
   - else → `.random`
4. `.dailyWeekdays` is shared by Mon–Fri and 7-day feeds;
   `FeedScheduleProfile.categoryLabel` reads `activeWeekdays` to print **Weekdays** vs
   **Daily**. `activeWeekdays` drives scheduling, so a Mon–Fri feed never opens weekend
   slots — no new scheduling machinery needed.
5. Every classified feed carries a **learned `releaseWindow`** around the densest
   publish-time mode, plus `observedSpreadMinutes`. Tight feeds keep a 1-hour floor;
   messy ordinary feeds get a wider floor and a lower confidence so the scheduler
   does not over-trust an over-narrow cluster.
6. `weekdayProbabilities` is stored on the profile for Stage 2's intensity tiers.

Tuning constants live in `FeedScheduleProfiler` (`activeDayThreshold`,
`regularMinimumWeeks`, `multiDayMinimumReliableDates`, …) and will be calibrated
against the exported 71-feed diagnostic.

## Stage 2 — IMPLEMENTED ✅
1. **Densest-mode window** (`releaseTimeWindow`): instead of the full trimmed range, the
   window hugs the densest publish-time cluster (sliding ±`modeSearchHalfWidthMinutes`
   search), so a bimodal feed (Windows Weekly: 4–5am + 9–11am) can get a tight 4–5am
   window.
2. **Adaptive widening**: if the full observed spread is large, or the winning mode
   covers too little of the history, `adaptiveWindowHalfWidth` widens the floor to
   2–4 hours and `regularCadenceConfidence` applies a spread penalty. This keeps
   tight news feeds tight while giving ordinary daily/weekly feeds more room.
3. **Soft tail = existing `.missedRelease`**: after the tight window passes without an
   episode, the feed keeps checking on the decaying missed-release cadence (up to
   `missedReleaseMaxUrgencyAge` = 8 h), which catches the stragglers — no new states.
4. **Broad safety sweeps**: learned non-news feeds (`burst`, `dailyWeekdays`,
   `weekly`, `multiSlot`) get a low-priority fallback check outside the main window
   every 12 h for daily/multi/burst and every 24 h for weekly. Hourly and rolling
   bulletin feeds do not use this; their short minute windows stay precise.
5. **Recency weighting**: publish times are weighted by `pow(0.5, ageWeeks /
   recencyHalfLifeWeeks)`, so a feed that shifts its time retunes within a few weeks
   (all history still counts).
6. **Three-tier watch intensity** (`releaseSlots` + `RefreshSlot.isLight`): high-
   probability weekdays get the full window on high rotation; medium-probability days
   (`lightTierThreshold`..`fullTierThreshold`) get lighter slots (recheck ×
   `lightTierRecheckMultiplier`, no pre-window, no missed-release escalation); low days
   are skipped. Tier thresholds live on `FeedRefreshScheduling`.

Tests: `testWeeklyWindowHugsDensestModeIgnoringStragglers`,
`testWindowFollowsRecentPublishTime`, `testWideSpreadWeekdayFeedGetsBroaderWindowAndLowerConfidence`,
`testLearnedFeedGetsSafetySweepOutsideWindow`, `testMediumProbabilityDayGetsLightTierChecks`.

## Validation — TODO
Re-run the Feed Refresh Schedule export and confirm: ~27–30 Random feeds move to
Daily/Weekdays/Weekly; weekend slots drop for Mon–Fri shows; the TWiT weeklies (incl.
Windows Weekly) land weekly with tight ~4–5am windows. Then calibrate the constants
(`activeDayThreshold`, tier thresholds, `modeSearchHalfWidthMinutes`,
`recencyHalfLifeWeeks`, adaptive widening floors, and safety-sweep intervals) against
the real data if needed.

## Diagnostics
Per-subscription **Release Radar Data** screen and the all-feeds text export both show
the v2 gate checks (cadence + active-day, no time gate), learned window, observed spread,
and the **per-weekday watch tiers** — each day's publish probability mapped to Full /
Light / Skip via `FeedRefreshScheduling.watchTier(forProbability:)`. Re-export after
each change to measure impact.
