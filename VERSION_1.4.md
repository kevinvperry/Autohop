# Autohop Version 1.4 — Change Ledger

<!--
AI CONTEXT — VERSION_1.4.md
Canonical running ledger for code, behaviour, diagnostics, and user-visible
changes made after the Version 1.3 release tag. Add every accepted Version 1.4
change here when implemented. Do not describe planned work as complete. Public
release notes should be derived from completed entries and omit internal detail.
-->

## Completed

### Reliable Priority Stack reordering — 18 July 2026

- Rebuilt Subscriptions Reorder around a stable local UUID draft. Users can move
  several active podcasts in one session without each gesture racing a delayed
  shared-store update.
- Limited drag targets to active real subscriptions. Inactive subscriptions
  remain visible and fixed at the bottom, while hidden browse previews never
  enter the reorder index space.
- Done, navigation away, and scene deactivation now validate and commit the
  final order once. Malformed or stale drafts are rejected instead of applying a
  best-effort move to the wrong show.
- Added bounded persistence retries, lifecycle flushes, durable-save failure
  reporting, and reorder diagnostics. A transient database failure no longer
  silently loses the new order.
- Added one atomic private-iCloud `SubscriptionOrder` record containing the full
  real-subscription UUID order. Remote order is deferred during a local drag;
  intentional local movement wins, while an unchanged session accepts the
  deferred remote generation.
- CloudKit success handling is now version-aware for subscription, episode,
  history, stats, queue, and order records. A delayed response for an older
  upload cannot mark a newer local edit clean.
- Added regression coverage for repeated moves, Inactive/browse boundaries,
  invalid drafts, remote/local reorder races, persistence retry and reload,
  CloudKit mapping, atomic generation acknowledgement, and stale field
  acknowledgement.

### Discover category Top 50 pages — 17 July 2026

- Added a dedicated Top-50 chart page for every current Discover category:
  Comedy, News, True Crime, Society & Culture, Business, Sports, Health &
  Fitness, Technology, Science, and TV & Film.
- Category chips now push their corresponding chart instead of scrolling within
  Discover. Existing Top-15 horizontal rails remain as fast browsing previews.
- Category pages reuse the established Top Podcasts editorial design, selected
  country, pull-to-refresh, mini-player, RSS resolution, and subscribed/preview
  routing. Their 50-entry results load only when opened and use the existing
  country-and-category chart cache.
- Polished navigation with `Top 50 - <Category>` titles, roomier Discover
  section spacing, and icon-and-chevron category rail headings that also open
  the expanded chart.
- Extended the shared storefront picker to Top Episodes, Top Podcasts, and every
  category page. A country change reloads the visible chart and persists when
  returning to Discover.
- Improved first-content speed: Discover now renders immediately and inserts
  heroes, individual category rails, and country spotlights as each independent
  request completes instead of waiting for the slowest section.
- Category pages now open from their already-loaded Top-15 rail and unobtrusively
  load the remaining chart in the background. Country/category guards prevent
  stale preview rows appearing after a storefront change.
- Reduced duplicate Apple chart requests by allowing fresh Top-50 podcast cache
  entries to satisfy smaller Top-8 and Top-15 chart requests while preserving
  Apple's rank ordering and existing cache lifetime.

### Sleep Schedule active-hours boundary — 17 July 2026

- Fixed Sleep Schedule continuing to issue **Still Listening** prompts after its
  configured Active Hours had ended.
- Active Hours are now enforced throughout the live lifecycle, not only when
  playback initially starts: crossing the end boundary cancels a countdown,
  End-of-Episode arming, an active chime, the player overlay, and the lock-screen
  notification without interrupting ordinary podcast playback.
- A late notification response cannot re-arm another cycle outside the window,
  and changing the configured hours to exclude the current time ends existing
  schedule activity immediately.

### Listening History episode-list redesign — 15 July 2026

- Aligned Listening History rows with Autohop's shared episode-list design: 44-point
  artwork, matching title and podcast metadata typography, shared episode status
  pills, and the standard animated download-progress treatment.
- History pills now communicate the recorded outcome: **Played** for a completed or
  marked-played episode, **Archived** for a manual or automatic archive, and
  **Paused** for incomplete listening. The actively playing history episode uses
  **Playing** without changing its stored historical outcome.
- Added exact local event date and time metadata labelled **Completed**,
  **Manually Archived**, or **Auto Archived**. Older records without a classified
  event retain a safe **Last listened** or **Archived** fallback rather than
  inventing historical detail.
- Retained the existing section grouping, search, matching swipe actions, and
  download-before-action behaviour.
- Fixed After Playing Auto Archive incorrectly replacing an episode's completed
  history event with Auto Archived. Completed and marked-played outcomes now take
  precedence over later automatic storage cleanup. A conservative migration repairs
  affected natural completions whose saved position proves they reached the end.

### Mono Audio — 14 July 2026

- Added Stereo/Mono selection to the shared Playback controls in both Podcast
  Settings and System Settings → Default Playback.
- Stereo remains the factory and legacy-data default. The System Settings value
  seeds new subscriptions and unsubscribed-feed playback; it does not rewrite
  existing podcast preferences.
- For audio episodes, Mono uses the AVAudioEngine path to average decoded left
  and right samples, then sends the centred signal to both outputs. This corrects
  presenter mixes that strongly favour one ear without discarding either channel.
- Per-podcast changes persist and sync with the existing PlaybackPreference and
  apply during active playback from the current position. Video remains on its
  required AVPlayer path and does not receive the fold-down.

### Play Instant — 14 July 2026

- Added an opt-in **Play Instant** switch to each podcast's Automation settings,
  intended for sparing use with the listener's absolute-favourite content.
- A new, Download-Filter-eligible episode triggers only after a confirmed automatic
  download and only while another episode is actively playing. Autohop sounds a
  gentle two-note warning, waits two seconds, saves the interrupted position, and
  starts the new arrival ahead of the normal Up Next order.
- Natural completion or Mark Played advances through any additional qualifying
  arrivals in FIFO order, then returns to the exact interrupted position. A manual
  pause, archive, episode selection, or Next command cancels the saved return.
- Manual downloads, backlog files, filter-skipped episodes, and downloads completed
  while playback is paused or idle are deliberately excluded. Background URLSession
  completions retain automatic provenance through the durable download-intent store.
- The setting defaults off, decodes safely from older subscription files, and uses
  the existing per-podcast persistence and private-iCloud sync payload.

### Auto Archive — 14 July 2026

- Added a per-podcast **40 Minutes** option to the Inactive Episodes selector.
  It is intended for hourly news bulletins, allowing an aging downloaded bulletin
  to be archived around the time a replacement becomes available. The option uses
  the existing download/last-played inactivity clock; it is not offered as the
  global default for every new podcast.

### Release Radar and Auto Archive diagnostics — 15 July 2026

- Replaced the user-facing Radar Sensitivity control with automatic timing derived
  from each feed's learned state: approximately 2–3 minutes in active windows,
  5 minutes before a predicted release, 5–10 minutes shortly after a miss, and
  15–60 minutes for random/unreliable feeds, plus broad safety surveillance.
- During confirmed background audio playback, due-feed polling now runs no more
  often than every four minutes. Routine cycles check seven feeds; pre-window,
  active-window, and missed-release candidates may extend a cycle to a hard maximum
  of ten. Low Power Mode, thermal pressure, constrained/cellular networking, and
  large active downloads reduce these budgets.
- Added oldest-deferred-feed age and backlog identity to refresh diagnostics so
  fairness and starvation can be audited directly.
- Reduced the automatic archive gate from 30 to 25 minutes and added eligibility
  summaries explaining zero-result passes, protected episodes, waiting thresholds,
  and archive counts by rule.
- Added System Settings → Auto Archive Activity, a bounded local audit showing the
  episode, podcast, timestamp, rule, configured threshold, and measured age for
  each automatic archive recorded after this update.
- Exhausted download watchdog retries now terminate and clear the associated task's
  watchdog state before failure is reported, preventing later cancellation
  callbacks from reviving the same failed transfer.

### Playback seeking and completion — 17 July 2026

- Fixed an occasional Player scrubber/timer freeze caused when the system Slider
  cancelled a drag without delivering its normal editing-ended callback. An idle
  seek session now commits after five seconds and returns the UI to the canonical
  playback clock while uninterrupted audio continues.
- A scrub or forward skip that reaches the final quarter-second now enters the
  normal episode-completion pipeline instead of asking AVAudioEngine to seek to
  EOF. This prevents the engine file reader from restarting at frame zero, marks
  the episode Played, clears its resume position, and advances normally.
- Manual skip statistics now credit only the actual remaining duration when the
  configured skip interval crosses the end of an episode.
- Completing an episode that was saved as a Play Instant return point now cancels
  that return session, preventing the skipped final seconds from being restored
  after the following episode ends.

### Per-podcast Volume Adjustment — 17 July 2026

- Added a live −3…+3 dB whole-step Volume Adjustment to Individual Subscription
  Settings → Playback, positioned between Vocal Boost and Mono Audio. The default
  is 0 dB and global Default Playback intentionally remains unchanged.
- Audio amplification uses a dedicated final AVAudioUnitEQ gain stage, separate
  from system output volume and Sleep Timer fading. Enabling a non-zero adjustment
  moves an ordinary audio episode onto the processing path while preserving its
  playback position; later changes apply live.
- The value persists and syncs as part of the subscription's existing
  `PlaybackPreference`. Legacy data decodes to 0 dB and malformed/out-of-range
  values are clamped to −3…+3.

### CarPlay — 14 July 2026

- Replaced CarPlay's system-derived playback-rate button with an AppState-derived
  configured-speed control. The Now Playing button now displays the episode's
  effective speed, such as `1.6x`, instead of showing `0x` while paused or during
  brief audio-engine/Now Playing state transitions. The adjustment page and its
  Slower/Faster behavior are unchanged.
- Enlarged the Now Playing speed label again after real-vehicle testing: it now
  uses a 34-point heavy compressed glyph, a clearer multiplication symbol, and an
  image cropped dynamically to the measured text bounds. Removing fixed transparent
  padding prevents CarPlay from shrinking the useful glyph relative to adjacent
  controls, without changing its action or effective-speed source.

### Performance and reliability — 14 July 2026

- Reclassified download watchdog phases: first-byte waits receive a 30-minute
  deadline; the existing 10-minute threshold applies only after payload transfer
  starts. This prevents slow CDN/server response setup from being retried as a
  stalled active download.
- Increased routine Listening History and Stats sync persistence batches from 10
  to 30 seconds while preserving immediate lifecycle durability.
- Prevented the first playback tick's immediate Stats persistence checkpoint
  from publishing a duplicate UI revision; later playback revisions remain
  coalesced while lifecycle saves still publish genuinely pending data.
- Reduced routine persistence diagnostic output to five-minute summaries, retaining
  immediate reporting for lifecycle flushes, failures, and slow database writes.
- Added generation ownership to AVAudioEngine buffer loops so stale callbacks from
  a seek, stop, or route replacement cannot change time, finish playback, or race a
  route-coordinated restart.
- Added stage timing for cold app bootstrap and slow playback resumes to isolate the
  two main-thread hang paths found in the Version 1.3 overnight diagnostic.
- Retained proactive memory trimming at the physical-footprint threshold. Added
  parse/merge autorelease boundaries, 16-feed refresh memory checkpoints, actor
  yields, and a 25 ms drain pause between batches during large manual refreshes.

## Verification status

- iPhone simulator Debug build: passed 14 July 2026.
- Full automated test bundle: compiled successfully; simulator execution was
  blocked when the unsigned test host exited during CloudKit entitlement setup.
- Extended on-device 80-feed manual-refresh memory test: pending.
