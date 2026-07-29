# Autohop Viewport Resizability Audit — 30 July 2026

<!--
AI CONTEXT — Docs/RESIZABILITY_AUDIT_2026-07-30.md

PURPOSE: Source-based inventory of every user-facing iOS view and shared visual
component, identifying low-risk layout changes that improve use of the
available viewport before iPad and Mac support are enabled. This is the audit
artifact required by Phase 0 of RESPONSIVE_LAYOUT_PROPOSAL.md.

STATUS: AUDIT COMPLETE; EASY-WIN IMPLEMENTATION PACKAGE LANDED 2026-07-30.
The target family and navigation model remain unchanged. Visual simulator and
device testing is still required; later macro-layout work remains in the
governing proposal.

SCOPE: 40 iOS SwiftUI files in `Views/`, including sheets, overlays, player
chrome, onboarding and shared cards, plus the UIKit video surface. The widget
extension received a family-coverage check because widgets also appear on
iPhone and iPad. tvOS, watchOS, CarPlay templates, website layout and the
fixed-size exported share image are outside this viewport audit.

EVIDENCE RULE: Findings below describe the code as it exists on 30 July 2026.
They are not claims that every risk reproduces on hardware. Static inspection
can establish rigid constraints and missing adaptation; Xcode previews,
simulators and devices must establish the resulting appearance.

RELATED: Docs/RESPONSIVE_LAYOUT_PROPOSAL.md is the governing phased plan.
DESIGN.md becomes the home of reusable layout patterns after implementation.
-->

## 1. Outcome

Autohop does not need a wholesale visual rewrite to gain meaningful viewport
resilience. Most `List`, `Form` and ordinary scrolling pages already compress
reasonably on current iPhones. The easiest wins are concentrated in five
patterns:

1. fixed-height sheets that can clip in a short viewport or look undersized in
   a large one;
2. dense horizontal rows that assume phone-portrait width;
3. metadata grids that always force exactly two columns;
4. editorial/list content that expands without a readable maximum width; and
5. hero cards, charts and onboarding panels with fixed heights but no response
   to the available height.

These can be addressed without enabling iPad, adding a Mac target, replacing
the navigation hierarchy or redesigning the main player. That makes them the
appropriate first implementation phase.

### Mechanical evidence

The current tree contains four fixed-count `LazyVGrid` definitions and one
correctly adaptive example in `SupportView`; seven sheet presentations use
fixed point heights; `ViewThatFits` is unused; and only the Search show rail
currently uses `containerRelativeFrame`. There are 224 explicit
`.font(.system(size: ...))` declarations. These numbers identify audit sites,
not automatic replacements: a deliberate three-choice grid or display font
may remain fixed if it has an accessible fallback and passes the viewport
matrix.

## 2. Viewport model for implementation and QA

Layout must respond to the space offered by its immediate container, not to a
device model or `horizontalSizeClass`. Preserve the provisional bands already
locked in `RESPONSIVE_LAYOUT_PROPOSAL.md` until visual testing justifies a
centralised adjustment:

| Band | Provisional available width | Representative situations |
|---|---:|---|
| Narrow | below 340 pt | very small phone, narrow resizable window, large text |
| Standard | 340–499 pt | current portrait iPhones |
| Wide | 500–699 pt | landscape phone, half-width tablet window |
| Expansive | 700 pt and above | full iPad, large resizable/Mac window |

Every changed surface should be checked at minimum in:

- a narrow portrait viewport with Dynamic Type XL;
- a current standard iPhone in portrait;
- a current large iPhone in landscape;
- approximately half an iPad window;
- a near-square 700 pt-class window; and
- full 11-inch and 13-inch iPad widths once iPad is enabled.

The first phase may prepare the views for the last three cases without yet
advertising those platforms as supported.

## 3. Ranked easy wins

### EW-01 — Introduce one adaptive-layout vocabulary (highest leverage)

Create `Views/AdaptiveLayout.swift` containing only reusable, testable layout
decisions: width-band classification, gutters, readable content widths,
artwork ranges and grid-column helpers. No view should introduce its own
breakpoint. Suggested initial maximums, to be tuned visually, are approximately
720 pt for prose/forms, 900 pt for dense lists and 1,100 pt for editorial
surfaces.

**Why first:** every subsequent change otherwise creates more magic numbers.
**Risk:** low. The helper does nothing until views adopt it.

### EW-02 — Make sheets content-safe instead of height-fixed

Replace hard-coded heights with scrollable content and adaptive
`.medium`/`.large` presentation where appropriate. Priority surfaces:

- `FirstSubscribeCard` (currently fixed around 470/540 pt);
- `SleepTimerSheetView` (fixed compact/expanded heights);
- subscription title and priority editors;
- Settings skip-time editor; and
- Player archive and audio-control sheets.

Keep deliberately compact sheets compact when the content fits, but always
offer a larger detent and scrolling for short landscape windows and large
text. Existing share sheets already follow this safer pattern.

**Benefit:** removes a predictable clipping class with little design change.
**Risk:** low.

### EW-03 — Give dense rows a compact fallback with `ViewThatFits`

Use semantic alternatives, not geometry arithmetic. Preserve the current row
when it fits; otherwise wrap, stack or hide the least important label. Apply
first to:

- Player top controls and audio-route row;
- Sleep Timer's end-of-episode action row;
- Stats hero metrics;
- Episode Detail action buttons and dense metadata; and
- row trailing controls in Downloads and Subscription Settings.

Add `layoutPriority` to the primary title and make secondary copy the first
thing that truncates. Icons must retain at least a 44×44 pt interactive hit
area even when their visible glyph is smaller.

**Benefit:** immediate improvement on small phones, landscape and larger text.
**Risk:** low to moderate because player controls require interaction checks.

### EW-04 — Make repeated metadata grids adaptive

Replace unconditional two-column grids with adaptive columns that naturally
become one column when each pill cannot retain a useful minimum width and add
columns only when the viewport supports them. Primary sites are Player
Details and Episode Detail. Stats dashboards can use the same helper later.

**Benefit:** eliminates cramped pills without phone-model branching.
**Risk:** low.

### EW-05 — Add readable maximum widths to wide layouts

Centre inner content on large viewports while allowing backgrounds, lists and
progress chrome to continue filling the window. Start with long-form pages and
forms: Support, Settings, Subscription Settings, Episode Detail, Add Feed,
Acknowledgements, diagnostics and onboarding. Apply a wider list maximum to
Downloads, Podcasts, Queue and search results.

Do not blindly place `.frame(maxWidth:)` on a native `List` or `Form` in a way
that breaks its background, separators or safe areas. Constrain an appropriate
inner container or section content.

**Benefit:** substantial iPad/Mac readability gain with minimal phone impact.
**Risk:** low, but native list styling must be visually checked.

### EW-06 — Make onboarding safe in short viewports

`WelcomeView` and `FirstSubscribeCard` currently depend on fixed hero sizes and
a vertically stacked call-to-action area. Make descriptive content scrollable,
cap its readable width, keep the primary action in a safe-area inset, and
allow the hero illustration to reduce when height is constrained. Resize must
not reset the current onboarding page.

**Benefit:** prevents the app's first experience from clipping in landscape or
large text.
**Risk:** low to moderate.

### EW-07 — Clamp editorial cards and charts rather than stretching them

For Discover hero cards, Top Episodes/Podcasts feature cards and Stats charts,
derive height from a clamped aspect/available range. Adapt shelf item size so
wide screens reveal a useful number of complete cards instead of stretching
one hero or displaying many undersized tiles. Keep horizontal shelves for this
phase; expansive multi-column dashboards belong to the later iPad phase.

**Benefit:** better use of width without changing information architecture.
**Risk:** moderate because visual tuning is required.

### EW-08 — Refine the Podcast Detail header

Use `ViewThatFits` or the central width band to retain the current artwork/text
header when it fits and stack it vertically when it does not. Cap the header
and episode list widths on expansive viewports. Replace nested geometry-based
truncation probes where a semantic wrapping layout can provide the result.

**Benefit:** removes a known squeeze point on narrow widths and an over-stretch
on large ones.
**Risk:** moderate.

### EW-09 — Centre Mini Player content on wide windows

Keep its progress line and material background full width, but cap and centre
the artwork/title/control cluster. At narrow widths, retain the episode title
before the podcast name and optional time label. This preserves the compact
player's identity without creating an iPad redesign.

**Benefit:** easy visual polish at both width extremes.
**Risk:** low.

### EW-10 — Clamp coach marks to the visible safe area

Coach-mark placement must use the current window/container and safe-area
insets, then choose a viable side or centre presentation. It must never depend
on a remembered device width. Resize while a coach mark is visible must move
the overlay without restarting the tour.

**Benefit:** avoids detached or off-screen guidance.
**Risk:** moderate because all anchors need a test pass.

### EW-11 — Couple Dynamic Type work to reflow testing

Explicit point-sized fonts are widespread. Do not bulk-replace all 224 sites:
some are intentional display typography or compact badges. Classify them by
role, migrate ordinary body/headline/caption text to semantic text styles, and
use `@ScaledMetric` for custom display sizes that should grow. Every migration
must be checked with its row or card's compact fallback because the current
fixed sizes can hide a reflow defect.

**Benefit:** makes responsive layouts accessible instead of merely geometric.
**Risk:** moderate; a mechanical search-and-replace would cause regressions.

## 4. Implemented first package

The following contained package was implemented on 2026-07-30 before enabling
new device families:

1. EW-01 adaptive vocabulary plus pure unit tests for bands and grid helpers.
2. EW-02 all fixed-height sheet conversions.
3. EW-03 compact fallbacks for Player, Sleep Timer, Stats hero and Episode
   Detail.
4. EW-04 adaptive metadata grids.
5. EW-05 readable-width treatment for non-player pages.
6. EW-06 onboarding height resilience.
7. EW-09 Mini Player inner-width and text-priority refinement.
8. Begin EW-11 with the same touched surfaces; do not attempt a repository-wide
   font migration in this package.

Defer EW-07, EW-08 and EW-10 to a second visual package if the first package
becomes too large to review confidently. None of these tasks requires turning
on `TARGETED_DEVICE_FAMILY = 1,2`.

### Explicitly not an easy win

Do not combine this package with:

- enabling the iPad device family;
- adding `NavigationSplitView` or a new Mac/Catalyst target;
- replacing the Player's three-panel navigation with a wide side-by-side
  composition;
- changing orientation ownership for video; or
- adopting unverified future fold/toolbar APIs.

Those changes have wider navigation, playback, release and state-restoration
blast radii and remain in later phases of the governing proposal.

## 5. Complete surface audit

| Surface | Current viewport behaviour | Easy-win action | Priority |
|---|---|---|---|
| `PlayerView` | Portrait-oriented panel stack; crowded top/audio rows; fixed two-column metadata; several fixed sheet sizes | Compact `ViewThatFits` rows, adaptive metadata grid and safe sheets now; wide side-by-side player later | P0 |
| `RootView` / Mini Player | Flexible centre but uncapped content spans very wide windows; secondary text competes at narrow widths | Full-width chrome with centred capped inner row; title priority and narrow fallback | P0 |
| `QueueSheetView` | List rows are mostly flexible; fixed rank/art/trailing metadata can compress | Adaptive presentation, readable list width and invisible 44 pt targets for small controls | P1 |
| `PodcastsView` | Main list is reasonably flexible; empty state uses fixed 104 pt artwork and broad padding | Max list width; adaptive empty-state padding/art scale; prioritise titles over badges | P1 |
| `DiscoverView` | Fixed 320/284 pt hero heights and 124 pt shelf items | Clamp hero size; adapt shelf tile range and insets | P1 |
| `PodcastSearchView` | Show rail is already a strong container-relative pattern; lists still span indefinitely at wide widths | Preserve rail model; cap result widths; consider two-column results only at expansive widths | P1 |
| `PodcastDetailView` | Forced 128 pt-artwork horizontal header; nested geometry probes; unbounded wide layout | Stack header when cramped; cap content; remove avoidable geometry probes | P1 |
| `EpisodeDetailView` | Fixed 120 pt art/action composition and forced two-column metadata | Compact actions, adaptive metadata grid, readable content width | P0 |
| `StatsView` | Forced three-across hero; charts fixed around 150–230 pt; broad single column | Wrap hero; clamp chart heights; cap width now, dashboard columns later | P0/P1 |
| `TopEpisodesView` | Feature card around 232 pt high; compact rows fixed around 84 pt art | Clamp feature aspect/height; stack compact row when narrow | P1 |
| `TopPodcastsView` | Same fixed feature/compact-card family | Share the Top content adaptive pattern | P1 |
| `DownloadsView` | List is mostly flexible; title/progress/status/trailing controls can compete | Title priority, compact controls and readable list width | P1 |
| `SettingsView` / Listening History | Native Form/List is safe on phones but too broad on large windows; skip editor fixed around 300 pt | Readable form width and adaptive skip editor | P0 |
| `SubscriptionSettingsView` | Form is safe; title/priority editors fixed around 220/230 pt | Readable form width and adaptive editors | P0 |
| `DownloadFiltersView` | Standard form/list behaviour | Verify, cap readable width; no redesign | P2 |
| `NotificationSettingsView` | Flexible list with fixed artwork | Readable width and title priority; verify only otherwise | P2 |
| `SleepTimerSheetView` | Fixed 240/380 pt presentation; dense end-of-episode row; fixed three-column grid | Scrollable detents, `ViewThatFits` row and adaptive columns | P0 |
| `SleepScheduleView` | Standard Form | Readable width and verification only | P2 |
| `WelcomeView` | Fixed hero/waveform sizes and non-scrolling vertical composition | Scroll-safe content, responsive hero and safe-area CTA | P0 |
| `FirstSubscribeCard` | Fixed sheet heights | Adaptive scrollable sheet, capped content | P0 |
| `GettingStartedChecklist` | Flexible rows; icon sizing is intentional | Cap readable width; retain 24 pt icon | P2 |
| `StarterPacksView` | Scrollable cards work on phones but remain a long narrow column on wide screens | Max width now; adaptive multi-column pack layout later | P1 |
| `CoachMark` | Anchor/card placement assumes phone geometry | Safe-area/window clamping and viable-side fallback | P1 |
| `SupportView` | Adaptive pill grid is already strong; prose can become too wide | Preserve grid; cap prose width | P1 |
| `AcknowledgementsView` | Standard list/prose | Cap prose/list width and verify wrapping | P2 |
| `AddFeedView` | Standard form | Cap readable form width | P2 |
| `AutoArchiveActivityView` | Standard list | Cap list width; verify empty state | P2 |
| `DiagnosticLogView` | Dense diagnostic text can become excessively wide | Readable/monospaced line width while preserving copying | P2 |
| `FeedRefreshScheduleView` | Fixed 86 pt key column can squeeze localized values | Semantic Grid or vertical narrow fallback | P1 |
| `SubscriptionRadarDiagnosticsView` | Fixed weekday/value widths | Grid alignment and narrow fallback | P2 |
| `MenuSheetView` | Navigation/list content is naturally flexible | Presentation and max-width verification | P2 |
| `PlaybackControlsCard` | Intentional compact controls; labels may compete | Retain target sizes; prioritise values and wrap/stack labels | P1 |
| `AudioRoutePickerView` | System route picker wrapper | No viewport change beyond maintaining a 44 pt hit area | Verify |
| `NativeVideoPlayerView` | AVPlayer layer fills bounds; orientation requests are host-sensitive | Preserve resizing without recreating player; orientation work remains separate Phase 0 task | Separate |
| `EpisodeShareSheet` / `PodcastShareSheet` | Recently changed to scrollable medium/large sheets | Verify at narrow width and large text; no new architecture | Verify |
| `EpisodeShareCardView` | Deliberately fixed export canvas | No responsive conversion; it is an output artifact | N/A |
| `CachedArtworkImage` / `EpisodeBadges` | Shared primitives accept caller sizing | No independent change; audit each caller | N/A |
| `RecapSettingsView` | Form/sheet composition | Readable width and adaptive sheet presentation | P1 |
| `AutohopProSettingsView` | Development-only Form | No release work; apply shared width pattern if re-enabled | P3 |
| `NowPlayingUpNextWidget` | Explicit small/medium/large and accessory render paths already respond to WidgetKit families | Preserve family-specific compositions; verify iPad widget families and Dynamic Type during Phase 1 QA | Verify |

## 6. Verification and acceptance criteria

An easy-win conversion is complete only when:

- no title, primary value or actionable control is clipped at any canonical
  width;
- all actions retain at least a 44×44 pt hit area;
- a short landscape viewport can reach every sheet action by scrolling;
- Dynamic Type XL does not overlap controls;
- wide layouts keep prose readable and do not stretch artwork unnaturally;
- resizing does not dismiss a sheet, reset navigation/onboarding, recreate
  playback or move the user to a different panel; and
- current standard-iPhone portrait appearance remains intentionally familiar.

The implementation should produce a screenshot matrix rather than relying on
one simulator. Physical-device confirmation remains necessary for Player,
Mini Player, sheet gestures, keyboard/search interaction and video playback.
