# Stats Page Accounting Audit — 14 August 2026

<!--
AI CONTEXT — Full end-to-end audit of every Stats page section after reports of
incorrect long-range figures. Keep this document aligned with StatsView,
ListeningStatsStore, HistoryStatsCoordinator and tvOS playback accounting.
It distinguishes corrected defects from unavoidable forward-only limitations.
-->

## Audit scope

The audit traced iOS and tvOS event capture, daily bucketing, local persistence,
additive per-device iCloud merging, calendar range selection and every Stats page
presentation: hero totals, streak, Top Shows, expanded show details, drifting
shows, heatmap, monthly trend, listening clock, downloads and time-saved rows.

## Confirmed defects corrected

| Area | Defect | Correction |
|---|---|---|
| All time-based sections | iOS AVPlayer emitted media-time callbacks faster at speeds above 1×, while the app credited a fixed 0.5 seconds per callback. Listening at 1.4× could therefore inflate elapsed listening by about 40%. | Natural media progress is validated once and converted with `mediaDelta / effectiveSpeed`. The same elapsed-time contract now feeds iOS and tvOS. |
| Calendar/Lifetime hero and time saved | Imported pre-daily-bucket totals were retained by `lifetime`, but page summaries omitted them. The first repair included only Lifetime, leaving 2026 six hours below Lifetime even though the entire baseline interval occurred in 2026. | The baseline now records its cutover and is included in any period that wholly contains the known interval, plus Lifetime. Existing files infer cutover from their earliest local daily bucket. |
| Trend reconciliation | Imported totals have no original day/month/hour/show attribution, so a monthly chart cannot fully equal an enclosing year/Lifetime headline. | The chart remains truthful to attributable daily buckets and displays the amount included in the selected total but unavailable to plot. |
| Expanded Top Shows | Long-range completion counts depended on a capped mutable history projection. | Durable per-show daily completion counters plus deduplicated retained episode/history recovery; history capacity increased to 5,000. |
| Expanded time saved | Mixed legacy/current ranges dropped legacy contributions if any newer per-show map existed. | Savings are reconciled per day; missing legacy attribution is apportioned for that day and labelled estimated. |
| tvOS accounting | Media-position deltas were written as elapsed seconds at speeds above 1×. | tvOS converts media progress to elapsed time before writing shared Stats buckets. |
| Variable-speed savings | The elapsed-time input was divided by speed a second time. | Savings use `elapsed × (speed − 1)`. |

## Section-by-section result

| Section | Source and audit result |
|---|---|
| Time listened | Additive daily elapsed seconds. Period filters are calendar anchored and half-open for concluded periods. Fixed speed inflation and Lifetime baseline omission. |
| Time saved | Four independently accumulated categories; total is their sum. Skip amounts are bounded to the actual forward distance. Corrected rate formula and Lifetime import. |
| Episodes finished | Completion events stored globally and per show. Cross-device day partitions merge additively. Historical per-show attribution remains recoverable only where episode/history evidence survives. |
| Current streak | Consecutive combined local/remote days with at least 60 seconds, allowing an unfinished current day without breaking yesterday's streak. Correct once elapsed-time input is corrected. |
| Top Shows | Ranked from the same period's per-show elapsed seconds; title snapshots survive unsubscribe and sync. Correct once elapsed-time input is corrected. |
| Expanded show details | Durable completion count, day-reconciled saved time, period share, retained-history completion/abandonment/cadence evidence, and latest retained episode timestamp. Historical evidence limits are disclosed below. |
| Drifting From | Uses classified resolved history only, excludes deliberately filter-skipped episodes and inactive/preview subscriptions, and is restricted to current short ranges. No arithmetic defect found. |
| Heatmap / busiest day | Zero-filled calendar days from the selected period and the shared elapsed-time buckets. Monday alignment verified. |
| Monthly trend | Groups selected daily buckets by calendar month. Lifetime legacy data remains unbucketed and is explicitly disclosed rather than assigned to a fabricated month. |
| Listening clock | Sums 24 normalized hour buckets and identifies the maximum. Older/corrupt arrays are padded or truncated safely. Correct once elapsed-time input is corrected. |
| Data downloaded | Actual successful on-disk byte count plus completion-event count, including genuine re-download traffic. Failed/cancelled downloads do not count. Both foreground and background settlement paths were verified as alternatives, not duplicate calls. |
| This / Last and rank movement | Current periods and concluded prior periods use calendar boundaries; Last details have an exclusive current-period upper bound. Rank comparison windows were verified. |
| iCloud merge | Device-owned full-day partitions sum additively; remote data is not copied into the local bucket, avoiding repeated merge inflation. Per-show counters and titles follow the same contract. |

## Unavoidable historical limits

- Corrected playback-rate accounting is prospective. Existing aggregate buckets
  do not retain enough sample-level information to identify and reverse old
  speed-related inflation safely.
- Imported legacy playback totals contain no month, hour, show, episode or streak
  attribution. The whole block is included only when its known interval is fully
  inside the selected range; it is never split using an unsupported guess.
- Old per-show completion, abandonment and cadence evidence cannot be recreated
  after both the former history cap and the live subscription episode set have
  discarded it. New completion counters are durable.
- Download-byte tracking began in June 2026 and cannot be backfilled reliably.
