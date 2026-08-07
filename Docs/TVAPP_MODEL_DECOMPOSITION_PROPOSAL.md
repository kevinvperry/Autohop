# Autohop tvOS `TVAppModel` Decomposition — Phased Proposal

<!--
AI CONTEXT — Docs/TVAPP_MODEL_DECOMPOSITION_PROPOSAL.md

PURPOSE: Canonical implementation plan for decomposing the oversized tvOS
TVAppModel currently located in TV/App/AutohopTVApp.swift. This is an
architecture-only proposal. Creating this document does not authorize or make
runtime changes.

STATUS: IMPLEMENTED IN CODE ON 2 AUGUST 2026. GENERIC tvOS/iOS BUILD AND
AUTOMATED TEST GATES ARE RECORDED IN VERSION_1.5.md; PHYSICAL APPLE TV
REGRESSION GATES REMAIN REQUIRED BEFORE RELEASE.

SCOPE: tvOS application code only. Do not alter iPhone UI, iPhone playback,
Release Radar, download policy, queue composition, or iPhone sync behaviour.
Shared code may be changed only when the change is platform-neutral, covered by
tests, and explicitly required by a later approved phase.

AUTHORITY: Private iCloud/CloudKit is Autohop's sole cross-device sync system.
The iPhone remains authoritative for subscriptions, priority order, settings,
and Up Next composition. Apple TV authors only its legitimate companion-device
events: playback position/state, listening history, additive listening stats,
and episode archive actions.

RELATED DOCUMENTS:
- Docs/TVOS_REBUILD_PROPOSAL.md — product and platform architecture.
- SYNC_DESIGN.md — cross-device authority and CloudKit behaviour.
- DESIGN.md — visual and interaction rules.
- VERSION_1.5.md — implementation record after each completed phase.

AI IMPLEMENTATION RULE: Move one coherent responsibility at a time. Preserve
behaviour first; optimise only after equivalence is demonstrated. Never perform
a large mechanical split followed by debugging multiple changed behaviours.
-->

## 1. Executive decision

`TVAppModel` should be decomposed incrementally, not rewritten.

The current implementation works as the tvOS composition root, but it also
contains application lifecycle, local-cache construction, CloudKit
coordination, first-sync presentation, subscription recovery, queue projection,
legacy queue enrichment, library projection, episode detail loading, playback
routing, archive write-back, history projection, diagnostics, and retry-task
ownership.

This concentration makes apparently small tvOS changes risky because:

- unrelated state changes can invalidate the same observable model;
- asynchronous task ownership and cancellation boundaries are difficult to see;
- queue, library, history, and playback policies can accidentally depend on
  mutable state owned by another concern;
- physical-device bugs are difficult to attribute to one subsystem;
- tests must construct or reason about the whole app model;
- a single file now contains about 1,405 lines, with `TVAppModel` occupying
  roughly 1,240 of them;
- future AI-assisted changes receive too much mixed context and can repair the
  wrong layer.

The desired end state is a small root composition model that creates focused
services, forwards lifecycle events, and publishes only root-level state.

## 2. Locked constraints

Every phase must obey these constraints.

1. **No iPhone behaviour changes.** The work is confined to the tvOS target and
   tvOS-specific tests unless a separately approved shared-code change is
   unavoidable.
2. **No sync-authority changes.** iPhone remains the author of subscriptions,
   settings, priority order, and Up Next.
3. **No schema migration by accident.** Moving ownership must not rename
   CloudKit fields, GRDB tables, record types, persistence keys, queue keys, or
   history identities.
4. **No identity simplification.** GUID, enclosure URL, subscription identity,
   legacy queue keys, and title-based compatibility matching retain their
   current tested precedence.
5. **No playback-engine duplication.** `StreamingPlaybackEngine` and
   `TVPlaybackModel` remain the playback owners. Extracted components must not
   create a second AVPlayer state machine.
6. **No second source of observable truth.** Each user-visible value has one
   owner. The root may expose a read-only facade, but must not maintain competing
   copies without an explicit projection boundary.
7. **Preserve diagnostics.** Existing event names and metadata remain stable
   during moves. New ownership fields may be added.
8. **One extraction per commit.** Each phase should be independently buildable,
   testable, reviewable, and revertible.
9. **Physical Apple TV gates remain mandatory.** Simulator/unit success does
   not prove focus, video presentation, CloudKit timing, or Siri Remote response.
10. **Update documentation continuously.** Completed work is recorded in
    `VERSION_1.5.md` and any affected canonical architecture document.

## 3. Current responsibility map

### 3.1 Root application and lifecycle

Current owner: `TV/App/AutohopTVApp.swift`

- delayed creation of `TVAppModel` so the launch animation can render;
- scene-phase forwarding;
- background playback checkpoint;
- artwork trimming;
- foreground CloudKit priming.

This shell is appropriate and should remain small.

### 3.2 Composition and persisted dependencies

Current owner: `TVAppModel.init()`

- logging and hang-watchdog startup;
- cache-directory creation;
- `SubscriptionStore` construction;
- `TVProjectionStore` construction;
- `ListeningStatsStore` construction;
- `TVPlaybackModel` construction and callback wiring;
- cached library projection restoration;
- global weak model registration.

This should become a dedicated composition factory so tests can inject stores,
clocks, network loaders, and sync engines.

### 3.3 Bootstrap and first-sync experience

Current owner: `TVAppModel.bootstrap()` plus first-sync message methods.

- deferred database load;
- cache repair and survival-kit restoration;
- CloudKit startup;
- first-sync wait messaging;
- initial materialisation and library refresh;
- root loading/ready/empty state.

This is a coherent workflow and a high-value early extraction.

### 3.4 CloudKit and foreground freshness

Current owner: `startCloudSync()`, `primeLibraryFromCloudSoon`, foreground
polling, recent-history priming, remote callbacks, and sync status.

The existing `TVForegroundSyncCoordinator` and `TVForegroundSyncPolicy` are
useful foundations, but the root still owns too much orchestration and task
state.

### 3.5 Subscription recovery/materialisation

Current owner: survival-kit methods, targeted RSS materialisation, retry tasks,
remote subscription materialisation, and pending-materialisation diagnostics.

This is a separate bounded recovery subsystem. It must never become a broad
all-library feed refresh engine.

### 3.6 Library projection and episode details

Current owner: `refreshLibrary`, indexes, tiles, episode rows, targeted detail
loads, projection persistence, refresh debounce, and root-state derivation.

These responsibilities should be split into a library repository/projection
model and a targeted episode-detail loader.

### 3.7 Up Next projection and legacy enrichment

Current owner: queue snapshot resolution, cached snapshot fallback, local
archive suppression, legacy episode recovery indexes, bounded feed enrichment,
retry ownership, row diagnostics, and queue display projection.

This is the most identity-sensitive extraction and should occur only after
dependency injection and characterization tests are established.

### 3.8 Continue Listening/history projection

Current owner: history cache invalidation, most-recent-entry lookup, local
episode resolution, and `TVContinueListening` projection.

This can become a small read model driven by history-change and
library-resolution inputs.

### 3.9 Playback commands and companion write-back

Current owner: begin playback, archive episode, subscription lookup, checkpoint
flush, and callbacks to `TVPlaybackModel`/CloudKit.

Playback state remains in `TVPlaybackModel`. The root should eventually call a
small coordinator that resolves an episode request and performs companion
write-back without owning AVPlayer internals.

## 4. Target architecture

```text
AutohopTVApp
└── TVAppModel                         @MainActor root facade
    ├── TVAppDependencies              immutable dependency container
    ├── TVBootstrapCoordinator         launch and root-state workflow
    ├── TVSyncCoordinator              CloudKit lifecycle/freshness/status
    ├── TVMaterializationCoordinator   survival-kit and bounded RSS recovery
    ├── TVLibraryModel                 library/read-only detail projections
    ├── TVQueueModel                   Up Next and legacy-row enrichment
    ├── TVContinueListeningModel       synced history projection
    ├── TVPlaybackCoordinator          request resolution/checkpoint/archive
    └── TVPlaybackModel                existing AVPlayer-facing model
```

Supporting repository boundaries:

```text
TVProjectionStore (existing GRDB cache)
├── queue projections
├── library projections
└── bounded episode-detail projections

SubscriptionStore (existing shared persistence surface)
├── synced subscriptions/settings/history
├── synced phone-authored queue snapshot
└── companion archive/history/stat writes
```

### 4.1 Final `TVAppModel` contract

The final root should ideally own fewer than 250 lines and expose:

- `rootState`, `statusText`, and high-level `syncStatus`;
- references to the focused observable child models needed by views;
- `bootstrap()`, `sceneBecameActive()`, and `sceneBecameInactive()`;
- narrow routing methods retained temporarily for source compatibility.

It should not directly:

- fetch or parse RSS;
- manage per-feed retry dictionaries;
- query/decode history tables;
- calculate queue identity matches;
- create CloudKit engines;
- rebuild library indexes;
- own AVPlayer state;
- perform GRDB projection reads/writes;
- expose the complete `SubscriptionStore` to every view.

## 5. State and concurrency rules

### 5.1 Observable ownership

Use focused `@MainActor @Observable` models for UI-facing immutable projections:

- `TVLibraryModel`
- `TVQueueModel`
- `TVContinueListeningModel`
- existing `TVPlaybackModel`
- a small sync-status surface from `TVSyncCoordinator`

Views observe only the model relevant to that page. A queue change must not
force Library or player controls to recalculate.

### 5.2 Service ownership

Network, database, decoding, sorting, and recovery work should live in focused
services/coordinators. Their heavy work runs off-main where the existing store
APIs permit it; they publish one compact result on the main actor.

### 5.3 Task ownership

Every long-lived `Task` must have:

- exactly one owning component;
- a stable semantic key where work is per subscription/episode;
- cancellation on replacement or coordinator teardown;
- generation checks before publishing results;
- explicit logs for start, completion, cancellation, timeout, and failure.

No extracted component may reach into another component's task dictionary.

### 5.4 Dependency direction

Allowed:

```text
View → focused model → coordinator/repository → store/network
Root → all child components
Playback coordinator → TVPlaybackModel
Queue/History models → TVEpisodeResolver
```

Disallowed:

```text
Repository → View
Queue model ↔ Library model circular ownership
TVPlaybackModel → TVAppModel
Store callback → broad root refresh without a domain-specific event
```

## 6. Phased implementation

## Phase 0 — Freeze behaviour and establish measurement

### Objective

Create a trustworthy baseline before moving code.

### Work

1. Record current line count, launch timing, first cached render, first CloudKit
   refresh, queue projection duration, library refresh duration, focus response,
   and idle memory on physical Apple TV.
2. Inventory every view access to `TVAppModel` and classify it as lifecycle,
   sync, library, queue, history, playback, archive, or diagnostics.
3. Add characterization tests around existing public behaviour without changing
   implementation.
4. Record stable diagnostic event names that must survive extraction.
5. Confirm the current safety commit and clean working tree before Phase 1.

### Required characterization tests

- cached projection produces `.ready` without waiting for CloudKit;
- empty cache remains loading until bootstrap determines ready/empty;
- phone-authored queue order is preserved exactly;
- current playing episode is suppressed from Up Next only under existing rules;
- legacy video identity retains media kind, speed, and resume position;
- archive action writes the companion episode state and hides the stale row;
- history invalidation updates Continue Listening once;
- foreground poll deduplicates concurrent history/queue work;
- targeted episode details never trigger an all-library feed sweep.

### Exit gate

All baseline tests pass against the un-decomposed model. No product behaviour is
changed in this phase.

## Phase 1 — Extract dependency construction

### Objective

Make the model testable without changing ownership or behaviour.

### New files

- `TV/App/TVAppDependencies.swift`
- `TV/App/TVAppEnvironment.swift` (only if clock/file-system/network factories
  need a clear protocol boundary)

### Work

1. Move cache-path construction and store/model creation out of
   `TVAppModel.init()` into a production dependency factory.
2. Add an internal initializer accepting dependencies.
3. Keep logging and lifecycle registration in a small explicit startup seam.
4. Inject clock, feed loader, survival-kit store, projection store, and CloudKit
   engine factory where practical.
5. Preserve the existing production initializer as a convenience wrapper.

### Tests

- dependencies use Caches rather than Documents for rebuildable tvOS data;
- playback/stats stores share the correct sync database;
- cached library projection restores before network work;
- test construction performs no real network or CloudKit activity.

### Exit gate

Both tvOS build configurations pass. Physical launch is visually and
diagnostically equivalent to baseline.

## Phase 2 — Extract bootstrap workflow

### Objective

Remove launch sequencing and first-sync presentation from the root.

### New file

- `TV/App/TVBootstrapCoordinator.swift`

### Ownership moved

- deferred store loading;
- cache cleanup/migration flags;
- CloudKit startup hand-off;
- survival-kit rebuild request;
- animated first-sync status sequence;
- initial ready/empty decision;
- bootstrap generation/cancellation.

### Root interaction

The coordinator publishes a compact `TVBootstrapState`:

```swift
enum TVBootstrapState: Equatable {
    case loading(message: String)
    case ready
    case empty
    case recoverableFailure(message: String)
}
```

`TVAppModel` maps this to its existing root state during migration.

### Exit gate

Cold install, warm launch, offline launch with cache, and empty-library launch
all match baseline. Launch animation remains fluid on device.

## Phase 3 — Extract sync coordination

### Objective

Give CloudKit lifecycle, remote callbacks, freshness polling, and sync status
one owner.

### New/changed files

- `TV/Sync/TVSyncCoordinator.swift`
- retain and integrate `TVForegroundSyncCoordinator.swift`
- retain `TVForegroundSyncPolicy.swift`

### Ownership moved

- `CloudSyncEngine` creation and callbacks;
- queue/history/subscription foreground fetch policy;
- recent-history task sharing;
- last-prime timestamps;
- scene-active polling;
- flush requests after playback/archive checkpoints;
- `TVSyncStatus` publication;
- domain-specific invalidation events.

### Event contract

Prefer typed events instead of a broad refresh closure:

```swift
enum TVSyncChange: Sendable {
    case subscriptions
    case queue(generation: Int64?)
    case history
    case episodeState
    case statistics
}
```

### Important guardrail

The coordinator does not build display models. It reports what changed; the
relevant projection owner decides what to recompute.

### Exit gate

Archive and playback-position changes reach iPhone as before. Foreground
updates remain deduplicated. Queue/history fetch counts do not increase.

## Phase 4 — Extract materialisation and survival recovery

### Objective

Isolate bounded compatibility recovery from normal library display.

### New file

- `TV/Recovery/TVMaterializationCoordinator.swift`

### Ownership moved

- survival-kit capture/load/update;
- missing-subscription detection;
- targeted RSS materialisation;
- durable retry scheduling/backoff;
- remote subscription materialisation;
- pending-materialisation diagnostics.

### Required API shape

```swift
protocol TVMaterializing: AnyObject {
    func rebuildMissingSubscriptions() async
    func materializeRemoteSubscription(_ state: SubscriptionSyncState) async
    func retryPendingNow()
    var pendingDiagnostics: [String] { get }
}
```

The exact protocol may evolve, but callers must not receive or mutate retry
dictionaries.

### Exit gate

Legacy/missing subscriptions recover after cold install and transient failure.
No broad library sweep is introduced. Relaunch reconstructs durable retry work.

## Phase 5 — Extract library projection and episode details

### Objective

Make Library a focused observable read model.

### New files

- `TV/Library/TVLibraryModel.swift`
- `TV/Library/TVLibraryProjector.swift`
- `TV/Library/TVEpisodeDetailRepository.swift`

### Ownership moved

- library subscriptions and O(1) subscription index;
- library tiles;
- refresh debounce and performance timing;
- cached library projection persistence;
- per-subscription episode rows;
- targeted detail-load task/cancellation;
- detail-load status and diagnostics.

### View migration

Migrate `TVLibraryView` and `TVEpisodeListView` to `TVLibraryModel` directly.
Keep temporary forwarding properties on `TVAppModel` until both views compile
and tests pass, then remove them.

### Exit gate

Library navigation, focused artwork, targeted detail loading, archive actions,
and cold-cache restoration pass on device. Queue and playback behaviour are
unchanged.

## Phase 6 — Extract queue projection and legacy enrichment

### Objective

Move the most identity-sensitive subsystem behind a tested queue model.

### New files

- `TV/Queue/TVQueueModel.swift`
- `TV/Queue/TVQueueProjector.swift`
- `TV/Queue/TVLegacyQueueEnrichmentCoordinator.swift`

### Ownership moved

- synced queue snapshot resolution;
- cached snapshot fallback;
- queue rows and resolved items;
- local suppression after archive;
- orphan-recovery indexes;
- GUID/title compatibility recovery;
- bounded legacy feed enrichment and retry tasks;
- unresolved-row diagnostics.

### Identity rule

`TVEpisodeResolver` remains the single compatibility boundary. Do not copy its
matching logic into the projector or enrichment coordinator.

### View migration

Migrate Home's Up Next presentation to `TVQueueModel`. The temporary dedicated
`TVQueueView` was subsequently retired on 2 August 2026 when Home adopted the
complete full-width queue list as the sole tvOS Up Next surface.

### Exit gate

- phone queue order and generations remain exact;
- unresolved rows remain visible and truthful;
- legacy rows become playable when their bounded source arrives;
- Windows Weekly audio/video identities do not cross-match;
- archive suppression survives a stale incoming queue snapshot;
- no queue mutation causes a full library refresh.

## Phase 7 — Extract Continue Listening/history projection

### Objective

Make history invalidation and resume display independent of queue/library UI
updates.

### New files

- `TV/History/TVContinueListeningModel.swift`
- `TV/History/TVContinueListeningProjector.swift`

### Ownership moved

- cached most-recent in-progress history entry;
- history invalidation flag/generation;
- local episode resolution for playability;
- Continue Listening display projection.

### Exit gate

The hero updates after phone and TV playback changes without broad root
invalidation. Current active playback is not duplicated in Continue Listening
under the existing product rule.

## Phase 8 — Extract playback routing and companion actions

### Objective

Separate playback request resolution and tvOS-authored state changes from the
root while retaining the existing playback engine/model.

### New file

- `TV/Playback/TVPlaybackCoordinator.swift`

### Ownership moved

- authoritative history selection for a playback request;
- `TVEpisodeResolver.playbackResolution` invocation;
- begin/resume routing into `TVPlaybackModel`;
- archive-current-episode stop behaviour;
- companion archive write-back;
- checkpoint-triggered CloudKit flush request;
- subscription lookup needed by playback preferences.

### Non-goal

Do not move AVPlayer observation, player generation, media probing, speed
application, position timers, Now Playing information, or chapter behaviour out
of `TVPlaybackModel`/`StreamingPlaybackEngine` during this phase.

### Exit gate

Audio/video playback, resume position, speed inheritance, pause/resume speed,
archive-current, Stats accounting, and position sync all pass device tests.

## Phase 9 — Reduce the root and migrate diagnostics

### Objective

Finish the decomposition and remove compatibility forwarding.

### Work

1. Delete forwarding properties/methods after every view uses its focused model.
2. Move subsystem diagnostics to their actual owners.
3. Make `TVDiagnosticsView` consume a read-only aggregated diagnostics snapshot,
   not the internals of every coordinator.
4. Reduce `TVAppModel` to composition, root state, lifecycle forwarding, and
   navigation-level coordination.
5. Move `TVRootView` into `TV/Views/TVRootView.swift` and leave
   `AutohopTVApp.swift` as the application entry point only.
6. Enforce target file-size guidance:
   - root model: preferably under 250 lines;
   - coordinators/models: preferably under 400 lines;
   - split policy/repository code when a file exceeds one coherent concern.

### Exit gate

No view accesses `SubscriptionStore` through the root merely for convenience.
No extracted subsystem depends back on `TVAppModel`. Full tvOS regression suite
and physical-device checklist pass.

## Phase 10 — Measure, optimise, and close

### Objective

Confirm decomposition produced clearer ownership without introducing overhead.

### Compare against Phase 0

- time to first cached Home render;
- time to first current CloudKit projection;
- main-thread stalls over 100/350 ms;
- Siri Remote focus response and missed/double moves;
- queue/library projection durations;
- CloudKit fetch/write counts;
- RSS requests and concurrent enrichment count;
- idle and playback memory;
- video startup and resume latency;
- position/archive propagation time to iPhone.

Optimise only measured regressions. Decomposition alone is not evidence of a
performance improvement.

### Exit gate

Results and device coverage are recorded in `VERSION_1.5.md`; canonical tvOS
architecture documents reflect the implemented file/ownership map.

## 7. Proposed file structure

```text
TV/
├── App/
│   ├── AutohopTVApp.swift
│   ├── TVAppModel.swift
│   ├── TVAppDependencies.swift
│   └── TVBootstrapCoordinator.swift
├── Sync/
│   ├── TVSyncCoordinator.swift
│   ├── TVForegroundSyncCoordinator.swift
│   └── TVForegroundSyncPolicy.swift
├── Recovery/
│   └── TVMaterializationCoordinator.swift
├── Library/
│   ├── TVLibraryModel.swift
│   ├── TVLibraryProjector.swift
│   └── TVEpisodeDetailRepository.swift
├── Queue/
│   ├── TVQueueModel.swift
│   ├── TVQueueProjector.swift
│   └── TVLegacyQueueEnrichmentCoordinator.swift
├── History/
│   ├── TVContinueListeningModel.swift
│   └── TVContinueListeningProjector.swift
├── Playback/
│   ├── TVPlaybackCoordinator.swift
│   ├── TVPlaybackModel.swift
│   └── existing playback policies/probes
├── Resolution/
│   └── TVEpisodeResolver.swift
├── Diagnostics/
│   └── existing diagnostics plus snapshot adapter
├── Models/
│   └── TVDisplayModels.swift
└── Views/
    ├── TVRootView.swift
    └── existing focused views
```

Names may be refined during implementation, but responsibility boundaries must
remain stable.

## 8. Migration technique

Use a strangler-style extraction for every phase:

1. Add characterization tests around current behaviour.
2. Introduce the new component with injected inputs.
3. Move unchanged logic into it.
4. Keep a temporary forwarding API on `TVAppModel`.
5. Run unit tests and both generic-platform builds.
6. Migrate one view/caller at a time.
7. Run physical Apple TV scenarios.
8. Remove the forwarding API and dead state.
9. Commit the phase independently.
10. Update `VERSION_1.5.md`.

Do not combine extraction with visual redesign, CloudKit schema changes,
playback-engine changes, or policy retuning in the same commit.

## 9. Testing strategy

### 9.1 Unit tests

Each extracted component receives direct tests with fakes for time, stores,
network, CloudKit, and projection persistence where applicable.

Priority suites:

- bootstrap state transitions and cancellation;
- sync event routing and freshness deduplication;
- materialisation retry/backoff and relaunch recovery;
- queue generation/order and legacy identity recovery;
- library projection equality/invalidation;
- history cache invalidation;
- playback request resolution;
- archive/checkpoint write-back;
- task-generation stale-result suppression.

### 9.2 Integration tests

- cached DB + delayed CloudKit;
- empty DB + current CloudKit;
- offline launch + cached projections;
- old queue schema + missing subscription projection;
- active playback while queue/history updates arrive;
- archive on TV followed by stale phone-authored queue;
- large library with bounded targeted episode detail request;
- video history record with legacy/ambiguous media metadata.

### 9.3 Physical-device matrix

At minimum, test:

- cold launch and warm launch;
- first install and existing cache;
- online and temporarily offline;
- audio and video playback;
- return from full-screen video;
- pause/resume and speed persistence;
- Home/Up Next/Library focus during sync changes;
- playback position TV → iPhone and iPhone → TV;
- archive TV → iPhone;
- Stats contribution from TV;
- memory warning and app background/foreground;
- diagnostic export.

## 10. Diagnostics requirements

Each component should log a consistent ownership field:

```text
component=bootstrap|sync|materialization|library|queue|history|playback
generation=<task or projection generation>
reason=<launch|foreground|remoteChange|userAction|retry>
durationMs=<measured wall time>
result=<completed|cancelled|failed|skipped>
```

Preserve current event keys during extraction so before/after logs remain
comparable. Add new keys only when they expose a previously invisible boundary.

The diagnostic snapshot should report:

- current owner/generation for active tasks;
- current queue generation and unresolved count;
- library projection count and age;
- history projection age;
- pending materialisation/enrichment counts;
- CloudKit last fetch/push outcomes;
- current playback identity/state/position/speed/media kind.

## 11. Risks and mitigations

### Risk: duplicate observable state

**Mitigation:** one owner per value; temporary root forwarding must be computed or
read-only and deleted in the phase that migrates its final caller.

### Risk: stale async result overwrites newer state

**Mitigation:** generation tokens and cancellation checks at every publication
boundary.

### Risk: identity behaviour changes during queue extraction

**Mitigation:** retain `TVEpisodeResolver` as the sole compatibility boundary and
land characterization tests before Phase 6.

### Risk: increased CloudKit or RSS traffic

**Mitigation:** record baseline counts; sync coordinator owns deduplication;
materialisation/detail loaders remain targeted and bounded.

### Risk: actor hopping makes UI slower

**Mitigation:** measure rather than assume; publish compact immutable projections
once per domain change.

### Risk: extraction destabilises working playback

**Mitigation:** playback extraction occurs late; do not change AVPlayer ownership
or playback policy in the same phase.

### Risk: temporary facade becomes permanent

**Mitigation:** each forwarding API is tagged with its removal phase and is an
exit-gate failure if callers remain.

## 12. Recommended implementation order

The phases should be implemented in the documented order. In particular:

1. Establish tests and dependency injection before moving identity-sensitive
   code.
2. Extract bootstrap and sync before page projections because these provide
   domain-specific invalidation signals.
3. Extract recovery before queue so legacy feed work has a clear owner.
4. Extract Library before Queue because queue resolution consumes the library
   index, not the reverse.
5. Extract playback routing only after queue/history/library inputs have stable
   interfaces.
6. Remove the root facade only after all views have migrated.

The first implementation milestone should therefore be **Phase 0 and Phase 1
only**. That creates safety and testability while minimizing behavioural risk.

## 13. Definition of complete

The decomposition is complete only when:

- `TVAppModel` is a small composition/lifecycle facade;
- each async task has one obvious owner;
- views observe focused page models rather than the entire application model;
- queue, library, history, sync, recovery, and playback routing have independent
  tests;
- no iPhone behaviour or sync authority changed;
- CloudKit/RSS traffic did not increase unexpectedly;
- physical Apple TV playback, focus, sync, archive, and Stats scenarios pass;
- documentation matches the implemented architecture;
- each phase is preserved in Git history as a separately revertible commit.

## 14. Implementation record — 2 August 2026

The approved decomposition has been implemented with behaviour-preserving
extensions and focused ownership components:

- `AutohopTVApp.swift` now contains only application construction/lifecycle;
- `TVAppModel.swift` is a 249-line composition facade;
- bootstrap, sync, recovery, Library, Queue, history, playback, and diagnostics
  are physically separated by subsystem;
- `TVAppDependencies` provides the production/test construction seam;
- dedicated bootstrap, sync, materialisation, and queue-enrichment coordinators
  own their task/state domains;
- `TVLibraryModel`, `TVQueueModel`, and `TVContinueListeningModel` are focused
  observable state owners consumed directly by their views;
- pure Library/Queue/Continue Listening projectors and a bounded episode-detail
  repository isolate display and network boundaries;
- `TVPlaybackCoordinator` owns request resolution and companion write-back while
  the existing playback model/engine remain the sole AVPlayer state machine;
- `TVRootView` and diagnostic aggregation moved out of the app/model files;
- tvOS architecture regression tests cover focused state and projection order.

The extraction intentionally retains narrow forwarding methods where existing
views need user actions (`beginPlayback`, `archiveEpisode`, targeted legacy
enrichment). Policy and task ownership now sits behind those facades.
