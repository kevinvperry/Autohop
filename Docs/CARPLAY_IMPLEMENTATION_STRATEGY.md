# CarPlay Implementation Strategy

Internal strategy for adding CarPlay to Autohop after Apple grants the CarPlay audio app entitlement.

Source inputs:

- `CarPlay-Developer-Guide.pdf`, CarPlay Developer Guide 2026-06-08.
- Autohop product docs: `README.md`, `FEATURES.md`, `DESIGN.md`.
- Current Autohop architecture: `App/AppState.swift`, `Queue/QueueService.swift`, `Playback/PlaybackEngine.swift`, `NowPlaying/NowPlayingService.swift`.
- Product decisions from Kevin, June 2026.

## Strategy summary

Autohop should implement CarPlay as a focused audio playback surface, not as a smaller version of the iPhone app.

The first CarPlay release should support:

- Now Playing.
- Up Next.
- A simplified Queue page.
- Playback speed control.
- Shared Listening on/off.
- Shared Listening speed picker.
- Archive current episode from the player.
- Queue row actions: Play, Play Next, Archive.

The first CarPlay release should not support:

- Search.
- Podcast browsing.
- Podcast discovery.
- Adding feeds.
- Downloads or feed refresh.
- Subscription management.
- Reordering beyond Play Next.
- Play Last.
- Sleep Timer or Sleep Schedule controls.
- Stats, diagnostics, onboarding, acknowledgements, settings, or sharing.
- CarPlay notifications.
- Any prompt that tells the driver to pick up iPhone.

This keeps the entitlement story simple: Autohop is a podcast/audio app whose CarPlay experience is designed for safe control of already downloaded playback while driving.

## Entitlement path

Apply for the CarPlay audio entitlement before implementation.

Relevant entitlement:

```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

Do not ship CarPlay UI until Apple grants the entitlement and the provisioning profile includes it. Once the entitlement is added, Autohop appears on the CarPlay home screen for everyone using that build; there is no per-user hiding of CarPlay.

The entitlement request should describe only the audio use case: downloaded podcast playback, automatic queue continuity, Now Playing, Up Next, and minimal queue actions.

## Product principles

1. CarPlay is a playback cockpit.

Autohop's CarPlay app exists so a driver can keep listening safely. It is not a management surface.

2. Downloaded only.

CarPlay shows only episodes already in Autohop's downloaded queue. It never starts a feed refresh, search, stream, or download.

3. Same state, same rules.

CarPlay must reuse the same queue, playback, archive, speed, and Shared Listening state as iPhone. It is another UI surface over `AppState`, not a separate queue model.

4. Short, flat, reversible where possible.

The hierarchy stays shallow. The main destructive action, Archive, is immediate by product choice; the cost is mitigated by keeping it behind an action sheet in Queue and using it only where the label is explicit.

5. No "use your phone" dead ends.

If something is unavailable, CarPlay should show a calm status message without instructing the driver to pick up iPhone.

## CarPlay guide constraints that matter

- The app must be primarily designed for the entitlement category. Autohop's category is audio playback.
- All CarPlay flows must work without interacting with iPhone.
- All CarPlay flows must be meaningful while driving.
- Templates must be used for their intended purpose.
- Unsupported templates can crash at runtime.
- Audio apps can use the Now Playing and List templates.
- Audio apps have a maximum template depth of 5, including the root template.
- Some cars dynamically limit lists to 12 items, so the UI must remain useful under that cap.
- The Now Playing template must be ready whenever CarPlay presents it, including from the CarPlay home screen.
- Only a List template can be pushed on top of the Now Playing template.
- CarPlay is commonly used while iPhone is locked, so queue state, local audio files, artwork, and metadata must be accessible while locked.
- Files using `NSFileProtectionComplete` or `NSFileProtectionCompleteUnlessOpen` are not available while locked.
- Keychain items requiring unlocked access are not available while locked.
- The audio session should activate only when Autohop is ready to play audio, not when the CarPlay scene connects.
- Recording should not be enabled in Autohop's CarPlay path.
- CarPlay notifications are not part of Autohop's v1 audio scope.

## Current architecture fit

Autohop already has the right core shape for CarPlay:

- `Queue/QueueService.swift` builds a downloaded-only queue.
- `App/AppState.swift` owns the memoized `downloadedQueue`.
- `App/AppState.swift` applies queue overrides through `playEpisodeNext(_:)`.
- `App/AppState.swift` plays specific episodes through `playEpisode(_:)`.
- `App/AppState.swift` archives through `archiveEpisode(_:)` and `archiveEpisodeAndPlayNext(_:)`.
- `App/AppState.swift` controls Shared Listening through `setSharedListening(active:)` and `updateSharedListeningSpeed(_:)`.
- `App/AppState.swift` controls speed through `updatePlaybackSpeed(for:speed:)`.
- `Playback/PlaybackEngine.swift` plays local files only.
- `NowPlaying/NowPlayingService.swift` already maintains system Now Playing metadata and remote commands.

The strategy should therefore be adapter-first:

- Add CarPlay scene setup.
- Add a CarPlay coordinator that observes `AppState`.
- Project existing state into CarPlay templates.
- Route all user actions back into existing `AppState` methods.

Do not create a separate CarPlay queue, separate playback controller, or separate settings store.

## V1 information architecture

Default launch behavior:

- If an episode is loaded, show Now Playing first.
- If no episode is loaded, show Up Next.
- If app state is still bootstrapping, show Loading, then switch to Now Playing or Up Next.

Screens:

- Now Playing: system Now Playing template.
- Up Next: compact list of downloaded queue items. Tap plays immediately.
- Queue: action list of downloaded queue items. Tap opens actions: Play, Play Next, Archive.
- Shared Listening speed picker: short list of `AppState.sharedListeningSpeedOptions`.

Navigation model:

- Now Playing is the primary entry when audio is available.
- Up Next should be reachable from Now Playing using the Playing Next affordance where supported.
- Queue should be reachable from the root surface or a simple list route.
- The hierarchy must never exceed 5 templates.

## Text wireframes

### Loading

```text
Autohop

Loading...
```

Notes:

- Use a simple list or alert-style placeholder while `AppState` finishes bootstrap.
- Replace as soon as possible.
- Do not ask the driver to open iPhone.

### Empty downloaded queue

```text
Autohop

No downloaded episodes
```

Notes:

- No "open iPhone" instruction.
- No download or refresh button.
- No search.

### Up Next

```text
Up Next

[artwork] Episode title
          Podcast name
          subtle progress indicator, if supported

[artwork] Episode title
          Podcast name
          subtle progress indicator, if supported
```

Behavior:

- Shows only `AppState.downloadedQueue`.
- Tapping a row immediately plays that episode.
- Artwork appears when available; otherwise use a placeholder.
- Row text is episode title plus podcast name only.
- Keep useful when limited to 12 rows.

### Queue

```text
Queue

[artwork] Episode title
          Podcast name
          subtle progress indicator, if supported

Tap row:

Play
Play Next
Archive
Cancel
```

Behavior:

- Same downloaded queue as Up Next.
- Tapping a row opens an action sheet.
- Play starts the episode immediately.
- Play Next moves the episode directly after the current episode by using the existing Play Next override.
- Archive immediately archives the episode.
- If the archived episode is currently playing, continue playback with the next downloaded queue item.

### Now Playing

```text
Now Playing

Artwork
Episode title
Podcast name
Elapsed / duration

Controls:
Play/Pause
Skip Back
Skip Forward
Speed
Shared Listening
Archive
Playing Next
```

Behavior:

- Uses `CPNowPlayingTemplate.shared`.
- Metadata must always be populated when an episode exists.
- Archive current episode immediately archives and advances.
- Speed cycles through `PlaybackPreference.speedOptions`.
- Shared Listening toggles on/off.
- Shared Listening speed picker opens a small speed list when needed.

## Detailed behavior decisions

### Episode source

Only `AppState.downloadedQueue` appears in CarPlay. This queue is already filtered to downloaded, unplayed, unarchived episodes with a local file.

Do not show:

- Undownloaded episodes.
- Downloading episodes.
- Failed downloads.
- Archived episodes.
- Played episodes.
- Browse/discovery results.
- Non-queue subscription libraries.

### Play

Up Next row tap:

- Call `await AppState.playEpisode(episode)`.
- Push or present Now Playing if CarPlay does not do so automatically.

Queue action sheet "Play":

- Same behavior as Up Next.

### Play Next

Queue action sheet "Play Next":

- Call `AppState.playEpisodeNext(episode)`.
- Do not start playback immediately.
- The selected episode moves directly after the current episode, matching iPhone behavior.
- If there is no current episode, the implementation should either no-op with a short status or treat Play Next as Play. Prefer treating it as Play in the no-current-episode state because "next" has no anchor.

### Archive

Queue action sheet "Archive":

- If the selected episode is current, call `await AppState.archiveEpisodeAndPlayNext(episode)`.
- Otherwise call `await AppState.archiveEpisode(episode)`.
- Do not ask for confirmation.
- Refresh CarPlay list templates immediately after state changes.

Now Playing Archive:

- Call `await AppState.archiveEpisodeAndPlayNext(currentEpisode)`.
- If the next item starts successfully, update Now Playing.
- If there is no next item, clear Now Playing and show the empty downloaded queue state.

### Playback speed

Speed button:

- Use `PlaybackPreference.speedOptions`, currently 1.0x through 2.5x in 0.1x increments.
- A single button cycles to the next preset.
- If current speed is at the last option, wrap to the first option.
- If Shared Listening is active, the main speed button should either be disabled or clearly reflect the Shared Listening speed. Prefer disabling normal per-podcast speed while Shared Listening is active, matching the iPhone audio controls.

Implementation:

- For normal speed, get the current episode's subscription and call `AppState.updatePlaybackSpeed(for:speed:)`.
- The change updates the same per-podcast speed the iPhone app uses.
- Live playback updates through existing `AppState` logic.

### Shared Listening

Shared Listening button:

- Toggles `AppState.sharedListeningActive` through `setSharedListening(active:)`.
- Does not automatically turn off when CarPlay disconnects.
- Controls the same global Shared Listening state as iPhone.
- iPhone UI should update live.

Shared Listening speed picker:

- Use `AppState.sharedListeningSpeedOptions`, currently `[1.0, 1.1, 1.2, 1.3]`.
- Only available while Shared Listening is active.
- Call `AppState.updateSharedListeningSpeed(_:)`.

Important existing behavior:

- Activating Shared Listening resets speed to 1.0x.
- Shared Listening disables Trim Silence while active.
- Per-podcast playback preferences are not modified.

### Artwork

List rows should show artwork where available.

Requirements:

- Provide a placeholder when artwork is missing or unavailable while locked.
- Avoid blocking list rendering on artwork.
- Resize to CarPlay-supported image sizes.
- Use `CPListItem.maximumImageSize` or `CPListImageRowItem.maximumImageSize` where applicable.
- Verify artwork cache/file protection while iPhone is locked.

### Progress

Show subtle list progress where the template supports it. Do not add extra progress text to rows.

Source:

- Use `AppState.effectivePlaybackTime(for:)`.
- Use `Episode.durationSeconds`.

If duration is unknown, omit progress.

### Errors

Use calm, short messages:

- "No downloaded episodes"
- "Episode unavailable"
- "Unable to play"

Avoid:

- "Pick up your iPhone"
- "Open Autohop on iPhone"
- Long troubleshooting copy.

## Proposed file-level implementation plan

### New files

`CarPlay/CarPlaySceneDelegate.swift`

- Conforms to `CPTemplateApplicationSceneDelegate`.
- Receives and stores `CPInterfaceController`.
- Sets initial root template.
- Disconnects cleanly.

`CarPlay/CarPlayCoordinator.swift`

- Main `@MainActor` coordinator for CarPlay templates.
- Observes `AppState` and relevant publishers.
- Owns the current CarPlay route.
- Builds templates.
- Routes all CarPlay actions into `AppState`.

`CarPlay/CarPlayTemplates.swift`

- Helper methods for creating:
  - Loading template.
  - Empty queue template.
  - Up Next list template.
  - Queue list template.
  - Queue action sheet.
  - Shared Listening speed list.

`CarPlay/CarPlayEpisodeRow.swift`

- Small projection type for row rendering:
  - episode ID.
  - title.
  - podcast title.
  - artwork.
  - progress.

`CarPlay/CarPlayArtworkProvider.swift`

- Async artwork adapter for CarPlay list images.
- Uses existing artwork cache where possible.
- Supplies placeholder immediately.
- Handles locked-device fallback.

`CarPlay/CarPlayNowPlayingController.swift`

- Configures `CPNowPlayingTemplate.shared`.
- Adds custom buttons where supported:
  - Speed.
  - Shared Listening.
  - Archive.
  - Playing Next.
- Keeps the template in sync with `NowPlayingService`/`AppState`.

`CarPlay/CarPlayLogger.swift` optional

- Thin wrapper or metadata helper for `AppLogger`.
- Useful if CarPlay diagnostics become noisy.

### Existing files to modify

`project.yml`

- Add CarPlay source folder if not automatically included.
- Add entitlement once approved.
- Add CarPlay scene manifest entries to generated Info.plist settings.

`Info.plist` or `project.yml` Info configuration

- Declare a CarPlay scene.
- Keep iPhone scene intact.
- Ensure the CarPlay scene delegate class name is correct.

`Autohop.entitlements`

- Add `com.apple.developer.carplay-audio` only after entitlement approval and provisioning profile update.

`App/AutohopApp.swift`

- Confirm app bootstrap works for a CarPlay-only launch.
- Avoid assuming the phone UI scene is connected before CarPlay.

`App/AppDelegate.swift`

- If dynamic scene configuration is preferred over Info.plist scene manifest, return the CarPlay scene configuration here.

`App/AppState.swift`

- Add small public helpers rather than letting CarPlay duplicate logic:
  - `func cyclePlaybackSpeedForCurrentEpisode()`
  - `func archiveCurrentEpisodeAndAdvance() async`
  - `func carPlayActionRows() -> [Episode]` if a named projection helps.
- Consider exposing current podcast title for an episode through a helper.
- Confirm all helpers are `@MainActor`.

`NowPlaying/NowPlayingService.swift`

- Confirm Now Playing metadata is always populated for CarPlay.
- Avoid duplicate ownership with `CPNowPlayingTemplate`; `NowPlayingService` remains the MPNowPlayingInfoCenter bridge, while CarPlay coordinator owns CarPlay template controls.

`Views/QueueSheetView.swift`

- No direct dependency from CarPlay.
- Use as behavioral reference for Play, Play Next, and Archive.

`Views/PlayerView.swift`

- No direct dependency from CarPlay.
- Use as behavioral reference for Archive current, speed controls, and Shared Listening.

`Persistence/SettingsStore.swift`

- Confirm settings writes triggered by CarPlay persist and notify the app state as expected.

`Downloads/DownloadManager.swift`

- Confirm local file paths and file protection are compatible with locked CarPlay use.

`Views/CachedArtworkImage.swift` or artwork cache implementation

- Confirm cache access while locked.
- If needed, adjust artwork cache protection for CarPlay-safe reads.

### Tests to add

`Tests/CarPlayQueueProjectionTests.swift`

- Downloaded-only queue projection.
- Empty queue state.
- Row title/detail mapping.
- Progress calculation.
- 12-item limited rendering still keeps the first queue items useful.

`Tests/CarPlayActionTests.swift`

- Queue Play calls the same behavior as iPhone play.
- Queue Play Next updates override IDs/order.
- Archive non-current removes the row.
- Archive current calls archive-and-advance semantics.

`Tests/CarPlaySpeedTests.swift`

- Speed cycles through `PlaybackPreference.speedOptions`.
- Wraps from 2.5x to 1.0x.
- Does not mutate per-podcast speed while Shared Listening is active if normal speed is disabled.

`Tests/CarPlaySharedListeningTests.swift`

- Toggle uses shared global state.
- Shared speed picker uses `AppState.sharedListeningSpeedOptions`.
- Disconnect does not reset Shared Listening.

`Tests/CarPlayLockedDataTests.swift` if feasible

- At minimum, unit-test file URLs/protection metadata for downloaded files and artwork cache files.
- Some lock-state behavior will require manual device testing.

## Implementation phases

### Phase 0: Entitlement preparation

Goal: get Apple approval before building production CarPlay.

Tasks:

- Finalize entitlement application language in `Docs/CARPLAY_ENTITLEMENT_APPLICATION.md`.
- Prepare iPhone screenshots or short screen recording:
  - Player.
  - Queue.
  - Shared Listening.
  - Downloaded-only queue behavior.
- Submit request as CarPlay audio app.

Exit criteria:

- Apple grants entitlement.
- Provisioning profile includes CarPlay audio capability.

### Phase 1: Architecture foundation

Goal: make Autohop capable of launching from CarPlay without relying on the iPhone UI scene.

Tasks:

- Add CarPlay scene declaration.
- Add `CarPlaySceneDelegate`.
- Add `CarPlayCoordinator`.
- Show Loading, then Now Playing or Up Next.
- Confirm app bootstrap works when CarPlay connects first.

Exit criteria:

- CarPlay Simulator opens Autohop.
- A root template is always provided.
- No audio session activation occurs just because CarPlay connected.

### Phase 2: Read-only playback surface

Goal: render Autohop's queue and Now Playing state.

Tasks:

- Populate `CPNowPlayingTemplate.shared`.
- Render Up Next from `AppState.downloadedQueue`.
- Render Queue from `AppState.downloadedQueue`.
- Show artwork with placeholder fallback.
- Show subtle progress if supported.
- Handle empty downloaded queue.

Exit criteria:

- Now Playing appears with correct episode and podcast metadata.
- Up Next shows downloaded queue only.
- Queue shows the same downloaded queue.
- Simulator and real hardware show useful rows with 12-item limits.

### Phase 3: Playback actions

Goal: wire safe controls into existing AppState behavior.

Tasks:

- Up Next row tap plays immediately.
- Queue row tap opens action sheet.
- Queue action sheet supports Play, Play Next, Archive.
- Now Playing supports Archive current episode.
- Archive current advances to next queue item.

Exit criteria:

- iPhone UI and CarPlay stay in sync.
- Queue updates immediately after Play Next and Archive.
- No duplicate playback state is introduced.

### Phase 4: Speed and Shared Listening

Goal: expose the car-specific audio controls Kevin wants.

Tasks:

- Add speed-cycle button using `PlaybackPreference.speedOptions`.
- Add Shared Listening toggle.
- Add Shared Listening speed list using `AppState.sharedListeningSpeedOptions`.
- Ensure Shared Listening persists after CarPlay disconnect.
- Ensure iPhone UI reflects all CarPlay changes live.

Exit criteria:

- Speed updates live while playing.
- Shared Listening toggles live while playing.
- Shared speed changes live while playing.
- Disconnect does not reset Shared Listening.

### Phase 5: Locked-device and hardware hardening

Goal: make CarPlay reliable in real driving conditions.

Tasks:

- Test while iPhone is locked.
- Verify downloaded audio files remain readable.
- Verify artwork remains readable or falls back cleanly.
- Verify queue state and settings are readable.
- Verify no CarPlay path touches unavailable Keychain items.
- Test route changes, car disconnect/reconnect, and app relaunch.

Exit criteria:

- Playback can start from CarPlay while iPhone is locked.
- Queue renders while iPhone is locked.
- Archive and Play Next work while locked.
- No dead screens or "use iPhone" instructions.

### Phase 6: Release readiness

Goal: pass Apple review and avoid car-specific regressions.

Tasks:

- Run CarPlay Simulator tests across light/dark styles.
- Test at least one real vehicle or aftermarket CarPlay head unit.
- Confirm template depth never exceeds 5.
- Confirm CarPlay does not show search, discovery, settings, or sleep controls.
- Confirm no CarPlay notifications are requested or used.
- Confirm no feed refresh/download starts from CarPlay.
- Update user-facing support docs if needed.

Exit criteria:

- Release candidate passes simulator and hardware checklist.
- App Review notes describe CarPlay audio scope accurately.

## Acceptance criteria

Entitlement/review:

- App requests only `com.apple.developer.carplay-audio`.
- CarPlay UI is clearly audio-playback focused.
- No non-driving workflows appear.

Launch:

- If current episode exists, CarPlay opens to Now Playing.
- If no current episode exists, CarPlay opens to Up Next.
- If app is bootstrapping, CarPlay shows Loading and then resolves.
- Empty queue shows "No downloaded episodes."

Playback:

- Up Next tap starts playback.
- Queue Play starts playback.
- Now Playing transport controls work.
- Skip intervals match user settings through existing remote command behavior.

Queue:

- Queue rows show episode title and podcast name.
- Queue rows show artwork where available.
- Queue rows show subtle progress where supported.
- Queue actions are Play, Play Next, Archive.
- Play Next moves the item after the current episode.
- Archive removes the item immediately.
- Archive current episode advances to next item.

Audio controls:

- Speed cycles through existing Autohop presets.
- Shared Listening toggles on/off.
- Shared Listening speed picker uses existing shared speed options.
- Shared Listening state persists after disconnect.

State sync:

- iPhone UI updates live after CarPlay actions.
- CarPlay UI updates live after iPhone actions.
- No separate CarPlay queue or settings state exists.

Safety:

- No CarPlay workflow asks the driver to pick up iPhone.
- No search or keyboard workflow exists in v1.
- No sleep controls exist in v1.
- No notification path exists in v1.

Reliability:

- Works while iPhone is locked.
- Does not activate audio session on CarPlay connection alone.
- Does not start downloads or feed refresh from CarPlay.
- Survives disconnect/reconnect.

## Key risks and mitigations

### Risk: Apple rejects controls as too settings-like

Speed and Shared Listening are audio playback controls, but a speed picker can look like settings.

Mitigation:

- Keep speed controls on Now Playing only.
- Present Shared Listening speed as a short active playback choice, not a settings page.
- Do not expose trim silence, vocal boost, skip intervals, or default playback preferences.

### Risk: Archive is destructive without confirmation

Immediate Archive is useful while driving but can be tapped accidentally.

Mitigation:

- In Queue, Archive is inside an action sheet, not directly on the row.
- On Now Playing, Archive should use a clear label/icon.
- Ensure iPhone can still show archived state and unarchive through existing UI if needed.

### Risk: locked iPhone cannot access files/artwork

CarPlay is often used while iPhone is locked.

Mitigation:

- Audit file protection for downloads, settings, queue pins, playback positions, and artwork cache.
- Use less restrictive protection where appropriate for playback files and CarPlay artwork.
- Always provide placeholder artwork.

### Risk: CarPlay-only launch misses app bootstrap

The app may be launched only for CarPlay.

Mitigation:

- Treat AppState bootstrap as app-level, not iPhone-scene-level.
- CarPlay coordinator waits on readiness and shows Loading.
- Avoid dependencies on SwiftUI view lifecycle for core playback setup.

### Risk: template API differences by iOS version

CarPlay templates and buttons vary by iOS version.

Mitigation:

- Build v1 against the minimum supported iOS version for CarPlay audio.
- Use availability checks for newer template features.
- Keep a conservative fallback: list templates plus shared Now Playing.

### Risk: list limits hide important queue items

Some cars limit lists to 12 items.

Mitigation:

- Put the current automatic queue order first.
- Do not add verbose grouping that consumes rows.
- Keep Up Next compact.

## Open implementation questions

These do not block the strategy, but should be decided during implementation:

- Should the Speed button label show the next speed or current speed?
- Should Play Next with no current episode behave as Play or show a short status?
- Should Archive current episode be a Now Playing custom button or live only through Queue action sheet if template constraints are tight?
- Should Up Next and Queue be separate root-level entries, or should Queue be reached from Up Next?
- What placeholder artwork should CarPlay use: app icon, generated podcast placeholder, or monochrome Autohop mark?

## Recommended v1 route

Build the most review-safe version that still feels like Autohop:

1. Apply for entitlement.
2. Add CarPlay scene and coordinator.
3. Launch into Now Playing when possible, otherwise Up Next.
4. Render Up Next and Queue from `AppState.downloadedQueue`.
5. Wire Play, Play Next, Archive.
6. Add Speed cycle.
7. Add Shared Listening toggle and speed picker.
8. Harden locked-device access.
9. Test in CarPlay Simulator and real hardware.

This gives Autohop a focused, useful CarPlay presence without diluting the product into browsing, settings, or feed management. It also plays directly to the app's strongest claim: the queue is already built, already downloaded, and ready to keep playing while the driver does less.
