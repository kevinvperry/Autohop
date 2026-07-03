# Autohop Apple Watch App — Implementation Proposal

<!--
AI CONTEXT — Docs/WATCH_APP_IMPLEMENTATION_PROPOSAL.md

PURPOSE: Full implementation proposal for an Autohop watchOS app, derived from a
file-level review of the Pocket Casts iOS watch app (local clone at
~/Developer/GitHub/pocket-casts-ios). Written for AI-assisted execution: every
pattern cites the reference file to read before implementing, every phase has
explicit deliverables, non-goals, and verification steps.

STATUS: PROPOSAL — no watch code exists yet. Nothing in this doc is built.
When a phase starts, update the phase status line and FEATURES.md.

RELATED: Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md (written 2026-07-03) defines
a cross-platform Phase 0 (AutohopCore platform matrix, AppState domain
extraction, StreamingPlaybackEngine, PlaybackCapabilities) that SUPERSEDES this
doc's §7.2 module-audit approach and generalises decision D7 into a shared
PlaybackCapabilities mechanism. If tvOS Phase 0 lands first, watch Phase 3
consumes those extracted domain objects instead of auditing modules itself.

HOW TO USE: Execute phases in order. Before writing code in a phase, read the
"Reference files" for that phase in the Pocket Casts clone AND the Autohop files
listed in the mapping table (§3). Follow the global constraints in §0 at all times.
-->

Source inputs:

- Pocket Casts iOS repo, local clone: `~/Developer/GitHub/pocket-casts-ios`
  (watch target: `Pocket Casts Watch App/`, phone counterpart:
  `podcasts/Watch Communication/`, protocol: `podcasts/WatchConstants.swift`).
  All pointers below written as `PC: <path>` are relative to that clone root.
- Autohop architecture: `App/AppState.swift`, `Playback/PlaybackEngine.swift`,
  `Queue/QueueService.swift`, `Downloads/DownloadManager.swift`,
  `Persistence/CloudSyncEngine.swift`, `NowPlaying/NowPlayingService.swift`.
- Autohop product docs: `FEATURES.md`, `DESIGN.md`, `SYNC_DESIGN.md`,
  `Docs/CARPLAY_IMPLEMENTATION_STRATEGY.md` (the CarPlay doc is the style and
  scoping precedent for this one).
- Code review of the Pocket Casts watch app performed 2026-07-02.

---

## 0. Global constraints (apply to every phase)

These override anything else in this document.

1. **XcodeGen**: `Autohop.xcodeproj` is generated from `project.yml`. The watch
   target, its Info.plist properties, and every file addition/rename MUST go
   through `project.yml`, then `xcodegen generate`. Never edit the .xcodeproj.
2. **No AI-run builds**: Kevin compiles and runs in Xcode himself. Do not run
   `xcodebuild`. Reason hard about compile-correctness before handing over
   (watch out for the single-expression implicit-return footgun when adding
   log lines). Where logic is UI-independent (message codecs, snapshot
   serialisers, queue mapping), put it in files the SwiftPM package can compile
   and add headless smoke tests alongside the existing `*SmokeTests` executables.
3. **MPL-2.0 discipline**: Everything taken from Pocket Casts in this proposal
   is *architecture and behaviour* (not copyrightable expression) — re-implement
   from scratch in Autohop idiom. IF any Pocket Casts source is ever ported
   line-for-line, that file becomes MPL-2.0-covered and MUST be added to
   `NOTICE`, `AcknowledgementsView`, and carry the MPL file header, matching the
   existing covered-file process.
4. **Docs + headers workflow**: before editing any Autohop file, read its
   AI CONTEXT header; after editing, update the header and the relevant docs
   (`FEATURES.md`, this file's phase status lines, `DESIGN.md` if watch UI
   patterns are added).
5. **Main branch only** unless Kevin says otherwise.
6. **Support page mirror**: when the watch app ships user-facing behaviour,
   update `Settings/SupportContent.swift` AND the website `support.html`
   together.
7. **Latest-episode principle**: nothing in watch auto-download logic may defer
   downloading the newest episode; limits archive old, never block new.

---

## 1. Strategy summary

Build the watch app **remote-first**: the watch is a remote control for the
iPhone before it is ever a standalone player. This is the same staging Pocket
Casts uses, and their code proves the two modes can share one UI layer if the
source abstraction (§2.1) is adopted from day one.

| Phase | Ships | Watch has DB? | Watch plays audio? | Status |
|---|---|---|---|---|
| 0 | Target scaffolding, shared protocol module | No | No | Not started |
| 1 | Now Playing remote control | No | No | Not started |
| 2 | Queue view + episode actions + state restoration | No | No | Not started |
| 3 | Standalone playback (downloads on watch, CloudKit sync) | Yes (GRDB) | Yes (AVPlayer path) | Not started |
| 4 | Polish: Smart Stack widget, App Intents, settings | — | — | Not started |

Phases 1–2 are a shippable v1 on their own. Phase 3 is a separate product
decision with real risk (§7.6) — do not start it implicitly.

**The first watch release (Phases 1–2) supports:**

- Now Playing: play/pause, skip ±N (user's configured intervals), speed,
  chapter next/prev when chapters exist, volume via Digital Crown.
- Up Next (the Priority Stack queue) with episode actions: Play, Play Next,
  Play Last, Archive, Mark Played.
- Auto-open Now Playing when watchOS launches the app because phone audio started.
- State restoration to the last-viewed page.

**The first watch release does not support** (CarPlay-precedent scoping):

- Search, browsing podcasts, discovery, adding feeds, OPML.
- Downloads or feed refresh on the watch.
- Subscription management, per-podcast settings, stats, onboarding, sharing.
- Sleep Timer control (candidate for Phase 4, not v1).
- Trim Silence / Vocal Boost toggles (phone-remote could support them like
  Pocket Casts does — deferred to keep v1 minimal; see D7).
- Standalone playback of any kind.

---

## 2. Reference architecture — how Pocket Casts built theirs

Read this section as "the prior art"; §3 maps it onto Autohop.

### 2.1 Two play sources behind one protocol (the load-bearing decision)

- `PC: Pocket Casts Watch App/UI/Play Source/PlaySourceViewModel.swift` —
  ~95-line protocol covering playback, episode actions, lists, and Now Playing
  metadata. Includes availability flags (`trimSilenceAvailable`,
  `volumeBoostAvailable`) so a source can decline features and the UI degrades.
- `PC: Pocket Casts Watch App/UI/Play Source/PhoneSourceViewModel.swift` —
  remote implementation: reads a cached state blob, sends WatchConnectivity
  commands. No database on the watch in this mode.
- `PC: Pocket Casts Watch App/UI/Play Source/WatchSourceViewModel.swift` —
  local implementation: same calls against the on-watch playback/database stack.
- `PC: Pocket Casts Watch App/UI/SourceManager.swift` — trivial persisted
  enum (`.phone` / `.watch`); `PlaySourceHelper.playSourceViewModel` is the
  one-line factory the whole UI uses.
- `PC: Pocket Casts Watch App/UI/Main Page/SourceInterfaceModel.swift` —
  source toggle UX, including the guard that syncs before switching when the
  two sources' now-playing episodes diverge (`nowPlayingEpisodesMatchOnBothSources()`).

Every screen (Now Playing, Up Next, lists, swipe actions) is written once
against the protocol. This is what makes remote-first cheap and standalone-later
possible without a UI rewrite.

### 2.2 Phone → watch state sync (the "state blob")

- `PC: podcasts/Watch Communication/WatchManager.swift` — phone-side manager.
  Key behaviours to replicate:
  - Subscribes to ~15 NotificationCenter events (playback started/paused/ended,
    position saved, effects changed, up-next changed, starred changed, refresh
    completed) and on ANY of them serialises one flat state dictionary
    (`sendStateToWatch()`, line ~540).
  - The blob contains: now-playing info (episode, status, position, duration,
    chapter info, speed/effects, podcast tint colour as hex, skip amounts,
    up-next count), the serialised Up Next list, playlist metadata, relevant
    settings, a protocol version key, and a **timestamp**.
  - Delivery tiering: `sendMessage` when `session.isReachable` (instant),
    else `updateApplicationContext` (queued, latest-wins, survives app death).
  - **Payload-too-large fallback**: on `WCErrorCodePayloadTooLarge`, retries
    once with a truncated Up Next list (`payloadTooLargeFallbackLimit`).
  - All sends funnel through a serial `sessionQueue` with a
    `dispatchPrecondition` — WCSession calls are not thread-safe.
- `PC: podcasts/WatchConstants.swift` — the wire protocol: stringly-typed
  dictionary keys plus `messageVersion` (`"wappv4"`). Copy the *versioning
  idea*, not the stringly-typed style (see D3).
- `PC: Pocket Casts Watch App/Data & Communication/SessionManager.swift` —
  watch-side receiver. Key behaviour: **timestamp guard**
  (`handleStateUpdate`, line ~111) discards any update whose timestamp is ≤ the
  last processed one, because stale queued `applicationContext` can arrive
  *after* fresher `sendMessage` data and would otherwise overwrite it. This
  guard fixed a real production bug for them — implement it from day one.
- `PC: Pocket Casts Watch App/Data & Communication/WatchDataManager.swift` —
  watch-side accessor over the blob (stored whole in UserDefaults). In phone
  mode the watch has **no database at all**; this file is the entire "model layer".

### 2.3 Watch → phone commands, tiered by loss tolerance

- `PC: Pocket Casts Watch App/Data & Communication/SessionManager+Send.swift` —
  three delivery tiers, chosen per command:
  1. **Fire-and-forget** (`sendResponseless`) for transient controls:
     play/pause, skip, speed, chapter. Dropped if unreachable — acceptable,
     the user just taps again.
  2. **Guaranteed** (`sendWithFallback`, line ~264): `sendMessage` with an
     error-handler fallback to `transferUserInfo` (queues until the phone is
     available) for state mutations: star/archive/mark played/up-next edits.
  3. **Request/reply** (`requestContents`, `requestDownloadedEpisodes`) for
     on-demand lists — fetched only when the user opens that screen, keeping
     the pushed state blob small.
- `PC: podcasts/Watch Communication/WatchManager.swift` line ~136
  (`handleWatchAction(messageType:payload:)`) — ONE unified handler processes
  a command whether it arrived via `didReceiveMessage` or `didReceiveUserInfo`,
  so the fallback path cannot drift from the primary path. Replicate this shape.

### 2.4 Standalone-mode infrastructure (Phase 3 prior art)

- Code sharing: `PlaybackManager.swift` and friends are compiled into the watch
  target by file membership (4 targets share the file per
  `podcasts.xcodeproj/project.pbxproj`); data/server layers are SwiftPM modules.
  Autohop's equivalent is cleaner: AutohopCore is already a package (D8).
- `PC: Pocket Casts Watch App/UI/ExtensionDelegate.swift`:
  - `applicationWillResignActive` → `transferForegroundDownloadsToBackground()`
    (foreground downloads handed to a background URLSession before suspension).
  - `handle(_ backgroundTasks:)` routes `WKURLSessionRefreshBackgroundTask`
    callbacks back to the download manager / background sync by session
    identifier prefix.
  - `scheduleNextRefresh()` — `WKApplication.scheduleBackgroundRefresh` every
    60 minutes; rescheduled on each activation and each background fire.
  - `handleRemoteNowPlayingActivity()` — watchOS auto-launched the app because
    the *phone* started playing; deep-link straight to Now Playing with
    source = .phone.
- `PC: Pocket Casts Watch App/UI/WatchSyncManager+Autodownload.swift` —
  "auto-download top N of the queue to the watch, auto-delete auto-downloaded
  files that fall out of the top of the queue". Configured on the phone,
  executed on the watch. This single feature is what makes standalone mode
  usable without ever browsing on a 40 mm screen.
- `PC: Pocket Casts Watch App/UI/WatchSyncManager.swift` — debounced reaction
  to incoming phone state (`ContextUpdateDebouncer`, 2 s, foreground-only
  because background execution windows are tied to task completion), and
  credential handover via request/reply. Autohop needs none of the
  account-credential machinery (CloudKit needs no login — D10).

### 2.5 UI patterns worth copying directly

- App entry: `PC: Pocket Casts Watch App/UI/PocketCastsApp.swift` — SwiftUI
  `@main` `App` + `@WKApplicationDelegateAdaptor`.
- Now Playing layout: `PC: Pocket Casts Watch App/UI/Now Playing/Interface/NowPlayingControls.swift`
  — three vertical groups: (title / tinted progress bar / subtitle + time
  remaining), (skip back / play-pause / skip forward), (effects / volume /
  up-next-with-count-badge). Notable details:
  - Haptic on every control: `WKInterfaceDevice.current().play(.click)`.
  - watchOS 11 double-tap: `.handGestureShortcut(.primaryAction)` on play/pause
    (`HandGestureShortcutPrimaryAction` modifier at the bottom of the file).
  - `containerRelativeFrame(.vertical)` + `scrollBounceBehavior(.basedOnSize)`
    to make the page fill the screen but still scroll on small watches.
- Crown volume: `PC: Pocket Casts Watch App/UI/SwiftUI/VolumeControl.swift` —
  `WKInterfaceVolumeControl(origin:)` wrapped in `WKInterfaceObjectRepresentable`;
  origin `.companion` in phone mode, `.local` in watch mode. This is how the
  Digital Crown adjusts the right device's volume with zero custom code.
- MVVM bridging: `PC: Pocket Casts Watch App/UI/Now Playing/Interface/NowPlayingViewModel.swift`
  — Combine publishers merge NotificationCenter events into `@Published`
  properties; the view model is 100 % source-agnostic through `PlaySourceViewModel`.
- State restoration: `PC: Pocket Casts Watch App/UI/State Restoration/Restorable.swift`
  — an `onAppear` modifier writes the page name to UserDefaults;
  `ExtensionDelegate.restorePreviousStateIfRequired()` +
  `PC: Pocket Casts Watch App/UI/Navigation/NavigationManager.swift` navigate
  back on launch. Dead simple; copy the shape.
- Image caching: `PC: Pocket Casts Watch App/Data & Communication/WatchImageHelper.swift`
  — disk cache 30 MB / 45-day expiry; memory limits tuned DOWN for older
  hardware. Principle to keep: watch image budgets are set per device class.

### 2.6 What NOT to copy

- Stringly-typed dictionary protocol (`WatchConstants`) → use Codable structs (D3).
- The whole-blob-in-UserDefaults key naming (`"data"`) — fine mechanism, but
  give it a proper store type with typed accessors.
- ClockKit complication assets (`Complication/ComplicationController.swift`,
  the `Complication.complicationset`) — ClockKit is deprecated; use WidgetKit
  accessory widgets (Phase 4).
- Feature-flag sync from phone to watch (`updateFeatureFlags`) — Autohop has no
  feature-flag system; skip.
- Their login/subscription gating (`SourceInterfaceModel.watchTapped()` requires
  Plus) — Autohop's standalone mode has no account to gate on (D10).

---

## 3. Mapping Pocket Casts concepts onto Autohop

| Pocket Casts | Autohop equivalent | Notes |
|---|---|---|
| `PlaybackManager.shared` | `App/AppState.swift` (@MainActor coordinator) + `Playback/PlaybackEngine.swift` | AppState is the only PlaybackEngine caller; the watch bridge must go through AppState, never the engine directly |
| Phone-side `WatchManager` | NEW `Watch/WatchBridge.swift` (phone target) | Model on `NowPlaying/NowPlayingService.swift`: singleton bridge, wired once in `AppState.bootstrap()`, pushed on the same tick/transition points |
| NotificationCenter fan-out triggers | AppState closure/observable hooks | Autohop doesn't use NotificationCenter for app events; add explicit `watchBridge.pushState()` calls at the same points AppState updates NowPlayingService |
| Up Next (stored, user-ordered list) | **Derived** Priority Stack: `Queue/QueueService.swift` + AppState pinned-ID overrides (`orderedQueueWithOverrides()`, memoized `cachedDownloadedQueue`) | Biggest semantic difference — see D4 |
| Episode `uuid` (server-global) | `Episode.id` (local UUID) | Fine for remote mode: the phone resolves its own IDs. Phase 3 cross-device identity rides on existing CloudKit record naming (`SYNC_DESIGN.md`) |
| Effects (speed / trim / boost) | Per-podcast speed, Trim Silence, Vocal Boost (`Models/PlaybackPreference.swift`, applied live via AppState) | Availability flags per source; see D7 |
| Podcast tint colour (server-computed, sent as hex) | Derive from artwork or use Autohop accent | Send optional hex in the snapshot; fall back to accent colour |
| `WatchConstants` message version `"wappv4"` | `WatchShared/WatchProto.swift` `protocolVersion` | Codable, versioned from day one |
| Their server sync on watch (Plus-gated) | `Persistence/CloudSyncEngine.swift` (CKSyncEngine) on watchOS | Autohop's structural advantage; see D10 |
| `DownloadManager` (watch build) | `Downloads/DownloadManager.swift` compiled for watchOS | Needs `WKURLSessionRefreshBackgroundTask` routing added (Phase 3) |

### Design decisions (locked unless Kevin overrides)

- **D1 — Remote-first.** Phases 1–2 ship with no watch database, no watch audio.
- **D2 — Adopt the `PlaySource` protocol in Phase 1**, even with only one
  implementation. Retro-fitting it later means rewriting every view model.
  Name it `WatchPlaySource` (protocol) / `PhonePlaySource` / `LocalPlaySource`.
- **D3 — Codable wire protocol.** One shared file (`WatchShared/WatchProto.swift`)
  compiled into BOTH the iOS and watchOS targets defines:
  `WatchStateSnapshot` (version, timestamp, now-playing struct, queue-item
  array, settings struct) and `WatchCommand` (enum with associated values).
  Encode with `JSONEncoder` into a single `Data` value inside the WCSession
  dictionary. Include `protocolVersion: Int`; the receiver ignores payloads
  with a newer major version.
- **D4 — The watch never mutates queue order directly.** Autohop's queue is
  derived (Priority Stack), not a stored list. The snapshot carries the
  *computed* `downloadedQueue` (top ~25 items: episodeID, title, podcast title,
  duration remaining, artwork URL). Watch actions are **intents** — `.playNow`,
  `.playNext`, `.playLast`, `.archive`, `.markPlayed` — that the phone applies
  through the exact same AppState methods CarPlay uses
  (`episodeIsCurrent(_:)`, `archiveCurrentEpisodeAndPlayNext()`, pinned-ID
  overrides). CarPlay already proved AppState can host a second UI surface this
  way; the watch is the third.
- **D5 — Don't stream the 2 Hz clock over WCSession.** Send position in the
  snapshot on transitions (play/pause/seek/episode change) plus a low-frequency
  periodic save (piggyback on AppState's existing persistence cadence). While
  `isPlaying`, the watch interpolates elapsed time locally with a 1 s
  `TimelineView`/timer against `snapshot.position + (now - snapshot.timestamp) × speed`.
  This mirrors why AppState's PERF-1 fix exists — do not re-create the
  over-invalidation problem over Bluetooth.
- **D6 — Video episodes:** in remote mode they behave identically to audio (the
  phone is doing the playing). In Phase 3 standalone mode, filter video
  episodes out of watch-local lists and badge them "iPhone only".
- **D7 — Trim Silence / Vocal Boost:** expose `trimSilenceAvailable` /
  `vocalBoostAvailable` on the source protocol from day one. Phase 1 v1 sets
  them false everywhere (keep the surface minimal); a later remote-mode
  Effects screen can flip them true for `PhonePlaySource` (Pocket Casts
  supports exactly this — toggles send commands, state comes back in the blob).
  `LocalPlaySource` (Phase 3) keeps them **false permanently**: the
  AVAudioEngine path in `Playback/PlaybackEngine.swift` is the most
  hardware-sensitive code in the app, and Pocket Casts shipping watch-local
  playback *without* these effects is strong evidence not to try (their
  `WatchSourceViewModel.swift` lines 45–55: hardcoded false + noop setters).
- **D8 — Deployment target watchOS 10.0** (matches iOS 17 baseline; gives
  `@Observable`, NavigationStack, `containerRelativeFrame`, WidgetKit
  accessories). Use `@Observable` view models, not ObservableObject/Combine —
  Pocket Casts' Combine bridging is a legacy artifact, and DEEP_SCAN PERF-1
  already pushed Autohop toward `@Observable`. Gate double-tap
  (`handGestureShortcut`) behind `#available(watchOS 11.0, *)`.
- **D9 — MPL:** this doc authorises pattern reuse only. Any verbatim port
  triggers the NOTICE/AcknowledgementsView/file-header process (§0.3).
- **D10 — Standalone mode is free.** Pocket Casts gates watch-local playback
  behind Plus because it requires *their sync server*. Autohop's sync is
  CloudKit (`Persistence/CloudSyncEngine.swift`), and CKSyncEngine is available
  on watchOS 9.1+, so a standalone watch app can sync subscription/episode
  state through the same private zone with no account and no server. This is a
  genuine competitive differentiator — Apple Watch podcast playback without a
  subscription. Keep it free.

---

## 4. Phase 0 — Target scaffolding

**Goal:** an empty watch app that builds, installs, and shows a placeholder
screen, plus the shared protocol module. No behaviour.

### Work items

1. **`project.yml`**: add two targets (XcodeGen `platform: watchOS`):
   - `AutohopWatch` — `type: application`, `platform: watchOS`,
     `deploymentTarget: "10.0"`, bundle ID `com.kevinperry.autohop.watchkitapp`
     (watchOS 9+ single-target app; no separate extension target needed),
     `TARGETED_DEVICE_FAMILY: "4"`, `DEVELOPMENT_TEAM: QT3N6256FG`,
     `WKCompanionAppBundleIdentifier: com.kevinperry.autohop` and
     `WKRunsIndependentlyOfCompanionApp: false` (flip to true in Phase 3) in
     generated Info properties. `MARKETING_VERSION` must match the iOS app.
   - Embed: add the watch app product to the `Autohop` target's dependencies
     (XcodeGen `dependencies: - target: AutohopWatch` with `embed: true`
     on the iOS target).
   - Sources for `AutohopWatch`: new `Watch/App/` directory + shared
     `WatchShared/` directory (see next item). Do NOT include the full app
     source tree.
2. **`WatchShared/`** (new top-level directory, compiled into BOTH targets):
   - `WatchProto.swift` — `protocolVersion`, `WatchStateSnapshot`,
     `WatchNowPlayingInfo`, `WatchQueueItem`, `WatchCommand`, and the
     encode/decode helpers (single `Data` payload under one dictionary key,
     plus a plain `timestamp` key readable without decoding).
   - Add `WatchShared/**` to the `Autohop` target sources in `project.yml`
     (it currently globs `path: .`, so it's included automatically — verify
     the excludes list doesn't catch it) and to `AutohopWatch` sources.
   - Add `WatchShared` to `Package.swift` test paths so codec round-trip smoke
     tests run headless (`swift run`-style, per the existing SmokeTests pattern).
3. **Watch app shell** (`Watch/App/`):
   - `AutohopWatchApp.swift` — `@main App`, `@WKApplicationDelegateAdaptor`.
   - `WatchExtensionDelegate.swift` — empty lifecycle stubs (filled in Phase 1/3).
   - Placeholder root view.
   - Watch asset catalog with the watch app icon (single 1024 pt icon; derive
     from `Design/AppIcon/autohop-icon-v1.svg`).
4. `xcodegen generate`; Kevin opens Xcode, confirms signing for the new target,
   runs on watch simulator.

**Reference files:** `PC: Pocket Casts Watch App/UI/PocketCastsApp.swift`,
`PC: Pocket Casts Watch App/Info.plist`.

**Verification:** iOS app still builds and behaves identically (watch target
must not disturb the iOS target's source globs); watch simulator shows the
placeholder; codec smoke test round-trips a snapshot.

**Non-goals:** any WCSession code.

---

## 5. Phase 1 — Remote control (Now Playing)

**Goal:** open the watch app, see what the phone is playing, control it.
The single highest-value watch use case (AirPods on a walk/gym, phone in a
pocket or across the room).

### 5.1 Phone side — `Watch/WatchBridge.swift` (iOS target)

Model directly on `NowPlaying/NowPlayingService.swift` (read its AI CONTEXT
header first): singleton, `configure(...)` wired once from `AppState.bootstrap()`,
state pushed from AppState at explicit points.

- **WCSession lifecycle:** `WCSession.isSupported()` guard, delegate set +
  `activate()` once; implement `sessionDidBecomeInactive` /
  `sessionDidDeactivate` (re-activate) for watch switching. Serialise ALL
  session work through one serial queue with a `dispatchPrecondition`, exactly
  like `PC: podcasts/Watch Communication/WatchManager.swift` (`sessionQueue`).
  Skip sends entirely unless `activationState == .activated && isPaired &&
  isWatchAppInstalled` (same guard as PC `sendStateToWatch`, line ~552).
- **Snapshot content** (`WatchStateSnapshot`): now-playing episode (id, title,
  podcast title, artwork URL, optional tint hex), `isPlaying`, position,
  duration, speed, skip-forward/back intervals from AppSettings, chapter title
  + hasChapters, queue item array (top ~25 of `downloadedQueue` — needed in
  Phase 2 but cheap to include now), snapshot timestamp, `protocolVersion`.
- **Push triggers:** call `WatchBridge.shared.pushState()` from AppState at the
  same transition points that update NowPlayingService: playback
  start/pause/finish, seek, episode change, speed/effects change, queue
  change (the synchronous `cachedDownloadedQueue` invalidation points), and
  the periodic position-persist cadence. Do NOT hook the 2 Hz PlaybackClock (D5).
  Debounce pushes (~0.5 s trailing) so a burst of queue mutations sends once.
- **Delivery tiering** (replicate PC exactly): reachable → `sendMessage` (no
  reply handler); unreachable → `updateApplicationContext`. On
  `WCErrorCodePayloadTooLarge`, retry once with the queue array truncated
  (log it — mirrors PC `payloadTooLargeFallbackLimit` handling). Also push on
  `sessionReachabilityDidChange` → reachable, and on `sessionWatchStateDidChange`.
- **Command handling:** one unified `handle(command:)` used by both
  `didReceiveMessage` and `didReceiveUserInfo` (PC `handleWatchAction` pattern).
  Every command dispatches to `@MainActor` AppState methods — the same surface
  CarPlay uses. Phase 1 commands: `.togglePlayPause`, `.skipForward`,
  `.skipBack`, `.setSpeed(Double)`, `.nextChapter`, `.previousChapter`,
  `.requestState` (wake-up: reply is a fresh push).

### 5.2 Watch side — `Watch/` (watchOS target)

- `Watch/Session/WatchSessionManager.swift` — WCSession delegate. Receives
  snapshot via both `didReceiveApplicationContext` and `didReceiveMessage`;
  **timestamp guard** before accepting (PC `SessionManager.handleStateUpdate`
  — discard if `timestamp <= lastProcessed`). Persist the raw snapshot `Data`
  to UserDefaults so launch renders instantly offline. On activation with no
  stored snapshot, send `.requestState` (PC `setup()` pattern).
- `Watch/Session/SnapshotStore.swift` — `@Observable` holder of the decoded
  `WatchStateSnapshot`; the watch-side model layer (analogue of PC
  `WatchDataManager`, but typed).
- `Watch/PlaySource/WatchPlaySource.swift` — the protocol (D2):
  now-playing metadata accessors, `togglePlayPause()`, `skip(forward:)`,
  `changeChapter(next:)`, `setSpeed(_:)`, queue accessors, episode intents,
  availability flags. `Watch/PlaySource/PhonePlaySource.swift` implements it
  over SnapshotStore + WatchSessionManager sends. (Reference:
  `PC: .../PhoneSourceViewModel.swift` for exactly which calls read the blob
  vs. send a message.)
- **Now Playing screen** (`Watch/Views/NowPlayingView.swift` + `@Observable`
  view model): copy the PC three-group layout (§2.5). Specifics:
  - Progress bar tinted with snapshot tint; title 1-line; time-remaining label.
  - Skip buttons show the user's configured intervals (values from snapshot).
  - Position interpolation while playing (D5): `TimelineView(.periodic(1s))`.
  - Haptic `.click` on every button; `.handGestureShortcut(.primaryAction)`
    on play/pause behind `#available(watchOS 11.0, *)`.
  - Crown volume: port the `WKInterfaceObjectRepresentable` wrapper from
    `PC: .../VolumeControl.swift` with origin `.companion` (trivial file —
    re-implement, don't copy, per D9).
  - Speed control: tap-to-cycle using the same increments as
    `AppState.cyclePlaybackSpeedForCurrentEpisode()` semantics, applied via
    `.setSpeed` command.
  - Empty state when snapshot has no now-playing episode ("Play something on
    your iPhone") — PC has `NowPlayingEmptyView.swift` for reference.
- **Auto-launch:** implement `handleRemoteNowPlayingActivity()` in the watch
  extension delegate → navigate to Now Playing (PC `ExtensionDelegate.swift`
  line ~42). This is what makes the watch app appear "already open on the
  right screen" when playback starts on the phone.
- **Artwork:** load via `AsyncImage`/URLSession from the artwork URL with a
  small disk cache; budget per PC `WatchImageHelper` (≤ 30 MB disk). Artwork is
  fetched from the network by the watch itself (via phone proxying) — do NOT
  ship image bytes through WCSession snapshots.

**Verification:** phone plays → watch reflects within ~1 s when reachable;
airplane-mode phone → watch shows last state and controls queue up nothing
(fire-and-forget tier drops silently); backgrounded watch app receives context
update and shows fresh state on next open; position drifts < 2 s over a
5-minute interpolation window; watch-initiated play/pause round-trips.

**Non-goals:** queue view, episode actions, any list UI, effects toggles.

---

## 6. Phase 2 — Queue + episode actions + restoration

**Goal:** see the Priority Stack, act on it. Completes the shippable v1.

### Work items

1. **Queue view** (`Watch/Views/QueueView.swift`): renders
   `snapshot.queueItems` (already pushed in Phase 1). Row = artwork thumb,
   title, podcast, time remaining — match the phone's Queue page patterns
   (`DESIGN.md` ListRow-Standard) at watch scale. Reference for watch list
   ergonomics: `PC: .../UI/Episode Lists/Up Next/UpNextView.swift` and
   `EpisodeRow.swift`.
2. **Episode intents** with guaranteed delivery: `.playNow(episodeID)`,
   `.playNext(episodeID)`, `.playLast(episodeID)`, `.archive(episodeID)`,
   `.markPlayed(episodeID)`. Send via **sendMessage-with-transferUserInfo
   fallback** (PC `sendWithFallback`, §2.3 tier 2) — a user archiving three
   episodes on a run with the phone unreachable must have all three apply when
   the phone reconnects. Phone-side handler applies them through AppState's
   CarPlay-proven methods (D4). Episode-not-found (queue changed since
   snapshot) is logged and dropped silently, matching PC's
   `handleAddToUpnext` guard behaviour.
3. **Action UX:** long-press/ellipsis per row → action list; archive on the
   *current* episode from Now Playing (maps to
   `AppState.archiveCurrentEpisodeAndPlayNext()`, same as CarPlay).
   Use `requiresConfirmation(forAction:)` on the protocol for destructive
   actions (PC pattern) — v1: archive requires no confirmation (matches phone
   swipe), nothing else is destructive.
4. **Up Next count badge** on Now Playing navigating to QueueView (PC
   `NowPlayingControls.navigationGroup`).
5. **State restoration:** `restorable(_:)`-style `onAppear` modifier writing
   the current page to UserDefaults; navigate back on cold launch
   (PC `Restorable.swift` + `ExtensionDelegate.restorePreviousStateIfRequired`
   + `NavigationManager.swift`). Use a NavigationStack path enum, not PC's
   WKInterfaceController plumbing.
6. **Root structure:** watchOS 10 `TabView`/vertical pagination:
   Now Playing ⇄ Queue (crown-swipeable pages), matching how PC pages between
   its main menu and Now Playing.

**Verification:** every intent applies correctly with phone reachable AND with
phone temporarily unreachable (fallback queue drains on reconnect); queue view
matches phone order including Play Next/Play Last pins; restoration returns to
Queue after app relaunch; snapshot stays under WCSession payload limits with a
100-episode queue (truncation to ~25 enforced phone-side).

**Ship gate:** Phases 1+2 together = App Store-ready watch v1. Update
`FEATURES.md`, `SupportContent.swift` + website `support.html` (§0.6), and App
Store metadata/screenshots before release.

---

## 7. Phase 3 — Standalone playback (separate product decision)

**Goal:** phone-free listening: downloaded episodes on the watch, played
locally to AirPods, state synced via CloudKit. Do not start without an explicit
go decision — this phase carries most of the risk.

### 7.1 Source toggle

- Persisted `.phone`/`.watch` source enum + main-screen toggle
  (PC `SourceManager.swift` + `SourceInterfaceModel.swift`). Implement the
  divergence guard: when switching sources and the now-playing episodes/positions
  differ, reconcile via CloudKit sync before switching (PC
  `nowPlayingEpisodesMatchOnBothSources()` — theirs syncs through their server;
  Autohop's equivalent is a CKSyncEngine `fetchChanges`/push cycle).
- `LocalPlaySource: WatchPlaySource` — second protocol implementation; the
  Phase 1–2 UI gets standalone mode for free (D2 payoff).

### 7.2 AutohopCore on watchOS — compilation audit

Add watchOS to `Package.swift` platforms; compile the minimum module set into
`AutohopWatch`. Expected status per file (verify at implementation time):

| File | watchOS status |
|---|---|
| `Persistence/AutohopDatabase.swift` (GRDB) | ✅ GRDB supports watchOS |
| `Queue/QueueService.swift` | ✅ pure logic |
| `Models/*` | ✅ pure |
| `Feeds/RSSParser.swift`, `FeedService.swift`, `EpisodeFeedLoader.swift` | ✅ URLSession/XMLParser — but see 7.5 for whether the watch refreshes feeds at all |
| `Persistence/CloudSyncEngine.swift` | ⚠️ CKSyncEngine exists on watchOS 9.1+; remote-notification wake needs the watch app's own push registration; audit `WKApplication` vs `UIApplication` references |
| `Downloads/DownloadManager.swift` | ⚠️ background URLSession works, but completion routing arrives as `WKURLSessionRefreshBackgroundTask` — add a watch path (§7.3) |
| `Playback/PlaybackEngine.swift` | ⚠️ AVPlayer path only (D7). Consider extracting `WatchPlaybackEngine` implementing the same `PlaybackControlling` surface minus engine-path features rather than `#if os(watchOS)` riddling the shared file |
| `App/AppState.swift` | ❌ do NOT compile for watch (4.6k-LOC iOS god object, DS-GOD). Build a small `WatchAppModel` owning database + queue + playback + sync for the watch |

### 7.3 Watch downloads

- Auto-download top N of the Priority Stack (N user-set on the phone, sent in
  the snapshot; default 5), auto-delete downloaded-for-watch files that fall
  below the top M — re-implement the algorithm shape of
  `PC: .../WatchSyncManager+Autodownload.swift` over `QueueService` output.
  §0.7 applies: the newest episode of the highest-priority podcast is always
  first in line.
- Lifecycle: `applicationWillResignActive` → hand foreground downloads to the
  background session (PC `transferForegroundDownloadsToBackground()`);
  `handle(backgroundTasks:)` routes `WKURLSessionRefreshBackgroundTask` by
  session identifier to DownloadManager (PC `ExtensionDelegate.handle`, §2.4).
- Storage budget: cap watch media (e.g. 1–2 GB or N-episode ceiling);
  downloads are device-local and never sync (SYNC_DESIGN.md invariant holds).
- Battery/route reality: watch downloads over Bluetooth-via-phone are slow;
  Wi-Fi direct is better; charging + Wi-Fi is the happy path. Schedule the
  auto-download check on `WKApplicationRefreshBackgroundTask` (60-min
  reschedule loop, PC `scheduleNextRefresh()`).

### 7.4 Playback + sync

- `WatchPlaybackEngine`: AVPlayer over the local file; speed via `rate`; audio
  session `.playback` + `AVAudioSession.RouteSharingPolicy` correctness for
  AirPods; Now Playing card via `MPNowPlayingInfoCenter` (port the *shape* of
  `NowPlaying/NowPlayingService.swift`).
- No Trim Silence / Vocal Boost locally, permanently (D7). Per-podcast *speed*
  DOES apply (plain rate).
- Position/played-state writes go through the same `@Synced` field-LWW model
  so CloudKit reconciles watch-vs-phone listening exactly like a second phone
  (SYNC_DESIGN.md). Stats: watch counts as its own device (stats are
  per-device, additive — existing design already accommodates this).

### 7.5 Open questions (resolve before Phase 3 build)

1. **Does the watch refresh RSS feeds itself?** Options: (a) no — episode
   catalog arrives via CloudKit-synced subscription/episode state + phone
   pushes, watch only downloads enclosures (simpler, but new-episode discovery
   stalls when the phone is away for days); (b) yes — run `EpisodeFeedLoader`
   for subscribed feeds in the background refresh window (PC does full refresh
   on watch; heavier). Recommendation: start with (a); catalog data already
   flows through CloudKit for episode user-state, and standalone runs are
   typically hours, not days.
2. **iCloud sync opt-in:** CloudSyncEngine is opt-in on the phone. Standalone
   watch mode with sync disabled = watch and phone states drift with no
   reconciliation. Options: require iCloud sync ON to enable watch standalone
   mode (recommended, matches how the feature is honest about its mechanics),
   or build a WatchConnectivity-only reconciliation (extra protocol surface;
   avoid).
3. Whether `WKRunsIndependentlyOfCompanionApp = true` + standalone App Store
   distribution is wanted at all, or standalone mode still assumes the iPhone
   app exists.

### 7.6 Risks

- PlaybackEngine extraction is the largest refactor; keep `PlaybackControlling`
  as the seam and change nothing behaviourally on iOS.
- CKSyncEngine push wake-ups on watchOS are less reliable than iOS; sync
  convergence may lean on foreground fetches. LWW field merges make this safe,
  just latent.
- Watch storage/battery constraints turn edge cases (100-episode queues, video
  episodes, 3-hour shows) into support tickets — scope lists and budgets hard.

---

## 8. Phase 4 — Polish

- **WidgetKit accessory widgets / Smart Stack** (NOT ClockKit): now-playing
  card with play state + relevance so it surfaces during playback; circular
  complication that launches the app. (Replaces what PC does in
  `Complication/ComplicationController.swift` with the modern API.)
- **App Intents**: "Resume playback", "Play <podcast>" for watch Siri; shares
  intent definitions with any future iOS App Intents work.
- **Watch settings screen**: auto-download count (Phase 3), haptics toggle.
- **Effects screen for remote mode** (flip D7 availability for `PhonePlaySource`):
  Trim Silence / Vocal Boost toggles + speed stepper, PC-style
  (`PC: .../UI/Effects/EffectsView.swift`).
- **Dynamic Type audit** on all watch screens (UI1 applies to the watch too).
- Sleep Timer remote control from the watch.

---

## 9. Documentation & QA obligations (every phase)

- Update `FEATURES.md` (new §: Apple Watch) and this doc's phase status lines
  at each phase completion.
- New watch files get AI CONTEXT headers on creation; touched AppState/
  DownloadManager/PlaybackEngine headers get updated (§0.4).
- Headless smoke tests for: proto codec round-trip + version tolerance,
  snapshot serialiser (given AppState-shaped inputs → expected snapshot),
  queue-item mapping, and (Phase 3) the auto-download top-N/delete algorithm.
  These all live in package-compilable files per §0.2.
- Manual QA matrix per phase: reachable / unreachable / phone-app-killed /
  watch-app-cold-launch / both-backgrounded; document results in a
  `WATCH_PHASE<N>_QA.md` following `Docs/CARPLAY_PHASE9_QA.md` precedent.

---

## 10. Quick pointer index (Pocket Casts clone)

| Pattern | File (relative to `~/Developer/GitHub/pocket-casts-ios/`) |
|---|---|
| Source-agnostic UI protocol | `Pocket Casts Watch App/UI/Play Source/PlaySourceViewModel.swift` |
| Remote-mode implementation | `Pocket Casts Watch App/UI/Play Source/PhoneSourceViewModel.swift` |
| Local-mode implementation (incl. disabled effects) | `Pocket Casts Watch App/UI/Play Source/WatchSourceViewModel.swift` |
| Source enum + persistence | `Pocket Casts Watch App/UI/SourceManager.swift` |
| Source toggle + divergence guard | `Pocket Casts Watch App/UI/Main Page/SourceInterfaceModel.swift` |
| Phone-side state push, delivery tiering, payload fallback, session threading | `podcasts/Watch Communication/WatchManager.swift` |
| Phone-side unified command handler | `podcasts/Watch Communication/WatchManager.swift` (`handleWatchAction`) |
| Wire protocol + versioning | `podcasts/WatchConstants.swift` |
| Watch-side receive + timestamp staleness guard | `Pocket Casts Watch App/Data & Communication/SessionManager.swift` |
| Watch-side command tiers (fire-and-forget / guaranteed / request-reply) | `Pocket Casts Watch App/Data & Communication/SessionManager+Send.swift` |
| Watch-side blob accessors (no-DB model layer) | `Pocket Casts Watch App/Data & Communication/WatchDataManager.swift` |
| Lifecycle: background tasks, download handoff, auto-launch deep link, refresh scheduling | `Pocket Casts Watch App/UI/ExtensionDelegate.swift` |
| Queue auto-download/auto-delete on watch | `Pocket Casts Watch App/UI/WatchSyncManager+Autodownload.swift` |
| Debounced context processing | `Pocket Casts Watch App/UI/WatchSyncManager.swift` |
| Now Playing layout, haptics, double-tap | `Pocket Casts Watch App/UI/Now Playing/Interface/NowPlayingControls.swift` |
| Source-agnostic Now Playing view model | `Pocket Casts Watch App/UI/Now Playing/Interface/NowPlayingViewModel.swift` |
| Crown volume control | `Pocket Casts Watch App/UI/SwiftUI/VolumeControl.swift` |
| State restoration | `Pocket Casts Watch App/UI/State Restoration/Restorable.swift`, `UI/Navigation/NavigationManager.swift` |
| Watch image cache budgets | `Pocket Casts Watch App/Data & Communication/WatchImageHelper.swift` |
| Up Next list UI | `Pocket Casts Watch App/UI/Episode Lists/Up Next/UpNextView.swift` |
| Effects screen (Phase 4 reference) | `Pocket Casts Watch App/UI/Effects/EffectsView.swift` |
