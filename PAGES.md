# Autohop — Page Reference

<!--
AI CONTEXT — PAGES.md
Canonical page/sheet naming and navigation map. Use these visible labels in
user-facing copy and docs. "Up Next" is the user-facing sheet name; `QueueSheetView`
and related `Queue*` identifiers are retained implementation names and should be
called out explicitly when needed so future AI agents do not rename working code
by accident.
Subscriptions Reorder operates only on active real-subscription UUIDs: Inactive
rows stay fixed below the draggable group, hidden browse previews are excluded,
and Done commits one validated durable order.
Version 1.3 exposes no Autohop Pro page: its retained view is development-only
behind ReleaseFeatures.autohopPro. The tvOS target and Relay are also excluded.
-->

**Source of truth for every screen in the app.**
Use these labels in design, development, and documentation discussions to avoid ambiguity.
Keep this file updated whenever a new page is added or an existing one is renamed.

> **Sheet** — slides up from the bottom, dismissed by swiping down.
> **Page** — pushed onto the navigation stack, dismissed with the back button.

---

## Page Table

| Label | Code Name | Type | Purpose |
|---|---|---|---|
| **Welcome** | `WelcomeView` | Sheet (fullScreenCover) | First-run value-prop screen, shown once to a brand-new user (no real subscriptions and `hasCompletedWelcome == false`). Presented by RootView over the launch splash. A 3-panel paged carousel (the model · "Listen your way" · "Made for real life") over three CTAs: Find shows (→ Discover), Import from another app (in-place OPML import → Subscriptions), or "I'll explore on my own" (→ Subscriptions). Sets `hasCompletedWelcome` on exit so it never reappears. See ONBOARDING_PLAN.md / FEATURES.md §18. |
| **Starter Packs** | `StarterPacksView` | Sheet | First-run "not sure where to start?" helper. Each pack is a genre's current Top-6 from Apple's public charts, scoped to the user's storefront; "Add these shows" subscribes to all via `AppState.subscribeToFeedURLs`. Presented from the empty Subscriptions state and the Discover first-run banner (both shown only while `realSubscriptionCount == 0`). |
| **You're All Set** | `FirstSubscribeCard` | Sheet | First-run "aha" card, presented by RootView on `.autohopFirstSubscription` (the user's first ever *single* deliberate subscribe; bulk OPML import is excluded). Ensures the show's latest episode is downloading, shows live progress, and turns **Play latest** into one tap — playing immediately if ready, or arming a wait that auto-starts the instant the download lands. Includes the one-time download-first education note. See FEATURES.md §18. |
| **Subscriptions** | `PodcastsView` | Full page | Your subscribed podcasts in priority order — the home page. Centered "Subscriptions" heading; action row below holds Reorder and refresh-all. Reorder creates a stable draft for active real subscriptions only: active rows show drag grips, Inactive rows remain fixed below them, hidden browse previews are excluded, status pills hide, and Done/navigation/background commits the validated final UUID order once. Each row shows artwork, the show title and the show's channel-level description (2-line clamp, styled like PodcastDetailView's episode rows), and a metadata line "Updated: &lt;relative age&gt;" (e.g. "Updated: 2 hours ago"; mins/hours → "Yesterday" → "2…6 days ago" → exact date; no episode length) with the latest-episode status pill. Tap a podcast to see its episodes. |
| **Podcast Search** | `PodcastSearchView` | Sheet | Search the podcast directory by name, author, or keyword. Also shows Recently Viewed history. Reached only via the Discover page's search shortcut. |
| **Discover** | `DiscoverView` | Page | Browse Apple Podcasts charts — Top-8 hero paging cards plus generously separated per-genre rails. The page shell and Search are usable immediately; heroes, rails, and spotlights appear independently as their requests complete. Each category chip and icon-bearing rail heading pushes that category's dedicated `Top 50 - <Category>` page; an available Top-15 rail seeds the child page instantly while the full chart loads. Two country spotlights are woven into the feed. The shared country picker appears on every chart page. |
| **Top Episodes** | `TopEpisodesView` | Page (child of Discover) | Expanded Top-50 episode chart for the selected Discover country (the full version of the Top-8 episode hero). Editorial layout: a large feature card every 7th entry (ranks 1/8/15/22/29/36/43), the rest are compact ranked rows. Each entry shows episode artwork (placeholder fallback), episode title, show name, and a relative publish label ("4 hours ago"). Tapping resolves the parent podcast and routes to the Podcast Detail page. |
| **Top Podcasts / Category Top 50** | `TopPodcastsView` | Page (child of Discover) | Expanded Top-50 *show* chart for the selected Discover country, used both for the overall chart and dedicated Comedy, News, True Crime, Society & Culture, Business, Sports, Health & Fitness, Technology, Science, and TV & Film charts. Same editorial layout as Top Episodes (a large feature card every 7th entry, the rest compact ranked rows). Each entry shows artwork, title, author/publisher, and category; tapping resolves the feed and routes to Podcast Detail. Overall is reached through See All; category pages through the chips. |
| **Podcast Detail** | `PodcastDetailView` | Page | A podcast's artwork, description, and full episode list — one page serving unsubscribed previews, browse-only previews, active subscriptions, and Inactive subscriptions. Header has a Subscribe⇄Unsubscribe button (Inactive still shows subscribed/Unsubscribe), a per-podcast new-episode notification bell beside it once subscribed, and an expandable "…more" show description; the Refresh Feed and Show Settings toolbar items appear for real subscriptions, including Inactive ones. Episodes are fully interactive from first load — swipe leading for Play / Play Next, and trailing for a far-right Download/Archive button plus Play Last. The far-right button is state-driven: a downloaded episode shows Archive; an un-downloaded episode on a subscribed + active feed shows Download (which downloads into the Up Next queue at its priority position); on non-subscribed previews or Inactive subscriptions it falls back to Archive/Unarchive. |
| **Add RSS Feed** | `AddFeedView` | Page | Manually enter a podcast RSS URL. Fallback for podcasts not found in the search directory. |
| **Podcast Settings** | `SubscriptionSettingsView` | Page | Per-podcast configuration — playback speed, Vocal Boost, stepped −3…+3 dB Volume Adjustment, Stereo/Mono audio, trim silence, chapter filtering, auto-archive rules, notifications, Download Filters entry point, feed exclusion from auto-refresh, and **Play Instant**. Volume Adjustment appears between Vocal Boost and Mono Audio, applies live through a gain stage independent of device volume, and syncs with the podcast preference. Mono Audio centres left/right presenter mixes for audio episodes and applies live. Play Instant appears in the shared Automation glass card; for an absolute-favourite show it can warn, interrupt active playback for a newly auto-downloaded episode, then return to the exact interrupted position. It never responds to manual downloads. Start skip / End skip share one rounded glass card matching the neighbouring Automation section, with the same padding and inset divider; the controls retain fixed minus/plus capsule buttons, compact minute/second text, and debounced persistence so scrolling and live playback stay stable. Chapter filtering edits the currently playing episode from this podcast when one has chapters, otherwise the newest episode; changes are applied to active playback immediately, while the current chapter remains protected from deselection on this settings page. Also reachable from the gear in an expanded **Up Next** row, which closes Up Next and opens this page (presented as a sheet) in its place. |
| **Download Filters** | `DownloadFiltersView` | Page (inside Podcast Settings) | Per-podcast automatic download rules for RSS episode duration, title, and description. Rules are local/backup-only in v1, affect automatic downloads only, and include a read-only latest-feed preview with skipped rows greyed out. |
| **Release Radar Data** | `SubscriptionRadarDiagnosticsView` | Page (inside Podcast Settings → Feed) | Read-only per-subscription diagnostic showing the filter-eligible data and gate outcomes behind this feed's Release Radar classification: learned profile + confidence + reason + window, **why-not-Daily / why-not-Weekly** checklists (each row a real classifier guard with this feed's value vs threshold, ✓/✗), the learning signal (reliable vs total observations, date-quality breakdown, median gap, typical time + spread, dominant weekday + ratio), **per-weekday watch tiers** (each day's publish probability mapped to Full / Light / Skip), and the most recent eligible observations. Episodes skipped by Download Filters are excluded so the page matches what Radar acts on. |
| **Episode Detail** | `EpisodeDetailView` | Page | Full detail for a single episode — description, chapters, chapter artwork, playback controls, share, and the same state-driven Download/Archive/Unarchive primary action used by Podcast Detail. |
| **Player** | `PlayerView` | Page (modal overlay) | Full-screen now-playing screen. Shows artwork, title, scrubber, playback controls, chapter list, plus sleep timer, AirPlay, share, and archive actions. Chapter previous/next targets are derived from playback time rather than an active-list index, so the controls remain reliable immediately after a filter change; deselecting the audible chapter here advances playback immediately to the next enabled chapter (or the episode end). On open, the scrubber immediately reflects the restored playback position for a partially played episode rather than waiting for a later tick. A cancelled scrub gesture recovers after five idle seconds instead of leaving the thumb/timers frozen, and seeking or skipping into the final 0.25 seconds completes and advances the episode rather than creating a resumable ending. A Sleep Schedule indicator pill (bed icon + minutes to the next prompt) appears in the top bar only while inside the active-hours window and pushes the Sleep Schedule page. While a "still listening?" prompt is live a full-screen overlay shows an oversized "Still Listening" confirm button. |
| **Audio Controls** | `AudioControlsSheetView` | Sheet (from Player) | Expanded audio settings — speed, trim silence, vocal boost — accessible while an episode is playing. |
| **Episode Share** | `EpisodeShareSheet` | Sheet (from Player) | Previews the rendered episode share card and exports it via the system share sheet together with the episode's audio URL. |
| **Up Next** | `QueueSheetView` | Sheet | The playback queue — the next episode plus the priority-ordered list of what plays after. Sheet title is "Up Next" (internal struct remains `QueueSheetView`). Small Video/Explicit indicators are icon-only and occupy the trailing metadata stack, separately from the blue/orange pin so the symbols cannot overlap. Tapping an episode title expands the row to reveal its full description plus two small purple circular glass buttons at the bottom-right: `list.bullet` (opens that podcast's **Podcast Detail** page, closing Up Next) and `gearshape` (opens that podcast's **Podcast Settings** page, closing Up Next). Both use the staged-ID "replace Up Next" pattern in PlayerView. Swipe actions are animated with matched haptics: Play Next/Last glide the row to the top/bottom (directional badge + pop), Archive slides it into an archive box and closes the gap. See DESIGN.md `QueueAction-Animation`. |
| **Sleep Timer** | `SleepTimerSheetView` | Sheet | Set a timer to stop playback after a fixed duration or at the end of the current episode. |
| **Downloads** | `DownloadsView` | Page | Download activity in three card sections: Downloading (progress bar in ≥1% steps, pause/resume + archive controls — controls are fixed-size so long progress text truncates instead of squashing buttons), Downloaded on Device (file sizes, archive), and Recently Archived (re-download button). Small Video and Explicit indicators use icon-only styling with no glass capsule. |
| **App Settings** | `SettingsView` | Page | Global app configuration — Release Radar (fully automatic learned timing; no sensitivity control), Auto Archive (run-now, activity audit, and global default rules seeded into new subscriptions), download behaviour, controls, global Default Playback, notifications, OPML import/export, and opt-in iCloud Sync. Default Playback includes Stereo/Mono Audio; Stereo is the factory default, and the selected value seeds future subscriptions without changing existing podcasts. Version 1.3 does not show Autohop Pro; that retained page requires an explicit development compilation condition. The Default Playback section mirrors the per-podcast trim controls exactly, including the standard menu-card background, compact minute/second text, and debounced minus/plus adjustment rows. |
| **Auto Archive Activity** | `AutoArchiveActivityView` | Page (inside App Settings → Auto Archive) | Newest-first local audit of automatic archive decisions. Each card shows episode, podcast, exact archived date/time, responsible rule (After Playing, Inactive Episodes, or Episode Limit), the configured threshold, and the measured age when archived. Records begin after this feature is installed; the bounded local store retains the latest 500 events. |
| **Notification Settings** | `NotificationSettingsView` | Page (inside App Settings) | Master new-episode notification toggle, Enable All / Disable All, a **Listening Recaps** row (opens the recaps sheet), and per-podcast notification toggles for every subscription. Shows a permission banner with an iOS Settings deep link when notifications are denied. |
| **Feed Refresh Schedule** | `FeedRefreshScheduleView` | Page (inside App Settings → Release Radar) | Read-only diagnostic table of every **active** subscription (Inactive excluded) and the Release Radar schedule auto feed-refresh uses for it: learned profile kind + confidence, current window state, the recurring "watches around…" pattern, the next concrete expected window (+ countdown), and the in-window recheck interval. Grouped by publish frequency (Watching now / soon · Hourly · Daily – Multiple Episodes · Daily · Several Times a Week · Weekly · Still learning), sorted alphabetically within each group; makes clear when auto feed refresh **will** and **won't** look for new episodes. Each row has a **Diagnostics** button (opens that feed's **Release Radar Data** screen) and a **Rebuild Prediction** button that fetches the feed's last 100 episodes' publish dates **and times** into the learner (learning-only — no episodes are added to the library, and episodes skipped by Download Filters are excluded) to form a stronger expected-window prediction. A toolbar **export** button (ShareLink) shares a plain-text diagnostic dump of every active subscription — the same filter-eligible data as each podcast's **Release Radar Data** screen — for offline trend analysis. |
| **Listening Recaps** | `RecapSettingsView` | Sheet | Opt-in weekly / monthly / yearly listening-summary notifications (all off by default; delivered ~9am). Reached from the bell button in the **Stats** toolbar and from **Notification Settings**. Enabling any toggle requests notification permission and schedules a recurring local notification that deep-links into the Stats "Last" view. |
| **Listening History** | `ListeningHistoryView` | Page (Menu) | Historical episode-outcome log grouped by event date, with a 60-second playback threshold. Rows use the canonical subscription episode-list geometry: 44pt artwork, subheadline-semibold episode title, caption podcast name and metadata, plus the shared `EpisodeStatusPill`. The pill reflects the recorded historical outcome (Played, Archived, Paused; Playing only while an unresolved entry is currently audible), not a later library-state change. Metadata identifies the event and exact local date/time: Completed, Manually Archived, Auto Archived, legacy Archived, or Last listened. Resolved rows retain the same four swipe positions and behavior as Podcast Detail: Play / Play Next on the leading edge, and a state-driven Download/Archive/Unarchive action plus Play Last on the trailing edge. Actions download first when required, and the standard animated purple progress bar appears beneath a row during download. |
| **Stats** | `StatsView` | Page (inside Menu, or direct from recap notification) | Listening stats over a selectable period (7 Days / displayed month / displayed year / Lifetime — all calendar-anchored, resetting at the start of each period; the selected month and year pills follow the **This / Last** bar, e.g. "July" → "June" and "2026" → "2025"). A distinct solid **This / Last** bar below the pills switches Week/Month/Year to the previous concluded period (hidden on Lifetime or when that period has no data, except recap notification deep links still open their intended Last view). Sections: time listened, time saved, episodes finished, streak, listening heatmap (or monthly trend chart), 24-hour listening clock, top shows, Shows You're Drifting From (This mode only), and time-saved breakdown. Download-Filter Skipped episodes are excluded from drifting-show calculations; manual downloads remain eligible. Tapping a Top Shows or drifting-shows row expands an inline detail card. A bell button in the toolbar opens the **Listening Recaps** sheet. |
| **Sleep Schedule** | `SleepScheduleView` | Page (inside Menu) | Recurring nightly sleep timer: on/off toggle, active-hours window (may span midnight), and prompt duration (10/15/20/40/60 min or End of Episode). During the window, after the duration a soft chime asks "Are you still listening?" over the continuing playback — any transport command confirms; no response within 60 s fades playback out and rewinds to where the chime started. The end of Active Hours is a hard boundary: pending countdowns and live prompts are dismissed, their notification is cleared, and ordinary playback continues without further prompts. |
| **Menu** | `MenuSheetView` | Sheet | Slide-up menu from the Subscriptions toolbar. The single gateway to Discover (top item — dismisses the Menu and pushes the Discover page), Stats, Sleep Schedule, Listening History, Downloads, App Settings, and Support (last item). (Find Podcasts lives behind the + button only.) |
| **Support** | `SupportView` | Page (inside Menu, last item) | In-app User Guide. A drill-down list of topic sections (icon + title + summary), including CarPlay support; tapping one pushes a native dark-themed detail page (`SupportSectionView`) rendering paragraphs, callouts, tables, status pills, and swipe-action cards. Content lives in `SupportContent.swift` and mirrors the website Support page. |
| **Acknowledgements** | `AcknowledgementsView` | Page (inside App Settings) | Credits for open-source libraries used in the app. |
| **Diagnostic Log** | `DiagnosticLogView` | Page (inside App Settings) | Internal log output for debugging playback, audio route changes, foreground/background feed scheduling, downloads, stats-sync/CloudKit conflicts, resource snapshots, playback tick timing, and main-thread watchdog gaps. Dev/support tool. |

---

## Navigation Structure

```
Player (PlayerView — permanent NavigationStack root, never torn down)
├── [Sheet] Up Next (QueueSheetView)           ← expanded-row gear opens Podcast Settings (replaces this sheet)
├── [Sheet] Sleep Timer (SleepTimerSheetView)
├── [Sheet] Audio Controls (AudioControlsSheetView)
├── [Sheet] Episode Share (EpisodeShareSheet)
└── Subscriptions (PodcastsView — home page, pushed above the Player)
    ├── Podcast Detail (PodcastDetailView)
    │   ├── Episode Detail (EpisodeDetailView)
    │   └── Podcast Settings (SubscriptionSettingsView)
    │       ├── Download Filters (DownloadFiltersView)
    │       └── Release Radar Data (SubscriptionRadarDiagnosticsView)
    ├── Discover (DiscoverView — pushed page)         ← + button (also top Menu item)
    │   ├── Podcast Detail (PodcastDetailView)
    │   ├── Top Episodes (TopEpisodesView)             ← "See All" on the Top Episodes hero
    │   │   └── Podcast Detail (PodcastDetailView)
    │   ├── Top Podcasts (TopPodcastsView)             ← "See All" on the first Top Podcasts hero
    │   │   └── Podcast Detail (PodcastDetailView)
    │   └── [Sheet] Podcast Search (PodcastSearchView) ← only entry point to Search
    │       ├── Podcast Detail (PodcastDetailView)
    │       └── Add RSS Feed (AddFeedView)
    └── [Sheet] Menu (MenuSheetView)                  ← only path to the pages below
        ├── Discover (DiscoverView — pushed page)     ← top menu item (same page as +)
        ├── Stats (StatsView)
        ├── Sleep Schedule (SleepScheduleView)
        ├── Listening History (ListeningHistoryView)
        ├── Downloads (DownloadsView)
        ├── App Settings (SettingsView)
        │   ├── Notification Settings (NotificationSettingsView)
        │   ├── Feed Refresh Schedule (FeedRefreshScheduleView)   ← Release Radar section
        │   ├── Auto Archive Activity (AutoArchiveActivityView)   ← Auto Archive section
        │   ├── Acknowledgements (AcknowledgementsView)
        │   └── Diagnostic Log (DiagnosticLogView)
        └── Support (SupportView)                     ← last menu item; in-app User Guide
            └── Support Section detail (SupportSectionView)
```

### First-run onboarding chrome (not in the tree above)

These appear only for a brand-new user and layer over the normal navigation rather than living in the page tree (see FEATURES.md §18, DESIGN.md "Onboarding — First-Run Components"):

- **Welcome** (`WelcomeView`) — full-screen cover over the launch splash on first run.
- **Starter Packs** (`StarterPacksView`) — sheet from the empty Subscriptions state / Discover first-run banner.
- **You're All Set** (`FirstSubscribeCard`) — sheet on the first deliberate subscribe.
- **Getting-Started checklist** (`GettingStartedChecklist`) — dismissible card pinned at the top of the Subscriptions (Priority Stack) page.
- **Coach marks** (`CoachMarkOverlay`) — one-at-a-time bottom tip cards floating above pages, below sheets (priorityStack, swipeActions, playerPanels, speed, sleepSchedule).
- **Onboarding toast** — transient confirmation capsule above the mini-player (e.g. after OPML import).

### Navigation rules (NavRules)

Every screen uses exactly one of three exit patterns:

1. **Pushed page** — brand back chevron (`chevron.left.circle.fill`) top-left; nothing else in that corner. `MiniPlayerBar` docks at the bottom (hidden during Subscriptions reorder mode); tapping it pops to the Player.
2. **Informational sheet** — `SheetCloseButton` (✕) top-right; drag-to-dismiss. No "Done"/"Cancel". (Up Next, Menu, Podcast Search, Audio Controls, Sleep Timer — timer presets apply and close in one tap.)
3. **Editing sheet** — `Cancel` leading / `Save` trailing, reserved for forms that commit data (Edit Title, Edit Priority, skip-interval editor).

Player top bar: quiet icon circle (top-left) pushes Subscriptions — the only nav exit; the Sleep Schedule indicator pill sits next to it (only inside the active-hours window) and pushes the Sleep Schedule page; purple **Up Next** button (top-right, with count badge) opens the Up Next sheet. One path per page — no duplicate routes.

---

## Browse Subscription Lifecycle

Podcasts opened via Podcast Search or Discover but not explicitly subscribed to are stored as **browse subscriptions** (`browseDate != nil`). These are invisible everywhere in the app except Podcast Search (Recently Viewed).

| State | `excludeFromAutoFeedRefresh` | `browseDate` | Visible in Priority List |
|---|---|---|---|
| Browse (auto-created on preview open) | `true` | set to open date | No |
| Inactive (user-set via Podcast Settings) | `true` | `nil` | Yes |
| Active subscription | `false` | `nil` | Yes |

Browse subscriptions are automatically deleted after 30 days only if no episode has been played or downloaded **and** the show has no listening-history entry (so anything you've actually listened to is kept, keeping its history navigable). The clock resets each time the user reopens the Podcast Detail page.

Inactive subscriptions are still real subscriptions. They remain visible in the Priority List with the Inactive pill, keep Settings/manual Refresh/notifications/Unsubscribe on the Podcast Detail page, and return to their saved Priority List position when `excludeFromAutoFeedRefresh` is turned off.
