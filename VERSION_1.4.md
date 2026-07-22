# Autohop Version 1.4 — Change Ledger

<!--
AI CONTEXT — VERSION_1.4.md
Canonical running ledger for code, behaviour, diagnostics, and user-visible
changes made after the Version 1.3 release tag. Add every accepted Version 1.4
change here when implemented. Do not describe planned work as complete. Public
release notes should be derived from completed entries and omit internal detail.
-->

## Completed

### Diagnostic logging efficiency and refresh observability — 21 July 2026

- Reworked AppLogger admission so disabled diagnostics do not evaluate expensive
  metadata. Added thread-safe normal/verbose state, bounded routine-event
  backpressure, dropped-entry accounting, queue-consistent export, line/value
  bounds, control-character normalization, URL user-info redaction, precompiled
  security regexes, and a build/mode header on exported logs.
- Added a user-controlled **Detailed Refresh Trace** tier. Normal diagnostics keep
  feed plans, backlog age, material merges, failures, downloads, scheduling,
  `feed.cycleSummary`, and `background.wakeSummary`; verbose mode adds per-feed
  boundaries, 304/no-op decisions, and candidate-list detail for short Release
  Radar investigations.
- Full CPU/thread resource sampling and the 100 ms main-thread watchdog now run
  only while diagnostics are enabled. Healthy resource sampling is five-minute,
  while a log-free five-minute footprint-only safety heartbeat preserves proactive
  artwork-cache trimming when diagnostics are off.
- Reduced healthy-path volume: download progress uses 25% milestones, playback
  tick summaries use a ten-minute interval while slow ticks remain immediate,
  unchanged queue recomputes and routine widget/sync events are verbose, and Auto
  Archive emits one eligibility/outcome pass summary instead of start/finish pairs.


### AppState decomposition Stages 0–14 — 18–19 July 2026

- Established a frozen regression baseline and explicit AppCompositionRoot with
  side-effect-light construction and idempotent runtime startup.
- Moved independent playback-clock, download-progress, warning-cue, Release
  Radar planning, and listening-history persistence leaves into domain files.
- Added HistoryStatsCoordinator as the exclusive iOS owner of listening tick
  accumulation, completion history, Stats credits, derived history summaries,
  remote adapters, and local-save-before-sync lifecycle checkpoints.
- Added QueueCoordinator as the exclusive owner of the downloaded Priority
  Stack projection, Play Next/Last pins, Up Next, badge count, and changed-only
  queue snapshots. Queue reads are now side-effect free, and queue work listens
  to a narrow queue-affecting store event rather than every subscription edit.
- Added OnboardingCoordinator for first-run, first-subscription, coach-mark, and
  toast policy. Single subscriptions retain the “You’re all set” moment while
  bulk imports remain silent.
- Added typed AppRoutingCoordinator commands for launch, menu, notification,
  recap, return-to-player, and onboarding presentation. RootView keeps its local
  NavigationPath and permanent PlayerView root; legacy notification producers
  continue through a compatibility adapter.
- Added DownloadCoordinator ownership for network download policy, bounded
  concurrency state, progress/activity projections, watchdog/backoff state,
  orphan-facing state, and downloaded-media activity projection.
- Added FeedRefreshCoordinator ownership for refresh-cycle attribution and
  cancellation, feed backoff, deferred-feed fairness, background-audio cadence,
  and the Release Radar cache. Added AutoDownloadWorkflow as the durable,
  serialized automatic-download intent boundary.
- Added AutoArchiveCoordinator as the exclusive owner of the 25-minute gate,
  After Playing, Inactive Episodes, Episode Limit, active/backlog protection,
  eligibility diagnostics, and Auto Archive Activity audit records.
- Added SubscriptionImportCoordinator as the owner of OPML import/export,
  security-scoped file access, duplicate filtering, partial-failure handling,
  bulk subscription, and import progress.
- Added SyncCoordinator as the owner of CloudKit lifecycle, callbacks, remote
  subscription materialization, history/Stats routing, active-player identity
  protection, lifecycle flushes, and explicit pulls.
- Added RelayCoordinator as the exclusive owner of entitlement-gated APNs
  registration, feed-membership reconciliation, circuit breakers, sync nudges,
  heartbeat, and silent-push routing. Existing release gates and schemas remain
  unchanged.
- Added PlaybackCoordinator as the owner of the playback engine-facing session,
  loaded episode, playing state, high-frequency clock, sleep services, Play
  Instant state, and episode generation. Delayed chapter and completion work now
  rejects stale episode generations.
- Added AppLifecycleCoordinator as the idempotent startup-state and retained-task
  owner. Foreground/background-audio polling and launch maintenance work are now
  cancellable through a deterministic stop seam.
- Injected domain coordinators as narrow SwiftUI environment observables,
  establishing the Stage 13 migration boundary without prematurely removing
  compatibility invalidation required by pages that still observe AppState.
- Migrated the first Stage 13 page families—Settings subsections, diagnostics,
  onboarding/import, Listening History, Stats, Auto Archive Activity, and
  Downloads—to directly observe their mutable domain owner. AppState remains
  only for cross-domain commands on those surfaces.
- Completed the second Stage 13 page-family pass: Discover/search/top lists,
  Subscriptions, Podcast Detail and Settings, Up Next, Player/Mini Player,
  RootView onboarding chrome, and Notification Settings now observe their
  specific coordinators/stores. CarPlay refreshes now subscribe to the playback,
  queue, subscription, download, and settings owners instead of broad AppState
  invalidation. AppState remains the deliberate high-level command façade.
- Completed the compatibility-forwarding audit. Removed AppState-wide
  invalidation relays for subscriptions, queue, history/Stats, onboarding,
  downloads, Auto Archive, imports, playback, Sleep Timer, and Sleep Schedule.
  Player observes the two sleep services directly. Retained only the proven
  settings bridge until Stage 14 introduces a protocol-friendly observable
  settings owner, preventing stale settings forms during the transition.
- Commenced Stage 14 by promoting SettingsViewModel into the observable,
  write-through global-settings owner. SettingsStoring now exposes a typed
  publisher for production and test substitution; Settings, Player, onboarding,
  notification, launch-routing, Sleep Schedule, and CarPlay surfaces observe
  that owner directly. Removed the final AppState object-change forwarding
  bridge while preserving diagnostic, sleep-schedule, and sync reactions as
  non-UI operational subscribers.
- Continued Stage 14 by removing AppState's final retained-task aliases and
  moving manual-skip, automatic-skip, and Trim Silence statistics callback
  ownership into PlaybackCoordinator. Statistics credits still enter
  MainActor and retain their existing episode/subscription attribution.
- Moved audio interruption, interruption recovery, and restored-output-route
  callback ownership into PlaybackCoordinator. Playback state, effective speed,
  and Now Playing timing remain synchronized when calls or audio-route changes
  interrupt and restore a session.
- Moved download-progress callback ownership into DownloadCoordinator while
  retaining the existing one-percent UI publication coalescing that limits
  scrolling and rendering churn during concurrent downloads.
- Moved download-watchdog callback and delayed retry ownership into
  DownloadCoordinator. Retry delays are now tracked per episode, superseded
  delays are cancelled, and exhausted watchdog work cannot later re-enter the
  download workflow.
- Moved background URLSession completion ownership into DownloadCoordinator.
  Relaunch-delivered downloads now settle media duration, byte statistics,
  activity state, progress, and downloaded projections through the same
  download owner while preserving notification and Play Instant policy.
- Moved Sleep Timer and Sleep Schedule callback ownership into
  PlaybackCoordinator, including lock-screen Still Listening handling and an
  explicitly owned, cancellable no-response fade-and-rewind task.
- Moved the complete 2 Hz playback-time pipeline into PlaybackCoordinator:
  scrubber time, sleep ticking, Now Playing updates, history and Stats credit,
  periodic position persistence, and slow-tick diagnostics now share one owner.
- Moved natural-episode-completion callback ownership and generation capture
  into PlaybackCoordinator, retaining stale-completion rejection before the
  cross-domain completion workflow is allowed to mutate current state.
- Extracted the ordered episode-completion transaction into
  EpisodeCompletionWorkflow, preserving Sleep Timer/Schedule, history, file
  cleanup, played-state, Play Instant, and queue-advancement behavior while
  reducing AppState to a compatibility command.
- Extracted Play Instant eligibility, warning transitions, candidate sequencing,
  interrupted-session restoration, and cancellation into PlayInstantWorkflow;
  PlaybackCoordinator remains the sole owner of its session state and delayed
  transition task.
- Moved lock-screen, headset, AirPods, and CarPlay remote-command callback
  installation into PlaybackCoordinator while preserving the existing
  high-level transport, next-track, and playback-rate commands.
- Extracted scrubber and skip navigation into PlaybackSeekWorkflow, preserving
  manual-skip statistics, Sleep Schedule confirmation, seek-to-end completion,
  and synchronized engine, scrubber, and Now Playing positions.
- Extracted playback startup into PlaybackStartWorkflow, preserving local-file
  repair, download-before-play, resume/start-skip policy, history/sync freshness,
  sleep-service startup, external chapters, and Now Playing publication.
- Extracted play/pause/resume and queue advancement into
  PlaybackTransportWorkflow, preserving pause checkpoints, restored-session
  preference, deliberate Play Instant cancellation, and empty-queue behavior.
- Extracted phone and CarPlay playback-launch policy into
  PlaybackLaunchWorkflow, with one shared launch-handled flag owned by
  PlaybackCoordinator to prevent competing scene startup paths.
- Moved the remaining queue/player, queue-badge, remote-file-deletion,
  first-subscription-routing, CloudKit-to-Relay, and new-subscription-default
  callback bodies into their owning coordinators. AppState now connects those
  typed owners without implementing their event handlers.
- Extracted playback-preference policy into PlaybackPreferenceWorkflow,
  preserving per-podcast settings, global browse/new-subscription defaults,
  Shared Listening, live engine updates, and Now Playing rate synchronization.
- Extracted manual Played/Archive/Unarchive transactions into
  EpisodeDispositionWorkflow, preserving history reasons, resume cleanup,
  downloaded-file deletion, queue pin cleanup, Play Instant handling, and
  archive-and-advance behavior.
- Extracted the bounded media-transfer loop into DownloadTransferWorkflow,
  preserving network rules, duplicate prevention, three concurrent download
  slots, FIFO draining, existing-file reuse, progress/activity settlement,
  failure backoff, notifications, and Play Instant delivery.
- Extracted user/platform download actions into DownloadActionsWorkflow,
  preserving CarPlay download-and-wait behavior, pause/resume restart fallback,
  cancellation, archive, deletion, watchdog retry, and startup orphan repair.
- Extracted durable automatic-download intent scheduling and draining into
  AutoDownloadIntentWorkflow. Intents remain persisted before asynchronous work
  and are removed only after a current, explainable terminal outcome.
- Moved rolling one-item feed replacement cleanup into the download action
  owner, so obsolete bulletin transfers are retired consistently without being
  misclassified as user-visible failures.
- Extracted Release Radar learning and scheduling into ReleaseRadarWorkflow,
  retaining filter-aware predictions, cached/off-main planning, diagnostic
  rebuilds, and backoff-aware background wake dates.
- Extracted each conditional feed fetch/merge into FeedRefreshItemWorkflow,
  preserving 304 validators, release learning, browse isolation, rolling-feed
  cleanup, automatic-download scheduling, memory scoping, and failure backoff.
- Extracted the complete multi-feed refresh controller into
  FeedRefreshCycleWorkflow, preserving foreground/background budgets, active
  cycle joining, Relay follow-ups, expiration safety, deferred-feed fairness,
  memory batch checkpoints, queue refresh, and Auto Archive follow-up.
- Extracted chapter presentation and mutation into PlaybackChapterWorkflow,
  preserving current/filtered chapters, previous/next navigation, live
  subscription-filter changes, and generation-safe external chapter loading
  without retaining duplicate network/parser code in AppState.
- Extracted local-media and resume ownership into PlaybackMediaWorkflow. File
  identity repair, duration reads, position persistence, and cold-launch restore
  validation now share one typed transaction used by playback, downloads, and
  Play Instant.
- Extracted new-episode notification policy into one shared workflow so ordinary
  and background download completions apply identical global/per-podcast gates
  without duplicating policy in AppState.
- Extracted scene/runtime policy into AppRuntimeWorkflow: background-audio feed
  polling, independent Auto Archive polling, settings reactions, Sleep Schedule
  configuration, idle-timer handling, resource context, and background playback
  diagnostics now share one owner. Delayed probes and maintenance tasks are
  retained, cancelled, and released through AppLifecycleCoordinator.
- Moved full Now Playing metadata reassertion into the playback preference owner,
  preserving scene/route recovery while removing the last Now Playing metadata
  implementation from AppState.
- Continued Stage 14 façade cleanup by deleting unused AppState projections for
  onboarding toast, history/import summaries, download activity/completion
  counts, first-run/subscription counts, queue-next helpers, and video-player
  state. Onboarding and Player surfaces now query their domain coordinators
  directly; AppState keeps only compatibility APIs still used by platform
  entry points, tests, or cross-domain commands.
- Removed the obsolete, compile-disabled duplicate Relay implementation from
  AppState. APNs registration, heartbeat, and silent-push entry points remain as
  thin platform façades over RelayCoordinator; all Relay tasks, retry state,
  membership reconciliation, and push classification now have one source owner.
- Migrated chapter and video presentation state from AppState to
  PlaybackCoordinator, including filtered/current chapters, chapter-page
  availability, previous/next targets, and video-player access. Player and
  Podcast Settings now observe the playback owner directly; navigation commands
  remain thin cross-domain seek intents.
- Removed AppState's final Task aliases. Play Instant and feed-refresh cycle
  tasks are now referenced directly through their owning coordinators, making
  cancellation and retained-work ownership explicit without changing behavior.
- Added PlaybackCheckpointWorkflow as the shared, ordered durability boundary
  for playback position, Listening History, Stats, and deferred CloudKit pushes.
- Replaced the remaining AppState-authored cross-workflow callback adapters with
  typed, weakly connected collaborators. Feed refresh, playback, downloads,
  Play Instant, completion, disposition, chapters, notifications, Auto Archive,
  runtime, and sync now communicate through named owners without depending on
  AppState or a service locator.
- Added injectable runtime environment, clock, and lifecycle-sleep seams for
  application state, background time, idle-timer policy, Radar/Auto Archive
  timing, and delayed maintenance. These policies can now be characterized
  deterministically without reading global UIKit state.
- Added AppStartupWorkflow as the exclusive owner of graph connection, callback
  installation, migrations, restoration, service start order, Release Radar
  warm-up, startup maintenance, and bootstrap timing. AppState now only guards
  singleton startup and delegates to this workflow.
- Completed the final compatibility/dead-code audit. Removed unused
  orphan-download and bulk-subscribe façade commands, rewrote the authoritative
  AppState AI CONTEXT header, and verified that AppState contains no retained
  Task, Combine relay, domain callback assignment, persistence transaction, or
  state-machine implementation.
- Regenerated and validated the complete local matrix: iOS build-for-testing and
  simulator tests, normal iOS app installation/startup, tvOS Simulator
  compilation, plus the RSS, OPML, Subscription Store, Download Manager, and
  Stats smoke suites. Updated stale Release Radar
  smoke fixtures to reflect the existing five-active-day burst gate,
  three-observed-week regular-cadence gate, and broad quiet-period safety checks;
  production scheduling behavior was unchanged.
- Removed AppState's obsolete 225-line pre-decomposition ownership narrative.
  Its concise authoritative Stage 14 AI header is now the only file-level
  responsibility map, while feature invariants remain beside their extracted
  owners. AppState is approximately 1,116 lines versus the 6,645-line review
  baseline; focused extraction and completion-workflow tests pass.
- Preserved existing JSON formats, CloudKit schemas, queue ordering, CarPlay
  entry points, playback behavior, and user-facing navigation.

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

### Background download and playback reliability — 21 July 2026

- Anchored download first-byte watchdog decisions to an absolute per-attempt
  deadline. Process suspension no longer extends a zero-byte wait; scene changes,
  network-path changes, BGTask entry, URLSession activity, and the periodic timer
  can all request immediate re-evaluation. Suspension grace remains limited to
  active transfers whose delegate progress may legitimately be withheld.
- Added generation ownership to delayed watchdog retries and retired the durable
  automatic-download intent when all bounded retries are exhausted. This creates
  one authoritative retry path and prevents a later intent drain from silently
  restarting an episode already presented as terminally failed.
- Added an optional second BGAppRefresh feed batch. After the normal eight-feed
  batch, Autohop may process two to four deferred feeds only when cooperative and
  system deadlines permit and Low Power Mode, thermal pressure, constrained or
  expensive networking, and large active downloads are absent. BGProcessing's
  persisted 12/18/24-hour outcome policy is unchanged.
- Added named slow-main-actor diagnostics around feed merges, queue projection,
  widget projection, download completion settlement, and audio-route handling.
  These records correlate future hang reports with the synchronous operation that
  occupied the UI thread.
- Coalesced duplicate same-output audio route notifications within 400 ms and
  enriched buffer-stall/recovery diagnostics with buffer generation, route
  generation, engine/node state, and route-coordination state. Existing
  generation guards continue to prevent stale buffer loops from launching a
  competing recovery.

### Overnight refresh and main-thread efficiency — 22 July 2026

- Added a genuine unchanged-feed fast path. Episode and subscription metadata
  setters now compare incoming values before persisting or publishing, preventing
  an unchanged one-episode feed from triggering broad store reconciliation.
- Added per-stage feed-merge timing so future diagnostics distinguish episode,
  artwork, author, description, category, and explicit-rating work instead of
  reporting only one opaque main-actor duration.
- Coalesced store publications across each background refresh cycle while keeping
  the final queue projection explicit. Nested transactions remain safe when an
  individual feed or download settlement also coalesces its own mutations.
- Reduced download completion settlement cost by resolving file metadata away
  from the main actor and applying downloaded-state and duration mutations as one
  store transaction. Slow settlements now identify lookup, store/media, Stats,
  and follow-up-effect stages.
- Persisted BGProcessing registration, scheduling, and launch-state diagnostics.
  Launch records now expose pending-request and next-eligibility dates, outcome
  pacing, failure count, power/network requirements, battery state, and system
  background-refresh availability. The existing 12/18/24-hour policy is unchanged.
- Reused existing widget thumbnails when episode identity and artwork source are
  unchanged. Publication diagnostics now separate projection, thumbnail lookup,
  artwork rendering, atomic persistence, and timeline reload timing, allowing the
  previously observed multi-second outliers to be located precisely.
- Expanded same-output route-change coalescing to absorb near-simultaneous route,
  configuration, and category notifications during the stabilization window while
  retaining route-generation ownership for genuine output changes.
- Deliberately retained the current BGAppRefresh batch policy. Additional backlog
  batches remain deferred until the new BGProcessing state records prove whether
  the overnight mechanism is unavailable, pending too far ahead, or simply not
  granted by iOS.

### Now Playing & Up Next widgets — 20 July 2026

- Added small, medium, and large Home Screen widgets for the current episode and
  downloaded Up Next queue, plus circular and rectangular Lock Screen/StandBy
  accessories.
- Added interactive play/pause and Play Now controls backed by
  AudioPlaybackIntent. Requests execute without foregrounding and revalidate the
  stable episode identity, downloaded state, and archive/play status against the
  live store before using the existing playback transaction.
- Added validated `autohop://` routes for Player, Up Next, Episode Detail, and
  Discover. Malformed or stale links fail safely and are logged.
- Added an atomic, versioned App Group display snapshot, bounded local JPEG
  artwork, visible-state hash deduplication, targeted timeline reloads, corrupt
  snapshot recovery, a 24-hour stale state, and current/previous-generation
  artwork cleanup. The extension performs no networking or database access.
- Added privacy-sensitive rectangular Lock Screen metadata, a non-sensitive
  circular queue count, and accentable rendering for tinted Lock Screen and
  StandBy modes.
- Increased Home Screen widget metadata contrast with an explicit light-grey
  token and reduced the large widget's Up Next heading to caption size, leaving
  more vertical room and emphasis for episode rows.
- Standardised video-podcast artwork presentation across widgets, CarPlay, and
  system Now Playing. Widescreen episode posters are now centre-cropped into
  square artwork slots without distortion; full-screen video remains widescreen.
- Added widget publication/skip/failure, intent outcome, and route
  accept/reject diagnostics plus isolated storage and route-parser coverage.
- Discovery/Stats widget concepts remain deliberately deferred and are not part
  of this implementation.

## Verification status

- iPhone simulator Debug build: passed 14 July 2026.
- Full automated test bundle: compiled successfully; simulator execution was
  blocked when the unsigned test host exited during CloudKit entitlement setup.
- Extended on-device 80-feed manual-refresh memory test: pending.
