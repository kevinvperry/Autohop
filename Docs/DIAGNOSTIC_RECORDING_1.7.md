# Diagnostic recording — Version 1.7

AI CONTEXT: Diagnostic-only instrumentation. Do not change queue/sync/playback behaviour to make counters look healthy. Model row counts are not proof of playable or visible rows. Retain privacy redaction and bounded logs. Inspect separate source, resolution, presentation and playback events.

## Implemented

- Logger state summaries deduplicate identical values with a bounded event cache. Queue projection no longer force-logs every identical recomputation. Existing normal/detailed Radar and background/download events remain intact.
- Every log line carries a recording-session identity to separate launches across retained segments.
- Export header reports write failures and the last successful write, plus retention limits. Failures never recursively call the logger.
- iOS log reads and export processing run on utility tasks. Log reads are coalesced; stale export responses are rejected and export errors shown instead of silently offering an absent file.
- TV export records the current root/sync/queue/playable/unresolved/library/materialisation/playback/memory/thermal snapshot before stitching. Unresolved examples are capped at 20; they carry redacted identities and resolution clues.
- TV logs synced, cached and locally constructed queue paths separately. Current queue model counts and Home list changes distinguish resolved/playable state from fetch counts. Home appearance captures a fresh snapshot. These are view/model lifecycle observations, not pixel-visibility guarantees.
- TV status transitions record previous/current badge labels. This records transitions without changing the existing status policy.
- Sequential startup recovery records each attempted subscription, index/total, elapsed time and success, before CloudKit activation. This exposes the existing startup bottleneck rather than fixing it.
- TV playback command metadata includes AVPlayer time-control state, waiting reason, item state and item error, alongside episode identity and request generation.

## Interpretation for the current issue

Compare tv.recovery.itemStart/itemEnd with sync.engineActivated. Then compare tv.queueProjection source/entries/unresolved, tv.queueModel rows/playable and tv.home.queueVisible. Request an export while the problem is present; tv.diagnostics.snapshot provides the capture-time state. A completed fetch alone is not a healthy Up Next verdict.

## Existing coverage retained

Release Radar cycle/detailed traces, background schedule/launch/expiration/completion markers, download task reconnection and terminal file outcomes, CloudKit fetch-cycle identifiers and per-record failures, and playback persistence/recovery events continue using their existing identifiers. Recording-session identity groups them by process; there is no new universal transaction identifier across every subsystem.

## Limits and follow-up validation

Two size-capped log segments remain; this is not a guaranteed retention duration. Important/forced events still bypass routine backpressure. iOS share export and TV snapshot capture need physical-device checks. Buffering fields capture command-time state; they are not continuous AVPlayer access-log collection. Storage errors are observable but the underlying TV stats storage bug is not fixed here. Full task-to-episode causal tracing, automatic queue screenshots, universal scene presentation instrumentation and an incident pinning store are not implemented.

## Validation result

Final iOS test build and all nine LogRedactionTests passed, including new pre-export capture/change-deduplication coverage. Final tvOS simulator build succeeded. Whitespace checks passed. Physical Apple TV reproduction and visible Up Next verification remain required; no claim that the underlying incident is fixed.

## Diagnostic reliability repairs — 20 September 2026

<!-- AI CONTEXT — Keep this contract aligned with source headers and the repair record. -->

Playback resume retires stale buffer waits; Pause cancels pending recovery; EOF
uses consistent completion and render health reflects actual callbacks. Auto
Archive reads live pin IDs without repeated catalogue scans. Download completion
awaits ordered off-main stats-file persistence. First active-runtime fallback is
prompt; later retries stay bounded. Sync settings reactions are deduplicated,
foreign subscription identities remain protected, and diagnostic exports additionally
pseudonymise personal route names/arbitrary GUIDs. MetricKit disk-write reports now
carry byte counts and bounded stacks. Titles/timestamps remain diagnostic context.
See [implementation and validation](DIAGNOSTIC_REPAIRS_2026-09-20.md).
