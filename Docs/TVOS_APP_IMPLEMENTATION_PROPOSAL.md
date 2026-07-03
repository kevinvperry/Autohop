# Autohop tvOS App — Implementation Proposal

<!--
AI CONTEXT — Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md

PURPOSE: Full implementation proposal for an Autohop tvOS app (audio + video
playback on modern Apple TV), derived from (a) a file-level review of the
Pocket Casts TV app in the local clone at ~/Developer/GitHub/pocket-casts-ios,
(b) current tvOS platform constraints (purgeable storage, Liquid Glass /
tvOS 26 design), and (c) an audit of Autohop's multi-platform seams. Includes
the cross-platform codebase refactor (Phase 0) that also benefits iPhone,
iPad, CarPlay, and the planned watch app.

STATUS: PROPOSAL — no tvOS code exists yet. Phase 0 (platform foundation) is
prerequisite work in the EXISTING iOS codebase; it must land and be verified
on iPhone before any tvOS UI is built.

RELATED: Docs/WATCH_APP_IMPLEMENTATION_PROPOSAL.md — the watch proposal
defines the WatchPlaySource pattern and D-series decisions this doc extends
(decision numbering here is T-series). Phase 0 in THIS doc supersedes the
watch doc's §7.2 module-audit approach: both platforms consume the same
AutohopCore platform matrix once Phase 0 lands.

HOW TO USE: Execute phases in order. Before writing code in a phase, read the
"Reference files" cited for it (PC: paths are relative to the Pocket Casts
clone root) and the Autohop files named in §4. Follow §0 constraints at all times.
-->

Source inputs:

- Pocket Casts iOS repo, local clone: `~/Developer/GitHub/pocket-casts-ios`,
  TV target `Pocket Casts TV App/` (a genuinely modern reference: `@Observable`,
  tvOS 18 `Tab` API, `onScrollGeometryChange`, focus sections, `AVPlayerViewController`
  with custom transport menus). Pointers written `PC: <path>`.
- Autohop architecture: `App/AppState.swift`, `Playback/PlaybackEngine.swift`,
  `Queue/QueueService.swift`, `Persistence/CloudSyncEngine.swift`,
  `Persistence/SubscriptionStore.swift`, `Feeds/*`, `NowPlaying/NowPlayingService.swift`,
  `project.yml`, `Package.swift`.
- Autohop product docs: `FEATURES.md`, `DESIGN.md`, `SYNC_DESIGN.md`,
  `FUTURE_VERSIONS.md` (Tier 1 "Streaming / instant play" — Phase 0 here
  builds its foundation), `Docs/WATCH_APP_IMPLEMENTATION_PROPOSAL.md`,
  `Docs/CARPLAY_IMPLEMENTATION_STRATEGY.md`.
- Platform research (2026-07): tvOS purgeable-storage rules (Apple: ~500 KB
  durable UserDefaults; all other local data must be purgeable when the app
  isn't running — https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/ ,
  https://developer.apple.com/forums/thread/16967 ); tvOS 26 Liquid Glass +
  `sidebarAdaptable` TabView guidance
  ( https://developer.apple.com/documentation/SwiftUI/Enhancing-your-app-content-with-tab-navigation ,
  https://www.donnywals.com/exploring-tab-bars-on-ios-26-with-liquid-glass/ ,
  https://github.com/conorluddy/LiquidGlassReference ).

---

## 0. Global constraints (apply to every phase)

1. **XcodeGen**: all targets/files go through `project.yml` + `xcodegen generate`.
   Never edit `Autohop.xcodeproj`.
2. **No AI-run builds**: Kevin compiles in Xcode. Reason hard about
   compile-correctness (implicit-return footgun). Keep platform-neutral logic in
   SwiftPM-compilable files and extend the headless `*SmokeTests` executables.
3. **MPL-2.0 discipline**: this doc authorises *pattern* reuse from Pocket Casts
   only. Any verbatim port → NOTICE + AcknowledgementsView + MPL file header,
   per the existing covered-file process.
4. **Docs + headers workflow**: read AI CONTEXT headers before editing, update
   headers + docs after. Phase 0 touches core iOS files — their headers MUST
   record the extraction.
5. **Main branch only** unless Kevin says otherwise. Phase 0 is a large
   refactor — propose a branch to Kevin before starting; do not branch unilaterally.
6. **Support page mirror**: `Settings/SupportContent.swift` + website
   `support.html` update together when TV behaviour ships.
7. **Zero iPhone regressions**: Phase 0 must be behaviour-preserving on iOS.
   Every extraction step keeps the existing views compiling against the same
   AppState surface (facade pattern, §5.2).
8. **tvOS storage rule** (platform fact, not a choice): only ~500 KB of
   UserDefaults is durable; Caches and everything else may be purged whenever
   the app isn't running. Design every tvOS feature to survive a full local
   wipe between launches (T2).

---

## 1. Strategy summary

Autohop tvOS is a **lean-back browse-and-play surface over the user's existing
library**, streaming-first, with video as the showcase. It is NOT the iPhone
app on a TV: no downloads UI, no settings farm, no stats dashboards, no
onboarding carousel.

| Phase | Ships | Platform(s) affected | Status |
|---|---|---|---|
| 0 | Platform foundation: AutohopCore matrix, AppState domain extraction, streaming playback source | iOS (refactor), unblocks tvOS/watch/iPad | Not started |
| 1 | tvOS target scaffolding + purge-resilient bootstrap | tvOS | Not started |
| 2 | Browse UI: Home, Queue, Library, episode lists (read-only) | tvOS | Not started |
| 3 | Playback: audio + video streaming player, position sync | tvOS | Not started |
| 4 | Discovery + subscribe on TV, Top Shelf, polish | tvOS | Not started |
| 5 | Follow-on: iPad enablement (optional, separate go) | iPadOS | Not started |

**The first tvOS release (Phases 1–3) supports:**

- Home: Continue Listening (resume current episode), the Priority Stack queue
  as a browsable shelf, latest episodes per subscription.
- Library: subscription grid → episode lists (artwork-forward cards).
- Full-screen playback of **audio and video** episodes, streamed from the
  enclosure URL: play/pause, scrub, skip ±N (user's intervals), playback speed,
  chapter markers in the transport bar, auto-advance to the next queue episode.
- Library + playback state arrives via the existing opt-in CloudKit sync;
  position/played updates written back through the same field-LWW model.
- Liquid Glass-native UI: standard components, `sidebarAdaptable` TabView,
  focus-driven cards.

**The first tvOS release does not support:**

- Downloads or a downloads UI (streaming only — T2/T3).
- Trim Silence and Vocal Boost (need complete local files + AVAudioEngine; see T4).
- Search/discovery/subscribe (arrives Phase 4), OPML, feed management.
- Stats dashboards, listening history UI, sleep timer/schedule, notifications,
  onboarding, sharing, per-podcast settings editing.
- Accounts of any kind (Autohop has none — the QR sign-in machinery that
  dominates the Pocket Casts TV app simply doesn't exist here).

---

## 2. Reference architecture — the Pocket Casts TV app

What to take (and skip) from `PC: Pocket Casts TV App/`. It is their newest
target and uses current APIs throughout — read it as "modern tvOS idiom",
not legacy.

### 2.1 App shell and navigation

- `PC: Pocket Casts TV App/PocketCastsTVApp.swift` — SwiftUI `@main`, forces
  `.preferredColorScheme(.dark)` (correct for TV), scene-phase analytics only.
  No AppDelegate at all.
- `PC: Pocket Casts TV App/UI/RootView.swift` — a tiny `@Observable`
  `AppCoordinator` state machine (`loading / welcome / browsing / signedIn`)
  injected via `.environment(...)`. Autohop's equivalent collapses to
  `loading / ready / empty` (no auth states).
- `PC: Pocket Casts TV App/UI/MainTabView.swift` — the navigation reference:
  - tvOS 18 `Tab(value:)` TabView with typed `MainTab` enum + router object.
  - `@FocusState` areas (`tabBar / profile / content`), `defaultFocus`,
    `.focusSection()`, `onMoveCommand` for edge-of-tab-bar moves (note their
    async-dispatch comment: rapid Siri-remote moves read stale selection —
    keep that fix).
  - A top accessory row that parallax-scrolls away using
    `onScrollGeometryChange` scroll offsets from each tab's content.
  - `ChromelessButtonStyle` for artwork buttons where platform chrome is wrong.
- `PC: Pocket Casts TV App/UI/Home/HomeView.swift` — shelf-based Home:
  `ScrollView` of `HomeSection`s, each a `LazyHStack` shelf with
  `.focusSection()`; the hidden-copy title trick (lines ~229–240) that reserves
  space for the focus-enlarged section title so layout never jumps — copy this.
  Sections conditional on signed-in state; Autohop's Home is conditional on
  "has library" instead.
- `PC: Pocket Casts TV App/UI/Common/FocusStore.swift` — tracks which section
  has focus (drives the title-emphasis animation).
- `PC: Pocket Casts TV App/UI/Common/BlurredCoverBackground.swift` — blurred
  artwork backdrop; use behind Autohop's audio player and detail pages.

### 2.2 The player (the most valuable file in the target)

- `PC: Pocket Casts TV App/UI/Player/NowPlayingView.swift` — ONE player surface
  for audio AND video: `AVPlayerViewController` wrapped in
  `UIViewControllerRepresentable`, fed the app's own `AVPlayer` instance
  (`playbackManager.avPlayer`). Steal these techniques:
  - `transportBarCustomMenuItems` — playback-speed menu (1.0–3.0× in 0.1
    steps, `UIMenu` with `.singleSelection`) and an effects menu, living in the
    system transport bar. This is the modern way to expose app controls in the
    tvOS player.
  - `externalMetadata` (`AVMetadataItem`: title, subtitle, artwork data) so
    the system info panel shows episode metadata.
  - `contentOverlayView` + `UIHostingController` overlay (`MediaOverlayView`)
    — for audio episodes it renders artwork/title over the video surface, with
    visibility tied to the transport bar via
    `playerViewController(_:willTransitionToVisibilityOfTransportBar:)`.
  - Presented with `.fullScreenCover` + `.ignoresSafeArea()` from any row.
- `PC: Pocket Casts TV App/UI/Player/NowPlayingViewModel.swift` —
  `@Observable` model exposing the shared `AVPlayer`, artwork loading off-main,
  and speed/effects accessors that write through the playback manager.
- Their `PlaybackManager` exposes its underlying `AVPlayer` for exactly this
  purpose — the precedent for Autohop's T5 engine-exposure decision.

### 2.3 Data layer

- `PC: Pocket Casts TV App/Data/TVDataManager.swift` — thin async facade over
  the shared database/server managers; "load podcast if missing, then play".
  The TV target compiles the full shared stack (DataManager, PlaybackManager,
  DownloadManager) via file target-membership — the same
  member-everything approach that makes their AppState-equivalent portable is
  the thing Autohop should do *better* via SwiftPM (§5).
- `PC: Pocket Casts TV App/Pocket-Casts-TV-App-Info.plist` —
  `UIBackgroundModes: audio` (audio keeps playing when the user backs out to
  the tvOS home screen — declare this for Autohop too).

### 2.4 What NOT to copy

- The entire Auth flow (`UI/Auth/*`, QR sign-in, `UserStateModel`,
  welcome/sign-in coordinator states) — Autohop has no accounts; this is ~30 %
  of their target that simply disappears.
- Discover-server dependence (`Data/DiscoverManager.swift`,
  `DiscoverServerHandler`) — Autohop's discovery is `Feeds/PodcastCharts.swift`
  + `Feeds/PodcastSearch.swift` (iTunes/Apple endpoints, plain URLSession) and
  arrives only in Phase 4.
- Firebase/analytics scaffolding.
- No Top Shelf extension exists in their target — Autohop should ship one
  (Phase 4) and beat them here.

---

## 3. tvOS platform decisions (T-series, locked unless Kevin overrides)

- **T1 — Streaming-first.** tvOS storage is purgeable (§0.8): the
  download-first architecture cannot hold on this platform. Episodes stream
  from enclosure URLs via `AVPlayer`. The iPhone app's downloads never sync
  anyway (SYNC_DESIGN.md invariant). AVPlayer's own buffering is the only
  "download". This intentionally builds the streaming muscle that
  FUTURE_VERSIONS Tier 1 ("Streaming / instant play") wants on iPhone — Phase 0
  puts the capability in core where both platforms reach it.
- **T2 — The local database is a rebuildable cache.** GRDB works on tvOS, but
  the DB file lives in `Caches` and may vanish between launches. Source of
  durable truth on TV: (a) CloudKit private zone via `CloudSyncEngine`
  (subscriptions, episode user-state, positions — CKSyncEngine is tvOS 17+),
  (b) RSS re-fetch for catalog content, (c) a minimal "survival kit" in
  UserDefaults (< 500 KB durable): subscription feed URLs + priority ranks +
  iCloud-sync flag, so even a purged, sync-disabled TV can rebuild its library
  from RSS alone. Bootstrap must be re-entrant: cold launch with empty Caches
  is a NORMAL path, not an error path (Phase 1 deliverable).
- **T3 — No downloads UI on TV, ever.** Nothing to manage; storage rules make
  promises unkeepable.
- **T4 — No Trim Silence / Vocal Boost on TV** (extends watch decision D7).
  The AVAudioEngine path needs a complete local `AVAudioFile`; streaming has
  none. Speed works fine via `AVPlayer.rate` (defaultRateAtWhichToPlay). The
  per-source capability flags from the watch proposal
  (`trimSilenceAvailable` etc.) become a core `PlaybackCapabilities` value —
  one mechanism, three platforms (§5.4).
- **T5 — One player surface for audio and video**, `AVPlayerViewController`
  with `contentOverlayView` artwork for audio (PC §2.2 pattern). Do NOT build
  a custom SwiftUI transport for v1 — the system player is the modern, HIG-
  compliant, Liquid Glass-native answer and is what users expect on TV.
  Additions over PC: **chapter navigation markers**
  (`AVPlayerItem.navigationMarkerGroups` with `AVTimedMetadataGroup`s built
  from `Models/Chapter.swift`) so Autohop chapters appear as scrubbable
  chapter markers in the system transport bar; and `interstitialTimeRanges`
  stays empty (no ads concept).
- **T6 — Liquid Glass via standard components.** Target tvOS 26 SDK; adopt by
  using system components, not by hand-rolling glass: `TabView` +
  `.tabViewStyle(.sidebarAdaptable)` (sidebar that collapses to the floating
  pill on tvOS), standard buttons/cards with focus effects, `NavigationStack`,
  `.fullScreenCover` for the player, `searchable`/search `Tab` role when
  search ships (Phase 4). Custom `glassEffect()` only if a bespoke surface
  truly needs it. Dark scheme preferred (`.preferredColorScheme(.dark)`).
  **Deployment target: tvOS 17.0** (matches CKSyncEngine floor and the iOS 17
  baseline) with `#available(tvOS 18/26)` gates for `Tab(value:)`,
  `sidebarAdaptable`, `onScrollGeometryChange`; if Kevin prefers zero gates,
  raise the floor to tvOS 18 — decide at Phase 1 start.
- **T7 — TV requires iCloud sync OFF-ramp.** If iCloud sync is enabled
  (recommended path), the TV mirrors the iPhone library automatically. If the
  user declines sync, the TV still works standalone: subscribe on-TV (Phase 4)
  or rebuild from the T2 survival kit; state then lives on the TV only and the
  UI says so once (single non-nagging notice). Never block the app behind a
  sync prompt.
- **T8 — Focus-first UI.** Every interactive element must be reachable by the
  Siri Remote focus engine: `.focusSection()` per shelf, `defaultFocus` on the
  primary action, `onPlayPauseCommand` (play/pause from anywhere sensible),
  `onExitCommand` (Menu backs out of covers), no hover-only affordances, no
  gestures without button equivalents. Reserve-space-for-focused-title trick
  from PC `HomeSection` (§2.1) for all shelf headers.
- **T9 — TV is its own stats device.** Listening on TV writes per-device stats
  rows (existing additive model); no LWW conflict by design. Stats UI stays on
  iPhone.
- **T10 — Video is first-class.** Video episodes get equal billing in shelves
  (16:9 stills where available, else artwork), and the Home "Latest" shelf
  surfaces them identically. The iPhone's video-in-landscape special-casing is
  irrelevant here — TV IS the landscape surface.

---

## 4. Cross-platform codebase optimisation (the Phase 0 case)

Kevin's directive: optimise the existing codebase to support iPhone, iPad,
CarPlay, Apple Watch, and tvOS. Current state and the five moves that fix it:

### 4.1 Current state (what blocks a 5-surface Autohop today)

- `Package.swift` declares no tvOS/watchOS platforms; the app target compiles
  the whole source tree directly (`project.yml` globs `path: .`).
- `App/AppState.swift` is a 4.6k-LOC `@MainActor` god object (DEEP_SCAN
  DS-GOD): it owns domain logic (queue composition, playback orchestration,
  download gating, release radar) AND iOS UI concerns (scene phase, CarPlay
  routing, coach marks). Nothing else can compile it — the watch proposal
  already had to ban it (§7.2 there); tvOS would have to as well, and without
  extraction each new platform re-implements orchestration and drifts.
- `Playback/PlaybackEngine.swift` is iOS-only in practice (AVAudioEngine path,
  UIKit-adjacent session handling) but hides behind the `PlaybackControlling`
  protocol — the seam already exists and CarPlay proved AppState can host
  multiple UI surfaces over one model.
- There is no "play from URL" path — everything assumes a downloaded local file.

### 4.2 The five moves

1. **Platform matrix in `Package.swift`**: declare
   `platforms: [.iOS(.v17), .tvOS(.v17), .watchOS(.v10)]`; split targets so a
   clean `AutohopCore` library (Models, Persistence, Feeds, Queue, Sync,
   playback protocol + capabilities) compiles for all three, while iOS-only
   files (PlaybackEngine's engine path, UIKit helpers, views) stay out of it.
   Audit: every `import UIKit` in core files gets removed or `#if canImport`d.
2. **AppState decomposition (strangler-fig, facade-preserving)**: extract
   platform-neutral domain objects into AutohopCore —
   - `LibraryModel` (subscriptions + episodes read model over SubscriptionStore),
   - `QueueModel` (Priority Stack + pinned overrides + memoization — the logic
     currently in AppState around `orderedQueueWithOverrides()` /
     `cachedDownloadedQueue`),
   - `PlaybackSession` (current episode, position, speed, chapter state,
     auto-advance policy — the orchestration currently spread through
     `startPlayback` / `handleEpisodeFinished` / seek / chapter methods),
   - `SyncController` (start/stop + status over CloudSyncEngine).
   `AppState` REMAINS the iOS composition root and keeps its public surface —
   existing views, CarPlay routing, and the watch snapshot serialiser keep
   working — but its bodies delegate to the extracted objects. Views migrate
   to observing domain objects opportunistically, never forced.
   **This is the single highest-leverage refactor in the codebase**: it
   resolves DS-GOD, gives tvOS/watch real models instead of blob mirrors, and
   thins CarPlay.
3. **Playback engine per platform behind `PlaybackControlling`**:
   iOS `PlaybackEngine` unchanged; new `StreamingPlaybackEngine` (AutohopCore,
   AVPlayer-only: URL or local file, `defaultRate` speed, periodic time
   observer, route/interruption handling per platform) serves tvOS now and the
   watch's Phase 3 `WatchPlaybackEngine` later — likely the same class with
   different capability flags.
4. **`PlaybackCapabilities` in core**: `{trimSilence, vocalBoost, video,
   streaming, sleepTimer}` availability resolved per platform/engine; UI on
   every surface (iPhone Effects sheet, watch source flags, TV transport menu)
   reads capabilities instead of hardcoding — replaces the watch doc's D7
   hardcoding with one shared mechanism.
5. **Streaming source plumbing**: `Episode` playback-asset resolution becomes
   `local file → else enclosure URL (when capability allows)`. On iPhone this
   stays behind a setting/flag default-off until the Tier 1 "instant play"
   feature is deliberately built — but the seam lands in Phase 0 and tvOS
   exercises it daily from day one.

### 4.3 iPad (the "tablet" in the directive)

iPad is deliberately NOT part of the tvOS phases: it shares the iOS target and
is mostly UI adaptivity, not architecture. Phase 0 makes it cheap
(domain objects don't care about size classes); the concrete work —
`TARGETED_DEVICE_FAMILY: "1,2"`, `NavigationSplitView` for
Library/Queue/Player columns, pointer/keyboard support, new screenshots — is
Phase 5, its own go decision. Do not enable device family 2 casually: App
Review re-screens iPad layouts on every screen including Settings and onboarding.

---

## 5. Phase 0 — Platform foundation (iOS refactor; prerequisite)

**Goal:** AutohopCore compiles for iOS + tvOS + watchOS; AppState is a facade
over extracted domain objects; a streaming AVPlayer engine exists behind
`PlaybackControlling`. Zero behaviour change on iPhone.

Work items (sequenced; each step leaves iOS shippable):

1. `Package.swift` platform matrix + target split (§4.2 move 1). Deliverable:
   `swift build` of AutohopCore succeeds for all three platforms locally
   (`swift build --destination`-style checks are NOT available for
   watchOS/tvOS from SwiftPM CLI — rely on compile-audit by inspection plus
   Kevin's Xcode build of a stub target; be explicit in the handoff notes).
2. UIKit/platform audit of core files; `#if os(...)` only at true divergence
   points (route handling, background-task registration), never mid-algorithm.
3. Extract `QueueModel` (pure logic + overrides; near-mechanical — QueueService
   is already pure). Headless smoke test: existing queue tests re-pointed.
4. Extract `PlaybackSession` + `PlaybackCapabilities`; AppState delegates.
   This is the riskiest step — it touches `startPlayback`,
   `handleEpisodeFinished`, seek, chapters, per-podcast settings push. Do it
   as its own reviewable unit with before/after behaviour notes.
5. Extract `LibraryModel`, `SyncController` (thin wrappers first; substance
   migrates later).
6. `StreamingPlaybackEngine` in core + episode asset resolution (§4.2 move 5),
   default-off on iOS.
7. Update AI CONTEXT headers on every touched file + `DEEP_SCAN` DS-GOD status
   + this doc's status line.

**Verification:** full iPhone manual pass (playback incl. trim-silence path,
queue ordering incl. pins, CarPlay, downloads, sync) — Kevin drives, provide a
checklist; all existing SwiftPM smoke tests green; no view file diffs except
imports.

**Non-goals:** any tvOS UI; changing iPhone behaviour; migrating views off
AppState.

---

## 6. Phase 1 — tvOS target scaffolding + purge-resilient bootstrap

**Goal:** `AutohopTV` target launches on Apple TV, builds its database from
nothing, and shows a placeholder Home fed by real synced data.

1. **`project.yml`**: add `AutohopTV` — `type: application`,
   `platform: tvOS`, `deploymentTarget: "17.0"` (T6 decision point),
   bundle ID `com.kevinperry.autohop.tv`, `DEVELOPMENT_TEAM: QT3N6256FG`,
   sources: new `TV/` directory + AutohopCore package product (NOT the iOS
   source glob). Info properties: `UIBackgroundModes: [audio]`
   (PC precedent §2.3), `UIUserInterfaceStyle: Dark`.
   tvOS brand assets: App Icon & Top Shelf Image stack (layered icon —
   parallax; derive layers from `Design/AppIcon/autohop-icon-v1.svg`:
   background gradient layer + waveform layer + chevron layer).
   iCloud/CloudKit entitlements mirroring the iOS container.
2. **`TV/App/AutohopTVApp.swift`** — SwiftUI `@main`; `TVAppModel`
   (`@Observable`, the tvOS composition root ~ a few hundred lines, composed
   from Phase 0 domain objects; the anti-AppState).
3. **Purge-resilient bootstrap (T2)** — the phase's real work:
   - `AutohopDatabase` on tvOS initialises in `Caches`; add a
     "rebuild from empty" path: read survival kit (UserDefaults: feed URLs +
     priorities + sync flag) → recreate subscription rows → kick
     `CloudSyncEngine.activateEngine()` fetch (episode user-state re-hydrates)
     → RSS refresh fills catalog. All existing stores must tolerate
     cold-empty DB + late-arriving sync (audit
     `Persistence/SubscriptionStore.swift` init-order assumptions).
   - Survival-kit writer: tiny core type persisting the subscription list
     compactly; updated on every subscription change; MUST stay well under
     500 KB (it's ~100 bytes/podcast — enforce a sanity assert, not a limit).
4. Root state machine: `loading → ready | empty` (PC `RootView` shape, minus
   auth); `empty` = "No library yet" screen with sync status + (until Phase 4)
   "set up on iPhone" guidance.

**Verification:** cold launch with empty Caches reaches `ready` with the
library visible (sync-enabled case) within acceptable time; delete-app →
reinstall → library returns; sync-disabled case reaches `empty` with correct
guidance; iOS target untouched.

---

## 7. Phase 2 — Browse UI (read-only)

**Goal:** the modern, easy-to-browse interface — full navigation with
placeholder play actions.

1. **Navigation shell**: `TabView` + `.tabViewStyle(.sidebarAdaptable)` (T6)
   with typed tab enum + router object (PC `MainTabView`/`MainTabRouter`
   shape, §2.1): **Home / Queue / Library** (Search tab added in Phase 4 with
   the search role). Focus plumbing: `defaultFocus` content-first,
   `.focusSection()` per shelf, `onMoveCommand` edge cases only if the sidebar
   interaction needs them (keep PC's async-dispatch fix if so).
2. **Home** (PC `HomeView` shelf grammar, §2.1):
   - "Continue Listening" hero row: current episode card (artwork, resume
     position bar, time remaining) — the `defaultFocus` target when present.
   - "Up Next" shelf: Priority Stack from `QueueModel` (episode cards:
     artwork, title, podcast, remaining).
   - "Latest" shelf: newest episode per subscription, newest first (Release
     Radar adjacency; video episodes first-class per T10).
   - `HomeSection` with the reserved-title-slot trick; `FocusStore`-style
     section-focus tracking for title emphasis.
3. **Queue tab**: the full Priority Stack as a focusable list — the queue IS
   Autohop's identity; give it a dedicated tab, not just a Home shelf. Row =
   large artwork, title, podcast, remaining time, pinned-indicator for
   Play Next/Play Last overrides. Read-only this phase.
4. **Library tab**: subscription grid (artwork cards, `LazyVGrid`, priority
   order to reinforce the mental model) → `NavigationStack` push to episode
   list (podcast header + episodes with played/position state from sync).
5. **Design language**: dark, artwork-forward, standard focus effects (no
   custom scale hacks except chromeless artwork buttons — PC
   `ChromelessButtonStyle`); blurred-artwork backdrops on detail pages (PC
   `BlurredCoverBackground`); Liquid Glass comes from the components, not
   custom materials. Text scale: TV type sizes, 10-foot readable; document
   patterns in `DESIGN.md` as new labelled patterns (e.g. `TVShelf-Standard`,
   `TVCard-Episode`).

**Verification:** every element reachable via focus engine alone; no layout
jumps on focus changes; empty states for zero-subscription and
zero-queue; scrolling stays 60fps with 50+ subscriptions (LazyH/VGrid +
existing `ArtworkImageCache` with a TV-sized budget).

---

## 8. Phase 3 — Playback (audio + video)

**Goal:** streamed playback of both media types with system-native controls;
position sync back to the phone. Completes the shippable v1.

1. **Player surface** (T5, PC §2.2): `AVPlayerViewController` in
   `UIViewControllerRepresentable`, presented `.fullScreenCover` from any
   card; fed by `StreamingPlaybackEngine`'s `AVPlayer`.
   - `externalMetadata`: title / podcast / artwork.
   - `transportBarCustomMenuItems`: speed menu (Autohop's speed range +
     per-podcast default applied on load; toast/confirm feedback pattern);
     no effects menu (T4 — capabilities say unavailable, so it never renders).
   - Chapter markers via `navigationMarkerGroups` from `Models/Chapter.swift`
     (+ external `podcast:chapters` fetched post-start, same policy as iPhone
     P7 — apply live when they arrive).
   - Audio episodes: `contentOverlayView` hosting SwiftUI artwork/title card,
     visibility synced to transport bar (PC coordinator-delegate pattern).
   - `onPlayPauseCommand` handled globally; Menu exits the cover
     (`onExitCommand`) with audio continuing.
2. **Session + engine behaviour**: `AVAudioSession` `.playback` /
   `.spokenAudio` on tvOS; skip ±N mapped to the user's synced intervals;
   auto-advance on finish through `PlaybackSession`'s existing policy
   (mark played → next queue episode — the same rule as iPhone, minus
   download gating since streams don't gate).
3. **Position sync**: periodic + transition writes through the same `@Synced`
   field-LWW rows; TV stats rows per T9. Verify phone⇄TV resume round-trips
   (start on phone, resume on TV mid-episode, back again).
4. **Background audio**: backing out to the tvOS home screen keeps audio
   playing (`UIBackgroundModes: audio`); Now Playing metadata via
   `MPNowPlayingInfoCenter` (port the shape of
   `NowPlaying/NowPlayingService.swift`; tvOS honours it in Control Center
   and the TV remote app).
5. **Failure UX**: streaming means network errors are normal — stall/timeout
   surfaces a focusable retry card, never a dead player.

**Ship gate (v1 = Phases 1–3):** update `FEATURES.md` (new §: Apple TV),
`SupportContent.swift` + website `support.html`, App Store metadata + TV
screenshots. tvOS App Review will exercise focus navigation and the
empty/sync-disabled paths — test both.

---

## 9. Phase 4 — Discovery, Top Shelf, polish

1. **Search tab** (search role) + **subscribe on TV**: reuse
   `Feeds/PodcastSearch.swift` + `Feeds/PodcastCharts.swift` (plain URLSession —
   already core-safe) for search + a Discover shelf set (charts); subscribing
   writes through `LibraryModel` → survival kit + CloudKit → appears on
   iPhone. Respect T7 for the sync-disabled case.
2. **Top Shelf extension** (`TVTopShelfContentProvider`, sectioned content:
   Continue Listening + top of queue with artwork + deep-link URLs into
   playback). PC ships none — differentiation. Requires an app URL-route
   handler (`onOpenURL`) in the TV app.
3. **Polish**: Liquid Glass detail pass on tvOS 26 (recompile + audit custom
   surfaces); screensaver/idle behaviour audit during audio; VoiceOver labels
   on all cards; long-title marquee/truncation rules; queue pin actions from
   TV (Play Next/Play Last as card context actions — long-press menu) if
   Kevin wants edit capability on TV at all (default: keep TV read-only,
   editing stays on iPhone).

## 10. Phase 5 — Follow-on: iPad (separate go decision)

SUPERSEDED (2026-07-03): iPad enablement is now specified in detail as
Phase 2 of `Docs/RESPONSIVE_LAYOUT_PROPOSAL.md` (the WWDC26 iOS 27
resizability / adaptive-layout proposal), which also covers fluid iPhone
window sizes and foldable readiness. The one-line scope that lived here
(`TARGETED_DEVICE_FAMILY: "1,2"`, NavigationSplitView, pointer/keyboard,
full-screen audit) carried over there. Phase 0 of THIS doc still helps: the
domain extraction makes iPad split-view view models cheap.

---

## 11. Documentation & QA obligations (every phase)

- `FEATURES.md` + this doc's status lines at each phase completion; new
  `DESIGN.md` TV patterns (Phase 2); AI CONTEXT headers on all new files and
  every touched core file (Phase 0 especially).
- Headless smoke tests: QueueModel extraction parity, PlaybackCapabilities
  matrix, survival-kit codec round-trip, asset-resolution (local vs stream)
  policy, chapter→navigation-marker mapping.
- Manual QA matrices: Phase 0 = full iPhone regression checklist (Kevin
  drives); Phases 1–3 = cold-empty-cache launch, sync on/off, purge-simulated
  relaunch, phone⇄TV resume, video + audio episodes, network-drop mid-stream,
  focus-only navigation sweep. Record results as `Docs/TVOS_PHASE<N>_QA.md`
  (CarPlay QA doc precedent).

---

## 12. Quick pointer index (Pocket Casts clone, TV target)

| Pattern | File (relative to `~/Developer/GitHub/pocket-casts-ios/`) |
|---|---|
| SwiftUI TV app entry, dark scheme | `Pocket Casts TV App/PocketCastsTVApp.swift` |
| Root state machine, @Observable coordinator via .environment | `Pocket Casts TV App/UI/RootView.swift`, `UI/AppCoordinator.swift` |
| Typed TabView, focus areas, onMoveCommand fix, parallax accessory, chromeless buttons | `Pocket Casts TV App/UI/MainTabView.swift`, `UI/MainTabRouter.swift` |
| Shelf grammar, focus sections, reserved-title-slot trick | `Pocket Casts TV App/UI/Home/HomeView.swift` |
| Section-focus tracking | `Pocket Casts TV App/UI/Common/FocusStore.swift` |
| AVPlayerViewController wrapper: transport menus, external metadata, audio overlay, transport-visibility delegate | `Pocket Casts TV App/UI/Player/NowPlayingView.swift` |
| @Observable player model exposing shared AVPlayer | `Pocket Casts TV App/UI/Player/NowPlayingViewModel.swift` |
| Audio-mode overlay content | `Pocket Casts TV App/UI/Player/MediaOverlayView.swift` |
| Thin async data facade for TV | `Pocket Casts TV App/Data/TVDataManager.swift` |
| Blurred artwork backdrop | `Pocket Casts TV App/UI/Common/BlurredCoverBackground.swift` |
| Toast feedback for transport-menu actions | `Pocket Casts TV App/UI/Common/Toast/ToastManager.swift` |
| Background audio on tvOS | `Pocket Casts TV App/Pocket-Casts-TV-App-Info.plist` |
| Episode card/row at TV scale | `Pocket Casts TV App/UI/Podcasts/EpisodeRow.swift`, `UI/Player/EpisodePlayerButton.swift` |
| Empty-state pattern | `Pocket Casts TV App/UI/Common/EmptyDataView.swift` |
