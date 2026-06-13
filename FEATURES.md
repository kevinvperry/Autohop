# Autohop — Feature & Settings Reference

**Source of truth for all feature descriptions, setting labels, defaults, and behaviour.**
Used to keep website pages, App Store copy, and in-app help text in sync and accurate.

> **Page names & navigation structure** → see [`PAGES.md`](PAGES.md)

> When any Swift model, view, or setting changes, update this file first, then propagate to
> the website support page and any other consumer.

---

## Table of Contents

1. [Priority Stack](#1-priority-stack)
2. [Find Podcasts (Search) & Discover](#2-find-podcasts-search)
   - [Search](#21-search)
   - [Podcast Preview Page](#22-podcast-preview-page)
   - [Subscribe Button Behaviour](#23-subscribe-button-behaviour)
   - [Browse Subscriptions](#24-browse-subscriptions)
   - [Recently Viewed](#25-recently-viewed)
3. [Queue](#3-queue)
4. [Player](#4-player)
5. [Audio Controls](#5-audio-controls)
   - [Playback Speed](#51-playback-speed)
   - [Trim Silence](#52-trim-silence)
   - [Vocal Boost](#53-vocal-boost)
   - [Shared Listening](#54-shared-listening)
6. [Chapters](#6-chapters)
7. [Downloads](#7-downloads)
8. [Sleep Timer](#8-sleep-timer)
   - [Sleep Schedule](#81-sleep-schedule)
9. [Video Podcasts](#9-video-podcasts)
10. [Per-Podcast Settings](#10-per-podcast-settings)
    - [Podcast section](#101-podcast-section)
    - [Playback section](#102-playback-section)
    - [Automation section](#103-automation-section)
    - [Auto Archive section](#104-auto-archive-section)
    - [Chapter Filter section](#105-chapter-filter-section)
    - [Feed section](#106-feed-section)
    - [Danger section](#107-danger-section)
11. [Listening History](#11-listening-history)
12. [Stats](#12-stats)
13. [OPML Import & Export](#13-opml-import--export)
14. [Notifications](#14-notifications)
15. [App Settings](#15-app-settings)
    - [Release Radar](#151-release-radar)
    - [Auto Archive](#152-auto-archive)
    - [Downloading](#153-downloading)
    - [Controls](#154-controls)
    - [Subscriptions](#155-subscriptions)
    - [Storage](#156-storage)
    - [About](#157-about)
16. [Support (In-App User Guide)](#16-support-in-app-user-guide)

---

## 1. Priority Stack

**What it is:** The main screen of the app. A ranked list of every podcast the user subscribes to.

**How it works:** Each subscription has a `priorityRank: Int` (1 = highest priority). Autohop builds the playback queue by walking down this list in rank order, picking the next downloaded, unplayed episode from each podcast. The queue advances automatically when an episode finishes — no manual intervention required.

**Reordering:** Drag-and-drop in Reorder mode (toolbar toggle). Priority rank can also be edited numerically via the individual podcast settings page.

**Episode status pills:** Each row shows a colour-coded status pill for the podcast's latest episode.

| State | Colour | Meaning |
|---|---|---|
| Unplayed | Gray | Downloaded and ready to play, not yet started |
| Queued | Teal | Sitting in the automatic queue |
| Paused | Yellow | Partially played but not currently playing |
| Playing | Green | Currently playing |
| Played | Blue | Listened to completion (natural end, Skip End, or Mark Played). Completion wins permanently: the pill stays Played even after the episode is later archived (manually or by Auto Archive). Tracked by `Episode.wasCompleted`. |
| Archived | Purple | Archived (removed from queue) before being listened to completion |
| Inactive | Orange | Excluded from auto feed refresh (finished show) |

**Navigation to per-podcast settings:** Tap a podcast row → episode list view → gear icon (⚙) in the top-right toolbar.

**Toolbar buttons (left to right):**
- Return to Player (play.circle.fill)
- Hamburger menu (☰) → Discover, Downloads, Listening History, Stats, Import OPML, Settings
- Reorder toggle ("Reorder" / "Done")
- Refresh all feeds (arrow.clockwise)
- Add Podcast / Discover (+) — opens the Discover charts sheet (search lives inside it)

---

## 2. Find Podcasts (Search)

**What it is:** A full-screen sheet for finding and subscribing to podcasts. The primary way to add new podcasts to Autohop.

**Access:** Tap the search shortcut at the top of the **Discover** page (the only entry point to Search).

---

### 2.1 Search

**How it works:**
1. User types a search term. Results appear automatically after a short debounce (400ms).
2. Results are fetched from the iTunes podcast catalog — no account or API key required.
3. Tapping a result opens the **Podcast Preview** page.

**Search states:**
- **Idle** — prompt to search + Recently Viewed history list (if any) + "Enter RSS URL" button
- **Loading** — spinner while results are fetching
- **Results** — list of matching podcasts; "Enter RSS URL" link at the bottom of the list
- **Empty** — `ContentUnavailableView` when the search returns no matches
- **Failed** — error message if the network request fails

**RSS URL entry:** Available from both the idle state and the results list footer. Navigates to the Add RSS Feed screen for users who have a direct feed URL.

**Results filtering:** Podcasts with no RSS feed URL (Apple Podcasts exclusives) are silently excluded from results.

**Already subscribed:** If the user taps a result for a podcast they are already actively subscribed to, they are redirected straight to the existing Podcast Episodes page — no duplicate subscription is created.

---

### 2.2 Podcast Preview Page

Tapping a search result (or a Recently Viewed row) opens the Podcast Preview page. The RSS feed is fetched immediately on open and a **browse subscription** is created automatically (see §2.4). The episode list is fully interactive from first load.

**Page structure:**
1. **Header** — 120×120pt artwork, title, explicit/video pills, description (2-line truncated), author · categories
2. **Subscribe button** — full-width, purple, always labelled "Subscribe". See §2.3 for behaviour.
3. **Episodes section** — "Episodes" heading + waveform icon, followed by the episode list in a card.

**Episode list:**
- Shows up to 50 most recent episodes on first load.
- Full status pills (Unplayed, Queued, Paused, Playing, Played, Archived), download progress bar, date, duration — identical to the Podcast Episodes page.
- Every episode row is a `NavigationLink` to Episode Detail.
- **Load Older Episodes** button appears when 50+ episodes are loaded. Fetches full episode history.

**Episode swipe actions** — identical to Podcast Episodes page:
- Leading: **Play** (green), **Play Next** (blue)
- Trailing: **Archive / Unarchive** (purple), **Play Last** (orange)

---

### 2.3 Subscribe Button Behaviour

The Subscribe button on the Podcast Preview page always shows the label "Subscribe". Its action depends on the current subscription state for that feed:

| Current state | Action |
|---|---|
| No subscription exists | Creates a new active subscription, inserts at top of Priority Stack |
| Browse subscription exists (auto-created, inactive) | Activates it, clears browse status, moves to top of Priority Stack |
| Already actively subscribed | User is redirected at search level — Subscribe button is never shown |

---

### 2.4 Browse Subscriptions

When a user opens a Podcast Preview page, Autohop silently creates a **browse subscription** in the background. This enables the fully interactive episode list from first load without requiring the user to explicitly subscribe.

**Browse subscriptions are invisible to the user** — they do not appear in the Priority Stack or anywhere else in the app. They are only visible in the Search sheet's Recently Viewed history.

**Behaviour:**
- Marked `excludeFromAutoFeedRefresh = true` (not polled for new episodes)
- Stored with a `browseDate` timestamp
- Retained for **30 days** from the most recent visit
- On revisit: episodes are refreshed (new content appears) and the 30-day clock resets
- **Automatically deleted** after 30 days if no episode has been played or downloaded
- Converted to a full active subscription when the user taps **Subscribe**

**If a user plays, queues, or archives an episode** from the preview page without subscribing, the browse subscription is retained (episodes have been acted on) but the podcast remains invisible in the Priority Stack until the user explicitly subscribes.

---

### 2.5 Recently Viewed

The Search idle state shows a **Recently Viewed** section listing all browse subscriptions, sorted by most recent visit.

Each row shows:
- Podcast artwork (44×44pt)
- Title and author
- "Viewed [date]" caption

Tapping a row navigates back to the Podcast Preview page for that podcast, refreshing episodes and resetting the 30-day clock.

---

### 2.6 Discover (Charts)

**What it is:** A full-screen sheet for browsing Apple Podcasts charts — the exploration counterpart to Search.

**Access:** Tap the `+` button on the Priority Stack toolbar, or **Discover** (top item) in the hamburger menu (☰). Discover is the parent page of Podcast Search.

**Page structure (top to bottom):**
- **Search shortcut** — a search-field-shaped button that opens the unchanged Podcast Search sheet
- **Top Podcasts hero** — the storefront's Top 8 as big sideways-paging cards (purple gradient, oversized ghosted rank numeral, artwork, rank pill, title/artist/genre)
- **Genre rails** — horizontally scrolling Top-15 shelves for Comedy, News, True Crime, Society & Culture, Business, Sports, Health & Fitness, Technology, Science, and TV & Film; a rail that fails to load is simply omitted
- **Country spotlight heroes** — two additional "Top Podcasts · <Country>" hero carousels (identical design to the top hero) woven into the rails: spotlight A appears between Sports and Health & Fitness, spotlight B at the very end. They show fixed storefronts — A = United States (or UK if the user's country is already US); B = United Kingdom (or Australia if the user's country is UK, and also Australia when A has taken UK, i.e. a US user). `DiscoverViewModel.spotlightCountries(selected:)` resolves the pair so neither duplicates the user's country or each other. Each spotlight loads independently (omitted on failure, never blocking the page) and resolves taps against *its own* storefront so the show opens reliably.

**Country picker:** Toolbar-leading menu ("🇦🇺 Australia ▾"). Defaults to the device's region (`Locale.current.region`, no location permission needed), falls back to the US, and persists the user's manual choice (`discoverCountryCode` in UserDefaults). 21 storefronts offered.

**Data source:** Apple's public chart feeds — the Marketing Tools v2 feed for the Top 8 and the legacy iTunes RSS genre endpoint for the rails. No API key or account. Responses are cached on disk for 12 hours (`Caches/discover-charts`), so the page opens instantly on revisit. Pull to refresh re-fetches.

**Tapping a chart entry:** The iTunes Lookup API resolves the show's RSS feed URL (spinner overlays the tile), then routing matches Search exactly — already-subscribed shows go straight to their Podcast Episodes page; everything else opens Podcast Preview, which creates the invisible 30-day browse subscription (§2.4) with fully interactive Play / Play Next / Play Last rows. Apple-exclusive shows with no public RSS feed show a "Not Available" alert.

---

## 3. Queue

**What it is:** A sheet view showing the current automatic playback order — all downloaded, unplayed episodes sorted by podcast priority rank, with any manual overrides applied on top.

**Manual overrides:**
- **Play Next** (blue) — promotes an episode to the front of the queue. Inserted at position 0, ahead of all other episodes.
- **Play Last** (orange) — demotes an episode to the end of the queue.
- Overrides are cleared when the episode is played or archived.

**Swipe actions:**
- Leading edge: Play (green), Play Next (blue)
- Trailing edge: Archive (purple), Play Last (orange)
- `allowsFullSwipe: false` on both edges — full swipe is disabled intentionally to prevent accidental actions.

**Pin badges:** Episodes with a Play Next or Play Last override show a pin badge above the duration — blue for Play Next, orange for Play Last.

---

## 4. Player

**What it is:** The full-screen playback view. Permanent root of the navigation stack — always accessible.

**Panels:** Three horizontally swipeable panels:
1. **Now Playing** — artwork, episode title, podcast name, scrubber, transport controls (skip back, play/pause, skip forward), audio controls button, sleep timer button, queue peek.
2. **Details** — episode description and metadata.
3. **Chapters** — chapter list. Only shown if the current episode has chapters.

**Top bar:** leading nav icon (pushes Subscriptions) · **Sleep Schedule indicator** · panel tab strip · Queue count pill. The Sleep Schedule indicator (`bed.double.fill` purple pill, matching the audio-row action buttons) appears next to the nav icon **only while inside the Sleep Schedule active-hours window**. It shows the whole minutes remaining until the next "still listening?" prompt while a countdown is running, and the icon alone when not counting (paused, idle, or End-of-Episode mode). Tapping it pushes the Sleep Schedule page (`AppRoute.sleepSchedule`).

**Transport controls:**
- Skip back: configurable duration (default 15s), applied globally in Settings
- Skip forward: configurable duration (default 30s), applied globally in Settings
- Both durations also controllable from Lock Screen and Control Centre

**Audio Controls button:** Opens `AudioControlsSheetView` — a dark card sheet with speed, trim silence, and vocal boost controls.

**Sleep Timer button:** Opens `SleepTimerSheetView`.

**Audio row (below the transport controls):** Sound Settings · Sleep Timer · AirPlay route picker (shows the current output name) · Share · Archive.

**Share:** Opens `EpisodeShareSheet` — previews a rendered share card (episode artwork, episode title, podcast name, Autohop branding) and exports it through the system share sheet together with the episode's audio URL.

**Archive:** Opens a confirmation sheet; on confirm, archives the currently playing episode, deletes its downloaded file, and advances to the next queued episode.

---

## 5. Audio Controls

Accessed via the audio controls button on the Now Playing panel. Dark card sheet. Changes take effect immediately during playback.

### 5.1 Playback Speed

**Per-podcast setting.** Stored in `PlaybackPreference.speed`.

| Property | Value |
|---|---|
| Range | 1.0x – 2.5x |
| Step | 0.1x |
| Default | **1.6x** |
| UI | − / value / + stepper |

**Rationale for 1.6x default:** A comfortable starting point that encourages users to explore speed control without being jarring on first use.

**Note:** Speed applies to the AVAudioUnitTimePitch node on the engine path, or AVPlayer's rate on the player path.

---

### 5.2 Trim Silence

**Per-podcast setting.** Stored in `PlaybackPreference.trimSilence`. Only active on **audio** episodes — never applied to video.

Uses an RMS-based silence detection algorithm ported from Pocket Casts (`SilenceDetector.swift`, using `vDSP_rmsqv` from Accelerate). Silent gaps are removed with fade-out/fade-in crossfades at each join point. The last 5 seconds of an episode are never trimmed.

| Level | `minRMS` threshold | Min gap (frames) | Effect |
|---|---|---|---|
| Off | — | — | No processing |
| Low | 0.0055 | 20 | Removes longer pauses only |
| Medium | 0.00511 | 16 | Moderate gap removal |
| High | 0.005 | 4 | Aggressive — removes brief pauses |

**Default:** Low (applied via first-launch migration `trimSilenceLowDefaultMigrated`).

**UI:** Toggle to enable/disable. When on, an animated segmented picker appears: Low / Medium / High.

---

### 5.3 Vocal Boost

**Per-podcast setting.** Stored in `PlaybackPreference.vocalBoostLevel`. Applied via AVAudioEngine on the engine path. For video or when both Vocal Boost and Trim Silence are off, AVPlayer is used instead (no engine path).

All non-off levels enable AVAudioSession's spoken audio mode. The processing chain has three stages — high-pass filter, dynamic compressor, peak limiter — each of which is active or bypassed depending on the level.

| Level | High-pass (180 Hz) | Dynamic compression | Limiter pre-gain | Effect |
|---|---|---|---|---|
| Off | bypassed | bypassed | bypassed | No processing |
| Light | active | bypassed | +4 dB | Removes low-end rumble, small loudness bump. Minimal processing. |
| Standard | active | active | +8 dB | Removes rumble, evens out quiet/loud passages, moderate loudness boost. |
| Strong | active | active | +11 dB | Full chain at maximum gain. Clearest and loudest result. Mirrors the Pocket Casts voice processing algorithm. |

**Default:** Strong (applied via first-launch migration `vocalBoostLevelMigrated`).

**Dynamic compressor settings (Standard and Strong):** threshold −41 dB, headroom 40 dB, attack 50ms, release 200ms. Lifts quiet passages without over-compressing.

**UI:** Toggle to enable/disable. When on, an animated segmented picker appears: Light / Standard / Strong.

---

### 5.4 Shared Listening

**Global temporary override** for group environments (car stereo, speakers with other people). Stored in `AppSettings.sharedListeningActive` / `AppSettings.sharedListeningSpeed` — per-podcast settings are never modified.

> **Marketing note:** Unique to Autohop — Apple Podcasts, Pocket Casts, and Overcast have no one-tap global speed override for group listening; users must manually change (and later restore) each show's speed. Promoted on the website feature grid and comparison table.

While active, **every** podcast plays at the chosen Shared Listening speed with **Trim Silence forced off**. Vocal Boost is unaffected. Deactivating instantly returns all podcasts to their own settings.

| Property | Value |
|---|---|
| Speed options | 1x / 1.1x / 1.2x / 1.3x |
| Default on activation | **1x** (always resets to 1x each time it is switched on) |
| Persistence | Survives app relaunch until explicitly switched off |

**UI:** Top row of the Audio Controls sheet — toggle plus animated segmented speed picker when on. While active, the per-podcast Speed and Trim Silence rows below are greyed out (disabled), and the sound-controls button in the player's audio row renders **white** (mirroring the active Sleep Timer button). Changes apply live to the playing episode via `AppState.effectivePreference(for:)`, which all playback paths read instead of raw `playbackPreference`.

---

## 6. Chapters

**Availability:** The Chapters panel in the player is only shown when the current episode has embedded chapter data.

**Display:** List of chapters with title and position. The currently playing chapter is highlighted and cannot be disabled.

**Skipping chapters:** Tap a chapter row to toggle its skipped state (not a swipe action). Skipped chapters are automatically bypassed during playback — the player jumps to the next enabled chapter when it reaches a disabled one.

**Chapter filter (per-podcast, per-position):** Disabled chapters are stored by position index in `ChapterFilter` on the `Subscription` model. Skips are **position-based and apply to all future episodes** of that podcast. This means disabling chapter 1 permanently skips the first chapter of every future episode — the primary use case being recurring show intros, sponsor reads, or outros that always appear in the same chapter slot.

**Editing chapter filter:** Available in the individual podcast's settings page (gear icon from episode list), under "Chapter Filter". Only shown when the latest episode has chapters.

---

## 7. Downloads

**What it is:** A view showing download activity and recently archived downloaded episodes.

**Download-first playback:** Autohop only plays files already on the device — no streaming. Background downloads keep the queue stocked automatically as new episodes are fetched.

**Auto-download:** New episodes discovered during a feed refresh are automatically queued for download (`AppState.refreshSubscription()` triggers download on new episode detection).

**Download states:** `notDownloaded` → `queued` → `downloading` → `downloaded` / `failed`

**Manual download:** Episodes not yet downloaded show a "Download" button in the episode list row.

**Download controls (global, in Settings):**
- Download over WiFi (default: on)
- Download over cellular (default: on)

---

## 8. Sleep Timer

**Access:** Sleep timer button on the Now Playing panel.

**Two modes:**

### Duration mode
Six presets in a 3×2 grid:

| Preset |
|---|
| 5 min |
| 10 min |
| 15 min |
| 30 min |
| 45 min |
| 1 hour |

While active: shows a countdown display with a **+5 min** extend button and a **Cancel** button.

### End of N Episodes mode
A stepper (range: 1–10, default: 1) lets the user choose how many episodes to finish before sleep. Tap **Set** to start. While active: shows episodes remaining with a **Cancel** button.

**Sheet height:** 380pt when inactive (preset grid + episode row). 240pt when a timer is active.

### 8.1 Sleep Schedule

**Access:** Menu → Sleep Schedule (`SleepScheduleView`). The recurring nightly counterpart to the one-shot Sleep Timer. Logic lives in `Playback/SleepScheduleService.swift`, owned by `AppState`.

> **Marketing note:** Sleep Schedule is an Autohop exclusive — no recurring/scheduled sleep timer with a "still listening?" check exists in Apple Podcasts, Pocket Casts or Overcast. It appears as a unique feature card and comparison-table row on the kevmarl.com promo page and has its own section in the support guide.

**Settings (persisted in `AppSettings`):**
- **Toggle** — `sleepScheduleEnabled` (default off). Runs every night when on.
- **Active Hours** — start/end time pickers (`sleepScheduleStartMinutes`/`sleepScheduleEndMinutes`, minutes from midnight; default 9:00pm–6:00am). The window may span midnight; start == end means always active.
- **Ask Every** — duration presets 10 / 15 / 20 / 40 / 60 minutes (default 20) plus **End of Episode** (stored as `sleepScheduleDurationMinutes = 0`).

**Behaviour:**
1. The schedule **arms** — it never self-starts audio. Whenever playback starts (audio or video) inside the window, the cycle begins.
2. After the chosen duration of playback (or at the episode boundary in End of Episode mode), a soft singing-bowl-style chime asks "Are you still listening?" — **playback keeps going**; the chime (C4 fundamental with quiet partials, slow ~0.5 s attack, ~7 s decay) plays over it at 0/20/40 s inside a single 60 s in-memory WAV via `AVAudioPlayer` (keeps the audio session rendering so the app isn't suspended while waiting; a 75 s backup `Task` covers audio failure). In End of Episode mode the queue still advances to the next episode under the chime.
3. **Any transport command is "yes"** — play/pause (lock screen, earbud tap, headphone remote), skip forward/back, scrubbing, the oversized on-screen overlay button in `PlayerView` (shown for the screen-on/video case; a deliberately large `minHeight: 160` "Still Listening" target for half-asleep tapping), or the **"Still Listening" action on the lock-screen notification** (see below). The cycle restarts; a pause press both confirms and pauses (the re-armed countdown freezes until resume).
4. **No response within 60 s = asleep.** Playback fades out over ~2.5 s, pauses, and **rewinds to where the chime started** — the last point plausibly heard, persisted as the morning resume position (start of the auto-advanced episode in End of Episode mode). The session ends; the schedule re-arms on the next playback start inside the window.
5. **Manual Sleep Timer overrides:** setting the regular Sleep Timer suspends the schedule for the rest of that session (`suspendForSession`, checked on every 0.5 s tick).
6. The countdown only advances while playing — pausing freezes it. Sessions that started inside the window keep cycling past the end time mid-cycle.

**Lock-screen "Still Listening" notification:** When the prompt fires, Autohop also posts a local notification (`NotificationService`) titled "Are you still listening?" carrying a **"Still Listening" action button**. It's a background action (empty options) so tapping it on the lock screen confirms **without unlocking or opening the app** — routed through the notification-centre delegate to `userResponded()`, exactly like a transport command. The notification uses `interruptionLevel = .timeSensitive` so it breaks through Sleep Focus / Do Not Disturb at night (requires the **Time Sensitive Notifications** capability on the app target). It is cleared automatically whenever the prompt ends (confirmed, timed out, suspended, or reset) via the service's `onPromptDismissed` callback.

**Player indicator:** While inside the active-hours window, the player top bar shows a Sleep Schedule pill (see §4) with the minutes remaining until the next prompt.

---

## 9. Video Podcasts

**Support:** Full audio and video podcast support. `Episode.mediaKind` is either `.audio` or `.video`.

**Playback path:** Video episodes always use AVPlayer (the `VideoPlayer` SwiftUI view requires it). Vocal Boost and Trim Silence are not available for video episodes — the engine path is audio-only.

**Landscape:** Full-screen video unlocks landscape orientation via `VideoOrientationController`.

**Chapters:** Chapter navigation works on video episodes.

**Badges:** Video episodes show a "VIDEO" badge in episode list rows and on the episode detail view.

---

## 10. Per-Podcast Settings

**Access:** Priority page → tap podcast row → episode list → gear icon (⚙) in top-right toolbar.

The settings page is titled with the podcast name and groups settings into sections:

---

### 10.1 Podcast section

| Setting | Description |
|---|---|
| Title | The display name of the podcast. Tap to edit. Edits are local — does not affect the RSS feed. |
| Priority rank | The podcast's position in the Priority Stack. Tap to edit numerically. Changing rank immediately reorders the list. |
| Author | Read-only. Pulled from the RSS feed. |

---

### 10.2 Playback section

All settings in this section are stored in `PlaybackPreference` on the `Subscription` model. Changes apply immediately if this podcast is currently playing.

| Setting | Options | Default | Notes |
|---|---|---|---|
| Playback speed | 1.0x – 2.5x (0.1x steps) | **1.6x** | A comfortable starting speed that encourages users to explore speed control. |
| Vocal Boost | Off / Light / Standard / Strong | **Strong** | See [Vocal Boost](#43-vocal-boost) for full chain description. |
| Trim Silence | Off / Low / Medium / High | **Low** | Audio episodes only. See [Trim Silence](#42-trim-silence). |
| Start skip | 0 – 300s (5s steps) | **0 (off)** | Automatically skips N seconds at the start of every episode. Measured in real file time, independent of playback speed. Primary use case: skipping recurring show intros or theme music. |
| End skip | 0 – 300s (5s steps) | **0 (off)** | Automatically skips N seconds at the end of every episode. Measured in real file time, independent of playback speed. Primary use case: skipping recurring outros or trailing ad reads. |

**Footer notes (shown in app):** "Vocal Boost lifts speech above music and background sound — Strong targets a −14 LUFS loudness goal for the clearest spoken audio. Trim Silence removes quiet gaps (audio episodes only)." and "Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically."

---

### 10.3 Automation section

| Setting | Default | Description |
|---|---|---|
| New episode notifications | **Off** | Sends a notification when a new episode is published. Off by default — users opt in only for shows they want to be notified about, to avoid unwanted interruptions. Requires the global notification toggle (Settings → Release Radar → Notification Settings) to also be on. |
| Exclude from Auto Feed Refresh | **Off** | When on, Autohop stops polling this podcast's RSS feed for new episodes. The podcast and its downloaded episodes remain in the library. Use case: finished/completed shows the user wants to keep but doesn't need updates from. |

---

### 10.4 Auto Archive section

Three independent rules. All stored in `AutoArchiveSettings` on the `Subscription` model. The archive pass runs at most every 30 minutes, or immediately on demand via Settings → Run Auto Archive Now.

| Rule | Setting name | Options | Default | Description |
|---|---|---|---|---|
| Rule 1 | Played Episodes | Never / After Playing / After 24h / After 2 Days / After 1 Week | **After Playing** | Archives a played episode immediately on completion, or after a delay. "After Playing" archives as soon as the episode finishes. |
| Rule 2 | Inactive Episodes | Never / 4h / 8h / 16h / 24h / 2 Days / 3 Days / 1 Week / 2 Weeks / 30 Days / 90 Days | **1 Week** | Archives unplayed episodes that haven't been touched (not played, not queued) within the set interval. Keeps feeds from accumulating stale backlog. |
| Rule 3 | Episode Limit | No Limit / 1 / 2 / 3 / 4 / 5 / 10 | **1** | Keeps only the N most recently published episodes, archiving older ones. Default of 1 keeps storage lean — the user always has the latest episode available. |

**Footer note (shown in app):** "Played Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives unplayed episodes that haven't been touched in the set time. Episode Limit keeps only the most recently published episodes, archiving older ones — the newest episode always downloads regardless. Auto Archive runs at most every 30 minutes."

---

### 10.5 Chapter Filter section

Only shown when the podcast's latest episode has chapter data.

| Behaviour | Detail |
|---|---|
| Toggle chapter | Tap a chapter row to enable/disable it. Currently playing chapter cannot be disabled. |
| Scope | Position-based. A disabled position is skipped in all future episodes of this podcast. |
| Primary use case | Permanently skip recurring chapters at a fixed position — show intros, sponsor reads, or outros that appear in the same chapter slot every episode. |

---

### 10.6 Feed section

| Field | Description |
|---|---|
| URL | The podcast's RSS feed URL. Read-only display. |

---

### 10.7 Danger section

| Action | Description |
|---|---|
| Unsubscribe | Removes the podcast and all its settings from Autohop. Downloaded episode files are not deleted — they remain on device until iOS cleans them up. Requires confirmation. |

---

## 11. Listening History

**Access:** Hamburger menu (☰) on the Priority page → Listening History. Also accessible from Settings → Subscriptions → Listening History.

**What it tracks:** Every episode the user has listened to, recorded in `ListeningHistoryStore` → `listening-history.json`.

**Minimum threshold:** Episodes where `listenedSeconds < 60 AND lastPositionSeconds < 60` are excluded from all lists. Episodes played or archived without at least 1 minute of actual playback are not shown.

### Stats header
Two summary cards at the top of the page:
- **Listening Time** — total hours and minutes across all recorded history entries that meet the minimum threshold.
- **Episodes** — total count of episodes with status `.played` or `.archived` that meet the minimum threshold (i.e., all finished episodes, including auto-archived ones that were genuinely listened to).

### History list
Episodes grouped by date: Today, Yesterday, then older dates (abbreviated format). Within each group, sorted most recent first. Each row shows:
- Podcast artwork
- Podcast name (uppercase caption)
- Episode title
- Status label + time listened + time remaining (if partially listened)

| Status | Meaning |
|---|---|
| Listened | Partially played — did not finish. Shows time remaining. |
| Played | Episode marked as played. |
| Archived | Episode was archived. |

### Search
Filters by episode title or podcast name. Results update as the user types. Same 60-second minimum threshold applies to search results. Search bar is always visible (`.navigationBarDrawer(displayMode: .always)`).

---

## 12. Stats

**Access:** Hamburger menu (☰) on the Priority page → Stats.

**What it is:** A lifetime summary of the user's listening activity and time saved by Autohop's audio processing features. Data is persisted in `ListeningStatsStore` → `listening-stats.json`.

### Data collection (June 2026)
All listening activity is bucketed per local calendar day in `DayStats` records (a few hundred bytes each, so lifetime retention is cheap). Each day records: wall-clock seconds, per-hour histogram (24 buckets), per-show seconds (keyed by subscription UUID, with a title map that survives unsubscribes), the four time-saved categories, episodes started/completed, and manual skip-forward count. Totals accumulated under the previous lifetime-only store (`playback-stats.json`) are imported once as a baseline so existing users keep their history; the legacy file is left in place.

Hooks: playback tick (0.5 s) → listening time + hour + show attribution; `SilenceDetector` callbacks → exact trimmed seconds; `startPlayback` from a fresh position → episode started; `handleEpisodeFinished` → episode completed. Saves are throttled to 30 s during playback and flushed on pause and when the app leaves the foreground.

Query API on `ListeningStatsStore`: `summary(for: .last(days:)/.lifetime)` (period aggregates incl. per-show, hour histogram, zero-filled day series for heatmaps), `lifetime` (legacy `PlaybackStats` shape used by `StatsView`), `currentStreakDays` / `longestStreakDays` (a day counts toward a streak at ≥ 60 s of listening). This is the data layer for the planned rich Stats page (period selector, heatmap, listening clock, top shows).

### Page layout (`Views/StatsView.swift`, June 2026)
All sections respond to a period selector at the top: **7 Days / 30 Days / 90 Days / 1 Year / All Time** (purple pill row). Cards follow the standard design system (`Section-Heading` + `white.opacity(0.08)` rounded cards, dark scheme, purple accent).

1. **Hero card** — big "Time listened" number (purple; All Time adds "since [date]"), plus three columns: time saved by Autohop (teal), episodes finished, and current streak (a day counts at ≥ 60 s of listening).
2. **Listening Heatmap** (7/30/90 days) — GitHub-style grid, columns are weeks and rows are weekdays, purple intensity scales with that day's listening (√-scaled so light days stay visible). Caption shows the busiest day. On 1 Year / All Time this is replaced by **Listening Over Time**, a Swift Charts monthly bar chart.
3. **Listening Clock** — 24-hour rose chart (Canvas): midnight at top, noon at bottom, each hour a wedge whose radius scales with listening in that hour. Caption shows the peak hour range.
4. **Top Shows** — up to 8 ranked rows: rank · 44 pt artwork (`Artwork-Placeholder` fallback) · show title with a purple bar relative to the #1 show · time listened. Titles resolve from the stats store's title map, so unsubscribed shows still appear. When more shows than fit have listening time, a **Show All ›** link in the section header pushes a full **Top Shows** screen (top 50, same row design and period selector). There, each row also shows a rank-movement badge vs. the previous period of the same length — teal ▲n, grey ▼n, or purple NEW (no badges on All Time, which has no previous period; previous ranks are computed across all shows, not just the top 50, via `ListeningStatsStore.previousPeriodShowSeconds(for:)`). Tapping any Top Shows row (main section or Show All) expands an inline **per-show detail card** (`ShowStatsExpandedCard`): episodes finished, time saved (real per-show value from `DayStats.perShowTimeSaved` — variable speed, trim silence, and skips are attributed to the playing episode's subscription; periods made up entirely of pre-tracking days fall back to apportioning the period total by listening share, labelled "est."), share of all listening, average completion %, episodes stopped partway, last-listened date, and listening cadence ("typical wait after release" — median delay between an episode's publish date and the last listen). Episode outcomes come from `ListeningHistoryStore` entries classified by `ShowEngagementAnalyzer.classify`, filtered to the selected period. Tap again to collapse.
5. **Shows You're Drifting From** (7/30/90 days only) — up to 5 currently-subscribed shows the user appears to be struggling with, computed by `Stats/ShowEngagementAnalyzer.swift` (pure functions, smoke-tested in `StatsSmokeTests`) over `ListeningHistoryStore` entries. Each entry is classified as completed (finished naturally or ≥ 90%), abandoned (≥ 60 s listened, ended < 80%), or archived unplayed (< 60 s; deliberate vs. auto-archive); in-progress and ambiguous legacy entries are skipped. Struggle score = (abandoned + deliberate archives + 0.5 × auto archives) / resolved episodes; shows need ≥ 4 resolved episodes, a score ≥ 0.4, **and ≥ 2 genuine drift signals** (abandoned mid-listen or deliberately archived unplayed) to appear — auto-archive churn alone can never flag a show, so high-volume feeds the episode limit cycles through (100% auto-archived news bulletins) stay out of the list (thresholds are constants in the analyzer). Rows: artwork · title · a blunt insight line ("Archived 6 of the last 8 unplayed", "You usually stop around the 12-minute mark" from the median abandon position) · a stacked completion bar (`Chart-CompletionBar`: teal finished / orange partial / dim unplayed) · finished/total fraction. Tapping a row expands an inline detail card (see below) with a **Podcast Settings** link; long-press offers Hide From This List (persisted in `UserDefaults` key `stats.hiddenDriftShowIDs`) and Unsubscribe. The section is omitted entirely when nothing qualifies — no empty state. Not shown on 1 Year / All Time (the 500-entry history cap truncates long ranges). The listening-history value types (`ListeningHistoryEntry`, `ListeningHistoryStatus`, `CompletionKind`) moved from `App/AppState.swift` to `Models/ListeningHistory.swift` so AutohopCore and the smoke tests can use them.
6. **Time Saved By** — breakdown card (rows below) plus a purple Total row.
7. **Privacy footer** — "Your listening stats never leave this device."

### Time Saved breakdown
Four rows showing how much time has been saved by each feature in the selected period:

| Stat | How it's calculated |
|---|---|
| **Skipping** | Sum of all manual skip-forward taps (skip amount, not wall clock). Backward skips are not counted. |
| **Variable Speed** | Each playback tick: `tickInterval × (speed − 1.0) / speed`. Represents the difference between listening at 1× vs. the user's set speed. |
| **Trim Silence** | Frames dropped by `SilenceDetector` per buffer chunk, converted to seconds. Accumulated during the buffer-read loop. |
| **Auto Skipping** | Start skip and end skip amounts at the moment they fire (real file time, not wall clock). |

### Total
Sum of all four time-saved categories, displayed in purple.

---

## 13. OPML Import & Export

**Access:** Hamburger menu (☰) → Settings → Subscriptions → Import OPML / Export OPML. Also accessible from within the Subscriptions section of App Settings.

**What it is:** OPML (Outline Processor Markup Language) is the standard format for transferring podcast subscription lists between apps.

### Import
1. Tap Import OPML.
2. Select an `.opml` or `.xml` file from Files or Downloads.
3. Autohop subscribes to each feed URL found in the file.
4. A progress indicator shows "Importing X of Y…" while in progress.

**Accepted file types:** `.opml`, `.xml`, plain text.

### Export
- Exports all current feed URLs and subscription order.
- Default filename: `autohop-subscriptions.opml`.
- Disabled when the subscription list is empty.

---

## 14. Notifications

**Two levels of control:**


| Level | Setting | Default | Location |
|---|---|---|---|
| Global | New episode notifications | **On** | Settings → Release Radar → Notification Settings |
| Per-podcast | New episode notifications | **Off** | Per-podcast Settings → Automation, or Settings → Release Radar → Notification Settings |

**Behaviour:** A notification fires only when both the global toggle and the per-podcast toggle are on. New podcasts default to off at the per-podcast level — the user opts in only for shows they want to be notified about.

**iOS permission:** Standard `UNUserNotificationCenter` authorisation is required. Managed by `NotificationService`, which is also the app's `UNUserNotificationCenterDelegate` (installed in `AppDelegate`).

**Sleep Schedule prompt notification:** Separate from new-episode alerts, `NotificationService` also posts the time-sensitive "Are you still listening?" lock-screen notification with its background "Still Listening" action button (see §8.1). This is generated locally on demand and is not gated by the per-podcast notification toggles.

---

## 15. App Settings

**Access:** Hamburger menu (☰) on the Priority page → Settings.

---

### 15.1 Release Radar

Autohop learns each podcast's release schedule (median publish interval anchored to its last episode) and starts watching the feed just before a new episode is expected. Feeds that expose only a single item at a time (hourly news bulletins) carry no cadence in the feed itself, so Autohop persists the publish dates it has seen (`RefreshStats.recentPublishDates`) and derives the schedule from those; until enough history exists, such feeds are checked at the Radar sensitivity cadence, backing off automatically while nothing new appears. Checks use HTTP conditional requests (ETag/If-Modified-Since), so the feed body is only downloaded when it has actually changed. Background refresh uses the same due dates (BGAppRefreshTask, due-date priority queue, up to 8 feeds per cycle); if a refresh cycle is already in flight when a background task fires, the task waits for that cycle to finish instead of completing early (completing early lets iOS suspend the app mid-request and strand it). Manual pull-to-refresh always refreshes every feed.

| Setting | Type | Default | Range | Description |
|---|---|---|---|---|
| Radar sensitivity | Stepper | **5 minutes** | 1 – 60 min | How often a feed is re-checked while a new episode drop is imminent. Lower means new episodes appear faster; checks are tiny, so even 1 minute is light on battery and data. |
| Notification Settings | Page link | — | — | Opens the Notification Settings page: the global "New episode notifications" master toggle (default **On**), Enable All / Disable All buttons, and a per-podcast toggle row (artwork + title) for every subscription. If iOS notification permission is denied, a banner with an "Open iOS Settings" deep link is shown. A notification fires only when the master toggle and the podcast's own toggle are both on. |

---

### 15.2 Auto Archive

| Setting | Description |
|---|---|
| Run Auto Archive Now | Manually triggers the archive pass across all subscriptions immediately, using each podcast's Auto Archive rules. Normally runs automatically at most every 30 minutes. Shows a spinner while running. |

---

### 15.3 Downloading

| Setting | Type | Default | Description |
|---|---|---|---|
| Downloads | Navigation link | — | Opens the Downloads page showing active, queued, and completed downloads. |
| Download over WiFi | Toggle | **On** | Allow downloads on Wi-Fi networks. |
| Download over cellular | Toggle | **On** | Allow downloads over mobile data. Turn off to restrict downloads to Wi-Fi only. |

---

### 15.4 Controls

| Setting | Type | Default | Range | Description |
|---|---|---|---|---|
| Keep Screen Awake | Toggle | **Off** | — | Prevents the screen from dimming or locking while an episode is actively playing in the full-screen player. Has no effect when playback is paused. |
| Lock Screen Scrubbing | Toggle | **On** | — | Enables seeking from the Lock Screen and Control Centre scrubber. Turn off to prevent accidental seeks when the phone is in a pocket. |
| Queue Badge | Toggle | **On** | — | Shows a number on the Autohop app icon counting how many downloaded episodes are ready to play. Turn off to clear the badge. |
| Skip back | Sheet (5s steps) | **15s** | 5 – 120s | Duration of the skip-back button in the player. Also controls the skip-back interval shown on the Lock Screen and in Control Centre. |
| Skip forward | Sheet (5s steps) | **30s** | 5 – 120s | Duration of the skip-forward button in the player. Also controls the skip-forward interval shown on the Lock Screen and in Control Centre. |

---

### 15.5 Subscriptions

| Setting | Type | Description |
|---|---|---|
| Manage podcasts | Navigation link | Opens the Priority Stack (PodcastsView) to reorder, add, or remove subscriptions. |
| Add RSS Feed | Navigation link | Opens the Add RSS Feed page to subscribe by entering a direct feed URL. |
| Listening History | Navigation link | Opens Listening History. See [Section 11](#11-listening-history). |
| Import OPML | Button | Opens the system file picker to import an OPML file. See [Section 13](#13-opml-import--export). |
| Export OPML | Button | Exports the current subscription list as an OPML file. Disabled when the subscription list is empty. |

---

### 15.6 Storage

| Display | Description |
|---|---|
| Downloaded episodes | Count of all episodes currently downloaded to the device, across every subscription. To free storage, archive episodes manually or tighten the Episode Limit rule in per-podcast Auto Archive settings. |

---

### 15.7 About

| Item | Description |
|---|---|
| Open Source Acknowledgements | Navigation link to the third-party licences view. |
| Version | Displays the app version and build number (e.g. "1.0 (42)"). Tap 5 times to unlock the hidden Diagnostics section for the current session. |

---

## 16. Support (In-App User Guide)

**Access:** Menu (☰) → **Support** (the last menu item). Code: `Views/SupportView.swift`; content data: `Views/SupportContent.swift` (`SupportGuide.sections`).

**What it is:** A native, dark-themed in-app User Guide that **mirrors the website Support page** (`kevmarl-site/support.html`). The two are kept in sync by hand — any change to support information is applied in both places.

**Structure:** Drill-down navigation. Support opens to a scannable list of ~16 topic rows (purple icon tile + title + one-line summary); tapping a topic pushes a detail page rendering just that section. Topics: Getting Started, Priority Stack, Queue, Player, Audio Controls, Chapters, Downloads, Per-Podcast Settings, Sleep Timer, Sleep Schedule, Video Podcasts, Notifications, OPML Import & Export, Listening History, Stats, App Settings.

**Content blocks (native renderers):** paragraphs with inline Markdown bold, headings, bullet and numbered lists, tinted callouts (tip / note / warning), key-value and labelled tables (as cards), colour-coded status pills, and Queue-style swipe-action cards. The website's SVG diagrams are intentionally omitted — the surrounding text and tables carry the same information on a phone screen. See DESIGN.md `ListRow-SupportSection` and `Blocks-Support`.

---

## Appendix: Model Defaults Quick Reference

### `PlaybackPreference.default`
| Property | Default |
|---|---|
| speed | 1.6x |
| startSkipSeconds | 0 (off) |
| endSkipSeconds | 0 (off) |
| vocalBoostLevel | .strong |
| trimSilence | .low |

### `AutoArchiveSettings.default`
| Property | Default |
|---|---|
| afterPlayed | .afterPlaying |
| afterInactive | .days7 (1 week) |
| episodeLimit | .one (keep 1) |

### `AppSettings.default`
| Property | Default |
|---|---|
| podcastPollMinutes | 5 |
| downloadOverWifi | true |
| downloadOverCellular | true |
| notifyNewEpisodes | true |
| skipBackSeconds | 15 |
| skipForwardSeconds | 30 |
| keepScreenAwakeDuringPlayback | false |
| lockScreenScrubbingEnabled | true |
| showQueueBadge | true |
| sharedListeningActive | false |
| sharedListeningSpeed | 1.0 |
| sleepScheduleEnabled | false |
| sleepScheduleStartMinutes | 1260 (9:00pm) |
| sleepScheduleEndMinutes | 360 (6:00am) |
| sleepScheduleDurationMinutes | 20 (0 = end of episode) |
| diagnosticLoggingEnabled | false |

### `Subscription.init` defaults
| Property | Default |
|---|---|
| notificationsEnabled | false |
| excludeFromAutoFeedRefresh | false |
| autoArchiveSettings | AutoArchiveSettings.default |
| playbackPreference | PlaybackPreference.default |
| browseDate | nil (nil = real subscription; non-nil = auto-created browse subscription) |
