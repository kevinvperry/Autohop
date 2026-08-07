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

## Structured files that cannot contain comments

`Info.plist`, `AutohopTV.entitlements`, asset-catalog `Contents.json` files and
PNG artwork use strict Apple formats. Adding comment keys or comment syntax can
break compilation, signing or App Store processing. Their AI-readable intent is
therefore documented here and in the tvOS section of `project.yml`:

- `Info.plist`: generated target metadata, CloudKit background notification and
  audio playback declarations.
- `AutohopTV.entitlements`: private CloudKit container and APNs entitlement.
- `Media.xcassets`: App Store icon stack and Top Shelf artwork metadata/assets;
  it contains no runtime logic.

## Non-negotiable invariants

1. Keep queue identity subscription-scoped and prefer authoritative snapshot
   keys over identities reconstructed from local feed/history objects.
2. Keep SwiftUI projections compact; never parse all feeds or traverse the full
   episode graph during focus movement.
3. Generation-own asynchronous playback and detail-loading work so stale tasks
   cannot mutate current presentation state.
4. Record important sync/playback/recovery stages through `AppLogger` with
   stable event keys and bounded metadata.
5. Update this map, the affected file header, tests and Version 1.5 notes when
   ownership or a cross-device contract changes.
6. Queue snapshot schema v3 carries optional Play Next/Play Last pin state.
   Keep decoding compatible with older snapshots and treat the latest durable
   Pin/Unpin outbox command for an episode as the user's authoritative intent.
