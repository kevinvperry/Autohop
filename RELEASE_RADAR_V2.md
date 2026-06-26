# Release Radar v2 — design & build reference

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
- **Window (Stage 2):** densest-mode primary window + a lighter *soft tail* for any
  secondary cluster (e.g. Windows Weekly: tight 4–5am + light 9–11am).
- **Recency (Stage 2):** recent episodes weighted more, but all history counts.

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
5. Every classified feed carries a **data-sized `releaseWindow`** (outlier-trimmed
   observed publish-time range, +margin, 1-hour floor) so variable-time feeds don't
   regress to a narrow fixed band. The prediction's daily/weekly/multi cases all honour
   this window.
6. `weekdayProbabilities` is stored on the profile for Stage 2's intensity tiers.

Tuning constants live in `FeedScheduleProfiler` (`activeDayThreshold`,
`regularMinimumWeeks`, `multiDayMinimumReliableDates`, …) and will be calibrated
against the exported 71-feed diagnostic.

## Stage 2 — IMPLEMENTED ✅
1. **Densest-mode window** (`releaseTimeWindow`): instead of the full trimmed range, the
   window hugs the densest publish-time cluster (sliding ±`modeSearchHalfWidthMinutes`
   search), so a bimodal feed (Windows Weekly: 4–5am + 9–11am) gets a tight 4–5am window.
2. **Soft tail = existing `.missedRelease`**: after the tight window passes without an
   episode, the feed keeps checking on the decaying missed-release cadence (up to
   `missedReleaseMaxUrgencyAge` = 8 h), which catches the stragglers — no new states.
3. **Recency weighting**: publish times are weighted by `pow(0.5, ageWeeks /
   recencyHalfLifeWeeks)`, so a feed that shifts its time retunes within a few weeks
   (all history still counts).
4. **Three-tier watch intensity** (`releaseSlots` + `RefreshSlot.isLight`): high-
   probability weekdays get the full window on high rotation; medium-probability days
   (`lightTierThreshold`..`fullTierThreshold`) get lighter slots (recheck ×
   `lightTierRecheckMultiplier`, no pre-window, no missed-release escalation); low days
   are skipped. Tier thresholds live on `FeedRefreshScheduling`.

Tests: `testWeeklyWindowHugsDensestModeIgnoringStragglers`,
`testWindowFollowsRecentPublishTime`, `testMediumProbabilityDayGetsLightTierChecks`.

## Validation — TODO
Re-run the Feed Refresh Schedule export and confirm: ~27–30 Random feeds move to
Daily/Weekdays/Weekly; weekend slots drop for Mon–Fri shows; the TWiT weeklies (incl.
Windows Weekly) land weekly with tight ~4–5am windows. Then calibrate the constants
(`activeDayThreshold`, tier thresholds, `modeSearchHalfWidthMinutes`,
`recencyHalfLifeWeeks`) against the real data if needed.

## Diagnostics
Per-subscription **Release Radar Data** screen and the all-feeds text export both show
the v2 gate checks (cadence + active-day, no time gate) and the **per-weekday watch
tiers** — each day's publish probability mapped to Full / Light / Skip via
`FeedRefreshScheduling.watchTier(forProbability:)`. Re-export after each change to
measure impact.
