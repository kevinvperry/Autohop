# iOS 27 Back button audit — 20 September 2026

<!-- AI CONTEXT — Evidence and route coverage for the shared Back compatibility repair.
Keep source headers, FEATURES.md, PAGES.md, DESIGN.md, project_autohop.md and
VERSION_1.7.md aligned when these contracts change. Simulator/source evidence does
not establish physical-device or release validation. -->

## Report and repair

The supplied Discover screenshot shows the system chevron and Autohop's filled
circle chevron side by side. Discover already applied
`navigationBarBackButtonHidden(true)` before adding its custom leading toolbar
item. The screenshot therefore demonstrates the failure of that combination on
the reported iOS 27 device; it is not a missing hide modifier. The precise
SwiftUI framework cause has not been established.

`appNavigationBackButton()` now owns both visibility and toolbar content:

- iOS 27 and later: allow the native Back control and add no custom leading item.
- iOS 17–26: retain the existing branded Back button and hide native Back.
- Podcast Detail and Podcast Settings presented from Player as modal stack roots:
  retain the explicit dismiss button on every version. Those roots have no
  previous stack destination and cannot rely on native Back.

Native Back and the existing custom button both preserve the nearest navigation
parent. No outer navigation path, playback, mini-player, chart content, country
picker or trailing toolbar actions were changed.

## Source audit coverage

Checked every Swift file for navigation containers, links, destinations,
presentations, leading toolbar items, back/left-chevron symbols and dismiss
controls. Cross-checked the route tree in PAGES.md, RootView's typed and desktop
routes, local Discover/chart destinations, Menu's stack and Player's modal stacks.

| Page / state | Finding and action |
| --- | --- |
| Discover — loading, failed, loaded; Subscriptions, Menu, welcome, widget and desktop routes | Shared policy replaces the competing system/custom controls. |
| Top Episodes | Shared policy; country picker preserved. |
| Top Podcasts and all category charts | Same shared view/policy; country picker preserved. |
| Podcast Detail — subscribed, inactive, browse preview, loading and unavailable | Shared policy; modal root explicitly retains dismiss. |
| Podcast Settings | Shared policy; modal root explicitly retains dismiss. |
| Episode Detail | Shared policy, including search-resolved episodes. |
| Download Feed Filters | Shared policy. |
| Podcast Replay | Shared policy. |
| Starting Episode picker | Shared policy. |
| Add RSS Feed | Shared policy. |
| App Settings | Shared policy. |
| Feed Refresh Schedule | Shared policy. |
| Auto Archive Activity | Shared policy. |
| Acknowledgements | Shared policy. |
| Diagnostic Log | Shared policy. |
| Downloads | Shared policy. |
| Sleep Schedule | Shared policy. |
| Keyboard Shortcuts | Shared policy. |
| Subscriptions | Menu occupies the leading slot; no custom Back exists. Existing native-Back suppression retained. |
| Search; Publishers & Creators results | Native Back only; no competing custom item. |
| Episode-search destination — loading/unavailable | Native Back only; resolved state uses Episode Detail's policy. |
| Stats; Top Shows | Native Back only. |
| Listening History | Native Back only. |
| Notification Settings | Native Back only. |
| Support; individual guide sections | Native Back only. |
| Release Radar Data | Native Back only, including unavailable state. |
| Player and full-screen video | Own full-screen controls; no custom navigation-bar Back pair. |
| Menu, Up Next, Listening Recaps, Audio Controls, Sleep Timer | Informational presentation controls; no competing custom Back. |
| Starter Packs, Welcome, first-subscription card and coach marks | Own onboarding/presentation controls; no competing custom Back. |
| Edit Title, Edit Priority, skip-duration editor, sharing/artwork/system sheets and confirmation dialogs | Modal/editing controls; no competing custom Back. |
| tvOS and widget sources | No copy of the affected custom iOS toolbar pattern; unchanged. |

There are 18 migrated destination implementations. A repeated source scan finds
one remaining construction of `NavigationBackButton`, inside the shared policy.
Subscriptions is the only separate page that explicitly hides native Back.

## Validation

The new `NavigationChromeTests` hosts real SwiftUI destinations and inspects the
rendered UINavigationItem, then invokes ambient dismissal to check that the
immediate parent remains. It covers Discover, 16 other migrated destinations,
six native-only destinations, Subscriptions and both modal root variants. The
private Starting Episode picker and private native-only child views were source
audited. Missing-subscription destinations exercise their unavailable states;
they do not establish populated-library or playback-state coverage.

- Xcode 27 simulator application and test-bundle build: passed.
- iOS 27.0, iPhone 18 Pro: all 5 tests passed, 0 failures; 26 destination/presentation variants checked.
- iOS 26.5, iPhone 17 Pro Max: all 5 tests passed, 0 failures; the same 26 variants checked.
- Discover screenshot review: one native chevron on iOS 27; one branded chevron on iOS 26.5. Both retain the title and country picker. The 26.5 screenshot also shows the existing mini-player.
- Parent-preserving ambient dismissal and both modal-root dismissals passed on both runtimes.
- `git diff --check`: passed.

Result bundles: `/tmp/autohop-nav-fixed27.xcresult` and
`/tmp/autohop-nav-verified26.xcresult`.
Screenshots saved in
`/Users/kevinperry/Documents/Codex/2026-09-20/autohop-navigation-audit/`.

The first test count assertion used legacy `leftBarButtonItems`, which is empty
for SwiftUI's modern toolbar. It was corrected to inspect `leadingItemGroups`
with a legacy fallback; the screenshots independently confirm the visible result.

Physical iPhone/iPad/Mac interaction, swipe-back gestures, VoiceOver and every
populated-library state have not been manually verified. No physical-device
installation, release archive or upload was performed.

The baseline app built with Xcode 27. The first iOS 27 hosted baseline run stalled
before executing tests in a synchronous UserNotifications service call during
launch; a process sample identified that wait. It was interrupted. No simulator
baseline reproduction or passing test is claimed from that run. Restarting the
simulator notification service allowed the subsequent iOS 27 verification run to
complete; production notification code was not changed for this task.

Apple's documented meaning of the original modifier is to hide the navigation
back button: [navigationBarBackButtonHidden](https://developer.apple.com/documentation/swiftui/view/navigationbarbackbuttonhidden(_:)). The compatibility repair avoids relying on that suppression for a custom pushed-page Back on iOS 27.
