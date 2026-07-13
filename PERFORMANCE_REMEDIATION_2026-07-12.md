# Overnight Performance Remediation — Final Resolution Ledger

## AI CONTEXT — Monday diagnostic follow-up (implemented 2026-07-13)

- Download stalls are confirmed against live URLSession task state, connectivity-wait state, and byte counters before cancellation. Suspended/waiting tasks hold their stall clock; out-of-process byte advances reset it. Confirmed stalls preserve resume data and use 30/60/120-second retries capped at three automatic attempts.
- Inactive background-audio feed polling is limited to one cycle per ten minutes and four feeds per cycle, without the visible-foreground active-window cap bypass.
- Decoded artwork memory is capped at 32 MB and purged with speculative prefetches on backgrounding, memory warning, or a ≥350 MB footprint. Paused AVAudioEngine graphs/files/buffers now receive the same background teardown as paused AVPlayer resources.
- BGAppRefreshTask has a 20-second cooperative deadline. It cancels and checkpoints unfinished feed candidates, completes the useful partial run successfully, and leaves the system expiration handler as a fallback.

> AI CONTEXT — This is the authoritative completion ledger for findings derived
> from `autohop-diagnostic-redacted (22).log`, Claude Fable's independent review,
> and the subsequent cross-repository audit completed 2026-07-12. Future AI models
> must verify current symbols before reopening an item. The iOS/tvOS app lives in
> this repository; the Worker lives in `../autohop-relay`.

## Completed repairs

1. **Worker `/v1/feeds` amplification and stale orphans:** full-set reconciliation
   diffs existing membership, batches D1 mutations, recomputes the union of added
   and removed feeds with set-oriented SQL, deletes true orphans, enforces body/set/
   delta limits, and returns authoritative membership plus revision and opaque IDs.
2. **Client membership storm and cancellation:** membership changes are detected by
   canonical feed-set comparison; ordinary changes use deltas; in-flight network work
   is separate from the cancellable debounce; acknowledged state is persisted; retry
   uses exponential backoff, jitter, server retry guidance, and circuit state.
3. **Targeted relay pushes:** opaque feed identities survive Worker coalescing through
   durable pending sets; the client refreshes only mapped subscriptions. Legacy pushes
   use a bounded due-only fallback that honors backoff.
4. **Silent-push contract:** a 20-second one-shot gate returns control to iOS exactly
   once without cancelling a refresh cycle owned by foreground/audio/BGTask work.
5. **BGProcessing frequency:** replacement scheduling occurs after outcome, with
   persisted earliest dates, 18/24-hour success cadence, exponential expiry retry,
   jitter, and pending-request protection.
6. **Playback tick persistence:** history updates batch over 10 seconds and flush at
   lifecycle/completion/merge boundaries; Stats retains per-tick numerical accuracy
   while coalescing UI publication and sync writes.
7. **Release Radar main-thread work:** profile fallback, prediction, scoring, fairness
   boost, and sorting operate on immutable snapshots at utility priority off-main.
8. **Backoff-aware wake selection:** effective feed due date is the later of Radar due
   and active failure backoff, preventing broken overdue feeds anchoring every wake.
9. **Logger and audio warning overhead:** logging formatting/redaction is off-caller,
   file size is tracked incrementally, viewer publication is coalesced, and normal
   one-buffer waits no longer emit stall warnings.
10. **Queue snapshot `recordNotFound`:** queued CloudKit record construction reads the
    authoritative current singleton rather than requiring it to remain pending.
11. **BGTask completion race:** refresh and processing tasks use a thread-safe one-shot
    gate so completion and expiration cannot both report terminal state.
12. **Relay entitlement verification:** Worker registration explicitly checks the
    verifier result's `ok` discriminant. Negating the diagnostic result object would
    be truthy and was a security bypass; this is corrected in `../autohop-relay/src/appstore.ts`.

## Findings resolved by upstream architectural changes

- The 573–781 MB relay-sweep spike was tied to the former unbounded full-library
  silent-push sweep. Protocol-v2 targeted refresh and the bounded legacy fallback
  remove that execution shape. Legitimate catch-up remains serial, limiting peak
  concurrent feed bodies, and resource snapshots remain available for confirmation.
- The observed relay 503 loop required both client and Worker changes; neither side
  alone was sufficient. Both sides are now implemented as described above.

## Validation contract

- iOS app and full test target must compile.
- tvOS target must compile.
- Worker must pass `npm run typecheck`.
- A future overnight diagnostic should show no full relay sweeps, no repeated
  `queue:current recordNotFound`, materially fewer history/stats/logger events,
  BGProcessing requests spaced by policy, and buffer warnings only above 250 ms.
