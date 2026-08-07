# Autohop tvOS Rebuild — Phased Implementation Proposal

<!--
AI CONTEXT — Docs/TVOS_REBUILD_PROPOSAL.md

PURPOSE: Canonical implementation plan for rebuilding the existing Autohop
tvOS client after the 26 July 2026 code, performance, sync, playback, focus,
and design audit. This document supersedes the implementation direction in
Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md where the two conflict. The older
document remains historical evidence of the original build and repair rounds.

STATUS: PHASES 0–6 IMPLEMENTED IN CODE ON 26 JULY 2026; PHYSICAL-DEVICE EXIT
GATES REMAIN OPEN. Follow-up repairs now include playable legacy-history
recovery, authoritative cross-device resume, removal of the dormant full-feed
sweep, and an Observation-safe AVPlayer bridge. A phase is not marked COMPLETE
until its required Apple TV scenarios pass. Record completed product work in
VERSION_1.5.md.

PRIMARY OUTCOMES:
1. Every audio/video request reaches a truthful playing, paused, ended, or
   actionable failed state; remote AVPlayer failures cannot remain invisible.
2. Apple TV renders the phone-authored Up Next generation promptly and can play
   its entries without performing an all-library RSS sweep.
3. Normal sync and navigation perform no broad main-actor library rebuild.
4. tvOS retains a compact purgeable GRDB projection cache, not the phone-shaped
   full subscription/episode store.
5. The interface follows explicit Siri Remote focus contracts and standard
   tvOS components, with a documented TV-specific design system.

NON-GOALS:
- Do not change iPhone queue ordering, download policy, or Release Radar rules.
- Do not make Apple TV a second feed-monitoring/download engine.
- Do not remove offline/cold-start resilience by depending on a currently
  online iPhone.
- Do not hand-build Liquid Glass effects that duplicate system components.
- Do not advertise tvOS as shipping until its release gates pass.

AUTHORITY: The iPhone is authoritative for subscriptions, settings, priority
order, and Up Next composition. TV is authoritative only for playback actions
performed on TV (position, played state, history, and its additive stats).
-->

## 1. Executive decision

The tvOS app requires a controlled rebuild of its TV-specific data,
synchronisation, playback-lifecycle, navigation, and presentation layers.
Shared domain policy should be retained.

The current client is not discarded wholesale. Keep:

- stable subscription/episode identity;
- `QueueModel` ordering and snapshot resolution policy;
- CloudKit record mapping and conflict protections;
- listening-history and statistics write-back;
- `StreamingPlaybackEngine` as the shared seam, after lifecycle repair;
- ImageIO downsampling and in-flight artwork request deduplication;
- the iPhone-authoritative/read-only-TV product rule;
- existing diagnostic logging and the TV hang watchdog;
- the four-tab top-level information architecture unless usability testing
  demonstrates a better structure.

Replace or substantially restructure:

- the former monolithic `TVAppModel` composition root (decomposed into focused
  tvOS owners on 2 August 2026; see
  `Docs/TVAPP_MODEL_DECOMPOSITION_PROPOSAL.md`);
- full-library episode materialisation on TV;
- launch/foreground RSS sweeping across every subscription;
- broad `objectWillChange`-driven projection invalidation;
- blind queue freshness polling without generation acknowledgement;
- optimistic AVPlayer success reporting;
- custom windowed-first video presentation;
- implicit focus behaviour and inconsistent visual hierarchy.

## 2. Audit findings that this proposal treats as established

### 2.1 Confirmed defects

1. `StreamingPlaybackEngine` does not observe `AVPlayerItem.status`, item/player
   errors, failed-to-play notifications, first-frame readiness, or a startup
   deadline. `TVPlaybackModel` can therefore set `isPlaying = true` after
   `AVPlayer.play()` even when remote media later fails.
2. TV Search claims that a TV subscription appears on other devices, while the
   TV CloudKit engine uses `pushesSubscriptionState: false`; TV-created
   subscriptions remain local.
3. The decoded TV artwork cache is configured for 150 MB versus 32 MB in the
   iPhone artwork loader. The TV limit does not include images retained by
   views, duplicate target sizes, source buffers, player buffers, or models.
4. Up Next snapshots are on the CloudKit fast lane, not the 60-second
   history/statistics slow lane. Any future diagnosis must not repeat that
   incorrect latency model.
5. `pushesSubscriptionState: false` does not structurally prevent outbound
   `QueueSnapshot` changes. TV normally does not author a queue today, but
   authority is enforced by convention rather than capability.
6. `refreshFeeds()` can fetch and parse every active subscription feed after
   launch/foreground priming.
7. Broad library refresh work, equality comparison, indexing, queue resolution,
   and history projection occur under a main-actor model.
8. Primary page padding commonly uses 64 horizontal / 48 vertical points,
   below Apple's typical 80 / 60 tvOS safe-content guidance.

### 2.2 Confirmed design limitations

- Material exists (`.thinMaterial`) but is used inconsistently as generic card
  fill rather than as a coherent hierarchy.
- Semantic SwiftUI typography is already used and should be retained; do not
  describe the current app as a fixed iPhone-size type port.
- Focus sections exist, but default focus, identity, restoration, mutation
  fallback, and cross-region navigation are not specified end to end.
- The 42-message first-sync carousel masks missing progressive availability.
- Dismissing the audio player leaves no strong persistent route back to Now
  Playing.

### 2.3 Important unresolved evidence

Missing AVPlayer lifecycle observation explains why failures are invisible. It
does not yet prove why a particular video asset fails. Candidate causes include
media/server/redirect/MIME/codec/network problems and secondary session/surface
lifecycle defects. Phase 0 must capture one real failure before source-specific
fixes are claimed.

## 3. Product and authority decisions

These decisions are locked for implementation unless the product owner changes
them explicitly.

### D1 — Phone-authoritative, not phone-online-dependent

The phone authors subscription configuration and Up Next. The TV keeps the
latest accepted projections in purgeable local storage and remains usable when
the phone is offline or absent. CloudKit, not a live peer connection, is the
durable transport.

### D2 — TV streams; it does not mirror iPhone downloads

Queue projections contain stream URLs. The TV does not sync media files or run
an automatic download manager.

### D3 — Compact local database retained

Keep GRDB as a rebuildable projection cache. Do not retain a phone-shaped full
library containing broad episode histories. Do not replace transactional storage
with ad hoc large UserDefaults blobs.

### D4 — One queue authority

Only the iPhone can create and upload Up Next queue generations. TV may write
episode state, listening history, positions, and its device-partitioned stats.

### D5 — Projection-first rendering

Home, Up Next, and Continue Listening render from denormalised CloudKit
projections. RSS/catalogue resolution is optional enrichment, never a
prerequisite for queue display or playback.

### D6 — System video player first

Video opens directly in `AVPlayerViewController`. Custom UI is limited to
supported transport-bar actions/content tabs and pre/post-player surfaces.

### D7 — Evidence before optimisation claims

Every phase records baseline and post-change measurements on physical Apple TV.
No performance claim is complete because a simulator build passes.

## 4. Target architecture

```text
iPhone authoritative domain
├── Subscription configuration
├── Priority order
├── Download-backed Up Next composition
└── Projection publisher
    ├── TVQueueProjection
    ├── TVLibraryProjection
    └── TVResumeProjection
              │
              ▼
        CloudKit private zone
              │
              ▼
tvOS application
├── TVSyncCoordinator
├── TVProjectionStore (compact, purgeable GRDB)
├── TVQueueRepository
├── TVLibraryRepository
├── TVResumeRepository
├── TVEpisodeDetailRepository (bounded, lazy)
├── TVPlaybackCoordinator
├── TVArtworkRepository
├── TVNavigationModel
└── Small immutable display models → SwiftUI views
```

### 4.1 TV application model rule

The root model may compose coordinators and expose root lifecycle state. It must
not fetch feeds, query whole history tables, reconstruct the complete library,
or own every UI projection.

### 4.2 Main actor rule

The main actor owns:

- SwiftUI-observed assignments;
- navigation/focus state;
- UIKit/AVKit presentation;
- short playback UI mutations.

Database reads, decoding, sorting, projection resolution, network preparation,
and cache pruning run off-main, then publish one immutable result.

### 4.3 Invalidation rule

Use domain-scoped change notifications:

- queue generation changed;
- library projection changed;
- resume projection changed;
- episode state changed;
- playback display state changed;
- sync health changed.

Do not use one broad subscription-store `objectWillChange` as the trigger for
unrelated survival, history, queue, and library work.

## 5. Projection schemas

Schema names are conceptual until Phase 2 finalises CloudKit compatibility.
All records require explicit versioning and backward-compatible decoding.

### 5.1 `TVQueueProjection`

One coherent ordered snapshot:

```text
schemaVersion: Int
generation: Int64                 // monotonically increasing per authority
generatedAt: Date
sourceDeviceID: String
entries: [TVQueueProjectionEntry]
```

Each entry:

```text
episodeKey: String                // stable subscription-scoped identity
episodeID: UUID?                  // optional local diagnostic identity
subscriptionID: UUID
episodeTitle: String
podcastTitle: String
streamURL: URL
mediaKind: audio | video
artworkURL: URL?
durationSeconds: Double?
publishedAt: Date?
explicit: Bool?
positionSeconds: Double?          // optional resume hint; history remains truth
```

Rules:

- ordering is authoritative and never entry-merged;
- a TV row is displayable and playable without local RSS data;
- generation wins before timestamp; timestamp is diagnostic/fallback only;
- reject an older generation from the same authority epoch;
- include an authority-epoch UUID if generation reset can occur after reinstall;
- cap entries to the actual Up Next product limit, not arbitrary feed history.

### 5.2 `TVLibraryProjection`

Contains display-only subscription tiles:

```text
schemaVersion, generation, generatedAt, sourceDeviceID
subscriptions[]:
  subscriptionID, title, author, artworkURL, priorityRank,
  category?, latestEpisodeSummary?, lastPlayedAt?
```

No episode arrays.

### 5.3 `TVResumeProjection`

One current Continue Listening/Watching entry containing all display and stream
data plus the current position. This may be derived from the existing listening
history schema initially if duplicating truth would add conflict risk.

### 5.4 Local GRDB tables

Proposed compact cache:

- `tv_queue_projection`
- `tv_library_projection`
- `tv_resume_projection`
- `tv_episode_detail_cache`
- `tv_sync_state`

`tv_sync_state` stores last announced/fetched/rendered generation, timestamps,
last error category, retry state, and source device. The database remains under
the tvOS Caches directory and must be fully rebuildable after purge.

## 6. CloudKit capability model

Replace the single subscription boolean with explicit capabilities:

```text
CloudSyncCapabilities
├── pushSubscriptionState
├── pushSubscriptionOrder
├── pushQueueProjection
├── pushEpisodeState
├── pushListeningHistory
└── pushListeningStats
```

Recommended presets:

```text
iPhone authority:
  true, true, true, true, true, true

tvOS companion:
  false, false, false, true, true, true
```

At engine activation, delete or quarantine prohibited pending rows so an old TV
database cannot upload stale authoritative records.

## 7. Phased implementation plan

Each phase is independently reviewable and reversible. Do not combine phases in
one unbounded change.

---

## Phase 0 — Evidence, diagnostics, and immediate truth fixes

**Status:** IMPLEMENTED — DEVICE VALIDATION PENDING

### Objective

Create reproducible baselines for all four reported problem areas and fix only
user-facing statements/configuration limits that do not depend on the rebuild.

### Work

1. Embed app version, build, Git commit, process session, database identity, and
   projection schema versions in every TV diagnostic launch event.
2. Add playback events:
   - requested source host/media kind;
   - asset property load start/result;
   - player-item status transitions and errors;
   - player error;
   - time-control status/reason for waiting;
   - access/error log summary;
   - surface attached and `AVPlayerLayer.readyForDisplay`;
   - first advancing timestamp / first frame;
   - startup deadline result.
3. Add queue-hop events:
   - phone generation created;
   - pending upload queued;
   - send requested/completed;
   - TV push generation announced;
   - TV fetch requested/returned;
   - generation adopted/persisted/rendered;
   - unresolved-entry count.
4. Add performance counters:
   - main-thread hang duration;
   - projection computation duration and actor;
   - SwiftUI invalidation source;
   - resident/footprint memory;
   - decoded artwork cache cost/count;
   - retained subscription/episode counts;
   - feed sweep count/duration/bytes.
5. Change the Search explanation so it does not promise cross-device TV
   subscriptions. Do not enable unrestricted subscription pushing.
6. Reduce the decoded-artwork budget from 150 MB to an initial measured ceiling
   between 40 and 64 MB. Choose the exact value after recording current peak and
   cache hit rate; add memory-warning/background trimming.
7. Add a developer-only TV Diagnostics surface or log export route showing
   iCloud status, projection generations, last successful sync, unresolved
   entries, playback state/error, memory, and build identity.

### Required physical-device scenarios

- reproduce one currently failing video episode;
- cold launch after deleting the TV app;
- warm launch with cached data;
- change phone Up Next while TV is active;
- change phone Up Next while TV is backgrounded, then foreground it;
- navigate continuously while a cloud prime is active;
- browse Home, all Up Next rows, and the complete Library.

### Automated tests

- diagnostic state reducer tests;
- build identity presence test;
- sync timing event ordering test;
- artwork-cost accounting and trimming tests;
- Search copy/feature-gate characterisation.

### Exit gate

- every complaint has a reproducible trace and baseline;
- a failed video produces item/player evidence rather than indefinite silence;
- queue latency can be divided into named hops;
- no cross-device subscription promise remains;
- current and reduced artwork-memory measurements are recorded.

### Rollback boundary

Diagnostics and copy changes are independent. Artwork limit can revert without
affecting schema or sync.

---

## Phase 1 — Truthful streaming playback lifecycle

**Status:** IMPLEMENTED — DEVICE VALIDATION PENDING

### Objective

Every playback request reaches a truthful terminal/steady state. Fix the known
lifecycle defect before guessing at publisher-specific video repairs.

### State machine

```text
idle
→ resolvingSource
→ loadingAsset
→ preparingItem
→ ready
→ playing ↔ paused
→ buffering → playing
→ ended

Any pre-terminal state → failed(PlaybackFailure)
```

### Work

1. Define a sendable `PlaybackFailure` with stable categories:
   `noSource`, `network`, `http`, `unsupportedMedia`, `notPlayable`, `drm`,
   `timedOut`, `itemFailed`, `playerFailed`, `cancelled`, `unknown`.
2. Resolve an `AVURLAsset`; asynchronously load required properties and confirm
   playability. For video, confirm a usable video track where supported.
3. Observe `AVPlayerItem.status`, `AVPlayerItem.error`, `AVPlayer.error`,
   `failedToPlayToEndTime`, waiting reason, and stalls.
4. Do not set `isPlaying` because `play()` was called. Derive display state from
   the state machine and actual player status.
5. Add a bounded startup deadline which produces a recoverable error. A timeout
   must cancel only its own player generation.
6. Make player generation atomic so stale KVO/notification callbacks cannot
   mutate a newer episode session.
7. Use `.moviePlayback` for video and an appropriate spoken/default playback
   mode for audio. Session-mode correction is required but must not be described
   as the proven source failure.
8. Disable video preloading. Retain audio preloading only if Phase 0 demonstrates
   worthwhile startup benefit within the memory budget.
9. Present video directly with `AVPlayerViewController`; remove the custom
   windowed-first requirement. Use the system player for remote gestures,
   subtitle/audio options, transport behaviour, and future platform styling.
10. Preserve audio background playback and checkpoint semantics.
11. Provide actionable error UI with Retry, Back, and diagnostic reference ID.

### Tests

- state-machine transition table;
- stale-generation callback rejection;
- no-source failure;
- item failed before ready;
- timeout then late ready;
- cancellation while loading;
- stall and recovery;
- end-of-item exactly once;
- audio/video audio-session policy;
- auto-advance after successful finish only;
- retry creates a new generation;
- TV write-back/checkpoint regression tests.

Use local deterministic HTTP fixtures for redirect, delayed response, wrong
MIME, status failure, and truncated media where practical. Codec and real stream
compatibility remains a device test.

### Exit gate

- every tested episode reaches playing or actionable failure;
- no indefinite spinner with `isPlaying == true` and zero progress;
- failing real-world video has a classified cause;
- system video controls work with the Siri Remote;
- audio resume, background playback, checkpoint, and auto-advance remain intact.

### Rollback boundary

Keep new state machine behind the shared streaming engine seam until all shared
tests pass. Do not migrate sync/data architecture in this phase.

---

## Phase 2 — Versioned, self-contained Up Next projection

**Status:** IMPLEMENTED — DEVICE VALIDATION PENDING

### Objective

Make the phone-authored queue independently displayable and playable on TV with
zero RSS fetches.

### Work

1. Add schema-versioned projection models to shared core.
2. Extend the iPhone queue publisher to denormalise required TV fields.
3. Add monotonically increasing generation plus authority epoch.
4. Persist generation transactionally with the snapshot so a crash cannot
   publish duplicate/out-of-order identity.
5. Add backward-compatible decoding for the current `QueueSnapshot`; TV may
   read legacy snapshots during migration but must not require new fields until
   the phone has published the new schema.
6. Store the latest accepted projection in compact TV GRDB storage.
7. Render Home/Up Next directly from projection display models.
8. Start playback from `streamURL` in the projection. Local episode resolution
   may enrich chapters/state but cannot gate playback.
9. Enforce `pushQueueProjection = false` in the TV capability preset.
10. Quarantine prohibited old pending queue rows when TV activates sync.

### Migration rules

- old phone + new TV: legacy snapshot remains readable; unresolved playback may
  use the existing targeted fallback temporarily;
- new phone + old TV: preserve the existing record or dual-write during one
  compatibility window;
- new phone + new TV: projection path is authoritative;
- database purge: fetch latest projection from CloudKit and rebuild;
- no CloudKit: show cached projection with honest age.

### Tests

- encoding/decoding all schema versions;
- generation monotonicity and epoch reset;
- older generation rejection;
- same-generation idempotence;
- projection order preservation;
- duplicate entry handling;
- missing optional fields;
- playback without local subscription catalogue;
- TV outbound queue prohibition;
- cache purge and rebuild.

### Exit gate

- an Up Next entry displays and starts audio/video with no feed fetch;
- exact phone ordering is preserved;
- TV cannot upload queue authority records;
- cached queue is usable offline;
- no legacy client is broken during the compatibility window.

---

## Phase 3 — Generation-acknowledged queue synchronisation

**Status:** IMPLEMENTED — DEVICE LATENCY VALIDATION PENDING

### Objective

Replace blind freshness assumptions with a measurable delivery contract.

### Work

1. On material iPhone queue change, write one coherent new generation.
2. Debounce bursts, then explicitly request CloudKit send for the pending
   projection. Queue remains on the fast lane.
3. Include announced generation/epoch in the Relay sync nudge where available.
4. TV receiving a nudge fetches until it receives at least the announced
   generation or reaches bounded retry/backoff.
5. Foreground activation requests the newest projection immediately.
6. Keep a low-frequency visible-app recovery poll only when no announced
   generation is pending and the projection exceeds a freshness threshold.
7. Persist fetch/retry state so app restarts do not create a hot loop.
8. Expose honest UI status:
   - Up to date;
   - Updating from iPhone;
   - Last updated …;
   - iCloud unavailable;
   - cached/offline;
   - update failed, retry.
9. Do not imply that a silent push guarantees background execution.

### Proposed Autohop service targets

These are product engineering targets, not claims attributed to Apple:

- active TV, healthy CloudKit/Relay: p90 generation render within 20 seconds;
- foreground recovery: render current server generation within 15 seconds;
- no unbounded one-second retry loop;
- stale/offline state communicated after a bounded threshold.

Tune targets after Phase 0 baseline; document any changed target and evidence.

### Tests

- nudge arrives before CloudKit record;
- CloudKit record arrives before nudge;
- duplicate/out-of-order nudges;
- fetch returns older generation;
- network loss and recovery;
- account unavailable;
- process restart during retry;
- no Relay entitlement (CloudKit fallback);
- bounded backoff and cancellation;
- latency metric completeness.

### Exit gate

- generation latency is measurable end to end;
- agreed p90 target passes on physical hardware under normal conditions;
- TV never renders an older generation over a newer cached one;
- UI truthfully represents stale/offline state.

---

## Phase 4 — Compact TV data layer and coordinator decomposition

**Status:** IMPLEMENTED — PHYSICAL-DEVICE PERFORMANCE VALIDATION PENDING

### Objective

Remove phone-shaped data work and broad main-actor invalidation from tvOS.

### Work

1. Introduce `TVProjectionStore` and the compact tables in §5.4.
2. Create narrow coordinators/repositories from §4.
3. Replace full `Subscription` arrays in SwiftUI with immutable display models.
4. Remove launch/foreground all-library `refreshFeeds()`.
5. Add bounded lazy episode-detail loading when the user opens a podcast.
6. Retain conditional HTTP validators and a small per-podcast episode cap.
7. Cancel detail/network work when its page is abandoned unless cache fill is
   nearly complete and demonstrably cheap.
8. Compute/sort/decode off-main and publish minimal changes on main.
9. Replace broad `objectWillChange` observation with domain events.
10. Remove the 42-message blocking carousel. Render cached projections
    immediately and update progressively.
11. Preserve purge recovery: CloudKit projection fetch rebuilds the cache;
    survival metadata must remain small and contain no full library blob.
12. Remove obsolete repair/coalescing code only after its replacement path is
    verified. Do not delete diagnostics that remain valuable.

### Suggested display models

- `TVQueueRowModel`
- `TVContinueCardModel`
- `TVPodcastTileModel`
- `TVEpisodeRowModel`
- `TVPlaybackDisplayModel`
- `TVSyncStatusModel`

Each model is `Equatable`, stable-identity based, and contains only render data.

### Performance gates

Autohop-selected targets:

- cached shell visible within 3 seconds on physical TV;
- no ordinary projection publication occupies main actor for more than 100 ms;
- target steady-state under 16 ms for individual view/projection updates;
- no focus-visible hitch while sync applies;
- no all-feed network sweep on launch/foreground;
- stable memory after traversing the complete Library twice.

### Tests

- repository projection correctness;
- domain invalidation isolation;
- cache purge/rebuild;
- bounded episode-detail cache;
- cancellation;
- no-feed-fetch queue playback;
- memory-warning trims;
- coordinator lifecycle and duplicate-task prevention;
- UI model identity stability during sync.

### Exit gate

- `TVAppModel` is a small composition/lifecycle root;
- feed sweep removed from normal startup and foreground paths;
- Instruments confirms projection and SwiftUI update targets;
- cached app is useful before network sync completes.

---

## Phase 5 — TV design system, focus architecture, and screen redesign

**Status:** IMPLEMENTED — PRODUCT/DEVICE REVIEW PENDING

### Objective

Create a coherent lean-back experience built around content, predictable focus,
and standard tvOS interaction.

### Deliverable: `TVDESIGN.md`

Document only implemented/approved patterns:

- 80-point horizontal / 60-point vertical primary safe-content guides;
- typography and truncation rules;
- grids, shelves, cards, rows, spacing, and focus expansion allowances;
- focused, selected, disabled, loading, and unavailable states;
- default-focus and restoration rules;
- materials and system-component policy;
- animation/reduced-motion behaviour;
- artwork aspect ratios and decode sizes;
- sync/error/loading language;
- VoiceOver labels, order, and hints;
- screen-specific wireframes and navigation map.

### Focus contract

Every page declares:

- focus scope;
- initial/default focus;
- stable item identity;
- last-focused restoration;
- player-dismissal restoration;
- live-data-mutation fallback;
- sidebar entry/exit behaviour;
- shelf/list edge behaviour;
- behaviour when an item is disabled or removed.

Use `@FocusState`, `.focused`, `.defaultFocus`, `.focusScope`, and
`.focusSection` deliberately. Avoid timer-driven view-tree replacement while
the user navigates.

### Screen plan

#### Home

1. Continue Listening/Watching hero.
2. Compact Up Next shelf.
3. Priority/Recently Used Library shelf.
4. Honest sync indicator only when needed.

Do not block Home on complete library sync.

#### Up Next

- clear ordered position;
- artwork, episode, podcast, remaining duration, video indicator;
- focused detail region that does not cause layout jumping;
- stable focus when a new generation arrives;
- cached/unresolved state remains readable and selectable when stream data is
  available.

#### Library

- segment or group by Priority, Recently Played, and A–Z for large libraries;
- consistent poster grid using system focus effects;
- lazy podcast detail loading;
- no undifferentiated 100+ tile wall as the only navigation mode.

#### Search

Choose and document one product behaviour before implementation:

- browse/play only; or
- safe cross-device subscription creation through a narrow command schema.

Do not retain a misleading local-only subscription experience.

#### Audio player

- artwork-forward layout;
- one predictable transport row;
- chapter/speed controls only when applicable;
- persistent Now Playing route after dismissal;
- focus returns to launch episode/card.

#### Video player

- system `AVPlayerViewController` full-screen experience;
- custom actions only through supported transport menus/content tabs;
- Back returns to the originating focused item;
- no duplicate custom windowed transport interface unless later user research
  proves a concrete need.

#### Settings / Diagnostics

- iCloud status;
- last projection generation/time;
- cached/offline status;
- unresolved entry count;
- app version/build/commit;
- export diagnostics;
- privacy/support links.

### Material policy

Build with the latest SDK and prefer standard SwiftUI/AVKit controls so current
system appearance is inherited. Custom material is reserved for navigation and
interaction hierarchy, not every content card. Artwork/content remains opaque
and dominant. Remove stacked purple/material decoration that reduces contrast
or creates inconsistent focus states.

### Accessibility and usability tests

- Siri Remote directional-only completion of every primary flow;
- Play/Pause and Back semantics;
- VoiceOver traversal and labels;
- Reduce Motion;
- Increase Contrast;
- legibility across supported TV sizes and overscan conditions;
- focus never disappears or becomes trapped;
- rapid directional input cannot outrun state updates.

### Exit gate

- every primary flow works without touch assumptions;
- focus restoration passes automated UI tests and real-device review;
- safe areas and semantic typography pass visual audit;
- no custom player/navigation chrome duplicates system behaviour;
- product owner approves the visual direction on physical television.

---

## Phase 6 — Release hardening and soak validation

**Status:** AUTOMATED HARDENING IMPLEMENTED — PHYSICAL SOAK GATE PENDING

### Objective

Prove the rebuilt app remains correct under real sync, network, playback, and
memory conditions.

### Automated release suite

- all shared-core tests;
- streaming playback state-machine suite;
- projection schema/migration suite;
- sync generation/retry suite;
- outbound capability enforcement;
- compact cache purge/rebuild;
- focus/navigation UI tests;
- performance tests for projection publication;
- Search feature/copy gate;
- release entitlement and feature-gate checks.

### Physical-device matrix

- current Apple TV 4K generation(s) available to the project;
- latest shipping tvOS and minimum supported tvOS 18;
- Ethernet and Wi-Fi;
- healthy, constrained, interrupted, and recovered network;
- large real library;
- fresh install and warm cache;
- iCloud signed out/restricted then restored;
- Relay available and unavailable;
- audio/video/chapters/subtitles/alternate tracks where available;
- several-hour playback with auto-advance;
- background/foreground and app termination;
- phone changes while TV is active, inactive, and relaunched;
- cache purge simulation.

### Soak requirements

- repeated navigation for at least 30 minutes during active sync;
- several-hour mixed audio/video playback;
- repeated player enter/exit and focus restoration;
- repeated queue generation updates;
- memory reaches a stable plateau rather than monotonic growth;
- no indefinite loading/buffering/syncing state;
- no stale generation replaces a newer one.

### Ship gate

The tvOS target may be considered for submission only when:

- all prior phase gates are complete;
- no critical/high defect remains open;
- performance targets pass on physical hardware;
- privacy/support/feature documentation matches implemented behaviour;
- App Store copy makes no future-feature claims;
- archive entitlements and CloudKit environment are verified;
- tvOS is explicitly enabled by release configuration rather than accidentally
  included with the iPhone submission.

## 8. File-level implementation map

Likely additions:

```text
PlaybackCore/StreamingPlaybackState.swift
PlaybackCore/StreamingPlaybackFailure.swift
Models/TVProjectionModels.swift
Persistence/TVProjectionDatabase.swift
TV/App/TVApplicationCoordinator.swift
TV/Sync/TVSyncCoordinator.swift
TV/Data/TVProjectionStore.swift
TV/Data/TVQueueRepository.swift
TV/Data/TVLibraryRepository.swift
TV/Data/TVResumeRepository.swift
TV/Data/TVEpisodeDetailRepository.swift
TV/Playback/TVPlaybackCoordinator.swift
TV/Navigation/TVNavigationModel.swift
TV/Views/TVSyncStatusView.swift
TV/Views/TVDiagnosticsView.swift
TVDESIGN.md
```

Likely major edits:

```text
PlaybackCore/StreamingPlaybackEngine.swift
Persistence/CloudSyncEngine.swift
Persistence/CloudKitSyncMapping.swift
Persistence/AutohopDatabase.swift
Persistence/SubscriptionStore.swift
App/QueueCoordinator.swift
TV/App/AutohopTVApp.swift
TV/Playback/TVPlaybackModel.swift
TV/Views/TVMainTabView.swift
TV/Views/TVHomeView.swift
TV/Views/TVQueueRow.swift
TV/Views/TVHistoryView.swift
TV/Views/TVLibraryView.swift
TV/Views/TVEpisodeListView.swift
TV/Views/TVPlayerView.swift
TV/Views/TVArtworkImage.swift
TV/Views/TVSearchView.swift
project.yml
```

Likely removals after replacement verification:

- all-library TV `refreshFeeds()` path;
- 42-message first-sync carousel;
- obsolete broad refresh coalescer/duty-cycle workarounds;
- custom windowed video surface and duplicated video controls;
- local-only TV subscription promise/flow if browse-only Search is selected;
- full TV subscription episode persistence not required by compact projections.

Do not remove old paths before compatibility, migration, and rollback tests pass.

## 9. Documentation obligations

After each completed phase update, as applicable:

- AI CONTEXT headers in every materially changed source file;
- `VERSION_1.5.md` completed ledger;
- this proposal's phase status and evidence links;
- `TVDESIGN.md` after Phase 5 begins;
- `FEATURES.md`;
- `PAGES.md`;
- `DESIGN.md` cross-reference to TV-specific rules;
- `SYNC_DESIGN.md` projection authority/schema/migration;
- `README.md` release status;
- `project_autohop.md` architecture;
- in-app Support and website support/privacy/features pages;
- App Store metadata only after behaviour passes ship gates.

Do not update public claims ahead of implementation.

## 10. Implementation discipline for AI agents

For every phase:

1. Read this document, the older tvOS proposal, relevant AI CONTEXT headers,
   `SYNC_DESIGN.md`, and current tests before editing.
2. Inspect the dirty working tree and preserve unrelated user work.
3. Add/update the working plan with the named phase and gates.
4. Prefer pure policy/state reducers in shared core with deterministic tests.
5. Use generation tokens for asynchronous playback/sync ownership.
6. Never infer success from a request being started; observe durable/terminal
   outcomes.
7. Keep network/database/projection work off the main actor.
8. Use `project.yml` and regenerate the Xcode project; do not hand-edit the
   generated project as the source of truth.
9. Run targeted tests, full shared tests, tvOS build, and applicable release
   checks before handoff.
10. Report what is implemented separately from what still requires physical
    device validation.
11. Do not mark a phase complete because it compiles.
12. Do not delete fallbacks until migration and rollback scenarios pass.

## 11. Final success definition

The rebuild is complete when Autohop TV is a responsive, projection-driven,
phone-authoritative companion that:

- launches into useful cached content quickly;
- receives and identifies the latest Up Next generation;
- plays queue entries without all-library RSS work;
- reports every playback failure truthfully;
- uses native video playback interaction;
- remains responsive while sync applies;
- has bounded, measured memory use;
- preserves focus predictably through navigation and live updates;
- works from its cached projection without a currently online phone;
- communicates stale/offline/error states honestly;
- passes automated and physical-device release gates.
