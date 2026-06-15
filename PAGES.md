# Autohop — Page Reference

**Source of truth for every screen in the app.**
Use these labels in design, development, and documentation discussions to avoid ambiguity.
Keep this file updated whenever a new page is added or an existing one is renamed.

> **Sheet** — slides up from the bottom, dismissed by swiping down.
> **Page** — pushed onto the navigation stack, dismissed with the back button.

---

## Page Table

| Label | Code Name | Type | Purpose |
|---|---|---|---|
| **Subscriptions** | `PodcastsView` | Full page | Your subscribed podcasts in priority order — the home page. Centered "Subscriptions" heading; action row below holds Reorder (mode toggle: status pills hide, drag grips show) and refresh-all. Tap a podcast to see its episodes. |
| **Podcast Search** | `PodcastSearchView` | Sheet | Search the podcast directory by name, author, or keyword. Also shows Recently Viewed history. Reached only via the Discover page's search shortcut. |
| **Discover** | `DiscoverView` | Sheet | Browse Apple Podcasts charts — Top-8 hero paging cards plus per-genre rails. Two extra "Top Podcasts · <Country>" spotlight heroes are woven into the rails (one before Health & Fitness, one at the end) for fixed US/UK/AU storefronts that never duplicate the user's selected country. Country picker (defaults to device region) switches storefronts. Search shortcut opens Podcast Search; tapping a chart entry routes to the Podcast Detail page. |
| **Podcast Detail** | `PodcastDetailView` | Page | A podcast's artwork, description, and full episode list — one page serving both the unsubscribed preview and a subscribed show. Header has a single Subscribe⇄Unsubscribe button (Unsubscribe asks for confirmation); the Refresh Feed and Show Settings toolbar items appear only when actively subscribed. Episodes are fully interactive from first load — swipe for Play, Play Next, Archive, and Play Last. |
| **Add RSS Feed** | `AddFeedView` | Page | Manually enter a podcast RSS URL. Fallback for podcasts not found in the search directory. |
| **Podcast Settings** | `SubscriptionSettingsView` | Page | Per-podcast configuration — playback speed, trim silence, auto-archive rules, notifications, and feed exclusion from auto-refresh. |
| **Episode Detail** | `EpisodeDetailView` | Page | Full detail for a single episode — description, chapters, chapter artwork, playback controls, download and share actions. |
| **Player** | `PlayerView` | Page (modal overlay) | Full-screen now-playing screen. Shows artwork, title, scrubber, playback controls, chapter list, plus sleep timer, AirPlay, share, and archive actions. A Sleep Schedule indicator pill (bed icon + minutes to the next prompt) appears in the top bar only while inside the active-hours window and pushes the Sleep Schedule page. While a "still listening?" prompt is live a full-screen overlay shows an oversized "Still Listening" confirm button. |
| **Audio Controls** | `AudioControlsSheetView` | Sheet (from Player) | Expanded audio settings — speed, trim silence, vocal boost — accessible while an episode is playing. |
| **Episode Share** | `EpisodeShareSheet` | Sheet (from Player) | Previews the rendered episode share card and exports it via the system share sheet together with the episode's audio URL. |
| **Queue** | `QueueSheetView` | Sheet | The playback queue — Up Next episode plus the priority-ordered list of what plays after. Drag to reorder, swipe to remove. |
| **Sleep Timer** | `SleepTimerSheetView` | Sheet | Set a timer to stop playback after a fixed duration or at the end of the current episode. |
| **Downloads** | `DownloadsView` | Page | All episodes currently downloaded to the device. Shows file sizes and allows deletion. |
| **App Settings** | `SettingsView` | Page | Global app configuration — default playback preferences, download behaviour, notifications, OPML import/export. |
| **Notification Settings** | `NotificationSettingsView` | Page (inside App Settings) | Master new-episode notification toggle, Enable All / Disable All, and per-podcast notification toggles for every subscription. Shows a permission banner with an iOS Settings deep link when notifications are denied. |
| **Listening History** | `ListeningHistoryView` | Page (Menu or App Settings) | Log of all episodes listened to, with duration and date. Grouped by time period. Minimum 60s playback threshold. |
| **Stats** | `StatsView` | Page (inside Menu) | Listening stats over a selectable period (7 Days / 30 Days / 90 Days / 1 Year / All Time) — time listened, time saved, episodes finished, streak, listening heatmap (or monthly trend chart), 24-hour listening clock, top shows, Shows You're Drifting From, and time-saved breakdown. Tapping a Top Shows or drifting-shows row expands an inline per-show detail card. |
| **Sleep Schedule** | `SleepScheduleView` | Page (inside Menu) | Recurring nightly sleep timer: on/off toggle, active-hours window (may span midnight), and prompt duration (10/15/20/40/60 min or End of Episode). During the window, after the duration a soft chime asks "Are you still listening?" over the continuing playback — any transport command confirms; no response within 60 s fades playback out and rewinds to where the chime started. |
| **Menu** | `MenuSheetView` | Sheet | Slide-up menu from the Subscriptions toolbar. The single gateway to Discover (top item), Downloads, Listening History, Stats, Sleep Schedule, App Settings, and Support (last item), plus the Import OPML action. (Find Podcasts lives behind the + button only.) |
| **Support** | `SupportView` | Page (inside Menu, last item) | In-app User Guide. A drill-down list of ~16 topic sections (icon + title + summary); tapping one pushes a native dark-themed detail page (`SupportSectionView`) rendering paragraphs, callouts, tables, status pills, and swipe-action cards. Content lives in `SupportContent.swift` and mirrors the website Support page. |
| **Acknowledgements** | `AcknowledgementsView` | Page (inside App Settings) | Credits for open-source libraries used in the app. |
| **Diagnostic Log** | `DiagnosticLogView` | Page (inside App Settings) | Internal log output for debugging playback and feed issues. Dev/support tool. |

---

## Navigation Structure

```
Player (PlayerView — permanent NavigationStack root, never torn down)
├── [Sheet] Queue (QueueSheetView)
├── [Sheet] Sleep Timer (SleepTimerSheetView)
├── [Sheet] Audio Controls (AudioControlsSheetView)
├── [Sheet] Episode Share (EpisodeShareSheet)
└── Subscriptions (PodcastsView — home page, pushed above the Player)
    ├── Podcast Detail (PodcastDetailView)
    │   ├── Episode Detail (EpisodeDetailView)
    │   └── Podcast Settings (SubscriptionSettingsView)
    ├── [Sheet] Discover (DiscoverView)               ← + button (also top Menu item)
    │   ├── Podcast Detail (PodcastDetailView)
    │   └── [Sheet] Podcast Search (PodcastSearchView) ← only entry point to Search
    │       ├── Podcast Detail (PodcastDetailView)
    │       └── Add RSS Feed (AddFeedView)
    └── [Sheet] Menu (MenuSheetView)                  ← only path to the pages below
        ├── [Sheet] Discover (DiscoverView)           ← top menu item (same sheet as +)
        ├── Downloads (DownloadsView)
        ├── Listening History (ListeningHistoryView)
        ├── Stats (StatsView)
        ├── Sleep Schedule (SleepScheduleView)
        ├── App Settings (SettingsView)
        │   ├── Notification Settings (NotificationSettingsView)
        │   ├── Acknowledgements (AcknowledgementsView)
        │   └── Diagnostic Log (DiagnosticLogView)
        └── Support (SupportView)                     ← last menu item; in-app User Guide
            └── Support Section detail (SupportSectionView)
```

### Navigation rules (NavRules)

Every screen uses exactly one of three exit patterns:

1. **Pushed page** — brand back chevron (`chevron.left.circle.fill`) top-left; nothing else in that corner. `MiniPlayerBar` docks at the bottom (hidden during Subscriptions reorder mode); tapping it pops to the Player.
2. **Informational sheet** — `SheetCloseButton` (✕) top-right; drag-to-dismiss. No "Done"/"Cancel". (Queue, Menu, Podcast Search, Discover, Audio Controls, Sleep Timer — timer presets apply and close in one tap.)
3. **Editing sheet** — `Cancel` leading / `Save` trailing, reserved for forms that commit data (Edit Title, Edit Priority, skip-interval editor).

Player top bar: quiet icon circle (top-left) pushes Subscriptions — the only nav exit; the Sleep Schedule indicator pill sits next to it (only inside the active-hours window) and pushes the Sleep Schedule page; purple **Queue** button (top-right, with count badge) opens the Queue sheet. One path per page — no duplicate routes.

---

## Browse Subscription Lifecycle

Podcasts opened via Podcast Search or Discover but not explicitly subscribed to are stored as **browse subscriptions** (`browseDate != nil`). These are invisible everywhere in the app except Podcast Search (Recently Viewed).

| State | `excludeFromAutoFeedRefresh` | `browseDate` | Visible in Priority List |
|---|---|---|---|
| Browse (auto-created on preview open) | `true` | set to open date | No |
| Inactive (user-set via Podcast Settings) | `true` | `nil` | Yes |
| Active subscription | `false` | `nil` | Yes |

Browse subscriptions are automatically deleted after 30 days if no episode has been played or downloaded. The clock resets each time the user reopens the Podcast Detail page.
