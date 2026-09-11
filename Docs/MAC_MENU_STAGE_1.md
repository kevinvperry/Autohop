# Mac application menus — stage one

<!--
AI CONTEXT — Docs/MAC_MENU_STAGE_1.md
Implementation and validation record for iPad-on-Mac menus and shortcuts.
Keep command behaviour aligned with DesktopCommands and DesktopCommandContext.
Preserve dated follow-up evidence and distinguish simulator/build checks from
physical Mac/TestFlight verification; no status-icon implementation is claimed.
Release update (2026-09-06): user confirmed Mac Menu crash resolved; issue closed.
iOS app/widget release candidate is 1.6.1 (17). This does not imply submission.
-->

Implemented 6 September 2026 for the existing iOS/iPadOS application, including its Apple-silicon Mac installation mode. No native Mac target or persistent status icon is introduced in this stage.

## Available menus

- **Autohop:** Settings…, alongside the system's About, Hide, Services, and Quit commands.
- **File:** Add RSS Feed…, Import Subscriptions…, Export Subscriptions…. System window-closing behaviour is retained; irrelevant document/new-window/printing actions are removed.
- **Edit:** Find Podcasts…, with normal system editing commands preserved.
- **View:** Player, Subscriptions, Discover, Up Next, Listening History, Stats, Downloads, Back.
- **Playback:** Play/Pause, configured-duration skips, Next Episode, previous/next chapter, the existing 1.0–2.5× speed choices, Audio Controls…, Sleep Timer…, Sleep Schedule….
- **Podcast:** Open Show, Show Settings…, Subscribe/Unsubscribe, Refresh Show, Refresh All Shows, Download Episode, Play Next, Play Last, Archive Episode….
- **Help:** Autohop Help, Keyboard Shortcuts, Acknowledgements.

Show/episode commands use the visible Podcast Detail, Episode Detail, Podcast Settings, or Player context. They do not use an unrelated previously visited show. The full Subscriptions list does not yet introduce a separate row-selection model; open a show to use its contextual menu commands. Unsubscribe and archive require confirmation. Menus reflect current availability, play/pause state, skip intervals, and speed checkmarks.

## Keyboard reference

| Action | Shortcut |
| --- | --- |
| Settings | Command-comma |
| Find Podcasts | Command-F |
| Add RSS Feed | Command-N |
| Import / Export subscriptions | Command-Shift-I / Command-Shift-E |
| Player / Subscriptions / Discover | Command-1 / Command-2 / Command-3 |
| Up Next / History / Stats / Downloads | Command-4 / Command-5 / Command-6 / Command-7 |
| Back | Command-[ |
| Play/Pause | Command-Return |
| Play/Pause on Player, without a focused editor/control | Space |
| Skip back / forward | Command-Left / Command-Right |
| Previous / next chapter | Command-Option-Left / Command-Option-Right |
| Next episode | Command-Shift-Right |
| Refresh visible show / all shows | Command-R / Command-Shift-R |

The same catalogue generates the in-app Help → Keyboard Shortcuts page. Shortcuts are app-local, not global hotkeys. Existing media-key handling remains unchanged. Transport/navigation keys yield to system text editing and focus behaviour; global destination shortcuts remain usable from Search. Navigation to another page is disabled while a modal is presented, so it cannot silently dismiss an editing dialog. Close the dialog first.

## Implementation

`DesktopCommands.swift` owns the semantic catalogue, menu construction, validation policy, and action dispatcher. Existing playback, queue, completion, import, and subscription workflows remain authoritative. The dispatcher revalidates state at invocation and coalesces overlapping asynchronous transport/library operations. Play Next/Last use the existing download-before-queue behaviour. Forward skipping and Next Episode preserve the normal completion and stats paths.

On iOS 26 and corresponding Mac runtimes, `UIMainMenuSystem.setBuildConfiguration` installs an explicit build callback at application launch. Older runtimes use `buildMenu(with:)`. Both builders are idempotent and do not bootstrap application services.

A `DesktopHostingController` provides a reachable responder above the SwiftUI navigation stack. This is needed because a `UIApplicationDelegateAdaptor` object is not itself a reliable action target in that stack. The host receives the already-created command handler and explicitly supplied environment objects. It does not create another AppState or playback engine. It becomes first responder only when no editor/control has focus.

Small context controllers attached to page shells expose the visible page's identities and ambient Back action. The lookup follows only the visible navigation/presentation branch. `AppRoutingCoordinator` supplies typed destination commands; RootView retains NavigationPath ownership. Audio Controls and Sleep Timer use the existing panel views over the current page. Import/export enter Settings' existing file-presentation flow.

## Verification and remaining device checks

Automated checks cover shortcut uniqueness, standard editing key preservation, available speed parity, empty/busy/chapter/selection/modal validation, menu command identifiers, and hidden-page context exclusion. Hosted integration checks exercise the real responder chain, destination routing, Back to the permanent Player, search focus, navigation while searching, and registration of the complete menu catalogue on iPadOS 26.

The Mac “Designed for iPad” build succeeds. The initial stage-one signed iPad Simulator run passed all 15 selected tests: 11 desktop-command tests, three episode-completion regressions, and one existing typed-routing regression. Unsigned test execution is unsuitable here: the existing CloudKit startup requires the app's signing entitlements.

Manual Mac inspection was attempted but Computer Use was waiting for Accessibility and Screen Recording permissions. Visual menu placement, physical keyboard/media-key behaviour, and older supported macOS/iPadOS runtimes still need a device walkthrough. A simulator pass is not a substitute for those checks.

## TestFlight follow-up: all Mac commands disabled

The initial integration test passed a UICommand as the sender, which missed a
native-menu validation failure. The adapter required that sender type and its
propertyList even during canPerformAction, and window lookup required a key
window throughout menu tracking. Both assumptions have been removed.

Each command now has a distinct, statically implemented Objective-C selector.
Validation and execution identify the command from the selector, accepting nil
or bridged senders. Both the hosting controller and application delegate expose
those actions and forward to the existing handler. Visible normal application
windows remain eligible while menu tracking temporarily clears key status;
hidden and overlay windows are excluded. Availability rules still disable
commands when their actual playback, selection, or modal prerequisites are absent.

Regression coverage now includes nil/non-UICommand senders, commands without
property-list metadata, delegate fallback dispatch, selector coverage, and loss
of key-window status. This fixes source for a subsequent build; it does not
modify an already installed TestFlight binary.

Follow-up validation: all 13 desktop-command tests pass, including the live
responder and delegate dispatch checks. The Mac “Designed for iPad” build also
succeeds. The updated binary has not been uploaded to TestFlight in this task.

## TestFlight follow-up: Subscriptions Menu crash

The 1.6 (14) Mac crash report identifies an `EnvironmentObject.error()` in
`CoachMarkOverlay.body` while SwiftUI creates its presentation host. The overlay
looked up `OnboardingCoordinator` before the presentation supplied its inherited
environment, even when no tip was active.

`CoachMarkOverlay` now takes the existing coordinator as an explicit
`@ObservedObject`. All four hosts (RootView, MenuSheetView, QueueSheetView and the
Player's Podcast Settings presentation) supply it. Tip updates, page ownership,
and dismissal continue to use the same coordinator; no tips are removed.

Verification: the new environment-free rendering regression and both onboarding
navigation-policy tests pass. Twelve desktop-command tests passed in the same
run; the hosted navigation integration test failed its initial visible-page
check, then passed on an isolated rerun. The signed Mac “Designed for iPad” build
succeeds. The exact mouse-click flow still requires verification in a new Mac
TestFlight build; this change has not been uploaded.

## Continued Mac Menu crash — full dependency boundary

The user reports that Menu still crashes in the latest installed Mac TestFlight
build while iPhone works. This supersedes any implication that the earlier
CoachMark-only fix established resolution. The user subsequently confirmed resolution on 6 September 2026; this
issue is complete. An exact failing frame was not established for that later report.

Both PlayerView and PodcastsView now apply `appEnvironment(appState)` inside
the Menu presentation closure. The shared helper in AutohopApp.swift supplies
exactly the existing bootstrap dependency set to Menu, its mini-player and
navigation descendants. Root bootstrap uses the same helper to prevent drift.
The explicit CoachMark coordinator remains in place. No new services are created.

DesktopCommandTests now presents the complete Menu through DesktopHostingController
with no ambient app services, in both compact-sheet and regular-fullscreen modes.
This tests the full dependency boundary rather than only rendering the tip overlay.
A simulator presentation test cannot confirm the user's exact Mac crash without
a matching crash report and Mac verification. The code change has not been uploaded.

Validation for the full-boundary follow-up: all 14 DesktopCommandTests pass on
the signed iPad simulator, including complete Menu presentation in both size
classes. Initial readiness assertions failed before attachment; the tests now
wait for actual visible context/window attachment rather than fixed short delays.
The signed Mac Designed-for-iPad build succeeds. These results do not establish
that the unprovided latest Mac crash report has the same root cause.
