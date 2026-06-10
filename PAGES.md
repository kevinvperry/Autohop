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
| **Priority List** | `PodcastsView` | Full page | Your subscribed podcasts in priority order. Drag to reorder. Tap a podcast to see its episodes. The home page of the app. |
| **Podcast Search** | `PodcastSearchView` | Sheet | Search the podcast directory by name, author, or keyword. Also shows Recently Viewed history. Entry point to finding new podcasts. |
| **Podcast Preview** | `PodcastPreviewView` | Page (inside Search sheet) | Shows a podcast's artwork, description, and full episode list before subscribing. Subscribe button graduates it to a full subscription. Episodes are fully interactive from first load. |
| **Add RSS Feed** | `AddFeedView` | Page | Manually enter a podcast RSS URL. Fallback for podcasts not found in the search directory. |
| **Podcast Episodes** | `SubscriptionEpisodesView` | Page | Full episode list for a subscribed podcast. Header shows artwork, title, description. Swipe episodes for Play, Archive, and other actions. |
| **Podcast Settings** | `SubscriptionSettingsView` | Page | Per-podcast configuration — playback speed, trim silence, auto-archive rules, notifications, and feed exclusion from auto-refresh. |
| **Episode Detail** | `EpisodeDetailView` | Page | Full detail for a single episode — description, chapters, chapter artwork, playback controls, download and share actions. |
| **Player** | `PlayerView` | Page (modal overlay) | Full-screen now-playing screen. Shows artwork, title, scrubber, playback controls, chapter list, plus sleep timer, AirPlay, share, and archive actions. |
| **Audio Controls** | `AudioControlsSheetView` | Sheet (from Player) | Expanded audio settings — speed, trim silence, vocal boost — accessible while an episode is playing. |
| **Episode Share** | `EpisodeShareSheet` | Sheet (from Player) | Previews the rendered episode share card and exports it via the system share sheet together with the episode's audio URL. |
| **Queue** | `QueueSheetView` | Sheet | The playback queue — Up Next episode plus the priority-ordered list of what plays after. Drag to reorder, swipe to remove. |
| **Sleep Timer** | `SleepTimerSheetView` | Sheet | Set a timer to stop playback after a fixed duration or at the end of the current episode. |
| **Downloads** | `DownloadsView` | Page | All episodes currently downloaded to the device. Shows file sizes and allows deletion. |
| **App Settings** | `SettingsView` | Page | Global app configuration — default playback preferences, download behaviour, notifications, OPML import/export. |
| **Listening History** | `ListeningHistoryView` | Page (Menu or App Settings) | Log of all episodes listened to, with duration and date. Grouped by time period. Minimum 60s playback threshold. |
| **Stats** | `StatsView` | Page (inside Menu) | Listening stats over a selectable period (30 Days / 90 Days / 1 Year / All Time) — time listened, time saved, episodes finished, streak, listening heatmap (or monthly trend chart), 24-hour listening clock, top shows, and time-saved breakdown. |
| **Menu** | `MenuSheetView` | Sheet | Slide-up menu from the Priority List toolbar. Shortcuts to Find Podcasts, Downloads, Listening History, Stats, and App Settings. |
| **Acknowledgements** | `AcknowledgementsView` | Page (inside App Settings) | Credits for open-source libraries used in the app. |
| **Diagnostic Log** | `DiagnosticLogView` | Page (inside App Settings) | Internal log output for debugging playback and feed issues. Dev/support tool. |

---

## Navigation Structure

```
Priority List (PodcastsView)
├── Podcast Episodes (SubscriptionEpisodesView)
│   ├── Episode Detail (EpisodeDetailView)
│   └── Podcast Settings (SubscriptionSettingsView)
├── [Sheet] Menu (MenuSheetView)
│   ├── [Sheet] Podcast Search (PodcastSearchView)
│   │   ├── Podcast Preview (PodcastPreviewView)
│   │   └── Add RSS Feed (AddFeedView)
│   ├── Downloads (DownloadsView)
│   ├── Listening History (ListeningHistoryView)
│   ├── Stats (StatsView)
│   └── App Settings (SettingsView)
│       ├── Listening History (ListeningHistoryView)   ← also reachable from Menu
│       └── Acknowledgements (AcknowledgementsView)
├── [Sheet] Podcast Search (PodcastSearchView)       ← also reachable from + button
├── [Overlay] Player (PlayerView)
│   ├── [Sheet] Queue (QueueSheetView)
│   ├── [Sheet] Sleep Timer (SleepTimerSheetView)
│   ├── [Sheet] Audio Controls (AudioControlsSheetView)
│   └── [Sheet] Episode Share (EpisodeShareSheet)
└── App Settings (SettingsView)                      ← also reachable from Menu
```

---

## Browse Subscription Lifecycle

Podcasts opened via Podcast Search but not explicitly subscribed to are stored as **browse subscriptions** (`browseDate != nil`). These are invisible everywhere in the app except Podcast Search (Recently Viewed).

| State | `excludeFromAutoFeedRefresh` | `browseDate` | Visible in Priority List |
|---|---|---|---|
| Browse (auto-created on preview open) | `true` | set to open date | No |
| Inactive (user-set via Podcast Settings) | `true` | `nil` | Yes |
| Active subscription | `false` | `nil` | Yes |

Browse subscriptions are automatically deleted after 30 days if no episode has been played or downloaded. The clock resets each time the user reopens the Podcast Preview page.
