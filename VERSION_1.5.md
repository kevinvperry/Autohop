# Autohop Version 1.5 — Change Ledger

<!--
AI CONTEXT — VERSION_1.5.md
Canonical running ledger for code, behaviour, diagnostics, and user-visible
changes implemented after Version 1.4 was submitted to Apple on 25 July 2026.
Add every accepted Version 1.5 change here when implemented. Do not describe
planned work as complete. Public release notes must be derived from completed
entries and omit internal implementation detail. Updating this ledger is part
of the implementation definition of done, including for small user-facing fixes
and diagnostic or performance-policy changes.
-->

## Completed

### Apple TV Discover navigation and playback repair — 7 August 2026

- Replaced placeholder category, show and episode destinations with focusable
  navigation backed by publisher RSS feeds.
- Added expanded category grids, show episode lists, full episode details,
  Play controls, searchable show routing, safe loading failures and route
  diagnostics.
- Added an explicit Discover playback origin: playback contributes to History
  and Stats but cannot subscribe, alter Up Next, write companion episode state
  or auto-advance into the phone-authored queue.
- Added route-depth, feed-resolution and play-request diagnostics so device
  exports distinguish catalogue, RSS, navigation and playback failures.

### Apple TV Discover foundations — 7 August 2026

- Replaced the standalone Apple TV Search tab with a first-class **Discover**
  destination containing storefront-aware Top Episodes, New & Notable, Top
  Podcasts, category browsing and catalogue search entry points.
- Added a narrow shared charts interface while keeping Apple response parsing,
  caching and the iPhone Discover view model private to their existing module.
- Added a dedicated tvOS Discover model and actor-backed repository with
  cancellation, request generations, local storefront persistence, bounded
  eager category loading and redacted performance diagnostics.
- Established immutable catalogue presentation models and a mechanically
  testable browse-only policy with no subscription, priority, archive or Up
  Next authority.
- Removed stale tvOS Search subscription state and inaccurate “add podcast”
  language. Full publisher-feed show/episode detail and playback integration
  remain later phases and are not represented as complete.

### Full episode descriptions on Apple TV — 7 August 2026

- Added one native, scrollable tvOS description sheet with the complete
  feed-supplied episode notes, podcast context, readable typography and a
  standard Done action.
- Added a visible Description control to the audio player and the native video
  player's Episode menu.
- Added Episode Description to the standard long-press context menu for Home,
  Up Next, Library and History episode rows/cards while preserving existing
  Pin, Unpin and Archive actions.
- Sanitized feed HTML into stable paragraph/list text without adding WebKit or
  another network/sync path; unresolved legacy rows remain safely unavailable
  until their existing detail recovery completes.

### More audible Play Instant warning and calmer sleep fades — 7 August 2026

- Increased the Play Instant transition cue's waveform level and player gain so
  the warning remains clearly audible over an episode already playing, without
  altering the user's normal playback volume.
- Replaced the manual Sleep Timer's abrupt five-second linear fade and Sleep
  Schedule's roughly 2.5-second stepped fade with one shared, smooth 30-second
  envelope.
- Preserved cancellation, extension, pause, rewind and volume-reset semantics;
  added diagnostics for cue/fade policy and regression coverage for the common
  monotonic fade curve.

### 2 August 2026 — Apple TV application model decomposed into focused subsystems

- Replaced the former 1,200-plus-line `TVAppModel` implementation file with a
  249-line composition facade and separate bootstrap, private-iCloud sync,
  recovery, Library, Up Next, Continue Listening, playback-routing, and
  diagnostics files.
- Added focused observable `TVLibraryModel`, `TVQueueModel`, and
  `TVContinueListeningModel` state owners so unrelated page changes no longer
  need to invalidate one monolithic root state surface.
- Added a production/test dependency container, dedicated sync/bootstrap/task
  coordinators, pure projection helpers, and a bounded episode-detail
  repository.
- Preserved `TVPlaybackModel` and `StreamingPlaybackEngine` as the sole player
  state machine while moving request resolution, checkpoints, and archive
  write-back behind `TVPlaybackCoordinator`.
- Migrated tvOS views to focused page state and added a read-only diagnostics
  snapshot boundary.
- Added architecture regression tests for bootstrap state, Library ordering,
  phone-authored queue ordering/placeholders, and state isolation.
- This is a tvOS-only architecture change. It does not alter iPhone playback,
  downloads, Release Radar, queue composition, or private-iCloud authority.

### 1 August 2026 — Apple TV Home stability and episode archiving

- Moved **Updating from iPhone** out of the Home content stack and into a
  non-interactive top-right status badge. Sync-status changes no longer insert
  or remove a row, so Home shelves and Siri Remote focus positions remain
  stable while iCloud updates. A subsequent device review moved the badge
  closer to the upper-right safe-area edge, separate from the content grid.
- Restyled **Continue Listening/Watching** to use the same compact 150-point
  artwork, typography, spacing, material and focus treatment as the active
  **Now Playing/Watching** card.
- Added Archive to every playable Apple TV episode surface through the native
  long-press context menu: Home shelves, Continue Listening, Up Next and
  podcast episode lists. The active Home hero also provides a visible Archive
  button.
- Added a directly focusable **Archive** button to every Up Next row after
  device testing found that the destructive long-press menu could appear
  without allowing its action to acquire Siri Remote focus.
- Added Archive to both player designs: the audio player control row and the
  native full-screen video transport menu.
- Archiving the active episode now stops and clears playback, removes the local
  row from Up Next, records durable companion EpisodeSyncState even for legacy
  projection-only episodes, and requests an immediate iCloud send to iPhone.
- Locally archived episodes are suppressed immediately from an older
  phone-authored queue snapshot. Diagnostics confirmed that Archive had run
  and synced three times, but the unchanged projection reconstructed the row
  and misleadingly made the command appear unsuccessful.
- Added regression coverage for catalogue-free archived-state authoring and
  verified the Apple TV build.

### 1 August 2026 — Apple TV responsiveness and authoritative playback sync

- Separated Up Next projection invalidation from listening-history
  invalidation. A playback checkpoint can now update Continue Listening
  without rebuilding or logging the unchanged queue; only a changed library or
  queue generation reconstructs Up Next.
- Replaced overlapping full-history launch/foreground sweeps with one shared,
  bounded recent-history prime. The Home surface requests at most the latest
  100 CloudKit history records while the normal change stream remains the
  durable full-history recovery path.
- Added an immediate tvOS checkpoint send path. Pause, player exit, app
  background and periodic playback checkpoints now queue the persisted history
  row, request a CKSyncEngine send, and log send requested/completed/failed plus
  the existing per-record acknowledgement.
- Preserved the authoritative phone-authored history record when a legacy or
  reinstalled tvOS episode has a different local UUID. Bounded enclosure/GUID
  recovery prevents playback from creating a second generated history entry.
- Allowed Apple TV to author playing/played EpisodeSyncState directly from
  durable subscription ID + GUID when no local catalogue Episode row exists.
  A self-contained Queue/History video can therefore update the iPhone instead
  of reporting `catalogMatch=false` and silently skipping state sync.
- Stopped resume seeks, scrubbing and other large AVPlayer position jumps from
  increasing synced listening totals. Only short natural playback ticks count
  as consumed time; every jump still updates the saved resume position.
- Retained the existing bounded/downsampled tvOS artwork cache. Log review and
  source audit confirmed it already loads off-main, deduplicates in-flight
  requests, limits decoded memory and prunes its disk cache.
- Added regression coverage for natural playback accounting, authoritative
  history identity recovery and catalogue-free companion episode state.
- Regenerated the Xcode project and verified the tvOS application build.

Physical Apple TV validation remains required to confirm reduced focus latency,
one queue projection per real generation, bounded recent-history priming,
CloudKit acknowledgement on the phone, and repeated video resume at the saved
position and selected speed.

### 31 July 2026 — Apple TV playback diagnostics, speed and history sync

- Removed the duplicate **Continue Watching** card while its episode is already
  represented by the active **Now Watching** section. Stable enclosure identity
  handles reconstructed episode UUIDs after feed migration or reinstall.
- Stopped computing and publishing the Continue Watching history projection
  while playback is active. Home now maintains one mutually exclusive hero,
  avoiding repeated history-table decoding and view invalidation during
  progress checkpoints.
- Stopped rewriting MediaRemote Now Playing metadata on every half-second
  playback tick. Apple TV now publishes it only at meaningful transport,
  position and speed changes, preventing the timeout churn observed in Xcode.
- Deferred the native AVKit speed menu until its player surface has appeared,
  eliminating zero-width focus/menu constraint conflicts during presentation.
- Hardened video pause/resume speed retention by keeping AVPlayer `defaultRate`
  and active `rate` aligned, using an explicit preferred-rate resume, and
  reasserting the selected subscription speed when playback resumes.
- Fixed uninterrupted Apple TV playback progress remaining local indefinitely.
  Direct history-database writes now request a bounded CloudKit slow-lane upload
  once per minute; pause, player exit and app backgrounding still upload
  immediately.
- Added durable GUID/enclosure identity reconciliation before tvOS authors
  playing or completed episode state. The synced mutation now targets the
  phone's current catalogue identity after a remove/re-add or legacy migration,
  rather than an Apple-TV-local UUID the phone cannot merge.
- Expanded persistent tvOS diagnostics with video-surface attach/detach,
  playback request generation, expected/default/actual rates, pause/resume,
  local progress writes, periodic upload requests and iCloud acknowledgements.
- Settings & Diagnostics now shows live playback state, position, selected
  speed, actual AVPlayer rate and pending history uploads. It can prepare the
  complete stitched redacted log inside the Apple TV app container for device
  retrieval; no diagnostic information is uploaded automatically.
- Promoted **Prepare Full Diagnostic Export** to the first control on Settings
  & Diagnostics, enabled structured log mirroring in physical DEBUG builds,
  and corrected rate formatting that previously generated runtime warnings.
- Fixed first-launch video presentation ordering. Continue Watching now waits
  for media classification, AVPlayer readiness and the resume seek before
  presenting AVKit, rather than attaching a full-screen cover to the interim
  audio-only state and requiring a second Now Watching tap.
- Replaced the diagnostic export's silent temporary-file copy with a direct,
  error-reporting atomic write. Physical tvOS denied the returned Documents
  location. Inspection of a real `.xcappdata` container confirmed physical
  tvOS had fallen back the live logger to temporary storage, which Xcode omits.
  The tvOS-only logger and export now use the already-writable and
  container-visible `Library/Caches/Autohop` directory; iPhone logging paths
  are unchanged.
- Added regression coverage for the periodic history-upload cadence.

Physical Apple TV validation remains required for repeated video starts,
pause/resume at non-1× speeds, and confirmation that a minute of TV playback
updates the iPhone history after CloudKit delivery.

### 31 July 2026 — Apple TV video return path, focus clarity and crash prevention

- Added generation ownership for asynchronous tvOS playback requests. An older
  AVAsset validation or media probe can no longer publish failure/player state
  after the user selects a newer episode.
- Reopening the currently playing episode now presents its existing AVPlayer
  without restarting, rebuffering, resetting resume position or reapplying
  default speed.
- Added a persistent **Now Playing / Now Watching** section to the normal Home
  layout after dismissing playback, including explicit **Return to video** and
  play/pause actions. It replaces the floating player bar, participates in
  predictable top-to-bottom focus order and never obscures other content.
- Added a consistent, low-cost selected-tile treatment across Home, Up Next,
  Library and podcast episode lists: a high-contrast magenta edge, restrained
  purple fill and short focus transition. Native tvOS card behaviour remains
  authoritative; no custom remote-command interception was introduced.
- Made playback speed explicit in full-screen native video controls. The menu
  title shows the active rate, the selected rate is checked, and changing it
  refreshes the menu while preserving the engine-owned player.
- Native AVPlayerViewController instances now detach from the engine-owned
  player when their cover is dismantled, allowing a clean full-screen video
  controller to attach when reopened.
- Removed the duplicate dismissal checkpoint that synchronously flushed
  progress/statistics twice and contributed to slow navigation back to Home.
- Added regression tests for stale playback-request rejection, reconstructed
  identity reopening the same enclosure, and genuinely different enclosures
  starting a new request.

Physical Apple TV validation remains required for repeated video dismiss/reopen,
directional focus stability, remote repeat behaviour, switching directly from a
playing video to another episode, long-buffering TWiT media, resume position and
speed preservation.

### 31 July 2026 — canonical Apple TV identity, video and sync resolution

- Added one tvOS-only episode resolver for Queue, Continue Watching and
  playback. Legacy history rows now infer video from recognised enclosure URLs
  instead of silently defaulting missing `mediaKind` to audio.
- Preserved the deliberate distinction between audio and video subscriptions
  while allowing a stale pre-reinstall subscription UUID to inherit settings
  from one exact current title. This restores the correct podcast title,
  playback speed and resume position without changing iPhone behaviour.
- Replaced title-only history association with stable history key, episode ID,
  enclosure URL and guarded title-plus-podcast matching.
- Added a bounded AVAsset video-track probe only for legacy, extensionless
  media whose type cannot otherwise be established. Declared and recognised
  media starts without the probe.
- Replaced the contradictory five-minute foreground poll plus five-minute
  freshness gate with a 60-second tvOS safety poll and 90-second maximum
  snapshot age. Private CloudKit changes remain the primary path.
- Added stable Up Next focus restoration when sync replaces or removes rows.
- Added a dedicated tvOS unit-test target covering legacy video inference,
  audio/video subscription separation, stale UUID settings inheritance,
  guarded history matching and foreground freshness policy.
- Regenerated the Xcode project from `project.yml`. These changes are confined
  to the Apple TV target and its tests; no iPhone runtime path was modified.

Physical Apple TV validation is still required for the legacy Windows Weekly
record, 1.5x preference inheritance, exact resume position, full-screen video,
foreground sync convergence and focus stability during a live queue update.

### 31 July 2026 — download recovery field validation and hardening

- Isolated the field-proven stalled-download recovery into a reproducible
  source-control commit. In diagnostic log 24, all 32 episodes that encountered
  stalls recovered and all 52 attempted episodes completed.
- Preserved the four-minute first-byte allowance during genuine process
  suspension, while shortening it to 60 seconds whenever foreground UI or
  active audio provides a verified execution window. Generation ownership and
  the final live-progress check remain mandatory before cancellation.
- Added truthful build provenance to launch diagnostics: commit,
  dirty-working-tree state, source fingerprint and UTC build timestamp.
  Diagnostic captures made from local edits can no longer be mistaken for a
  clean commit.
- Added an absolute feed-response ownership check. A response delivered after
  the request window—commonly after process suspension—is discarded instead of
  allowing one stale feed to monopolise a resumed refresh cycle.
- Removed synchronous statistics persistence from successful download
  settlement. Download counters remain authoritative in memory and are
  persisted at the next lifecycle/statistics checkpoint, preventing disk work
  from delaying completion handling.
- Added regression coverage for screen-closed active-audio rescue timing and
  deferred download-statistics persistence.
- Retained the existing retry ladder, circuit breakers, durable cooldowns,
  truthful **Retry Now** presentation and active-runtime fallback because log
  24 shows those mechanisms are effective.

Device validation still required:

- Deliberately exercise **Retry Now** on a genuinely stalled transfer.
- Confirm a quiet, low-playback overnight capture still behaves safely when no
  active execution window exists.

### 30 July 2026 — truthful stalled-download recovery and Retry Now

- Fixed exhausted automatic downloads being overwritten with **Waiting to
  retry** even when no scheduled retry existed. That label now requires a real
  retry owner; failed and ownerless paused rows expose **Retry Now**.
- Fixed a spent in-memory 30/60/120-second watchdog ladder carrying into a later
  post-cooldown attempt. Each genuine recovery cycle now gets a fresh short
  ladder while the durable 15/30/60-minute consecutive-exhaustion history is
  preserved across refreshes and launches.
- Manual Retry Now clears stale short-retry ownership and bypasses automatic
  cooldown/circuit gates. Cancel and Archive now clear retry tasks, dates,
  generations and active recovery eligibility.
- Added a recovery-only ordinary URLSession transfer while foreground UI or
  active audio provides an execution window. This avoids repeatedly feeding
  cross-host background-session first-byte stalls back into the same failing
  transport; ordinary automatic work remains durable and circuit-protected.
- Added circuit-bypass and active-runtime transfer diagnostics plus Downloads
  page state snapshots, and regression coverage for truthful retry presentation
  and durable cooldown history.

### 30 July 2026 — route-safe Play Instant recovery

- Fixed Play Instant losing an otherwise eligible automatic arrival when an
  AirPods route disappeared or playback paused just before download completion.
- Eligible arrivals now remain armed for up to 30 minutes and trigger, with the
  existing warning, when safe playback resumes. They never start unexpectedly
  through the phone speaker and simply retain their normal Up Next position if
  the waiting period expires.
- Added explicit diagnostics for armed, resumed, expired, manually satisfied
  and ineligible Play Instant decisions, replacing the previous silent guard.
- Preserved automatic-download and filter requirements, FIFO sequencing, exact
  interrupted-position restoration and deliberate-user-action cancellation.

### 30 July 2026 — responsive viewport foundations and easy-win layout pass

- Added one central adaptive-layout vocabulary for narrow, standard, wide and
  expansive container widths, readable content measures, gutters and adaptive
  grids, with regression tests for its boundaries.
- Replaced fixed-height onboarding, sleep, editing, archive and audio-control
  sheets with scroll-safe medium/large presentations.
- Added compact fallbacks for crowded Player, Mini Player, Sleep Timer and
  Stats controls; the AirPlay route control can now collapse without forcing
  the Player row beyond the available width.
- Converted Player/Episode metadata and Stats detail grids to adaptive columns,
  and converted Episode Detail actions to a wrapping grid.
- Added readable maximum widths to major custom scrolling pages including
  Search, Downloads, Support, Stats, podcast details and onboarding.
- Made Welcome and first-subscription onboarding scroll-safe for short
  landscape viewports and larger text, enlarged small onboarding touch targets,
  and began replacing fixed typography with semantic Dynamic Type styles.
- Changed Discover and Top chart feature cards from unconditional fixed heights
  to aspect-driven, clamped sizing.
- This phase deliberately does not enable iPad/Mac targets or change navigation;
  it establishes the fluid view foundation required before those later stages.

### 30 July 2026 — safer, honest sharing foundations

- Podcast Detail and Podcast Settings now share the podcast itself instead of
  silently sharing its newest episode.
- Episode sharing no longer falls back to the raw media enclosure. Autohop now
  shares only a validated publisher-facing episode page or HTTP(S) permalink;
  when none exists it safely shares the branded card and episode details.
- Added **Copy Link** when a safe episode page is available, with explicit copy
  confirmation and accessibility guidance.
- Added a pure `ShareURLResolver` that rejects credentials, sensitive query
  fields, local/private-network addresses, non-web schemes and oversized URLs.
- Replaced the fixed 580-point share sheet with adaptive, scrollable medium and
  large presentations for small phones, landscape and larger text sizes.
- Added a dedicated podcast share sheet that exports podcast artwork, title,
  creator and description without exposing the RSS feed address.
- Added resolver regression tests and updated the authoritative staged sharing
  proposal. Universal Links, inbound sharing, expanded card formats and tvOS QR
  sharing remain later Version 1.5 work.

### 29 July 2026 — automatic-download watchdog self-recovery

- Fixed automatic downloads becoming permanently stranded at 0% after two
  first-byte watchdog cancellations. Retry-task ownership now ends when the
  replacement transfer is handed off, so a later genuine timeout advances the
  bounded retry policy instead of being misclassified as a duplicate callback.
- Added generation-safe cleanup and explicit retry dates. Diagnostics now
  identify retry generation, handoff, next attempt and the owner responsible
  when a decision is coalesced.
- Separated watchdog recovery from a deliberate user pause in the Downloads
  page. Automatic stalls display **Waiting to retry** and remain recoverable;
  only a user-requested pause remains terminal until Resume is selected.
- Persisted intent draining now verifies concrete URLSession and local FIFO
  ownership. A stored `downloading` or `queued` flag with no corresponding live
  task is treated as an orphan, normalized and restarted automatically on
  foreground, launch, background-task completion or restored connectivity.
- Added explicit disposition diagnostics for every retained intent: scheduled
  retry, live URLSession task, local pending queue, recoverable orphan,
  exhaustion cooldown or eligible recovery.
- Added cross-host first-byte incident detection. Stalls affecting three or
  more unrelated hosts within ten minutes open a five-minute shared-session
  circuit, safely reset URLSession cache/credential state without invalidating
  healthy tasks, and automatically re-drain pending work when the circuit
  closes.
- Added a pure recovery-ownership policy and regression tests covering
  scheduled retries, live tasks, queued work, orphaned stored transfers and
  recoverable failed/not-downloaded intents.


### 28 July 2026 — storefront-aware Shows and Episodes search

- Replaced the modal flat podcast search list with a dedicated Search page
  pushed from Discover.
- Added independent Apple catalog providers for shows (`podcast`) and episodes
  (`podcastEpisode`), with separate loading, empty and failure boundaries.
- Every request now includes the country selected in Discover. Invalid or old
  persisted values safely fall back to the device storefront instead of
  silently receiving Apple's default US results.
- Results render in clearly labelled **Shows** and **Episodes** sections.
  Episode rows show their parent show, release date and duration; selection
  opens the parent show until exact RSS episode identity reconciliation ships
  in a later search phase.
- Preserved Recently Viewed, manual RSS entry, existing-subscription routing,
  browse-preview lifecycle, artwork caching and the mini-player contract.
- Added request-contract tests preventing storefront loss or accidental
  collapse of episode search back into the show endpoint.
- Follow-up physical-device refinement: Shows now use a compact, leading-aligned
  horizontal rail so their full result set no longer pushes Episodes behind the
  software keyboard. Episode rows begin immediately below the rail, and the
  results page supports interactive keyboard dismissal.
- Episode results now use deterministic relevance tiers (exact/prefix/phrase
  matches across episode title, show and publisher) and then newest publication
  date inside each tier, retaining Apple's original order only as the final tie
  breaker. Regression tests cover both ordering rules.
- Added an explicit **All / My Library** scope. My Library searches subscribed
  shows and their locally known episodes immediately, cancels remote catalog
  work while selected, and excludes temporary browse previews.
- Show-result cards now size themselves from the available viewport rather than
  a single fixed phone width. Titles use up to two lines, improving readability
  across compact phones, large phones and iPad without losing the horizontal
  rail's keyboard-friendly layout.
- Added **Publishers & Creators** groupings derived conservatively from exact
  show-author metadata. Empty/generic placeholders, URLs and email-like values
  are excluded, and no host/guest identity is inferred from prose or titles.
- Added regression coverage for local episode discovery, browse-preview
  exclusion and conservative creator grouping.
- Fixed Search result navigation being swallowed by a lazily nested typed
  destination. Show cards now link directly to the existing Podcast Detail
  page, and publisher/creator cards open their associated show list before the
  selected show proceeds to Podcast Detail.
- Episode cards now open the existing Episode Detail page. Apple catalog hits
  are reconciled safely to RSS using episode GUID first and exact normalized
  title only as a fallback; track IDs and fuzzy prose are never treated as RSS
  identity. A clear fallback offers the parent podcast when no safe match is
  possible. Regression tests cover GUID priority and fuzzy-match rejection.

### 28 July 2026 — Episode Trim duration alignment

- Fixed the duration line ("Off", "1 min 30 secs") sitting left of its row title
  on the **Default Episode Trim** rows in App Settings and the **Episode Trim**
  rows in Podcast Settings. The text now aligns flush beneath "Start skip" /
  "End skip".
- Cause: the duration was a sibling of the row `Label` in a shared `VStack`, and
  its indent was approximated with a hard-coded `.padding(.leading, 28)` that did
  not match the real `Label` icon-column width. It is now rendered *inside* the
  `Label`'s title slot, so SwiftUI owns the icon column and both lines share one
  leading edge — correct at every Dynamic Type size rather than at one font size.
- Fixed once in the shared `EpisodeTrimControlRow`, so both settings pages are
  corrected by the same change. `SettingsRowLabel` was deliberately left
  untouched: 24 other settings rows use it and none needed to change.
- Documentation: DESIGN.md `ControlRow-EpisodeTrim` now states the alignment
  contract, and the `PlaybackControlsCard.swift` AI CONTEXT header warns against
  reintroducing the fixed leading pad.

### 27 July 2026 — Discover category depth, rail "See All" tile, Priority label

- **Category pages expanded from Top 50 to Top 100.** All 19 Discover category
  pages now request 100 entries. Verified against Apple's legacy genre endpoint,
  which serves 100 (and 200) per genre. The editorial layout is unchanged and
  needs no change: the feature-card rule `(rank - 1) % 7 == 0` is
  depth-independent, so hero cards simply continue past 50 at ranks 57, 64, 71,
  78, 85, 92 and 99.
- **Depth is deliberately asymmetric.** The OVERALL Top Podcasts page and the
  Top Episodes page remain at 50 because both are served by Apple's Marketing
  Tools v2 feed, which hard-caps at 50 (`top/100` and `top/200` both error —
  verified 2026-07-25). Only the legacy-endpoint category charts can go deeper.
  Page titles now reflect this: "Top 100 - &lt;Category&gt;" vs plain
  "Top Podcasts". Depth lives in `DiscoverViewModel.categoryChartLimit`.
- **Chart cache reuse generalised.** A cached larger chart is an ordered
  superset of a smaller request, so the 15-entry Discover rails can be served
  from an already-downloaded category page. Supersets are now checked
  largest-first (100, then 50) so caches written before this change stay usable.
- **Every Discover category rail now ends with a "See All" tile** in the 16th
  position — the same 124 pt geometry as the artwork tiles, purple-tinted glass
  with a forward arrow — opening that category's chart page. Always present,
  including on rails that returned fewer than 15 podcasts, so the affordance
  never silently disappears. Wording matches the existing hero "See All"
  buttons. The shared `glassCard(cornerRadius:)` modifier gained a
  `highlighted:` parameter (defaulted, so all 40+ existing call sites are
  unchanged) applying the same purple tint as `glassCapsule`.
- **Subscriptions page: the drag-to-reorder toggle is now labelled "Priority"**
  (was "Reorder"). In-app Support, the first-run coach mark, and the website
  Support page were updated in the same pass so no instruction references a
  button name that no longer exists. Internal symbols (`finishReorderSession`,
  `beginPriorityReorderSession`, `Button-ReorderToggle`) intentionally keep
  their existing names.
- Documentation: FEATURES.md, PAGES.md, DESIGN.md (new `Tile-RailSeeAll`
  pattern) and the affected AI CONTEXT headers updated. Website rebuilt and
  deployed (`kevmarl-site` commit `e287993`).
- Validation: `swift build --target AutohopCore` passes. `DiscoverView`,
  `TopPodcastsView`, `PodcastsView` and `EpisodeBadges` are app-target only and
  were verified by inspection — **Xcode build still required**.

### 27 July 2026 — durable tvOS library recovery and large-download visibility

- Fixed a tvOS subscription materialisation failure being treated as terminal.
  Phone-authored subscription identity, feed URL, title and priority now enter
  the durable survival kit before the RSS request begins; failed requests retry
  with capped backoff, survive relaunch, and can be retried immediately with
  **Check for Updates**.
- Added a one-time authoritative iCloud membership sweep so subscriptions that
  disappeared before this repair can be recovered even when the former survival
  kit no longer contains them. Manual **Check for Updates** also performs the
  complete membership sweep.
- Library no longer silently drops a podcast while its RSS details are pending.
  It retains a non-navigable **Syncing details…** card and Settings & Diagnostics
  lists the affected subscriptions and feed hosts.
- Unified legacy Up Next recovery with the real Library materialisation path.
  A recovered queue episode now materialises its phone-authored subscription
  instead of existing only in a transient in-memory queue cache.
- Removed the Windows Weekly-specific feed and identity override. Audio and video
  subscriptions remain distinct and recovery uses only synced subscription or
  survival-kit feed identity, preventing old prototype metadata from overriding
  current phone-authored titles, media kinds and playback settings.
- Protected recovery against stale survival-kit resurrection: a synced remote
  unsubscribe cancels pending materialisation and removes its placeholder.
- Improved multi-gigabyte download handling. Explicitly paused downloads now
  persist resume data across app termination; live transfers request the video
  network service class, remain non-discretionary, wait for connectivity and
  allow constrained or expensive paths under the existing user network policy.
- Downloads now display smoothed transfer speed and estimated time remaining in
  addition to percentage and byte counts, making a slow publisher/CDN route
  distinguishable from a stalled transfer.
- Verified the complete 330-test package suite plus unsigned iOS and tvOS
  Simulator application builds.

### 27 July 2026 — background cancellation and feed-memory containment

- Removed the structured timeout race around feed requests. Feed fetches now
  inherit cancellation directly from their owning refresh task, preventing an
  uncooperative request from keeping the shared refresh coordinator occupied
  after a BGAppRefresh cooperative deadline.
- Added a file-backed, memory-mapped response path for the repeatedly
  pathological `twit.memberfulcontent.com` feed family. Its diagnostics retain
  the existing network-stage measurements so a physical-device capture can
  compare the new path with the former in-memory response materialisation.
- Added host-level parse-memory quarantine. Once one feed produces extreme
  memory growth, sibling feeds from that host are deferred instead of stacking
  several retained allocations in the same manual or automatic cycle.
- Added hard refresh-cycle ceilings at 450 MB physical footprint or 600 MB
  resident memory. Both automatic and manual refresh stop admitting feeds at
  the boundary, preserve due-work backlog where applicable, and emit an
  explicit `memoryStopped` diagnostic outcome.
- Added BGAppRefresh wake-generation and remaining-time diagnostics so an
  anomalous early expiration callback can be distinguished from the current
  task generation and an ordinary system deadline.
- Deferred listening-history progress bookkeeping until after the
  latency-sensitive playback tick, removing the observed 288 ms history write
  from clock, controls and Now Playing updates.
- Added regression coverage for both process-memory ceiling measures. The full
  330-test package suite and an unsigned iOS Simulator application build pass.

### 26 July 2026 — playable cross-device Continue Listening

- Extended listening-history sync with the episode stream URL and audio/video
  media kind. Continue Listening can now resume directly on Apple TV even when
  a reinstall, private-feed migration or remove/re-add operation changed the
  subscription identity and its local catalog has not materialized.
- Preserved backward compatibility with older history records that do not carry
  the new fields; existing iPhone builds continue to decode and sync normally.
- Added an exact-title, official-public-feed recovery for an already orphaned
  Windows Weekly video row. It does not reconstruct private credentials, create
  a duplicate subscription or use fuzzy search.
- Fixed recovery timing so arrival of live phone listening history can unlock a
  waiting legacy TV queue row without requiring another library membership
  change.
- Added regression coverage for old history decoding, playable video history
  round-tripping and tvOS history writes retaining the playable media identity.
- Audited production sources for obsolete prototype subscriptions. No original
  hardcoded test library remains; the only Windows Weekly constant is the
  explicit bounded migration fallback introduced above.
- Fixed recovered playback using a compatibility-feed GUID instead of the
  phone-authored history identity. Resume now starts from the Home card's synced
  position and subsequent TV progress updates the same cross-device record.
- Kept the phone-authored podcast name throughout playback instead of switching
  from “Windows Weekly” to the recovery feed title “Windows Weekly (Video)”.
- Prevented video episodes from entering the audio artwork UI while their
  AVPlayer is still being prepared; they now show a short “Preparing video…”
  state and then open the native full-screen video surface.
- Fixed the underlying Observation defect behind a permanent “Preparing
  video…” screen: the streaming engine now publishes player installation and
  removal, and `TVPlaybackModel` exposes a stored observable AVPlayer rather
  than an invisible computed passthrough.
- Deleted the dormant all-library tvOS RSS sweep and its throttling/suppression
  machinery. Added release guards preventing the sweep or prototype
  subscription seeding from returning.
- Added an AVFoundation regression test proving a concrete streaming player is
  published to the UI bridge and cleared at stop.

### 27 July 2026 — legacy video identity, resume and speed handoff

- Fixed an older Windows Weekly audio queue projection being accepted as the
  successful result of an explicitly requested video recovery. The affected
  row now remains non-playable while one bounded lookup resolves the exact
  episode from TWiT's official HD-video feed, and that feed takes precedence
  over a stale materialized audio-feed source.
- Restored per-podcast playback settings for queue/history records carrying an
  obsolete subscription UUID by resolving one unambiguous synced subscription
  with the same podcast identity before creating a default transient carrier.
- Made cross-device initial resume an acknowledged exact AVPlayer seek instead
  of a fire-and-forget seek that could lose a race with remote stream startup
  and begin at zero.
- Prevented Continue Watching from becoming playable through an audio-only
  Windows Weekly catalog match while its exact video recovery is pending.

### 26 July 2026 — tvOS rebuild remaining stages

- Added a compact, purgeable GRDB projection cache for the TV Library, Up Next
  queue and bounded episode details, allowing useful cached content to appear
  before CloudKit finishes updating.
- Replaced broad subscription-store observation with queue, membership and
  presentation domain events to reduce unnecessary SwiftUI invalidation and
  focus-engine stalls.
- Replaced the multi-minute first-sync carousel with an eight-second connection
  grace and progressive cached/offline UI.
- Added targeted podcast detail loading capped at 25 episodes, conditional HTTP
  validators, cancellation on navigation abandonment and a 12-podcast detail
  cache bound. The legacy all-library feed sweep is compile-time unavailable.
- Added projection cache purge/round-trip tests, a dedicated tvOS release
  validator and a physical Apple TV soak checklist. tvOS submission remains
  gated until the signed release candidate passes hardware validation.

### 26 July 2026 — legacy queue recovery and navigation responsiveness

- Fixed a starvation defect where only the first two unresolved legacy queue
  podcasts were offered detail recovery; later rows could remain on “Loading
  episode details…” forever. Recovery is now a real two-worker FIFO with bounded
  retries and a truthful terminal failure state.
- Legacy phone queue entries can now become playable from one lightweight
  matching RSS episode without persisting the complete feed. Video media kind,
  enclosure, artwork and duration are preserved.
- Home now renders authoritative Up Next projection rows, including unresolved
  legacy entries, instead of silently omitting them until RSS recovery finishes.
- Added a 150 MB pruned on-disk artwork source cache, three-per-host connection
  limit and existing 48 MB decoded-image memory cache to prevent repeated
  download/decode storms while navigating a library larger than memory capacity.
- Reduced expensive TV refresh work by separating membership/survival-kit events
  from queue/presentation events and skipping derived-state recomputation when
  neither library, queue nor listening history changed.
- Added zero-network recovery for legacy queue entries whose RSS GUID is itself
  a recognised audio/video enclosure URL. This specifically makes TWiT video
  entries such as Windows Weekly playable directly from the older synced queue
  key, without waiting for its private subscription record or fetching its feed.
- Added orphaned-subscription reconciliation for queue and Continue Listening
  records after a podcast has been removed/re-added: globally unique RSS GUID is
  preferred, with a globally unique normalized episode title as the guarded
  fallback. This uses the already-synced local Windows Weekly episode instead of
  waiting indefinitely on its obsolete subscription UUID.
- Settings diagnostics now describe unresolved rows using privacy-safe key,
  source and unique-title availability signals for physical-device verification.
- Physical TV diagnostics now include a UTC build timestamp as well as Git SHA,
  so successive uncommitted Xcode device builds can be distinguished reliably.

### Apple TV rebuild — Phases 3, 4 and 5 — 26 July 2026

- Added bounded queue-only recovery, honest Up Next sync states, stale-cache
  recovery and a five-minute low-frequency fallback poll.
  Foreground recovery no longer re-fetches the entire subscription zone.
- Added an old-phone/new-TV migration path: legacy queue rows now lazily fetch
  only their owning podcast (maximum two concurrent) instead of remaining stuck
  at “Syncing…” or triggering an all-library feed sweep.
- Introduced immutable queue-row and library-tile display models so focus-driven
  SwiftUI updates no longer traverse complete subscription/episode graphs.
- Reduced GPU compositing work by removing per-row blur materials and the
  episode-detail blurred-artwork backdrop; standard card focus remains.
- Added 80/60 safe-content spacing, ordered queue positions, video badges,
  truthful loading language and a Settings & Diagnostics page with redacted-log
  collection status, build identity, queue state and unresolved-row counts.
- Made Apple TV Search browse-only and explicitly directed subscription
  management to iPhone, preserving the phone-authoritative product contract.
- Added `TVDESIGN.md` as the canonical TV layout, artwork, sync-language,
  accessibility and focus contract.

Physical TV measurement remains required for generation latency, stable focus,
memory after two complete Library traversals and long audio/video playback.

### Apple TV rebuild — Phases 0, 1 and 2 — 26 July 2026

- Replaced optimistic streaming status with a generation-safe playback state
  machine. tvOS now waits for AVPlayer item readiness, classifies startup
  timeout/item/player failures, rejects stale callbacks, and derives Playing
  and Buffering from actual lifecycle state.
- Video episodes now open directly in Apple's native full-screen player with
  movie playback audio-session mode. Hidden video preloading and the custom
  windowed-first video surface were removed.
- Upgraded the phone-authored Up Next snapshot to a backward-compatible,
  self-contained Version 2 projection carrying podcast title, stream URL,
  media kind, artwork, duration, publication date and explicit status.
- Added monotonic queue generations scoped by an authority epoch. TV accepts
  newer generations, preserves legacy timestamp compatibility, renders and
  streams Version 2 rows without waiting for RSS catalogue materialisation,
  and uses a compact transient subscription context for playback metadata.
- Added structural Cloud sync capabilities: Apple TV cannot upload subscription
  configuration, subscription order, or Up Next authority, while playback
  state, listening history and additive statistics remain writable.
- Removed the automatic all-library RSS sweep from normal TV cloud priming.
- Reduced decoded artwork cache budget from 150 MB to 48 MB, added object-count
  limits and background/memory-pressure trimming, and disabled video preload.
- Added TV launch/build/session identity, queue generation/render diagnostics,
  playback lifecycle diagnostics, and truthful TV-only Search wording.
- Added regression coverage for legacy queue decoding, projection-only
  playback, generation ordering and truthful playback lifecycle flags.

Physical Apple TV validation remains required before these phases are declared
complete or the tvOS app is promoted as shipping.

### Guaranteed background freshness and response diagnostics — 26 July 2026

- Reserved up to two real slots for feeds that have crossed their hard
  successful-check ceiling in every capped background context. Reservations
  replace ordinary work inside the existing network budget, so a stale feed can
  no longer lose indefinitely to release-window scoring without increasing the
  four-minute background-audio energy ceiling.
- Tightened the general BGAppRefresh and BGProcessing successful-check ceiling
  from four hours to two. Added a separate freshness policy that recognises
  hourly/rolling profiles and synthetic news-bulletin feeds such as NPR News Now
  even when their limited RSS history learns as `dailyWeekdays`; those feeds use
  a 75-minute ceiling.
- Made release-window confidence operational. A daily, weekly, multi-slot, or
  burst feed whose window confidence falls below 0.50 now uses broad two- or
  four-hour surveillance instead of letting a low-quality learned time window
  gate checks. Cadence confidence remains independent.
- Added URLSession transaction diagnostics around large or memory-amplifying
  feed responses: wire and materialised sizes, content encoding/type, redirects,
  protocol, cache/network fetch type, duration, and process-memory deltas. These
  fields narrow the remaining transient allocation without incorrectly
  attributing process-wide memory across an `await` to XML parsing.
- Expanded BGProcessing terminal diagnostics with wake/process identity and
  explicit completion-versus-expiration race outcomes, while retaining the
  one-shot completion gate and owner-aware cycle cancellation.
- Added a final app build phase that embeds the checked-out Git commit in the
  built Info.plist before signing. Release validation now fails if the embed
  phase or explicit non-git fallback disappears.
- Added deterministic regression coverage for bulletin freshness
  classification, low-confidence surveillance, and stale-slot reservation.

### Apple TV playback preference and archive sync identity — 1 August 2026

- Persisted the playback speed selected on Apple TV into the existing synced
  listening-history record. Projection-only video episodes now restore that
  speed after an app rebuild or relaunch instead of reverting to 1×.
- Canonicalised legacy nested episode GUIDs before Apple TV authors archive
  state, preventing duplicated subscription/GUID wrappers from creating an
  iCloud record that the iPhone cannot match to its local episode.
- Added record-level diagnostics for listening-history and episode-state sends
  and receives, including position, speed, archive state, identity and whether
  a newer local version remains pending. A paired TV and iPhone diagnostic can
  now distinguish upload, fetch and local-application failures precisely.
- Bridged accepted remote listening-history updates into the iPhone's separate
  authoritative playback-position store. Previously CloudKit and History could
  receive the TV position while iPhone playback continued reading a stale local
  resume cache, making successful sync appear to have had no effect.
- Extended that bridge to an episode already open on the iPhone player: when
  the phone is paused, an accepted newer TV position now moves the live scrubber
  and resume point immediately. An actively playing iPhone remains authoritative
  and is never interrupted by a remote seek.
- Reworded tvOS startup and player buffering feedback from “Preparing video” to
  the media-neutral “Preparing playback” for both audio and video episodes.
- Added an overflow-aware tvOS player heading: long episode titles pause, scroll
  at a steady reading speed until their ending is visible, pause again, and
  return before repeating. Short titles remain still and Reduce Motion uses a
  wrapped, non-animated presentation.
- Verified from a physical Apple TV capture that natural playback is credited to
  the TV's additive daily Stats partition and queued to iCloud alongside history.
  The iPhone continues to merge that per-device partition into its Stats views.
- Added regression tests for projection-only speed restoration, preservation of
  a previously stored speed, and nested legacy GUID canonicalisation.

### Apple TV Home presentation cleanup — 2 August 2026

- Removed the duplicate large Home heading from the scrolling page. The
  persistent system Home tab control is now the single page identity and its
  tab chrome is explicitly kept visible while users move through shelves.
- Renamed the transient Home sync badge from “Updating from iPhone” to the
  accurate “Updating from iCloud”, aligned as fixed top-right chrome so status
  changes never reflow Home content.
- Removed the actively loaded episode from Home's rendered Up Next shelf while
  retaining it in the authoritative phone-authored queue and dedicated Up Next
  page. Now Playing is therefore the active episode's only Home appearance.

### Private iCloud becomes the sole sync architecture — 2 August 2026

- Retired the Autohop Pro subscription concept and removed its StoreKit product
  configuration, entitlement owner, purchase/restore UI, settings route and
  release feature gates.
- Removed the complete Cloudflare Worker relay client and credentials model,
  iPhone relay coordinator, APNs relay-token forwarding, silent-push dispatch,
  heartbeat/feed-membership/sync-nudge logic, tvOS paired registration and relay
  protocol tests.
- Kept APNs registration on both platforms solely for CKSyncEngine's native
  private CloudKit notifications. No token or user data is sent to an Autohop
  server or third-party synchronization service.
- Simplified iPhone startup and CloudKit callback ownership and retained tvOS's
  bounded foreground freshness poll as protection against delayed CloudKit
  delivery.
- Updated generated-project inputs, package membership, release validation and
  canonical product documentation to state that private iCloud is the only
  cross-device synchronization method.

### Apple TV queue consistency and cross-device History — 2 August 2026

- Replaced Home's horizontal Up Next artwork shelf with the exact same
  full-width, focusable queue rows used by the dedicated Up Next page,
  including position, duration, video state, detail recovery and Archive.
- Moved iCloud state into one app-shell status badge shared by Home, Up Next,
  Library, History, Search and Settings. Status changes no longer insert rows
  into page content or disturb focus and layout.
- Added a History tab showing the 50 most recently archived episodes from the
  existing private-iCloud listening history shared by all devices. Synced
  metadata remains visible even for legacy entries awaiting local details;
  resolved audio and video episodes can be replayed directly.
- Added a bounded recent-archive query and focused observable History model so
  remote history updates do not require views to scan the full history table.
- Removed the redundant dedicated Up Next tab after Home became the complete
  queue surface. Home rows now place priority before artwork, align publisher
  and duration directly beneath the episode title, and use compact icon-only
  Archive controls to preserve more space for episode information.
- Removed Autohop's second custom focus stroke from tvOS cards. Native tvOS card
  focus now owns the edge while Autohop supplies only its purple fill and glow,
  eliminating the double border visible on highlighted tiles.
- Added the iOS-matching blue Play Next control to every Home Up Next row except
  the first. Apple TV sends a narrow one-use command through the user's private
  iCloud; the iPhone resolves it through the existing QueueCoordinator pin
  policy and republishes the authoritative queue snapshot to every device.
- Play Next now pins the selected Apple TV row synchronously, before any
  CloudKit work begins. A temporary local overlay protects that immediate
  result from older snapshots until the phone-authored queue confirms the pin,
  removing the former round-trip delay and visible reorder reversal.
- Corrected legacy/reconstructed queue identity handling by pinning with the
  authoritative row key rather than a potentially different locally-derived
  episode key. Added durable stage diagnostics for row matching, immediate
  ordering, iCloud submission, phone application and snapshot confirmation;
  forced important tvOS evidence to disk so Xcode container captures are not
  returned as empty open log files.
- Kept Apple TV structurally unable to overwrite the full Up Next snapshot.
  Companion commands are uniquely identified, safely repeatable, consumed by
  the phone, and removed after application so delayed delivery cannot create a
  second queue authority.
- Completed a tvOS AI-context audit. Every runtime and tvOS regression-test
  Swift file now carries an `AI CONTEXT` ownership header; a directory-level
  architecture map documents target contracts and the strict plist,
  entitlement and asset formats that cannot safely contain comments. The tvOS
  release validator now fails if a future TV or TVTests Swift source is added
  without an AI-readable header.
- Added explicit cross-device queue pin state to the phone-authored Up Next
  snapshot. tvOS now displays the same blue Play Next and orange Play Last
  `pin.fill` badges as iPhone instead of inferring state from row position.
- Added the iOS-matching teal `pin.slash.fill` Unpin action to pinned tvOS Home
  rows. Unpin restores the natural Priority Stack position immediately on the
  Apple TV, then uses the existing one-use private-iCloud QueueCommand channel
  so iPhone persists the change and republishes it to every device.
- Preserved compatibility with older queue snapshots and already-uploaded Play
  Next commands: missing pin state decodes as unpinned, while a legacy command
  without an action still decodes as Play Next. Added shared CloudKit round-trip
  and tvOS natural-order regression tests for both Pin and Unpin.

### Standards-compliant podcast client identity — 7 August 2026

- Added one shared, privacy-safe User-Agent identity for iOS and tvOS RSS,
  artwork, chapter, enclosure-download and streamed-media requests. The format
  follows current IAB podcast measurement guidance: `Autohop/<version> Apple
  <device-class> <OS>/<version>`.
- Applied the identity to foreground, background and recovery URLSession paths
  and to AVFoundation streaming through Apple's supported
  `AVURLAssetHTTPUserAgentKey`, so podcast publishers can consistently
  distinguish genuine Autohop listening from generic Apple networking traffic.
- Deliberately excluded exact hardware models, serial numbers, account data,
  installation identifiers and advertising identifiers. Added deterministic
  iOS/tvOS format and header-preservation regression tests.

### Discover search navigation reliability — 7 August 2026

- Search now requests keyboard focus as soon as its dedicated results page is
  presented, so one tap on Discover's search control is enough to begin typing.
  The page owns an iOS 17-compatible focused text field instead of relying on
  timing-sensitive navigation-bar search-controller installation.
- Moved Search, subscribed-show and preview-show navigation onto RootView's one
  typed navigation path. Back now returns from a show to Search without an
  orphaned blank page, and the mini-player can reliably clear the path and
  reveal the permanent main Player from every search result.
- Added narrow navigation diagnostics for mini-player requests and completed
  returns to the Player root, preserving evidence if a future presentation
  layer interferes with the shared route.
- Replaced the mini-player's production NotificationCenter hop and the podcast
  page's descendant `dismiss()` call with direct actions supplied by RootView.
  Both controls now mutate the authoritative navigation path synchronously;
  notification and dismiss behavior remains only as an isolated-preview
  fallback.

### Strong Vocal Boost for new users — 7 August 2026

- New installations now default the global **Default Playback → Vocal Boost**
  setting to **Strong**, so every subscription created afterwards begins with
  clearer, more present spoken audio.
- Existing subscriptions retain their exact saved audio preferences. Existing
  saved global defaults are also preserved, and users can change the factory
  choice at any time from the main Settings page without altering podcasts
  they already follow.
- Kept the low-level legacy preference fallback at Off and added regression
  coverage for fresh installs, explicit saved choices and old settings payloads
  that predate the global Default Playback setting.

### tvOS Discover and player polish — 8 August 2026

- Increased vertical separation between Discover shelves so category rows are
  easier to scan and focus from a ten-foot viewing distance.
- Reused one deterministic RSS show-notes formatter across Discover show and
  episode details, removing visible HTML tags while preserving paragraph and
  list boundaries.
- Rehydrated lightweight queue/history playback projections from the owning
  subscription before player presentation, so the Description sheet receives
  publisher episode notes rather than a title-only record. Reduced sheet title,
  publisher and body typography to a more readable long-form scale.
- Changed long player titles to scroll left only, pause on the final words and
  reset without an animated backwards pass. Added vertical glyph space and
  horizontal-only masking so descenders such as j, g and y are not clipped.
- Added a persistent **Discover Playback Speed** control to Apple TV Settings.
  It applies only to episodes launched from Discover; Library episodes continue
  to use their synced per-podcast speed.
- Replaced the compressed tvOS speed picker with a focusable menu that clearly
  shows the selected speed and exposes each available value as a separate item.
- Simplified Discover shelves to larger artwork-only cards, retaining titles
  and publishers as VoiceOver labels rather than duplicating them visually.
- Added an RSS-confirmed **Video** pill to Discover artwork. Apple chart data
  does not declare media type, so Autohop samples and caches publisher enclosure
  metadata instead of guessing from show names or artwork.
- Added an explicit, bounded publisher-feed lookup when a lightweight playback
  record has no show notes. The Description control now displays a loading
  state while resolving up to 250 items, then presents the full cleaned notes
  or an honest unavailable state if the publisher no longer carries them.
- Rebuilt **Top Episodes** as wide television-first cards with artwork on the
  left and episode title, show and release date on the right. Reduced all
  Discover shelf-heading sizes to keep the page hierarchy balanced.
- Moved missing-note resolution into the shared Description sheet so Home,
  History, Library lists and the player all use the same publisher-feed path.
  Title-copy placeholders are rejected as descriptions, and named or
  double-escaped RSS entities such as `&rsquo;` are decoded correctly.
- Expanded Top Episodes cards to provide more horizontal title space, using a
  smaller two-line title treatment so long episode names remain recognisable.
- Replaced the constrained tvOS Description sheet with a full-screen,
  Siri-Remote-scrollable reader. The wider reading column and substantially
  smaller title, publisher and body typography expose complete long-form show
  notes without truncation.
- Fixed Description dismissal by letting the presenting item binding own both
  the Done button and Menu/back action, rather than relying on nested
  presentation-environment dismissal.
- Standardised tvOS episode lists on a focus-only ellipsis menu inspired by
  modern ten-foot podcast interfaces. Up Next now groups Play Next/Unpin,
  Description and Archive behind one compact control. Library episodes already
  present in Up Next can issue the same Play Next/Unpin command without
  inventing queue identity; History uses the menu for its applicable action,
  and browse-only Discover exposes Description without gaining queue or archive
  authority.
- Removed the permanently visible Up Next pin/unpin and Archive side buttons,
  returning that horizontal space to episode titles and metadata.
- Fixed the focus-only ellipsis menu closing immediately after opening by
  keeping its presenting control mounted while tvOS transfers focus into the
  menu. Reduced the button footprint and increased its separation from the
  episode card.
- Added **Play** as the first action in every tvOS episode ellipsis menu and
  matching long-press menu, covering Up Next, Library, History and Discover.
  The action starts the selected episode immediately through the existing
  generation-safe playback coordinator.
- Added **Play Next** to every resolved Discover episode row and detail page.
  Selection pins the episode at the top of Apple TV's Up Next projection
  immediately. Shows already present in the synced Library reuse their
  authoritative identity and send the normal cross-device QueueCommand;
  browse-only shows remain local to Apple TV so browsing never creates or
  activates an iPhone subscription as a hidden side effect.

### Apple TV release preparation — 9 August 2026

- Reorganised Apple TV Settings around everyday users: Discover playback speed
  remains first, followed by understandable iCloud, Up Next, Now Playing and
  About information. Technical counters and build provenance now live in a
  clearly secondary Developer Diagnostics section, with the full diagnostic
  export deliberately placed at the absolute bottom.
- Corrected cold-launch readiness so a cached show-artwork projection can no
  longer expose Home before the real store, Up Next, history and Continue
  Listening projections are assembled. This removes the misleading transient
  “Nothing to play yet” frame seen immediately after the system launch screen.
- Restored the existing 42-message branded startup carousel. First launch now
  explains private iCloud setup and highlights current features while Autohop
  prepares the first usable screen; returning launches still finish as soon as
  their complete local projection is ready rather than waiting artificially.
- Added a dedicated public **Autohop for Apple TV** website page. Its upper half
  explains the big-screen philosophy and current benefits; its lower half is a
  detailed setup, navigation, playback, Discover, iCloud, Settings and
  troubleshooting guide grounded in the current tvOS implementation.
- Made Discover Playback Speed the explicit initial focus target so Settings no
  longer opens on Check for Updates or leaves the speed menu unreachable.
- Increased separation around Settings section headings to make the user,
  playback, About and developer groups easier to distinguish at TV distance.
- Updated fresh-install defaults for the Version 1.5 ecosystem: private iCloud
  Sync, the global new-episode notification switch and Weekly Listening Recaps
  now start on. Monthly/yearly recaps remain off, per-podcast notification
  choices and iOS system permission still apply, and older saved settings use
  historical false fallbacks so no existing user's choices are rewritten.

## Validation still required

- Run a prolonged unplugged, screen-closed playback capture on a physical
  device to measure the new freshness ceilings under representative conditions.
- Review the new URLSession response metrics if abnormal feed-memory growth
  recurs; the diagnostics deliberately measure the network-response stage
  before attributing growth to XML parsing.
