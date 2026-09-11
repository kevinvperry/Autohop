# Discover, mini-player and Mac session — 6 September 2026

<!--
AI CONTEXT — Docs/SESSION_CHANGES_2026-09-06.md
Cross-reference and verification record for this session, reconciled after an
incomplete documentation pass. FEATURES/PAGES/DESIGN own current product contracts;
VERSION_1.7.md owns the running change ledger. Source headers explain local
ownership and regression constraints. Preserve verification limits and do not
attribute other dirty working-tree changes to this session or claim an upload.
Release update (2026-09-06): user confirmed Mac Menu crash resolved; issue closed.
User confirmed iOS-family 1.6.1 approved and live on 8 September 2026.
Its ledger is closed; all future changes belong in VERSION_1.7.md.
-->

## Release preparation follow-up

Relabelled the running ledger to 1.6.1, corrected iOS rejection status, updated
app/widget marketing versions and regenerated the project. Combined release/review
metadata and outstanding validation are in [the submission record](AppStore/1.6.1/SUBMISSION.md).
Configuration validation passed; no distribution upload or remote submission occurred.

## Scope and ownership

| Change | Files and responsibilities | Regression constraints |
| --- | --- | --- |
| Category charts | `Feeds/PodcastCharts.swift`, `Views/TopPodcastsView.swift`, `Views/DiscoverView.swift` | Category Top-8 episodes above Top-100 shows; shared hero component/metrics; show features at 8, 16, … 96. Overall Top-50 charts keep their existing cadence. Independent episode loading/retry. |
| Artwork | `Feeds/PodcastCharts.swift`, `Views/DiscoverView.swift`, `Tests/ArtworkURLTests.swift` | Decode episodeArtwork and icon separately; JSON NSNull is not an absent dictionary key. Resolve 600px templates; retain a show URL for failure fallback via the existing CachedArtworkImage pipeline. Version category cache keys; decode older optional-field caches. |
| Mini-player omissions | `Views/StatsView.swift`, `Views/AddFeedView.swift`, `Views/DiagnosticLogView.swift`, `Views/SubscriptionRadarDiagnosticsView.swift`, `Views/PodcastSearchView.swift` | Nested destinations need coverage too. Stats Show All lists shows. Resolved Episode Detail already owns a player; loading/unavailable states need their own. |
| Desktop commands | `App/DesktopCommands.swift`, `Views/DesktopCommandContext.swift`, `App/AppDelegate.swift`, `App/AutohopApp.swift`, `App/AppState.swift`, `App/AppRoutingCoordinator.swift`, `Views/RootView.swift` | One service graph; per-command selectors work without sender metadata; visible normal-window fallback during menu tracking; typed navigation and existing playback/library workflows. |
| Desktop page integration | `Views/PodcastsView.swift`, `Views/PlayerView.swift`, `Views/PodcastDetailView.swift`, `Views/SubscriptionSettingsView.swift`, `Views/SettingsView.swift`, `Views/PodcastSearchView.swift` | Visible show/episode IDs and nearest Back context; preserve text editing; focus Search on request; reuse import/export workflows once; player-only guarded Space shortcut. |
| Mac Menu crash | `Views/CoachMark.swift`, `Views/MenuSheetView.swift`, `Views/QueueSheetView.swift`, `Views/RootView.swift`, `Views/PlayerView.swift` | Pass the existing coordinator explicitly to all four CoachMarkOverlay hosts. No overlay EnvironmentObject lookup during early presentation evaluation. Keep live updates and tip policy. |
| Regression coverage | `Tests/DesktopCommandTests.swift`, `Tests/AppStateCoordinatorExtractionTests.swift`, `Tests/ArtworkURLTests.swift` | Keep policy tests distinct from live-host timing and physical-device verification. Existing `Tests/EpisodeCompletionWorkflowTests.swift` documents the completion path reused by desktop Next; no separate desktop completion pipeline. |
| Target membership | `project.yml`, generated `Autohop.xcodeproj/project.pbxproj` | Mac work belongs to the existing iOS-family target. Edit membership through XcodeGen; no native Mac/status-icon target was added. Generated project headers are not edited manually. |

Existing accurate headers, including the completion-workflow test header, remain
valid. This reconciliation adds missing structured headers and updates stale ones;
it does not replace unrelated Stats, sync, persistence or tvOS documentation work
already present in the shared working tree.

## Documentation map

- [FEATURES](../FEATURES.md): category behaviour, artwork fallback, Mac feature scope,
  mini-player coverage and Quick Tip crash fix.
- [PAGES](../PAGES.md): category naming/depth, Mac routes and Stats Show All identity.
- [DESIGN](../DESIGN.md): shared category hero style, distinct show-feature cadence,
  artwork and mini-player ownership, modal tip placement.
- [README](../README.md) and [project brief](../project_autohop.md): corrected
  category-depth summary and links to current implementation evidence.
- [Version 1.6.1 ledger](../VERSION_1.6.1.md): completed changes and this reconciliation.
  Version 1.6 remains the closed submission ledger; a 1.6 TestFlight crash report
  identifies the observed build and does not reopen that historical ledger.
- [Mini-player audit](MINI_PLAYER_AUDIT_2026-09-06.md): full coverage and exceptions.
- [Mac plan](MAC_MENU_AND_DESKTOP_IMPLEMENTATION_PLAN.md): staged proposal;
  [Mac stage one](MAC_MENU_STAGE_1.md): implementation and follow-up evidence.

## Verification evidence and limits

- Initial Mac stage: 15 selected tests passed (11 command tests, three existing
  completion regressions, one typed-routing regression), as recorded in the Mac
  implementation notes. Following disabled-menu fixes, all 13 command tests passed.
- Menu crash fix: environment-free overlay rendering and two tip-policy tests
  passed. Twelve command tests passed in the combined run; the live hosted routing
  test failed its visible-page assertions, then passed on an isolated rerun.
  Do not describe that combined run as fully green.
- Signed Mac Designed-for-iPad builds succeeded for the menu fixes. The exact
  TestFlight mouse-click flow and physical keyboard/media-key behaviour still
  require device verification. No upload is recorded for these fixes.
- Artwork fix: all 10 ArtworkURLTests passed. A live AU Comedy category sample
  returned HTTP 200 image/jpeg for all eight selected URLs: three episode images
  and five show covers. This is a sample, not a guarantee for every remote image.
- Mini-player coverage is a source audit, not a visual test of every device/page.
- This reconciliation changes documentation and comments only; runtime tests are
  not repeated solely for those edits. Headers provide context and constraints;
  they complement executable regression tests rather than guarantee correctness.

## Completion rule for future changes

Read the touched file's AI header first. Update its purpose, collaborators,
behaviour and invariants when they change, including tests and nested views.
Update the relevant canonical documents and VERSION_1.7.md in the same task.
Check for contradictory older statements, and record actual validation limits.
Keep historical audits/submission ledgers historical; link current corrections
rather than silently rewriting past evidence. Generated files remain governed by
their authoritative inputs.

## Subsequent Menu crash report

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

## Onboarding card overlap and clipping — 6 September 2026

While the first-subscription milestone is presented, OnboardingCoordinator hides
Quick Tips across all overlay hosts through visibleTip. The active tip retains
its page ownership and is not marked seen; cancellation while hidden prevents it
returning on an unrelated page. RootView enables suppression before presenting
and clears it when the sheet dismisses.

FirstSubscribeCard opens at the large detent with Play/Add more shows in a bottom
safe-area inset; explanatory content scrolls above those actions. Quick Tip
scroll content uses a minimum height measured from its actual overlay bounds,
not a fixed container-relative height, so long text can scroll to its dismissal
button. The sheet receives the existing shared app environment explicitly.


Validation: the signed iPad simulator build and all four selected onboarding
regressions pass (milestone suppression/cancellation, environment-free overlay
rendering, and existing page-tip cancellation/promotion). The supplied screenshot
identified the overlapping surfaces; these automated checks are not a visual
walkthrough of every iPad orientation or accessibility text size.

## Episode Detail artwork and actions — 6 September 2026

Episode Detail measures its actual page container to scale square artwork from
120pt on compact phones up to 320pt on large iPad/Mac windows. The cache receives
the matching display target size. Play, Play Next, Play Last and the state-dependent
fourth action form a centred group beneath the header. Four columns become two
on narrow pages; Download/Archive/Unarchive behaviour remains state-dependent.
Shared sizing lives in AdaptiveEpisodeDetailMetrics in AdaptiveLayout.swift;
EpisodeDetailView remains nested in SubscriptionSettingsView.swift.


Episode Detail validation: signed iPad simulator build succeeds; diff whitespace
checks pass. This layout-only change does not alter playback/library actions.
A visual walkthrough across orientations remains unperformed.

## Podcast episode row navigation — 6 September 2026

Tapping anywhere on an episode row in Podcast Detail (the subscription page)
opens EpisodeDetailView for that episode. Titles and description previews no
longer expand inline: they retain two- and three-line limits respectively.
The existing leading/trailing swipe actions and their full-swipe policy are
unchanged. The show's header description and Up Next expansion are separate
interactions and retain their existing behaviour.


Episode-row validation: signed iPad simulator build and diff whitespace checks
pass. Source review confirms the leading/trailing swipe blocks are unchanged.
Physical tap/swipe interaction has not been visually exercised in this task.

## Search existing subscriptions — 6 September 2026

The magnifying glass beside Discover reveals a rounded inline search field below
the Subscriptions title and focuses the keyboard. As the user types, the existing
list filters immediately by show or publisher name using localized case/diacritic-
insensitive matching. Surrounding whitespace is ignored. Only real subscriptions
are searched, including inactive shows; no Discover request or remote lookup is made.

The clear icon restores all rows and keeps the field open. Cancel clears the query,
dismisses the keyboard and closes the field. Keyboard Done dismisses the keyboard
while retaining the filtered list. A no-results message appears when nothing
matches. Original priority numbers and active/inactive ordering remain unchanged.
Priority is disabled while the search field is open, and Search is disabled during
reordering, preventing filtered IDs from entering the persistence transaction.
The mini-player remains available. On iOS 26 a fixed toolbar spacer keeps Search
and Discover in separate native glass groups. This replaces the initial modal
search dialog; no separate Search confirmation is required.


Inline-search validation: signed iPad simulator build and diff whitespace checks
pass. Source review confirms direct query binding updates the display filter
without changing stored subscriptions or reorder IDs. Visual device review of
keyboard/layout transitions remains outstanding.

## Subscription search keyboard space

Subscriptions intentionally removes its mini-player safe-area inset while inline
search is focused, so it cannot occupy the results area above the keyboard.
Done, Cancel or focus loss restores it, including when the query remains applied.
The existing reorder exception remains. This is presentation-only; playback is
not paused or restarted. Focus-based behaviour also applies to hardware keyboards.

Keyboard-space validation: signed iPad simulator build and diff whitespace checks
pass. No playback or persistence code changed. Physical keyboard/layout transitions
have not been visually exercised in this task.

## Downloads episode lists — 6 September 2026

Downloads uses native List sections for Downloading, Downloaded on Device and
Recently Archived so rows support standard swipe actions. Leading actions are
Play (green) and Play Next (blue); trailing actions are Archive (purple) and Play
Last (orange). Full-swipe execution is disabled. Inline archive buttons are removed;
Pause/Resume/Retry transfer controls and archived Re-download remain available.

All rows use AdaptiveListRowMetrics from actual container width for artwork and
matching cache decode targets, title/secondary fonts, spacing and status text.
Playback actions require a live episode, download first if needed and re-resolve
the episode after awaiting; failed downloads are not queued or played. Activity
Archive uses archiveDownload to cancel transfers and maintain file/model/activity
consistency. Playing episodes do not offer archive/requeue swipes. Historical
rows without a live episode retain their information without playback actions.


Downloads validation: signed iPad simulator build and all eight existing
QueueModelTests pass. These verify queue ordering, not physical swipe delivery.
Diff whitespace checks pass; visual swipe/layout validation on devices remains
outstanding. No transfer, persistence or queue engine implementation changed.

## Downloads row layout follow-up

Artwork is vertically centred beside the full-width text column. Episode titles
have up to three lines, publisher/show names two, and metadata can wrap. Media
badges and status pills occupy a separate bottom band with status at the right,
so they cannot squeeze the title or publisher. Archived rows place Re-download
in the same lower band. Transfer progress and swipe actions are unchanged.

Signed iPad simulator build and diff whitespace checks pass. This follow-up
changes row layout only; device visual verification is not claimed.
