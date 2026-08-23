# iOS-Family Asset Responsiveness Audit — 23 August 2026

<!--
AI CONTEXT — IOS_FAMILY_ASSET_RESPONSIVENESS_AUDIT_2026-08-23.md
Implementation audit for every SwiftUI surface in the shared iOS-family app.
Use this document when adding or resizing visual assets for iPhone, iPad,
resizable Mac windows or future intermediate/folding widths. The governing
rule is container-driven scaling through AdaptiveLayout.swift: enlarge
meaningful page chrome and content, cap reading measures, and preserve fixed
semantic geometry such as touch minima, progress tracks and export canvases.
This records implemented source state, not a speculative proposal.
-->

## Outcome

The Discover page's four-band, container-width strategy is now the common
navigation and persistent-player strategy across the iOS-family app. Inline
titles, icon-only toolbar controls, text toolbar actions, chart country controls
and the mini-player respond to the width actually offered by their current
window or split-view column. Standard iPhone dimensions remain unchanged.

The audit deliberately does not multiply every numeric constant. Large-screen
quality depends on distinguishing assets that convey page hierarchy from small
geometry that encodes state or interaction.

## Shared rules implemented

| Asset class | Large-screen behaviour | Reason |
|---|---|---|
| Inline navigation title | 17 / 22 / 28 pt by container band | Restores hierarchy on iPad and Mac while preserving iPhone |
| Icon toolbar control | Symbol scales; host is capped at 44 pt vertically | Prevents cropped circular controls in UIKit's fixed toolbar slot |
| Text/label toolbar action | Typography scales; natural width retained | Avoids phone-sized actions without forcing oversized buttons |
| Country/search navigation control | Reads the same injected viewport width | Keeps trailing controls proportionate to the title |
| Mini-player artwork/control | 40→46→52 pt with proportional spacing | Persistent chrome no longer looks detached from enlarged pages |
| Editorial content | Existing adaptive artwork/cards/type remain capped at 1,100 pt | More information is visible without unbounded stretching |
| Lists and forms | Preserve native semantic type; cap custom list/form content at 900/720 pt | Controls line length and scanning distance |
| Presentations | Compact sheets on iPhone; regular-width page/native modal treatment | Supports iPad and Mac without device-name branching |

### Follow-up: universal list-row implementation

Every native `List` and `Form` now applies `responsiveListSizing()`. The shared
row metrics preserve the established 44-point iPhone artwork baseline, then use
52 points on wide columns and 60 points on expansive columns. Explicit
image-led rows—subscriptions, podcast episodes, Up Next, Player Up Next, search,
downloads, history and notification selection—also scale their primary and
secondary text, spacing, padding, corner radius and progress indentation.
Support, acknowledgements, activity and diagnostic rows use the same typography
and density bands. Existing Discover, chart and Stats rows retain their richer
editorial metrics because those already meet or exceed this baseline.

The follow-up coordinated-element pass also closes the hierarchy gap outside
rows. Podcast Detail now scales description, publisher, categories, Subscribe
and notification controls with its title and artwork. Shared Video/Explicit and
episode-status pills scale everywhere they are reused; Settings labels and trim
controls do the same. The audit criterion is therefore the whole component—not
only its most visually prominent text or image.

An iPad screenshot comparison subsequently exposed an environment-ownership
defect: Subscriptions and Up Next constructed their rows in the parent view,
while the measured width had only been injected below that parent. Both stayed
on the 390-point fallback despite their responsive-looking navigation titles.
The root NavigationStack now distributes the live viewport width. Their row
copy, metadata, artwork, markers, action controls, expanded descriptions and
pills therefore select the same actual wide/expansive band as Podcast Detail.

### Episode-list horizontal measure follow-up

Podcast Detail's 20-point compact gutter and 860-point maximum card width is now
the canonical vertical episode-list measure. The shared modifier is applied to
Podcast Detail, Subscriptions, Up Next, Listening History, Downloads, Search
episode results and Auto Archive Activity. Discover's horizontal episode rails,
Top Episodes editorial charts and Player's single embedded Up Next card were
audited and retained as documented host-composition exceptions.

The related Subscriptions Priority/refresh row now uses the same outer column
instead of spanning the viewport. A navigation comparison also found two
exceptions: Podcast Detail's toolbar and Player's custom top bar. Both now use
the shared large-screen navigation bands for symbols, labels, pill heights,
flash artwork and hit targets, including the Player empty state.

Native toolbar follow-up: circular Back symbols and taller utility symbols now
use separate responsive modifiers. Utility icons are bounded to the shared
control-font band inside the native 44-point host, preventing Share clipping on
iPad/Mac, while compact circular Back artwork retains its larger dedicated band.

### Expansive Settings shortcut navigation

System Settings and Individual Subscription Settings now use otherwise-unused
expansive width for a fixed 240-point shortcut rail beside the existing Form.
The rail scrolls the right pane to stable major-section anchors, stays visible,
retains keyboard focus and tracks appearing sections. Conditional shortcuts
(developer Diagnostics and podcast Chapters) mirror the rendered Form. Below
the expansive band—including narrow iPad multitasking—the original single-column
structure and navigation remain unchanged.

Device validation found that Form virtualization also makes distant concrete row
IDs unavailable to `ScrollViewReader`. The final implementation keeps headers as
visibility observers but bridges shortcut requests to the native Form
collection/table and scrolls by explicit section index. This remains addressable
before SwiftUI realizes the destination rows. Shortcut labels exactly mirror the
visible headings. The two-pane workspace is centred within 960 points in
landscape, and the rail, Form and surrounding canvas now share solid black.
The bridge discovers the full-sized visible native list by content extent rather
than relying on an invisible SwiftUI marker's UIKit coordinates, then
synchronizes layout and makes one bounded retry if presentation is still racing.
Shortcut destinations centre their first control vertically, leaving the
supplementary section heading and neighbouring context visible.

## Page-by-page audit

### Primary navigation and playback

- `RootView` / `MiniPlayerBar`: upgraded. Artwork, play control, padding and
  corner treatment use shared width bands; progress geometry remains fixed.
- `PlayerView`: already uses container-derived player metrics and adaptive
  presentations. Playback waveform, scrubber and video surface retain semantic
  geometry; modal and share-sheet repairs remain unified.
- `PodcastsView`: upgraded title, Menu control and Add Podcast action. Native
  list rows retain semantic Dynamic Type and readable list behaviour.
- `QueueSheetView`: upgraded title and shared close control. Episode rows remain
  list-density assets; their artwork is intentionally not expanded into cards.
- `MenuSheetView`: upgraded title and shared close control.

### Editorial, discovery and detail

- `DiscoverView`: reference implementation; heading, navigation controls,
  search, shelves, cards, artwork and spacing use shared bands.
- `PodcastSearchView`: upgraded root/group headings and search action; result
  grids and detail presentations already use adaptive width helpers.
- `PodcastDetailView`: repaired after the audit exposed an ideal-size regression.
  Below a 600-point content column its artwork stays top-leading and title,
  description, badges and metadata stay beside it, protecting episode-list
  height. At 600+ points the complete header becomes a centred editorial hero.
  Its empty system title is retained because that hero supplies the heading.
- `TopEpisodesView`, `TopPodcastsView`: upgraded title/back chrome; existing
  adaptive ranked rows and country picker share the measured width.
- `StatsView`: upgraded Stats and Top Shows headings plus recap action; existing
  charts, cards, grids and ranked artwork remain adaptive.
- `StarterPacksView`: upgraded heading and completion action; existing pack
  cards remain adaptive.
- `WelcomeView`, `FirstSubscribeCard`, `GettingStartedChecklist`, `CoachMark`:
  existing responsive onboarding/card constraints retained.

### Library management, settings and support

- `SettingsView`: upgraded Settings, editor and Listening History headings,
  back action and editor actions. Native Form and Dynamic Type remain the
  correct large-screen pattern.
- `SubscriptionSettingsView`: upgraded subscription, edit and filter headings,
  back/share and save/cancel actions. Episode-detail empty title is retained.
- `DownloadsView`, `AutoArchiveActivityView`, `FeedRefreshScheduleView`,
  `DiagnosticLogView`, `AcknowledgementsView`, `AddFeedView`,
  `SleepScheduleView`: upgraded titles and applicable toolbar controls.
- `NotificationSettingsView`: upgraded settings and recap headings; native
  grouped controls remain semantic rather than visually inflated.
- `SupportView`: upgraded support index and article headings; prose remains
  bounded to a readable measure.
- `SubscriptionRadarDiagnosticsView`: upgraded heading; diagnostic values retain
  monospaced/readable semantics.

### Modals and supporting assets

- `EpisodeShareSheet`, `PodcastShareSheet`, `SleepTimerSheetView` and audio
  controls use adaptive presentation policies. Share-card export pixels remain
  deterministic so output is stable across devices.
- `PlaybackControlsCard`, `AudioRoutePickerView`, `NativeVideoPlayerView` and
  `CachedArtworkImage` are embedded components whose size is owned by the page
  container; no global screen lookup was introduced.
- `EpisodeBadges` remains intrinsic because badges encode compact metadata, not
  page hierarchy. `OPMLDocument` and `SupportContent` contain data rather than
  page assets and require no visual scaling.

## Fixed-size exceptions

Do not mechanically scale 44-point minimum targets or toolbar host heights;
waveform bars, progress tracks, scrubber thickness and state indicators;
compact badges/status pills; share/export canvas pixels; native Form/List row
geometry and separators; or platform-provided video and route-picker controls.

## Future acceptance criteria

Check each new page at narrow and standard iPhone widths, iPad split view,
full-width iPad and a resizable iOS-on-Mac window. Derive decisions from offered
container width, preserve Dynamic Type, avoid `UIScreen` sizing, cap prose/list
measures, keep controls inside the 44-point toolbar slot, and document any
deliberately fixed visual geometry.
