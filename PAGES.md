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
No Autohop Pro page or external relay settings exist. iCloud is the sole
cross-device synchronization method for iPhone and Apple TV.
Version 1.4 includes one adaptive Now Playing & Up Next system widget. It is an
external WidgetKit surface, not a page in the app navigation stack.
The tvOS app, submitted as Version 1.6 (build 13) on 22 August 2026, has Home, Up Next, Library,
Search, Player and Settings/Diagnostics tabs. Search is browse/play-only and TV
cannot change iPhone subscription settings or Priority order.
Page names and routes were rechecked against current SwiftUI code on 2026-07-24.
Apple TV Settings uses focus-driven automatic scrolling: actionable controls and
read-only health rows form nearby stable focus stops, and expensive diagnostics
are cached until explicit refresh. Dynamic Top Shelf is an external Home Screen
surface sourced from the same Up Next projection, not a navigable page.
-->

> All titled iOS-family pages share container-measured inline navigation chrome,
> and the persistent mini-player scales with that same page width. Its compact
> layout contains enlarged left artwork, a full-width episode title, then
> podcast/countdown metadata beside a tight right-aligned transport cluster;
> only its bottom progress strip spans the page width, with the rounded
> purple-glass surface continuing through the bottom safe area. Empty hero-led
> navigation titles remain intentionally hidden because the hero owns hierarchy.
> Podcast Detail keeps artwork top-left and identity/description top-right on
> content columns below 600 points; wider columns centre the complete header.
> All native List/Form pages and custom list-style surfaces share the same
> large-screen row-density policy; no page should introduce an isolated fixed
> 44-point image row without documenting why it is exempt.
> Responsive review covers the complete visual hierarchy—not only list titles.
> Secondary metadata, buttons, status/media pills, icons, artwork and hit areas
> must use the same container-width band as the page's primary content.
> Vertical episode-list surfaces use `episodeListPageWidth()`: 20-point compact
> gutters and an 860-point maximum surface within a centred 900-point column.
> This applies to Podcast Detail, Subscriptions, Up Next, Listening History,
> Downloads, Search episode results and Auto Archive Activity.
> Page action rows associated with those lists align to the same outer column;
> custom Player navigation and Podcast Detail toolbar controls share the
> standard responsive navigation scale.
> Expansive Settings pages use a persistent left shortcut rail and right-hand
> scrolling Form. System Settings groups Startup, Release Radar, Auto Archive,
> Downloading, Controls, Subscriptions, Sync, Storage, Contact, About and unlocked
> Diagnostics. Podcast Settings groups Podcast, Download Feed Filters, Playback,
> Automation, Auto Archive, optional Chapter filter, Feed and Subscription. Rail
> wording exactly mirrors the visible section headings.
> The complete rail/Form workspace is centred on landscape displays over one
> consistent black background.
> System and Podcast Settings use the same 48-point separation between menu
> sections at every device width; spacing within each section card is unchanged.
> Podcast Detail and the other iOS pages use bounded utility-toolbar symbols;
> Share no longer inherits the oversized circular-Back font on iPad/Mac.
> Shortcut taps use the native Form section index so distant virtualized sections
> remain reachable before SwiftUI creates their row views. The destination's
> first row is vertically centred, preserving its heading and nearby context;
> manual Form scrolling updates the selected shortcut as headers appear.

> Version 1.6 build 9: Settings → Developer Diagnostics disables the Full
> Diagnostic Export control while a report is being prepared and displays a
> progress/result message. Report preparation does not block focus navigation.

> The Player's Audio Controls sheet is one shared iOS-family surface on iPhone,
> iPad and Mac. Its runtime owners are passed explicitly at presentation so a
> Mac modal cannot lose inherited state and terminate the app.

> The Episode Share sheet measures its complete preview and action stack and
> presents one fitted-height stop. It must not use generic medium/large detents,
> which either conceal controls or create an oversized full-screen sheet.

> Discover navigation chrome follows the same immediate-container width bands
> as its page assets. The title, Back control and country picker progressively
> enlarge on iPad and Mac without changing the compact phone baseline.

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
| **Starter Packs** | `StarterPacksView` | Sheet | First-run "not sure where to start?" helper. Each pack is a genre's current Top-6 from Apple's public charts, scoped to the user's storefront; "Add these shows" subscribes to all through `SubscriptionImportCoordinator`. Presented from the empty Subscriptions state and the Discover first-run banner (both shown only while `OnboardingCoordinator.realSubscriptionCount == 0`). |
| **You're All Set** | `FirstSubscribeCard` | Sheet | First-run "aha" card, presented by RootView on `.autohopFirstSubscription` (the user's first ever *single* deliberate subscribe; bulk OPML import is excluded). Ensures the show's latest episode is downloading, shows live progress, and turns **Play latest** into one tap — playing immediately if ready, or arming a wait that auto-starts the instant the download lands. Includes the one-time download-first education note. See FEATURES.md §18. |
| **Subscriptions** | `PodcastsView` | Full page | Your subscribed podcasts in priority order — the home page. Centered "Subscriptions" heading; action row below holds Priority (drag-to-reorder toggle) and refresh-all. Reorder creates a stable draft for active real subscriptions only: active rows show drag grips, Inactive rows remain fixed below them, hidden browse previews are excluded, status pills hide, and Done/navigation/background commits the validated final UUID order once. Each row shows artwork, the show title and the show's channel-level description (2-line clamp, styled and responsively scaled like PodcastDetailView's episode rows), and a metadata line "Updated: &lt;relative age&gt;" (e.g. "Updated: 2 hours ago"; mins/hours → "Yesterday" → "2…6 days ago" → exact date; no episode length) with the latest-episode status pill. Row metadata, Priority/refresh controls, artwork and pills use the root container's live iPad/Mac width rather than a phone fallback. Tap a podcast to see its episodes. |
| **Podcast Search** | `PodcastSearchView` | Page (child of Discover) | Dedicated search with an All / My Library scope. All uses independent, storefront-aware Apple Shows and Episodes providers; My Library searches subscribed shows and locally known episodes immediately without a network dependency. Adaptive two-line show cards support compact phones through iPad. Show rows open Podcast Detail; episode rows open Episode Detail after safe Apple-GUID/RSS reconciliation; Publishers & Creators open a list of shows carrying the exact cleaned author metadata. The idle state retains Recently Viewed and manual RSS entry. |
| **Discover** | `DiscoverView` | Page | Browse Apple Podcasts charts — five Top-8 hero carousels separated by all 19 Apple categories as per-genre rails, in a 4/5/5/5 cadence: Top Episodes (fixed, above the feed), **New & Notable**, Top Podcasts, then two fixed-country international spotlights, the second closing the feed. The page shell and Search are usable immediately; heroes, rails, and spotlights appear independently as their requests complete. The first 9 rails load on open and the rest as the user scrolls. Each category chip, icon-bearing rail heading, and the trailing "See All" tile that closes each rail pushes that category's dedicated `Top 100 - <Category>` page; an available Top-15 rail seeds the child page instantly while the full chart loads. Category names follow the selected storefront ("Sport" in AU, "Sports" in US). New & Notable has no See All and is hidden when fewer than 3 shows qualify. The shared country picker appears on every chart page. |
| **Top Episodes** | `TopEpisodesView` | Page (child of Discover) | Expanded Top-50 episode chart for the selected Discover country (the full version of the Top-8 episode hero). Editorial layout: a large feature card every 7th entry (ranks 1/8/15/22/29/36/43), the rest are compact ranked rows. Each entry shows episode artwork (placeholder fallback), episode title, show name, and a relative publish label ("4 hours ago"). Tapping resolves the parent podcast and routes to the Podcast Detail page. |
| **Top Podcasts / Category Top 50** | `TopPodcastsView` | Page (child of Discover) | Expanded *show* chart for the selected Discover country — **Top 100 for each of the 19 Apple category pages**, Top 50 for the overall chart (Marketing Tools caps that feed at 50). Used both for the overall chart and a dedicated chart for each category (Comedy, News, True Crime, Society & Culture, Business, Sports, History, Health & Fitness, Education, Arts, Technology, Science, TV & Film, Fiction, Music, Leisure, Kids & Family, Religion & Spirituality, Government). The page title uses the storefront-localised category name. Same editorial layout as Top Episodes (a large feature card every 7th entry, the rest compact ranked rows). Each entry shows artwork, title, author/publisher, and category; tapping resolves the feed and routes to Podcast Detail. Overall is reached through See All; category pages through the chips. |
| **Podcast Detail** | `PodcastDetailView` | Page | A podcast's artwork, description, and full episode list — one page serving unsubscribed previews, browse-only previews, active subscriptions, and Inactive subscriptions. Header has a Subscribe⇄Unsubscribe button (Inactive still shows subscribed/Unsubscribe), a per-podcast new-episode notification bell beside it once subscribed, and an expandable "…more" show description; title, description, publisher, categories, buttons, badges and artwork scale together on iPad/Mac. Its Back button dismisses the nearest destination and therefore returns to the exact Subscriptions, Discover/Search/chart or root page that opened it. The Refresh Feed and Show Settings toolbar items appear for real subscriptions, including Inactive ones. Episodes are fully interactive from first load — swipe leading for Play / Play Next, and trailing for a far-right Download/Archive button plus Play Last. The far-right button is state-driven: a downloaded episode shows Archive; an un-downloaded episode on a subscribed + active feed shows Download (which downloads into the Up Next queue at its priority position); on non-subscribed previews or Inactive subscriptions it falls back to Archive/Unarchive. |
| **Add RSS Feed** | `AddFeedView` | Page | Manually enter a podcast RSS URL. Fallback for podcasts not found in the search directory. |
| **Podcast Settings** | `SubscriptionSettingsView` | Page | Per-podcast configuration — playback speed, Vocal Boost, stepped −3…+3 dB Volume Adjustment, Stereo/Mono audio, trim silence, chapter filtering, auto-archive rules, notifications, Download Filters entry point, feed exclusion from auto-refresh, and **Play Instant**. Volume Adjustment appears between Vocal Boost and Mono Audio, applies live through a gain stage independent of device volume, and syncs with the podcast preference. Mono Audio centres left/right presenter mixes for audio episodes and applies live. Play Instant appears in the shared Automation glass card; for an absolute-favourite show it can warn, interrupt active playback for a newly auto-downloaded episode, then return to the exact interrupted position. It waits rather than interrupting when the current episode has 60 seconds or less remaining. If the audio route is temporarily unavailable, the arrival remains armed for up to 30 minutes and triggers only after safe playback resumes; it never autoplays through the phone speaker and never responds to manual downloads. Start skip / End skip share one rounded glass card matching the neighbouring Automation section, with the same padding and inset divider; the controls retain fixed minus/plus capsule buttons, compact minute/second text, and debounced persistence so scrolling and live playback stay stable. Chapter filtering edits the currently playing episode from this podcast when one has chapters, otherwise the newest episode; changes are applied to active playback immediately, while the current chapter remains protected from deselection on this settings page. Also reachable from the gear in an expanded **Up Next** row, which closes Up Next and opens this page (presented as a sheet) in its place. |
| **Download Feed Filters** | `DownloadFiltersView` | Page (inside Podcast Settings) | Per-podcast automatic-download rules for RSS episode duration, title and description. Manual Play/Download actions bypass them; Exclude matches always reject an episode, while All/Any controls how enabled Include rules combine. Rules roam with per-podcast settings when iCloud Sync is enabled. A read-only latest-feed preview greys skipped rows, and a first-arrival high-contrast coach mark explains the model before configuration. |
| **Release Radar Data** | `SubscriptionRadarDiagnosticsView` | Page (inside Podcast Settings → Feed) | Read-only per-subscription diagnostic showing the filter-eligible data and gate outcomes behind this feed's Release Radar classification: learned profile + confidence + reason + window, **why-not-Daily / why-not-Weekly** checklists (each row a real classifier guard with this feed's value vs threshold, ✓/✗), the learning signal (reliable vs total observations, date-quality breakdown, median gap, typical time + spread, dominant weekday + ratio), **per-weekday watch tiers** (each day's publish probability mapped to Full / Light / Skip), and the most recent eligible observations. Episodes skipped by Download Filters are excluded so the page matches what Radar acts on. |
| **Episode Detail** | `EpisodeDetailView` | Page | Full detail for a single episode — description, chapters, chapter artwork, playback controls, share, and the same state-driven Download/Archive/Unarchive primary action used by Podcast Detail. |
| **Player** | `PlayerView` | Page (modal overlay) | Full-screen now-playing screen. Shows artwork, title, scrubber, playback controls, chapter list, plus sleep timer, AirPlay, share, and archive actions. The embedded one-item Up Next preview uses bounded custom dragging to coexist with the paged Player, but displays Play and Archive as the same isolated rounded green/purple controls used by episode lists rather than full-height colour slabs. Its Details panel uses a centred 900-point reading column, responsive gutters/type/cards and a separate 720-point feed-image cap on large screens. RSS attribution is kept in that metadata grid: Publisher comes from episode/channel author metadata, the first channel category is Category and remaining values are individual Sub-Category cards; no unlabeled author line appears between artwork and description. The iOS-family **Review in Apple Podcasts** action follows the grid. Chapters shares the centred 900-point column and responsive typography, row spacing and bounded selection-control scale. Video full-screen presentation preserves the effective per-podcast speed and play/pause state, permits user-driven landscape rotation without forcing a geometry change during presentation, and leaves AVPlayerViewController containment to SwiftUI. Chapter previous/next targets are derived from playback time rather than an active-list index, so the controls remain reliable immediately after a filter change; deselecting the audible chapter here advances playback immediately to the next enabled chapter (or the episode end). On open, the scrubber immediately reflects the restored playback position for a partially played episode rather than waiting for a later tick. A cancelled scrub gesture recovers after five idle seconds instead of leaving the thumb/timers frozen, and seeking or skipping into the final 0.25 seconds completes and advances the episode rather than creating a resumable ending. A Sleep Schedule indicator pill (bed icon + minutes to the next prompt) appears in the top bar only while inside the active-hours window and pushes the Sleep Schedule page. While a "still listening?" prompt is live a full-screen overlay shows an oversized "Still Listening" confirm button. |
| **Audio Controls** | `AudioControlsSheetView` | Sheet (from Player) | Expanded audio settings — global Shared Listening toggle and group speed, plus per-podcast speed, trim silence and vocal boost — accessible while an episode is playing. Shared Listening controls and the Player button's active highlight observe `SettingsViewModel` directly so toggle animation, picker visibility, speed selection and the external indicator update without closing the sheet. The full cross-page control ownership audit is recorded in `Docs/CONTROL_STATE_AUDIT_2026-08-14.md`. |
| **Episode Share** | `EpisodeShareSheet` | Adaptive sheet (from Player or Episode Detail) | Previews the rendered episode card and shares a validated publisher episode page when available; otherwise shares card + details without exposing the enclosure. Offers Copy Link only for safe resolved pages, plus the iOS-family **Review in Apple Podcasts** show action. |
| **Podcast Share** | `PodcastShareSheet` | Adaptive sheet (from Podcast Detail or Podcast Settings) | Shares the podcast's artwork, title, creator and description. It never substitutes the newest episode or exposes the RSS feed URL. Includes the same iOS-family **Review in Apple Podcasts** action. |
| **Up Next** | `QueueSheetView` | Sheet | The playback queue — the next episode plus the priority-ordered list of what plays after. Sheet title is "Up Next" (internal struct remains `QueueSheetView`). Episode/show/metadata text, artwork, rank/play markers, Video/Explicit indicators, expanded descriptions and shortcut buttons share Podcast Detail's live container-responsive row bands. Partially played rows show remaining time; a positive final minute is rendered as `59s`…`1s left remaining`, never `0m left remaining`. The shared formatter also governs all other iOS-family and tvOS episode-list runtime metadata. Tapping an episode title expands the row to reveal its full description plus two purple circular glass buttons at the bottom-right: `list.bullet` (opens that podcast's **Podcast Detail** page, closing Up Next) and `gearshape` (opens that podcast's **Podcast Settings** page, closing Up Next). Both use the staged-ID "replace Up Next" pattern in PlayerView. Swipe actions are animated with matched haptics: Play Next/Last glide the row to the top/bottom (directional badge + pop), Archive slides it into an archive box and closes the gap. See DESIGN.md `QueueAction-Animation`. |
| **Sleep Timer** | `SleepTimerSheetView` | Sheet | Set a timer to stop playback after a fixed duration or at the end of the current episode. |
| **Downloads** | `DownloadsView` | Page | Download activity in three card sections: Downloading (progress bar in ≥1% steps, Resume/Retry Now + archive controls — controls are fixed-size so long progress text truncates instead of squashing buttons), Downloaded on Device (file sizes, archive), and Recently Archived (re-download button). **Waiting to retry** appears only when a concrete retry task owns the next attempt; terminal or ownerless work exposes **Retry Now** immediately. Opening the page logs aggregate state counts for diagnosis and is not itself a recovery trigger. Small Video and Explicit indicators use icon-only styling with no glass capsule. |
| **App Settings** | `SettingsView` | Page | Global app configuration — Release Radar (fully automatic learned timing; no sensitivity control), Auto Archive (run-now, activity audit, and global default rules seeded into new subscriptions), download behaviour, controls, global Default Playback, notifications, OPML import/export, private iCloud Sync, and near-bottom Contact actions for the support website and the iOS-family public TestFlight beta. iCloud Sync starts On only for fresh installs; upgrades preserve both explicit choices and the historical Off fallback when an older settings file has no sync key. Default Playback includes Stereo/Mono Audio; Stereo is the factory default, and the selected value seeds future subscriptions without changing existing podcasts. No paid sync tier or external relay setting exists. CloudKit subscription settings are UUID-authoritative: historical records sharing a feed URL cannot overwrite the active subscription identity. The Default Playback section mirrors the per-podcast trim controls exactly, including the standard menu-card background, compact minute/second text, and debounced minus/plus adjustment rows. |
| **Auto Archive Activity** | `AutoArchiveActivityView` | Page (inside App Settings → Auto Archive) | Newest-first local audit of automatic archive decisions. Each card shows episode, podcast, exact archived date/time, responsible rule (After Playing, Inactive Episodes, or Episode Limit), the configured threshold, and the measured age when archived. Records begin after this feature is installed; the bounded local store retains the latest 500 events. |
| **Notification Settings** | `NotificationSettingsView` | Page (inside App Settings) | Settings-style Form with distinct **New Subscriptions**, **Listening Recaps**, and **Podcasts** headings. The new-episode switch is On for fresh installs and is snapshotted only by subscriptions added after the choice; it never changes or gates existing podcasts. Listening Recaps opens its weekly/monthly/yearly sheet (weekly On for fresh installs). Existing subscriptions retain independent artwork toggles plus Enable All / Disable All. Shows a permission banner with an iOS Settings deep link when authorization is denied. |
| **Feed Refresh Schedule** | `FeedRefreshScheduleView` | Page (inside App Settings → Release Radar) | Read-only diagnostic table of every **active** subscription (Inactive excluded) and the Release Radar schedule auto feed-refresh uses for it: learned profile kind + confidence, current window state, the recurring "watches around…" pattern, the next concrete expected window (+ countdown), and the in-window recheck interval. Grouped by publish frequency (Watching now / soon · Hourly · Daily – Multiple Episodes · Daily · Several Times a Week · Weekly · Still learning), sorted alphabetically within each group; makes clear when auto feed refresh **will** and **won't** look for new episodes. Each row has a **Diagnostics** button (opens that feed's **Release Radar Data** screen) and a **Rebuild Prediction** button that fetches the feed's last 100 episodes' publish dates **and times** into the learner (learning-only — no episodes are added to the library, and episodes skipped by Download Filters are excluded) to form a stronger expected-window prediction. A toolbar **export** button (ShareLink) shares a plain-text diagnostic dump of every active subscription — the same filter-eligible data as each podcast's **Release Radar Data** screen — for offline trend analysis. |
| **Listening Recaps** | `RecapSettingsView` | Sheet | Weekly / monthly / yearly listening-summary notifications (weekly on for new users; monthly and yearly off; delivered ~9am). Reached from the bell button in the **Stats** toolbar and from **Notification Settings**. Enabling any toggle requests notification permission and schedules a recurring local notification that deep-links into the Stats "Last" view. |
| **Listening History** | `ListeningHistoryView` | Page (Menu) | Historical episode-outcome log grouped by event date, with a 60-second playback threshold. Rows use the canonical subscription episode-list geometry: 44pt artwork, subheadline-semibold episode title, caption podcast name and metadata, plus the shared `EpisodeStatusPill`. The pill reflects the recorded historical outcome (Played, Archived, Paused; Playing only while an unresolved entry is currently audible), not a later library-state change. Metadata identifies the event and exact local date/time: Completed, Manually Archived, Auto Archived, legacy Archived, or Last listened. Resolved rows retain the same four swipe positions and behavior as Podcast Detail: Play / Play Next on the leading edge, and a state-driven Download/Archive/Unarchive action plus Play Last on the trailing edge. Actions download first when required, and the standard animated purple progress bar appears beneath a row during download. |
| **Stats** | `StatsView` | Page (inside Menu, or direct from recap notification) | Listening stats over a selectable period (7 Days / displayed month / displayed year / Lifetime — all calendar-anchored, resetting at the start of each period; the selected month and year pills follow the **This / Last** bar, e.g. "July" → "June" and "2026" → "2025"). A distinct solid **This / Last** bar below the pills switches Week/Month/Year to the previous concluded period (hidden on Lifetime or when that period has no data, except recap notification deep links still open their intended Last view). Sections: time listened, time saved, episodes finished, streak, listening heatmap (or monthly trend chart), 24-hour listening clock, top shows, Shows You're Drifting From (This mode only), and time-saved breakdown. Time-based figures use elapsed wall time on iOS and tvOS regardless of playback speed. Imported legacy totals are included in Lifetime and any calendar range that wholly contains their known interval, with an explanatory note where those totals cannot be plotted by month. Download-Filter Skipped episodes are excluded from drifting-show calculations; manual downloads remain eligible. Tapping a Top Shows or drifting-shows row expands an inline detail card; its finished count uses durable per-show daily counters with retained-history/completed-episode recovery for older buckets rather than relying solely on the capped history projection. A bell button in the toolbar opens the **Listening Recaps** sheet. |
| **Sleep Schedule** | `SleepScheduleView` | Page (inside Menu) | Recurring nightly sleep timer: on/off toggle, active-hours window (may span midnight), and prompt duration (10/15/20/40/60 min or End of Episode). During the window, after the duration a soft chime asks "Are you still listening?" over the continuing playback — any transport command confirms; no response within 60 s fades playback out and rewinds to where the chime started. The end of Active Hours is a hard boundary: pending countdowns and live prompts are dismissed, their notification is cleared, and ordinary playback continues without further prompts. |
| **Menu** | `MenuSheetView` | Sheet | Slide-up menu from the Subscriptions toolbar. The single gateway to Discover (top item — dismisses the Menu and pushes the Discover page), Stats, Sleep Schedule, Listening History, Downloads, App Settings, and Support (last item). Its background and grouped link surface match Sleep Schedule's native grouped palette. The root Menu reserves its lower region for a rich responsive Mini Player whenever an episode is loaded: the links scroll above it, its closely grouped transport controls operate playback, and tapping its remaining surface returns to the permanent Player. Pushed Menu destinations replace this rich card and use the standard persistent mini-player. (Find Podcasts lives behind the + button only.) |
| **Support** | `SupportView` | Page (inside Menu, last item) | In-app User Guide. A drill-down list of topic sections (icon + title + summary), including CarPlay support; tapping one pushes a native dark-themed detail page (`SupportSectionView`) rendering paragraphs, callouts, tables, status pills, and swipe-action cards. Content lives in `SupportContent.swift` and mirrors the website Support page. |
| **Acknowledgements** | `AcknowledgementsView` | Page (inside App Settings) | Credits for open-source libraries used in the app. |
| **Diagnostic Log** | `DiagnosticLogView` | Page (inside App Settings) | Internal support output for playback, audio routes, foreground/background feed scheduling, downloads, Auto Archive, CloudKit, resources and UI stalls. **Enable Diagnostic Log** activates normal outcome-focused diagnostics and five-minute resource/UI monitoring. Optional **Detailed Refresh Trace** adds per-feed candidates, item boundaries, 304 and no-op decisions for short Release Radar investigations. Normal mode retains `feed.refreshAll.plan`, `feed.cycleSummary`, backlog age, scheduling and `background.wakeSummary`. Exports are redacted and include build/mode/dropped-entry metadata. |
| **Now Playing & Up Next Widget** | `NowPlayingUpNextWidget` | Home Screen / Lock Screen / StandBy system surface | Small, medium, and large Home Screen layouts use a textured very-dark-charcoal glass surface and show downloaded current/Up Next episodes with local, centred-square artwork and interactive, always-visible purple glass-style playback controls. iOS 26+ uses native Liquid Glass for the background sheen and iOS 17–25 a matching static fallback; native glass is intentionally excluded from App Intent Toggle labels because WidgetKit can suppress those controls. 16:9 video thumbnails are cropped without distortion or overflow. Circular/rectangular accessories retain system backgrounds and show live count or privacy-sensitive current/next metadata. Links enter Player, the existing Up Next sheet, Episode Detail, or Discover through validated `autohop://` routes. It is not part of `NavigationPath`; WidgetKit owns presentation. |

---

## Navigation Structure

```
Player (PlayerView — permanent NavigationStack root, never torn down)
├── [Sheet] Up Next (QueueSheetView)           ← expanded-row gear opens Podcast Settings (replaces this sheet)
├── [Sheet] Sleep Timer (SleepTimerSheetView)
├── [Sheet] Audio Controls (AudioControlsSheetView)
├── [Sheet] Episode Share (EpisodeShareSheet)
├── [Sheet] Podcast Share (PodcastShareSheet)
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
    │   └── Search (PodcastSearchView — pushed page)   ← only entry point to Search
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

### Widget external entry routes

- `autohop://player` → pop to the permanent Player root.
- `autohop://up-next` → pop to Player and present its existing Up Next sheet.
- `autohop://episode/<subscription-id>/<encoded-stable-key>` → resolve the
  identity against the live store, then push Subscriptions → Episode Detail.
- `autohop://discover?source=widget` → push Subscriptions → Discover.

Malformed, credentialed, unknown, stale, or oversized routes are rejected and
logged. Widget playback is an App Intent rather than a route.

### First-run onboarding chrome (not in the tree above)

These appear only for a brand-new user and layer over the normal navigation rather than living in the page tree (see FEATURES.md §18, DESIGN.md "Onboarding — First-Run Components"):

- **Welcome** (`WelcomeView`) — full-screen cover over the launch splash on first run.
- **Starter Packs** (`StarterPacksView`) — sheet from the empty Subscriptions state / Discover first-run banner.
- **You're All Set** (`FirstSubscribeCard`) — sheet on the first deliberate subscribe.
- **Getting-Started checklist** (`GettingStartedChecklist`) — dismissible card pinned at the top of the Subscriptions (Priority Stack) page.
- **Coach marks** (`CoachMarkOverlay`) — high-contrast white/black contextual cards with prominent top and bottom close actions. Each card is owned by its requesting page and automatically disappears on navigation without being falsely marked read. Coverage: Discover, Priority Stack, Podcast Detail actions, Player panels/audio controls, Up Next, Stats, Downloads, Sleep Schedule, global Settings and per-podcast automation.
- **Onboarding toast** — transient confirmation capsule above the mini-player (e.g. after OPML import).

### Navigation rules (NavRules)

Every screen uses exactly one of three exit patterns:

1. **Pushed page** — brand back chevron (`chevron.left.circle.fill`) top-left; nothing else in that corner. Back always calls the ambient SwiftUI dismiss action so it removes the nearest destination and preserves nested parents; a child must never directly mutate RootView's outer path. `MiniPlayerBar` docks at the bottom (hidden during Subscriptions reorder mode); tapping it deliberately clears the complete path to the Player.
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
# Apple TV Setup and Demo Pages (Version 1.6)

<!-- AI CONTEXT — tvOS first-install page map. The demo is a separate local
experience, not fixture data inserted into personal-library pages. -->

- **Setup Required:** appears when no personal library exists, iCloud reports a
  recoverable problem, or bootstrap remains loading at the first-usable-screen
  deadline. Primary focus is Explore Demo Library; Discover, bounded retry and
  Settings remain available. Completed states contain no indefinite spinner.
- **Demo Home:** Continue Listening plus an interactive synthetic Up Next list.
- **Demo Subscriptions:** four priority-ranked synthetic shows and episode lists.
- **Demo History:** completed/archived synthetic activity with replay.
- **Demo Player:** private bundled-media AVPlayer with audio/video, pause, seek,
  playback speed and Finish Demo Episode. A persistent Demo label is visible.
- **Demo Settings:** privacy explanation, Reset Demo Library and Exit Demo.

# Apple TV System Top Shelf (Version 1.6)

<!-- AI CONTEXT — System-owned tvOS Home Screen surface, not an in-app page. -->

- **Currently Playing/Watching:** the live episode is reserved first with
  progress, even when it sits below the visible Up Next queue cap.
- **Continue Listening:** idle fallback containing one playable, meaningfully
  started episode with progress; omitted within the final minute.
- **Up Next:** up to ten total items, exact TV Home order and poster artwork;
  the featured episode is deduplicated.
- **Select and Play/Pause:** cold/warm deep links both use normal exact-identity
  playback and resume behaviour.
- **Unavailable:** improved static purple banner with no fake controls.

Apple TV Home's in-app **Up Next** rows show `X left` for partially played
episodes and total runtime for untouched episodes, matching the iOS page. A
positive value under one minute uses seconds instead of an inaccurate `0m`.

# Apple TV Settings and Diagnostics (Version 1.6)

<!-- AI CONTEXT — User-readable health first, developer evidence second. -->

- **Apple TV Home Screen:** publisher status, eligible episodes, App Group,
  snapshot and extension outcome plus Refresh Top Shelf Now.
- **Performance:** launch state, uptime, memory, thermal pressure and detected
  main-thread hangs.
- **Export:** prepares a bounded redacted local file for retrieval through
  Xcode; Autohop never uploads it.
- **Navigation:** read-only rows participate in focus movement, so the page
  scrolls progressively rather than jumping between distant action buttons.
- **Top Shelf fault isolation:** shows separate shared-container-root and
  Library/Caches write outcomes, retry pause, and suppressed attempt count.
- **Performance accuracy:** shows how many suspension gaps were excluded from
  foreground hang results.
- **Artwork provenance:** reports how many current Top Shelf images came from
  the TV disk cache, a fresh download, or the branded placeholder.
