# Autohop Design System

<!--
AI CONTEXT — DESIGN.md
Canonical visual-pattern reference for AI/code changes. PAGES.md owns page names;
FEATURES.md owns behaviour/defaults. The visible playback-order sheet is "Up
Next"; `QueueSheetView`, `downloadedQueue`, and `QueueAction-Animation` remain
implementation/design-token names. When editing UI, preserve the app-wide dark
mode, purple accent semantics, glass-ready iOS 26 fallbacks, fixed row geometry,
and the labeled pattern names below so future prompts can target them.
Subscriptions Reorder is a local UUID-draft interaction: only active real
subscriptions receive drag grips, Inactive rows remain fixed below them, and
browse previews are absent from the visual/index space. Done commits once.
Version 1.3 presents only the iPhone design system. Retained Apple TV and
Autohop Pro screens are development references and are not shipping surfaces.
-->

> **Page names & navigation structure** → see [`PAGES.md`](PAGES.md)

The **Priority**, **Up Next**, **Downloads**, **Individual Subscription**, and **Individual Episode** pages are the canonical design references for Autohop. All other pages must match the patterns defined here. Each pattern has a **label** so it can be referenced directly in future instructions (e.g. "apply `EpisodeStatusPill` to the History page").

---

## Quick Reference

| Label | What it controls |
|---|---|
| `ColorScheme-Dark` | Every page forces dark mode — no white or light screens |
| `Accent-Purple` | Purple is the highlight colour for buttons, icons, active states, and progress |
| `AppIcon-GlassReady` | iOS app icon source: vivid purple Liquid Glass-ready background, launch-splash-matched lavender and green waveform bars, centred white skip chevron |
| `NavTitle-Inline` | Page title in the centre of the top bar, not as a large heading |
| `NavBack-Standard` | Pushed pages: brand back chevron top-left, nothing else in that corner |
| `SheetClose-Standard` | Informational sheets: ✕ close button top-right, no Done/Cancel |
| `Sheet-MaterialBackground` | Player sheets use `.presentationBackground(.regularMaterial)` (Liquid Glass on iOS 26) to match the system AirPlay picker — not a solid fill |
| `MiniPlayer-Bar` | Now-playing bar docked at the bottom of every pushed page; tap to return to Player |
| `List-Plain` | Lists use `.plain` style; row backgrounds do the visual separating |
| `Section-Heading` | Bold `title3` section label above each card group |
| `Section-CardList` | A `List` or `VStack` wrapped in a `white.opacity(0.08)` rounded-rect card |
| `Glass-Card` | Shared `glassCard(cornerRadius:)` View modifier (`Views/EpisodeBadges.swift`) — iOS 26 glass surface, `.ultraThinMaterial` fallback. Used by Podcast Detail episode list + Episode Detail description card |
| `Glass-Capsule` | Shared `glassCapsule(highlighted:)` View modifier (`Views/EpisodeBadges.swift`) — iOS 26 glass capsule pill; `highlighted: true` adds purple tint. Used by Discover chips, rank badges, Subscriptions reorder toggle |
| `Section-CardRows` | Inside a card: `VStack(spacing: 0)` rows separated by `Divider` with `white.opacity(0.08)` tint |
| `ListRow-Standard` | Up Next episode row: position · artwork · text stack · spacer · trailing metadata |
| `ListRow-SubscriptionRow` | Priority page row: rank number · artwork · subscription+episode text stack · status pill |
| `ListRow-EpisodeRow` | Individual Subscription episode row: artwork · title · description · metadata + pill · optional progress bar |
| `ListRow-ActiveBackground` | Currently playing row gets `Color.purple.opacity(0.08)` background |
| `ListRow-IdleBackground` | Non-playing rows in a card list use `Color.white.opacity(0.08)` |
| `PositionIndicator-Playing` | Up Next number replaced by a small purple `play.fill` icon when the episode is playing |
| `Artwork-Placeholder` | Purple-to-black gradient + waveform icon when no artwork URL is available |
| `Text-PodcastTitle` | Show name: `.caption`, `.secondary`, above the episode title |
| `Text-SubscriptionTitle` | Priority page show name: `.headline.weight(.bold)`, `.primary` — it is the primary title |
| `Text-EpisodeTitle` | Episode title: `.subheadline.bold()`, `.primary`, `lineLimit(2)` |
| `Text-EpisodeTitleSecondary` | Priority page episode title: `.subheadline` (not bold), `.secondary`, `lineLimit(2)` |
| `Text-MetadataRow` | Date + duration/remaining on one line, separated by `•`, caption, secondary |
| `Text-MetadataAdaptive` | Duration shows "Xm left remaining" when partially played, full duration otherwise |
| `Text-Duration` | Total duration: `.caption`, `.secondary`, `.monospacedDigit()` |
| `EpisodeStatusPill` | Colour-coded capsule pill showing episode state — 8 states, each a unique colour |
| `Badge-VideoPillSmall` | Small icon-only TV indicator — no glass or capsule; used in dense episode list rows |
| `Badge-VideoPillLarge` | Large clear glass "Video" text pill — used in detail page headers alongside `Badge-ExplicitPillLarge` |
| `Badge-ExplicitPillLarge` | Large clear glass "Explicit" text pill — used in detail page headers alongside `Badge-VideoPillLarge` |
| `Badge-ExplicitPillSmall` | Small icon-only "E in square" indicator (iTunes-style) — no glass or capsule |
| `Badge-RankPill` | Liquid glass capsule pill centred below artwork on Priority page, stacked vertically below VideoPillSmall and ExplicitPillLarge |
| `Button-DownloadInline` | Bordered small "Download" button inline in the metadata row for undownloaded episodes |
| `Badge-Pin` | `pin.fill` icon in trailing stack: blue = Play Next, orange = Play Last |
| `SwipeActions-EpisodeRow` | Swipe actions on episode rows: Play / Play Next (leading), and trailing far-right Download/Archive · Play Last. The trailing far-right button is state-driven: downloaded → Archive; not-downloaded on a subscribed + active feed → Download (teal); on non-subscribed previews or Inactive subs it falls back to Archive/Unarchive. Episode Detail uses the same primary-action rule in its fourth circle button. |
| `SwipeColor-Semantics` | green=play, blue=promote, teal=download/queue, purple=primary action, orange=demote, red=destructive |
| `Header-SubscriptionPage` | Centred channel header: 120pt artwork · title · Video+Explicit pills · description · bold author + bold categories |
| `Toolbar-SubscriptionPage` | Individual Subscription toolbar: Return to Player leading, Refresh Feed + Settings trailing |
| `Toolbar-NavigationPage` | Priority page toolbar: 3 leading buttons + 2 trailing icon buttons |
| `Toolbar-SheetStandard` | Up Next sheet toolbar: shortcut left · bordered action centre · Done right |
| `Button-ReturnToPlayer` | `play.circle.fill` — always first leading button, returns to player from anywhere |
| `Button-MenuHamburger` | `line.3.horizontal` — opens `MenuSheetView` |
| `Button-ReorderToggle` | Plain text "Reorder"/"Done" — toggles drag-to-reorder mode |
| `Button-RefreshAll` | `arrow.clockwise` trailing button — shows spinner while loading, hidden when list empty |
| `Button-AddFeed` | `plus` trailing button — opens the Find Podcasts search sheet |
| `Button-ToolbarAction` | Bordered, regular size, icon-only, shows `ProgressView` while async work runs |
| `Button-ContextualShortcut` | Downloads button in the Up Next toolbar — navigates + pulses purple when a download is active |
| `Indicator-PulsingIcon` | `easeInOut` 0.6s repeating scale pulse for active background state |
| `EmptyState-ContentUnavailable` | `ContentUnavailableView` with system image + description for empty lists |
| `ProgressBar-Download` | `ProgressView(value:total:)` tinted `.purple`, animated `.linear(0.3s)` — used on Priority, Subscription episode, Listening History, and Downloads rows |
| `Row-DownloadActivity` | Downloads page active/completed download row layout |
| `Row-ArchivedEpisode` | Downloads page recently-archived row: artwork · text stack · re-download button |
| `TopBar-Player` | Main Player top bar: Priority list icon · panel tabs · Up Next count pill |
| `Panel-NowPlaying` | Main Player now-playing panel — artwork · chapter strip · episode copy · scrubber · controls · audio row · Up Next row |
| `Panel-Details` | Main Player details panel — episode title · metadata · description image · `HTMLDescriptionText` · meta cards grid |
| `Panel-Chapters` | Main Player chapters panel — chapter rows with skip toggle + All/None controls |
| `Artwork-Player` | Dynamically sized artwork behind a purple radial glow; cornerRadius adapts for chapters |
| `EpisodeCopy-Player` | Centred episode title (16pt bold) + tappable subscription name (12pt gray) |
| `Scrubber-Player` | Purple `Slider` + elapsed (left) / remaining (right) time labels, restored on first render from the canonical playback clock so a resumed episode opens at the correct thumb position |
| `Controls-Player` | Skip-back icon · 76pt purple-tinted-glass play/pause button · skip-forward icon |
| `AudioRow-Player` | Five-button row: Sound Settings · Sleep Timer · AirPlay route picker (centre) · Share · Archive |
| `Button-PlayerAction` | Player action pill: purple icon on glass via `Player-GlassPill` (idle neutral glass, active purple-tinted). Used by audio-row buttons + top-bar Up Next / Sleep Schedule pills |
| `Player-GlassPill` | Shared `playerGlassPill(highlighted:cornerRadius:)` modifier (`Views/PlayerView.swift`): iOS 26 glass (neutral / purple-tinted when highlighted), `purple.opacity(0.12)` fill + stroke fallback |
| `ArchiveConfirmationSheet` | Bottom sheet confirming archive of the currently playing episode — matches dark card style of Sleep Timer and Audio Controls sheets |
| `UpNextRow-Player` | Up Next episode row — `ListRow-Standard` layout with custom drag gesture (not `.swipeActions`) |
| `MetaCard-Details` | Two-column grid of key/value cards on the Details panel |
| `AudioControls-Sheet` | Audio controls bottom sheet: Speed stepper · Trim Silence toggle + picker · Vocal Boost toggle + picker |
| `Card-PlaybackControls` | Shared Speed / Trim Silence / Vocal Boost / optional Volume Adjustment / Mono Audio card (`Views/PlaybackControlsCard.swift`). Per-podcast settings enable the −3…+3 dB adjustment between Vocal Boost and Mono; global Default Playback deliberately omits it. iOS 26: `.glassCard(cornerRadius:12)` card + `.glassCard(cornerRadius:10)` stepper. iOS 17–25: flat `fill` background. The `usesHostBackground` flag lets App Settings inherit its Form surface; Podcast Settings retains the self-contained glass card. |
| `ControlRow-EpisodeTrim` | Shared start/end skip row (`EpisodeTrimControlRow`) used in both App Settings and Podcast Settings: title + compact duration text on the left, fixed capsule minus/plus controls on the right, 5-second steps, 0–300s bounds, minute/second wording ("1 min 30 secs"), debounced persistence, and no playback/store-driven animation. Podcast Settings hosts both rows in one `glassCard`, matching its Automation section. |
| `Form-SettingsDark` | Settings page recipe. **App Settings (`SettingsView`)** — "defined glass" on iOS 26: `scrollContentBackground(.visible)` native Liquid Glass Form sections lifted by a faint `white.opacity(0.05)` row tint over a `black.opacity(0.5)` page base, 36pt section spacing; the shared Default Playback card orders Speed, Trim Silence, Vocal Boost, then Mono Audio. Mono Audio uses the same full-width segmented-selector treatment as the two multi-level audio controls, with explicit Stereo/Mono states. The card uses `usesHostBackground: true` to match. **Podcast Settings (`SubscriptionSettingsView`)** — every section's row background uses the same regular `glassEffect` surface as the Playback controls card (`sectionRowBackground`) so the whole page reads as one consistent glass treatment; the Automation toggles (notifications, feed-refresh exclusion, and Play Instant) are rendered inside one divided `glassCard` to avoid per-row glass shade variance. iOS 17–25 (both pages): `scrollContentBackground(.hidden)` over `Color.black`, `white.opacity(0.08)` row cards, 36pt spacing. |
| `SettingsRowLabel` | Purple SF Symbol (16pt semibold) + primary-colour title row label (`Views/PlaybackControlsCard.swift`), used on every control row across the settings flow — mirrors the Speed / Trim / Vocal rows |
| `HTMLDescriptionText` | Full-fidelity HTML episode description: `NSAttributedString` parsed, fonts normalised to SF, links purple, first image extracted |
| `Header-EpisodePage` | Centred episode header: 120pt artwork · title · Video+Explicit pills · feed title · categories |
| `Buttons-EpisodePage` | Four equal-width circle buttons in one row: Play (green) · Play Next (blue) · Play Last (orange) · state-driven Download (teal) / Archive / Unarchive (purple) |
| `Description-EpisodePage` | HTMLDescriptionText inside a `white.opacity(0.08)` card, with `Section-Heading` label above |
| `MetaGrid-EpisodePage` | Two-column MetaCard-Details grid: Published · Duration · File Size · Classification · File Status · Priority Rank |
| `Toolbar-EpisodePage` | Episode page toolbar: Return to Player leading only, empty nav title |
| `Selector-PeriodPills` | Stats page period selector: glass capsule pill row, purple-tinted glass selected / plain glass unselected |
| `Selector-ThisLast` | Stats This/Last bar (`StatsView.swift`): a **solid** two-segment capsule — flat `white.opacity(0.10)` track + 3pt inset, purple sliding chip on the active side — deliberately *unlike* the glass `Selector-PeriodPills`. Content-width (narrow), centered, contextual labels ("This Week / Last Week", "This Month / Last Month", "This Year / Last Year"). Hidden on Lifetime or when the previous period has no data, except recap notification deep links still show their intended Last period |
| `Card-StatsHero` | Stats hero card: big purple time-listened number + three stat columns (time saved teal) |
| `Chart-Heatmap` | GitHub-style listening heatmap (30/90d) or Swift Charts monthly bars (1y/lifetime) |
| `Chart-ListeningClock` | 24-hour rose chart in Canvas — wedge radius scales with listening per hour |
| `Chart-DataDownloaded` | Stats Data Downloaded card: cyan total + mini-stats + cyan bar chart of download volume over time |
| `ListRow-TopShow` | Stats top-shows row: rank · 44pt artwork · title + relative purple bar · duration |
| `Card-ShowStatsExpanded` | Stats inline per-show detail card: tap a Top Shows / Drifting row to toggle; 2-column stat-tile grid in a nested `white.opacity(0.05)` card |
| `Card-TopEpisodeFeature` | Top Episodes page large feature card (`Views/TopEpisodesView.swift`): full-width purple→black gradient, oversized ghosted rank numeral top-trailing, 140pt artwork + `#rank` capsule, title (2 lines), show, relative time. One every 7th rank (1/8/15/22/29/36/43) |
| `ListRow-TopEpisode` | Top Episodes page compact row: rank numeral · 84pt artwork · episode title (2 lines) + show + relative publish time |
| `QueueAction-Animation` | Up Next swipe-action animations + haptics (see Swipe Actions — Episode Rows section; token name stays legacy) |

---

## Color Scheme

**Label: `ColorScheme-Dark`**

All sheets and navigation stacks use a forced dark color scheme.

```swift
.preferredColorScheme(.dark)
```

---

## Accent Color

**Label: `Accent-Purple`**

Purple (`Color.purple`) is the primary accent throughout the app:
- Active/playing state indicators and row backgrounds
- Tints on primary action buttons and archive actions
- Artwork placeholder gradients
- Progress bars (`ProgressView.tint(.purple)`)
- Contextual shortcut button when active

---

## App Icon

**Label: `AppIcon-GlassReady`**

The app icon source of truth is [`Design/AppIcon/autohop-icon-v1.svg`](Design/AppIcon/autohop-icon-v1.svg). The Xcode-facing PNGs live in [`Assets.xcassets/AppIcon.appiconset`](Assets.xcassets/AppIcon.appiconset) and must be regenerated whenever the SVG changes.

Current visual recipe:

- **Background** — iOS 26 Liquid Glass-ready purple gradient: `#7C61FF` → `#5B3FD6` → `#4930B8`, plus a soft white top-left glow. Avoid returning to dark navy; the glass overlay muddies it.
- **Left waveform** — four enlarged rounded bars based on the startup-animation lavender family from `LaunchLoadingView`: `Color(red: 0.66, green: 0.62, blue: 0.91)` / `#A89EE8`, a deliberately brighter tallest bar `#D4CEFF`, `Color(red: 0.69, green: 0.66, blue: 0.93)` / `#B0A8ED`, and `Color(red: 0.60, green: 0.56, blue: 0.89)` / `#998FE3`.
- **Centre chevron** — strong white skip-forward mark, visually centred between the waveform groups and thick enough to read at small icon sizes.
- **Right waveform** — four enlarged rounded bars based on the startup-animation green family from `LaunchLoadingView`: `Color(red: 0.11, green: 0.73, blue: 0.33)` / `#1CBA54`, a deliberately brighter tallest bar `#35E879`, `#1CBA54` again, and `Color(red: 0.09, green: 0.66, blue: 0.29).opacity(0.75)` / `#17A84A` at `0.75` opacity.
- **Composition** — waveform groups fill more of the square than the original icon, with balanced outside margins and a lowered baseline. Keep the SVG square, unrounded, and opaque; iOS applies the final icon mask.

---

## Navigation Title Style

**Label: `NavTitle-Inline`**

All navigation titles use `.inline` display mode.

```swift
.navigationTitle("Page Title")
.navigationBarTitleDisplayMode(.inline)
```

---

## Navigation Chrome (NavRules)

> Full navigation structure and the three exit patterns → see `PAGES.md`.

**Label: `NavBack-Standard`** — every pushed page's only top-left control. The
icon-only button carries an explicit `.accessibilityLabel("Back")` so VoiceOver
announces it — a raw `Image` has no accessibility label of its own (a SwiftUI
`Label` would derive one, but this control uses `Image`). New pushed pages MUST copy
this labelled form:

```swift
ToolbarItem(placement: .topBarLeading) {
    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
        .accessibilityLabel("Back")
}
```

**Label: `SheetClose-Standard`** — every informational sheet's only close control, top-right (`SheetCloseButton` in `Views/RootView.swift`). Text `Cancel`/`Save` buttons are reserved for editing sheets that commit data.

**Label: `MiniPlayer-Bar`** — `MiniPlayerBar` (`Views/RootView.swift`), docked via `.miniPlayerBar()` on every pushed page. Artwork · episode title · remaining time · play/pause, with a purple progress hairline on top. Tapping it posts `.autohopReturnToPlayer` to pop to the Player. Hidden on Subscriptions while Reorder mode is active.

The Individual Subscription episodes page uses an empty nav title (the channel name is shown in `Header-SubscriptionPage` instead):

```swift
.navigationTitle("")
.navigationBarTitleDisplayMode(.inline)
```

---

## List Style

**Label: `List-Plain`**

Lists use `.plain` style with no separator lines introduced by the list itself. Visual separation comes from row backgrounds and card containers.

```swift
List { ... }
    .listStyle(.plain)
```

---

## Section Heading

**Label: `Section-Heading`**

Bold `title3` label placed above each card group. Used on all canonical pages.

```swift
Text("Section Title")
    .font(.title3.weight(.bold))
    .foregroundStyle(.primary)
```

With an optional trailing icon:

```swift
HStack(spacing: 6) {
    Text("Section Title")
        .font(.title3.weight(.bold))
        .foregroundStyle(.primary)
    Image(systemName: "arrow.up.arrow.down")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)
}
```

The Individual Subscription page uses a waveform icon:

```swift
HStack(spacing: 6) {
    Text("Episodes")
        .font(.title3.weight(.bold))
        .foregroundStyle(.primary)
    Image(systemName: "waveform")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)
}
```

---

## Section Card — List Container

**Label: `Section-CardList`**

A `List` wrapped in a rounded-rect card. Used on the Priority page and Individual Subscription page.

```swift
List { ... }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .padding(.horizontal, 20)
```

---

## Section Card — Row Group

**Label: `Section-CardRows`**

A `VStack(spacing: 0)` of rows inside a rounded-rect card. The card itself is the shared `Glass-Card` (`.glassCard(cornerRadius: 16)`) on the Downloads and Stats pages; rows are separated by a `Divider` tinted `white.opacity(0.08)`, indented past the artwork.

```swift
VStack(spacing: 0) {
    ForEach(items) { item in
        RowView(item)
        if item.id != items.last?.id {
            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.leading, 70)   // 14 padding + 44 artwork + 12 spacing
        }
    }
}
.glassCard(cornerRadius: 16)
```

---

## Glass Capsule Modifier

**Label: `Glass-Capsule`**

Shared `glassCapsule(highlighted:)` View extension in `Views/EpisodeBadges.swift`. Wraps any view in a glass `Capsule`. `highlighted: true` adds purple tint — used wherever the app uses a purple-accent pill surface.

- **iOS 26+ (neutral):** `.glassEffect(in: Capsule())`
- **iOS 26+ (highlighted):** `.glassEffect(.regular.tint(.purple), in: Capsule())`
- **iOS 17–25 (neutral):** `.background(Color.white.opacity(0.08), in: Capsule())`
- **iOS 17–25 (highlighted):** `purple.opacity(0.22)` background + `purple.opacity(0.35)` stroke

Usage:
- **Discover search shortcuts** — `.glassCapsule()` (neutral)
- **Discover category chips** — `.glassCapsule(highlighted: true)` (purple-tinted)
- **Discover hero rank badge** — `.glassCapsule(highlighted: true)` (purple-tinted)
- **Discover rail tile rank badge** — `.glassCapsule()` (neutral)
- **Subscriptions reorder toggle** — uses `.glassEffect(.regular.tint(.purple), in: Capsule())` directly (pre-dates this modifier)

---

## Individual Subscription Page — Channel Header

**Label: `Header-SubscriptionPage`**

The centred header shown at the top of every Individual Subscription episodes page, above the section heading and episode list card. All content is centre-aligned.

Structure (top to bottom):
1. **Artwork** — 120×120 pt, `cornerRadius 20`, subtle stroke overlay (`white.opacity(0.08), lineWidth: 0.5`)
2. **Channel title** — `.title3.weight(.bold)`, `.primary`, `multilineTextAlignment(.center)`
3. **Video + Explicit pills** — `HStack(spacing: 6)` of `VideoPillLarge` and/or `ExplicitPillLarge`, shown only when applicable. Placed **between the title and the description**. `VideoPillLarge` triggered by `sub.latestEpisode?.mediaKind == .video`; `ExplicitPillLarge` triggered by `sub.isExplicit == true` (channel-level RSS `<itunes:explicit>` tag).
4. **Channel description** — `.footnote`, `.secondary`, `lineLimit(2)`, `multilineTextAlignment(.center)`, HTML stripped via `stripHTML(_:)`. Hidden when empty.
5. **Author · Categories** — single `HStack`, `.caption`, `.secondary`, both text values **bold** (`.fontWeight(.bold)`). Categories are the comma-separated `sub.categories` array from the channel-level RSS `<itunes:category>` tags — replaces the old episode count.

Top padding reduced to `8 pt` (was `18 pt`) so the header sits closer to the navigation controls.

```swift
VStack(spacing: 12) {
    CachedArtworkImage(url: sub.artworkURL) { placeholderArtwork }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))

    VStack(spacing: 4) {
        Text(sub.title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)

        let showVideo = sub.latestEpisode?.mediaKind == .video
        let showExplicit = sub.isExplicit == true
        if showVideo || showExplicit {
            HStack(spacing: 6) {
                if showVideo   { VideoPillLarge() }
                if showExplicit { ExplicitPillLarge() }
            }
        }

        if let description = sub.description.map(stripHTML), !description.isEmpty {
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }

        HStack(spacing: 6) {
            if let author = sub.author {
                Text(author).fontWeight(.bold).lineLimit(1)
            }
            if sub.author != nil, !sub.categories.isEmpty { Text("·") }
            if !sub.categories.isEmpty {
                Text(sub.categories.joined(separator: ", ")).fontWeight(.bold).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
.frame(maxWidth: .infinity)
.padding(.horizontal, 20)
.padding(.top, 8)
```

---

## Individual Subscription Page — Episode Row

**Label: `ListRow-EpisodeRow`**

The episode row used in the Individual Subscription episodes list. Differs from `ListRow-Standard` (Queue) in that it shows episode-level artwork (falling back to channel artwork), includes an episode description preview, uses no queue position number, and shows a download progress bar when actively downloading.

Structure:
- **Artwork column** — 44×44 pt artwork (`cornerRadius 9`, `episode.artworkURL ?? sub.artworkURL`, falls back to `Artwork-Placeholder`). No badges below artwork.
- **Title** — plain `Text(episode.title)`, `.subheadline.weight(.semibold)`, `.primary`, `lineLimit(2)` — no inline pill.
- **Status/media indicators** — icon-only `VideoPillSmall` and/or `ExplicitPillSmall` float in the **top-right corner** of the row via `.overlay(alignment: .topTrailing)` on the outer `VStack`. They have no glass capsule; the separate episode-status pill remains in the metadata row.
- **Description preview** — `.caption`, `.secondary`, `lineLimit(3)`. HTML stripped via `stripHTML(_:)`. Hidden when empty.
- **Metadata row** — date · `•` · adaptive duration (`Text-MetadataAdaptive`) · `Spacer` · `EpisodeStatusPill`. `.caption`, `.tertiary`.
- **Download progress bar** (`ProgressBar-Download`) — shown below the HStack, indented 56 pt, only when `downloadState == .downloading`.

```swift
VStack(alignment: .leading, spacing: 0) {
    HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .center, spacing: 4) {
            CachedArtworkImage(url: episode.artworkURL ?? sub.artworkURL) { placeholderArtwork }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }

        VStack(alignment: .leading, spacing: 3) {
            Text(episode.title)   // plain text — no inline pill
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let desc = episode.description.map(stripHTML), !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 4) {
                if let date = episode.publishedAt { Text(formatPublishedDate(date)).lineLimit(1) }
                if let duration = episode.durationSeconds {
                    let elapsed = appState.effectivePlaybackTime(for: episode)
                    let remaining = elapsed > 0 ? max(0, duration - elapsed) : duration
                    Text("•")
                    Text(elapsed > 0 ? "\(formatDuration(remaining)) left remaining" : formatDuration(duration))
                        .monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 8)
                EpisodeStatusPill(kind: statusKind(for: episode))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    if episode.downloadState == .downloading,
       let progress = appState.downloadProgress[episode.id] {
        ProgressView(value: progress, total: 1.0)
            .tint(.purple)
            .animation(.linear(duration: 0.3), value: progress)
            .padding(.leading, 56)
            .padding(.top, 6)
    }
}
.padding(.vertical, 6)
.overlay(alignment: .topTrailing) {
    if episode.mediaKind == .video || episode.isExplicit == true {
        HStack(spacing: 3) {
            if episode.mediaKind == .video { VideoPillSmall() }
            if episode.isExplicit == true  { ExplicitPillSmall() }
        }
    }
}
```

Row background follows `ListRow-ActiveBackground` / `ListRow-IdleBackground`:

```swift
.listRowBackground(
    appState.currentPlayerEpisode?.id == episode.id
        ? Color.purple.opacity(0.08)
        : Color.white.opacity(0.08)
)
```

---

## Individual Subscription Page — Toolbar

**Label: `Toolbar-SubscriptionPage`**

| Side | Button |
|---|---|
| Leading | `Button-ReturnToPlayer` |
| Trailing 1st | Refresh Feed (`arrow.clockwise`) — shows `ProgressView` while running |
| Trailing 2nd | Settings (`gearshape`) — navigates to `SubscriptionSettingsView` |

```swift
.toolbar {
    ToolbarItem(placement: .topBarLeading) {
        ReturnToPlayerButton()
    }
    ToolbarItemGroup(placement: .topBarTrailing) {
        Button { /* refresh */ } label: {
            if isRefreshing { ProgressView() }
            else { Label("Refresh Feed", systemImage: "arrow.clockwise") }
        }
        .disabled(subscription == nil || isRefreshing)
    }
    ToolbarItem(placement: .primaryAction) {
        NavigationLink { SubscriptionSettingsView(subscriptionID: subscriptionID) } label: {
            Label("Show Settings", systemImage: "gearshape")
        }
        .disabled(subscription == nil)
    }
}
```

---

## List Row — Up Next Episode Row

**Label: `ListRow-Standard`**

The standard episode row used in Up Next. Five horizontal zones left to right:

1. **Position indicator** — 20 pt fixed width: Up Next number or `PositionIndicator-Playing`
2. **Artwork** — 44×44 pt, `cornerRadius 9`
3. **Text stack** — leading-aligned, expands: podcast title (caption/secondary) · episode title (subheadline.bold/primary) · metadata row
4. **Spacer**
5. **Trailing metadata** — icon-only Video/Explicit indicators (when applicable) + pin badge (if pinned) + duration. These are separately arranged in the stack, so media indicators never overlay the pin.

**Expanded state:** tapping the episode title toggles `expandedEpisodeID`, unclamping the title and revealing the full plain-text description (indented to the artwork edge, `lineLimit 15`). A **small purple circular glass gear** (`gearshape`, the `refreshButton` treatment — 30×30, `glassEffect(in: Circle())` with a `.ultraThinMaterial` fallback, `.accessibilityLabel("Podcast settings")`) sits at the **bottom-right** of the expanded area; tapping it opens that podcast's `SubscriptionSettingsView` by dismissing the Up Next sheet and presenting Settings in its place ("replace Up Next", coordinated in `PlayerView` via the sheet's `onDismiss`).

```swift
HStack(spacing: 12) {
    // 1. Position indicator
    if isCurrent {
        Image(systemName: "play.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.purple)
            .frame(width: 20)
    } else {
        Text("\(index + 1)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 20, alignment: .center)
    }

    // 2. Artwork
    CachedArtworkImage(url: artworkURL) { placeholderArtwork }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))

    // 3. Text stack
    VStack(alignment: .leading, spacing: 2) {
        Text(podcastTitle).font(.caption).foregroundStyle(.secondary)
        Text(episodeTitle).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
        HStack(spacing: 4) {
            Text(date)
            if let remaining { Text("•"); Text(remaining) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    Spacer()

    // 5. Trailing metadata
    VStack(alignment: .trailing, spacing: 4) {
        if isPinnedNext || isPinnedLast {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isPinnedNext ? Color.blue : Color.orange)
        }
        Text(duration).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}
.contentShape(Rectangle())
```

---

## Top Episodes Page — Feature Card & Compact Row

**Labels: `Card-TopEpisodeFeature`, `ListRow-TopEpisode`** (`Views/TopEpisodesView.swift`)

The Top Episodes page (child of Discover, reached via the "See All" button on the Top Episodes hero) is an editorial Top-50 list. A **feature card every 7th rank** (1, 8, 15, 22, 29, 36, 43 — `(rank - 1) % 7 == 0`) breaks up a list of **compact rows**, on a black page in a `LazyVStack` (18 pt spacing, 20 pt horizontal page insets). **`Views/TopPodcastsView.swift` (the "Top Podcasts" page) reuses this exact layout and styling** — same `Card-TopEpisodeFeature` / `ListRow-TopEpisode` structure — but for chart *shows*: each entry shows the podcast's artwork, title, author (artist), and category (genreName) in place of the episode's title/show/relative-time, and is reached via the "See All" on the first "Top Podcasts" hero.

**Feature card (`Card-TopEpisodeFeature`)** — mirrors the Discover episode-hero card, sized as a static full-width tile:
- 232 pt tall, `cornerRadius 22`, `white.opacity(0.08)` hairline stroke
- Purple→black diagonal gradient background (`Color(red:0.20,green:0.08,blue:0.42).opacity(0.95)` → `black.opacity(0.85)`)
- Oversized ghosted rank numeral (220 pt, `white.opacity(0.07)`) pinned top-trailing, `allowsHitTesting(false)`
- Bottom-aligned `HStack`: **140 pt artwork** (`cornerRadius 18`) + a `VStack` of `#rank` capsule · title (`title3.bold`, 2 lines) · show (`subheadline`, secondary) · relative publish time (`caption`, tertiary)
- Extra separation: 24 pt top padding (4 pt for rank 1) + 14 pt bottom, so heroes stand apart from the rows
- Resolving tap shows `resolvingOverlay`; `.disabled` while any episode resolves

**Compact row (`ListRow-TopEpisode`)** — `HStack(spacing: 14)`, 8 pt vertical padding:
- Rank numeral — 28 pt fixed width, `system(16, .bold, .rounded)`, secondary
- **84 pt artwork** (`cornerRadius 13`), `ArtworkPlaceholder` fallback
- `VStack`: episode title (`subheadline.semibold`, 2 lines) · show (`caption`, secondary) · relative publish time (`caption2`, tertiary)

Both use the relative time label (`relativeReleasedLabel`, "4 hours ago"). Tapping resolves the parent podcast's feed and pushes `PodcastDetailView` (same routing rule as Discover — active sub → episodes, else preview).

---

## List Row — Priority Page Subscription Row

**Label: `ListRow-SubscriptionRow`**

The row layout used on the Priority page. Differs from `ListRow-Standard` in three ways: (1) the podcast name is the **primary** title, (2) the secondary line is the show's **channel-level description** (2-line clamp, HTML-stripped) — NOT the latest episode title, (3) there is no trailing metadata stack — the status pill sits inline in the metadata row at the bottom. Title/description match PodcastDetailView's episode-row styling (subheadline-semibold / caption-secondary). Metadata line is `Updated: <relative age>` (mins/hours → "Yesterday" → "2…6 days ago" → exact date; no episode length).

The left column has the artwork only. Icon-only `VideoPillSmall` and `ExplicitPillSmall` float in the top-right corner via `.overlay(alignment: .topTrailing)` on the outer row `VStack`. `rankPill` sits in a separate bottom band row below the top HStack. Episode title is plain text (no inline pill).

```swift
HStack(alignment: .top, spacing: 12) {
    // Left column: artwork only — no badges below
    VStack(alignment: .center, spacing: 4) {
        CachedArtworkImage(url: sub.artworkURL) { placeholderArtwork }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // Text stack
    VStack(alignment: .leading, spacing: 3) {
        // Subscription title is PRIMARY
        Text(sub.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

        // Secondary line: the show's CHANNEL description (2-line clamp),
        // HTML-stripped — not the latest episode title
        Text(stripHTML(sub.description))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

        // Metadata row: "Updated: <relative age>" · Spacer · status pill
        // (no episode length)
        HStack(spacing: 4) {
            Text("Updated: \(relativePublishedLabel(date))")
            Spacer(minLength: 8)
            EpisodeStatusPill(kind: statusKind)   // or Button("Download")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)

        // Download progress bar (only when actively downloading)
        if isDownloading {
            ProgressView(value: progress, total: 1.0)
                .tint(.purple)
                .animation(.linear(duration: 0.3), value: progress)
                .padding(.top, 3)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
.padding(.vertical, 6)
.overlay(alignment: .topTrailing) {
    if episode.mediaKind == .video || episode.isExplicit == true {
        HStack(spacing: 3) {
            if episode.mediaKind == .video { VideoPillSmall() }
            if episode.isExplicit == true  { ExplicitPillSmall() }
        }
    }
}
```

---

## List Row Background — Active State

**Label: `ListRow-ActiveBackground`**

The row for the currently playing episode gets a faint purple tint. Applied via `.listRowBackground`.

```swift
.listRowBackground(isPlaying ? Color.purple.opacity(0.08) : Color.white.opacity(0.08))
```

> Note: on the Priority page (card list) and Individual Subscription page (card list), idle rows use `Color.white.opacity(0.08)` — not `.clear` — because the card background is already black. On the Queue (plain list against black), idle rows use `.clear`.

---

## List Row Background — Idle State

**Label: `ListRow-IdleBackground`**

| Page | Idle background |
|---|---|
| Queue (plain list on black) | `Color.clear` |
| Priority (card list) | `Color.white.opacity(0.08)` |
| Individual Subscription (card list) | `Color.white.opacity(0.08)` |
| Downloads (card group) | Inherited from card container |

---

## Position Indicator — Playing State

**Label: `PositionIndicator-Playing`**

When a row is the currently playing episode, the position number is replaced by a small purple `play.fill` icon.

```swift
if isCurrent {
    Image(systemName: "play.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.purple)
        .frame(width: 20)
} else {
    Text("\(index + 1)")
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 20, alignment: .center)
}
```

---

## Artwork Placeholder

**Label: `Artwork-Placeholder`**

When no artwork URL is available, show a purple-to-black diagonal gradient with a waveform icon.

```swift
ZStack {
    LinearGradient(
        colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    Image(systemName: "waveform")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white.opacity(0.65))
}
```

For video episode placeholders, use `"play.rectangle.fill"` in place of `"waveform"`.
The `Header-SubscriptionPage` placeholder uses a larger icon size (`size: 36`).

---

## Episode Status Pill

**Label: `EpisodeStatusPill`**

A colour-coded capsule pill shown on the Priority page, Individual Subscription page, and any other page listing episodes. Communicates episode state at a glance. Eight states, each a unique colour. White foreground on all.

> **Shared component.** `EpisodeStatusKind` and `EpisodeStatusPill` live once in `Views/EpisodeBadges.swift` (alongside the Video/Explicit badges). Each page keeps its own `statusKind(for:)` resolver but renders the shared pill — do not re-declare these per file.

| State | Label | Colour | Trigger |
|---|---|---|---|
| `unplayed` | Unplayed | Gray | Unplayed, no saved position, episode is **not** downloaded |
| `queued` | Queued | Teal | Unplayed, no saved position, episode **is** downloaded (`downloadState == .downloaded`) |
| `partiallyPlayed` | Paused | Yellow | `playedState == .playing` but NOT the current player episode; OR `playedState == .unplayed` with saved position > 0 |
| `nowPlaying` | Playing | Green | `playedState == .playing` AND `currentPlayerEpisode?.id == episode.id` |
| `played` | Played | Blue | `playedState == .played` |
| `archived` | Archived | Purple | `playedState == .archived` |
| `inactive` | Inactive | Orange | `subscription.excludeFromAutoFeedRefresh == true` (Priority page only) |
| `skipped` | Skipped | Muted gray | `downloadState == .notDownloaded` and the subscription's active `DownloadFilterSettings` currently exclude the episode |

Priority order for the pill decision (check top to bottom):
1. `excludeFromAutoFeedRefresh` → **Inactive** (Priority page only)
2. `playedState == .archived` → **Archived**
3. `playedState == .played` → **Played**
4. saved playback position / active player state → **Paused** or **Playing**
5. active Download Filters exclude a not-downloaded episode → **Skipped**
6. `statusKind(for: episode)` → **Unplayed** or **Queued**

**Glass pill pattern (applies to all pills):**
- **iOS 26+:** colour-tinted liquid glass — a semi-transparent colour layer underneath `.glassEffect(in: Capsule())` lets the tint show through the frosted material
- **iOS 17–25 fallback:** solid `color.opacity(0.82)` capsule, unchanged

```swift
// Views/EpisodeBadges.swift — shared, not per-page.
enum EpisodeStatusKind {
    case unplayed, queued, partiallyPlayed, nowPlaying, played, archived, inactive, skipped

    var label: String {
        switch self {
        case .unplayed:        return "Unplayed"
        case .queued:          return "Queued"
        case .partiallyPlayed: return "Paused"
        case .nowPlaying:      return "Playing"
        case .played:          return "Played"
        case .archived:        return "Archived"
        case .inactive:        return "Inactive"
        case .skipped:         return "Skipped"
        }
    }

    var color: Color {
        switch self {
        case .unplayed:        return Color.gray
        case .queued:          return Color.teal
        case .partiallyPlayed: return Color.yellow
        case .nowPlaying:      return Color.green
        case .played:          return Color.blue
        case .archived:        return Color.purple
        case .inactive:        return Color.orange
        case .skipped:         return Color(white: 0.42)
        }
    }
}

struct EpisodeStatusPill: View {
    let kind: EpisodeStatusKind

    var body: some View {
        let label = Text(kind.label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .background(kind.color.opacity(0.45), in: Capsule())
                .glassEffect(in: Capsule())
        } else {
            label
                .background(kind.color.opacity(0.82), in: Capsule())
        }
    }
}
```

`statusKind` resolution logic (same on both Priority and Subscription pages):

```swift
private func statusKind(for episode: Episode) -> EpisodeStatusKind {
    switch episode.playedState {
    case .playing:
        return appState.currentPlayerEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
    case .played:   return .played
    case .archived: return .archived
    case .unplayed:
        let position = appState.effectivePlaybackTime(for: episode)
        if position > 0 { return .partiallyPlayed }
        return episode.downloadState == .downloaded ? .queued : .unplayed
    }
}
```

---

## Rank Pill

**Label: `Badge-RankPill`**

The priority rank number is displayed as a liquid glass capsule pill **centred below the artwork column** on the Priority page, rendered in the bottom band beneath the artwork row. The icon-only `Badge-VideoPillSmall` / `Badge-ExplicitPillSmall` remain in the row's top-trailing overlay; they do not share the rank pill's glass treatment.

- **iOS 26+:** native `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background

```swift
@ViewBuilder
private func rankPill(_ rank: Int) -> some View {
    let label = Text("\(rank)")
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)

    if #available(iOS 26, *) {
        label.glassEffect(in: Capsule())
    } else {
        label.background(.ultraThinMaterial, in: Capsule())
    }
}

// Priority page — artwork column (top) + badge VStack + rank pill in bottom band:
VStack(alignment: .center, spacing: 4) {
    CachedArtworkImage(url: sub.artworkURL) { placeholderArtwork }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))

    VStack(spacing: 3) {
        if episode.mediaKind == .video { VideoPillSmall() }
        if episode.isExplicit == true  { ExplicitPillLarge() }
    }
    .frame(minWidth: 44)
}

// Rank pill sits in the bottom band row below the artwork VStack:
rankPill(sub.priorityRank)
    .frame(minWidth: 44, alignment: .center)
```

---

## Video Badge (Small)

**Label: `Badge-VideoPillSmall`**

The small variant of the video indicator. It is the existing `tv.fill` icon alone,
with no glass, material, background, capsule, or decorative padding. Most episode
lists place it in the **top-right corner** via an overlay; Up Next places it in
the trailing metadata stack so it cannot collide with `Badge-Pin`.

- **Icon:** `tv.fill`, `.caption.bold()`, white foreground
- **Surface:** none; minimum icon layout frame is 14×14 pt
- **Placement:** normally `.overlay(alignment: .topTrailing)` in an `HStack`
  alongside `ExplicitPillSmall`; Up Next uses its trailing metadata `VStack`.

```swift
.overlay(alignment: .topTrailing) {
    if episode.mediaKind == .video || episode.isExplicit == true {
        HStack(spacing: 3) {
            if episode.mediaKind == .video { VideoPillSmall() }
            if episode.isExplicit == true  { ExplicitPillSmall() }
        }
    }
}
```

Pages covered (list rows): Priority (PodcastsView), Queue (QueueSheetView), Individual Subscription (SubscriptionSettingsView), Downloads (both active and archived rows), Player Up Next row.

---

## Video Badge Large

**Label: `Badge-VideoPillLarge`**

The large variant of the video indicator. A "Video" text pill used in **detail page headers** when `episode.mediaKind == .video` (or `sub.latestEpisode?.mediaKind == .video` for channel headers). Placed in an `HStack(spacing: 6)` below the title alongside `ExplicitPillLarge`.

- **iOS 26+:** `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background
- **Text:** `"Video"`, `.caption.bold()`, white foreground
- **Padding:** `.horizontal: 8, .vertical: 5`

```swift
// Detail header — below title:
HStack(spacing: 6) {
    if showVideo   { VideoPillLarge() }
    if showExplicit { ExplicitPillLarge() }
}
```

Pages covered (detail headers): Individual Subscription channel header, Individual Episode detail header.

---

## Explicit Pill (Large)

**Label: `Badge-ExplicitPillLarge`**

The large variant of the explicit indicator. An "Explicit" text pill used in **detail page headers** when `episode.isExplicit == true`. Placed in an `HStack(spacing: 6)` below the title alongside `VideoPillLarge`.

- **iOS 26+:** `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background
- **Text:** `"Explicit"`, `.caption.bold()`, white foreground
- **Padding:** `.horizontal: 8, .vertical: 5`

Pages covered (detail headers): Individual Subscription channel header, Individual Episode detail header.

---

## Explicit Pill Small

**Label: `Badge-ExplicitPillSmall`**

The small variant of the explicit indicator. It is the existing iTunes-style
"E in a square" icon alone, with no surrounding glass/material capsule or
decorative padding.

- **Icon:** 11×11 pt white `RoundedRectangle(cornerRadius: 2)` with a black bold "E" (`size: 8, weight: .bold`) overlaid
- **Surface:** none; minimum icon layout frame is 14×14 pt
- **Placement:** follows `Badge-VideoPillSmall`; in Up Next both icons occupy the
  trailing metadata stack above the separately arranged pin and duration.

Pages covered (list rows): Priority (PodcastsView), Queue (QueueSheetView), Individual Subscription (SubscriptionSettingsView), Downloads (both active and archived rows), Player Up Next row.

---

## Inline Download Button

**Label: `Button-DownloadInline`**

When an episode has never been downloaded (and is not archived/played/skipped by Download Filters), show a bordered "Download" button inline in the metadata row — in the same trailing position as `EpisodeStatusPill`.

```swift
Button("Download") {
    Task { await appState.downloadLatestEpisode(for: sub) }
}
.font(.caption.bold())
.buttonStyle(.bordered)
.controlSize(.small)
```

---

## Adaptive Duration / Remaining Time

**Label: `Text-MetadataAdaptive`**

In the metadata row, the time display adapts based on whether the user has started the episode:
- **Partially played:** shows `"Xm left remaining"` (time left, not total)
- **Unplayed:** shows full duration `"Xh Ym"` or `"Xm"`

```swift
let elapsed = appState.effectivePlaybackTime(for: episode)
let remaining = elapsed > 0 ? max(0, duration - elapsed) : duration
let isPartial = elapsed > 0
Text(isPartial ? "\(formatDuration(remaining)) left remaining" : formatDuration(duration))
    .monospacedDigit()
```

Duration format: `"Xh Ym"` when ≥ 1 hour, otherwise `"Ym"`. No seconds.

---

## Podcast Title Style

**Label: `Text-PodcastTitle`**

The podcast (show) title above the episode title in Queue rows — small, grey, not bold.

```swift
Text(podcastTitle)
    .font(.caption)
    .foregroundStyle(.secondary)
```

---

## Subscription Title Style (Priority Page)

**Label: `Text-SubscriptionTitle`**

On the Priority page, the subscription (show) name is the **primary** bold title — larger and more prominent than the episode title below it.

```swift
Text(sub.title)
    .font(.headline.weight(.bold))
    .foregroundStyle(.primary)
    .lineLimit(1)
```

---

## Episode Title Style

**Label: `Text-EpisodeTitle`**

Standard episode title style used in the Queue and Individual Subscription page — bold, primary, up to 2 lines.

```swift
// Queue
Text(episodeTitle)
    .font(.subheadline.bold())
    .foregroundStyle(.primary)
    .lineLimit(2)

// Individual Subscription (slightly lighter weight)
Text(episode.title)
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(.primary)
    .lineLimit(2)
```

---

## Episode Title Style — Secondary

**Label: `Text-EpisodeTitleSecondary`**

Used on the Priority page where the subscription name is already the primary title. The episode title is de-emphasised — not bold, secondary colour.

```swift
Text(episode.title)
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .lineLimit(2)
```

---

## Metadata Row

**Label: `Text-MetadataRow`**

Date and time information on the same line, separated by `•`, in caption/secondary (or tertiary on Priority and Subscription pages).

```swift
HStack(spacing: 4) {
    Text(formattedDate).lineLimit(1)
    if let remaining {
        Text("•")
        Text(remaining).lineLimit(1)
    }
}
.font(.caption)
.foregroundStyle(.secondary)   // .tertiary on Priority and Subscription pages
```

---

## Duration Display

**Label: `Text-Duration`**

Total episode duration in the trailing metadata stack.

```swift
Text(formatDuration(seconds))   // "1h 4m" or "58m"
    .font(.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
```

---

## Pin Badge

**Label: `Badge-Pin`**

Appears in the trailing stack of a Queue row when the episode has been manually positioned. Sits above the duration. Blue = Play Next, Orange = Play Last.

```swift
VStack(alignment: .trailing, spacing: 4) {
    if isPinnedNext || isPinnedLast {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isPinnedNext ? Color.blue : Color.orange)
    }
    Text(formatDuration(duration))
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
}
```

---

## Download Progress Bar

**Label: `ProgressBar-Download`**

Purple, animated progress bar shown whenever an episode is actively downloading. Used in three places:

| Page | Position |
|---|---|
| Subscriptions | Below the metadata row, indented 56 pt (past artwork) |
| Individual Subscription | Below the episode row HStack, indented 56 pt (past artwork) |
| Listening History | Below the history row HStack, indented 56 pt (matching canonical 44 pt artwork + 12 pt gap) |
| Downloads page | Inside the activity row, below the text stack |

Progress values publish in ≥1% steps (coalesced by AppState's download callback
into the narrow `Downloads/DownloadProgressModel`) so several concurrent
downloads don't re-invalidate whole pages every second — don't expect sub-1% bar
movement.

```swift
ProgressView(value: progress, total: 1.0)
    .tint(.purple)
    .animation(.linear(duration: 0.3), value: progress)
    .padding(.leading, 56)   // aligns with text stack (14 padding + 44 artwork + 12 gap − 14 row inset)
    .padding(.top, 6)        // breathing room below metadata row
```

Only shown when `episode.downloadState == .downloading && appState.downloadProgress[episode.id] != nil`.

---

## Swipe Actions — Episode Rows

**Label: `SwipeActions-EpisodeRow`**

Four swipe actions used on episode rows. Full-swipe is disabled on both edges. Applied on the **Up Next** sheet, **Podcast Detail** page, and **Listening History** page (the History rows resolve each entry to its `Episode` first and skip the actions when it can't be resolved).

Listening History deliberately mirrors Podcast Detail's action implementation:
Play and Play Next lead; the same state-driven Download/Archive/Unarchive primary
action and Play Last trail. Play/Play Next/Play Last await a required manual
download first, manual downloads bypass feed filters, the current episode has no
swipes, and unresolved retained history records remain read-only.

### Leading (swipe right) — both pages
| Action | Icon | Colour | Behaviour |
|---|---|---|---|
| **Play** | `play.fill` | `.green` | Starts playback immediately. On Subscription page: downloads first if not on device. Up Next also dismisses the sheet. |
| **Download** | `arrow.down.circle` | `.teal` | **Subscription page only**, and only when the episode is `.notDownloaded`/`.failed` (hidden while downloading or once downloaded). Downloads the episode — which places it in the Up Next queue at its priority-sorted position (`downloadedQueue` = QueueService priority order over downloaded episodes). Does not start playback. Sits between Play and Play Next. |
| **Play Next** | `text.line.first.and.arrowtriangle.forward` | `.blue` | Pins to top of queue. On Subscription page: downloads first if not on device. |

### Trailing (swipe left) — both pages
| Action | Icon | Colour | Behaviour |
|---|---|---|---|
| **Archive** | `archivebox` | `.purple` | Archives the episode. Up Next: also advances to next episode (`archiveEpisodeAndPlayNext`). Subscription: archives only, no queue advance. |
| **Unarchive** | `arrow.uturn.backward.circle` | `.purple` | Replaces Archive on Subscription page when `playedState == .archived` or `.played`. Resets to unplayed. Not shown in Up Next. |
| **Play Last** | `text.line.last.and.arrowtriangle.forward` | `.orange` | Pins to bottom of queue. On Subscription page: downloads first if not on device. |

### Conditional visibility — Subscription page only
- The currently playing episode shows **no swipe actions** on either edge.
- Archive is replaced by Unarchive when the episode is already `.archived` or `.played`.

**Up Next action animations (`QueueAction-Animation`, Up Next only).** The Up Next list carries `.animation(value: downloadedQueue.map(\.id))` so order/membership changes glide rows to their new slots. On top of that, each action adds a cue + a matched haptic (`.sensoryFeedback`):
- **Play Next / Play Last** — light impact haptic; the row pops (scale 1.05) and flashes a directional badge at the leading edge (`arrow.up.to.line` blue for top / `arrow.down.to.line` orange for bottom), then commits the reorder so the row visibly travels to the top/bottom.
- **Archive** — success haptic; the row slides toward the trailing edge while shrinking + fading as an `archivebox.fill` badge (purple circle) fades in at the trailing edge, then the archive commits and the gap closes behind it.
- **Unpin** — light impact haptic; the row glides back to its natural priority slot.

```swift
// Up Next sheet pattern
.swipeActions(edge: .leading, allowsFullSwipe: false) {
    Button { dismiss(); Task { await appState.playEpisode(episode) } }
        label: { Label("Play", systemImage: "play.fill") }.tint(.green)
    Button { appState.playEpisodeNext(episode) }
        label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }.tint(.blue)
}
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    Button { Task { await appState.archiveEpisodeAndPlayNext(episode) } }
        label: { Label("Archive", systemImage: "archivebox") }.tint(.purple)
    Button { appState.playEpisodeLast(episode) }
        label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }.tint(.orange)
}

// Subscription page — additional download-if-needed logic and Unarchive
.swipeActions(edge: .leading, allowsFullSwipe: false) {
    let isCurrentlyPlaying = appState.currentPlayerEpisode?.id == episode.id
    if !isCurrentlyPlaying {
        Button {
            Task {
                if episode.downloadState != .downloaded { await appState.downloadEpisodeForQueue(episode) }
                if let updated = appState.subscriptionStore.episode(subscriptionID: sub.id, episodeID: episode.id) {
                    await appState.playEpisode(updated)
                }
            }
        } label: { Label("Play", systemImage: "play.fill") }.tint(.green)

        Button {
            Task {
                if episode.downloadState != .downloaded { await appState.downloadEpisodeForQueue(episode) }
                appState.playEpisodeNext(episode)
            }
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }.tint(.blue)
    }
}
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    let isCurrentlyPlaying = appState.currentPlayerEpisode?.id == episode.id
    if !isCurrentlyPlaying {
        if episode.playedState == .archived || episode.playedState == .played {
            Button { appState.unarchiveEpisode(episode) }
                label: { Label("Unarchive", systemImage: "arrow.uturn.backward.circle") }.tint(.purple)
        } else {
            Button { Task { await appState.archiveEpisode(episode) } }
                label: { Label("Archive", systemImage: "archivebox") }.tint(.purple)
        }
        Button {
            Task {
                if episode.downloadState != .downloaded { await appState.downloadEpisodeForQueue(episode) }
                appState.playEpisodeLast(episode)
            }
        } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }.tint(.orange)
    }
}
```

---

## Swipe Action Color Semantics

**Label: `SwipeColor-Semantics`**

| Colour | Meaning |
|---|---|
| `.green` | Play immediately |
| `.blue` | Promote / move to top |
| `.purple` | Primary app action (archive, unarchive, download) |
| `.orange` | Demote / move to bottom |
| `.red` | Destructive delete (reserved) |

---

## Downloads Page — Activity Row

**Label: `Row-DownloadActivity`**

The row used in the "Downloading" and "Downloaded on Device" card sections. Adapts to show progress controls, error state, or an archive button depending on status.

Structure:
- **Artwork** — 44×44, cornerRadius 9 (`Artwork-Placeholder`)
- **Text stack** — podcast title (caption/secondary) with optional media kind pill inline · episode title (subheadline.bold/primary) · metadata line (size + date, caption/secondary)
- **Spacer**
- **Trailing:** archive button (when completed) OR status pill (when in-progress)
- **Progress / error row** (when downloading/paused/failed) — indented 56 pt (past artwork)

Layout rules (2026-07-02):
- The pause/resume/archive `controls` HStack is `.fixedSize()` — it shares a row with
  the progress/error text, and without it a long "NN% • X MB of Y GB" compresses the
  buttons ("Re-sume" wraps mid-word). Buttons keep intrinsic size; text truncates
  (`lineLimit(1)`).
- Media + explicit pills are INLINE in the podcast-title row on ALL statuses — never a
  top-trailing overlay (the overlay version floated over the Downloading/Paused status
  pill and clipped at the card edge).

Media kind pill (Video / Audio) — inline in the podcast title row (all statuses), with `ExplicitPillSmall` after it when the episode is explicit:
```swift
Text(mediaKind == .video ? "Video" : "Audio")
    .font(.caption2.weight(.bold))
    .foregroundStyle(.purple)
    .padding(.horizontal, 7).padding(.vertical, 3)
    .background(Color.purple.opacity(0.18), in: Capsule())
```

Download status pill colours:
| Status | Colour |
|---|---|
| Downloading | Purple |
| Paused | Orange |
| Failed | Red |
| Completed | Green |

---

## Downloads Page — Archived Episode Row

**Label: `Row-ArchivedEpisode`**

Used in the "Recently Archived" card section. Simpler than the activity row — no controls except a re-download button.

```swift
HStack(alignment: .top, spacing: 12) {
    // Artwork — 44×44, cornerRadius 9
    CachedArtworkImage(url: entry.artworkURL) { placeholderArtwork }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))

    VStack(alignment: .leading, spacing: 2) {
        Text(entry.podcastTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Text(entry.episodeTitle).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
        // Metadata: "Archived Jun 6, 2026 · Listened 73%" (completionPercent when available)
        Text(metadataText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    Spacer(minLength: 8)

    // Re-download button — bordered small, purple tint
    Button { redownload() } label: {
        Label("Re-download", systemImage: "arrow.down.circle").labelStyle(.iconOnly)
    }
    .buttonStyle(.bordered).controlSize(.small).tint(.purple)
}
.padding(14)
```

Metadata format: `"Archived [date] · Listened [pct]%"` when completion data is available; `"Archived [date]"` for older entries without completion data.

---

## Toolbar Layout — Navigation Page

**Label: `Toolbar-NavigationPage`**

Used on full navigation stack pages (Priority page). No "Done" dismiss button — the system back button handles navigation.

| Side | Position | Button |
|---|---|---|
| Leading | 1st | `Button-ReturnToPlayer` |
| Leading | 2nd | `Button-MenuHamburger` |
| Leading | 3rd | `Button-ReorderToggle` |
| Trailing | 1st | `Button-RefreshAll` |
| Trailing | 2nd | `Button-AddFeed` |

```swift
.toolbar {
    ToolbarItem(placement: .navigationBarLeading) {
        HStack(spacing: 8) {
            ReturnToPlayerButton()
            Button { showMenu = true } label: { Image(systemName: "line.3.horizontal") }
            Button(editMode == .active ? "Done" : "Reorder") {
                withAnimation { editMode = editMode == .active ? .inactive : .active }
            }
        }
    }
    ToolbarItem(placement: .primaryAction) {
        HStack {
            Button { refreshAll() } label: {
                if isRefreshingAll { ProgressView() }
                else { Label("Refresh All", systemImage: "arrow.clockwise") }
            }
            .disabled(isRefreshingAll)
            Button { showSearch = true } label: { Label("Add Podcast", systemImage: "plus") }
        }
    }
}
```

---

## Toolbar Layout — Sheet

**Label: `Toolbar-SheetStandard`**

Used on sheet-presented pages (Queue). Three positions:

| Placement | Content |
|---|---|
| `.topBarLeading` | Contextual shortcut (`Button-ContextualShortcut`) |
| `.principal` | Primary page action, `.bordered` style (`Button-ToolbarAction`) |
| `.confirmationAction` | Plain "Done" to dismiss |

```swift
.toolbar {
    ToolbarItem(placement: .topBarLeading) { /* shortcut */ }
    ToolbarItem(placement: .principal) {
        Button { action() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
            .buttonStyle(.bordered).controlSize(.regular).disabled(isLoading)
    }
    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
}
```

---

## Toolbar Action Button Style

**Label: `Button-ToolbarAction`**

Bordered, regular size, icon-only. Shows `ProgressView` while async work runs.

```swift
Button { action() } label: {
    if isLoading { ProgressView().controlSize(.small) }
    else { Label("Label", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
}
.buttonStyle(.bordered)
.controlSize(.regular)
.disabled(isLoading)
```

---

## Contextual Shortcut Button

**Label: `Button-ContextualShortcut`**

Downloads shortcut in the Queue toolbar. Navigates to Downloads and visually signals active download state.

- **Icon:** `arrow.down.circle.fill` (active) / `arrow.down.circle` (idle)
- **Color:** `Color.purple` (active) / `Color.primary` (idle)
- **Size:** `.title3.weight(.semibold)`
- **Animation:** pulsing scale when active (`Indicator-PulsingIcon`)
- **Accessibility:** explicit `.accessibilityLabel`

```swift
ToolbarItem(placement: .topBarLeading) {
    NavigationLink { DownloadsView() } label: {
        DownloadShortcutButton(isActive: hasActiveDownloads)
    }
    .accessibilityLabel("Downloads")
}
```

---

## Pulsing Icon Animation

**Label: `Indicator-PulsingIcon`**

Used on any icon that represents an active background process. Scale animates between `0.85` and `1.0` using `easeInOut(duration: 0.6).repeatForever(autoreverses: true)`. Always starts from a known `false` state to prevent animation glitches.

```swift
@State private var pulsing = false

Image(systemName: isActive ? "icon.fill" : "icon")
    .foregroundStyle(isActive ? Color.purple : Color.primary)
    .scaleEffect(pulsing ? 1.0 : 0.85)
    .onAppear { if isActive { startPulse() } }
    .onChange(of: isActive) { _, active in
        if active { startPulse() }
        else { withAnimation(.default) { pulsing = false } }
    }

private func startPulse() {
    pulsing = false
    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
        pulsing = true
    }
}
```

---

## Empty State

**Label: `EmptyState-ContentUnavailable`**

Empty lists use `ContentUnavailableView` with a system image, title, and description.

```swift
ContentUnavailableView(
    "Your queue builds itself",
    systemImage: "square.stack",
    description: Text("As you subscribe and episodes download, they line up here in priority order — newest first, ready to play.")
)
```

The primary new-user funnel screens (Player, Subscriptions) use a richer **custom**
empty state instead of `ContentUnavailableView`: a 104 pt purple-tint circle holding a
glyph (or a `ProgressView` while a first episode downloads), a `.rounded`-bold title, a
`Color(white: 0.62)` body, and one or more capsule CTAs (`EmptyState-CTAButton`).

---

## Onboarding — First-Run Components

The first-run experience (ONBOARDING_PLAN.md; FEATURES.md §18) introduces a small family
of purple-accented dark-card components. They all sit on the standard black page / sheet
background and reuse the app's purple accent.

**Label: `EmptyState-CTAButton`** — capsule action used in the Player / Subscriptions
empty states and Welcome. Filled = `Color.purple` fill, white 16 pt semibold text,
~28×13 pt padding; outline = `Color.purple.opacity(0.14)` fill with purple text.

**Label: `Onboarding-Welcome`** (`WelcomeView`) — full-screen cover on the launch
splash's purple background (`Color(red: 0.176, green: 0.149, blue: 0.502)`). A paged
`TabView` (`.page(indexDisplayMode: .always)`) of 3 panels (waveform/glyph hero,
30 pt `.rounded` bold title, translucent-white body) over three stacked CTAs:
white-filled primary, `white.opacity(0.16)` secondary, plain-text tertiary.

**Label: `Onboarding-FirstSubscribeCard`** (`FirstSubscribeCard`) — bottom sheet
(`.height(470/540)`), 96 pt artwork, "You're all set 🎧" title, body, a
`white.opacity(0.06)` rounded **download-status row** (spinner + "Downloading… N%" or a
green check + "Ready to play"), and a purple-capsule **Play latest** primary.

**Label: `Onboarding-CoachMark`** (`CoachMarkOverlay`) — a dismissible bottom card
(`Color(red:0.12,0.12,0.15)` fill, `purple.opacity(0.35)` 1 pt stroke, soft shadow): a
34 pt purple-circle glyph, bold 15 pt title, 13 pt grey body, and a purple "Got it"
button. One visible at a time; floats above pages, below sheets.

**Label: `Onboarding-Checklist`** (`GettingStartedChecklist`) — top-of-Priority-Stack
card (`white.opacity(0.06)` fill, `purple.opacity(0.25)` stroke) with a title + dismiss
`xmark`, three check rows (`checkmark.circle.fill` green / `circle` grey, strikethrough
when done), and a small grey footer note.

**Label: `Onboarding-StarterPackCard`** (`StarterPacksView`) — `white.opacity(0.06)`
rounded card per genre: genre title, a row of six 48 pt artwork thumbnails, and a full-width
capsule "Add these shows" (purple → `green.opacity(0.4)` + check once added).

**Label: `Onboarding-Banner`** — the Discover first-run starter-packs banner and the
import toast share the rounded `purple.opacity(0.12)` fill + `purple.opacity(0.3)` stroke
treatment; the toast is a centred capsule pinned above the mini-player, auto-dismissed.

---

## Podcast Search Sheet

**Label: `Sheet-PodcastSearch`**

A full-screen sheet containing its own `NavigationStack`. Presented from `PodcastsView` (`+` button) and `MenuSheetView` ("Find Podcasts"). Forced dark mode.

**Five display phases:**
- **Idle** — centred magnifying glass icon + prompt copy + Recently Viewed history list (if any) + "Enter RSS URL" bordered button at the bottom
- **Loading** — centred `ProgressView("Searching…")`
- **Results** — `List` of podcast rows + "Enter RSS URL" footer row (navigates to `AddFeedView`)
- **Empty** — `ContentUnavailableView.search(text:)`
- **Failed** — `ContentUnavailableView` with error message

**Search bar:** `.searchable(placement: .navigationBarDrawer(displayMode: .always))`. Debounce: 400ms via `Task.sleep` in `PodcastSearchViewModel`. Results update automatically as the user types.

**Result row layout** — identical to `ListRow-SubscriptionRow` artwork column + text stack, but simplified (no rank pill, no status pill):
- **Artwork** — 44×44, `cornerRadius 9`, `Artwork-Placeholder` fallback
- **Title** — `.headline.weight(.semibold)`, `.primary`, `lineLimit(1)`
- **Author** — `.subheadline`, `.secondary`, `lineLimit(1)`
- **Genre** — `.caption`, `.tertiary`, `lineLimit(1)`

**Navigation destinations:** Both push `PodcastDetailView`, which renders every podcast state itself.
- `navigationDestination(for: PodcastSearchResult.self)` — checks for an existing real subscription (`browseDate == nil`) at the tapped feed URL; if found, pushes `PodcastDetailView(subscriptionID:)`; otherwise `PodcastDetailView(result:)`.
- `navigationDestination(for: UUID.self)` — used by Recently Viewed rows. Pushes `PodcastDetailView(browseSubscription:)` for browse subscriptions (`browseDate != nil`) or `PodcastDetailView(subscriptionID:)` for real subscriptions, including Inactive ones.

**Recently Viewed row layout:**
- **Artwork** — 44×44, `cornerRadius 9`
- **Title** — `.headline.weight(.semibold)`, `.primary`, `lineLimit(1)`
- **Author** — `.subheadline`, `.secondary`, `lineLimit(1)`
- **Browse date** — `.caption`, `.tertiary` — "Viewed today / yesterday / [abbreviated date]"

**Cancel button:** `.topBarLeading` toolbar item — dismisses the sheet.

---

## Podcast Detail Page

**Label: `View-PodcastDetail`**

The single page (`PodcastDetailView`) for a podcast in **every** state — an unsubscribed search/preview, a browse-only preview, an active subscription, or an Inactive subscription whose auto feed refresh is paused. Replaces the former `PodcastPreviewView` and `SubscriptionEpisodesView` (merged June 2026). Pushed from Podcast Search, Discover, Recently Viewed, the Priority Stack, and the Player's show name. A `VStack` layout (not `ScrollView`) — the episode list is a `List` that fills remaining vertical space. `MiniPlayerBar` is always docked at the bottom.

For an unsubscribed preview, a browse subscription is created automatically in the background when the feed finishes loading (`.task`), so the episode list is fully interactive from first load. See FEATURES.md §2.4 for the full browse subscription lifecycle.

**Toolbar:**
- Back button (`chevron.left.circle.fill`) — leading, always.
- Share button (`square.and.arrow.up`) — trailing, always.
- **Refresh Feed** (`arrow.clockwise`) and **Show Settings** (`gearshape` → `SubscriptionSettingsView`, `.primaryAction`) — shown for real subscriptions (`browseDate == nil`), including Inactive ones; absent on unsubscribed previews and browse pages.

**Header** — matches `Header-SubscriptionPage` with a Subscribe⇄Unsubscribe button appended:
1. **Artwork** — 120×120 pt, `cornerRadius 20`, 0.5pt white/8% stroke overlay, `Artwork-Placeholder` fallback
2. **Title** — `.title3.weight(.bold)`, `.primary`, `multilineTextAlignment(.center)`
3. **Video / Explicit pills** — `Badge-VideoPillLarge` + `Badge-ExplicitPillLarge`, shown when applicable, centred between title and description
4. **Description** — `.footnote`, `.secondary`, `multilineTextAlignment(.center)`, HTML-stripped. Collapsed to `lineLimit(3)` with a trailing **"…more"** toggle; a hidden measurement probe (`DescriptionTruncationKey` preference) only shows the toggle when the text actually overflows 3 lines, and tapping it expands to the full untruncated description.
5. **Author · Categories** — `.caption`, `.secondary`, `fontWeight(.bold)`, separated by `·`
6. **Subscribe row** — the full-width **Subscribe ⇄ Unsubscribe button** (height `50 pt`, `.borderedProminent`; not subscribed: `.purple` tint, `Label("Subscribe", systemImage: "plus.circle.fill")`; subscribed or Inactive: `.gray` tint, `Label("Unsubscribe", systemImage: "checkmark.circle.fill")` → confirmation dialog before removing; `ProgressView` while subscribing) laid out beside a **notification bell** button (`bell.fill`/`bell.slash`, purple-tinted iOS-glass capsule) shown for real subscriptions, including Inactive ones, toggling `Subscription.notificationsEnabled` in place. See FEATURES.md §2.2/§2.3.

**Episodes section heading** — `Text("Episodes")` `.title3.weight(.bold)` + `Image(systemName: "waveform")` `.title3.weight(.semibold)` `.secondary`. The heading `HStack` has `.padding(.top, 10)` on top of the VStack's base spacing (12 pt), giving ~22 pt total visual gap between the Subscribe button row and the Episodes heading.

**Episode list** — a `List` in a `RoundedRectangle(cornerRadius: 16)` card with `Color.white.opacity(0.08)` background, using `ListRow-EpisodeRow` (Video/Explicit badges as a top-trailing overlay per DESIGN.md):
- `NavigationLink` to `EpisodeDetailView` for each row
- Leading swipe: Play (green), Play Next (blue)
- Trailing swipe: far-right Download (teal) / Archive / Unarchive (purple), Play Last (orange) — **no Share swipe**
- Download progress bar
- **Load Older Episodes** button at ≥50 episodes — calls `appState.loadFullEpisodeHistory(for:)`

**Loading state:** While the feed is fetching and no subscription exists yet, a centred `ProgressView("Loading feed…")` is shown in place of the content view.

---

## Return to Player Button

**Label: `Button-ReturnToPlayer`**

Always the first leading button on any page toolbar. Posts a notification that collapses navigation back to the main player.

```swift
struct ReturnToPlayerButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
        } label: {
            Image(systemName: "play.circle.fill")
        }
        .accessibilityLabel("Return to Player")
    }
}
```

---

## Menu Hamburger Button

**Label: `Button-MenuHamburger`**

Second leading button. Opens `MenuSheetView`.

```swift
Button { showMenu = true } label: {
    Image(systemName: "line.3.horizontal")
}
.sheet(isPresented: $showMenu) { MenuSheetView() }
```

---

## Reorder Toggle Button

**Label: `Button-ReorderToggle`**

Third leading button on pages with reorderable lists. Switches between "Reorder" and "Done".

```swift
Button(editMode == .active ? "Done" : "Reorder") {
    withAnimation { editMode = editMode == .active ? .inactive : .active }
}
.environment(\.editMode, $editMode)  // passed to the List
.moveDisabled(editMode != .active)   // applied per row
```

---

## Refresh All Button

**Label: `Button-RefreshAll`**

First trailing button. Triggers full feed refresh. Hidden when the list is empty.

```swift
if !subscriptions.isEmpty {
    Button { refreshAll() } label: {
        if isRefreshingAll { ProgressView() }
        else { Label("Refresh All", systemImage: "arrow.clockwise") }
    }
    .disabled(isRefreshingAll)
}
```

---

## Add Podcast Button

**Label: `Button-AddFeed`**

Rightmost trailing button. Opens `PodcastSearchView` as a sheet — the primary podcast discovery and subscription flow. `AddFeedView` (RSS URL entry) is accessible from within `PodcastSearchView`.

```swift
Button { showSearch = true } label: {
    Label("Add Podcast", systemImage: "plus")
}
.sheet(isPresented: $showSearch) { PodcastSearchView() }
```

---

---

# Main Player Page

The Main Player is the root view of the app — a full-screen `ZStack` on black (`Color.black.ignoresSafeArea()`). It has no navigation bar. Three panels are swiped horizontally via `TabView(.page)` with the default index dots hidden: **Now Playing**, **Details**, and **Chapters** (only when the current episode has chapters).

---

## Main Player — Top Bar

**Label: `TopBar-Player`**

A custom `HStack` across the top of the screen (not a SwiftUI toolbar). Three zones:

| Zone | Content | Action |
|---|---|---|
| Leading | `list.bullet` glass icon circle (15pt semibold, white; neutral `.glassEffect(in: Circle())`, `Color(white: 0.12)` circle fallback) | `NavigationLink` to Priority page |
| Leading (cont.) | **Sleep Schedule indicator** — `bed.double.fill` pill, only while in the active-hours window | `NavigationLink` to `AppRoute.sleepSchedule` |
| Centre | Panel tab strip — `Now Playing` / `Details` / `Chapters` | Switches `TabView` panel with `easeInOut(0.22)` animation |
| Trailing | Up Next count pill (`Player-GlassPill`, icon + count) | Opens `QueueSheetView` as a sheet |

**Panel tab strip** — each tab is a plain `Button`. The selected tab sits on neutral glass (`.glassEffect(in: Capsule())`; `Color(white: 0.15)` capsule fallback below iOS 26) with white foreground and shows its title; unselected tabs stay bare (no glass) with `Color(white: 0.4)` foreground. `font(.system(size: 13, weight: .semibold))`, height 30.

**Sleep Schedule indicator (`Indicator-SleepSchedule`)** — appears immediately right of the leading nav icon, but only while `sleepScheduleService.isActive` (schedule enabled AND current time inside the active-hours window). Uses the shared `Player-GlassPill` surface (neutral glass, purple `0.85` icon, height 32) — the same pill as the audio-row buttons and Up Next pill. Shows `bed.double.fill` plus the whole minutes until the next "still listening?" prompt (`minutesUntilPrompt`, from the `.counting` phase); when not counting (paused, idle, or End-of-Episode mode) the icon shows alone. Wrapped in a `TimelineView(.periodic(by: 30))` so it appears/disappears at the window edges and the digit stays current while paused.

**Up Next count pill** — shows `appState.downloadedQueue.count` (`square.stack` icon + count). Uses the shared `Player-GlassPill` surface (neutral glass, purple `0.85` icon/text, height 32) — matching the audio-row buttons. When an episode is added to the queue it briefly cross-fades to that episode's subscription artwork. Opens `QueueSheetView`.

```swift
HStack(spacing: 0) {
    NavigationLink(value: AppRoute.podcasts) {
        Image(systemName: "list.number")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
    }

    Spacer()

    HStack(spacing: 2) {
        ForEach(visiblePanels) { panel in
            Button(panel.title) {
                withAnimation(.easeInOut(duration: 0.22)) { selectedPanel = panel.rawValue }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selectedPanel == panel.rawValue ? .white : Color(white: 0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selectedPanel == panel.rawValue ? Color(white: 0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    Spacer()

    Button { showQueue = true } label: {
        Text("\(appState.downloadedQueue.count)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color(white: 0.55))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(white: 0.18), lineWidth: 0.5))
    }
}
.padding(.horizontal, 16)
```

---

## Main Player — Now Playing Panel

**Label: `Panel-NowPlaying`**

A non-scrolling `GeometryReader` panel. All vertical space is pre-calculated so the artwork fills exactly what remains after reserving space for every other element. The panel renders top to bottom:

1. **Artwork** (`Artwork-Player`) — fills remaining vertical space, constrained also by `width − 44`
2. **Chapter strip** (`Panel-Chapters` strip) — only when `!appState.activeChapters.isEmpty`
3. **Episode copy** (`EpisodeCopy-Player`)
4. **Scrubber** (`Scrubber-Player`)
5. **Controls** (`Controls-Player`)
6. **Audio row** (`AudioRow-Player`)
7. **Up Next row** (`UpNextRow-Player`) — only when queue has a second episode

Horizontal padding throughout: `22 pt` on each side. Bottom padding on the last element: `30 pt`.

---

## Main Player — Artwork

**Label: `Artwork-Player`**

The artwork fills the largest square that fits after reserved height is subtracted. A purple radial gradient is layered behind the artwork image to add ambient glow.

- **Size** — computed dynamically: `max(80, min(geo.size.width − 44, geo.size.height − reservedHeight))`
- **Corner radius** — `18` when chapters are present, `20` otherwise
- **Radial glow** — `RadialGradient(colors: [Color.purple.opacity(0.34), .clear], center: .init(x: 0.5, y: 0.66), startRadius: 0, endRadius: size * 0.54)`
- **Overlay** — `white.opacity(0.1)` stroke, lineWidth 0.5
- **Placeholder** — `Color(white: 0.07)` fill + `waveform` icon at `size 52, weight .semibold, Color.purple.opacity(0.5)` (not the standard gradient placeholder)

**Video episodes:** artwork area is replaced by `VideoPlayer(player:)` at 16:9 aspect ratio, centred vertically in the artwork frame. Two overlay buttons bottom-trailing: Picture-in-Picture (`pip.enter`) and Full Screen (`arrow.up.left.and.arrow.down.right`). Both use `38×34 pt`, `black.opacity(0.58)` background, `cornerRadius 12`.

**Artwork URL resolution:** channel artwork is preferred (`subscriptionStore.subscription(id:)?.artworkURL`), falling back to `episode.artworkURL`.

---

## Main Player — Episode Copy

**Label: `EpisodeCopy-Player`**

Centred, two-line stack placed directly below the artwork.

- **Episode title** — `font(.system(size: 16, weight: .bold))`, `.white`, `multilineTextAlignment(.center)`, `lineLimit(2)`
- **Subscription name** — `font(.system(size: 12))`, `Color(white: 0.55)`, `multilineTextAlignment(.center)`, `lineLimit(1)`. Tappable: `NavigationLink` to `PodcastDetailView` for that subscription.

Empty state (no episode): title becomes `"No Episode"` at `Color(white: 0.3)`, subtitle becomes context-sensitive hint.

```swift
VStack(alignment: .center, spacing: 3) {
    Text(ep.title)
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: .infinity)

    NavigationLink { PodcastDetailView(subscriptionID: sub.id) } label: {
        Text(sub.title)
            .font(.system(size: 12))
            .foregroundStyle(Color(white: 0.55))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
}
```

---

## Main Player — Scrubber

**Label: `Scrubber-Player`**

**AI CONTEXT — seek completion/recovery (2026-07-17):** `sliderValue` is local
drag state while `PlaybackClock.time` is the canonical rendered position. A normal
Slider editing-end commits one seek. If iOS cancels the gesture without delivering
editing-end, five seconds without thumb movement commits the same seek and clears
`isSeeking`, preventing permanently frozen elapsed/remaining labels. A scrub or
forward skip within 0.25 seconds of duration is an episode completion: it must use
the played/history/position-clear/advance pipeline and must never start an engine
buffer loop at EOF. If that episode was a Play Instant return target, completion
cancels the return so its skipped ending cannot be resurrected later.

Purple `Slider` above a two-label time row. The slider value tracks the canonical playback clock while not seeking; during seek the value is decoupled and committed on `onEditingChanged(false)`. On first appearance, the drag-local slider state is explicitly synchronised from the restored playback clock so a paused resumed episode does not render with the thumb stranded at the beginning.

> **Glass:** the scrubber is a stock SwiftUI `Slider`, which on iOS 26 automatically renders with the system Liquid Glass thumb/track — there is no custom opacity/material surface to replace, so it carries only `.tint(.purple)`. No manual `.glassEffect` is applied (or needed).

- **Slider** — `tint(.purple)`, range `0...duration`, disabled when no episode
- **Left label** — elapsed time: `formatTime(displayTime)` in `h:mm:ss` or `m:ss` format
- **Right label** — remaining time: `"-\(formatTime(remainingTime))"`, `Color(white: 0.55)`
- Both labels: `font(.system(size: 13, weight: .semibold, design: .rounded))`, `.monospacedDigit()`, `Color(white: 0.42)` / `Color(white: 0.55)`

```swift
VStack(spacing: 6) {
    Slider(value: $sliderValue, in: 0...total, onEditingChanged: { editing in
        isSeeking = editing
        if !editing { appState.seek(to: min(max(0, sliderValue), total)) }
    })
    .tint(.purple)

    HStack {
        Text(formatTime(displayTime)).monospacedDigit().foregroundStyle(Color(white: 0.42))
        Spacer()
        Text("-\(formatTime(remainingTime))").monospacedDigit().foregroundStyle(Color(white: 0.55))
    }
    .font(.system(size: 13, weight: .semibold, design: .rounded))
}
```

---

## Settings Trim Control Row

**Label: `ControlRow-EpisodeTrim`**

The Start skip / End skip controls on both **Podcast Settings** and **App
Settings → Default Playback** use the same shared row component:

- Left side: purple `SettingsRowLabel` title with the current trim value below it
- Value text: compact elapsed wording (`Off`, `45 secs`, `1 min`, `1 min 30 secs`)
- Right side: fixed-width capsule with 44pt minus/plus buttons
- Section surface: App Settings applies `cardBackground` directly to each native
  Form row. Podcast Settings follows its custom-control sections: both trim rows
  sit in one `glassCard(cornerRadius: 12)` with 20pt horizontal / 14pt vertical
  row padding, a divider inset by 60pt, zero outer list insets, and a clear Form
  row background. This exactly mirrors the neighbouring Automation card and
  prevents iOS 26 from assigning custom trim rows a different glass shade.
- Interaction: each tap updates the visible value immediately, then debounces the
  persisted write so rapid adjustments do not thrash the store or active playback
- Motion: the row disables inherited animations from playback-clock/store updates
  so it stays stable while scrolling and while an episode from that subscription
  is actively playing

This row intentionally does **not** use native `Stepper` chrome because the
system material was recompositing poorly in the scrolling settings forms.

```swift
EpisodeTrimControlRow(
    title: "Start skip",
    systemImage: "backward.end.fill",
    persistedSeconds: ...,
    onCommit: ...
)
```

---

## Main Player — Controls

**Label: `Controls-Player`**

Three-button `HStack`. Skip buttons flank the central play/pause button.

- **Skip back / Skip forward** — `SkipIntervalIcon` view: `gobackward` / `goforward` SF Symbol at `size 36, weight .regular` with the skip seconds number overlaid at `size 15 (or 12 for ≥100s), design .rounded`, offset `y: 3`. Foreground `Color(white: 0.9)`. Frame `64×64`.
- **Play / Pause** — `pause.fill` / `play.fill` at `font size 28`, white, `76×76` circle. The primary CTA, so it uses purple-tinted glass (`.glassEffect(.regular.tint(.purple), in: Circle())`; solid `Color.purple` circle fallback below iOS 26), with the purple glow `shadow(color: purple.opacity(0.35), radius: 14)` retained in both. Disabled when queue is empty.
- Skip seconds values come from `appState.settingsStore.appSettings.skipBackSeconds` / `skipForwardSeconds`.
- Skip forward overshot: if `currentTime + skip ≥ duration`, advances to the next episode instead of clamping.

```swift
HStack(alignment: .center) {
    Button { /* seek back */ } label: {
        SkipIntervalIcon(direction: .backward, seconds: skipBackSeconds)
    }
    .frame(maxWidth: .infinity)

    Button { Task { await appState.togglePlayPause() } } label: {
        let playIcon = Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 28))
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)

        if #available(iOS 26, *) {
            playIcon.glassEffect(.regular.tint(.purple), in: Circle())
                .shadow(color: Color.purple.opacity(0.35), radius: 14)
        } else {
            playIcon.background(Color.purple).clipShape(Circle())
                .shadow(color: Color.purple.opacity(0.35), radius: 14)
        }
    }

    Button { /* seek forward or advance */ } label: {
        SkipIntervalIcon(direction: .forward, seconds: skipForwardSeconds)
    }
    .frame(maxWidth: .infinity)
}
.padding(.vertical, 8)
```

---

## Main Player — Audio Row

**Label: `AudioRow-Player`**

A five-button `HStack` below the controls, providing access to audio settings, output routing, sharing, and episode archiving.

| Zone | Width | Content |
|---|---|---|
| Leading | 96 pt (leading-aligned) | Sound Settings button + Sleep Timer button |
| Centre | expands | AirPlay / audio route picker |
| Trailing | 96 pt (trailing-aligned) | Share button + Archive button |

**Sound Settings button** (`slider.horizontal.3`) — `Button-PlayerAction` style. Opens `AudioControlsSheetView`.

**Sleep Timer button** (`moon.zzz` / `moon.zzz.fill`) — `Button-PlayerAction` style. When the sleep timer is **inactive**, icon is `Color.purple.opacity(0.85)` on neutral glass. When **active**, the pill becomes purple-tinted glass with a `.white` icon (`highlighted` state). A small badge capsule (purple background, white text) overlays the top-trailing corner showing either a countdown (`"m:ss"` / `"Xh"`) for duration mode or `"Nep"` for episode mode. Opens `SleepTimerSheetView`.

**AirPlay button** — a visible `HStack` of `airplayaudio` icon + route name label layered under an invisible `AVRoutePickerView` (`opacity(0.02)`) that captures the tap. Shows the current audio output name from `AVAudioSession.currentRoute.outputs.first`. Route-change stability is handled below the UI in `PlaybackEngine`: brief AirPods/Speaker route storms should not visually change this control except for the route label itself, while confirmed device removal still leaves playback paused until the user resumes. iOS may report real AirPods transitions as `unknown` or `categoryChange`, so the engine treats settled output changes as restart candidates even when the route reason is not tidy.

**Share button** (`square.and.arrow.up`) — `Button-PlayerAction` style. Opens `EpisodeShareSheet` (`Views/EpisodeShareSheet.swift`): a fixed-height bottom sheet (`presentationDetents([.height(580)])`, sized to the 280×360 share card + Share/Cancel buttons so it sits proportionally with the other audio-row sheets — not full-screen) that previews the rendered episode share card (`EpisodeShareCardView` — artwork, episode title, podcast name, Autohop branding) and exports it through the system share sheet together with the episode's audio URL. Disabled when no episode is loaded.

**Archive button** (`archivebox`) — `Button-PlayerAction` style. Opens `ArchiveConfirmationSheet` (a bottom sheet). On confirm, calls `archiveEpisodeAndPlayNext` to archive the currently playing episode and advance to the next. Icon matches `SwipeActions-EpisodeRow` (`archivebox`).

---

## Main Player — Archive Confirmation Sheet

**Label: `ArchiveConfirmationSheet`**

A bottom sheet presented when the Archive button is tapped in `AudioRow-Player`. Matches the dark card style of `SleepTimerSheetView` and `AudioControlsSheetView`.

- **Background** — `Sheet-MaterialBackground` (`.presentationBackground(.regularMaterial)`), `presentationCornerRadius(20)`, drag indicator hidden
- **Height** — fixed `320 pt` (`presentationDetents([.height(320)])`)
- **Icon** — `archivebox` at `size 28, weight .semibold`, `Color.purple.opacity(0.85)`
- **Title** — `"Archive Episode?"`, `size 17, weight .bold`, white
- **Message** — `"This will archive the currently playing episode and delete its downloaded file."`, `size 14, Color(white: 0.55)`, centre-aligned
- **Archive button** — full-width, `Color.purple.opacity(0.85)` background, `cornerRadius 14`, white bold label. Dismisses sheet then calls `onConfirm`.
- **Cancel button** — full-width, `Color(white: 0.12)` background, `cornerRadius 14`, `Color(white: 0.55)` semibold label. Dismisses sheet only.

---

## Player Action Button

**Label: `Button-PlayerAction`**

The shared **glass** style used by the Player's six action pills — the audio-row buttons (Sound Settings, Sleep Timer, Share, Archive) plus the top-bar Queue pill and Sleep Schedule indicator. The icon style is the `playerActionIcon(_:highlighted:)` helper; the surface is the shared `playerGlassPill(highlighted:cornerRadius:)` modifier (`Player-GlassPill`, `Views/PlayerView.swift`).

- **Icon** — SF Symbol at `size 18, weight .bold`; `Color.purple.opacity(0.85)` foreground when idle, `.white` when `highlighted` (Sleep Timer running, Shared Listening on)
- **Frame** — `44×32 pt` (icon buttons); the Queue/Sleep-Schedule pills size to their content at height 32
- **Surface** — `playerGlassPill`:
  - **iOS 26+:** idle → neutral `.glassEffect(in: RoundedRectangle(cornerRadius: 9))`; highlighted → purple-tinted `.glassEffect(.regular.tint(.purple), in:)` — same idle/active split as the Priority page reorder toggle
  - **iOS 17–25 fallback:** the original `Color.purple.opacity(0.12)` fill + `Color.purple.opacity(0.3)` `lineWidth 0.5` stroke at `cornerRadius 9`

The centre AirPlay route picker (`audioSourceButton`) stays borderless — it is not a pill.

```swift
private func playerActionIcon(_ systemName: String, highlighted: Bool = false) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(highlighted ? Color.white : Color.purple.opacity(0.85))
        .frame(width: 44, height: 32)
        .playerGlassPill(highlighted: highlighted)
}

private extension View {
    @ViewBuilder
    func playerGlassPill(highlighted: Bool = false, cornerRadius: CGFloat = 9) -> some View {
        if #available(iOS 26, *) {
            if highlighted {
                glassEffect(.regular.tint(.purple), in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            background(Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.purple.opacity(0.3), lineWidth: 0.5))
        }
    }
}
```

---

## Main Player — Up Next Row

**Label: `UpNextRow-Player`**

Shows the second episode in the queue (the one after the currently playing episode) as a preview card at the bottom of the Now Playing panel. Uses the `ListRow-Standard` layout inside a rounded card.

**Important:** `.swipeActions` is incompatible with content inside `TabView(.page)` (gesture conflicts). The Up Next row uses a **custom `DragGesture`** instead, with `highPriorityGesture` to beat the `TabView` pan recogniser.

Card appearance: shared `Glass-Card` (`.glassCard(cornerRadius: 14)` — iOS 26 glass, `.ultraThinMaterial` fallback). Padding `14 pt` horizontal + `10 pt` vertical. The card slides over the green/purple swipe-action reveals; the Video/Explicit badges remain a top-trailing overlay outside the glass clip.

**Position indicator:** `arrow.forward` icon (not a number) — purple, `size 10, weight .bold`, 20 pt frame.

**Swipe gesture actions:**
- Swipe right (leading) → **Play** (`Color.green` reveal) — calls `appState.skipToEpisode(episode)`
- Swipe left (trailing) → **Archive** (`Color.purple` reveal) — calls `appState.archiveEpisode(episode)`
- Open threshold: `40 pt`. Full-open offset: `80 pt`. Snaps to open/closed with `spring(response: 0.3, dampingFraction: 0.75)`.
- Horizontal drag is only recognised when `|deltaX| > |deltaY| × 0.6` — vertical drags fall through to any scroll container.

```swift
// Inside UpNextRow
.highPriorityGesture(
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
        .onChanged { value in
            let h = value.translation.width
            let v = value.translation.height
            guard abs(h) > abs(v) * 0.6 else { return }
            // ...update offset...
        }
        .onEnded { _ in
            // snap to open (±80) or closed (0) based on threshold
        }
)
```

---

## Main Player — Chapter Strip

**Label: `Panel-Chapters` (strip variant)**

When `appState.activeChapters` is non-empty, a compact chapter strip appears between the artwork and episode copy on the Now Playing panel. It shows the current chapter title + "Chapter N of M" and provides prev/next navigation buttons.

- **Prev / Next buttons** — `28×28` circle, `Color(white: 0.12)` fill, `white.opacity(0.18)` stroke, `chevron.left` / `chevron.right` at `size 13, weight .semibold, Color(white: 0.55)`. Disabled at first/last chapter.
- **Centre area** — tappable; navigates to the full Chapters panel with `easeInOut(0.22)`. Title: `size 12, weight .bold, white`, `lineLimit(1)`. Subtitle: `size 10, Color(white: 0.33)`.
- **Container** — shared `Glass-Card` (`.glassCard(cornerRadius: 12)` — iOS 26 glass, `.ultraThinMaterial` fallback). `padding(.horizontal, 11)`, `padding(.vertical, 8)`. The prev/next chevron buttons stay as dark `Color(white: 0.12)` circles inside the glass.

---

## Main Player — Chapters Panel

**Label: `Panel-Chapters`**

The full chapters panel (third tab). A header row (chapter count + skip count, plus All/None bulk-toggle buttons) sits above a scrollable chapter list. The list (the `LazyVStack` of rows) is wrapped in a shared `Glass-Card` (`.glassCard(cornerRadius: 16)`, inset `padding(.horizontal, 12)`) — like the Podcast Detail episode list — so the rows sit on one glass surface; the old full-width header divider is dropped. Chapter rows use `padding(.horizontal, 14)` to sit inside the card.

**Chapter row structure:**
- **Toggle circle** — 24×24, `Color.purple` fill + `checkmark` when included; clear fill + `Color(white: 0.33)` stroke when skipped
- **Chapter number** — `size 12, weight .bold`, `Color.purple` when current, `Color(white: 0.33)` otherwise, 18 pt trailing-aligned
- **Title + start time** — title `size 13, weight .bold`, white (skipped: `Color(white: 0.3)` + strikethrough); start time `size 11, Color(white: 0.22)`
- **Current indicator** — 6pt purple filled circle when chapter is playing
- **Duration** — trailing, `size 11, Color(white: 0.22)`, `.monospacedDigit()`
- **Active row background** — `Color.purple.opacity(0.08)`, same as `ListRow-ActiveBackground`
- **Skipped row opacity** — `0.45`
- **Divider** — `white.opacity(0.06)` at the bottom of each row

The row body seeks to that chapter; its leading circular control toggles the skipped state. Disabling the currently playing chapter in the Player immediately advances to the next enabled chapter. The Podcast Settings list disables its current row to protect against accidental interruption. Previous/next availability is derived from real time-based navigation targets, never a fabricated fallback index.

---

## Main Player — Details Panel

**Label: `Panel-Details`**

A `ScrollView` showing full episode metadata. Sections top to bottom:

1. **Episode title** — `size 20, weight .bold`, white, `padding(.horizontal, 20)`
2. **Metadata row** — date (`calendar` icon) + duration (`hourglass` icon), `size 12, Color(white: 0.55)`
3. **Description image** — either the first `<img>` extracted from the description HTML, or the channel/episode artwork as a fallback. `cornerRadius 14`, full width. Shown before the text.
4. **Episode subtitle** — `size 13, weight .bold, Color(white: 0.55)` (from RSS `<itunes:subtitle>`)
5. **Episode author** — `size 12, Color(white: 0.33)` (from RSS `<itunes:author>`)
6. **`HTMLDescriptionText`** — full HTML description. `fontSize: 14`, `color: Color(white: 0.78)`, `linkColor: .purple`. `showsFirstImage: false` (image already shown above). Wrapped in a `Glass-Card` (`.glassCard(cornerRadius: 16)`, `padding 14`) with an explicit `white.opacity(0.12)` `lineWidth 0.5` border overlay, inset `padding(.horizontal, 20)`.
7. **Meta cards grid** (`MetaCard-Details`) — two-column `LazyVGrid` of glass cards in a `GlassEffectContainer(spacing: 8)`

---

## Main Player — HTML Description

**Label: `HTMLDescriptionText`**

A SwiftUI `View` that renders a raw HTML string from an episode's RSS description field as a styled `Text`. Safe to use in `ScrollView` contexts (not in a `List` or during view init).

**How it works:**
- Strips `<img>` tags and normalises `<br>` / `<p>` for text display
- Converts `<li>` list items to `<p>• ` paragraphs and strips `<ul>/<ol>` wrappers, so list items get paragraph spacing instead of rendering as cramped lines (applied in `htmlForTextDisplay(_:)` via regex, benefits all `HTMLDescriptionText` uses — Player Details, Episode Detail, Support)
- Parses with `NSAttributedString(.html)` on a background thread is acceptable here — unlike in `List` row bodies, `ScrollView` doesn't trigger WebKit spin-up in the main render pass
- Strips `NSForegroundColorAttributeName` so SwiftUI `.foregroundStyle` applies
- Normalises all fonts to SF system font at `fontSize`, preserving bold and italic traits
- Re-colours links to `UIColor.systemPurple` with `.underlineStyle.single`
- Falls back to plain-text HTML tag stripping if `NSAttributedString` parsing fails

**Parameters:**

```swift
HTMLDescriptionText(
    html: ep.description ?? "",
    fontSize: 14,
    color: Color(white: 0.78),
    linkColor: .purple,
    showsFirstImage: false,  // true shows the first <img> above the text
    sentenceBreaks: false    // true: blank line after each sentence-ending full stop
)
```

**`sentenceBreaks`** — when `true`, the space(s) after a sentence-ending full stop (`.` followed by whitespace) are replaced with a blank line, so each sentence reads on its own. Applied via a regex pass on the parsed `NSMutableAttributedString` (`(?<=\.)[ \t]+` → `\n\n`), preserving font/link attributes; decimals and URLs have no space after the dot so they're untouched. **Only the Main Player Details panel description sets this `true`** — the Episode Detail description and all other uses keep the default `false`.

**`firstImageURL(from:)`** — static method used by the Details panel to extract the first `<img src=...>` from the HTML so it can be placed above the text block rather than inline.

> **Do not use `HTMLDescriptionText` inside `List` rows or `View.body` synchronous init paths** — it calls `NSAttributedString(.html)` which initialises WebKit and will crash if called during SwiftUI's synchronous layout pass. Use `stripHTML(_:)` from `SubscriptionSettingsView` for plain-text previews in list rows.

---

## Main Player — Meta Cards Grid

**Label: `MetaCard-Details`**

A two-column `LazyVGrid` of key/value **glass** cards shown at the bottom of the Details panel — same treatment as the Episode Detail page's `MetaGrid-EpisodePage`. Each card: uppercase tracking label + bold value.

- **Grid** — `[GridItem(.flexible()), GridItem(.flexible())]`, spacing `8`, wrapped in a `GlassEffectContainer(spacing: 8)` (iOS 26) so the tiles read as one cohesive glass surface
- **Card** — iOS 26: `.glassEffect(in: RoundedRectangle(cornerRadius: 10))`; iOS 17–25 fallback: flat `Color(white: 0.09)` + `white.opacity(0.075)` stroke. Padding `12 × 10`
- **Key** — `size 10, weight .bold`, `.textCase(.uppercase)`, `.tracking(0.5)`, `Color(white: 0.33)`
- **Value** — `size 13, weight .bold`, white, `lineLimit(2)`

Fields shown (when available): Published · Released · Duration · File size · Classification (Explicit / Clean) · File Status (Downloaded / Available / Archived) · Priority rank · Chapter count. The Published and Released cards split a single `publishedAt` into two complementary views: **Published** answers *which day* via `relativePublishedDateLabel` — Today / Yesterday / "N Days Ago" (up to 6 days) / then an abbreviated exact date ("12 Jun", year only when not the current year, e.g. "28 Dec 2024"); **Released** answers *what time* via `relativeReleasedLabel` — relative elapsed time under 24h ("10 minutes ago" / "2 hours ago"), then the actual clock time of release ("6:54 AM") once 24h+ old. (Episode **lists** still use the separate time-tiered `relativePublishedLabel`, so a same-day episode reads "11 hours ago" in a list but "Today" on the Published card.) All are shared helpers in `Views/EpisodeBadges.swift`, only shown when `publishedAt` is non-nil.

```swift
@ViewBuilder
private func metaCard(_ key: String, _ value: String) -> some View {
    let content = VStack(alignment: .leading, spacing: 3) {
        Text(key)
            .font(.system(size: 10, weight: .bold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Color(white: 0.33))
        Text(value)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)

    if #available(iOS 26, *) {
        content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
    } else {
        content
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
    }
}
```

---

## Player Sheets — Material Background

**Label: `Sheet-MaterialBackground`**

All sheets in the app use a translucent system **material** background instead of a solid fill, so they match the native AirPlay route picker.

Sheets covered:
- **Player sheets:** Queue (`QueueSheetView`), Sleep Timer (`SleepTimerSheetView`), Audio Controls (`AudioControlsSheetView`), Archive confirmation (`ArchiveConfirmationSheet`), Episode Share (`EpisodeShareSheet`)
- **Navigation sheets:** Menu (`MenuSheetView`) and Podcast Search (`PodcastSearchView`) — both apply `.presentationBackground(.regularMaterial)` on their outer `NavigationStack`

```swift
.presentationBackground(.regularMaterial)
.presentationCornerRadius(20)   // bottom sheets
```

- `.regularMaterial` renders as the system frosted material (Liquid Glass on iOS 26), blurring the content behind while staying legible.
- List/scroll content inside must set `.scrollContentBackground(.hidden)` so the material shows through — see Queue list, Menu list, Podcast Search list.
- Row backgrounds inside these sheets use `Color.white.opacity(0.07)` (Menu rows, Podcast Search result rows) so they read as distinct rows on the material without fighting it.
- Inner surface cards keep their own glass treatment — the Audio Controls speed stepper uses `.glassCard(cornerRadius: 10)` (iOS 26 glass, `.ultraThinMaterial` fallback), the Recently Viewed block in Podcast Search uses `.glassCard(cornerRadius: 16)`.
- The full-screen Sleep Schedule prompt (`Overlay-SleepSchedulePrompt`) is **not** a card sheet — it stays a solid `black.opacity(0.72)` dimming scrim.

---

## Main Player — Audio Controls Sheet

**Label: `AudioControls-Sheet`**

A bottom sheet (`presentationDetents`) for per-subscription audio settings. Sheet height is dynamic — base `300 pt` + `68 pt` for each active picker row (trim silence or vocal boost when enabled).

Sheet background: `Sheet-MaterialBackground` (`.presentationBackground(.regularMaterial)`). Drag indicator hidden; `presentationCornerRadius(20)`.

**Three rows, each separated by a `Divider` indented `60 pt` from the leading edge:**

### Speed Row
Stepper (`−` · value · `+`) on the right. Steps through `PlaybackPreference.speedOptions` array (e.g. `0.5× … 3.0×`). Value display: `size 15, weight .bold, design .rounded`, `.monospacedDigit()`. Stepper background: `.glassCard(cornerRadius: 10)` (iOS 26 glass, `.ultraThinMaterial` fallback), buttons `44×38 pt`.

### Trim Silence Row
`Toggle` (purple tint) on the right. When on, a segmented `Picker` with Low / Medium / High animates in below (`easeInOut(0.22)`). Picker tint: `.purple`.

### Vocal Boost Row
Same pattern as Trim Silence. Label includes a subtitle `"Voices sound clearer"` in `size 13, Color(white: 0.50)`. Levels: Light / Standard / Strong.

### Volume Adjustment Row (Podcast Settings only)

Placed immediately after Vocal Boost and before Mono Audio. Header uses the shared
purple `speaker.wave.1.fill` icon, 17 pt semibold title, 13 pt secondary subtitle
(`Adjust this podcast only`), and a purple bold rounded current value (`−2 dB`,
`0 dB`, `+2 dB`). Beneath it, a purple stepped Slider spans whole-number values
from −3 to +3 with compact endpoint labels. The control changes subscription gain,
not device volume; do not add it to global Default Playback.

**Row icon style:** `size 18, weight .semibold`, `.purple` foreground, `26 pt` fixed width frame.

```swift
// Sheet height adapts to visible pickers
private var sheetHeight: CGFloat {
    var height: CGFloat = 300
    if trimSilenceOn { height += 68 }
    if vocalBoostOn  { height += 68 }
    return height
}
```

---

# Individual Episode Page

The Individual Episode page (`EpisodeDetailView`) is a scrollable detail view pushed onto the navigation stack when tapping an episode row in the Individual Subscription page. It is modelled on `Header-SubscriptionPage` and `Panel-Details` from the Main Player.

---

## Individual Episode Page — Header

**Label: `Header-EpisodePage`**

Centred header at the top of the scroll content. All content is centre-aligned.

Structure (top to bottom):
1. **Artwork** — 120×120 pt, `cornerRadius 20`, subtle stroke overlay (`white.opacity(0.08), lineWidth: 0.5`). Uses `episode.artworkURL` with fallback to `subscription.artworkURL`, then `Artwork-Placeholder`.
2. **Episode title** — `.title3.weight(.bold)`, `.primary`, `multilineTextAlignment(.center)`
3. **Video + Explicit pills** — `HStack(spacing: 6)` of `VideoPillLarge` and/or `ExplicitPillLarge`, shown only when applicable. `VideoPillLarge` triggered by `ep.mediaKind == .video`; `ExplicitPillLarge` triggered by `ep.isExplicit == true`.
4. **Feed title** — `.subheadline`, `.secondary`, `multilineTextAlignment(.center)`
5. **Categories** — `sub.categories.joined(separator: " · ")`, `.caption`, `.tertiary`, `multilineTextAlignment(.center)`. Hidden when `sub.categories` is empty.

```swift
VStack(spacing: 12) {
    CachedArtworkImage(url: ep.artworkURL ?? sub.artworkURL) { placeholderArtwork }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))

    VStack(spacing: 6) {
        Text(ep.title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)

        let showVideo = ep.mediaKind == .video
        let showExplicit = ep.isExplicit == true
        if showVideo || showExplicit {
            HStack(spacing: 6) {
                if showVideo    { VideoPillLarge() }
                if showExplicit { ExplicitPillLarge() }
            }
        }

        Text(sub.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        if !sub.categories.isEmpty {
            Text(sub.categories.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}
.frame(maxWidth: .infinity)
```

---

## Individual Episode Page — Action Buttons

**Label: `Buttons-EpisodePage`**

Four action buttons in a single `HStack(spacing: 0)` below the header. Each button is a 64×64 pt filled circle with a `.title2.weight(.semibold)` icon centred inside, and a `.caption` / `.secondary` text label below. Layout uses `swipeStyleButton` — a plain-style button with `frame(maxWidth: .infinity)` so all four share equal width.

Colours and icons match `SwipeColor-Semantics` and `SwipeActions-EpisodeRow` exactly. All four buttons are **disabled** while `ep.downloadState == .downloading`.

| Button | Icon | Colour | Action |
|---|---|---|---|
| **Play** | `play.fill` | `.green` | Downloads first if not on device (`downloadEpisodeForQueue`), then fetches the refreshed episode object and calls `playEpisode(_:)` |
| **Play Next** | `text.line.first.and.arrowtriangle.forward` | `.blue` | Downloads first if not on device, then calls `playEpisodeNext(_:)` to pin to top of queue |
| **Play Last** | `text.line.last.and.arrowtriangle.forward` | `.orange` | Downloads first if not on device, then calls `playEpisodeLast(_:)` to pin to bottom of queue |
| **Download** | `arrow.down.circle` | `.teal` | Calls `downloadEpisodeForQueue(_:)`. Shown for not-downloaded episodes on active real subscriptions |
| **Archive** | `archivebox` | `.purple` | Calls `archiveEpisode(_:)`. Shown for downloaded episodes, and as the fallback for unplayed preview/inactive episodes |
| **Unarchive** | `arrow.uturn.backward.circle` | `.purple` | Calls `unarchiveEpisode(_:)`. Fallback for archived/played preview/inactive episodes |

Download/Archive/Unarchive occupy the same fourth slot — only one is shown at a time.

```swift
private func swipeStyleButton(
    label: String,
    icon: String,
    color: Color,
    disabled: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(color)
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
}
```

A `ProgressBar-Download` appears below the button row when `ep.downloadState == .downloading`.

---

## Individual Episode Page — Description

**Label: `Description-EpisodePage`**

Full HTML episode description rendered via `HTMLDescriptionText`, inside a **glass** rounded card matching `PodcastDetailView`'s `episodeListCard`. Both use the shared `glassCard(cornerRadius:)` modifier (`Glass-Card`) — real glass on iOS 26+, `.ultraThinMaterial` fallback below.

```swift
VStack(alignment: .leading, spacing: 8) {
    Text("Description")
        .font(.title3.weight(.bold))
        .foregroundStyle(.primary)

    HTMLDescriptionText(
        html: description,
        fontSize: 15,
        color: Color(white: 0.78),
        linkColor: .purple,
        showsFirstImage: false
    )
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(cornerRadius: 16)
}
```

Hidden when `ep.description` is nil or empty.

---

## Individual Episode Page — Details Grid

**Label: `MetaGrid-EpisodePage`**

A two-column `LazyVGrid` of meta cards at the bottom of the scroll content.

**Glass treatment:** the Episode page cards are **glass** and the grid is wrapped in a `GlassEffectContainer(spacing: 8)` so the small cards read as one cohesive glass surface. The Main Player Details panel's `MetaCard-Details` grid now uses the identical treatment.

- **iOS 26+:** each card `.glassEffect(in: RoundedRectangle(cornerRadius: 10))`, grid inside `GlassEffectContainer(spacing: 8)`
- **iOS 17–25 fallback:** flat `Color(white: 0.09)` card + `white.opacity(0.075)` stroke (the original `MetaCard-Details` style), no container

Key text stays `Color(white: 0.33)` uppercase; value text stays white bold.

Fields shown (when available):

| Field | Source | Always shown |
|---|---|---|
| Published | `relativePublishedLabel(ep.publishedAt)` — the canonical tiered relative date used by every episode list, the Subscriptions "Updated" row, and the Downloads page's downloaded/archived times ("Just now" / "15 mins ago" / "2 hours ago" / "Yesterday" / "N days ago" (2–6) / abbreviated date, year only when not the current year) | Only when non-nil |
| Released | `relativeReleasedLabel(ep.publishedAt)` — elapsed since publish, e.g. "2 days ago" | Only when non-nil |
| Duration | `ep.durationSeconds`, formatted `"Xh Ym"` / `"Ym"` | Only when non-nil |
| File Size | `ep.fileSizeBytes`, formatted `"X MB"` / `"X.X GB"` | Only when non-nil |
| Classification | `ep.isExplicit == true ? "Explicit" : "Clean"` | Always |
| File Status | Derived from `downloadState` + `playedState` (see below) | Always |
| Priority Rank | `sub.priorityRank`, formatted as ordinal (`"1st"`, `"2nd"`, etc.) | Always |

**File Status values:**

| Value | Condition |
|---|---|
| Played | `playedState == .played` |
| Archived | `playedState == .archived` |
| Now Playing | `downloadState == .downloaded && playedState == .playing` |
| Downloaded | `downloadState == .downloaded` |
| Downloading | `downloadState == .downloading` |
| Queued | `downloadState == .queued` |
| Download Failed | `downloadState == .failed` |
| Not Downloaded | `downloadState == .notDownloaded` |

---

## Individual Episode Page — Toolbar

**Label: `Toolbar-EpisodePage`**

| Side | Button |
|---|---|
| Leading | `Button-ReturnToPlayer` |

Empty navigation title (`.navigationTitle("")`) — the episode title is shown in the header content. Forced dark mode via `.preferredColorScheme(.dark)`.

---

# Stats Page

`Views/StatsView.swift`, reached via Menu → Stats or directly from a Listening Recap notification. Follows the standard dark scheme (`ColorScheme-Dark`), `Accent-Purple`, `NavTitle-Inline`. Every section card uses the shared `Glass-Card` modifier (`.glassCard(cornerRadius: 16)` — iOS 26 glass, `.ultraThinMaterial` fallback) rather than a flat `white.opacity(0.08)` fill. Card-internal dividers, axis grid lines, progress-bar tracks, and the nested expanded-show card stay on `white.opacity(…)` insets. All sections respond to the period selector.

Sections stack in a `VStack(spacing: 32)`: period selector · Hero · Top Shows · Drifting Shows · Heatmap/Trend · Listening Clock · **Data Downloaded** · Time Saved By · Privacy Footer.

## Stats Page — Period Selector

**Label: `Selector-PeriodPills`**

A centred `HStack(spacing: 8)` of capsule buttons (7 Days / [displayed month] / [displayed year] / Lifetime). The four ranges are calendar-anchored, each resetting at the start of its period: 7 Days = Monday 00:00 → now (resets Monday); the month pill is dynamically labelled from the active This/Last state (e.g. "July" in This Month, "June" in Last Month); the year pill likewise shows the active year (e.g. "2026" in This Year, "2025" in Last Year); Lifetime = all history. Pills use the same glass treatment as the Priority page reorder toggle: the selected pill is purple-tinted glass (`.glassEffect(.regular.tint(.purple), in: Capsule())`) with a white `.footnote.weight(.semibold)` label; unselected pills are plain glass (`.glassEffect(in: Capsule())`) with a `.secondary` label. Below iOS 26 the fallback is the original solid `Color.purple` / `Color.white.opacity(0.08)` capsule. Switching animates with `.easeInOut(duration: 0.15)`.

## Stats Page — Hero Card

**Label: `Card-StatsHero`**

`Glass-Card` rounded card (`.glassCard(cornerRadius: 16)`, padding 16). Contents top-to-bottom:
1. Subtitle (`.subheadline`, `.secondary`) — "Time listened" (or "Time listened since [date]" on Lifetime)
2. Headline number — `size 40, weight .bold`, `.purple`, `contentTransition(.numericText())`
3. `Divider` overlaid `white.opacity(0.08)`
4. Three equal columns (`heroStat`): value `.headline.bold` (teal for time saved, primary otherwise) over `.caption` `.secondary` label

## Stats Page — Heatmap

**Label: `Chart-Heatmap`**

GitHub-style contribution grid (7 Days and month periods only): columns are Monday-aligned weeks, rows are weekdays, leading/trailing nil-padded for weekday alignment (Monday = first day, independent of locale). Cell fill: `Color.clear` (pad), `white.opacity(0.06)` (zero), or `Color.purple.opacity(0.25 + 0.75 × √fraction)` scaled against the period's busiest day. Cell size 30 pt (≤7 weeks) or 19 pt. Caption below: "Busiest day: …" (`.caption`, `.secondary`). On the year and Lifetime views the card is replaced by a Swift Charts monthly `BarMark` chart (purple bars, `cornerRadius 3`, y-axis in hours, height 170).

## Stats Page — Listening Clock

**Label: `Chart-ListeningClock`**

24-hour rose chart drawn in a `Canvas` (height 230): midnight at top, noon at bottom; each hour is a wedge whose radius scales with `√(hourSeconds/max)`, filled `purple.opacity(0.9)` with 1° gaps between wedges. Two reference circles stroked `white.opacity(0.08)`. Compass labels 12am/6am/12pm/6pm in `.caption2` `.tertiary`. Caption below: "Peak listening: [range]".

## Stats Page — Data Downloaded

**Label: `Chart-DataDownloaded`**

A `Glass-Card` whose contents are, top to bottom:
1. **Headline row** — big cyan total (`size 36, weight .bold`, `.cyan`, `contentTransition(.numericText())`) + "total downloaded" caption on the left; on the right, two trailing mini-stats (`downloadMiniStat`: `.title3.bold.monospacedDigit` value over `.caption .secondary` label) — episode count and average size per episode. Mini-stats are hidden when nothing was downloaded.
2. **Download chart** — a Swift Charts `BarMark` of download volume over time, **cyan** (`Color.cyan.gradient`, `cornerRadius 3`, height 150) to distinguish it from the purple listening charts. Bucketing mirrors the trend chart: per-day bars on heatmap ranges (7 Days / month), per-month bars on year/Lifetime. X-axis labels `.day()` or `.month(.narrow)`; y-axis labels formatted via `formattedBytes` (3 marks). Hidden when no bytes were recorded in the period.
3. **Empty state** — when nothing was downloaded, the chart is replaced by "No episodes downloaded in this period" (`.subheadline`, `.secondary`).

## Stats Page — Top Show Row

**Label: `ListRow-TopShow`**

Card rows (standard `Section-CardRows` divider at `padding(.leading, 70)`): rank number (`.subheadline.semibold.monospacedDigit`, `.secondary`, width 18) · 44 pt artwork (`cornerRadius 9`, `Artwork-Placeholder` fallback) · show title (`.subheadline.semibold`, lineLimit 1) over a 4 pt purple capsule bar sized relative to the #1 show · trailing duration (`.caption.monospacedDigit`, `.secondary`). Up to 8 rows. Tapping a row toggles an inline `Card-ShowStatsExpanded` beneath it.

## Stats Page — Privacy Footer

Centred `.caption` `.tertiary` row: `lock.shield` icon + "Your listening stats are private — kept on your device and your own iCloud, never sent to Autohop."

## Completion Bar

**Label: `Chart-CompletionBar`**

Horizontal stacked outcome bar used in the Stats page "Shows You're Drifting From" rows (`CompletionBar` in `Views/StatsView.swift`). 5 pt tall, `Capsule`-clipped `HStack` with 1 pt gaps; segment widths proportional to episode counts, minimum 3 pt so tiny counts stay visible.

The underlying drift dataset excludes episodes in the current Download Feed
Filters **Skipped** state (`downloadState == .notDownloaded` and filter evaluation
rejected). These deliberate non-downloads contribute no finished, partial, or
unplayed segment and cannot qualify a show through either drift or neglect.
Manually downloaded episodes remain eligible because manual actions bypass filters.

- **Teal** — episodes finished
- **Orange** — stopped partway (abandoned)
- **`white.opacity(0.25)`** — archived unplayed

A single shared legend (`6 pt circle dots + .caption2 .tertiary labels`) appears once below the section, never per row.

## Stats Page — Drifting Show Row

Card rows (standard `Section-CardRows` divider at `padding(.leading, 70)`): 44 pt artwork (`Artwork-Placeholder` fallback) · show title (`.subheadline.semibold`, lineLimit 1) · blunt insight line (`.caption` `.secondary`, e.g. "Archived 6 of the last 8 unplayed") · `Chart-CompletionBar` · trailing "finished/total" fraction (`.caption.monospacedDigit`, `.secondary`). Row tap toggles an inline `Card-ShowStatsExpanded` beneath the row (this variant includes a Podcast Settings link to `SubscriptionSettingsView`); long-press context menu offers Hide From This List and Unsubscribe (confirmation dialog).

## Stats Page — Expanded Show Card

**Label: `Card-ShowStatsExpanded`**

Inline per-show detail card (`ShowStatsExpandedCard` in `Views/StatsView.swift`) revealed under a Top Shows or Drifting Show row by tapping it; tap again to collapse (animated `.easeInOut(duration: 0.2)`, transition `.opacity` + `.move(edge: .top)`). Nested card styling: `white.opacity(0.05)` background, `cornerRadius 12`, padding 14, inset `padding(.horizontal, 14)` inside the parent `Glass-Card` — kept as a faint solid inset rather than nested glass. Contents: a 2-column `LazyVGrid` of stat tiles — value `.subheadline.bold.monospacedDigit` (teal for finished/time-saved, orange for stopped-partway, primary otherwise) over a `.caption2` `.secondary` label — covering episodes finished, time saved ("(est.)" suffix when apportioned rather than tracked), share of all listening, average completion %, stopped partway, last listened (relative date), and typical wait after release. Drift-row variant appends a purple gear + "Podcast Settings" `NavigationLink`.

## Main Player — Sleep Schedule Prompt Overlay

**Label: `Overlay-SleepSchedulePrompt`**

Full-screen overlay shown over the player while `sleepScheduleService.isPrompting` (the screen-on / video case; on the lock screen the time-sensitive "Still Listening" notification handles it). `Color.black.opacity(0.72)` scrim, centred `VStack(spacing: 22)`: `moon.zzz.fill` (40pt, purple) · "Are you still listening?" (`size 22, .bold`, white) · subtitle (`size 14`, `Color(white: 0.6)`) · a deliberately **oversized** confirm button. The button fills the width and is `minHeight: 160` with a `size 26, .bold` "Still Listening" label, `Color.purple` fill, `cornerRadius 28`, explicit `contentShape` — a huge tap target so a half-asleep user can confirm without aiming. Tapping calls `sleepScheduleService.userResponded()`. The overlay is strictly bounded by the configured Active Hours: if the window ends during a prompt, the service dismisses the overlay, chime, and lock-screen notification while leaving podcast playback undisturbed.

## Support Page — Section Row

**Label: `ListRow-SupportSection`**

Drill-down list row in `SupportView` (Menu → Support). `HStack(spacing: 14)`: a 38×38 purple icon tile (`Color.purple.opacity(0.15)` fill, `cornerRadius 9`, 17pt semibold purple SF Symbol) · a `VStack` of the section title (`size 16, .semibold`, primary) over a one-line summary (`size 13`, `.secondary`, lineLimit 2). Standard dark `List` with `scrollContentBackground(.hidden)` over `Color.black`.

## Support Page — Content Blocks

**Label: `Blocks-Support`**

Native renderers in `SupportView` for the structured `SupportBlock` data (mirrors the website Support page; content in `SupportContent.swift`):

- **Paragraph / heading / bullets / steps** — `size 15` body in `Color(white: 0.75)`; headings `size 17 .bold` white; bullets use a purple "–", steps a purple monospaced index. Inline **bold** is parsed at runtime via `AttributedString(markdown:)`.
- **Callout** (`tip` / `note` / `warning`) — tinted rounded card (`tint.opacity(0.14)` fill, `0.3` stroke, `cornerRadius 10`) with a leading symbol (`lightbulb.fill` purple / `info.circle.fill` blue / `exclamationmark.triangle.fill` orange).
- **Table** — each row a `white.opacity(0.06)` card (`cornerRadius 12`): first cell a `.semibold` title, remaining cells labelled by the header (`**Header:** value`) or shown plain for two-column key/value tables.
- **Pills** — adaptive `LazyVGrid` of capsule status chips (8pt colour dot + label, `color.opacity(0.18)` fill) reusing the `Episode Status Pill` colour set.
- **Swipe-action cards** — two `white.opacity(0.06)` cards (Swipe Right / Swipe Left) listing each action as a colour dot + `**Label** — detail`, matching the Queue swipe semantics.

# Listening History Page

`ListeningHistoryView` (`Views/SettingsView.swift`), reached via Menu → Listening History. Forced dark (`ColorScheme-Dark`), `Accent-Purple`, black background. Layout: a header row of two glass stat tiles (`HistoryStatView` — Listening Time, Episodes) above a grouped history `List`. `.searchable` filters by episode/podcast title (60 s minimum playback threshold). Resolved episode rows use canonical `SwipeActions-EpisodeRow` behavior and show `ProgressBar-Download` beneath the row while an action-triggered download is active. Empty/empty-search states use `ContentUnavailableView`.

**Label: `View-ListeningHistory`**

- **Stat tiles** — `HistoryStatView`: uppercase `.caption2.bold` `.secondary` title over a `.title3.bold` primary value, in a `Glass-Card` (`.glassCard(cornerRadius: 12)`).
- **History list** — a `.plain` `List` with `.scrollContentBackground(.hidden)` wrapped in a single `Glass-Card` (`.glassCard(cornerRadius: 16)`), like `PodcastDetailView`'s episode list. Rows are clear so the one glass surface shows behind them; the currently-playing row gets `Color.purple.opacity(0.08)`. Sections are date groups (Today / Yesterday / abbreviated date) with `.caption.bold` `.secondary` headers.
- **Row** (`ListeningHistoryRow`) — canonical `ListRow-EpisodeRow` sizing: 44 pt artwork (`cornerRadius 9`, purple-gradient `Artwork-Placeholder` fallback) · episode title (`.subheadline.semibold`, primary, two lines) · podcast title (`.caption`, secondary, one line) · metadata (`.caption`, tertiary) · shared trailing `EpisodeStatusPill`. Metadata is historical and timestamped from the terminal mutation: `Completed • <date/time>`, `Manually Archived • <date/time>`, `Auto Archived • <date/time>`, or honest legacy/unresolved fallbacks (`Archived`, `Last listened`). Played/Archived pills come from the stored history outcome rather than a later live library state; unresolved entries show Paused, or Playing only while currently audible. The download bar uses the canonical 56 pt leading indent.
- **Swipe actions** (`SwipeActions-EpisodeRow`) — mirrors `PodcastDetailView`: leading **Play** (green) / **Play Next** (blue); trailing far-right **Download** (teal) for not-yet-downloaded episodes on active real subscriptions, otherwise **Archive** (purple, → **Unarchive** when the episode is archived/played), plus **Play Last** (orange). Each resolves the entry to its `Episode` via `subscriptionStore.episode(subscriptionID:episodeID:)`, downloads first if not on device, and is hidden when the entry's episode can't be resolved or is the currently-playing episode.

## Settings Pages — Form Style

**Label: `Form-SettingsDark`**

All settings pages (`SettingsView` / App Settings, `SubscriptionSettingsView` / Podcast Settings, `DownloadFiltersView`, `NotificationSettingsView`, `AddFeedView`, `DiagnosticLogView`, `AcknowledgementsView`) use a two-tier recipe:

**iOS 26 — native Liquid Glass Form sections:**
```swift
.scrollContentBackground(.visible)   // let iOS 26 Form glass through
.background(Color.clear.ignoresSafeArea())
.tint(.purple)
.preferredColorScheme(.dark)
```
Row backgrounds are `Color.clear` so the system glass section cards show unobstructed. The `Card-PlaybackControls` card uses `.glassCard(cornerRadius: 12)` (card surface) and `.glassCard(cornerRadius: 10)` (speed stepper).

**iOS 17–25 — flat dark card recipe (unchanged):**
```swift
.scrollContentBackground(.hidden)
.background(Color.black.ignoresSafeArea())
.tint(.purple)
.preferredColorScheme(.dark)
```
Each `Section` gets `white.opacity(0.08)` via `.listRowBackground(Color.white.opacity(0.08))`. `Card-PlaybackControls` receives `fill: Color.white.opacity(0.08)`.

Each page uses three shared computed helpers (`cardBackground`, `formScrollBackground`, `formPageBackground`) to switch between the two tiers via `#available(iOS 26, *)`. Pop-up editor sheets (skip duration, edit title, edit priority) carry `.tint(.purple)` + `.preferredColorScheme(.dark)` on both tiers.

Long section footers (> ~5 rendered rows) are split into multiple paragraphs with `\n\n` at a natural idea boundary for readability.

**Label: `SettingsRowLabel`**

Every control row (toggle, link, stepper, picker, value row) uses the shared `SettingsRowLabel` (`Views/PlaybackControlsCard.swift`) as its label, so each setting carries a purple glyph the way the Speed / Trim Silence / Vocal Boost rows do:

```swift
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.purple)
        }
    }
}
```

The icon is forced `.purple` while the title inherits the row's primary colour. Section group headers stay as plain text labels (no icon). Action buttons (Run Auto Archive, Import/Export OPML) keep their own `Label` and read as purple-tinted actions; destructive buttons (Unsubscribe) stay red.

## Auto Archive Activity

**AI CONTEXT — decision-audit surface (2026-07-15):** `AutoArchiveActivityView`
is reached from the Auto Archive section in System Settings. It is intentionally a
read-only operational history, not a second episode-management list. The durable
local store is bounded to 500 newest-first records and starts collecting only after
the feature is installed.

- Use the standard black page background, compact navigation title, circular glass
  back button, and persistent mini player used by other System Settings subpages.
- Render one standard rounded menu card per decision. Do not use episode artwork or
  swipe controls: the information hierarchy is episode title, podcast name, exact
  local archived date/time, then labelled Rule / Configured threshold / Measured age
  rows.
- Rule labels are user-facing and limited to **After Playing**, **Inactive Episodes**,
  and **Episode Limit**. Threshold and measured-age values must reflect the values
  captured at archive time rather than recalculating from current settings.
- Use `ContentUnavailableView` when the store is empty and explain that future
  automatic archives will appear; never imply that pre-feature history was lost.

---

# CarPlay Now Playing Controls

**AI CONTEXT — playback-speed glyph (2026-07-15):** CarPlay's speed control is
an app-rendered `CPNowPlayingImageButton`, not the system playback-rate button.
This preserves the configured effective speed while paused and avoids the system
button's transient `0x` state. Render the short value (`1x`, `1.5x`, etc.) in a
an automatically measured template-image canvas using 34 pt heavy compressed
system text and the multiplication symbol (`1.5×`). Crop the output to its actual
glyph bounds with only a one-point anti-aliasing margin. CarPlay scales the entire
image into the standard button slot; a fixed transparent canvas makes the label
visibly smaller than the neighbouring list, Shared Listening, and archive symbols.

# Subscriptions Page

`Views/PodcastsView.swift` — the app's home page. Ranked list of real
subscriptions. Active subscriptions can be drag-reordered; Inactive
subscriptions remain visible and fixed below the active list.

## Subscriptions Page — Action Row

The action row sits below the nav title. Left: Reorder toggle capsule
(`glassCapsule(highlighted:)` — neutral when idle, purple-tinted when Reorder
active). Right: Refresh All button when not in reorder mode.

**Reorder interaction contract (`List-ReorderPriorityStack`):**

- Entering Reorder creates a stable local draft of active, real subscription
  UUIDs. SwiftUI moves mutate that draft; they do not repeatedly persist the
  shared store.
- Active rows show drag grips. Inactive rows remain below them without grips.
  Browse-only preview rows are never rendered and never enter the move-index
  calculation.
- Multiple drags may be performed in one session. **Done**, navigation away, or
  the app leaving the active scene validates and commits the final UUID order as
  one transaction.
- Status pills and the mini-player remain hidden during Reorder so drag targets
  stay visually stable.
- If membership changed in a way that makes the draft invalid, the app rejects
  the uncertain order and asks the user to retry. A failed local write is retried
  with bounded backoff and surfaced if it cannot be made durable.
- A remote iCloud ordering update received during the drag is deferred until the
  session ends; a deliberate local move wins, while an unchanged session accepts
  the deferred remote order.
- Podcast Settings' numeric Priority editor uses the same active-real row count
  as its maximum; it never exposes a rank position occupied by an Inactive or
  hidden browse row.

**Refresh All button:**
- Frame: `30×30 pt` `Circle`
- Icon: `arrow.clockwise`, `font(.system(size: 13, weight: .semibold))`
- Foreground: `.purple`
- Surface: `glassEffect(in: Circle())` (iOS 26) / `.ultraThinMaterial` fallback

---

# Discover Page

`Views/DiscoverView.swift` — pushed from the Subscriptions `+` button. Browsable charts and categories from Apple's Marketing Tools API.

## Discover Page — Layout

A single `ScrollView` with a lazy `VStack(alignment: .leading, spacing: 60)` separating sections. The 60pt spacing gives the image-heavy category rails and hero cards a clearer visual break.

**Four hero carousel sections** interspersed with category rails. The purple
category chips above the feed are navigation controls: each pushes a dedicated
`Top 50 - <Category>` child page for the selected storefront. Each category row
also has a linked heading composed of its purple SF Symbol, bold category name,
and trailing chevron. The Top-15 rails remain on Discover as quick previews.

| Position | Content | Data Source |
|---|---|---|
| Top of page | **Top Episodes hero** — Top 8 episodes | Apple Marketing Tools episode chart |
| After rail 3 | **Top Podcasts hero** — Top 8 podcasts | Apple Marketing Tools podcast chart |
| After rail 6 | **Spotlight A** — editorial spotlight | Apple Marketing Tools |
| End of feed | **Spotlight B** — editorial spotlight | Apple Marketing Tools |

Hero carousels use `TabView(.page)` with the default page dots hidden. Section spacing in `feedSections` is position-based (rail count thresholds), not genre-ID based.

**Progressive loading contract:** `DiscoverViewModel.phase` enters `.loaded` as
soon as a country load starts so the Search shortcut and page chrome never wait
behind the slowest chart endpoint. A task group publishes Top Episodes, overall
Top Podcasts, each category rail, and both country spotlights independently.
Rails are re-sorted into `ChartGenre.rails` order after every arrival, preventing
network completion order from rearranging the designed page. Only an all-section
failure replaces the page with Charts Unavailable.

## Discover Page — Episode Hero Carousel

**Top Episodes Today** — `TabView(.page)` of up to 8 `heroEpisodeCard` cards (284 pt height). Data from `DiscoverViewModel.topEpisodes: [ChartEpisode]`.

**`heroEpisodeCard` layout:**
- **Ghost rank numeral** — oversized semi-transparent rank number (Instrument Serif, `size 140, weight .bold`, `white.opacity(0.06)`) stretched behind the card
- **Artwork** — 148×148 pt, `cornerRadius 16`
- **HStack(alignment: .bottom)**: artwork column (with deep purple→indigo gradient overlay on left half) + text column
- **Text column** (bottom-aligned): rank badge (`glassCapsule(highlighted: true)`) · title (`size 15, weight .bold`, `lineLimit(3)`) · show name (`.caption .secondary`) · relative release time (`relativeReleasedLabel`, `.caption2 .tertiary`)
- **Background** — `white.opacity(0.05)` rounded-rect card, `cornerRadius 20`

**`ChartEpisode` model** (`Feeds/PodcastCharts.swift`):

```swift
struct ChartEpisode: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let rank: Int
    let title: String
    let showName: String
    let artworkURL: URL?
    var releaseDateString: String?   // var — enriched post-fetch
    let collectionId: String?
    var releaseDate: Date? { /* ISO8601 parse of releaseDateString */ }
}
```

**API:** `https://rss.marketingtools.apple.com/api/v2/{country}/podcasts/top/{limit}/podcast-episodes.json`
- Limit: 8 episodes
- Cache TTL: 2 hours (separate from 12-hour podcast cache)
- Release dates not in chart response — enriched via per-podcast iTunes Lookup (`lookup?id={collectionId}&entity=podcastEpisode&limit=10`) run concurrently with `withTaskGroup`
- `collectionId` parsed from Apple Podcasts URL path using `/id(\d+)` regex

## Discover Page — Glass Elements

| Element | Modifier |
|---|---|
| Search shortcut chips | `.glassCapsule()` (neutral) |
| Category chips | `.glassCapsule(highlighted: true)` (purple-tinted) |
| Episode hero rank badge | `.glassCapsule(highlighted: true)` (purple-tinted) |
| Rail tile rank badge | `.glassCapsule()` (neutral) |

## Discover — Category Top 50 Pages

`TopPodcastsView` serves both the overall Top Podcasts chart and category charts.
Category pages are reached from both Discover chips and rail headings and use the
title `Top 50 - <Category>`, followed by
`Apple Podcasts · <Category> · <Country>`.
They deliberately mirror the established Top Podcasts editorial rhythm: full-width
feature cards at ranks 1/8/15/22/29/36/43, compact 84pt-artwork rows elsewhere,
20pt horizontal insets, black background, brand back control, pull-to-refresh,
and the docked mini-player. Selecting an entry resolves its RSS feed and follows
the standard subscribed-or-preview Podcast Detail route.

When the matching country/category Top-15 rail already exists, `TopPodcastsView`
uses those same ranked models as its immediate list and shows a small
“Loading the full Top 50…” footer. The canonical 50-entry result replaces that
preview when ready; preview data is storefront-keyed so a country change cannot
flash the previous country's chart.

The same `ChartCountryPicker` toolbar menu appears on Discover, Top Episodes,
Top Podcasts, and category Top-50 pages. It binds to the shared
`discoverCountryCode` preference, so a selection reloads the visible child chart
and remains selected after navigating back.

## Apple TV Patterns (tvOS Phase 2)

Read-only browse UI, lean-back and artwork-forward (Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md §7). Standard tvOS focus effects only — no custom scale hacks — via `.buttonStyle(.card)`. Files: `TV/Views/*.swift`.

| Pattern | Where | Shape |
|---|---|---|
| `TVShelf-Standard` | `TVHomeView.shelf(title:episodes:)` | Section header + horizontal `LazyHStack` inside `ScrollView(.horizontal)`, wrapped in `.focusSection()` per shelf so the focus engine treats it as one unit |
| `TVCard-Episode` | `TVEpisodeCard` | 280×280 artwork + title (2 lines) + podcast name, `.buttonStyle(.card)` |
| `TVCard-Hero` | `TVHomeView.continueListeningSection` | Wide artwork + title/podcast/"Resume" label, the `Continue Listening` shelf's single large card |
| `TVCard-Podcast` | `TVSubscriptionCard` | Square artwork + title, used in the Library grid (`LazyVGrid(.adaptive(minimum: 260))`) |
| `TVCard-QueueRow` | `TVQueueRow` | Full-width row: artwork + title/podcast/duration — the tvOS analog of "List Row — Up Next Episode Row" |
| `TVRow-Episode` | `TVEpisodeRow` | Title + relative date + a plain text status pill (Played/Archived/In Progress) — no swipe actions (tvOS has none); a focus-driven context menu is a later-phase option if needed |

**Navigation shell:** `TabView` + `.tabViewStyle(.sidebarAdaptable)`, tvOS 18 `Tab(_:systemImage:value:)` builder (`TVMainTabView`) — this is why `AutohopTV`'s deployment target is 18.0, not the Phase 1 scaffold's 17.0 (see project.yml's inline note). Library pushes by subscription UUID (`TVRouter.libraryPath`), not the `Subscription` value, so a pushed detail page always resolves the live model instead of a stale snapshot.

**Known simplification:** `Continue Listening` identifies an in-progress episode via the synced `Episode.playedState == .playing` field, not a real resume-position bar. Decomposition Stage 2 moved `ListeningHistoryStore` into shared-core Persistence, where it remains module-internal; the TV UI has not been wired to a public history reader, so physical target membership alone does not change this screen's current behavior.
| Podcast hero cards | `TabView(.page)` carousel, same card style as before |
