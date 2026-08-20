# AI CONTEXT — Autohop tvOS source map

This file is the directory-level context header for the complete Apple TV
target. Every Swift source in `TV/` and every tvOS-only regression test in
`TVTests/` must also contain its own `AI CONTEXT` header. The release validator
enforces that rule.

## Platform contract

- The iPhone is the durable author of subscriptions, priority ordering and the
  complete Up Next queue.
- Private CloudKit in the user's own iCloud account is the only cross-device
  transport. There is no Autohop server, relay or subscription service.
- Apple TV may author playback/history/archive state and one-use Pin/Unpin
  queue commands. Pin is the cross-device form of iOS Play Next; the phone
  applies each command and republishes the authoritative complete queue.
  Apple TV must never replace that phone-authored queue snapshot.
- tvOS databases and projections are purgeable caches. CloudKit plus the
  survival kit rebuild them.
- `AutohopCore` supplies shared models, persistence and playback machinery.
  The tvOS target must not import the iPhone `AppState` runtime.

## Ownership map

- `App/`: composition, dependencies and bootstrap sequencing.
- `Models/`: focused presentation state and immutable display projections.
- `Sync/`: CloudKit lifecycle, foreground refresh and TV-originated commands.
- `Queue/`: authoritative snapshot projection and legacy detail enrichment.
- `Library/`: compact library projection and bounded selected-feed details.
- `History/`: Continue Listening and the cross-device archive history.
- `Playback/`: request ownership, AVPlayer lifecycle, track probing, progress
  accounting and progress-upload policy.
- `Recovery/` and `Resolution/`: cache rebuilds and identity compatibility.
- `Diagnostics/`: read-only state snapshots and main-thread hang evidence.
- `Views/`: presentation and focus only; views must not become sync, identity,
  persistence or playback-policy owners.
- `Navigation/`: tab/path/player presentation state.
- `Demo/`: Release-build, offline App Review demonstration. It owns synthetic
  fixtures, bundled first-party media, ephemeral queue/history/progress and its
  private AVPlayer. It must never import or receive production persistence,
  CloudKit, sync, statistics or subscription writers.

## Structured files that cannot contain comments

`Info.plist`, `AutohopTV.entitlements`, asset-catalog `Contents.json` files and
PNG artwork use strict Apple formats. Adding comment keys or comment syntax can
break compilation, signing or App Store processing. Their AI-readable intent is
therefore documented here and in the tvOS section of `project.yml`:

- `Info.plist`: generated target metadata, CloudKit background notification and
  audio playback declarations.
- `AutohopTV.entitlements`: Debug/private CloudKit container and development
  APNs entitlement. `AutohopTV.Release.entitlements`: the matching distribution
  container plus production APNs. `project.yml` selects them by configuration;
  the signed archive remains the final authority and must be inspected.
  Both app configurations and the Top Shelf extension run as the current tvOS
  user with a user-independent keychain, so app and App Group presentation data
  are profile-scoped without deprecated user-identifier APIs.
- `Media.xcassets`: App Store icon stack and Top Shelf artwork metadata/assets;
  it contains no runtime logic. The current repeated-layer icon stack is the
  last hardware-proven configuration that produces tvOS's required flattened
  primary icon. Do not delete, empty or consolidate its Front/Middle/Back files
  based only on visual theory or simulator compilation; replacement requires a
  signed-device Home Screen check plus compiled `Assets.car` inspection.
- Dynamic Top Shelf is implemented by `TV/TopShelf`, `TVTopShelf` and the typed
  routes in `TV/Navigation`. The extension is a bounded renderer of an atomic
  App Group presentation snapshot and may write only its 4 KB content-free
  diagnostic heartbeat; it must never open CloudKit, GRDB, RSS or production
  model state. Live playback is projected separately from Home's idle-only
  Continue Listening item, owns the first slot and is deduplicated from Up Next.
  Both system actions use exact-identity playback. Queue rows carry bulk-read
  synced position metadata so rendering and focus remain persistence-free.
  The containing app resolves a SHA-256 account scope from CloudKit before
  publishing. An unavailable or changed account clears the manifest first;
  never replace this with an installation UUID or relabel an old candidate.
  Generation pruning happens only after manifest commit and is best-effort —
  cleanup failure must not roll back artwork referenced by the live manifest.
  Its canonical design and remaining physical release gates are in
  `Docs/TVOS_DYNAMIC_TOP_SHELF_IMPLEMENTATION_PROPOSAL.md`.
- `Diagnostics/` and Settings expose compact local health for launch, memory,
  thermal pressure, hangs and Top Shelf. The extension's maximum-4 KB
  content-free heartbeat is its sole operational write; the canonical audit is
  `Docs/TVOS_DIAGNOSTICS_AUDIT_2026-08-15.md`.

## Non-negotiable invariants

1. Keep queue identity subscription-scoped and prefer authoritative snapshot
   keys over identities reconstructed from local feed/history objects.
2. Keep SwiftUI projections compact; never parse all feeds or traverse the full
   episode graph during focus movement.
3. Generation-own asynchronous playback and detail-loading work so stale tasks
   cannot mutate current presentation state.
4. Record important sync/playback/recovery stages through `AppLogger` with
   stable event keys and bounded metadata.
5. Update this map, the affected file header, tests and current version notes when
   ownership or a cross-device contract changes.
6. Queue snapshot schema v3 carries optional Play Next/Play Last pin state.
   Keep decoding compatible with older snapshots and treat the latest durable
   Pin/Unpin outbox command for an episode as the user's authoritative intent.
7. Launch presentation has a ten-second first-usable-screen deadline. The
   deadline exposes setup/demo without cancelling or racing mutable bootstrap
   work; a late genuine library may still become ready normally.
8. Demo media and mutations remain bundle/in-memory only. Never merge demo and
   personal projections or allow demo actions to reach CloudKit/stats.
9. Survival-kit membership changes enter `scheduleLibraryRefresh`; per-record
   CloudKit materialisation must never call the synchronous projector directly.
10. Discover owns one stable repository for landing, cards and destinations.
    Media-kind failures use bounded retry backoff; view reconstruction must not
    discard successful classification caches or create probe storms.
11. Treat `.inactive` as a transient presentation state. Only `.background`
    performs lifecycle checkpointing and decoded-artwork eviction.
12. Natural playback completion and explicit stop always leave a fully idle
    presentation snapshot. Demo playback also completes on AVPlayer end events,
    and completed demo episodes are never offered as Continue Listening.
13. Treat the tvOS icon stack as an indivisible release artifact. A successful
    asset-catalog build is insufficient: the Home Screen must show Autohop, not
    the white grid placeholder, before any layer cleanup can ship.
