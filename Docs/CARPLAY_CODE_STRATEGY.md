# CarPlay Code Strategy

Status: Apple has approved the CarPlay Audio App entitlement for the account.

Purpose: define the coding plan before implementation begins. This document is deliberately about sequencing, ownership, integration points, and verification gates. It does not contain implementation code.

Related documents:

- `Docs/CARPLAY_IMPLEMENTATION_STRATEGY.md` - product and behavior strategy.
- `Docs/CARPLAY_ENTITLEMENT_APPLICATION.md` - entitlement background and Apple-facing framing.
- `Docs/CARPLAY_PHASE9_QA.md` - Phase 9 verification status and remaining manual CarPlay checks.

## North Star

Build CarPlay as a thin, native CarPlay UI surface over Autohop's existing playback system.

Do not create a second app model. Do not create a second queue. Do not create a second playback controller. CarPlay should project existing `AppState` into CarPlay templates and route every action back to the same methods already used by the iPhone UI.

The first release remains:

- Now Playing first when an episode is loaded.
- Queue if no episode is loaded.
- Simplified Queue for selection and actions.
- Downloaded queue only.
- Queue actions: Play Now, Play Next, Play Last, Archive.
- Player actions: Archive, slower/faster speed dialog, Shared Listening toggle, Shared Listening speed picker.
- No search, browsing, downloads, feed refresh, sleep controls, settings, stats, diagnostics, sharing, or CarPlay notifications.

## Implementation Shape

Add a new `CarPlay/` module folder inside the app target.

Recommended files:

- `CarPlay/CarPlaySceneDelegate.swift`
- `CarPlay/CarPlayCoordinator.swift`
- `CarPlay/CarPlayRoute.swift`
- `CarPlay/CarPlayTemplateFactory.swift`
- `CarPlay/CarPlayEpisodePresenter.swift`
- `CarPlay/CarPlayArtworkProvider.swift`
- `CarPlay/CarPlayNowPlayingController.swift`

The responsibilities should stay sharply separated:

- Scene delegate: CarPlay connection lifecycle only.
- Coordinator: state observation, navigation decisions, and action routing.
- Template factory: creates CarPlay templates from already-prepared view data.
- Episode presenter: converts `Episode` plus subscription/position data into row models.
- Artwork provider: resolves CarPlay-sized images with placeholder fallback.
- Now Playing controller: configures `CPNowPlayingTemplate.shared` and its custom controls.

## Existing Code To Reuse

Primary state and actions:

- `App/AppState.swift`
  - `downloadedQueue`
  - `currentPlayerEpisode`
  - `currentPlayerTime`
  - `isPlaying`
  - `effectivePlaybackTime(for:)`
  - `playEpisode(_:)`
  - `playEpisodeNext(_:)`
  - `archiveEpisode(_:)`
  - `archiveEpisodeAndPlayNext(_:)`
  - `setSharedListening(active:)`
  - `updateSharedListeningSpeed(_:)`
  - `updatePlaybackSpeed(for:speed:)`
  - `effectiveSpeed(for:)`

Queue rules:

- `Queue/QueueService.swift`
  - Already enforces downloaded, local-file-backed, unplayed, unarchived queue entries.

Playback:

- `Playback/PlaybackEngine.swift`
  - Already plays local files only.
  - Must not be touched for CarPlay unless a real playback bug is found.

Now Playing and remote controls:

- `NowPlaying/NowPlayingService.swift`
  - Keep as the `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` bridge.
  - Do not make it responsible for CarPlay template navigation.

Artwork:

- `Views/CachedArtworkImage.swift`
  - `ArtworkImageCache` should be reused through a non-SwiftUI CarPlay adapter.

Project generation:

- `project.yml`
  - Source of truth for generated `Info.plist`.
  - Source of truth for generated `Autohop.entitlements`.
  - Add `CarPlay.framework` dependency here.
  - Do not hand-edit `Autohop.xcodeproj/project.pbxproj` except as a last resort.

## Phase 0: Capability And Signing Setup

Goal: make the local project eligible to build a CarPlay-capable app.

Tasks:

- In Apple Developer, enable the CarPlay Audio App capability on the Autohop App ID.
- Regenerate or refresh development provisioning profiles after enabling the capability.
- In Xcode, confirm the selected team/profile contains the CarPlay audio capability.
- In `project.yml`, plan to add:
  - `CarPlay.framework` as an SDK dependency.
  - `com.apple.developer.carplay-audio: true` under entitlements.
  - CarPlay scene configuration under generated Info.plist properties.

Gate:

- Xcode signing shows the CarPlay capability without manual drift from `project.yml`.
- A clean project regeneration will preserve the entitlement.

Notes:

- Since this repo uses XcodeGen, `project.yml` must remain the durable source of truth.
- The checked-in `Info.plist` and `Autohop.entitlements` are generated outputs. They should change only as a result of planned XcodeGen source updates.

## Phase 1: Scene Skeleton

Goal: Autohop appears in CarPlay and always provides a valid root template, with no playback behavior yet.

Tasks:

- Add `CarPlaySceneDelegate`.
- Add `CarPlayCoordinator`.
- Add a minimal loading template.
- Wire the CarPlay scene to the coordinator.
- Store and clear `CPInterfaceController` on connect/disconnect.
- On connect, set a root template immediately.
- Confirm no audio session is activated merely by connecting CarPlay.

Preferred scene configuration:

- Add only the CarPlay scene role to the generated Info.plist via `project.yml`.
- Keep the existing SwiftUI `WindowGroup` for the iPhone UI.
- If this conflicts with SwiftUI scene startup in practice, switch to AppDelegate dynamic scene configuration for the CarPlay role.

Gate:

- App builds.
- CarPlay Simulator launches Autohop.
- CarPlay shows a simple root template.
- iPhone UI still launches normally.
- No queue/playback actions exist yet.

Why this phase is separate:

- Scene setup and signing are the most brittle parts. Isolate them before adding product behavior.

## Phase 2: AppState Readiness For CarPlay-Only Launch

Goal: make CarPlay safe when it connects before the iPhone UI appears.

Current risk:

- `AppState.bootstrap()` already happens in `AutohopApp.init()`.
- `startPlaybackOnLaunchIfNeeded()` currently runs from the SwiftUI `WindowGroup` task.
- A CarPlay-only launch must not depend on the phone window appearing before CarPlay can render useful state.

Tasks:

- Add an idempotent app-readiness entry point in `AppState`, or reuse `startPlaybackOnLaunchIfNeeded()` from the CarPlay coordinator.
- Ensure the method is safe to call from both iPhone and CarPlay paths.
- Make the coordinator show Loading until this startup step has completed.
- After readiness:
  - show Now Playing if `currentPlayerEpisode` exists.
  - otherwise show Queue.

Gate:

- Calling startup readiness twice has no side effects.
- CarPlay can show current/queued content without opening the iPhone UI.
- No feed refresh or download starts because of CarPlay readiness.

## Phase 3: Read-Only Template Projection

Goal: show correct CarPlay UI without actions.

Tasks:

- Add `CarPlayEpisodePresenter`.
- Convert `AppState.downloadedQueue` into CarPlay row data:
  - episode title.
  - podcast title.
  - artwork or placeholder.
  - optional progress.
- Add Queue list.
- Add empty downloaded queue template.
- Configure `CPNowPlayingTemplate.shared` enough to show current metadata.
- Observe app state changes and refresh templates conservatively.

Important design choice:

- CarPlay uses the Queue list only. Earlier Up Next/Queue separation was removed
  after real-hardware testing because it added navigation without adding useful
  driver value.

Gate:

- Lists show downloaded queue only.
- Empty queue shows "No downloaded episodes."
- Rows show episode title and podcast name only.
- Artwork failure does not block row display.
- List remains useful if only 12 items are shown.

## Phase 4: Action Routing

Goal: wire CarPlay controls into existing AppState behavior.

Tasks:

- Queue row tap:
  - open a short action page.
- Queue action page:
  - Play Now: `await appState.playEpisode(episode)`.
  - Play Next: `appState.playEpisodeNext(episode)`.
  - Play Last: `appState.playEpisodeLast(episode)`.
  - Archive:
    - if current episode, `await appState.archiveEpisodeAndPlayNext(episode)`.
    - otherwise `await appState.archiveEpisode(episode)`.
- Now Playing Archive:
  - `await appState.archiveEpisodeAndPlayNext(currentEpisode)`.

Add small AppState helpers only when they reduce duplication:

- `archiveCurrentEpisodeAndPlayNext() async`
- `cyclePlaybackSpeedForCurrentEpisode()`
- `podcastTitle(for episode:)`
- `episodeIsCurrent(_:)`

Gate:

- iPhone and CarPlay update together.
- Play Next changes queue order immediately.
- Archive removes the row immediately.
- Archiving current starts the next downloaded queue item.
- No action starts downloads, feed refresh, search, or browsing.

## Phase 5: Speed And Shared Listening

Goal: add the chosen audio controls without opening the door to settings.

Tasks:

- Add Now Playing speed button.
- Speed button cycles through `PlaybackPreference.speedOptions`.
- If Shared Listening is off:
  - update current episode's subscription speed through `updatePlaybackSpeed(for:speed:)`.
- If Shared Listening is on:
  - prefer disabling normal speed cycle, or make the button clearly reflect Shared Listening speed.
- Add Shared Listening toggle:
  - calls `setSharedListening(active:)`.
- Add Shared Listening speed list:
  - uses `AppState.sharedListeningSpeedOptions`.
  - calls `updateSharedListeningSpeed(_:)`.
- Do not turn Shared Listening off on CarPlay disconnect.

Gate:

- Speed changes live during playback.
- Shared Listening changes live during playback.
- Shared Listening state persists after disconnect.
- iPhone audio controls reflect CarPlay changes immediately.
- No trim silence, vocal boost, skip interval, or default settings controls appear in CarPlay.

## Phase 6: Artwork, Progress, And Locked-Device Hardening

Goal: make the feature reliable when the phone is locked in a car.

Tasks:

- Add `CarPlayArtworkProvider`.
- Use existing artwork cache where possible.
- Always return a placeholder if artwork is missing, slow, protected, or unavailable.
- Size images for CarPlay list/Now Playing usage.
- Audit file protection for:
  - downloaded audio files.
  - artwork disk cache.
  - queue pins.
  - playback position file.
  - settings file.
  - subscription database.
- Verify no CarPlay path requires unlocked Keychain access.

Gate:

- Start playback from CarPlay while iPhone is locked.
- Render queue from CarPlay while iPhone is locked.
- Archive and Play Next work while locked.
- Artwork never creates a blank or stuck list.

## Phase 7: Template Depth And Navigation Pass

Goal: ensure CarPlay navigation stays review-safe and mechanically safe.

Tasks:

- Count every possible template stack.
- Keep max depth below 5.
- Ensure Now Playing only pushes a List template above it.
- Avoid nested action chains.
- Make Queue action page one level only.
- Make Shared Listening speed picker one short list only.
- Test no-current-episode states:
  - root Queue.
  - empty queue.
  - Play Next with no current episode.

Recommended decisions:

- If Play Next is tapped with no current episode, treat it as Play.
- If Archive current leaves no next episode, clear Now Playing and show empty queue.

Gate:

- No route exceeds template depth.
- No unsupported template is used for the audio entitlement.
- No screen contains non-driving workflows.

## Phase 8: Tests

Goal: lock behavior down before full CarPlay simulator/hardware work.

Add focused tests before broad UI polish:

- Queue projection tests:
  - downloaded only.
  - title plus podcast name.
  - empty state.
  - progress calculation.
- Action routing tests:
  - Play.
  - Play Next.
  - Archive non-current.
  - Archive current and advance.
- Speed tests:
  - cycle through presets.
  - wrap at end.
  - Shared Listening interaction.
- Shared Listening tests:
  - toggle persists.
  - speed picker updates shared speed.
  - disconnect does not reset.

Gate:

- Existing smoke/unit tests still pass.
- New behavior tests pass without requiring a CarPlay runtime where possible.

## Phase 9: Simulator And Hardware QA

Goal: verify the real CarPlay experience.

Simulator checks:

- Launch Autohop from CarPlay home.
- Launch while iPhone UI is already open.
- Launch while iPhone UI is not open.
- Current episode opens Now Playing.
- No current episode opens Queue.
- Empty queue shows calm empty state.
- Queue action page works.
- Now Playing Archive advances.
- Speed slower/faster dialog works.
- Shared Listening toggle and speed list work.
- Light and dark appearances.
- Different screen sizes.

Real hardware checks:

- Wired CarPlay.
- Wireless CarPlay if available.
- Locked iPhone.
- Head unit controls.
- Steering wheel play/pause/skip.
- Disconnect/reconnect during playback.
- Route changes during playback.
- Poor/no network, confirming no CarPlay download/stream path is needed.

Gate:

- No crashes.
- No blank templates.
- No stuck spinners.
- No unexpected audio session activation.
- No instruction to use iPhone.

## Phase 10: Release Preparation

Goal: make App Review and future maintenance easy.

Tasks:

- Update support documentation to mention CarPlay audio support.
- Add App Review notes:
  - CarPlay is audio-only.
  - It uses downloaded queue items only.
  - It excludes search, browsing, downloads, and settings.
- Confirm production provisioning profile includes CarPlay audio entitlement.
- Confirm archive build has the entitlement.
- Run final regression on:
  - normal iPhone app launch.
  - background audio.
  - lock screen controls.
  - Control Center controls.
  - Sleep Schedule notification behavior.
  - queue pin persistence.
  - archive behavior.

Gate:

- Release candidate is tested in simulator and real CarPlay hardware.
- Entitlement appears in archived app.
- No unrelated app behavior regresses.

## Proposed Coding Order

Use this order when implementation begins:

1. Update signing/project configuration in `project.yml`.
2. Regenerate project and confirm entitlement/profile.
3. Add CarPlay scene skeleton with Loading template.
4. Add coordinator and readiness flow.
5. Add row presenter and read-only Queue template.
6. Add Now Playing template setup.
7. Add Queue action page with Play Now, Play Next, Play Last, Archive.
9. Add Now Playing Archive.
10. Add slower/faster speed dialog.
11. Add Shared Listening toggle.
12. Add Shared Listening speed list.
13. Add artwork provider and progress indicators.
14. Harden locked-device behavior.
15. Add tests.
16. Run simulator QA.
17. Run real hardware QA.
18. Prepare release notes/App Review notes.

## Stop Points

Stop and reassess after these moments:

- After signing/project setup if Xcode does not show the entitlement cleanly.
- After scene skeleton if the iPhone SwiftUI scene behaves differently.
- After read-only templates if CarPlay list limitations force a simpler IA.
- After Now Playing custom controls if a requested button is not supported on the current minimum iOS target.
- After locked-device testing if file protection blocks playback or artwork.

## Non-Goals For The Coding Pass

Do not implement:

- Search.
- Podcast/library browsing.
- Add feed.
- Download/refresh from CarPlay.
- Drag/reorder.
- Sleep controls.
- Stats.
- Settings.
- Notifications.
- Voice input.
- Custom non-template UI.

## First Pull Request Shape

The cleanest first PR should include:

- Project capability setup.
- CarPlay scene skeleton.
- Loading/empty templates.
- Read-only Queue template.
- No playback actions yet.

This makes the riskiest platform integration reviewable before behavior gets layered on.

The second PR should add actions. The third should add speed/Shared Listening. The fourth should harden artwork, progress, locked-device behavior, and tests.

That PR structure keeps review sane and gives us escape hatches if the CarPlay template API pushes back.
