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

- Added bounded queue-only recovery after Relay wake hints, honest Up Next sync
  states, stale-cache recovery and a five-minute low-frequency fallback poll.
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

## Validation still required

- Run a prolonged unplugged, screen-closed playback capture on a physical
  device to measure the new freshness ceilings under representative conditions.
- Review the new URLSession response metrics if abnormal feed-memory growth
  recurs; the diagnostics deliberately measure the network-response stage
  before attributing growth to XML parsing.
