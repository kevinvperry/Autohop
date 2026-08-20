# tvOS Diagnostics and Performance Audit — 15 August 2026

<!--
AI CONTEXT — Canonical audit of Autohop's tvOS diagnostic recording after the
clean-install Demo Library and Dynamic Top Shelf work. This document separates
observed evidence from hypotheses, defines the event and privacy contracts, and
records implemented remediation. It must be updated when a new tvOS subsystem
or cross-process extension is introduced.
-->

## Executive finding

### 16 August independent-review resolution

The `createRoot:NSCocoaErrorDomain:513` evidence proves that the main app
resolved an App Group URL; it does not by itself prove either that the root is
writable or that the installed signing state is fully correct. Claims that the
tvOS App Group root is universally read-only were unsupported. Version 1.6
build 7 therefore moves regenerable content to Library/Caches *and* probes both
locations, while the signed archive gate checks the effective app and extension
entitlements. This makes the next physical-device result conclusive.

The audit also corrected an overstated sync mechanism: 399 refreshes for
15,945 records is inconsistent with one refresh per record. Direct bypasses
were per subscription/batch and sequencing call sites. Non-sequencing paths now
use the coalescer; required immediate reads remain direct. Suspension-era hangs
are gated by scene state, CKSyncEngine state uses the tvOS cache boundary,
record pulls emit batch summaries, and redacted exports pseudonymise UUIDs and
URLs using stable hashes.

The physical build subsequently proved the storage distinction: the container
root returned Cocoa 513 while Library/Caches was writable, and dynamic content
returned successfully. A supplied 08:14 `.xcappdata` bundle still represented
the earlier 1.5 (6) binary and could not diagnose the later partial-artwork
screen. Build 8 adds artwork provenance counts (TV disk cache, network and
placeholder) and uses branded poster compositions sized for four-across display.

The diagnostic logger itself was already bounded and comparatively efficient:
one serial append handle, a 500-entry routine backpressure limit, two capped
5 MB segments, lazy metadata construction and one-Hz UI invalidation. The main
failure was observability architecture rather than raw logger performance.
Dynamic Top Shelf collapsed every extension failure into `nil`, so static
fallback artwork could not be attributed to missing publication, unavailable
App Group storage, invalid/stale data, account-scope mismatch or a rendering
failure. Recent launch deadline, Demo Library and deep-link paths also lacked a
single correlated outcome/timing vocabulary.

No source-only audit can identify which Top Shelf condition occurred on the
user's already-installed physical Apple TV because the former extension did not
record it. The implemented heartbeat and Diagnostics panel make the next load
conclusive without guessing.

## Audited surfaces

| Surface | Previous evidence | Audit result | Implemented action |
|---|---|---|---|
| Process/build identity | Version, build, commit, source fingerprint and session | Strong; container path was unnecessary | Retained build identity; removed filesystem path |
| Launch/bootstrap | Store-load timing and sync events | Missing one first-usable-state duration | Added `tv.launch.rootStateChanged` with elapsed time and projection counts |
| Main-thread responsiveness | 250 ms ping, 350 ms hang threshold | Good event evidence; no on-screen summary | Added session count and longest-hang summary |
| Memory/thermal state | Not visible | Performance reports lacked environmental context | Added current footprint, thermal state and uptime to Settings diagnostics |
| Library/queue/materialisation | Detailed events and projection counts | Useful, but developer rows exposed titles/hosts | Replaced content strings with ordinal/state descriptions |
| Playback | Lifecycle, rates, positions and checkpoints | Strong; some metadata included podcast/host | Removed unnecessary free-form podcast/host values |
| Discover | Phase and resolution events | Useful; persisted show/episode titles | Replaced titles with counts and media kind |
| Demo Library | Isolation enforced in architecture | Entry/exit was not correlated | Added `tv.experience.changed`; no demo content is recorded |
| Top Shelf publication | Success/failure only in containing app | Critical silent branches and no extension evidence | Added staged publisher state, duration/error codes and manual refresh |
| Top Shelf extension | No durable diagnostic output | Primary cause of non-actionable fallback | Added bounded content-free heartbeat with explicit outcome |
| Top Shelf deep links | Accepted/rejected parser events | Resolution and refresh result missing | Added resolved-from-projection/resolved-after-refresh/unavailable timing |
| Export | Redacted bounded local file | Good; no capture-time health summary | Export event now records Top Shelf/performance scalar state |

## Dynamic Top Shelf decision tree

The Settings → Apple TV Home Screen panel now exposes each boundary in order:

1. **Eligible episodes** proves whether the current Home projection produced a
   candidate. Zero is a product-state outcome, not an extension failure.
2. **Shared App Group** proves whether the containing app can resolve the
   configured group container. `Unavailable` points to signing/capability or
   installation configuration.
3. **Dynamic snapshot** proves whether a valid, fresh manifest exists and shows
   its generation, item count and age.
4. **Top Shelf extension** is the last system load outcome:
   `dynamicContentReturned`, `appGroupUnavailable`,
   `sharedDefaultsUnavailable`, `accountScopeMissing`, `manifestMissing`,
   `manifestInvalid`, `accountScopeMismatch` or `noRenderableContent`.
5. **Refresh Top Shelf Now** republishes the current projection and invalidates
   TVServices. It does not alter queue, history, subscriptions or playback.

The extension heartbeat is capped at 4 KB, atomically replaced and contains
only outcome, generation, counts and milliseconds. It contains no titles,
episode keys, subscription identifiers, artwork URLs or descriptions. The
extension remains prohibited from networking, CloudKit, GRDB, RSS and domain
writes; this operational heartbeat is its sole write.

## Performance recording policy

- Routine events must describe a meaningful transition, summary or slow-path
  threshold. They must not run per frame, focus update, playback tick or item.
- Timings use monotonic process intervals where practical and integer
  milliseconds. Counts and state names are preferred to arrays or descriptions.
- Failures, launch outcomes, Top Shelf publication outcomes, demo boundary
  changes and main-thread hangs persist immediately. Routine bursts remain
  subject to logger backpressure.
- The Diagnostics screen performs filesystem and memory inspection only when it
  is rendered or a manual export is requested. No new polling timer was added.
- The Top Shelf extension performs one bounded manifest read and one tiny atomic
  heartbeat write per system request; it does not download or decode artwork.
- Detailed events remain in the capped log. SwiftUI observes only compact
  aggregate values, preventing a diagnostic log burst from becoming a UI issue.

## Privacy and support contract

tvOS diagnostics record build identity, state names, counts, durations, media
kind, bounded opaque request identifiers where correlation is necessary, and
error types/codes. New diagnostic paths must not record podcast or episode
titles, descriptions, feed hosts, stream URLs, artwork URLs, query strings,
authentication material or private iCloud record payloads. Exports remain local
until the user retrieves the Apple TV container with Xcode; Autohop does not
upload diagnostics.

## Verification gates

### Build-6 container remediation

The 21:53 container proved candidate selection was healthy (ten items per
attempt) but all completed publications failed after artwork preparation; the
extension never received a valid manifest. It also exposed 4,592 subscription
persistence failures caused by `subscription.feedURL` uniqueness, with 130
runtime podcasts versus 120 distinct persisted feeds.

Publication now labels each storage stage (`createRoot`, `replaceGeneration`,
`createGeneration`, `writeArtwork`, `encodeManifest`, `writeManifest`,
`pruneGenerations`) with a privacy-safe Foundation domain/code, commits immutable
artwork before the atomic manifest, and caches prepared artwork between attempts.
SubscriptionStore canonicalises URL identity, rejects duplicate local adds,
absorbs a colliding remote UUID into the established feed row and reconciles
legacy in-memory duplicates before SQLite persistence.

- Unit-test snapshot validation and the extension heartbeat round trip.
- Require AI headers across `TV`, `TVTopShelf` and `TVTests`.
- Require Top Shelf publisher, extension outcome vocabulary and heartbeat file
  in the tvOS release validator.
- Build and test the complete tvOS app with the embedded extension.
- On physical hardware, focus Autohop in the top row, open Settings afterward,
  and record the five Top Shelf health rows before reinstalling or changing
  signing. This is the evidence needed to identify the current fallback cause.
