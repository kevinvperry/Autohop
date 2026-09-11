# Mac menus, shortcuts, and menu bar player — implementation plan

<!--
AI CONTEXT — Docs/MAC_MENU_AND_DESKTOP_IMPLEMENTATION_PLAN.md
Historical staged proposal. Stage one is implemented; stage two remains planned.
Read MAC_MENU_STAGE_1.md for current code, follow-up fixes and validation limits.
Do not treat status-icon or native-shell recommendations as delivered features.
-->

Prepared 6 September 2026. Proposal only; no application code changed for this plan.

Stage one has since been implemented; see [implementation and validation notes](MAC_MENU_STAGE_1.md). The native macOS shell and status icon remain a later stage.

## 1. Recommended approach

Deliver this in two releases:

1. Improve the existing iPad app running on Apple-silicon Macs with application menus, discoverable keyboard shortcuts, and reliable navigation commands.
2. Build a dedicated macOS application shell for the persistent menu bar icon, native Settings window, and predictable operation with all windows closed. Reuse Autohop's domain logic and data contracts; budget explicitly for platform adapters and desktop views.

The two requested surfaces are different: application menus sit beside the Apple menu and belong to the active app; a status icon sits on the right and remains accessible while another app is active. Both should expose the same playback actions.

Apple documents UIMenuBuilder support for iPhone/iPad apps running on Mac, including responder-based command validation. This makes the first release possible without a new Mac target. [Apple: iPhone and iPad apps on Macs](https://developer.apple.com/videos/play/wwdc2021/10056/).

A persistent status icon is a platform decision, not a small addition to the current view. SwiftUI MenuBarExtra is a macOS scene; the installed SDK marks it unavailable on iOS. It cannot simply be added to the current iOS app or directly to a Catalyst scene. [Apple: MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra).

## 2. What exists in this repository

- project.yml defines an iPhone/iPad app, with no dedicated macOS app target or explicit Catalyst configuration.
- App/AutohopApp.swift uses UIApplicationDelegateAdaptor and WindowGroup. Service bootstrap currently happens when the root view appears.
- Package.swift supports macOS for core/headless tests; its comments explicitly say this is not a Mac application.
- Mac adaptations currently concern sizing and modal presentation, including isiOSAppOnMac checks. They do not supply desktop application commands.
- Search has Command-F; shared sheet closing has an Escape shortcut. No application-wide command catalogue, UIMenuBuilder implementation, or status item was found.
- AppRoutingCoordinator already owns typed navigation commands while RootView owns the actual NavigationPath.
- PlaybackTransportWorkflow, PlaybackSeekWorkflow, PlaybackPreferenceWorkflow, and EpisodeCompletionWorkflow already own the actions menus need. PlaybackCoordinator connects equivalent actions to NowPlayingService.
- Shared stats/history and persistence are critical invariants. A new menu action must use existing workflows rather than writing playback or database state itself.

## 3. Proposed application menus

Preserve the standard application, File, Edit, View, Window, and Help conventions. Add Playback and Podcast menus. Keep the existing in-window Menu as a convenient alternative, with consistent labels.

| Menu | Proposed contents |
| --- | --- |
| Autohop | About Autohop; Settings…; system Services, Hide, Hide Others, Show All, Quit. |
| File | Add RSS Feed…; Import Subscriptions…; Export Subscriptions…; Close Window. Do not offer New Document, Save, Print, or other document actions with no real meaning. |
| Edit | Standard undo/redo and clipboard/text commands where supported; Find Podcasts…. Avoid claiming Undo for subscription/archive operations until reversible domain actions exist. |
| View | Player, Subscriptions, Discover, Up Next, Listening History, Stats, Downloads; Back; later, Show/Hide Sidebar and Show Menu Bar Player. |
| Playback | Play/Pause; Skip Back [configured interval]; Skip Forward [configured interval]; Next Episode; Previous/Next Chapter; Playback Speed submenu; Audio Controls…; Sleep Timer…; Sleep Schedule…. |
| Podcast | Actions for the explicitly selected show/episode: Open Show, Show Settings…, Refresh Show, Subscribe/Unsubscribe…, Download, Play Next, Play Last, Archive…. Include Refresh All Shows as an app-wide action. |
| Window | System Minimize, Zoom/full-screen and window switching; later, Show Main Window. No New Window until shared playback and focused-window routing are proven. |
| Help | Autohop Help; Keyboard Shortcuts; Contact Support; Acknowledgements. Keep diagnostic commands within the existing developer/support gate. |

Use separators and short submenus for speed and sleep presets. Show unavailable commands disabled so the menu structure remains predictable. Playback labels/checkmarks update when playback, queue, speed, or selected content changes. Selection-sensitive commands must never silently act on the current playing show instead of the selected show.

Apple recommends structuring menus around the actions and objects in an app, and making those actions discoverable to keyboard users. [Apple: Designing iPad Apps for Mac](https://developer.apple.com/videos/play/wwdc2019/809/).

## 4. Proposed keyboard shortcuts

These are defaults to validate on real Macs, including non-US keyboard layouts. Modifier-heavy optional actions can initially have no shortcut.

| Action | Proposed shortcut | Behaviour |
| --- | --- | --- |
| Settings | Command-comma | Open/focus settings; native Settings window in release two. |
| Find Podcasts | Command-F | Open Search and focus its field; reuse the existing binding. |
| Add RSS Feed | Command-N | Open the URL entry form, not an empty document. |
| Import / Export subscriptions | Command-Shift-I / Command-Shift-E | Open file selection/save UI. |
| Player / Subscriptions / Discover | Command-1 / Command-2 / Command-3 | Navigate to the existing destination. |
| Up Next / History / Stats / Downloads | Command-4 / Command-5 / Command-6 / Command-7 | Open or focus the relevant destination. |
| Back | Command-[ | Dismiss the nearest pushed destination; preserve navigation parents. |
| Play/Pause | Command-Return | App-wide transport command while Autohop is active. |
| Play/Pause in player context | Space | Only when no editor, text field, slider, or other focused control owns Space. |
| Skip backward / forward | Command-Left / Command-Right | Respect configured intervals; yield to text editing and control-specific behaviour. |
| Previous / next chapter | Command-Option-Left / Command-Option-Right | Enabled only when a valid chapter target exists. |
| Next episode | Command-Shift-Right | Same completion/advance behaviour as the existing remote Next action. |
| Refresh selected show | Command-R | Only when a show is selected and refresh is available. |
| Refresh all shows | Command-Shift-R | Reuse refresh coalescing/backoff policy; suppress duplicate runs. |
| Close / Minimize / Hide / Quit | Command-W / Command-M / Command-H / Command-Q | Leave system handling intact. |
| Dismiss transient UI | Escape | Preserve the existing cancellation/close contract. |

Do not assign a bare Delete key to archive or unsubscribe. Preserve Command-C/V/X/A/Z, Return for submitting forms, Option-arrow word movement, and keyboard accessibility behaviour. Test repeat events so held keys cannot repeatedly complete episodes or launch imports.

Ordinary application shortcuts work while Autohop is active. They are not global hotkeys. Existing media-key support remains through NowPlayingService and the system remote-command path. Global hotkeys are a separately scoped enhancement; do not introduce system-wide keyboard monitoring to implement ordinary menus.

## 5. Command architecture

Introduce a small typed command layer shared by menus, shortcuts, and the later status panel:

- AppCommand: stable identifiers for navigation, transport, library, and presentation commands; explicit associated episode/subscription IDs for contextual actions.
- AppCommandContext: readiness, current playback state, selected content, focused scene, busy operations, and modal/editing state.
- AppCommandHandler: validates against current state and forwards to existing domain owners on the main actor. No duplicate player, queue, refresh, or persistence implementation.
- CommandPresentation: menu title, enabled state, checkmark, shortcut, and accessible description. State changes refresh command presentation; playback-clock ticks should not rebuild the whole menu.

Implementation boundaries:

1. Add a UIKit menu builder through AppDelegate.buildMenu(with:), operating only on the main menu system. Use UIMenu/UIKeyCommand and a responder adapter with validation. A command that is visible and clickable must route to a responder that is actually reachable from the focused window.
2. Connect the adapter after the composition root is ready. Avoid bootstrapping AppState merely because macOS asks to build menus; preserve CarPlay-only startup behaviour.
3. Extend AppRoutingCoordinator with the missing typed routes/presentation intents: search and focus, settings, history, downloads, RSS entry, imports, exports, sleep controls, and support. RootView remains responsible for navigation.
4. Add focused selection context to relevant lists. Until selection is unambiguous, disable contextual Podcast commands.
5. Remove duplicate bindings when centralising existing Command-F. Share definitions across adapters so titles and shortcuts cannot drift.
6. Revalidate at execution time as well as display time. An episode can finish or a selection can disappear while a menu is open.
7. Serialize destructive/advancing transport transitions and asynchronous imports. Retain existing confirmation flows for unsubscribe and archive where applicable.

Playback details matter: skip-forward must call PlaybackSeekWorkflow.skipForward, which accounts for skipped-time stats and end-of-episode behaviour. Next Episode must follow the current completion and Play Instant cancellation path. Speed changes retain the current per-podcast preference semantics. Seek-back clamps to zero. All entry points should produce the same queue, history, and stats results.

Apple describes the supported UIKit menu integration in [Adding menus and shortcuts](https://developer.apple.com/documentation/uikit/adding-menus-and-shortcuts-to-the-menu-bar-and-user-interface) and [UIMenuBuilder](https://developer.apple.com/documentation/uikit/uimenubuilder).

## 6. Persistent menu bar player

Recommended release-two design: a monochrome Autohop template icon, with an accessible label reflecting playback state. Default enabled for the dedicated Mac app; provide “Show Autohop in the menu bar” in Settings. Do not animate the icon continuously or put a long episode title in the system bar.

Click opens a compact panel, approximately 340–380 points wide, containing:

- Current artwork, episode title, show name, and playback status.
- Elapsed/remaining time and a scrubber with keyboard/accessibility support.
- Skip back, Play/Pause, Skip forward, and a separate Next Episode action.
- Playback speed and sleep timer status/controls.
- A short Up Next preview, linking to the full queue.
- Open Autohop, Settings…, and Quit Autohop.

Without a current episode, show an honest empty state with Open Autohop and an available queue-start action. Display loading/download/error states; never leave enabled controls pointing at stale episode IDs. Open the panel without unnecessarily bringing the main window forward. Open Autohop explicitly activates and restores the window.

Use native SwiftUI MenuBarExtra with window style for the dedicated macOS target, falling back to an NSStatusItem/NSPopover implementation only if prototype testing exposes a concrete accessibility or panel-lifecycle limitation. Observe the playback clock only while the panel is visible; artwork and command state should use bounded shared caches/subscriptions.

The window and status panel share exactly one application service graph and playback engine. Bootstrap those services at the macOS application level, not inside a main-window task. Closing or recreating a window must not restart playback or duplicate callbacks.

## 7. Choosing the Mac runtime

| Option | Benefits | Cost/limitation | Recommendation |
| --- | --- | --- | --- |
| Existing iPad app on Mac | Maximum code reuse; supports menu customisation and shortcuts. | No direct native MenuBarExtra; runtime controls window/background behaviour. | Ship release one here. |
| Mac Catalyst | Reuses much of UIKit UI; additional Mac window/toolbar APIs. | Does not directly unlock MenuBarExtra or arbitrary AppKit APIs; status integration requires a separately proven architecture. | Optional short feasibility study if reducing UI porting cost becomes the priority. |
| Native macOS SwiftUI shell | Direct supported status-panel, Settings, and desktop lifecycle APIs. | Platform adapters and desktop views required; shared core does not make the current app automatically portable. | Recommended destination for the full requirement. |

Do not base delivery on loading unsupported AppKit symbols into an iOS app. A Catalyst/AppKit bridge or separate helper would require its own supportability, signing, distribution, lifecycle, and communications investigation; it is not a promised shortcut in this plan. Apple explicitly limits Catalyst to APIs available to Catalyst. [Apple: Mac Catalyst](https://developer.apple.com/documentation/uikit/mac-catalyst).

For the native route, first inventory UIKit, AVAudioSession, background tasks, file protection, notifications, sharing, widgets, and CarPlay dependencies. Reuse parsing, models, data semantics, and tested workflows through narrow platform interfaces. Supply Mac adapters for audio routing/session behaviour, application lifecycle, file panels, notifications, and scheduling. Avoid blanket conditional compilation throughout domain code.

## 8. Mac lifecycle, settings, and migration

- Closing the last native Mac window continues active playback and keeps the enabled status icon available. Command-Q checkpoints position/history/stats, stops playback, releases resources, and terminates; it never silently relaunches.
- Reopening via Dock or status panel restores one main window and its navigation/size. Additional library windows can follow once focused routing is implemented.
- Inactive app, hidden window, closed window, computer sleep, and process termination are distinct states. Audit AppRuntimeWorkflow assumptions before mapping native Mac lifecycle events onto them.
- Computer sleep suspends work; do not promise ongoing playback or precise refresh while asleep. On wake, reconcile clock/checkpoints, network, audio route, and refresh deadlines without double-crediting listening time.
- Provide a native Settings scene in the Mac shell. Mac-local settings include status-icon visibility, window restoration, and optional launch at login. Keep launch at login off by default and use system registration rather than custom launch scripts. [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
- Keep appearance, playback, and subscription settings consistent with existing sync contracts. Mac-local window/status/login preferences should not change the iPhone experience.
- Confirm deployment minimum, bundle identity, signing, App Store listing/replacement behaviour, iCloud containers, App Groups, and entitlements before distributing a native build. Treat macOS 14 as a provisional minimum matching the shared package, pending API/build validation.
- Prove upgrade migration from the current iOS-on-Mac installation. Do not assume a new target inherits its sandbox. Preserve local-only data with an explicit tested export/import or supported migration path; OPML alone cannot preserve history, stats, preferences, queue state, or downloaded files. Cloud sync is not sufficient for users who disabled it.
- Avoid two installed variants independently acting as the same playback session or corrupting shared storage. Do not enable unsupervised cross-process writes to a shared database.

## 9. Work sequence and completion gates

Effort ranges are planning estimates for one experienced Apple-platform engineer with focused testing, not commitments.

| Stage | Deliverable | Completion gate | Indicative effort |
| --- | --- | --- | --- |
| A. Runtime and menu prototype | Verify shipped Mac mode; small main-menu/shortcut proof on a real Mac; confirm current menu contents and reserved keys. | Commands invoke the intended action from nested pages and sheets without changing text entry. | 1–2 days |
| B. Shared commands | Catalogue, validation/context, responder adapter, typed routing additions. | No duplicate playback/service instances; action semantics match current buttons. | 2–4 days |
| C. Existing-app menu release | Menus, shortcuts, focus behaviour, help reference, operation/error states. | Mac and iPad keyboard QA plus iPhone/CarPlay regression checks pass. | 3–5 days |
| D. Native Mac feasibility | Buildable Mac shell; shared service/adapter inventory; real playback + status panel proof; migration/distribution design. | Play/pause/skip, close/reopen, checkpoint restore, and data access work on Mac. Update remaining estimate from evidence. | 3–5 days |
| E. Native Mac implementation | Essential app pages, native Settings/status panel, adapters, lifecycle, migration. | Feature parity agreed explicitly; no missing existing essentials hidden by the new shell. | 4–8 weeks, provisional |
| F. Mac release QA | Migration fixtures, playback/stats soak tests, accessibility, signing and distribution rehearsal. | Acceptance matrix below passes on minimum and current supported macOS. | 1–2 weeks |

Release one can stand alone, but it does not fulfil the persistent icon requirement. The full request is complete only when release two's status panel and lifecycle are delivered. If stage D exposes a significantly larger port, revise scope/timing before implementing the full shell.

## 10. Acceptance tests

- Every custom menu item invokes the same behaviour as its in-app equivalent; unavailable actions are disabled and execution revalidates them.
- Shortcuts work from Player, Subscriptions, Discover, Stats, child details, and supported modal contexts; editing a feed URL or search query never skips audio or archives content accidentally.
- Mouse menu selection, keyboard shortcut, mini player, status panel, and media keys produce matching playback/queue results.
- Skip-forward at the episode boundary and Next Episode preserve completion, resume-point clearing, auto-archive, Play Instant cancellation, and stats accounting exactly once.
- Empty queue, missing download, offline feeds, removed subscription, buffering, repeated commands, and rapid episode changes behave safely and visibly.
- Menu bar panel responds while another app is active; it neither steals focus for background updates nor duplicates the main playback service.
- Close/reopen, hide/unhide, Quit/relaunch, sleep/wake, Bluetooth output changes, and network changes preserve correct state.
- Native Mac upgrade tests cover local-only and iCloud-enabled users, existing downloads, history/stats, subscription order, and user preferences.
- Accessibility checks cover VoiceOver, Full Keyboard Access, focus order, shortcut discovery, large text, high contrast, menu bar overflow, and multiple displays.
- Measure CPU/memory with the status panel open and closed; hidden UI must not maintain unnecessary progress rendering or polling.
- Test a real Apple-silicon Mac on minimum/current supported macOS. Add Intel testing only if the dedicated Mac release explicitly supports Intel. iOS Simulator builds alone do not validate desktop menus or the status panel.

## 11. Proposed source organisation

- App/AppCommand.swift, App/AppCommandHandler.swift: shared actions and validation.
- App/AppCommandContext.swift: readiness, selection, focus, and operation availability.
- App/AppMenuBuilder.swift: UIKit menu and responder adapter for release one.
- App/AppDelegate.swift: menu integration without eager service bootstrap.
- App/AppRoutingCoordinator.swift and Views/RootView.swift: typed route/presentation handling.
- Views/PodcastSearchView.swift and list views: focus and selection publication.
- Mac/App/AutohopMacApp.swift: native scenes and application-owned composition root.
- Mac/Commands/AutohopMacCommands.swift: SwiftUI Commands adapter using the shared action catalogue.
- Mac/Views/MenuBarPlayerView.swift and Mac/Views/MacSettingsView.swift: desktop surfaces.
- Mac/Platform/: audio, lifecycle, windowing, file, and system-integration adapters.
- Tests/: domain command behaviour and routing validation; dedicated Mac UI tests for focus, menus, and lifecycle.
- project.yml: target/source membership and platform-specific exclusions, followed by XcodeGen regeneration. Update Package.swift explicitly when extracting shared code; adding a folder must not accidentally compile desktop-only code into the existing iOS or TV targets.

The first implementation step should be stage A, followed by the shared command layer. This gives existing Mac installations useful improvements while establishing the same actions needed by the later native menu bar player.
