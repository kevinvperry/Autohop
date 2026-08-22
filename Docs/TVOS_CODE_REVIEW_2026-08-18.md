# Autohop tvOS Code Review — 18 August 2026

<!--
AI CONTEXT — Docs/TVOS_CODE_REVIEW_2026-08-18.md

Full-surface review of the Apple TV target at Version 1.6 build 10 (commit
4ac3da1). Scope: every Swift source in TV/, TVTopShelf/ and TVTests/, the
AutohopTV/AutohopTVTopShelf/AutohopTVTests sections of project.yml, both
entitlement files, TV/Info.plist and TV/Media.xcassets.

Each finding cites the exact file and line and states the observable
consequence. Findings are evidence-based reading of the current sources; none
of them has been confirmed on physical Apple TV hardware. Update or delete a
finding when it is fixed, and record the fix in VERSION_1.6.md.
-->

> Resolution update — 20 August 2026: the confirmed and qualified findings in
> this review were repaired in commits `87e4ba8` and its follow-up, except the
> icon-layer recommendation: the hardware-proven stack was restored after the
> proposed Back-only layout produced tvOS's white grid placeholder. Dedicated
> AI context headers now preserve the account, commit, refresh, repository,
> lifecycle, playback and demo invariants. Physical-device checklist items in
> `TVOS_PHASE6_VALIDATION.md` remain deliberately unchecked until observed on
> signed Apple TV hardware.
>
> Submission update — 22 August 2026: Version 1.6 build 13 was submitted to
> Apple App Review. Historical findings below retain their original wording;
> the submission does not mark unchecked device evidence complete.

## Scope and verdict

10,608 lines across 80 Swift files. The architecture is sound and the
decomposition described in `Docs/TVAPP_MODEL_DECOMPOSITION_PROPOSAL.md` has
genuinely landed: `TVAppModel` is a 297-line composition facade, page
projections are pure and testable, playback/queue/sync policy lives in
`enum`/`struct` boundaries with 52 regression tests, and the Top Shelf
extension is correctly firewalled from CloudKit, GRDB, RSS and networking.
The invariants in `TV/AI_CONTEXT.md` are respected almost everywhere.

The problems that remain are concentrated in three places:

1. **Main-actor work during first sync.** The refresh coalescer that Round 8b
   installed is bypassed by the materialisation path, so a cold CloudKit zone
   still drives one full uncoalesced projection rebuild per subscription record.
2. **Discover's video-badge probe.** Its cache is defeated by SwiftUI view
   re-initialisation, so browsing Discover issues roughly two network requests
   per show card, repeatedly.
3. **Release gates that the current code cannot pass**, chiefly the Top Shelf
   account-scope requirement in `Docs/TVOS_PHASE6_VALIDATION.md`.

Nothing here is a crash or a data-loss risk. The highest-value items are P1-1,
P1-2 and P1-3.

---

## P1 — Performance and correctness

### P1-1. Remote subscription materialisation bypasses the refresh coalescer

`TV/Recovery/TVAppModel+Recovery.swift:77` — `rememberMaterializationCandidate`
ends with a direct `refreshLibrary()`, not `scheduleLibraryRefresh()`.

The call chain is per CloudKit record:

- `Persistence/CloudSyncEngine.swift:1218` awaits
  `onSubscriptionNeedsMaterialization` **once per subscription record** inside
  the record-application loop.
- `TV/Sync/TVAppModel+Sync.swift:236` `materializeRemoteSubscription` calls
  `rememberMaterializationCandidate(entry)` first.
- That performs a survival-kit JSON decode, a re-encode/write, and then a full
  synchronous `refreshLibrary()`.

Round 8b measured a refresh pass at roughly 300 ms with a library this size. A
cold-zone sweep of ~130 subscription records therefore blocks the main actor
for tens of seconds in 300 ms slices — precisely the focus-engine starvation
signature the coalescer was built to prevent. The duty-cycle bound in
`scheduleLibraryRefresh` (`TV/Library/TVAppModel+Library.swift:85`) never sees
these calls.

`forgetMaterializationCandidate` (`:87`) has the same direct call and is
invoked in a loop from `retryPendingMaterializationsNow` (`:132`), so a manual
**Check for Updates** with N stale kit entries costs N full refreshes.

**Fix:** both helpers should call `scheduleLibraryRefresh()`. The only reason
to keep a direct call is ordering, and neither of these has an ordering
requirement — the tail of `materializeRemoteSubscription` already schedules one.

### P1-2. Survival kit is fully decoded inside a per-row loop

`TV/Queue/TVAppModel+Queue.swift:247` — `retryLegacyRowsWhoseSourcesArrived`
calls `survivalKitStore.load()` **inside** the `for item in upNextItems` loop.

`SurvivalKitStore.load()` (`Persistence/SubscriptionSurvivalKit.swift:79`) is
an unmemoised `JSONDecoder().decode` of the whole kit — roughly 13 KB and ~130
entries at Kevin's library size. With 20 unresolved queue rows that is 20 full
decodes per refresh, on the main actor. `refreshLibraryBody` calls this method
on every pass where projections changed (`TV/Library/TVAppModel+Library.swift:202`).

`pumpQueueEnrichment` (`TV/Queue/TVAppModel+Queue.swift:126`) has the same
pattern inside its `while` loop.

**Fix:** hoist one `let kit = survivalKitStore.load()` above each loop. A
memoised cache inside `SurvivalKitStore` (invalidated on `save`) would fix all
ten call sites at once and is the cleaner change.

### P1-3. Discover re-creates its repository on every parent render

`TV/Views/TVDiscoverView.swift:17` — `private let repository = TVDiscoverRepository()`.

This is a plain stored property on a SwiftUI `View` struct, so its default
expression runs every time the struct is initialised. `TVMainTabView.body`
re-runs on any observed change (`syncStatus`, `isPreparingPlayback`, playback
ticks), and `destination(for:)` constructs a fresh `TVDiscoverView` each time —
so a **new actor with an empty `videoShowCache`** replaces the old one
constantly.

Compounding it, `TVDiscoverModel` builds a *second*, separate repository via
its default argument (`TV/Discover/TVDiscoverModel.swift:36`), so landing loads
and card badges never share a cache at all.

The cost per cache miss is real: `isVideoShow`
(`TV/Discover/TVDiscoverRepository.swift:110`) does a chart `resolveShow`
lookup **plus** an RSS fetch, purely to decide whether to draw a "Video" pill.
The landing page renders roughly 73 show/episode cards (15 top + 10 notable +
4×12 category), so a full browse can issue ~146 network requests, throttled to
two at a time, and re-issue them whenever cards are recycled.

**Fix:** `@State private var repository = TVDiscoverRepository()`, and pass
that instance into `TVDiscoverModel(repository:)`. Consider persisting
`videoShowCache` to `UserDefaults` — the audio/video nature of a show does not
change between sessions.

### P1-4. `.inactive` is treated as `.background`

`TV/App/AutohopTVApp.swift:148-155` — the `else` branch of
`if phase == .active` runs `handleBackgrounded()` **and**
`TVArtworkLoader.shared.trimForMemoryPressure()`.

`scenePhase` passes through `.inactive` on transient system events, not only on
a real background transition. Each one currently force-pushes a CloudKit
checkpoint (`playbackCoordinator.checkpoint()` → `flushAndSendDeferredPushes`),
publishes a Top Shelf snapshot, and **empties the entire decoded artwork
NSCache** (`TV/Views/TVArtworkImage.swift:132` removes all objects and cancels
all in-flight loads). Returning to the app then re-decodes every visible tile.

**Fix:** gate both on `phase == .background`. `.inactive` should at most
checkpoint; it should never purge the cache.

### P1-5. Double library projection on every refresh pass

`TV/Library/TVAppModel+Library.swift:147-157` — `TVLibraryProjector.project` is
called twice per `refreshLibraryBody`. The first call (`baseProjection`) exists
solely to compute `realIDs`, discarding its tiles and dictionary.

Each call filters, sorts and maps all ~130 `Subscription` values, and builds a
`subscriptionsByID` dictionary that the caller never reads —
`recomputeDerivedState` rebuilds it independently at `:252`. The projector's
`subscriptionsByID` field (`TV/Library/TVLibraryProjector.swift:44`) is
referenced only by `TVTests/TVAppDecompositionTests.swift:47`.

**Fix:**

```swift
let realIDs = Set(subscriptionStore.subscriptions.lazy
    .filter { $0.browseDate == nil }.map(\.id))
```

then a single `project(...)` call. Optionally have `recomputeDerivedState`
adopt `projection.subscriptionsByID` instead of rebuilding it.

### P1-6. `reason == "bootstrap"` is a dead condition

`TV/Sync/TVAppModel+Sync.swift:306` gates the full subscription-membership
sweep on `reason == "bootstrap"`. No caller ever passes that string. The five
call sites pass `"launch"`, `"foreground"`, `"tv.manualRetry"`,
`"tv.setupRetry"` and `"tv.topShelf.deepLink"`; bootstrap itself passes
`"launch"` (`TV/App/TVAppModel+Bootstrap.swift:65`).

The comment two lines below says "Bootstrap owns the full library prime", but
on a returning device with a populated library that sweep only fires via the
`librarySubscriptions.isEmpty` or one-shot-migration escape hatches. The
CKSyncEngine delta stream still delivers new subscriptions, so this is not
user-visible today — but the intended authoritative membership reconciliation
on launch is not happening, and the condition reads as if it is.

**Fix:** decide the policy explicitly. Either add `"launch"` to the condition
(restoring the documented behaviour, at the cost of a paginated sweep every
cold launch) or delete the dead `"bootstrap"` term and update the comment to
describe what actually runs.

---

## P2 — Top Shelf

### P2-1. Account scope cannot satisfy its own release gate

`TV/TopShelf/TVTopShelfSnapshotPublisher.swift:285` `resolvedAccountScope()`
mints a random `UUID` on first publish and stores it in the App Group defaults
forever. It is never derived from, or invalidated by, the signed-in iCloud
account.

`Docs/TVOS_PHASE6_VALIDATION.md:35` requires: *"Apple TV user/account switching
never exposes the prior scope's titles or artwork."* Neither entitlement file
requests `com.apple.developer.user-management`, so the app container is shared
across tvOS users. After a user switch the stored scope still matches the
manifest, `TopShelfContentProvider` (`TVTopShelf/TopShelfContentProvider.swift:41`)
passes its equality check, and the previous account's episode and podcast
titles render on the Home Screen.

**Fix:** derive the scope from `CKContainer.default().userRecordID` (hashed, to
keep the manifest content-free) and rewrite it whenever the resolved record ID
changes, clearing the manifest on mismatch. `CKAccountChanged` is the natural
trigger.

### P2-2. Failed pruning deletes a generation the manifest already references

`TV/TopShelf/Shared/TVTopShelfSharedStorage.swift:119-124` — the
`removeOldGenerations` call sits inside the same `do` block whose `catch`
removes the new generation directory. The manifest has already been written
atomically by that point (`:117`).

If pruning throws, the rollback deletes the artwork the live manifest points
at. `TopShelfContentFactory` (`TVTopShelf/TopShelfContentFactory.swift:22`)
only validates the filename via `try? artworkURL(...)`, never file existence,
so the extension returns items whose image URLs resolve to nothing — blank
cards rather than the intended static fallback.

**Fix:** move `removeOldGenerations` outside the rollback scope. Pruning is
best-effort cleanup and must never invalidate a committed generation.

### P2-3. Publisher diagnostics overwrite the pause state

`TV/TopShelf/TVTopShelfSnapshotPublisher.swift:243-245` — the failure path sets
`diagnostics.phase = "Paused after storage failure"` and then unconditionally
overwrites it with `"Publish failed"` on the next line.

`retryAfterSeconds` survives, so Settings still shows the automatic-retry row,
but the phase row never reports the paused state from this branch. Given P2-1
through P2-3 exist specifically to make the next physical-device result
conclusive, a diagnostics row that reports the wrong state is worth fixing.

**Fix:** make the overwrite an `else` on the `consecutiveFailures >= 3` branch.

### P2-4. Unclamped thumbnail size for extreme aspect ratios

`TV/TopShelf/TVTopShelfArtworkPreparer.swift:102` computes
`kCGImageSourceThumbnailMaxPixelSize` as
`max(width, height) * maxDimension / min(sourceWidth, sourceHeight)`.

Podcast artwork is effectively always square, so this is fine in practice. For
a 3000×100 source it would request an 18,240 px thumbnail — a large allocation
on a memory-constrained Apple TV, from arbitrary publisher-controlled artwork.

**Fix:** clamp the computed value (4,096 is generous for a 808×1216 output).

---

## P3 — Playback and media

### P3-1. Now Playing metadata is incomplete

`TV/Playback/TVPlaybackModel.swift:505` `updateNowPlayingInfo()` sets title,
artist, rate, default rate, elapsed time and duration — but no
`MPMediaItemPropertyArtwork`. The tvOS system Now Playing surface and Control
Center therefore show a generic placeholder for every episode, even though
artwork is already decoded and cached by `TVArtworkLoader`.

`configureRemoteCommands()` (`:523`) registers `play`, `pause`,
`skipForward` and `skipBackward`, but not `togglePlayPauseCommand` (the Siri
Remote's own play/pause button in several backgrounded contexts) or
`changePlaybackPositionCommand` (system scrubbing).

**Fix:** populate artwork from the loader cache when available, and register
the two missing commands.

### P3-2. `handleFinished` silently strands playback when the subscription is nil

`TV/Playback/TVPlaybackModel.swift:466` — `guard let subscription =
currentSubscription else { return }`. On that path nothing happens: no
`markListeningHistoryFinished`, no stats completion, no auto-advance, no
`stopAndClear()`. `currentEpisode` stays set, so Home keeps rendering a
"Now Playing" hero for an episode that has ended.

**Fix:** fall through to `stopAndClear()` and log the anomaly rather than
returning silently.

### P3-3. `stopAndClear` leaves stale presentation state

`TV/Playback/TVPlaybackModel.swift:361` resets the episode, subscription, ID,
origin, history-entry ID, `isPlaying`, `playbackState` and `errorMessage`, but
leaves `currentTime`, `currentSubscriptionTitle`, `currentSpeed` and
`isBuffering` at their previous values.

Nothing renders them while `currentEpisode == nil`, so this is latent rather
than visible — but the next `play()` also does not reset `isBuffering`, and the
Settings Now Playing rows read `snapshot.playbackPositionSeconds` from
`currentTime` unconditionally (`TV/Diagnostics/TVAppModel+Diagnostics.swift:17`),
so Settings reports a position for "None".

### P3-4. Redundant policy evaluation

`TV/Playback/TVPlaybackModel.swift:387,390` calls
`TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(delta)` twice for
the same delta in the same tick. Cosmetic; fold into one `if`.

---

## P4 — Resilience and state

### P4-1. Poisoned artwork disk-cache entries never self-heal

`TV/Views/TVArtworkImage.swift:155-164` — the loader prefers the mapped disk
file, and if `downsampledImage` returns `nil` (truncated or corrupt file), the
`nil` is not memory-cached. Every subsequent render of that URL re-reads the
same bad bytes, re-decodes, and fails again. The entry survives until the LRU
size prune (150 MB) evicts it.

**Fix:** delete the disk entry and retry the network fetch once when decoding a
disk-sourced payload fails.

### P4-2. `isVideoShow` does not cache negative outcomes

`TV/Discover/TVDiscoverRepository.swift:125` — the `catch` returns `false`
without writing `videoShowCache[key]`. A show whose feed is slow, blocked or
malformed is re-probed (chart lookup + RSS fetch) on every card appearance.
This multiplies P1-3.

**Fix:** `videoShowCache[key] = false` in the catch, or cache a short-lived
negative result if a retry is wanted.

### P4-3. `locallyArchivedEpisodeKeys` never expires

`TV/App/TVAppModel.swift:87` / filtered at
`TV/Library/TVAppModel+Library.swift:268-273`. The set grows for the process
lifetime and is never pruned when the phone republishes a queue that contains
the key again. Un-archiving on iPhone therefore cannot restore the row on Apple
TV until the app is relaunched.

**Fix:** drop a key once an authoritative snapshot newer than the archive
action still contains it (the same confirmation pattern already used for
`pendingPlayNextEpisodeKey` at `:279`).

### P4-4. Cached-projection badge reports a fabricated timestamp

`TV/App/TVAppModel.swift:262` sets `syncStatus = .cached(Date(), generation: 0)`
when a cached library projection loads. `TVSyncStatus.cached` renders as
`"Cached · updated \(date.formatted(.relative…))"`
(`TV/Models/TVDisplayModels.swift:66`), so a projection written days ago is
labelled "updated in 0 seconds".

`TVProjectionStore` already stores a real `updatedAt` column but does not
expose it (`Persistence/TVProjectionStore.swift:17`).

**Fix:** add an `updatedAt(key:)` accessor and use the stored value.

### P4-5. Freshness poll can strand the badge on "Updating"

`TV/Sync/TVAppModel+Sync.swift:428-440` sets `.updating` unconditionally, then
only restores `.upToDate` `if let snapshot`. With no synced queue snapshot the
badge stays "Updating from iCloud…" indefinitely.

**Fix:** add an `else` restoring the prior status or `.unavailable`, matching
`primeLibraryFromCloudSoon`'s handling at `:290-294`.

### P4-6. Discover Play Next uses a locally derived key

`TV/Sync/TVAppModel+Sync.swift:145` — the library-match branch of
`requestDiscoverPlayNext` builds a `TVQueueRowModel` whose `id` is
`PlaybackPositionStore.key(for: libraryEpisode)` and hands it to
`requestPlayNext`. That method's own header (`:66-70`) explains that a derived
key is exactly what broke the optimistic move previously, and that the row ID
must come from the phone-authored snapshot.

In practice the library episode carries the phone's `subscriptionID`, so keys
usually agree — but the invariant is stated and then violated one function
away.

**Fix:** prefer an existing `queueRows` entry for that episode when one exists,
and fall back to the derived key only when it does not.

---

## P5 — Demo (App Review-visible)

### P5-1. Completed demo episodes reappear as "Continue Listening"

`TV/Demo/TVDemoSession.swift:62` — `continueEpisode` returns the first episode
with `progress > 0`. `markCompleted` sets progress to the full duration
(`:82`), so after a reviewer finishes an episode it immediately becomes the
Continue Listening hero at 100 %.

**Fix:** exclude episodes whose progress is at or near `duration`.

### P5-2. Demo playback has no end-of-item handling

`TV/Demo/TVDemoPlayerView.swift:88` installs a periodic time observer but no
`AVPlayerItemDidPlayToEndTime` observation. When the 30 s audio or 12 s video
ends the player simply stops; the episode is not marked complete and the cover
stays open. The only completion path is the explicit "Finish Demo Episode"
button.

**Fix:** observe end-of-item and call the existing `onComplete`.

---

## P6 — Dead code and build hygiene

| Item | Location | Note |
|---|---|---|
| `shelf(title:episodes:)` and `TVEpisodeCard` | `TV/Views/TVHomeView.swift:261,333` | Unreachable since the Latest shelf was removed |
| `TVAppModel.episodeRows(subscriptionID:)` | `TV/Library/TVAppModel+Library.swift:339` | Duplicate; views use `libraryModel.episodeRows` |
| `TVMaterializationCoordinator.cancelRetry` | `TV/Recovery/TVMaterializationCoordinator.swift:23` | No callers |
| `TVForegroundSyncCoordinator.stop()` | `TV/Sync/TVForegroundSyncPolicy.swift:41` | No callers; the poll task runs for the process lifetime |
| `TVDiscoverModel.mutationPolicy` | `TV/Discover/TVDiscoverModel.swift:29` | Declared, never read outside its test |
| `sharedRecentHistoryPrime(engine:reason:)` | `TV/Sync/TVAppModel+Sync.swift:447` | Takes an `engine` it discards via `_ = engine` |
| `TVLibraryProjector.Projection.subscriptionsByID` | `TV/Library/TVLibraryProjector.swift:44` | Built every pass, read only by a test |

### P6-1. Engineering docs ship inside the App Store binary

`project.yml:368` declares `sources: - TV` with no `excludes`, and
`Autohop.xcodeproj/project.pbxproj:1677-1689` shows the result:
`TV/AI_CONTEXT.md` and `TV/Demo/README.md` are in AutohopTV's Resources build
phase, and `TVTopShelf/AI_CONTEXT.md` is in the extension's.

Internal architecture notes are therefore distributed in the shipped app.

**Fix:** add `excludes: ["**/*.md", "*.entitlements"]` to the AutohopTV source
entry, matching the pattern already used for `AutohopTVTopShelf` at
`project.yml:451`.

### P6-2. Duplicate PNGs outside their imagesets

Five files sit directly in `.imagestacklayer` directories rather than inside
their `Content.imageset`:

```
TV/Media.xcassets/Brand Assets.brandassets/App Icon - App Store.imagestack/{Back,Middle,Front}.imagestacklayer/AutohopTV-AppStore-1280x768.png
TV/Media.xcassets/Brand Assets.brandassets/App Icon.imagestack/Front.imagestacklayer/AutohopTV-{400x240,800x480}.png
```

No `Contents.json` references them. They are repository clutter and add ~5
copies of the same artwork to the working tree.

---

## P7 — App icon layer composition

`TV/Media.xcassets/Brand Assets.brandassets/App Icon.imagestack` puts the
**same** `HomeScreen-400x240@1x.png` / `@2x.png` pair on both the **Front** and
**Middle** layers, and leaves the **Back** layer's `Content.imageset` empty.

`App Icon - App Store.imagestack` puts the same `AutohopTV-AppStore-1280x768.png`
on all three layers.

tvOS parallax offsets each layer independently while the icon is focused. Two
identical opaque full-bleed layers produce a visible doubled or ghosted edge as
the front layer slides over the middle, and an empty back layer means the
parallax reveals nothing behind. The conventional layout for a deliberately
flat, non-parallax icon is artwork on **Back** only, with Middle and Front
empty.

This is only observable on hardware with the icon focused, which is why the
three recent icon commits may not have surfaced it. Worth checking on the
device before resubmission.

---

## P8 — Documentation drift

- **`firstSyncWaitMessages` (42 entries, `TV/App/TVAppModel+Bootstrap.swift:89`)**
  is documented as covering "≈ 5 minutes before any repeat". `bootstrap()`
  cancels the rotator via `defer` when it returns, which on a clean install is
  roughly 8 s later — two messages. The full rotation is now reachable only
  during a long survival-kit rebuild. The list is not dead, but its rationale
  no longer matches the launch path.

- **`TVDESIGN.md`** describes queue artwork at 360 px, library/shelf at ~520 px,
  detail at 440 px and the player hero at 1200 px. Those match the code, but
  Discover uses 240/440/560/640/720 px, none of which the design document
  mentions.

- **`Docs/TVOS_PHASE6_VALIDATION.md`** has 0 of 11 core boxes and 0 of 8 Top
  Shelf boxes checked, with "Release candidate: _not assigned_". P2-1 means the
  account-switching box cannot pass with the current implementation.

- **`Docs/TVOS_APP_REVIEW_RESUBMISSION_NOTES.md`** is still marked DRAFT with
  eight unchecked verification items.

---

## Suggested order of work

1. P1-1, P1-2, P1-5 — main-actor cost during first sync. Small, local, and
   directly attack the symptom Kevin has reported repeatedly on hardware.
2. P1-3, P4-2 — Discover network volume. One-line ownership change plus a cache
   write.
3. P1-4 — `.inactive` handling.
4. P2-1, P2-2, P2-3 — Top Shelf correctness, needed before the Phase 6 gate can
   be signed.
5. P3-1, P3-2, P4-1, P4-4, P4-5 — playback and status polish.
6. P5-1, P5-2 — demo behaviour, visible to App Review.
7. P6, P7, P8 — hygiene, icon layers, documentation.

Items 1–3 need no new tests to be safe but should gain regression coverage for
the coalescer bypass. Item 4 changes cross-process behaviour and needs the
physical-device Top Shelf checks in `Docs/TVOS_PHASE6_VALIDATION.md`.
