# Autohop — Feature & Settings Reference

**Source of truth for all feature descriptions, setting labels, defaults, and behaviour.**
Used to keep website pages, App Store copy, and in-app help text in sync and accurate.

> When any Swift model, view, or setting changes, update this file first, then propagate to
> the website support page and any other consumer.

---

## Table of Contents

1. [Priority Stack](#1-priority-stack)
2. [Queue](#2-queue)
3. [Player](#3-player)
4. [Audio Controls](#4-audio-controls)
   - [Playback Speed](#41-playback-speed)
   - [Trim Silence](#42-trim-silence)
   - [Vocal Boost](#43-vocal-boost)
5. [Chapters](#5-chapters)
6. [Downloads](#6-downloads)
7. [Sleep Timer](#7-sleep-timer)
8. [Video Podcasts](#8-video-podcasts)
9. [Per-Podcast Settings](#9-per-podcast-settings)
   - [Podcast section](#91-podcast-section)
   - [Playback section](#92-playback-section)
   - [Automation section](#93-automation-section)
   - [Auto Archive section](#94-auto-archive-section)
   - [Chapter Filter section](#95-chapter-filter-section)
   - [Feed section](#96-feed-section)
   - [Danger section](#97-danger-section)
10. [Listening History](#10-listening-history)
11. [OPML Import & Export](#11-opml-import--export)
12. [Notifications](#12-notifications)
13. [App Settings](#13-app-settings)
    - [Podcast Polling](#131-podcast-polling)
    - [Auto Archive](#132-auto-archive)
    - [Downloading](#133-downloading)
    - [Controls](#134-controls)
    - [Subscriptions](#135-subscriptions)
    - [Storage](#136-storage)
    - [About](#137-about)

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
| Played | Blue | Marked as played |
| Archived | Purple | Archived (removed from queue) |
| Inactive | Orange | Excluded from auto feed refresh (finished show) |

**Navigation to per-podcast settings:** Tap a podcast row → episode list view → gear icon (⚙) in the top-right toolbar.

**Toolbar buttons (left to right):**
- Return to Player (play.circle.fill)
- Hamburger menu (☰) → Settings, Queue, Downloads
- Reorder toggle ("Reorder" / "Done")
- Refresh all feeds (arrow.clockwise)
- Add RSS Feed (+)

---

## 2. Queue

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

## 3. Player

**What it is:** The full-screen playback view. Permanent root of the navigation stack — always accessible.

**Panels:** Three horizontally swipeable panels:
1. **Now Playing** — artwork, episode title, podcast name, scrubber, transport controls (skip back, play/pause, skip forward), audio controls button, sleep timer button, queue peek.
2. **Details** — episode description and metadata.
3. **Chapters** — chapter list. Only shown if the current episode has chapters.

**Transport controls:**
- Skip back: configurable duration (default 15s), applied globally in Settings
- Skip forward: configurable duration (default 30s), applied globally in Settings
- Both durations also controllable from Lock Screen and Control Centre

**Audio Controls button:** Opens `AudioControlsSheetView` — a dark card sheet with speed, trim silence, and vocal boost controls.

**Sleep Timer button:** Opens `SleepTimerSheetView`.

---

## 4. Audio Controls

Accessed via the audio controls button on the Now Playing panel. Dark card sheet. Changes take effect immediately during playback.

### 4.1 Playback Speed

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

### 4.2 Trim Silence

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

### 4.3 Vocal Boost

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

## 5. Chapters

**Availability:** The Chapters panel in the player is only shown when the current episode has embedded chapter data.

**Display:** List of chapters with title and position. The currently playing chapter is highlighted and cannot be disabled.

**Skipping chapters:** Tap a chapter row to toggle its skipped state (not a swipe action). Skipped chapters are automatically bypassed during playback — the player jumps to the next enabled chapter when it reaches a disabled one.

**Chapter filter (per-podcast, per-position):** Disabled chapters are stored by position index in `ChapterFilter` on the `Subscription` model. Skips are **position-based and apply to all future episodes** of that podcast. This means disabling chapter 1 permanently skips the first chapter of every future episode — the primary use case being recurring show intros, sponsor reads, or outros that always appear in the same chapter slot.

**Editing chapter filter:** Available in the individual podcast's settings page (gear icon from episode list), under "Chapter Filter". Only shown when the latest episode has chapters.

---

## 6. Downloads

**What it is:** A view showing download activity and recently archived downloaded episodes.

**Download-first playback:** Autohop only plays files already on the device — no streaming. Background downloads keep the queue stocked automatically as new episodes are fetched.

**Auto-download:** New episodes discovered during a feed refresh are automatically queued for download (`AppState.refreshSubscription()` triggers download on new episode detection).

**Download states:** `notDownloaded` → `queued` → `downloading` → `downloaded` / `failed`

**Manual download:** Episodes not yet downloaded show a "Download" button in the episode list row.

**Download controls (global, in Settings):**
- Download over WiFi (default: on)
- Download over cellular (default: on)

---

## 7. Sleep Timer

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

---

## 8. Video Podcasts

**Support:** Full audio and video podcast support. `Episode.mediaKind` is either `.audio` or `.video`.

**Playback path:** Video episodes always use AVPlayer (the `VideoPlayer` SwiftUI view requires it). Vocal Boost and Trim Silence are not available for video episodes — the engine path is audio-only.

**Landscape:** Full-screen video unlocks landscape orientation via `VideoOrientationController`.

**Chapters:** Chapter navigation works on video episodes.

**Badges:** Video episodes show a "VIDEO" badge in episode list rows and on the episode detail view.

---

## 9. Per-Podcast Settings

**Access:** Priority page → tap podcast row → episode list → gear icon (⚙) in top-right toolbar.

The settings page is titled with the podcast name and groups settings into sections:

---

### 9.1 Podcast section

| Setting | Description |
|---|---|
| Title | The display name of the podcast. Tap to edit. Edits are local — does not affect the RSS feed. |
| Priority rank | The podcast's position in the Priority Stack. Tap to edit numerically. Changing rank immediately reorders the list. |
| Author | Read-only. Pulled from the RSS feed. |

---

### 9.2 Playback section

All settings in this section are stored in `PlaybackPreference` on the `Subscription` model. Changes apply immediately if this podcast is currently playing.

| Setting | Options | Default | Notes |
|---|---|---|---|
| Playback speed | 1.0x – 2.5x (0.1x steps) | **1.6x** | A comfortable starting speed that encourages users to explore speed control. |
| Vocal Boost | Off / Light / Standard / Strong | **Strong** | See [Vocal Boost](#43-vocal-boost) for full chain description. |
| Trim Silence | Off / Low / Medium / High | **Low** | Audio episodes only. See [Trim Silence](#42-trim-silence). |
| Start skip | 0 – 300s (5s steps) | **0 (off)** | Automatically skips N seconds at the start of every episode. Measured in real file time, independent of playback speed. Primary use case: skipping recurring show intros or theme music. |
| End skip | 0 – 300s (5s steps) | **0 (off)** | Automatically skips N seconds at the end of every episode. Measured in real file time, independent of playback speed. Primary use case: skipping recurring outros or trailing ad reads. |

**Footer note (shown in app):** "Strong targets clearer spoken audio with a -14 LUFS loudness goal. Trim Silence removes quiet gaps — only active for audio episodes. Start and end skip are measured in real file time, independent of playback speed."

---

### 9.3 Automation section

| Setting | Default | Description |
|---|---|---|
| New episode notifications | **Off** | Sends a notification when a new episode is published. Off by default — users opt in only for shows they want to be notified about, to avoid unwanted interruptions. Requires the global notification toggle (Settings → Podcast Polling) to also be on. |
| Exclude from Auto Feed Refresh | **Off** | When on, Autohop stops polling this podcast's RSS feed for new episodes. The podcast and its downloaded episodes remain in the library. Use case: finished/completed shows the user wants to keep but doesn't need updates from. |

---

### 9.4 Auto Archive section

Three independent rules. All stored in `AutoArchiveSettings` on the `Subscription` model. The archive pass runs at most every 12 hours, or immediately on demand via Settings → Run Auto Archive Now.

| Rule | Setting name | Options | Default | Description |
|---|---|---|---|---|
| Rule 1 | Played Episodes | Never / After Playing / After 24h / After 2 Days / After 1 Week | **After Playing** | Archives a played episode immediately on completion, or after a delay. "After Playing" archives as soon as the episode finishes. |
| Rule 2 | Inactive Episodes | Never / 4h / 8h / 16h / 24h / 2 Days / 3 Days / 1 Week / 2 Weeks / 30 Days / 90 Days | **1 Week** | Archives unplayed episodes that haven't been touched (not played, not queued) within the set interval. Keeps feeds from accumulating stale backlog. |
| Rule 3 | Episode Limit | No Limit / 1 / 2 / 3 / 4 / 5 / 10 | **1** | Keeps only the N most recently published episodes, archiving older ones. Default of 1 keeps storage lean — the user always has the latest episode available. |

**Footer note (shown in app):** "Played Episodes archives after it finishes playing (or after a delay). Inactive Episodes archives unplayed episodes that haven't been touched in the set time. Episode Limit keeps only the most recently published episodes, archiving older ones. Archive runs at most every 12 hours."

---

### 9.5 Chapter Filter section

Only shown when the podcast's latest episode has chapter data.

| Behaviour | Detail |
|---|---|
| Toggle chapter | Tap a chapter row to enable/disable it. Currently playing chapter cannot be disabled. |
| Scope | Position-based. A disabled position is skipped in all future episodes of this podcast. |
| Primary use case | Permanently skip recurring chapters at a fixed position — show intros, sponsor reads, or outros that appear in the same chapter slot every episode. |

---

### 9.6 Feed section

| Field | Description |
|---|---|
| URL | The podcast's RSS feed URL. Read-only display. |

---

### 9.7 Danger section

| Action | Description |
|---|---|
| Unsubscribe | Removes the podcast and all its settings from Autohop. Downloaded episode files are not deleted — they remain on device until iOS cleans them up. Requires confirmation. |

---

## 10. Listening History

**Access:** Settings → Subscriptions → Listening History.

**What it tracks:** Every episode the user has listened to, recorded in `ListeningHistoryStore` → `listening-history.json`.

### Stats header
Two summary cards at the top of the page:
- **Listening Time** — total hours and minutes across all recorded history.
- **Episodes** — total count of completed episodes (`AppState.completedEpisodeCount`).

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
Filters by episode title or podcast name. Results update as the user types. Search bar is always visible (`.navigationBarDrawer(displayMode: .always)`).

---

## 11. OPML Import & Export

**What it is:** OPML (Outline Processor Markup Language) is the standard format for transferring podcast subscription lists between apps.

### Import
**Access:** Settings → Subscriptions → Import OPML (or Settings page directly).
1. Tap Import OPML.
2. Select an `.opml` or `.xml` file from Files or Downloads.
3. Autohop subscribes to each feed URL found in the file.
4. A progress indicator shows "Importing X of Y…" while in progress.

**Accepted file types:** `.opml`, `.xml`, plain text.

### Export
**Access:** Settings → Subscriptions → Export OPML.
- Exports all current feed URLs and subscription order.
- Default filename: `autohop-subscriptions.opml`.
- Disabled when the subscription list is empty.

---

## 12. Notifications

**Two levels of control:**

| Level | Setting | Default | Location |
|---|---|---|---|
| Global | New episode notifications | **On** | Settings → Podcast Polling |
| Per-podcast | New episode notifications | **Off** | Per-podcast Settings → Automation |

**Behaviour:** A notification fires only when both the global toggle and the per-podcast toggle are on. New podcasts default to off at the per-podcast level — the user opts in only for shows they want to be notified about.

**iOS permission:** Standard `UNUserNotificationCenter` authorisation is required. Managed by `NotificationService`.

---

## 13. App Settings

**Access:** Hamburger menu (☰) on the Priority page → Settings.

---

### 13.1 Podcast Polling

| Setting | Type | Default | Range | Description |
|---|---|---|---|---|
| Check interval | Stepper | **5 minutes** | 1 – 60 min | How often Autohop checks for new episodes while the app is open. 5 minutes is the target — iOS may adjust timing based on system conditions. Background refresh is separate (BGAppRefreshTask, opportunistic, cursor-based round-robin across subscriptions). |
| New episode notifications | Toggle | **On** | — | Global switch for new episode notifications. Per-podcast toggles must also be on for a notification to fire. |

---

### 13.2 Auto Archive

| Setting | Description |
|---|---|
| Run Auto Archive Now | Manually triggers the archive pass across all subscriptions immediately, using each podcast's Auto Archive rules. Normally runs automatically at most every 12 hours. Shows a spinner while running. |

---

### 13.3 Downloading

| Setting | Type | Default | Description |
|---|---|---|---|
| Downloads | Navigation link | — | Opens the Downloads page showing active, queued, and completed downloads. |
| Download over WiFi | Toggle | **On** | Allow downloads on Wi-Fi networks. |
| Download over cellular | Toggle | **On** | Allow downloads over mobile data. Turn off to restrict downloads to Wi-Fi only. |

---

### 13.4 Controls

| Setting | Type | Default | Range | Description |
|---|---|---|---|---|
| Keep Screen Awake | Toggle | **Off** | — | Prevents the screen from dimming or locking while an episode is actively playing in the full-screen player. Has no effect when playback is paused. |
| Lock Screen Scrubbing | Toggle | **On** | — | Enables seeking from the Lock Screen and Control Centre scrubber. Turn off to prevent accidental seeks when the phone is in a pocket. |
| Skip back | Sheet (5s steps) | **15s** | 5 – 120s | Duration of the skip-back button in the player. Also controls the skip-back interval shown on the Lock Screen and in Control Centre. |
| Skip forward | Sheet (5s steps) | **30s** | 5 – 120s | Duration of the skip-forward button in the player. Also controls the skip-forward interval shown on the Lock Screen and in Control Centre. |

---

### 13.5 Subscriptions

| Setting | Type | Description |
|---|---|---|
| Manage podcasts | Navigation link | Opens the Priority Stack (PodcastsView) to reorder, add, or remove subscriptions. |
| Add RSS Feed | Navigation link | Opens the Add RSS Feed screen. Subscribe to any podcast by entering its RSS feed URL directly — useful for independent shows not listed in major directories. |
| Listening History | Navigation link | Opens Listening History. See [Section 10](#10-listening-history). |
| Import OPML | Button | Opens the system file picker to import an OPML file. See [Section 11](#11-opml-import--export). |
| Export OPML | Button | Exports the current subscription list as an OPML file. Disabled when the subscription list is empty. |

---

### 13.6 Storage

| Display | Description |
|---|---|
| Downloaded episodes | Count of episodes currently downloaded to the device. To free storage, archive episodes manually or tighten the Episode Limit rule in per-podcast Auto Archive settings. |

---

### 13.7 About

| Item | Description |
|---|---|
| Open Source Acknowledgements | Navigation link to the third-party licences view. |
| Version | Displays the app version and build number (e.g. "1.0 (42)"). Tap 5 times to unlock the hidden Diagnostics section for the current session. |

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
| diagnosticLoggingEnabled | false |

### `Subscription.init` defaults
| Property | Default |
|---|---|
| notificationsEnabled | false |
| excludeFromAutoFeedRefresh | false |
| autoArchiveSettings | AutoArchiveSettings.default |
| playbackPreference | PlaybackPreference.default |
