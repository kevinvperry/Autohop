# Mini player coverage audit — 6 September 2026

<!--
AI CONTEXT — Docs/MINI_PLAYER_AUDIT_2026-09-06.md
Source coverage audit for shared iOS-family navigation and mini-player ownership.
Preserve intentional modal exceptions and resolved-detail ownership; never add
a second inset around a page that already owns one. This is not a device walkthrough.
-->

Audited the iOS-family navigation destinations, including nested views declared
inside other view files, root routes, direct NavigationLinks, and modal entry
points. The shared iPhone/iPad/iOS-on-Mac views follow PAGES.md's rule that every
pushed page docks MiniPlayerBar. This is a source audit, not a visual walkthrough
on each device.

## Missing coverage fixed

| Destination | Entry point | Fix |
| --- | --- | --- |
| Top Shows (up to 50 shows) | Stats → Top Shows → Show All | Added the shared bottom inset to TopShowsListView. |
| Add RSS Feed | Search or Settings | Added the shared bottom inset to AddFeedView. |
| Diagnostic Log | Settings → unlocked diagnostic log | Added the shared bottom inset to DiagnosticLogView. |
| Release Radar Data | Feed Refresh Schedule → subscription diagnostics | Added the shared bottom inset to SubscriptionRadarDiagnosticsView. |
| Publisher/creator results | Search → Publishers & Creators | Added the shared bottom inset to PodcastCreatorResultsView. |
| Episode search loading/unavailable states | Search → episode result | Added the inset separately to both states. The resolved EpisodeDetailView already owns its inset, so it does not receive a duplicate. |

## Existing coverage confirmed

- Subscriptions uses a direct safeAreaInset with MiniPlayerBar, hidden during
  priority reordering as specified by the navigation rules.
- Discover, Podcast Search, Top Episodes, and Top Podcasts/category pages.
- Podcast Detail, Episode Detail, Podcast Settings, and Download Feed Filters.
- Stats, Listening History, Downloads, and Auto Archive Activity.
- Settings, Notification Settings, Feed Refresh Schedule, and Sleep Schedule.
- Support, individual Support sections, and Acknowledgements.
- Menu provides its own richer MenuMiniPlayer; its pushed destinations provide
  the standard mini player.

## Surfaces without the standard mini player

These are separate presentation types rather than missed pushed-page insets:

- Main Player and full-screen video provide their own playback controls.
- Up Next, Audio Controls, Sleep Timer, Listening Recaps, sharing, artwork
  previews, archive confirmation, and title/priority/skip editing are modal
  sheets or system presentations.
- Welcome, Starter Packs, the first-subscription card, launch splash, coach
  marks, and onboarding overlays are onboarding or transient surfaces.
- The separate tvOS app has no iOS MiniPlayerBar implementation. Its Home,
  Discover, Library, Search, History, Diagnostics, and nested details use the TV
  navigation/player architecture, with a full-screen TVPlayerView. No TV UI
  redesign was made by this fix.

MiniPlayerBar itself intentionally renders only when a current episode exists,
including when paused. A blank bar while nothing is loaded is not expected.

## Validation

- Reviewed every titled iOS-family view and all direct/root navigation targets.
- Reviewed conditional episode-search rendering to avoid duplicate players.
- Built the Autohop scheme for the iOS Simulator in Debug with signing disabled.
- Checked whitespace with git diff --check.

## Subscription search keyboard space

Subscriptions intentionally removes its mini-player safe-area inset while inline
search is focused, so it cannot occupy the results area above the keyboard.
Done, Cancel or focus loss restores it, including when the query remains applied.
The existing reorder exception remains. This is presentation-only; playback is
not paused or restarted. Focus-based behaviour also applies to hardware keyboards.


## Bottom safe-area repair — 20 September 2026

<!-- AI CONTEXT — One background includes material, purple tint and glass through
 the home-indicator area. Expand that background's layout to the actual safe area;
never apply glass only above progress or offset a patch outside its bounds. -->

The original Stats screenshot showed readable rows below the progress strip.
Replacing an offset 64-point patch with a safe-area material background fixed
coverage, but left a darker band because glass still covered only the bar. The
follow-up screenshot confirmed that mismatch. `PersistentMiniPlayerSurface` now
renders material, tint and glass together in one background extended into the
bottom container safe area. The progress strip is over this continuous surface;
it no longer separates two different treatments. Content layout and controls are
unchanged. Both `.miniPlayerBar()` and Subscriptions' direct inset use this surface.

Validation: build and hosted page/sheet captures passed on iOS 27 and iOS 26.5
simulators. All four screenshots were inspected for both coverage and colour
continuity. On iOS 27 the centre samples 10 pixels above/below the progress strip
were RGB (79, 57, 85) and (79, 57, 84), confirming removal of the abrupt dark band.
These are fixture measurements, not a promise of identical pixels over every
backdrop; native glass retains its adaptive lighting. `git diff --check` passed.
Result bundles: `/tmp/autohop-miniplayer-glass27.xcresult` and
`/tmp/autohop-miniplayer-glass26.xcresult`; exports: `/tmp/autohop-glass27-images`
and `/tmp/autohop-glass26-images`.
The fixture uses the production surface over synthetic scrolling rows; it does
not start audio or mutate the library. Physical-device, rotation, iPad and every
populated destination remain unverified.
