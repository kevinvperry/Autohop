> **SUPERSEDED — historical record only.** Current canonical assessment: `ASSESSMENT_2026-08-30.md`. Do not cite figures from this file as current.

# AppState Decomposition Characterization Baseline

<!--
AI CONTEXT — APPSTATE_DECOMPOSITION_BASELINE.md

PURPOSE:
Stage 0 execution record for APPSTATE_DECOMPOSITION_PROPOSAL.md. This document
freezes the source/build/test/diagnostic evidence that Stages 1–2 must preserve.
It is a regression baseline, not a redesign specification and not evidence that
every existing behavior is ideal.

AUTHORITY:
- APPSTATE_DECOMPOSITION_PROPOSAL.md owns migration order and target ownership.
- FEATURES.md owns user-visible behavior.
- SYNC_DESIGN.md owns CloudKit behavior.
- This file owns the pre-coordinator characterization evidence and device-only
  validation boundary.

RULE FOR FUTURE AI MODELS:
Before Stage 3 or any later ownership transfer, rerun the automated suites and
add direct tests for that stage's affected workflows. A diagnostic-log trace may
characterize an OS-integrated behavior for Stages 1–2, but it must not replace a
deterministic coordinator test once that behavior is moved.
-->

## 1. Frozen source state

- Baseline recorded: 18 July 2026, Australia/Melbourne.
- Task-entry branch: `main`.
- Task-entry revision: `d95f29ab4b81b9609ac4f565260d253c4c08e3a0`.
- Task-entry working tree: no unrelated edits were detected; the later dirty
  paths are the Stage 0–2 implementation itself.
- Proposal review snapshot: `d8e0320488e4`, recorded in the proposal on
  17 July 2026.
- AppState at implementation review: 6,645 lines before Stage 2 physical moves.
- AppState after Stages 1–2: approximately 6,250 lines. The reduction is a
  consequence of moving existing leaf types, not an acceptance metric.
- Persisted formats changed: none.
- CloudKit record schemas changed: none.
- User-visible features/settings changed: none.

## 2. Harness contract

The Stage 0 application harness is the combination of:

- protocol-backed dependencies already accepted by `AppState.init`;
- `AppCompositionRoot.Dependencies`, which holds the complete injected graph
  formerly constructed inside `AppState.bootstrap`;
- `AppCompositionRoot.makeAppState()`, which constructs but does not start;
- `AppState.bootstrap(compositionRoot:startRuntime:)`, which permits a
  constructed singleton in tests without launching OS-owned services;
- DEBUG-only startup guard and singleton reset seams used by the Xcode tests.

The harness proves these invariants:

1. Supplied dependency identities reach AppState unchanged.
2. Construction leaves startup state at `constructed`.
3. Construction does not install playback/download runtime callbacks.
4. Phone and CarPlay entry paths resolve the same process instance.
5. A second startup attempt cannot install a second long-lived runtime graph.

The harness is not a service locator. Production code uses
`AppCompositionRoot.production()`; coordinators added in later stages must
receive narrow dependencies explicitly.

## 3. Automated characterization map

The following table maps the proposal's minimum suite to executable evidence
that existed or was added before structural ownership moved.

| Workflow contract | Automated evidence | Additional runtime evidence |
|---|---|---|
| Start at zero, start trim, partial resume | `PlaybackSessionPolicyTests` start/resume cases; `CarPlayBehaviorTests.testCarPlayColdLaunchResumesRestoredEpisode` | `player.start` logs include zero and non-zero resumes |
| Seek while playing and continuing clock | `PlaybackSessionPolicyTests.testOrdinarySeekDoesNotCompleteEpisode`; `AppStateLeafExtractionTests.testPlaybackClockRetainsCurrentTimeProjection` | `playback.seek` followed by `playback.tickSummary` |
| Forward skip crossing EOF | `PlaybackSessionPolicyTests.testForwardSkipCrossingEndIsCompletionAndCreditsOnlyRemainingTime` | Completion traces use the same boundary policy |
| Natural completion | `TVListeningHistoryWriteBackTests.testMarkListeningHistoryFinishedSetsPlayedStatusAndCompletionKind`; queue advance coverage in `CarPlayBehaviorTests` | `player.finished`, `playback.finished`, and `engine.readEOF` |
| Remote Next | `CarPlayBehaviorTests` action-routing and archive/advance cases; `PlaybackSessionPolicyTests` completion boundary | Now Playing command remains installed by AppState start |
| Chapter live filter/navigation | `PlaybackSessionPolicyTests` chapter navigation, filtered-current, and edge cases | Chapter callbacks remain on the existing engine/store path |
| Play Instant queue/warning/return/cancellation rules | Codable default/backward-compatibility in `AppSettingsDefaultsTests`; cue binary contract in `AppStateLeafExtractionTests` | `playInstant.queued`, `.warning`, `.started`, and `.restoring` sequence in the diagnostic baseline |
| Queue order, Play Next/Last, unpin/persistence, Up Next | `QueueModelTests`, `QueueSnapshotSyncTests`, and `CarPlayBehaviorTests` | `queue.upNextRefresh` identity-change diagnostics |
| Queue snapshot only on composition change | `QueueSnapshotSyncTests.testUpdateLocalQueueSnapshotDedupesUnchangedEntries` | `sync.queued` queue counts |
| Manual/queued/CarPlay/automatic/background downloads | `CarPlayBehaviorTests`, `AutoDownloadIntentStoreTests`, `DownloadResponseValidationTests` | `download.start`, `.progress`, `.taskComplete`, `.complete`, `.backgroundWake` |
| Watchdog retry/exhaustion | Download validation tests protect terminal classification inputs | `download.watchdogRetryScheduled`, `.watchdogRetry`, `.watchdogRetryExhausted` |
| Conditional HTTP 304 | `HTTPResponseValidationTests.testSuccessAndNotModifiedPass` | `feed.notModified` |
| Updated merge and durable intent ordering | `FeedRefreshMergeTests` plus `AutoDownloadIntentStoreTests` | `feed.refreshMerge` then `.autoDownloadScheduled`/intent diagnostics |
| Browse-preview exclusion | `CarPlayBehaviorTests.testSubscriptionProjectionExcludesBrowsePreviews`; `SubscriptionSurvivalKitTests.testCaptureExcludesBrowsePreviewsAndOrdersByRank` | `feed.refreshAll.skippedInactive` |
| Refresh cancellation/backlog restoration | `ReleaseRadarSchedulingTests` budget/fairness policies | `feed.refreshAll.cancelled` includes unfinished and deferred-backlog counts |
| Background-audio refresh budget | `ReleaseRadarSchedulingTests.testUrgentWindowBypassStopsAtHardMaximum` and protected-budget tests | execution context is logged as `backgroundAudioAlive` |
| Three Auto Archive rules and zero-result explanation | `AppSettingsDefaultsTests` persistence/default contracts; completion repair tests | `autoArchive.played`, `.inactive`, `.inlineLimit`, `.start`, `.skip`, `.finished` |
| Preserve completed history through Auto Archive | `ListeningHistoryCompletionRepairTests` | `history.autoArchivePreservedCompletion` |
| Local-save-before-sync checkpoint | `StatsWriteCoalescingTests` save flush and `SyncPushCoalescingTests.testLifecycleFlushNeverDefers` | scene phase/checkpoint diagnostics |
| Remote materialization and rank preservation | `MaterializeSettingsPreservationTests`, `SubscriptionSurvivalKitTests`, `SubscriptionSyncTests` | `sync.materializeFailed` is the failure sentinel |
| Onboarding browse exclusion/first subscription | Browse exclusion tests plus `realSubscriptionCount` production contract | launch reconciliation diagnostics |
| OPML partial failure/progress cleanup | `OPMLSmoke` parser/import smoke suite | AppState retains `defer { opmlImportProgress = nil }` and per-feed failure summary |
| Stage 1 construction and singleton/start guard | Three decomposition tests in `CarPlayBehaviorTests` | `app.startSkipped` identifies rejected duplicate starts |
| Stage 2 narrow observables and cue format | `AppStateLeafExtractionTests` | No runtime behavior change |
| Listening-history/CloudKit persistence compatibility | `HistorySyncTests`, `TVListeningHistoryWriteBackTests`, legacy Codable repair tests | Existing `listening-history.json` path and schema retained verbatim |

Some rows intentionally combine a pure-policy test with a production diagnostic
trace because the OS surface cannot be driven reliably in the shared headless
suite. This is sufficient for the no-behavior-change composition and physical
move in Stages 1–2. It is not sufficient to move the relevant ownership later:
the destination coordinator must receive a direct fake-backed test first.

## 4. Representative diagnostic baseline

Source: the latest supplied diagnostic file at implementation time,
`autohop-diagnostic-redacted (23).log`.

- Capture window: 14 July 2026 07:17 UTC through 15 July 2026 07:05 UTC.
- Size: approximately 6.6 MB.
- Device class: iPhone15,3; 108 subscriptions during representative launches.
- Launches: 12 `app.bootstrapTiming` samples.
- Synchronous bootstrap total: 801.3–3,525.9 ms.
- Playback starts: 57 `player.start` events.
- Playback tick summaries: 522; ordinary early examples averaged 2.2–2.7 ms
  with no samples above the then-current 120 ms slow threshold.
- Completed refresh cycles: 137.
- Cancelled refresh cycles with backlog restoration: 6.
- Conditional 304 outcomes: 433.
- Downloads started: 98; completed: 79.
- Scene phase transitions: 249.
- BGAppRefresh completions: 15, 3,303–13,283 ms, average approximately
  7,921 ms.
- Auto Archive: 32 starts and 32 completions, including played, inactive,
  episode-limit, and zero-result passes.
- Play Instant: one complete queued → warning → started → restored sequence.

The same capture contains known watchdog-exhaustion noise and extreme outliers
that were repaired after the capture. Those values are not performance targets.
For decomposition, the baseline contract is event sequencing, metadata presence,
and workflow continuity. A fresh post-refactor overnight log is required before
using timing/resource numbers as a performance acceptance decision.

## 5. Device-only validation boundary

The following scenarios require Apple runtime services, real scheduling, or
hardware and therefore remain manual/device integration gates:

- simultaneous real phone scene and CarPlay cold launch;
- CarPlay template lifecycle and remote command delivery;
- background URLSession process relaunch and completion handler timing;
- BGAppRefreshTask/BGProcessingTask scheduling, expiration, and suspension;
- AVAudioSession interruptions, Bluetooth/AirPods route loss, and route restore;
- lock-screen Now Playing ownership and scrubbing;
- CloudKit account changes, push delivery, and remote materialization over the
  production container;
- notification authorization and Still Listening actions;
- memory/resource behavior during an 80-feed refresh;
- Play Instant warning audibility and restoration across a real audio route;
- OPML import UI progress under mixed live network failures.

Stages 1–2 do not change the implementations behind these surfaces. Before
shipping a build containing later coordinator extraction, run this list on a
physical iPhone and the CarPlay simulator/hardware as applicable.

## 6. Stage 0 gate result

Stage 0 is complete for the approved Stage 1 composition change and Stage 2
physical leaf moves:

- task-entry revision and tree state recorded;
- representative diagnostic contract recorded;
- shared suite passes;
- injected construction/singleton/start guard coverage added;
- physically moved leaf contracts covered;
- device-only scope separated explicitly;
- no behavior, persistence, or schema redesign introduced.

This gate does not authorize Stage 3 automatically. Stage 3 must add direct
HistoryStatsCoordinator workflow tests for any contracts that currently rely on
runtime traces before moving their ownership.
