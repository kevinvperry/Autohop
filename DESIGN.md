# Autohop Design System

> **Page names & navigation structure** → see [`PAGES.md`](PAGES.md)

The **Priority**, **Queue**, **Downloads**, **Individual Subscription**, and **Individual Episode** pages are the canonical design references for Autohop. All other pages must match the patterns defined here. Each pattern has a **label** so it can be referenced directly in future instructions (e.g. "apply `EpisodeStatusPill` to the History page").

---

## Quick Reference

| Label | What it controls |
|---|---|
| `ColorScheme-Dark` | Every page forces dark mode — no white or light screens |
| `Accent-Purple` | Purple is the highlight colour for buttons, icons, active states, and progress |
| `NavTitle-Inline` | Page title in the centre of the top bar, not as a large heading |
| `NavBack-Standard` | Pushed pages: brand back chevron top-left, nothing else in that corner |
| `SheetClose-Standard` | Informational sheets: ✕ close button top-right, no Done/Cancel |
| `MiniPlayer-Bar` | Now-playing bar docked at the bottom of every pushed page; tap to return to Player |
| `List-Plain` | Lists use `.plain` style; row backgrounds do the visual separating |
| `Section-Heading` | Bold `title3` section label above each card group |
| `Section-CardList` | A `List` or `VStack` wrapped in a `white.opacity(0.08)` rounded-rect card |
| `Section-CardRows` | Inside a card: `VStack(spacing: 0)` rows separated by `Divider` with `white.opacity(0.08)` tint |
| `ListRow-Standard` | Queue episode row: position · artwork · text stack · spacer · trailing metadata |
| `ListRow-SubscriptionRow` | Priority page row: rank number · artwork · subscription+episode text stack · status pill |
| `ListRow-EpisodeRow` | Individual Subscription episode row: artwork · title · description · metadata + pill · optional progress bar |
| `ListRow-ActiveBackground` | Currently playing row gets `Color.purple.opacity(0.08)` background |
| `ListRow-IdleBackground` | Non-playing rows in a card list use `Color.white.opacity(0.08)` |
| `PositionIndicator-Playing` | Queue number replaced by a small purple `play.fill` icon when the episode is playing |
| `Artwork-Placeholder` | Purple-to-black gradient + waveform icon when no artwork URL is available |
| `Text-PodcastTitle` | Show name: `.caption`, `.secondary`, above the episode title |
| `Text-SubscriptionTitle` | Priority page show name: `.headline.weight(.bold)`, `.primary` — it is the primary title |
| `Text-EpisodeTitle` | Episode title: `.subheadline.bold()`, `.primary`, `lineLimit(2)` |
| `Text-EpisodeTitleSecondary` | Priority page episode title: `.subheadline` (not bold), `.secondary`, `lineLimit(2)` |
| `Text-MetadataRow` | Date + duration/remaining on one line, separated by `•`, caption, secondary |
| `Text-MetadataAdaptive` | Duration shows "Xm left remaining" when partially played, full duration otherwise |
| `Text-Duration` | Total duration: `.caption`, `.secondary`, `.monospacedDigit()` |
| `EpisodeStatusPill` | Colour-coded capsule pill showing episode state — 7 states, each a unique colour |
| `Badge-VideoBadge` | Small clear glass TV-icon pill — used in episode list rows via `.overlay(alignment: .topTrailing)` |
| `Badge-VideoBadgeLarge` | Large clear glass "Video" text pill — used in detail page headers alongside `Badge-ExplicitPill` |
| `Badge-ExplicitPill` | Large clear glass "Explicit" text pill — used in detail page headers alongside `Badge-VideoBadgeLarge` |
| `Badge-ExplicitPillSmall` | Small clear glass "E in square" icon pill (iTunes-style) — used in episode list rows via `.overlay(alignment: .topTrailing)` |
| `Badge-RankPill` | Liquid glass capsule pill centred below artwork on Priority page, stacked vertically below VideoBadge and ExplicitPill |
| `Button-DownloadInline` | Bordered small "Download" button inline in the metadata row for undownloaded episodes |
| `Badge-Pin` | `pin.fill` icon in trailing stack: blue = Play Next, orange = Play Last |
| `SwipeActions-EpisodeRow` | Four swipe actions on episode rows: Play / Play Next (leading), Archive or Unarchive / Play Last (trailing) |
| `SwipeColor-Semantics` | green=play, blue=promote, purple=primary action, orange=demote, red=destructive |
| `Header-SubscriptionPage` | Centred channel header: 120pt artwork · title · Video+Explicit pills · description · bold author + bold categories |
| `Toolbar-SubscriptionPage` | Individual Subscription toolbar: Return to Player leading, Refresh Feed + Settings trailing |
| `Toolbar-NavigationPage` | Priority page toolbar: 3 leading buttons + 2 trailing icon buttons |
| `Toolbar-SheetStandard` | Queue sheet toolbar: shortcut left · bordered action centre · Done right |
| `Button-ReturnToPlayer` | `play.circle.fill` — always first leading button, returns to player from anywhere |
| `Button-MenuHamburger` | `line.3.horizontal` — opens `MenuSheetView` |
| `Button-ReorderToggle` | Plain text "Reorder"/"Done" — toggles drag-to-reorder mode |
| `Button-RefreshAll` | `arrow.clockwise` trailing button — shows spinner while loading, hidden when list empty |
| `Button-AddFeed` | `plus` trailing button — opens the Find Podcasts search sheet |
| `Button-ToolbarAction` | Bordered, regular size, icon-only, shows `ProgressView` while async work runs |
| `Button-ContextualShortcut` | Downloads button in Queue toolbar — navigates + pulses purple when a download is active |
| `Indicator-PulsingIcon` | `easeInOut` 0.6s repeating scale pulse for active background state |
| `EmptyState-ContentUnavailable` | `ContentUnavailableView` with system image + description for empty lists |
| `ProgressBar-Download` | `ProgressView(value:total:)` tinted `.purple`, animated `.linear(0.3s)` — used on Priority rows, Subscription episode rows, and Downloads page |
| `Row-DownloadActivity` | Downloads page active/completed download row layout |
| `Row-ArchivedEpisode` | Downloads page recently-archived row: artwork · text stack · re-download button |
| `TopBar-Player` | Main Player top bar: Priority list icon · panel tabs · queue count pill |
| `Panel-NowPlaying` | Main Player now-playing panel — artwork · chapter strip · episode copy · scrubber · controls · audio row · Up Next row |
| `Panel-Details` | Main Player details panel — episode title · metadata · description image · `HTMLDescriptionText` · meta cards grid |
| `Panel-Chapters` | Main Player chapters panel — chapter rows with skip toggle + All/None controls |
| `Artwork-Player` | Dynamically sized artwork behind a purple radial glow; cornerRadius adapts for chapters |
| `EpisodeCopy-Player` | Centred episode title (16pt bold) + tappable subscription name (12pt gray) |
| `Scrubber-Player` | Purple `Slider` + elapsed (left) / remaining (right) time labels |
| `Controls-Player` | Skip-back icon · 76pt purple circle play/pause button · skip-forward icon |
| `AudioRow-Player` | Five-button row: Sound Settings · Sleep Timer · AirPlay route picker (centre) · Share · Archive |
| `Button-PlayerAction` | Bordered icon button used in `AudioRow-Player`: purple icon, `purple.opacity(0.12)` background, `cornerRadius 9`, `purple.opacity(0.3)` border |
| `ArchiveConfirmationSheet` | Bottom sheet confirming archive of the currently playing episode — matches dark card style of Sleep Timer and Audio Controls sheets |
| `UpNextRow-Player` | Up Next episode row — `ListRow-Standard` layout with custom drag gesture (not `.swipeActions`) |
| `MetaCard-Details` | Two-column grid of key/value cards on the Details panel |
| `AudioControls-Sheet` | Audio controls bottom sheet: Speed stepper · Trim Silence toggle + picker · Vocal Boost toggle + picker |
| `HTMLDescriptionText` | Full-fidelity HTML episode description: `NSAttributedString` parsed, fonts normalised to SF, links purple, first image extracted |
| `Header-EpisodePage` | Centred episode header: 120pt artwork · title · Video+Explicit pills · feed title · categories |
| `Buttons-EpisodePage` | Four equal-width circle buttons in one row: Play (green) · Play Next (blue) · Play Last (orange) · Archive/Unarchive (purple) |
| `Description-EpisodePage` | HTMLDescriptionText inside a `white.opacity(0.08)` card, with `Section-Heading` label above |
| `MetaGrid-EpisodePage` | Two-column MetaCard-Details grid: Published · Duration · File Size · Classification · File Status · Priority Rank |
| `Toolbar-EpisodePage` | Episode page toolbar: Return to Player leading only, empty nav title |
| `Selector-PeriodPills` | Stats page period selector: capsule pill row, purple selected / `white.opacity(0.08)` unselected |
| `Card-StatsHero` | Stats hero card: big purple time-listened number + three stat columns (time saved teal) |
| `Chart-Heatmap` | GitHub-style listening heatmap (30/90d) or Swift Charts monthly bars (1y/lifetime) |
| `Chart-ListeningClock` | 24-hour rose chart in Canvas — wedge radius scales with listening per hour |
| `ListRow-TopShow` | Stats top-shows row: rank · 44pt artwork · title + relative purple bar · duration |
| `Card-ShowStatsExpanded` | Stats inline per-show detail card: tap a Top Shows / Drifting row to toggle; 2-column stat-tile grid in a nested `white.opacity(0.05)` card |

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

**Label: `NavBack-Standard`** — every pushed page's only top-left control:

```swift
ToolbarItem(placement: .topBarLeading) {
    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
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

A `VStack(spacing: 0)` of rows inside a `white.opacity(0.08)` rounded-rect card. Used on the Downloads page. Rows are separated by a `Divider` tinted `white.opacity(0.08)`, indented past the artwork.

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
.background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
```

---

## Individual Subscription Page — Channel Header

**Label: `Header-SubscriptionPage`**

The centred header shown at the top of every Individual Subscription episodes page, above the section heading and episode list card. All content is centre-aligned.

Structure (top to bottom):
1. **Artwork** — 120×120 pt, `cornerRadius 20`, subtle stroke overlay (`white.opacity(0.08), lineWidth: 0.5`)
2. **Channel title** — `.title3.weight(.bold)`, `.primary`, `multilineTextAlignment(.center)`
3. **Video + Explicit pills** — `HStack(spacing: 6)` of `VideoBadgeLarge` and/or `ExplicitPill`, shown only when applicable. Placed **between the title and the description**. `VideoBadgeLarge` triggered by `sub.latestEpisode?.mediaKind == .video`; `ExplicitPill` triggered by `sub.isExplicit == true` (channel-level RSS `<itunes:explicit>` tag).
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
                if showVideo   { VideoBadgeLarge() }
                if showExplicit { ExplicitPill() }
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
- **Status/Video/Explicit pills** — `VideoBadge` and/or `ExplicitPillSmall` float in the **top-right corner** of the row via `.overlay(alignment: .topTrailing)` on the outer `VStack`. This avoids compressing the text column.
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
            if episode.mediaKind == .video { VideoBadge() }
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

## List Row — Queue Episode Row

**Label: `ListRow-Standard`**

The standard episode row used in the Queue. Five horizontal zones left to right:

1. **Position indicator** — 20 pt fixed width: queue number or `PositionIndicator-Playing`
2. **Artwork** — 44×44 pt, `cornerRadius 9`
3. **Text stack** — leading-aligned, expands: podcast title (caption/secondary) · episode title (subheadline.bold/primary) · metadata row
4. **Spacer**
5. **Trailing metadata** — pin badge (if pinned) + duration

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

## List Row — Priority Page Subscription Row

**Label: `ListRow-SubscriptionRow`**

The row layout used on the Priority page. Differs from `ListRow-Standard` in three ways: (1) the podcast name is the **primary** bold title, (2) the episode title is **secondary** and not bold, (3) there is no trailing metadata stack — the status pill sits inline in the metadata row at the bottom.

The left column has the artwork only. `VideoBadge` and `ExplicitPillSmall` float in the top-right corner via `.overlay(alignment: .topTrailing)` on the outer row `VStack`. `rankPill` sits in a separate bottom band row below the top HStack. Episode title is plain text (no inline pill).

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
            .font(.headline.weight(.bold))
            .foregroundStyle(.primary)
            .lineLimit(1)

        // Episode title is SECONDARY (not bold) — plain text, no inline pill
        Text(episode.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)

        // Metadata row: date · duration/remaining · Spacer · status pill
        HStack(spacing: 4) {
            Text(formattedDate)
            Text("•")
            Text(durationOrRemaining).monospacedDigit()
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
            if episode.mediaKind == .video { VideoBadge() }
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

A colour-coded capsule pill shown on the Priority page, Individual Subscription page, and any other page listing episodes. Communicates episode state at a glance. Seven states, each a unique colour. White foreground on all.

| State | Label | Colour | Trigger |
|---|---|---|---|
| `unplayed` | Unplayed | Gray | Unplayed, no saved position, episode is **not** downloaded |
| `queued` | Queued | Teal | Unplayed, no saved position, episode **is** downloaded (`downloadState == .downloaded`) |
| `partiallyPlayed` | Paused | Yellow | `playedState == .playing` but NOT the current player episode; OR `playedState == .unplayed` with saved position > 0 |
| `nowPlaying` | Playing | Green | `playedState == .playing` AND `currentPlayerEpisode?.id == episode.id` |
| `played` | Played | Blue | `playedState == .played` |
| `archived` | Archived | Purple | `playedState == .archived` |
| `inactive` | Inactive | Orange | `subscription.excludeFromAutoFeedRefresh == true` (Priority page only) |

Priority order for the pill decision (check top to bottom):
1. `excludeFromAutoFeedRefresh` → **Inactive** (Priority page only)
2. `playedState == .archived` → **Archived**
3. `playedState == .played` → **Played**
4. `statusKind(for: episode)` → **Unplayed**, **Queued**, **Paused**, or **Playing**

**Glass pill pattern (applies to all pills):**
- **iOS 26+:** colour-tinted liquid glass — a semi-transparent colour layer underneath `.glassEffect(in: Capsule())` lets the tint show through the frosted material
- **iOS 17–25 fallback:** solid `color.opacity(0.82)` capsule, unchanged

```swift
private enum EpisodeStatusKind {
    case unplayed, queued, partiallyPlayed, nowPlaying, played, archived, inactive

    var label: String {
        switch self {
        case .unplayed:        return "Unplayed"
        case .queued:          return "Queued"
        case .partiallyPlayed: return "Paused"
        case .nowPlaying:      return "Playing"
        case .played:          return "Played"
        case .archived:        return "Archived"
        case .inactive:        return "Inactive"
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
        }
    }
}

private struct EpisodeStatusPill: View {
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

The priority rank number is displayed as a liquid glass capsule pill **centred below the artwork column** on the Priority page, rendered in the bottom band beneath the `VStack` containing the artwork and `Badge-VideoBadge` / `Badge-ExplicitPill`. All three pills stack vertically: Video → Explicit → Rank.

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
        if episode.mediaKind == .video { VideoBadge() }
        if episode.isExplicit == true  { ExplicitPill() }
    }
    .frame(minWidth: 44)
}

// Rank pill sits in the bottom band row below the artwork VStack:
rankPill(sub.priorityRank)
    .frame(minWidth: 44, alignment: .center)
```

---

## Video Badge (Small)

**Label: `Badge-VideoBadge`**

The small variant of the video indicator. A TV-icon pill shown in the **top-right corner** of episode list rows when `episode.mediaKind == .video`. Placed via `.overlay(alignment: .topTrailing)` on the outer row container — never below artwork.

- **iOS 26+:** `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background
- **Icon:** `tv.fill`, `.caption.bold()`, white foreground
- **Padding:** `.horizontal: 8, .vertical: 5`
- **Placement:** `.overlay(alignment: .topTrailing)` on the row's outer view, in an `HStack(spacing: 3)` alongside `ExplicitPillSmall` when both apply.

```swift
.overlay(alignment: .topTrailing) {
    if episode.mediaKind == .video || episode.isExplicit == true {
        HStack(spacing: 3) {
            if episode.mediaKind == .video { VideoBadge() }
            if episode.isExplicit == true  { ExplicitPillSmall() }
        }
    }
}
```

Pages covered (list rows): Priority (PodcastsView), Queue (QueueSheetView), Individual Subscription (SubscriptionSettingsView), Downloads (both active and archived rows), Player Up Next row.

---

## Video Badge Large

**Label: `Badge-VideoBadgeLarge`**

The large variant of the video indicator. A "Video" text pill used in **detail page headers** when `episode.mediaKind == .video` (or `sub.latestEpisode?.mediaKind == .video` for channel headers). Placed in an `HStack(spacing: 6)` below the title alongside `ExplicitPill`.

- **iOS 26+:** `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background
- **Text:** `"Video"`, `.caption.bold()`, white foreground
- **Padding:** `.horizontal: 8, .vertical: 5`

```swift
// Detail header — below title:
HStack(spacing: 6) {
    if showVideo   { VideoBadgeLarge() }
    if showExplicit { ExplicitPill() }
}
```

Pages covered (detail headers): Individual Subscription channel header, Individual Episode detail header.

---

## Explicit Pill (Large)

**Label: `Badge-ExplicitPill`**

The large variant of the explicit indicator. An "Explicit" text pill used in **detail page headers** when `episode.isExplicit == true`. Placed in an `HStack(spacing: 6)` below the title alongside `VideoBadgeLarge`.

- **iOS 26+:** `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background
- **Text:** `"Explicit"`, `.caption.bold()`, white foreground
- **Padding:** `.horizontal: 8, .vertical: 5`

Pages covered (detail headers): Individual Subscription channel header, Individual Episode detail header.

---

## Explicit Pill Small

**Label: `Badge-ExplicitPillSmall`**

The small variant of the explicit indicator. An iTunes-style "E in a square" icon pill shown in the **top-right corner** of episode list rows when `episode.isExplicit == true`. Placed via `.overlay(alignment: .topTrailing)` alongside `VideoBadge`.

- **iOS 26+:** `.glassEffect(in: Capsule())`
- **iOS 17–25 fallback:** `.ultraThinMaterial` background
- **Icon:** 11×11 pt white `RoundedRectangle(cornerRadius: 2)` with a black bold "E" (`size: 8, weight: .bold`) overlaid
- **Padding:** `.horizontal: 8, .vertical: 5`
- **Placement:** same `.overlay(alignment: .topTrailing)` pattern as `Badge-VideoBadge` — see that section for the full snippet.

Pages covered (list rows): Priority (PodcastsView), Queue (QueueSheetView), Individual Subscription (SubscriptionSettingsView), Downloads (both active and archived rows), Player Up Next row.

---

## Inline Download Button

**Label: `Button-DownloadInline`**

When an episode has never been downloaded (and is not archived/played), show a bordered "Download" button inline in the metadata row — in the same trailing position as `EpisodeStatusPill`.

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
| Downloads page | Inside the activity row, below the text stack |

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

Four swipe actions used on episode rows. Full-swipe is disabled on both edges. Applied on the **Queue** page and **Individual Subscription** page.

### Leading (swipe right) — both pages
| Action | Icon | Colour | Behaviour |
|---|---|---|---|
| **Play** | `play.fill` | `.green` | Starts playback immediately. On Subscription page: downloads first if not on device. Queue page also dismisses the sheet. |
| **Play Next** | `text.line.first.and.arrowtriangle.forward` | `.blue` | Pins to top of queue. On Subscription page: downloads first if not on device. |

### Trailing (swipe left) — both pages
| Action | Icon | Colour | Behaviour |
|---|---|---|---|
| **Archive** | `archivebox` | `.purple` | Archives the episode. Queue: also advances to next episode (`archiveEpisodeAndPlayNext`). Subscription: archives only, no queue advance. |
| **Unarchive** | `arrow.uturn.backward.circle` | `.purple` | Replaces Archive on Subscription page when `playedState == .archived` or `.played`. Resets to unplayed. Not shown on Queue page. |
| **Play Last** | `text.line.last.and.arrowtriangle.forward` | `.orange` | Pins to bottom of queue. On Subscription page: downloads first if not on device. |

### Conditional visibility — Subscription page only
- The currently playing episode shows **no swipe actions** on either edge.
- Archive is replaced by Unarchive when the episode is already `.archived` or `.played`.

```swift
// Queue page pattern
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

Media kind pill (Video / Audio) — inline in the podcast title row, only shown when status ≠ completed:
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
    "Queue is Empty",
    systemImage: "tray",
    description: Text("Download an episode to start listening.")
)
```

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

**Navigation destinations:**
- `navigationDestination(for: PodcastSearchResult.self)` — checks for an existing active subscription at the tapped feed URL; if found, pushes `SubscriptionEpisodesView`; otherwise pushes `PodcastPreviewView`.
- `navigationDestination(for: UUID.self)` — used by Recently Viewed rows. Routes to `PodcastPreviewView` (browse/inactive) or `SubscriptionEpisodesView` (active) by subscription ID.

**Recently Viewed row layout:**
- **Artwork** — 44×44, `cornerRadius 9`
- **Title** — `.headline.weight(.semibold)`, `.primary`, `lineLimit(1)`
- **Author** — `.subheadline`, `.secondary`, `lineLimit(1)`
- **Browse date** — `.caption`, `.tertiary` — "Viewed today / yesterday / [abbreviated date]"

**Cancel button:** `.topBarLeading` toolbar item — dismisses the sheet.

---

## Podcast Preview Page

**Label: `View-PodcastPreview`**

Pushed onto the `PodcastSearchView` navigation stack when a search result or Recently Viewed row is tapped. A `VStack` layout (not `ScrollView`) — the episode list is a `List` that fills remaining vertical space.

A browse subscription is created automatically in the background when the feed finishes loading (`.task`). This means the episode list is always fully interactive from first load. See FEATURES.md §2.4 for the full browse subscription lifecycle.

**Toolbar:** Back button (`chevron.left.circle.fill`) + `ReturnToPlayerButton` — leading placement. Matches all other pushed pages.

**Header** — matches `Header-SubscriptionPage` with the addition of a Subscribe button:
1. **Artwork** — 120×120 pt, `cornerRadius 20`, 0.5pt white/8% stroke overlay, `Artwork-Placeholder` fallback
2. **Title** — `.title3.weight(.bold)`, `.primary`, `multilineTextAlignment(.center)`
3. **Explicit / Video pills** — shown when applicable, centred below title
4. **Description** — `.footnote`, `.secondary`, `multilineTextAlignment(.center)`, `lineLimit(2)`, HTML-stripped
5. **Author · Categories** — `.caption`, `.secondary`, `fontWeight(.bold)`, separated by `·`
6. **Subscribe button** — full-width, height `50 pt`, `.borderedProminent`, `.purple` tint. Label always `Label("Subscribe", systemImage: "plus.circle.fill")`, `.headline`. Shows `ProgressView` while active. See FEATURES.md §2.3 for action behaviour.

**Episodes section heading** — `Text("Episodes")` `.title3.weight(.bold)` + `Image(systemName: "waveform")` `.title3.weight(.semibold)` `.secondary` — matches `SubscriptionEpisodesView`.

**Episode list** — a `List` in a `RoundedRectangle(cornerRadius: 16)` card with `Color.white.opacity(0.08)` background. Identical layout, swipe actions, and status pills to `SubscriptionEpisodesView`:
- `NavigationLink` to `EpisodeDetailView` for each row
- Leading swipe: Play (green), Play Next (blue)
- Trailing swipe: Archive/Unarchive (purple), Play Last (orange)
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
| Leading | `list.number` icon (18pt semibold, white) | `NavigationLink` to Priority page |
| Centre | Panel tab strip — `Now Playing` / `Details` / `Chapters` | Switches `TabView` panel with `easeInOut(0.22)` animation |
| Trailing | Queue count pill | Opens `QueueSheetView` as a sheet |

**Panel tab strip** — each tab is a plain `Button`. Selected tab: white foreground + `Color(white: 0.15)` rounded-rect background. Unselected: `Color(white: 0.4)` foreground, clear background. `cornerRadius 14`, `font(.system(size: 13, weight: .semibold))`.

**Queue count pill** — shows `appState.downloadedQueue.count`. Fixed height 30 pt, `Color(white: 0.12)` background, `cornerRadius 15`, subtle `Color(white: 0.18)` stroke. Font: `size: 12, weight: .bold`, colour `Color(white: 0.55)`.

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
- **Subscription name** — `font(.system(size: 12))`, `Color(white: 0.55)`, `multilineTextAlignment(.center)`, `lineLimit(1)`. Tappable: `NavigationLink` to `SubscriptionEpisodesView` for that subscription.

Empty state (no episode): title becomes `"No Episode"` at `Color(white: 0.3)`, subtitle becomes context-sensitive hint.

```swift
VStack(alignment: .center, spacing: 3) {
    Text(ep.title)
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: .infinity)

    NavigationLink { SubscriptionEpisodesView(subscriptionID: sub.id) } label: {
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

Purple `Slider` above a two-label time row. The slider value tracks `appState.currentPlayerTime` while not seeking; during seek the value is decoupled and committed on `onEditingChanged(false)`.

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

## Main Player — Controls

**Label: `Controls-Player`**

Three-button `HStack`. Skip buttons flank the central play/pause button.

- **Skip back / Skip forward** — `SkipIntervalIcon` view: `gobackward` / `goforward` SF Symbol at `size 36, weight .regular` with the skip seconds number overlaid at `size 15 (or 12 for ≥100s), design .rounded`, offset `y: 3`. Foreground `Color(white: 0.9)`. Frame `64×64`.
- **Play / Pause** — `pause.fill` / `play.fill` at `font size 28`, white, `76×76` purple circle, `shadow(color: purple.opacity(0.35), radius: 14)`. Disabled when queue is empty.
- Skip seconds values come from `appState.settingsStore.appSettings.skipBackSeconds` / `skipForwardSeconds`.
- Skip forward overshot: if `currentTime + skip ≥ duration`, advances to the next episode instead of clamping.

```swift
HStack(alignment: .center) {
    Button { /* seek back */ } label: {
        SkipIntervalIcon(direction: .backward, seconds: skipBackSeconds)
    }
    .frame(maxWidth: .infinity)

    Button { Task { await appState.togglePlayPause() } } label: {
        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 28))
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(Color.purple)
            .clipShape(Circle())
            .shadow(color: Color.purple.opacity(0.35), radius: 14)
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

**Sleep Timer button** (`moon.zzz` / `moon.zzz.fill`) — `Button-PlayerAction` style. When the sleep timer is **inactive**, icon is `Color.purple.opacity(0.85)` (matches all other player action buttons). When **active**, icon turns `.white` — same purple background and border unchanged. A small badge capsule (purple background, white text) overlays the top-trailing corner showing either a countdown (`"m:ss"` / `"Xh"`) for duration mode or `"Nep"` for episode mode. Opens `SleepTimerSheetView`.

**AirPlay button** — a visible `HStack` of `airplayaudio` icon + route name label layered under an invisible `AVRoutePickerView` (`opacity(0.02)`) that captures the tap. Shows the current audio output name from `AVAudioSession.currentRoute.outputs.first`.

**Share button** (`square.and.arrow.up`) — `Button-PlayerAction` style. Opens `EpisodeShareSheet` (`Views/EpisodeShareSheet.swift`): a bottom sheet that previews the rendered episode share card (`EpisodeShareCardView` — artwork, episode title, podcast name, Autohop branding) and exports it through the system share sheet together with the episode's audio URL. Disabled when no episode is loaded.

**Archive button** (`archivebox`) — `Button-PlayerAction` style. Opens `ArchiveConfirmationSheet` (a bottom sheet). On confirm, calls `archiveEpisodeAndPlayNext` to archive the currently playing episode and advance to the next. Icon matches `SwipeActions-EpisodeRow` (`archivebox`).

---

## Main Player — Archive Confirmation Sheet

**Label: `ArchiveConfirmationSheet`**

A bottom sheet presented when the Archive button is tapped in `AudioRow-Player`. Matches the dark card style of `SleepTimerSheetView` and `AudioControlsSheetView`.

- **Background** — `Color(red: 0.10, green: 0.10, blue: 0.13)`, `presentationCornerRadius(20)`, drag indicator hidden
- **Height** — fixed `320 pt` (`presentationDetents([.height(320)])`)
- **Icon** — `archivebox` at `size 28, weight .semibold`, `Color.purple.opacity(0.85)`
- **Title** — `"Archive Episode?"`, `size 17, weight .bold`, white
- **Message** — `"This will archive the currently playing episode and delete its downloaded file."`, `size 14, Color(white: 0.55)`, centre-aligned
- **Archive button** — full-width, `Color.purple.opacity(0.85)` background, `cornerRadius 14`, white bold label. Dismisses sheet then calls `onConfirm`.
- **Cancel button** — full-width, `Color(white: 0.12)` background, `cornerRadius 14`, `Color(white: 0.55)` semibold label. Dismisses sheet only.

---

## Player Action Button

**Label: `Button-PlayerAction`**

The shared button style used for all four flanking buttons in `AudioRow-Player`. Extracted as a `playerActionIcon(_:)` helper function.

- **Icon** — SF Symbol at `size 18, weight .bold`, `Color.purple.opacity(0.85)` foreground (white when Sleep Timer is active)
- **Frame** — `44×32 pt`
- **Background** — `Color.purple.opacity(0.12)`, `cornerRadius 9`
- **Border** — `Color.purple.opacity(0.3)`, `lineWidth 0.5`

```swift
private func playerActionIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(Color.purple.opacity(0.85))
        .frame(width: 44, height: 32)
        .background(Color.purple.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.purple.opacity(0.3), lineWidth: 0.5))
}
```

---

## Main Player — Up Next Row

**Label: `UpNextRow-Player`**

Shows the second episode in the queue (the one after the currently playing episode) as a preview card at the bottom of the Now Playing panel. Uses the `ListRow-Standard` layout inside a rounded card.

**Important:** `.swipeActions` is incompatible with content inside `TabView(.page)` (gesture conflicts). The Up Next row uses a **custom `DragGesture`** instead, with `highPriorityGesture` to beat the `TabView` pan recogniser.

Card appearance: `Color(white: 0.09)` background, `cornerRadius 14`, `white.opacity(0.075)` stroke. Padding `14 pt` horizontal + `10 pt` vertical.

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
- **Container** — `Color(white: 0.09)` background, `cornerRadius 12`, `white.opacity(0.075)` stroke. `padding(.horizontal, 11)`, `padding(.vertical, 8)`.

---

## Main Player — Chapters Panel

**Label: `Panel-Chapters`**

The full chapters panel (third tab). Shows all chapters as a scrollable list with a header row showing chapter count and skip count, plus All/None bulk-toggle buttons.

**Chapter row structure:**
- **Toggle circle** — 24×24, `Color.purple` fill + `checkmark` when included; clear fill + `Color(white: 0.33)` stroke when skipped
- **Chapter number** — `size 12, weight .bold`, `Color.purple` when current, `Color(white: 0.33)` otherwise, 18 pt trailing-aligned
- **Title + start time** — title `size 13, weight .bold`, white (skipped: `Color(white: 0.3)` + strikethrough); start time `size 11, Color(white: 0.22)`
- **Current indicator** — 6pt purple filled circle when chapter is playing
- **Duration** — trailing, `size 11, Color(white: 0.22)`, `.monospacedDigit()`
- **Active row background** — `Color.purple.opacity(0.08)`, same as `ListRow-ActiveBackground`
- **Skipped row opacity** — `0.45`
- **Divider** — `white.opacity(0.06)` at the bottom of each row

Tapping a row toggles the chapter's skipped state (except the currently playing chapter, which cannot be skipped).

---

## Main Player — Details Panel

**Label: `Panel-Details`**

A `ScrollView` showing full episode metadata. Sections top to bottom:

1. **Episode title** — `size 20, weight .bold`, white, `padding(.horizontal, 20)`
2. **Metadata row** — date (`calendar` icon) + duration (`hourglass` icon), `size 12, Color(white: 0.55)`
3. **Description image** — either the first `<img>` extracted from the description HTML, or the channel/episode artwork as a fallback. `cornerRadius 14`, full width. Shown before the text.
4. **Episode subtitle** — `size 13, weight .bold, Color(white: 0.55)` (from RSS `<itunes:subtitle>`)
5. **Episode author** — `size 12, Color(white: 0.33)` (from RSS `<itunes:author>`)
6. **`HTMLDescriptionText`** — full HTML description. `fontSize: 14`, `color: Color(white: 0.78)`, `linkColor: .purple`. `showsFirstImage: false` (image already shown above).
7. **Meta cards grid** (`MetaCard-Details`) — two-column `LazyVGrid`

---

## Main Player — HTML Description

**Label: `HTMLDescriptionText`**

A SwiftUI `View` that renders a raw HTML string from an episode's RSS description field as a styled `Text`. Safe to use in `ScrollView` contexts (not in a `List` or during view init).

**How it works:**
- Strips `<img>` tags and normalises `<br>` / `<p>` for text display
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
    showsFirstImage: false   // true shows the first <img> above the text
)
```

**`firstImageURL(from:)`** — static method used by the Details panel to extract the first `<img src=...>` from the HTML so it can be placed above the text block rather than inline.

> **Do not use `HTMLDescriptionText` inside `List` rows or `View.body` synchronous init paths** — it calls `NSAttributedString(.html)` which initialises WebKit and will crash if called during SwiftUI's synchronous layout pass. Use `stripHTML(_:)` from `SubscriptionSettingsView` for plain-text previews in list rows.

---

## Main Player — Meta Cards Grid

**Label: `MetaCard-Details`**

A two-column `LazyVGrid` of key/value cards shown at the bottom of the Details panel. Each card: uppercase tracking label + bold value.

- **Grid** — `[GridItem(.flexible()), GridItem(.flexible())]`, spacing `8`
- **Card** — `Color(white: 0.09)` background, `cornerRadius 10`, `white.opacity(0.075)` stroke, padding `12 × 10`
- **Key** — `size 10, weight .bold`, `.textCase(.uppercase)`, `.tracking(0.5)`, `Color(white: 0.33)`
- **Value** — `size 13, weight .bold`, white, `lineLimit(2)`

Fields shown (when available): Published · Duration · File size · Classification (Explicit / Clean) · File Status (Downloaded / Available / Archived) · Priority rank · Chapter count.

```swift
private func metaCard(_ key: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
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
    .background(Color(white: 0.09))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
}
```

---

## Main Player — Audio Controls Sheet

**Label: `AudioControls-Sheet`**

A bottom sheet (`presentationDetents`) for per-subscription audio settings. Sheet height is dynamic — base `300 pt` + `68 pt` for each active picker row (trim silence or vocal boost when enabled).

Sheet background: `Color(red: 0.10, green: 0.10, blue: 0.13)` (slightly blue-tinted dark). Drag indicator hidden; `presentationCornerRadius(20)`.

**Three rows, each separated by a `Divider` indented `60 pt` from the leading edge:**

### Speed Row
Stepper (`−` · value · `+`) on the right. Steps through `PlaybackPreference.speedOptions` array (e.g. `0.5× … 3.0×`). Value display: `size 15, weight .bold, design .rounded`, `.monospacedDigit()`. Stepper background: `Color(white: 0.20)`, `cornerRadius 10`, buttons `44×38 pt`.

### Trim Silence Row
`Toggle` (purple tint) on the right. When on, a segmented `Picker` with Low / Medium / High animates in below (`easeInOut(0.22)`). Picker tint: `.purple`.

### Vocal Boost Row
Same pattern as Trim Silence. Label includes a subtitle `"Voices sound clearer"` in `size 13, Color(white: 0.50)`. Levels: Light / Standard / Strong.

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
3. **Video + Explicit pills** — `HStack(spacing: 6)` of `VideoBadgeLarge` and/or `ExplicitPill`, shown only when applicable. `VideoBadgeLarge` triggered by `ep.mediaKind == .video`; `ExplicitPill` triggered by `ep.isExplicit == true`.
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
                if showVideo    { VideoBadgeLarge() }
                if showExplicit { ExplicitPill() }
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
| **Archive** | `archivebox` | `.purple` | Calls `archiveEpisode(_:)`. Shown when `playedState != .archived && playedState != .played` |
| **Unarchive** | `arrow.uturn.backward.circle` | `.purple` | Calls `unarchiveEpisode(_:)`. Replaces Archive when `playedState == .archived || playedState == .played` |

Archive/Unarchive occupy the same fourth slot — only one is shown at a time.

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

Full HTML episode description rendered via `HTMLDescriptionText`, inside a `white.opacity(0.08)` rounded card — the same card background used for episode lists on the Priority and Individual Subscription pages (`Section-CardList`).

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
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
}
```

Hidden when `ep.description` is nil or empty.

---

## Individual Episode Page — Details Grid

**Label: `MetaGrid-EpisodePage`**

A two-column `LazyVGrid` of `MetaCard-Details` cards at the bottom of the scroll content. Identical card style to the Main Player Details panel.

Fields shown (when available):

| Field | Source | Always shown |
|---|---|---|
| Published | `ep.publishedAt`, `.abbreviated` date, no time | Only when non-nil |
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

`Views/StatsView.swift`, reached via Menu → Stats. Follows the standard dark scheme (`ColorScheme-Dark`), `Accent-Purple`, `NavTitle-Inline`, and `white.opacity(0.08)` cards. All sections respond to the period selector.

## Stats Page — Period Selector

**Label: `Selector-PeriodPills`**

A centred `HStack(spacing: 8)` of capsule buttons (7 Days / 30 Days / 90 Days / 1 Year / All Time). Selected pill: `Color.purple` background, white `.footnote.weight(.semibold)` label. Unselected: `Color.white.opacity(0.08)` background, `.secondary` label. Switching animates with `.easeInOut(duration: 0.15)`.

## Stats Page — Hero Card

**Label: `Card-StatsHero`**

`white.opacity(0.08)` rounded card (`cornerRadius 16`, padding 16). Contents top-to-bottom:
1. Subtitle (`.subheadline`, `.secondary`) — "Time listened" (or "Time listened since [date]" on All Time)
2. Headline number — `size 40, weight .bold`, `.purple`, `contentTransition(.numericText())`
3. `Divider` overlaid `white.opacity(0.08)`
4. Three equal columns (`heroStat`): value `.headline.bold` (teal for time saved, primary otherwise) over `.caption` `.secondary` label

## Stats Page — Heatmap

**Label: `Chart-Heatmap`**

GitHub-style contribution grid (7/30/90-day periods only): columns are weeks, rows are weekdays, leading/trailing nil-padded for weekday alignment. Cell fill: `Color.clear` (pad), `white.opacity(0.06)` (zero), or `Color.purple.opacity(0.25 + 0.75 × √fraction)` scaled against the period's busiest day. Cell size 30 pt (≤7 weeks) or 19 pt. Caption below: "Busiest day: …" (`.caption`, `.secondary`). On 1 Year / All Time the card is replaced by a Swift Charts monthly `BarMark` chart (purple bars, `cornerRadius 3`, y-axis in hours, height 170).

## Stats Page — Listening Clock

**Label: `Chart-ListeningClock`**

24-hour rose chart drawn in a `Canvas` (height 230): midnight at top, noon at bottom; each hour is a wedge whose radius scales with `√(hourSeconds/max)`, filled `purple.opacity(0.9)` with 1° gaps between wedges. Two reference circles stroked `white.opacity(0.08)`. Compass labels 12am/6am/12pm/6pm in `.caption2` `.tertiary`. Caption below: "Peak listening: [range]".

## Stats Page — Top Show Row

**Label: `ListRow-TopShow`**

Card rows (standard `Section-CardRows` divider at `padding(.leading, 70)`): rank number (`.subheadline.semibold.monospacedDigit`, `.secondary`, width 18) · 44 pt artwork (`cornerRadius 9`, `Artwork-Placeholder` fallback) · show title (`.subheadline.semibold`, lineLimit 1) over a 4 pt purple capsule bar sized relative to the #1 show · trailing duration (`.caption.monospacedDigit`, `.secondary`). Up to 8 rows. Tapping a row toggles an inline `Card-ShowStatsExpanded` beneath it.

## Stats Page — Privacy Footer

Centred `.caption` `.tertiary` row: `lock.shield` icon + "Your listening stats never leave this device."

## Completion Bar

**Label: `Chart-CompletionBar`**

Horizontal stacked outcome bar used in the Stats page "Shows You're Drifting From" rows (`CompletionBar` in `Views/StatsView.swift`). 5 pt tall, `Capsule`-clipped `HStack` with 1 pt gaps; segment widths proportional to episode counts, minimum 3 pt so tiny counts stay visible.

- **Teal** — episodes finished
- **Orange** — stopped partway (abandoned)
- **`white.opacity(0.25)`** — archived unplayed

A single shared legend (`6 pt circle dots + .caption2 .tertiary labels`) appears once below the section, never per row.

## Stats Page — Drifting Show Row

Card rows (standard `Section-CardRows` divider at `padding(.leading, 70)`): 44 pt artwork (`Artwork-Placeholder` fallback) · show title (`.subheadline.semibold`, lineLimit 1) · blunt insight line (`.caption` `.secondary`, e.g. "Archived 6 of the last 8 unplayed") · `Chart-CompletionBar` · trailing "finished/total" fraction (`.caption.monospacedDigit`, `.secondary`). Row tap toggles an inline `Card-ShowStatsExpanded` beneath the row (this variant includes a Podcast Settings link to `SubscriptionSettingsView`); long-press context menu offers Hide From This List and Unsubscribe (confirmation dialog).

## Stats Page — Expanded Show Card

**Label: `Card-ShowStatsExpanded`**

Inline per-show detail card (`ShowStatsExpandedCard` in `Views/StatsView.swift`) revealed under a Top Shows or Drifting Show row by tapping it; tap again to collapse (animated `.easeInOut(duration: 0.2)`, transition `.opacity` + `.move(edge: .top)`). Nested card styling: `white.opacity(0.05)` background, `cornerRadius 12`, padding 14, inset `padding(.horizontal, 14)` inside the parent `white.opacity(0.08)` card. Contents: a 2-column `LazyVGrid` of stat tiles — value `.subheadline.bold.monospacedDigit` (teal for finished/time-saved, orange for stopped-partway, primary otherwise) over a `.caption2` `.secondary` label — covering episodes finished, time saved ("(est.)" suffix when apportioned rather than tracked), share of all listening, average completion %, stopped partway, last listened (relative date), and typical wait after release. Drift-row variant appends a purple gear + "Podcast Settings" `NavigationLink`.
