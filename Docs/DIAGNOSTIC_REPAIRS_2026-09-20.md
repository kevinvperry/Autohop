# Diagnostic repairs — 20 September 2026

<!-- AI CONTEXT — Implementation record for the supplied diagnostic-log investigation.
Preserve user intent, download durability, pin protection, EOF audio and redaction.
This work does not establish that iOS 27 caused every original incident. Do not
claim the historical disk-write exception is attributed or Bluetooth verified. -->

## Implemented repairs

| Area | Change and invariant |
| --- | --- |
| Resume/buffer timeout | Stop the old producer/node and invalidate its generation before engine restart; resume uses a fresh semaphore/read loop at the paused media position. Old paused deadlines cannot request recovery for the new generation. |
| Recovery intent | Pause and new Play cancel a queued graph rebuild; cancellation is checked before starting playback. Coordinator callbacks reject paused or superseded episodes. Transport reflects actual engine state while awaiting recovery. |
| Render diagnostics | Only rendered callbacks set lastRenderedAt; resume grace remains separate. Timeout recovery no longer asserts confirmed silence. Failed engine-start duration and full recovery elapsed/rebuild durations are distinguished. |
| EOF | Accept NSOSStatusErrorDomain -39 only at EOF, alongside legacy generic EOF. Retain any returned tail frames and use the normal detector-drain/sentinel path; do not suppress mid-file errors. |
| Auto Archive | Build protection from the pin IDs rather than repeated whole-library scans. Read current pins/playback again before each candidate archive after possible suspension. No archive rule/default/order changes. |
| Download stats | Immutable snapshots perform validation, backup, checksumming, encoding and atomic writes on a serial lane; settlement awaits completion. Synchronous lifecycle checkpoints use the same ordered lane. Older async acknowledgements cannot replace newer persistence state. SQLite flushing remains on its existing owner. Downloaded-activity completion updates one row; broad rebuilds remain for reconciliation/deletion. |
| Disk-write diagnosis | MetricKit includes disk-write bytes, app/build/OS identity and a bounded stack. Slow stats snapshots report logical primary/backup bytes and elapsed checkpoint time. These are not measurements of physical write amplification. |
| Download retries | First confirmed stall can immediately hand off to active-runtime fallback when foreground/playback provides execution. Later retries retain 60/120-second waits; inactive first retries keep 30 seconds. The handoff waits for the old transfer workflow to finish settlement, preventing stale catch/defer work from overwriting a new attempt. Existing network/cancellation/duplicate guards and exhaustion limits remain. |
| Sync noise | Only a changed iCloud switch invokes its settings reaction. Repeated foreign-identity rejection becomes bounded change-driven evidence scoped by identity, preserving the existing structured event name; rejection itself and remote records remain unchanged. |
| Redaction | Personal route names and non-UUID GUIDs receive stable pseudonyms on entry/export. Re-export preserves pseudonyms. Episode titles and timestamps remain useful context; the export is not anonymous. |

## Deliberate boundaries

AVAudioEngine startup still uses the existing serial main-thread control path;
this repair removes stale producer recovery, not all OS/route startup latency.
Route notifications still rebuild when needed; a new route is not suppressed
merely because another recovery recently ran. Physical Bluetooth transitions need
device testing. Other history/stats lifecycle saves remain synchronous; the
historical MetricKit writer is unproven. No CloudKit records were deleted, no
archive safety was relaxed, and no notification/privacy setting was changed.

## Validation

The focused 95-test suite passed on iOS 27. On iOS 26.5, 94 passed and the existing
35 ms lifecycle-poller timing assertion failed with zero observed ticks; that test
passed when rerun in isolation without changing its implementation. This is not
recorded as a clean single-run pass on iOS 26.5.

Coverage includes real silent-file engine
resume after a paused semaphore timeout, Pause during delayed recovery, exactly-once
natural completion, EOF classification, ordered concurrent durable stats writes,
backup/integrity/locked-load cases, retry/cancellation policy, pin projection,
subscription merges and redaction idempotence. The first run found a nested-GUID
pseudonym re-export defect; it was corrected before final verification.

The shared `AutohopCore` target builds successfully. Final logging/sync verification
after preserving stable event names passed all 32 tests on each of iOS 26.5 and
iOS 27. `git diff --check` passed.

Local result bundles: `/tmp/autohop-repairs-complete27.xcresult`,
`/tmp/autohop-repairs-complete26.xcresult`,
`/tmp/autohop-repairs-poller26.xcresult`,
`/tmp/autohop-repairs-logging26.xcresult`, and
`/tmp/autohop-repairs-logging27.xcresult`. Build log:
`/tmp/autohop-repairs-core-final.log`.

Physical route switching, extended listening/energy use, production download-host
behaviour and receipt/symbolication of a real new MetricKit disk report remain
unverified. No release archive, physical-device installation or upload is claimed.
