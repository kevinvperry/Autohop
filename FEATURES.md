# Autohop — Feature & Settings Reference

<!--
AI CONTEXT — FEATURES.md
Canonical product/behaviour reference for Autohop features, settings, defaults,
and implementation-facing notes that must stay aligned with Swift views/models,
website support copy, App Store text, and in-app help. Update this file whenever
a user-visible feature, setting label/default, navigation path, or cross-cutting
implementation behaviour changes. Section 17 documents the shared artwork cache
and lazy image-loading system: source-byte disk cache, downsampled memory
variants, validation/failure cooldowns, disk pruning, prefetch priorities, and
the call sites that deliberately use CachedArtworkImage/ArtworkImageCache.
Verified against the current code during the 2026-07-24 whole-project audit.
VERSION_1.4.md and VERSION_1.5.md are closed historical ledgers. VERSION_1.6.md
records the tvOS Version 1.6 (build 13) submission on 22 August 2026 and
separates post-submission source work from the submitted binary.
Section 15.1 documents Release Radar's learned scheduling, including hourly,
rolling-bulletin, burst, daily, weekly, multi-slot, learning, unreliable-date,
and random profiles; foreground/background caps; protected background slots for
daily/active/missed release windows; adaptive window widening for messy ordinary
feeds; broad safety sweeps outside learned windows; deferred backlog draining;
cancellation checkpoints; and diagnostic fields.
Section 7/15.1 documents that feed refresh schedules auto-downloads without
waiting for media transfer completion, including stale-download cancellation for
rolling one-item feeds. Section 15.7 documents CloudKit type-namespaced record
IDs, collision containment, full-record namespace migration, legacy subscription
settings recovery, atomic `SubscriptionOrder` generations, stale-ack protection,
and DayStats conflict convergence/storm logging. Section 15.9
documents diagnostic resource snapshots (`footprintMB`), watchdog inactive-gap
classification, main-thread hang context, playback tick timing, and stats-sync
flush breadcrumbs. Playback route-change stability is covered in §4/§15.9.
These notes are the user/product-facing counterpart to the June 2026 diagnostic
repair work in SYNC_DESIGN.md and the AI headers in the touched Swift files.
The iPhone and Apple TV targets use only the user's private iCloud account for
cross-device sync. The abandoned Autohop Pro and Cloudflare relay prototypes
have been removed from the project.
Apple TV dynamic Top Shelf is a pre-materialised App Group projection: the main
app selects Up Next/Continue content and prepares bounded artwork, while the
memory-constrained extension performs only a local read and TVServices mapping.
Feed membership is unique by canonical feed URL even when legacy CloudKit UUIDs
collide; the already-established local identity is retained.
Section 19 documents CarPlay support. Keep it aligned with the approved audio
entitlement scope: Now Playing, downloaded-only Up Next, Subscriptions, explicit
download-before-play confirmation for subscription episodes, Play Now, Play Next,
Play Last, Archive, playback speed, and Shared Listening. CarPlay must not grow
search, podcast discovery, feed refresh, settings, sleep controls, stats, OPML,
notifications, or other non-driving workflows.
-->

> Version 1.6 build 9: Apple TV diagnostics exports are prepared away from the
> user-interface thread with visible progress. iCloud diagnostics report
> privacy-safe fetch cycles, state advancement and material-change counts;
> inactive Apple TV scenes defer projection rebuilding until they become active.

**Source of truth for all feature descriptions, setting labels, defaults, and behaviour.**
Used to keep website pages, App Store copy, and in-app help text in sync and accurate.

> **Cross-device architecture:** iPhone and Apple TV synchronize through the
> user's private iCloud account. There is no Autohop account, subscription tier,
> developer-operated sync service, or Cloudflare relay.

> **tvOS submission note:** the separate Apple TV
> target now uses an iPhone-authored self-contained queue, native audio/video
> streaming, compact purgeable projections, bounded podcast detail loading and
> read-only subscription/order behaviour. It also presents complete feed-supplied
> episode descriptions in a native scrollable sheet: use the Description control
> in the audio player, the Episode menu during native video playback, or long-press
> an episode on Home, Up Next, Library or History. Physical-device Phase 6
> target was submitted as Version 1.6 (build 13) on 22 August 2026. The
> in-repository physical-device evidence checklist remains incomplete, so this
> submission record is not itself an approval or public-release claim.

> **Page names & navigation structure** → see [`PAGES.md`](PAGES.md)

> When any Swift model, view, or setting changes, update this file first, then propagate to
> the website support page and any other consumer.

---

## Table of Contents

1. [Priority Stack](#1-priority-stack)
2. [Find Podcasts (Search) & Discover](#2-find-podcasts-search)
   - [Search](#21-search)
   - [Podcast Detail Page](#22-podcast-detail-page)
   - [Subscribe / Unsubscribe Button Behaviour](#23-subscribe--unsubscribe-button-behaviour)
   - [Browse Subscriptions](#24-browse-subscriptions)
   - [Recently Viewed](#25-recently-viewed)
3. [Up Next](#3-up-next)
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
    - [Startup](#150-startup)
    - [Release Radar](#151-release-radar)
    - [Auto Archive](#152-auto-archive)
    - [Downloading](#153-downloading)
    - [Controls](#154-controls)
    - [Default Playback](#155-default-playback)
    - [Subscriptions](#156-subscriptions)
    - [Sync (iCloud)](#157-sync-icloud)
    - [Storage](#158-storage)
    - [About](#159-about)
16. [Support (In-App User Guide)](#16-support-in-app-user-guide)
17. [Artwork Cache & Lazy Image Loading](#17-artwork-cache--lazy-image-loading)
18. [First-Run Experience (New User Onboarding)](#18-first-run-experience-new-user-onboarding)
19. [CarPlay](#19-carplay)

---

## 1. Priority Stack

**What it is:** The main screen of the app. A ranked list of every podcast the user subscribes to.

**How it works:** Each subscription has a `priorityRank: Int` (1 = highest priority). Autohop builds the playback queue by walking down this list in rank order, picking the next downloaded, unplayed episode from each podcast. The queue advances automatically when an episode finishes — no manual intervention required.

**Reordering:** Tap Priority, then drag active shows into the desired order.
Autohop keeps a stable UUID-based draft until Done, so several moves in one
session cannot be misapplied through stale filtered-list indices. Inactive shows
stay visible but fixed below the draggable group; hidden browse previews never
enter the drag list. Done, navigation away, or scene deactivation validates and
persists the final order as one transaction. If iCloud delivers another device's
order during a drag, it waits until the session finishes; a deliberate local
move wins, while an unchanged session accepts the remote order.

The durable cross-device representation is one atomic `SubscriptionOrder`
generation containing the full real-subscription UUID list. The displayed
`priorityRank` values are derived locally from that list. This prevents a
multi-row reorder from arriving on another device as a mixture of old and new
per-podcast ranks.

The numeric Priority editor in Podcast Settings follows the same boundary: its
maximum is the number of active real subscriptions, and it is unavailable for an
Inactive show. Hidden browse and Inactive rows cannot inflate the selectable
rank.

**Row layout (2026-07-02):** artwork + rank pill · show title (subheadline-semibold) · the show's **channel-level description** clamped to 2 lines (not the latest episode title) · a metadata line `Updated: <relative age>` (mins/hours → "Yesterday" → "2…6 days ago" → exact date; no episode length). See `ListRow-SubscriptionRow` in DESIGN.md.

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
| Skipped | Muted gray | Not downloaded because this podcast's Download Filters currently exclude the episode. Manual swipe actions still work. |

**Navigation to per-podcast settings:** Tap a podcast row → episode list view → gear icon (⚙) in the top-right toolbar.

**Toolbar buttons (left to right):**
- Return to Player (play.circle.fill)
- Hamburger menu (☰) → Discover, Stats, Sleep Schedule, Listening History, Downloads, Settings, Support
- Priority toggle ("Priority" / "Done") — enters drag-to-reorder mode
- Refresh all feeds (arrow.clockwise)
- Add Podcast / Discover (+) — pushes the Discover charts page (search lives inside it)

---

## 2. Find Podcasts (Search)

**What it is:** A dedicated page for finding shows and episodes in the selected Discover storefront. The primary way to add new podcasts to Autohop.

**Access:** Tap the search shortcut at the top of the **Discover** page (the only entry point to Search).

---

### 2.1 Search

**How it works:**
1. User types a search term. Results appear automatically after a short debounce (400ms).
2. An **All / My Library** scope chooses the source. All uses independent show and episode providers against Apple's catalog in the country selected in Discover. My Library searches locally known subscribed shows and episodes immediately, makes no Apple request, and excludes temporary browse previews.
3. Results are clearly separated into a compact horizontal **Shows** rail and a vertical **Episodes** list, keeping both result types visible while the keyboard is open. Show cards adapt between compact phone, large phone and iPad widths and permit two title lines. Tapping a show opens its existing Podcast Detail page. Tapping an episode opens the existing Episode Detail page: Apple results are reconciled to RSS by episode GUID, with exact normalized title as the narrow fallback; local results already carry their RSS episode UUID.
4. Episode results are ordered by explicit match quality first, then newest publication date within the same relevance tier.
5. **Publishers & Creators** are conservatively grouped from exact, non-empty show-author metadata. Obvious placeholders, web addresses and email-like values are rejected. This section does not infer hosts, guests or people from titles/descriptions.
6. Tapping a publisher/creator opens a dedicated list of the shows carrying that exact author value; selecting a show then opens its Podcast Detail page.

**Search states:**
- **Idle** — prompt to search + Recently Viewed history list (if any) + "Enter RSS URL" button
- **Loading** — each section displays its own progress state
- **Results** — separate Shows and Episodes cards, followed by Publishers & Creators when trustworthy author metadata is available; "Enter RSS URL" link at the bottom
- **Empty / Failed** — section-local messages, so a successful provider remains usable if the other request is empty or unavailable

**RSS URL entry:** Available from both the idle state and the results list footer. Navigates to the Add RSS Feed screen for users who have a direct feed URL.

**Results filtering:** Podcasts with no RSS feed URL (Apple Podcasts exclusives) are silently excluded from results.

**Already subscribed:** If the user taps a result for a podcast they are already actively subscribed to, the same Podcast Detail page opens in its subscribed state (header shows Unsubscribe; Refresh Feed and Show Settings appear in the toolbar) — no duplicate subscription is created.

---

### 2.2 Podcast Detail Page

A single page (`PodcastDetailView`) serves every state of a podcast — an unsubscribed preview, a browse-only preview, an active subscription, and an Inactive subscription whose auto feed refresh is paused. Tapping a search result, a Discover chart entry, a Recently Viewed row, a Priority Stack row, or the show name in the Player all open this same page. For a preview, the RSS feed is fetched immediately on open and a **browse subscription** is created automatically (see §2.4). The episode list is fully interactive from first load. The mini-player bar is always docked at the bottom.

**Page structure:**
1. **Header** — 120×120pt artwork, title, large Video/Explicit pills, show description (truncated to ~3 lines with a "…more" toggle that expands to the full text when long enough), author · categories.
2. **Subscribe row** — the full-width **Subscribe ⇄ Unsubscribe button** (purple "Subscribe" until subscribed, then grey "Unsubscribe"; see §2.3), with a **per-podcast new-episode notification bell** beside it shown for real subscriptions, including Inactive ones. The bell toggles `Subscription.notificationsEnabled` in place (bell.fill when on, bell.slash when off) — the same flag exposed in Podcast Settings and Notification Settings, and still gated by the global notification toggle.
3. **Episodes section** — "Episodes" heading + waveform icon, followed by the episode list in a card.

**Toolbar:**
- Back chevron (always) and a Share button (always).
- **Refresh Feed** and **Show Settings** (gear → Podcast Settings) appear for real subscriptions, including Inactive ones — never on an unsubscribed preview or browse-only page.

**Episode list:**
- Shows up to 50 most recent episodes on first load.
- Full status pills (Unplayed, Queued, Paused, Playing, Played, Archived), small Video/Explicit badges as a top-trailing overlay, download progress bar, date, duration.
- Every episode row is a `NavigationLink` to Episode Detail.
- **Load Older Episodes** button appears when 50+ episodes are loaded. Fetches full episode history.

**Episode swipe actions:**
- Leading: **Play** (green), **Play Next** (blue)
- Trailing (far-right first): a state-driven **Download / Archive** button, then **Play Last** (orange). The far-right button is **Archive** (purple) whenever the episode is downloaded; **Download** (teal — downloads the episode, which queues it at its priority-sorted Up Next position, no playback) when it isn't downloaded *and* the podcast is a subscribed, active feed; and falls back to the original **Archive / Unarchive** (purple) on non-subscribed previews or Inactive subscriptions. Download never appears on previews or Inactive subs; Unarchive is otherwise reached from the Episode Detail page.

---

### 2.3 Subscribe / Unsubscribe Button Behaviour

The header button toggles between Subscribe and Unsubscribe based on the current subscription state for that feed:

| Current state | Button | Action |
|---|---|---|
| No subscription exists | **Subscribe** | Creates a new active subscription, inserts at top of Priority Stack |
| Browse subscription exists (auto-created, inactive) | **Subscribe** | Activates it, clears browse status, moves to top of Priority Stack |
| Active subscription | **Unsubscribe** | Shows a confirmation dialog; on confirm, removes the subscription. The page stays open with the button flipped back to Subscribe |
| Inactive subscription (`Exclude from Auto Feed Refresh` on) | **Unsubscribe** | Still subscribed: shows the same confirmation dialog. Manual Refresh Feed, Settings, and notification controls remain available. |

Unsubscribing is also still available from the Podcast Settings page (§10.8).

---

### 2.4 Browse Subscriptions

When a user opens the Podcast Detail page for an unsubscribed show, Autohop silently creates a **browse subscription** in the background. This enables the fully interactive episode list from first load without requiring the user to explicitly subscribe.

**Browse subscriptions are invisible to the user** — they do not appear in the Priority Stack or anywhere else in the app. They are only visible in the Search sheet's Recently Viewed history.

**Behaviour:**
- Marked `excludeFromAutoFeedRefresh = true` (not polled for new episodes)
- Stored with a `browseDate` timestamp
- Retained for **30 days** from the most recent visit
- On revisit: episodes are refreshed (new content appears) and the 30-day clock resets
- **Automatically deleted** after 30 days only if no episode has been played or downloaded **and** the show has no listening-history entry (anything you've listened to is kept, so its history stays navigable)
- Converted to a full active subscription when the user taps **Subscribe**

**If a user plays, queues, or archives an episode** from the preview page without subscribing, the browse subscription is retained (episodes have been acted on) but the podcast remains invisible in the Priority Stack until the user explicitly subscribes.

---

### 2.5 Recently Viewed

The Search idle state shows a **Recently Viewed** section listing all browse subscriptions, sorted by most recent visit.

Each row shows:
- Podcast artwork (44×44pt)
- Title and author
- "Viewed [date]" caption

Tapping a row navigates back to the Podcast Detail page for that podcast, refreshing episodes and resetting the 30-day clock.

---

### 2.6 Discover (Charts)

**What it is:** A full-screen sheet for browsing Apple Podcasts charts — the exploration counterpart to Search.

**Access:** Tap the `+` button on the Priority Stack toolbar, or **Discover** (top item) in the hamburger menu (☰). Discover is the parent page of Podcast Search.

**Page structure (top to bottom):** five hero carousels separated by 19 category rails in a 4 / 5 / 5 / 5 cadence — Top Episodes (fixed, above the feed) · rails 1–4 · **New & Notable** · rails 5–9 · Top Podcasts · rails 10–14 · International A · rails 15–19 · International B (closes the feed).

- **Search shortcut** — a search-field-shaped button that pushes the dedicated Search Results page, preserving the selected storefront
- **Top Episodes hero** — the storefront's Top 8 *episodes* (not shows) as big paging cards at the very top of the page. The header's **See All** button pushes the **Top Episodes** page (`TopEpisodesView`) — an editorial Top-50 episode list where a large feature card appears every 7th entry (ranks 1/8/15/22/29/36/43) and the rest are compact ranked rows, each showing episode artwork (placeholder fallback), episode title, show name, and relative publish time ("4 hours ago"). Tapping resolves the parent podcast and opens Podcast Detail (§2.2). Data: the Marketing Tools `podcast-episodes.json` feed (limit 50), release dates enriched per parent podcast via the iTunes Lookup API, cached per country.
- **Top Podcasts hero** — the storefront's Top 8 as big sideways-paging cards (purple gradient, oversized ghosted rank numeral, artwork, rank pill, title/artist/genre). The header's **See All** button pushes the **Top Podcasts** page (`TopPodcastsView`) — an editorial Top-50 *show* list with the same layout as Top Episodes (a large feature card every 7th entry, the rest compact ranked rows), each entry showing the show's artwork, title, author/publisher, and category. Tapping resolves the show's feed and opens Podcast Detail (§2.2). Data: `topPodcasts` (limit 50), cached per country. **Only this first hero (the selected-country one) has a See All — the two fixed-country spotlight heroes don't.**
- **New & Notable hero** — recently launched shows that are already charting, shown as the same paging hero cards. **Apple publishes no new-releases endpoint for podcasts** (verified 2026-07-25: every legacy `new*`/`noteworthy` feed type returns HTTP 400, and Marketing Tools serves only `top`), so Autohop derives the list: it takes a 200-deep overall chart, keeps shows with 30 or fewer episodes, then confirms genuine newness by reading each candidate's **oldest** indexed episode date and requiring it within 90 days. That last step is essential — the Lookup API's `releaseDate` is the *latest* episode, so a 1995 show reports today's date, and episode count alone admits long-running feeds that merely trim their episode list. The 8 newest qualifying shows are shown newest-first, capped at 3 per genre so one hot category cannot claim the shelf, and a show whose episodes are densely and evenly spaced (a rolling feed exposing only a recent window) is rejected. Episode-1 dates are cached permanently because they never change, so in steady state only new chart entrants cost a lookup. **No See All** — the qualifying pool is only a handful of shows. Hidden entirely when fewer than 3 qualify.
- **Category shortcuts and rails** — purple chips for all **19** Apple top-level categories — Comedy, News, True Crime, Society & Culture, Business, Sports, History, Health & Fitness, Education, Arts, Technology, Science, TV & Film, Fiction, Music, Leisure, Kids & Family, Religion & Spirituality, and Government — each push a dedicated `Top 100 - <Category>` page (raised from Top 50 on 2026-07-27; the legacy genre endpoint serves 100). The **overall** Top Podcasts page remains Top 50 because Apple's Marketing Tools feed that serves it hard-caps at 50 entries. Category names follow the selected storefront (Apple localises them: 1545 is "Sport" in the Australian store and "Sports" in the US store), fetched from Apple's genre tree and cached for 30 days with English fallbacks. Every rail heading repeats that link with the category's purple symbol and a trailing chevron. The page reuses the Top Podcasts editorial layout, feed resolution, pull-to-refresh, and mini-player. When its Top-15 rail is already available, the category page paints those entries immediately and extends/replaces them with the canonical Top 50 in the background. Horizontally scrolling Top-15 rails remain on Discover as quick previews; a rail that fails to load is omitted, and its chip is therefore omitted too. Every rail ends with a **See All** tile in the 16th position — same 124 pt size as the artwork tiles, purple-tinted glass with a forward arrow — opening that category's `Top 50` page. It is always present (the category page holds up to 50 entries even when the rail returned fewer than 15), giving the category page an affordance at both ends of the row: the heading for vertical scanning, the tile for users who swipe to the end.
- **Country spotlight heroes** — two additional "Top Podcasts · <Country>" hero carousels (identical design to the top hero) woven into the rails: spotlight A after rail 14, spotlight B at the very end. They show fixed storefronts — A = United States (or UK if the user's country is already US); B = United Kingdom (or Australia if the user's country is UK, and also Australia when A has taken UK, i.e. a US user). `DiscoverViewModel.spotlightCountries(selected:)` resolves the pair so neither duplicates the user's country or each other. Each spotlight loads independently (omitted on failure, never blocking the page) and resolves taps against *its own* storefront so the show opens reliably.

**Country picker:** Toolbar menu ("🇦🇺 Australia ▾") shown throughout the Discover chart family: main Discover, Top Episodes, Top Podcasts, and every category Top 50. It defaults to the device's region (`Locale.current.region`, no location permission needed), falls back to the US, and persists the user's manual choice (`discoverCountryCode` in UserDefaults). Changing it on a child page reloads that chart and updates Discover when the user returns. 21 storefronts offered.

**Data source and loading:** Apple's public chart feeds — the Marketing Tools v2 feed for the Top 8, the legacy iTunes RSS genre endpoint for category charts, and the legacy RSS overall chart for the New & Notable pool (Marketing Tools serves at most 50 entries, so it cannot supply a 200-deep pool). No API key or account. Discover renders its shell immediately and publishes heroes, rails, and country spotlights independently as each request completes; one slow endpoint does not hold the page behind a global spinner. **Rails load in two stages:** the first 9 are fetched when the page opens and the remaining 10 only once the user scrolls toward them, so expanding from 10 to 19 categories does not increase the cost of a cold open for someone who never scrolls past the first few rails. Responses are cached on disk for 12 hours (`Caches/discover-charts`). A fresh Top-50 podcast cache is an ordered superset that can satisfy Top-8 or Top-15 requests, avoiding duplicate downloads after an expanded chart has been viewed.

**Tapping a chart entry:** The iTunes Lookup API resolves the show's RSS feed URL (spinner overlays the tile), then routing matches Search exactly — every entry opens the Podcast Detail page (§2.2), in its subscribed state for shows already subscribed, otherwise as a preview that creates the invisible 30-day browse subscription (§2.4) with fully interactive Play / Play Next / Play Last rows. Apple-exclusive shows with no public RSS feed show a "Not Available" alert.

---

## 3. Up Next

**What it is:** A sheet view showing the current automatic playback order — all downloaded, unplayed episodes sorted by podcast priority rank, with any manual overrides applied on top. The sheet is labelled "Up Next" in-app (was "Queue" prior to v1.3).

**Manual overrides:**
- **Play Next** (blue) — promotes an episode to the front of the queue. Inserted at position 0, ahead of all other episodes.
- **Play Last** (orange) — demotes an episode to the end of the queue.
- Overrides are cleared when the episode is played or archived.

**Swipe actions:**
- Leading edge: Play (green), Play Next (blue)
- Trailing edge: Archive (purple), Play Last (orange)
- `allowsFullSwipe: false` on both edges — full swipe is disabled intentionally to prevent accidental actions.

**Pin badges:** Episodes with a Play Next or Play Last override show a pin badge above the duration — blue for Play Next, orange for Play Last.

**Episode details & shortcuts:** Tapping an episode's title expands the row to reveal the full episode description. The expanded row also shows two small purple circular glass buttons in its bottom-right corner:
- **Podcast list** (`list.bullet`) — closes the Up Next sheet and opens that podcast's **Podcast Detail** page (episode list) in its place.
- **Podcast settings** (`gearshape`) — closes the Up Next sheet and opens that podcast's **Podcast Settings** page in its place.

Both use the same "replace the queue" pattern: the subscriptionID is staged, the Up Next sheet dismisses, and the new sheet is presented in `onDismiss` so UIKit never sees two simultaneous sheet transitions.

**Action animations:** Each swipe action is animated with a matched haptic (`.sensoryFeedback`) and the list reorders fluidly (a no-bounce `.smooth` spring keyed to the queue's episode order):
- **Play Next / Play Last** — a light impact haptic; the row pops gently and flashes a directional badge at its leading edge (blue ↑ "to top" / orange ↓ "to bottom"), then the row visibly glides to its new top/bottom slot. The reorder is deferred until the swipe row finishes closing, so a neighbouring episode never appears to jump over the one being moved.
- **Archive** — a success haptic; the row slides toward the trailing edge while shrinking and fading as a purple archive-box badge fades in, then the archive commits and the gap closes behind it.
- **Unpin** — a light impact haptic; the row glides back to its natural priority slot.

---

## 4. Player

**What it is:** The full-screen playback view. Permanent root of the navigation stack — always accessible.

**Panels:** Three horizontally swipeable panels:
1. **Now Playing** — artwork, episode title, podcast name, scrubber, transport controls (skip back, play/pause, skip forward), audio controls button, sleep timer button, queue peek.
2. **Details** — episode description and metadata, followed by the iOS-family
   **Review in Apple Podcasts** action beneath the metadata-card grid. The show
   must pass an exact normalized RSS feed match in the selected Apple storefront;
   a failure is explained inline and never opens a similarly named show. Apple
   provides no supported direct review-composer URL, so the control instructs
   the listener to scroll to Ratings & Reviews.
3. **Chapters** — chapter list. Only shown if the current episode has chapters.

**Top bar:** leading nav icon (pushes Subscriptions) · **Sleep Schedule indicator** · panel tab strip · Queue count pill. The Sleep Schedule indicator (`bed.double.fill` purple pill, matching the audio-row action buttons) appears next to the nav icon **only while inside the Sleep Schedule active-hours window**. It shows the whole minutes remaining until the next "still listening?" prompt while a countdown is running, and the icon alone when not counting (paused, idle, or End-of-Episode mode). Tapping it pushes the Sleep Schedule page (`AppRoute.sleepSchedule`).

**Transport controls:**
- Skip back: configurable duration (default 15s), applied globally in Settings
- Skip forward: configurable duration (default 30s), applied globally in Settings
- Both durations also controllable from Lock Screen and Control Centre

**Scrubber restore behaviour:** When Autohop opens on an episode that already has a saved resume position, the scrubber thumb is synchronised from the canonical playback clock on first render, so the thumb, elapsed time, and remaining time all immediately reflect the same restored position even before playback resumes.

**Audio Controls button:** Opens `AudioControlsSheetView` — a dark card sheet with speed, trim silence, and vocal boost controls.

**Sleep Timer button:** Opens `SleepTimerSheetView`.

**Audio row (below the transport controls):** Sound Settings · Sleep Timer · AirPlay route picker (shows the current output name) · Share · Archive.

**Audio route changes:** Removing AirPods/headphones still pauses playback and requires deliberate user action to resume, but Autohop waits briefly to confirm the route loss before pausing so AirPods/Speaker transition storms do not immediately stop playback. If a new or non-built-in output appears during that confirmation window, the pending pause is cancelled. Active output transitions on the AVAudioEngine path schedule a delayed buffer-loop restart from the current playback position, including messy iOS `unknown` / `categoryChange` AirPods notifications. Route-loss confirmation cancels stale restart timers, and a replacement route reschedules the restart only after the route has settled, so the render watchdog is less likely to be the first recovery path.

**Share:** Opens an adaptive `EpisodeShareSheet` that previews a rendered share
card and exports it with a validated publisher-facing episode page when one is
available. It never automatically shares the media enclosure or RSS feed URL.
When no safe public page exists, it shares the card and descriptive text only.
**Copy Link** appears only for a safe resolved page. Podcast Detail and Podcast
Settings use `PodcastShareSheet`, which shares the podcast's own artwork, title,
creator and description rather than silently substituting its newest episode.
Both iOS-family share sheets also offer **Review in Apple Podcasts** for the
show; the Player therefore exposes the action without adding another permanent
button to its compact five-control audio row. This action is absent from tvOS.

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

**Per-podcast setting.** Stored in `PlaybackPreference.vocalBoostLevel`. Audio episodes use the AVAudioEngine processing chain when Vocal Boost is on. Video episodes remain on AVPlayer and apply Vocal Boost as an `AVAudioMix` gain over the loaded audio tracks, so video playback never switches to the engine path.

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

**UI:** Top row of the Audio Controls sheet — toggle plus animated segmented speed picker when on. Both read the observable `SettingsViewModel.appSettings` snapshot so their switch/selection visuals update immediately; commands still route through AppState/`PlaybackPreferenceWorkflow` for live engine side effects. While active, the per-podcast Speed and Trim Silence rows below are greyed out (disabled), and the sound-controls button in the player's audio row reads the same observable snapshot and renders **white** (mirroring the active Sleep Timer button). Changes apply live to the playing episode through `PlaybackPreferenceWorkflow.effectivePreference(for:)`, which all playback paths read instead of raw `playbackPreference`.

---

## 6. Chapters

**Availability:** The Chapters panel in the player is only shown when the current episode has embedded chapter data.

**Display:** List of chapters with title and position. The currently playing chapter is highlighted. Disabling it from the Player immediately advances playback to the next enabled chapter; Podcast Settings disables that row to prevent accidental interruption.

**Skipping chapters:** Tap a chapter control to toggle its skipped state. `PlaybackChapterWorkflow` persists the new filter and pushes it into the active playback engine atomically, so an episode already playing uses the new filter immediately. Skipped chapters are automatically bypassed; a disabled final chapter uses the loaded media duration when RSS duration is unavailable.

**Chapter filter (per-podcast, per-position):** Disabled chapters are stored by position index in `ChapterFilter` on the `Subscription` model. Skips are **position-based and apply to all future episodes** of that podcast. This means disabling chapter 1 permanently skips the first chapter of every future episode — the primary use case being recurring show intros, sponsor reads, or outros that always appear in the same chapter slot.

**Editing chapter filter:** Available in the individual podcast's settings page (gear icon from episode list), under "Chapter Filter". While an episode from that podcast is loaded, the section uses that episode's chapter positions; otherwise it uses the newest episode with chapters.

---

## 7. Downloads

**What it is:** A view showing download activity and recently archived downloaded episodes.

**Download-first playback:** Autohop only plays files already on the device — no streaming. Background downloads keep the queue stocked automatically as new episodes are fetched.

**Auto-download:** New episodes discovered during a feed refresh are automatically scheduled for download after the feed has been fetched, parsed, and merged. The refresh cycle does **not** wait for the media file to finish downloading; download progress/completion is reported separately through the normal Downloads surfaces. User-initiated download/play-now paths still await the download where that behaviour is intentional. For rolling one-item feeds, such as hourly news bulletins, a newly discovered latest episode cancels a stale in-progress download for the previous latest episode immediately instead of waiting for app-start orphan cleanup.

**Stalled-download recovery:** The first-byte watchdog uses an absolute deadline
for each URLSession attempt, including across process suspension. It is
re-evaluated at lifecycle, network, BGTask, URLSession, and periodic checkpoints.
The deadline is **phase-aware**: an attempt created or first evaluated while the
app is active gets 60 seconds to produce its first payload byte, while an attempt
created or first evaluated while the app is backgrounded gets four minutes,
because background URLSession delegate delivery is legitimately slower and a tight
foreground deadline would otherwise cancel healthy transfers. Returning to the
foreground never shortens an attempt's existing deadline generation. Only
transfers that have already received payload data receive suspension grace.
Cancellation is generation-safe: exactly one terminal decision is allowed per
task generation, and live task progress/completion is re-checked before a cancel
is issued so a transfer that has finished out-of-process is not cancelled.
Automatic retries are bounded. After a 30/60/120-second short ladder exhausts,
the durable intent enters a persisted 15/30/60-minute cooldown. When that
cooldown ends, Autohop starts a fresh short ladder without erasing the durable
consecutive-exhaustion history. While foreground UI or active audio supplies a
real execution window, a recovery attempt can use an ordinary URLSession path
to avoid the cross-host background-session first-byte failure mode measured in
Log 23. That recovery path may bypass an open automatic circuit breaker, but
normal automatic work remains protected. The Downloads page says **Waiting to
retry** only while a concrete retry task owns the next attempt; otherwise it
offers **Retry Now**, which safely bypasses cooldown and circuit gates.

**Host circuit breakers (automatic downloads only):** Repeated *terminal* download
failures are tracked per media host. Two terminal failures on one host within a
10-minute window pause new **automatic** downloads to that host for 15 minutes;
if three or more distinct hosts are failing concurrently, new automatic download
starts pause globally for 5 minutes. A successful download clears its host's
breaker. Manual (user-initiated) downloads deliberately bypass all breakers, so a
struggling host never blocks an explicit tap. This prevents a dead or throttled
CDN from generating an endless retry storm in the background while leaving healthy
hosts unaffected.

**BGAppRefresh backlog handling:** A normal background wake protects a short
eight-feed base batch. If that batch finishes early, an optional second batch of
two to four deferred feeds may run when deadline, power, thermal, network, and
large-download conditions are safe. Conditional requests, Release Radar priority,
failure backoff, and oldest-deferred fairness apply to both batches.

**Download states:** `notDownloaded` → `queued` → `downloading` → `downloaded` / `failed`

**Downloads page rows:** three card sections — Downloading (progress bar + Resume/Retry Now + archive; controls are fixed-size so long progress text truncates rather than compressing buttons), Downloaded on Device, Recently Archived (re-download). **Waiting to retry** is displayed only while an actual scheduled retry exists; failed or ownerless paused work remains immediately recoverable with **Retry Now**. Audio/Video and Explicit pills sit inline next to the podcast title. Progress publishes are coalesced to ≥1% steps so multiple concurrent downloads don't re-render whole pages every second. Opening the page records aggregate state counts for diagnosis but does not secretly restart downloads.

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
During the final 30 seconds, playback follows the shared smooth sleep-fade
envelope before pausing. Extending or cancelling during the fade restores full
playback volume immediately.

### End of N Episodes mode
A stepper (range: 1–10, default: 1) lets the user choose how many episodes to finish before sleep. Tap **Set** to start. While active: shows episodes remaining with a **Cancel** button.

**Sheet height:** 380pt when inactive (preset grid + episode row). 240pt when a timer is active.

### 8.1 Sleep Schedule

**Access:** Menu → Sleep Schedule (`SleepScheduleView`). The recurring nightly counterpart to the one-shot Sleep Timer. Timing logic lives in `Playback/SleepScheduleService.swift`; `PlaybackCoordinator` owns its callbacks and active playback-session integration, while `AppRuntimeWorkflow` applies settings and scene/runtime policy.

> **Marketing note:** Sleep Schedule should be described as a shipped Autohop
> recurring sleep-timer feature, not as a competitor claim. It appears as a
> feature card on the kevmarl.com promo page and has its own section in the
> support guide.

**Settings (persisted in `AppSettings`):**
- **Toggle** — `sleepScheduleEnabled` (default off). Runs every night when on.
- **Active Hours** — start/end time pickers (`sleepScheduleStartMinutes`/`sleepScheduleEndMinutes`, minutes from midnight; default 9:00pm–6:00am). The window may span midnight; start == end means always active.
- **Ask Every** — duration presets 10 / 15 / 20 / 40 / 60 minutes (default 20) plus **End of Episode** (stored as `sleepScheduleDurationMinutes = 0`).

**Behaviour:**
1. The schedule **arms** — it never self-starts audio. Whenever playback starts (audio or video) inside the window, the cycle begins.
2. After the chosen duration of playback (or at the episode boundary in End of Episode mode), a soft singing-bowl-style chime asks "Are you still listening?" — **playback keeps going**; the chime (C4 fundamental with quiet partials, slow ~0.5 s attack, ~7 s decay) plays over it at 0/20/40 s inside a single 60 s in-memory WAV via `AVAudioPlayer` (keeps the audio session rendering so the app isn't suspended while waiting; a 75 s backup `Task` covers audio failure). In End of Episode mode the queue still advances to the next episode under the chime.
3. **Any transport command is "yes"** — play/pause (lock screen, earbud tap, headphone remote), skip forward/back, scrubbing, the oversized on-screen overlay button in `PlayerView` (shown for the screen-on/video case; a deliberately large `minHeight: 160` "Still Listening" target for half-asleep tapping), or the **"Still Listening" action on the lock-screen notification** (see below). The cycle restarts; a pause press both confirms and pauses (the re-armed countdown freezes until resume).
4. **No response within 60 s = asleep.** Playback follows the same smooth 30-second fade used by the manual timer, pauses, and **rewinds to where the chime started** — the last point plausibly heard, persisted as the morning resume position (start of the auto-advanced episode in End of Episode mode). The session ends; the schedule re-arms on the next playback start inside the window.
5. **Manual Sleep Timer overrides:** setting the regular Sleep Timer suspends the schedule for the rest of that session (`suspendForSession`, checked on every 0.5 s tick).
6. The countdown only advances while playing — pausing freezes it. **Active Hours are a hard boundary:** when the configured end time arrives, any countdown or End-of-Episode arming is cancelled, and an in-progress chime/overlay/lock-screen notification is dismissed without pausing normal playback. A late "Still Listening" action cannot re-arm the schedule outside the window.

**Lock-screen "Still Listening" notification:** When the prompt fires, Autohop also posts a local notification (`NotificationService`) titled "Are you still listening?" carrying a **"Still Listening" action button**. It's a background action (empty options) so tapping it on the lock screen confirms **without unlocking or opening the app** — routed through the notification-centre delegate to `userResponded()`, exactly like a transport command. The notification uses `interruptionLevel = .timeSensitive` so it breaks through Sleep Focus / Do Not Disturb at night (requires the **Time Sensitive Notifications** capability on the app target). It is cleared automatically whenever the prompt ends (confirmed, timed out, suspended, or reset) via the service's `onPromptDismissed` callback.

**Player indicator:** While inside the active-hours window, the player top bar shows a Sleep Schedule pill (see §4) with the minutes remaining until the next prompt.

---

## 9. Video Podcasts

**Support:** Full audio and video podcast support. `Episode.mediaKind` is either `.audio` or `.video`.

**Artwork presentation:** Video feeds often supply 16:9 episode posters. Autohop
uses a centred square crop for podcast-artwork slots in episode lists, Home
Screen widgets, CarPlay, and system Now Playing rather than stretching the image
or allowing it to overflow. The actual video player retains the source aspect
ratio.

**Playback path:** Video episodes always use AVPlayer (the video UI requires it). Vocal Boost can still be applied to video as an AVPlayer `audioMix`; Trim Silence is audio-only because it depends on the AVAudioEngine buffer-processing path.

**Full-screen playback:** Entering full-screen video preserves the exact
effective playback speed and whether playback was playing or paused. The AVPlayer
default rate remains aligned with the per-podcast preference so AVKit cannot
silently reset a preferred speed such as 1.4x to 1x during presentation.
Full-screen presentation unlocks user-driven landscape rotation before the
transition begins; it does not force a geometry change while UIKit is presenting
the player. SwiftUI owns `AVPlayerViewController` containment, avoiding conflicting
parent-controller state while retaining the explicit Picture in Picture fallback.

**Platform parity:** tvOS uses the shared streaming AVPlayer engine, which follows
the same persistent `defaultRate` policy. The custom iOS full-screen transition is
phone/tablet-specific; the underlying playback-speed behaviour stays unified.

**Chapters:** Chapter navigation works on video episodes.

**Badges:** Video episodes show a "VIDEO" badge in episode list rows and on the episode detail view.

---

## 10. Per-Podcast Settings

**Access:** Priority page → tap podcast row → episode list → gear icon (⚙) in top-right toolbar.

The settings page is titled with the podcast name and groups settings into sections. It uses the shared dark settings style (`Form-SettingsDark` in DESIGN.md): a purple `SettingsRowLabel` glyph on every control row, purple tint, and 36pt section spacing. On iOS 26 every section uses the same regular `glassEffect` surface as the Playback controls card, so the whole page reads as one consistent glass treatment; below iOS 26 it falls back to `white.opacity(0.08)` cards on black.

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
| Trim Silence | Off / Low / Medium / High | **Low** | Audio episodes only. See [Trim Silence](#42-trim-silence). |
| Vocal Boost | Off / Light / Standard / Strong | **Strong** | See [Vocal Boost](#43-vocal-boost) for full chain description. |
| Volume Adjustment | −3 dB … +3 dB (whole-number steps) | **0 dB** | Fourth item in the per-podcast Playback card, between Vocal Boost and Mono Audio. A purple stepped slider compensates for a podcast mastered quieter or louder than the rest of the library. Audio uses a dedicated final EQ gain stage, independent of device volume and sleep fading. Stored and synced inside `PlaybackPreference`; changes apply immediately. This is deliberately per-podcast only and is not shown in global Default Playback. |
| Mono Audio | Stereo / Mono | **Stereo** | Final item in the Playback card, presented as a full-width two-option segmented selector matching Trim Silence and Vocal Boost. Audio episodes only. Mono averages the decoded left and right channels and sends the centred result to both outputs, correcting podcasts whose presenters are mixed heavily toward one side. The System Settings value is the default for future subscriptions; each existing podcast keeps its own value. |
| Start skip | 0 – 300s (5s steps) | **0 (off)** | Automatically skips N seconds at the start of every episode. Measured in real file time, independent of playback speed. Primary use case: skipping recurring show intros or theme music. |
| End skip | 0 – 300s (5s steps) | **0 (off)** | Automatically skips N seconds at the end of every episode. Measured in real file time, independent of playback speed. Primary use case: skipping recurring outros or trailing ad reads. |

**Footer notes (shown in app):** "Volume Adjustment balances podcasts that are quieter or louder than the rest of your library without changing device volume. Vocal Boost improves speech clarity, while Trim Silence removes quiet gaps (audio episodes only)." and "Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically."

**Trim control UI:** Start skip and End skip use the shared `EpisodeTrimControlRow` component on both the per-podcast page and the global Default Playback page. Each row shows compact elapsed wording (`Off`, `45 secs`, `1 min 30 secs`), steps in 5-second increments, clamps to 0…300 seconds, updates its on-screen value immediately, and debounces persistence so rapid taps do not cause sluggish playback-side updates.

---

### 10.3 Automation section

| Setting | Default | Description |
|---|---|---|
| New episode notifications | **Off** | Sends a notification when a new episode is published. Off by default — users opt in only for shows they want to be notified about, to avoid unwanted interruptions. Requires the global notification toggle (Settings → Release Radar → Notification Settings) to also be on. |
| Exclude from Auto Feed Refresh | **Off** | When on, Autohop stops polling this podcast's RSS feed during automatic/feed-all refresh cycles and moves it to the bottom of the Priority Stack with the Inactive pill. The podcast remains subscribed, keeps its downloaded episodes, can still be manually refreshed from its own detail page, and returns to its saved priority position when the setting is turned off. |
| Play Instant | **Off** | For a deliberately small number of absolute-favourite shows. When a filter-eligible new episode finishes an **automatic** download while another episode is actively playing, Autohop sounds a gentle two-note warning, waits two seconds, saves the current position, and plays the arrival ahead of Up Next. It does not interrupt when the current episode has exactly 60 seconds or less remaining; the arrival stays armed and may trigger after natural advancement. If playback or its route is temporarily inactive at completion, the episode remains armed for up to 30 minutes and triggers when safe playback resumes; Autohop never starts it unexpectedly through the phone speaker. Natural completion or Mark Played returns to the exact interrupted position. Multiple qualifying arrivals use FIFO order. Pausing during an active Instant session, archiving, choosing another episode, or manually skipping Next cancels the automatic return. Manual downloads, backlog files and filter-skipped episodes do not trigger it. Stored and synced with the podcast's `AutoArchiveSettings` payload for backward-compatible per-subscription persistence, but presented here because it is automation rather than an archive rule. |

**Play Instant footer note (shown in app):** Play Instant interrupts active playback after an automatic download, except when the current episode has 60 seconds or less remaining. A temporarily unavailable route arms the episode for up to 30 minutes; it triggers only after safe playback resumes and never autoplays through the phone speaker.

---

### 10.4 Auto Archive section

Three independent rules. All are stored in `AutoArchiveSettings` on the `Subscription` model. `AutoArchiveCoordinator` exclusively owns rule evaluation, activity auditing, and the pass that runs at most every **25 minutes** while the app process is active, including background-audio playback; the pass is also requested at launch, after a completed feed refresh, and on demand. Every pass writes an `autoArchive.eligibility` diagnostic summary so a zero-result run explains how many episodes were evaluated, protected, still below threshold, or excluded. New subscriptions are seeded from the **global Auto Archive default** (App Settings → Auto Archive, §15.2); the defaults below are the factory values of that global default. Changing a podcast's rules here only affects that podcast.

| Rule | Setting name | Options | Default | Description |
|---|---|---|---|---|
| Rule 1 | Played Episodes | Never / After Playing / After 24h / After 2 Days / After 1 Week | **After Playing** | Archives a played episode immediately on completion, or after a delay. "After Playing" archives as soon as the episode finishes. |
| Rule 2 | Inactive Episodes | Never / **30 Minutes** / 4h / 6h / 8h / 12h / 16h / 24h / 2 Days / 3 Days / 4 Days / 5 Days / 1 Week / 2 Weeks / 30 Days / 90 Days | **1 Week** | Archives downloaded-but-unplayed episodes that haven't been played within the set interval of being downloaded. The 30-minute per-podcast option targets hourly news bulletins so an aging downloaded bulletin is removed around the time its replacement becomes available. The inactivity clock starts when the file lands on device (`Episode.downloadedAt`) and resets if the user starts playing the episode (`Episode.lastPlayedAt`). Episodes that have **never been downloaded** are completely exempt. Feed refreshes preserve both local timestamps by stable episode GUID. With the 25-minute gate, a 30-minute timeout is normally enforced between approximately 30 and 55 minutes after last activity. |
| Rule 3 | Episode Limit | No Limit / 1 / 2 / 3 / 4 / 5 / 10 | **1** | Retains the newest N automatically managed downloads and replaces the oldest when a newer episode arrives. Explicit downloads, active playback, and Play Next/Play Last pins are protected and do not consume automatic slots. Changing the limit does not backfill older episodes. Failed and never-downloaded episodes do not consume a slot. |

**Footer note (shown in app):** "Played Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives downloaded-but-unplayed episodes that haven't been played within the set time of being downloaded. The 30 Minutes option is useful for frequently replaced hourly news bulletins. Episode Limit rotates automatic downloads to keep the newest selected number; manually downloaded and manually positioned Up Next episodes are protected. Changing the limit does not download older episodes. Automatic downloading still follows this podcast's Download Feed Filters. Auto Archive runs at most every 25 minutes."

**Fresh-subscription backlog exemption:** When you subscribe to a show, its pre-existing back-catalogue (every episode published on or before the moment you subscribed, tracked by `Subscription.subscribedAt`) is left **browsable as Unplayed** — the Inactive Episodes and Episode Limit rules skip it. This stops subscribing to an established show from archiving its entire 50-episode backlog (and flooding Stats) on day one. Only episodes that arrive **after** you subscribe flow through the inactive/limit lifecycle. The newest auto-download eligible episode downloads immediately; Download Filters can make Autohop look back to a newer matching eligible episode instead of the raw latest item. Legacy subscriptions created before this field existed have no `subscribedAt` and keep the old behaviour.

---

### 10.5 Chapter Filter section

Shown using the loaded episode when that podcast is currently playing; otherwise the newest episode supplies the position list.

| Behaviour | Detail |
|---|---|
| Toggle chapter | Tap a chapter row to enable/disable it. Podcast Settings protects the current row; Player toggles are live and immediately advance if the current position is disabled. |
| Scope | Position-based. A disabled position is skipped in all future episodes of this podcast. |
| Primary use case | Permanently skip recurring chapters at a fixed position — show intros, sponsor reads, or outros that appear in the same chapter slot every episode. |

---

### 10.6 Download Filters page

**Access:** Podcast Settings → Feed → Download Filters.

Download Filters are stored in `DownloadFilterSettings` on the local `Subscription` model, and since July 2026 they also roam via iCloud Sync as part of the per-podcast settings record (struct-level last-write-wins — the most recently edited device's full filter set wins). Filters affect automatic downloads from refresh, background refresh, and the priority auto-download flow; manual episode actions (Play, Play Next, Play Last, Download) bypass filters. Episodes skipped by filters are excluded from Release Radar's learned feed schedule, so their publish dates/times do not train future refresh windows.

| Control | Options | Default | Notes |
|---|---|---|---|
| Match mode | All / Any segmented control | **All** | Controls how include rules combine across enabled groups. Exclude rules always win. |
| Duration filters | On / Off | **Off** | When enabled, duration rules can include/exclude episodes longer than or shorter than 1–300 minutes. Missing duration is skipped. |
| Title filters | On / Off | **Off** | Case-insensitive simple text matching. Rules support contains / does not contain. Empty text rules are ignored. |
| Description filters | On / Off | **Off** | Case-insensitive simple text matching. Rules support contains / does not contain. Empty descriptions behave like empty text. |
| Add rule | Plus icon button per group | — | Adds a sensible default row: duration Include · Longer than · 40 min; title Include · Contains; description Exclude · Contains. |
| Preview Matches | Button | — | Fetches the latest RSS feed read-only and shows up to 50 current episodes. Included rows render normally; skipped rows are greyed out and show a concise reason. Preview errors show retry copy and do not fall back to stored episodes. |

When all three filter groups are off, no filtering occurs and Autohop downloads the next available episode as before. When filters are active, automatic refresh looks through the merged feed and downloads the newest eligible unplayed, unarchived, not-yet-downloaded episode. Episodes skipped by filters remain visible with a grey **Skipped** pill, do not count toward Episode Limit because they were never downloaded, and do not influence Release Radar prediction schedules.

---

### 10.7 Feed section

| Field | Description |
|---|---|
| URL | The podcast's RSS feed URL. Read-only display. |
| Download Filters | Opens the per-podcast Download Filters page. |

---

### 10.8 Danger section

| Action | Description |
|---|---|
| Unsubscribe | Removes the podcast and all its settings from Autohop. Downloaded episode files are not deleted — they remain on device until iOS cleans them up. Requires confirmation. |

---

## 11. Listening History

Listening progress is accumulated from the playback clock and persisted in efficient
30-second batches. Pause, backgrounding, sleep stops, and episode completion immediately
flush the final batch, retaining accurate resume positions and iCloud history without
performing disk and sync bookkeeping every half-second.

**Access:** Hamburger menu (☰) on the Subscriptions page → Listening History.

**What it tracks:** Every episode the user has listened to, recorded in `ListeningHistoryStore` → `listening-history.json`.

**Minimum threshold:** Episodes where `listenedSeconds < 60 AND lastPositionSeconds < 60` are excluded from all lists. Episodes played or archived without at least 1 minute of actual playback are not shown.

### Stats header
Two summary cards at the top of the page:
- **Listening Time** — total hours and minutes across all recorded history entries that meet the minimum threshold.
- **Episodes** — total count of episodes with status `.played` or `.archived` that meet the minimum threshold (i.e., all finished episodes, including auto-archived ones that were genuinely listened to).

### History list
Episodes grouped by date: Today, Yesterday, then older dates (abbreviated format). Within each group, sorted most recent first. Each row shows:
- 44 pt episode/podcast artwork, matching the canonical Subscription episode row
- Episode title in `.subheadline.semibold`, followed by the podcast name in `.caption.secondary`
- A shared `EpisodeStatusPill` representing the stored historical outcome: Played, Archived, or Paused (Playing only while an unresolved entry is currently audible)
- Event metadata with an exact local date and time: Completed, Manually Archived, Auto Archived, legacy Archived, or Last listened

History deliberately resolves status from the stored entry rather than a later
episode-library mutation. `lastListenedAt` is the event timestamp: terminal
completion/archive paths stamp it when the action occurs, while unresolved rows
use it as their latest listening time. Older entries without `CompletionKind`
fall back honestly to their persisted Played/Archived/Listened status.

Rows that still resolve to a current library episode use the same four swipe
positions and behavior as Podcast Detail: Play / Play Next on the leading edge,
and a state-driven Download/Archive/Unarchive action plus Play Last on the
trailing edge. Full swipe is disabled and the current playing episode exposes no
swipes. Play, Play Next, and Play Last manually download first when necessary;
the standalone Download action adds the episode to priority-sorted Up Next
without starting playback. While any of these actions downloads an episode, the
standard animated purple progress bar appears beneath the row, aligned past the
History page's 54 pt artwork.

| Status | Meaning |
|---|---|
| Listened | Partially played — did not finish. Shows time remaining. |
| Played | Episode marked as played. |
| Archived | Episode was archived. |

### Search
Filters by episode title or podcast name. Results update as the user types. Same 60-second minimum threshold applies to search results. Search bar is always visible (`.navigationBarDrawer(displayMode: .always)`).

---

## 12. Stats

**Access:** Hamburger menu (☰) on the Priority page → Stats, or directly from a Listening Recap notification.

**What it is:** A lifetime summary of the user's listening activity and time saved by Autohop's audio processing features. Data is persisted in `ListeningStatsStore` → `listening-stats.json`.

### Data collection (June 2026)
All listening activity is bucketed per local calendar day in `DayStats` records (a few hundred bytes each, so lifetime retention is cheap). Each day records: elapsed wall-clock seconds, per-hour histogram (24 buckets), per-show seconds (keyed by subscription UUID, with a title map that survives unsubscribes), per-show episode starts/completions, the four time-saved categories, global episodes started/completed, and manual skip-forward count. iOS and tvOS both convert playback progress to elapsed wall time before recording. Variable-speed saving is elapsed time × (speed − 1), i.e. the extra media consumed in that elapsed interval. Totals accumulated under the previous lifetime-only store (`playback-stats.json`) are imported once as a baseline so existing users keep their history; the legacy file is left in place.

Hooks: playback tick (0.5 s) → listening time + hour + show attribution; `SilenceDetector` callbacks → exact trimmed seconds; `startPlayback` from a fresh position → episode started; `handleEpisodeFinished` → episode completed. Saves are throttled to 30 s during playback and flushed on pause and when the app leaves the foreground.

Query API on `ListeningStatsStore`: `summary(for: .last(days:)/.lifetime)` (period aggregates incl. per-show, hour histogram, zero-filled day series for heatmaps), `lifetime` (legacy `PlaybackStats` shape used by `StatsView`), `currentStreakDays` / `longestStreakDays` (a day counts toward a streak at ≥ 60 s of listening). This is the data layer for the planned rich Stats page (period selector, heatmap, listening clock, top shows).

### Page layout (`Views/StatsView.swift`, June 2026)
All sections respond to a period selector at the top: **7 Days / [displayed month] / [displayed year] / Lifetime** (purple pill row); the page **opens in 7 Days** by default. The middle two pills are dynamically labelled from the active This/Last selection — the current or previous month name (e.g. "July" / "June") and the current or previous year (e.g. "2026" / "2025"). Cards follow the standard design system (`Section-Heading` + `white.opacity(0.08)` rounded cards, dark scheme, purple accent).

The first three ranges are **calendar-anchored** and reset at the start of each period (rather than being rolling trailing windows):

| Pill | Window | Resets | Rank-movement compares against |
|---|---|---|---|
| **7 Days** | Monday 00:00 → now (Monday = first day, Sunday = last, independent of locale) | every Monday | the previous full Monday–Sunday week |
| **[Month]** (e.g. "July" / "June") | 1st of the displayed month 00:00 → now for This Month, or the previous full calendar month for Last Month | the 1st of each month | the previous full calendar month |
| **[Year]** (e.g. "2026" / "2025") | Jan 1 of the displayed year 00:00 → now for This Year, or the previous full calendar year for Last Year | Jan 1 | the previous full calendar year |
| **Lifetime** | all recorded history | — | no comparison (no previous period) |

Each is near-empty at the start of its period and fills in as it progresses.

**This / Last toggle.** Below the pill row, a distinct **solid segmented bar** (a purple sliding chip on a flat track — deliberately styled differently from the glass pills) switches the selected Week / Month / Year between the current period and the **previous concluded one**, with contextual labels inside it (**This Week / Last Week**, This Month / Last Month, This Year / Last Year). Selecting "Last" drives the whole page — hero numbers, heatmap (laying out the prior week/month grid), trend chart, clock, top shows (with rank-movement vs. the period before *that*), time-saved, and data-downloaded — from the concluded period (`StatsPeriod.previousWeek/.previousMonth/.previousYear`). The bar is **hidden entirely** when **Lifetime** is selected, or when **the previous period has no listening** (`store.summary(for: previous).wallClockSeconds == 0`), except when opened from a Listening Recap notification, where the intended Last period is shown even if empty. Per-show detail cards are upper-bounded so a concluded period doesn't bleed into the present, and the present-tense "Shows You're Drifting From" section is hidden in Last mode. This toggle is the in-app surface the weekly/monthly/yearly **Listening Recap** notifications deep-link into.

1. **Hero card** — big "Time listened" number (purple; Lifetime adds "since [date]"), plus three columns: time saved by Autohop (teal), episodes finished, and current streak (a day counts at ≥ 60 s of listening). Listening is elapsed wall time derived from natural media progress divided by effective playback speed on both iOS and tvOS, so faster playback cannot inflate any time-based statistic. The imported pre-daily-bucket baseline is included in Lifetime and in any calendar period that wholly contains its known start-to-cutover interval; it is never partially guessed across a boundary.
2. **Top Shows** — up to 8 ranked rows: rank · 44 pt artwork (`Artwork-Placeholder` fallback) · show title with a purple bar relative to the #1 show · time listened. Titles resolve from the stats store's title map, so unsubscribed shows still appear. When more shows than fit have listening time, a **Show All ›** link in the section header pushes a full **Top Shows** screen (top 50, same row design and period selector). There, each row also shows a rank-movement badge vs. the previous comparable period — the previous week, calendar month, or calendar year (teal ▲n, grey ▼n, or purple NEW; no badges on Lifetime, which has no previous period; previous ranks are computed across all shows, not just the top 50, via `ListeningStatsStore.previousPeriodShowSeconds(for:)`). Tapping any Top Shows row (main section or Show All) expands an inline **per-show detail card** (`ShowStatsExpandedCard`): episodes finished, time saved (real per-show value from `DayStats.perShowTimeSaved` — variable speed, trim silence, and skips are attributed to the playing episode's subscription; each pre-tracking day falls back to apportioning that day's total by listening share, labelled "est.", including within mixed legacy/current ranges), share of all listening, average completion %, episodes stopped partway, last-listened date, and listening cadence ("typical wait after release" — median delay between an episode's publish date and the last listen). Finished counts use durable per-show daily counters; days recorded before those counters existed are recovered from retained history and sticky completed episode state, deduplicated by media URL, with the greater independently evidenced count used to avoid migration overlap. Remaining completion-detail and abandonment evidence comes from `ListeningHistoryStore` entries classified by `ShowEngagementAnalyzer.classify`, filtered to the selected period; bounded history retention is 5,000 entries. Tap again to collapse.
3. **Shows You're Drifting From** (7 Days and the current month only, and only in **This** mode — hidden when the This/Last bar is on "Last", since it's a present-tense signal) — up to 5 currently-subscribed shows the user appears to be struggling with, computed by `Stats/ShowEngagementAnalyzer.swift` (pure functions, smoke-tested in `StatsSmokeTests`) over `ListeningHistoryStore` entries. Episodes currently shown as **Skipped** by Download Feed Filters (filter-rejected and not downloaded) are removed before analysis, because deliberately declining an episode is not evidence of drifting from its show; manually downloaded/played episodes remain eligible because manual actions intentionally bypass filters. Each remaining entry is classified as completed (finished naturally or ≥ 90%), abandoned (≥ 60 s listened, ended < 80%), or archived unplayed (< 60 s; deliberate vs. auto-archive); in-progress and ambiguous legacy entries are skipped. Struggle score = (abandoned + deliberate archives + 0.5 × auto archives) / resolved episodes. A show qualifies via **either** path: **drift** — ≥ 4 resolved episodes, a score ≥ 0.4, **and ≥ 2 genuine drift signals** (abandoned mid-listen or deliberately archived unplayed); or **neglect** — a "ghost subscription" with **zero completions and ≥ 4 auto-archived unplayed episodes**, i.e. new episodes keep arriving and aging out of the episode limit while the user never once finishes one. The **completion count** (not the auto-archive rate) is what separates a ghost sub from healthy high-volume use, where the user finishes some episodes and lets the rest cycle — those stay out of the list, so a daily news feed you actually dip into is never flagged (thresholds are constants in the analyzer). Rows: artwork · title · a blunt insight line ("Archived 6 of the last 8 unplayed", "Downloaded 7, never played" for a ghost sub, "You usually stop around the 12-minute mark" from the median abandon position) · a stacked completion bar (`Chart-CompletionBar`: teal finished / orange partial / dim unplayed) · finished/total fraction. Tapping a row expands an inline detail card (see below) with a **Podcast Settings** link; long-press offers Hide From This List (persisted in `UserDefaults` key `stats.hiddenDriftShowIDs`) and Unsubscribe. Only real, active subscriptions appear: `StatsView` filters out shows the user has unsubscribed from **and** invisible browse/preview subscriptions (`browseDate != nil`, auto-created when previewing a podcast in search) — without the latter filter, a previewed-but-never-subscribed show could surface via the neglect path. The section is omitted entirely when nothing qualifies — no empty state. Not shown on the year / Lifetime views (the 500-entry history cap truncates long ranges). The listening-history value types (`ListeningHistoryEntry`, `ListeningHistoryStatus`, `CompletionKind`) moved from `App/AppState.swift` to `Models/ListeningHistory.swift` so AutohopCore and the smoke tests can use them.
4. **Listening Heatmap** (7 Days and month) — GitHub-style grid, columns are Monday-aligned weeks and rows are weekdays, purple intensity scales with that day's listening (√-scaled so light days stay visible). Caption shows the busiest day. On the year and Lifetime views this is replaced by **Listening Over Time**, a Swift Charts monthly bar chart. Imported legacy totals predate daily attribution, so an enclosing year/Lifetime includes them in its headline while the chart displays the attributable buckets and explains the difference.
5. **Listening Clock** — 24-hour rose chart (Canvas): midnight at top, noon at bottom, each hour a wedge whose radius scales with listening in that hour. Caption shows the peak hour range.
6. **Data Downloaded** — a card showing the total data Autohop downloaded in the selected period (`ByteCountFormatter` `.file` style, e.g. "1.2 GB"), with a context line "N episodes · avg X each". Recorded per calendar day in `DayStats.bytesDownloaded` / `episodesDownloaded` (summed per period and cross-device sync-merged like the other stats), incremented by `DownloadTransferWorkflow` and the background-settlement path using the actual on-disk file size. **Forward-only** — tracking began June 2026, so there is no backfill: only successful downloads count (re-downloads count again as real traffic; cancelled/failed/partial do not), and Lifetime accrues from this build onward.
7. **Time Saved By** — breakdown card (rows below) plus a purple Total row.
8. **Privacy footer** — "Your listening stats are private — kept on your device and your own iCloud, never sent to Autohop."

### Time Saved breakdown
Four rows showing how much time has been saved by each feature in the selected period:

| Stat | How it's calculated |
|---|---|
| **Skipping** | Sum of all manual skip-forward taps (skip amount, not wall clock). Backward skips are not counted. |
| **Variable Speed** | Natural media-position delta is converted to elapsed time as `mediaDelta / speed`; saved time is then `elapsed × (speed − 1)`. Represents the media time avoided versus listening at 1× without allowing callback frequency to inflate listening time. |
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
| Global | New episode notifications | **Off** | Settings → Release Radar → Notification Settings |
| Per-podcast | New episode notifications | **Off** | Per-podcast Settings → Automation, or Settings → Release Radar → Notification Settings |

**Behaviour:** A notification fires only when both the global toggle and the per-podcast toggle are on. Both default off, so the app is silent until the user explicitly opts in — first by enabling the global toggle, then per show.

**iOS permission:** `UNUserNotificationCenter` authorisation is **not requested at launch**. `NotificationService.configure()` (called from `AppDelegate`) only installs the delegate + notification categories; the system permission prompt is deferred until the user opts in — enabling a notification toggle, or turning on Sleep Schedule (`NotificationService.requestPermission()`). `NotificationService` is also the app's `UNUserNotificationCenterDelegate`.

**Sleep Schedule prompt notification:** Separate from new-episode alerts, `NotificationService` also posts the time-sensitive "Are you still listening?" lock-screen notification with its background "Still Listening" action button (see §8.1). This is generated locally on demand and is not gated by the per-podcast notification toggles.

### 14.1 Listening Recaps (opt-in periodic summaries)

A family of notifications that summarise the user's listening when a period concludes. Three independent toggles (`AppSettings.recapWeeklyEnabled / recapMonthlyEnabled / recapYearlyEnabled`), with **weekly on for new users** and monthly/yearly off, in a **Listening Recaps** sheet (`RecapSettingsView`) reachable from **two places**: the **bell button in the Stats page toolbar**, and a **Listening Recaps row in Notification Settings**.

| Recap | Delivered | Covers |
|---|---|---|
| Weekly | Monday 09:00 | the prior Monday–Sunday week |
| Monthly | 1st of the month 09:00 | the prior calendar month |
| Yearly | Jan 1 09:00 | the year just gone |

**Mechanism (B — teaser + in-app numbers).** Each recap is a **recurring local `UNCalendarNotificationTrigger`** scheduled by `NotificationService.scheduleRecaps(weekly:monthly:yearly:)` (idempotent — called on every toggle change, on `RecapSettingsView` appear, and at launch from `RootView` so they survive relaunch/reinstall). Because local notifications carry fixed content, the body is an **evergreen teaser** ("Your week in listening 📊 — Tap to see how you listened last week."); the real figures are shown **in-app** when the user taps it, which deep-links into the Stats **"Last"** view for that period via the notification's `userInfo` recap key. Delivery time is a fixed 09:00 local; recaps use normal priority (respect Focus/DND).

**Opt-in & permission:** enabling any toggle requests notification permission via the same `requestPermission()` path as new-episode alerts; a denied-permission banner with an "Open iOS Settings" link is shown. All computed on-device — listening data never leaves the phone.

> Known v1 trade-off: with pre-scheduled local notifications a recap still fires for a quiet period (it can't be cancelled at the boundary without background execution); the recap deep-link still opens the intended Last Week / Last Month / Last Year Stats view, which shows the normal empty-period state when there is no listening.

---

## 15. App Settings

**Access:** Hamburger menu (☰) on the Priority page → Settings.

The page uses the shared dark settings style (`Form-SettingsDark` in DESIGN.md): a purple `SettingsRowLabel` glyph on every control row, purple tint, and 36pt section spacing. On iOS 26 it uses "defined glass" — native Liquid Glass Form sections lifted by a faint `white.opacity(0.05)` row tint over a `black.opacity(0.5)` page base so card edges read clearly; below iOS 26 it falls back to `white.opacity(0.08)` cards on black. The Default Playback card (§15.5) is matched to the other section cards (via `usesHostBackground`), and the linked sub-screens (Notification Settings, Add RSS Feed, Diagnostic Log, Acknowledgements) and Podcast Settings (§10) share the same style. Long section footers are split into multiple paragraphs for readability.

---

### 15.0 Startup

| Setting | Type | Default | Description |
|---|---|---|---|
| Open at launch | Menu picker | **Player** | Which screen Autohop opens to on a normal cold launch: **Player**, **Subscriptions** (your Priority Stack), or **Discover**. Discover/Subscriptions are pushed above the always-alive Player, so the back chevron unwinds to the Player. Stored in `AppSettings.launchScreen`. The first-run Welcome flow always takes precedence for brand-new users; this preference applies once onboarding is complete (see §18). |

---

### 15.1 Release Radar

Release Radar is Autohop's automatic feed-refresh system. Its job is to prioritise feeds when new podcast episodes are expected while avoiding wasteful checks during periods when a feed is predictably quiet. `FeedRefreshCoordinator` owns refresh-cycle state, backoff, deferred-feed fairness, background-audio cadence, and the Release Radar profile cache; `AutoDownloadIntentWorkflow` owns durable scheduling, eligibility revalidation, serialized draining, and terminal settlement over state retained by `AutoDownloadWorkflow`. Exact discovery timing depends on when Autohop is active and when iOS grants background execution.

> **AI CONTEXT — automatic policy update (2026-07-15):** Radar Sensitivity is no longer user configurable. During confirmed background playback, polling is bounded to one cycle every four minutes. Seven routine feeds may be checked; pre-window, active-window, and missed-release work may extend the cycle to a hard maximum of ten. Low Power Mode, thermal pressure, constrained/cellular networking, and large active downloads reduce these budgets.

**When checks run:** Autohop checks due feeds (1) on a ~30-second timer while the app is open, (2) **while you're listening with the app in the background** — audio playback keeps the app alive, so due feeds are refreshed and new episodes downloaded on the same cadence as in the foreground, (3) opportunistically via iOS Background App Refresh (`BGAppRefreshTask`), whose timing iOS controls and never guarantees, and (4) as a longer catch-up via a `BGProcessingTask` that iOS runs while the device is **charging and on Wi-Fi** (typically overnight) — a full sweep of every due feed plus downloads, so you wake up current even after a long stretch without opening the app. Newly found episodes download via a background `URLSession` that continues even if the app is later suspended. If the user has turned **Background App Refresh** off for Autohop, iOS grants *no* off-app checks at all; **Settings → Release Radar** then shows a warning with an **Open iOS Settings** link explaining this (and that force-quitting the app also stops background checks). (Background-task reliability research and the design rationale live in `BACKGROUND_REFRESH_RESEARCH.md`.) **Settings → Release Radar → Feed Refresh Schedule** (`FeedRefreshScheduleView`) shows a per-active-subscription table of when Release Radar will and won't check each feed — learned profile + confidence, current state, the recurring watch pattern, and the next concrete window — grouped by behaviour (Inactive subs excluded). Each row has a **Rebuild Prediction** button that fetches the feed's last 100 episodes' publish dates **and times** into the learner (without adding episodes to your library) to form a stronger schedule prediction; episodes skipped by Download Filters are excluded from that learner. For a weekly show this is typically enough history to size its release window from the observed publish-time spread. The page also has a toolbar **export** button that writes a shareable plain-text diagnostic of every active subscription — each show's classification, daily/weekly gate outcomes, learning signal, learned window, observed spread, weekday counts, **per-weekday watch tiers** (probability → Full/Light/Skip), and recent eligible observations — so the whole picture can be exported and analysed for trends.

**BGProcessing cadence:** Catch-ups are outcome-paced rather than immediately re-requested. Useful runs wait at least 18 hours, empty runs 24 hours, and expired runs retry with persisted exponential backoff; small positive jitter avoids metronomic wake patterns. An already-pending request is preserved.

| Setting | Type | Default | Range | Description |
|---|---|---|---|---|
| Notification Settings | Page link | — | — | Opens the Notification Settings page: the global "New episode notifications" master toggle (default **On for new users**), Enable All / Disable All buttons, and a per-podcast toggle row (artwork + title) for every subscription. iOS notification permission remains a separate system choice and is requested contextually rather than at launch. If permission is denied, a banner with an "Open iOS Settings" deep link is shown. A notification fires only when the master toggle, the podcast's own toggle, and system permission are all on. |

**Core promise:** a feed that usually releases at a known time should be watched aggressively near that time, then left alone when it is unlikely to publish. A feed with no reliable pattern is still checked at a lower surveillance cadence. Learned windows are an optimisation, never an indefinite gate: background-audio checks impose a 90-minute maximum successful-check age, BGAppRefresh/BGProcessing use a two-hour general ceiling, and recognised hourly/news-bulletin feeds use a 75-minute ceiling even when a synthetic latest-item-only feed learns under another schedule kind.

**Data captured from RSS:** Every feed refresh records per-episode release observations in `RefreshStats.releaseObservations` (capped at 200). Each observation stores the episode key, GUID, title, audio URL, RSS `publishedAt`, first/last seen times, whether it was new when first seen, and a publish-date quality marker (`missing`, `plausible`, `futureDated`, `implausiblyOld`). This history is stored on the subscription so schedule learning survives app launches and works even when the current RSS feed only exposes one item.

**Initial seeding:** When a new subscription is added, `SubscriptionStore` seeds release observations from the episodes already present in the fetched feed. New subscriptions use an automatic learning cadence until enough reliable observations exist to classify the schedule.

**Schedule profiles:** `FeedScheduleProfiler` classifies each podcast into one of these profile kinds. Hourly / rolling-bulletin / burst are detected first. Everything else is classified by **Release Radar v2** on its *cadence + active-day pattern only* — publish *time of day* never gates classification, it only sizes the watch window. The profiler learns a **recency-weighted** per-weekday publish probability (recent weeks count for more, so a feed that changed its schedule — or whose older history was captured incompletely — self-corrects rather than being held back by stale data) and watches each weekday at a tier set by that probability: **high → full window on high rotation**, **medium → a lighter occasional check**, **low → skipped entirely**. So a Mon–Fri show spends nothing on the weekend, while a show that *occasionally* drops a Saturday still gets a light Saturday check. A weekly show that skips the odd week (holidays/hiatus) is still recognised as weekly via its dominant weekday's share of episodes. Learned windows hug the densest publish-time cluster for tight feeds, but ordinary daily/weekly/multi feeds widen and lower confidence when their full observed spread is genuinely messy.

| Profile | Meaning | Refresh behaviour |
|---|---|---|
| `learning` | Not enough reliable publish dates yet. | Check briefly at the automatic learning cadence, then decay after repeated empty checks. |
| `unreliableDates` | Most observed episodes have missing or suspicious RSS dates. | Fall back to first-seen surveillance because published times cannot be trusted; recent real releases can temporarily tighten the cadence. |
| `hourly` | Episodes arrive near-hourly around the same minute of the hour. | Open a short window around the learned minute and check on high rotation. |
| `rollingBulletin` | Short news-style feeds use predictable minute marks but change cadence, such as hourly most of the day with half-hourly releases during breakfast. | Open short windows around each learned minute-of-hour slot, such as `:00` and `:30`, instead of treating the feed as random. |
| `burst` ("Daily – Multiple Episodes") | Multiple episodes per day inside a short daily window, on **most days of the week**. A multi-segment show on only one or two weekdays falls through to weekly instead. | Check before and through the daily window; keep checking after the first episode because more may follow. |
| `dailyWeekdays` | A near-daily feed (5+ active days, ~1-day cadence). Classified on cadence + the set of weekdays it reliably publishes on — publish time is irrelevant here. The active-day set distinguishes **Weekdays** (Mon–Fri) from **Daily** (includes the weekend); `FeedScheduleProfile.categoryLabel` reads it to print the right label. | Check across the learned window on each *active* weekday only; never opens weekend slots for a Mon–Fri show; stand down after the expected episode arrives. |
| `weekly` | One reliable publish day on a ~weekly cadence (4–11 day gap). The publish *time* may drift hours week to week (produced shows post-process late), so classification rests on the day + cadence, not a fixed minute. | Check across the learned window on that day, then stand down until the next expected week. |
| `multiSlot` | "Several times a week" — a small, consistent set of 2–4 active days. | Check across the learned window on each of those days. |
| `random` | Reliable dates exist, but no consistent active day or cadence emerges. | Use low-frequency surveillance, normally 15–60 minutes depending on recent activity. |

**Due prediction:** `FeedRefreshScheduling` converts a profile into the next time a feed deserves a fetch. Learned profiles create explicit release windows:

| Profile | Pre-window | Active window |
|---|---|---|
| `hourly` | 3 minutes before the learned minute. | 2 minutes before to 15 minutes after the learned minute. |
| `rollingBulletin` | 3 minutes before each learned minute-of-hour slot. | 2 minutes before to 15 minutes after each learned slot. |
| `burst` | 10 minutes before the learned burst start. | Learned burst start through learned burst end + 30 minutes. |
| `dailyWeekdays` | 20 minutes before the learned window start, on each active weekday. | The learned `releaseWindow` — a window around the **densest** publish-time mode (recency-weighted), adaptively widened when the full observed spread is messy, repeated on every active weekday. Falls back to typical − 10 min … + 75 min if unwindowed. |
| `weekly` | 20 minutes before the learned window start. | The learned `releaseWindow` — a window hugging the densest publish-time cluster (recency-weighted, +20 min margin, 1-hour floor), widened when the observed spread is broad; stragglers outside it are caught by missed-release and safety-sweep checks. Falls back to typical − 10 min … + 120 min if unwindowed. Closes early the moment that week's episode arrives. |
| `multiSlot` | 10 minutes before the learned window start, on each active day. | The learned `releaseWindow` (densest mode, adaptively widened for messy feeds), repeated on each active day; falls back to typical − 5 min … + 60 min if unwindowed. |

If the expected episode has not appeared by the end of its learned window, the feed enters `missedRelease`: Autohop normally checks every 5–10 minutes shortly after the miss, then backs off to a 10–30 minute cadence. Missed-release urgency expires after 10 post-window empty checks or 8 hours of window age; after that the feed drops back to low-priority fallback surveillance until the next learned window. Learned daily/multi/burst profiles also get a four-hour broad safety sweep and weekly feeds a daily sweep. When a learned release window's confidence is below 0.50, it no longer gates checks: daily/multi/burst feeds use two-hour broad surveillance and weekly feeds four-hour surveillance. This prevents one late or out-of-window episode from being missed while avoiding indefinite high-frequency polling.

**One-item hourly and rolling bulletin feeds:** Feeds that publish frequently but only expose the latest item are supported. Each newly seen item is recorded into release observations even after it disappears from the RSS feed. Once enough observations exist, a stable single-minute feed can be profiled as `hourly`, while mixed-cadence bulletin feeds can be profiled as `rollingBulletin` when they repeatedly use predictable minute marks such as `:00` and `:30`. This covers feeds that publish hourly most of the day but every half hour during a morning news block, so they receive real release windows instead of being ranked as random surveillance. The legacy `recentPublishDates` history remains capped at 10 and is still used by the fallback cadence model while the richer observation learner is unavailable or incomplete.

**Priority selection:** Timed/background cycles first filter to feeds that are actually due, then `FeedRefreshPrioritizer` ranks due feeds before any cap is applied. Priority favours missed releases, active/pre-release windows, high-confidence hourly, rolling-bulletin, burst, and daily-weekday feeds, feeds still learning, random feeds needing surveillance, the user's podcast priority rank, feeds not fetched recently, and feeds overdue beyond their expected due time. Foreground timed cycles attempt up to 12 due feeds, while background cycles attempt up to 8. Active and pre-window feeds bypass the foreground cap so a current release window is not missed. Background cycles protect 6 of their 8 slots for `preWindow`, `activeWindow`, and `missedRelease` candidates before filling remaining slots with ordinary due/backlog work; this is specifically intended to help daily one-episode shows that publish around a known time and rolling bulletin feeds that move between hourly and half-hourly slots.

**Backlog draining:** When more feeds are due than a timed/background cycle can attempt, the unselected feeds are checkpointed in an in-memory deferred backlog. Deferred feeds receive a bounded fairness boost on later cycles, so a device waking after many hours processes the strongest candidates first and drains the rest over future runs instead of hammering every overdue feed immediately. Every capped background context first reserves up to two ordinary slots for feeds whose maximum successful-check age has elapsed, oldest check first. During **background-audio** cycles there is an additional backlog-fairness reservation: once a due feed has waited roughly 8 minutes it is guaranteed one selection slot **within the same energy ceiling** (two slots after roughly 20 minutes), *replacing* monopolising work rather than enlarging the batch. This stops scoring or active-window feeds from starving stale and ordinary due work. If iOS expires a background task, selected-but-unfinished feeds are checkpointed back into that backlog before the cycle stops.

**HTTP efficiency:** Feed requests use HTTP conditional validators (`ETag` and `Last-Modified`) whenever available. A check is often a cheap 304 Not Modified response; the feed body is only downloaded when the server reports a change. Large or memory-amplifying responses also record URLSession transaction evidence—wire/materialised sizes, content encoding, redirects, protocol, fetch source, duration, and process-memory deltas—so response buffering can be distinguished from parser/model retention.

**Feed parse memory safety:** `RSSParser` limits retained work to at most 50 episodes per automatic refresh, caps retained text per element, drains per-item transient allocations, and repairs bare ampersands with a low-copy byte pass. These controls bound Autohop-owned model/text retention, but they do **not** guarantee that Foundation networking or `XMLParser` cannot transiently amplify physical memory: a diagnostic capture still observed a roughly 443 MB parse-stage increase from a 3.68 MB feed after the caps landed. Autohop therefore records memory separately at network-data, XML-parser, and model-materialisation boundaries and retains a **persistent parse-memory circuit breaker**. A feed that demonstrates extreme parse growth is quarantined, and constrained background contexts continue excluding it after the timed quarantine until a foreground or manual refresh validates a safe parse. Skips and stage measurements are logged (`feed.parseMemoryQuarantine`, `feed.parseMemoryQuarantineSkipped`, and `feed.parseMemoryStage`). Manual refresh remains available for explicit recovery and validation.

**Refresh/download separation:** A successful refresh finishes once the RSS response has been fetched, parsed, merged into the subscription, and any automatic download has been scheduled. Slow or stalled media transfers continue through the download queue and no longer keep manual refresh, timed Release Radar refresh, or background refresh marked in progress. The scheduled auto-download path re-validates that the subscription still exists, is not a browse preview, still has the same latest episode, and that the latest episode has not already been played or archived.

**Manual, timed, and background refresh:**

| Trigger | Behaviour |
|---|---|
| Manual refresh | Ignores due dates and refreshes every eligible non-excluded feed, subject to temporary failure backoff unless explicitly overridden by the caller. It does not wait for any scheduled auto-download to complete. |
| Timed foreground refresh | Refreshes only feeds whose learned schedule says they are due, capped at 12 per cycle. Active/pre-release windows bypass that foreground cap. Auto-downloads run separately after each successful feed merge. |
| Background refresh | Uses the same due/prediction/priority/backlog pipeline, capped at 8 feeds per BGAppRefreshTask cycle, with 6 protected slots reserved for Release Radar windows (`preWindow`, `activeWindow`, `missedRelease`) before ordinary due feeds. A 20-second cooperative deadline cancels and checkpoints unfinished candidates, completing the useful partial run before iOS's typical expiration window. Scheduled media downloads are left to the download queue rather than holding the BGAppRefreshTask open. |

**Exclusions and failure backoff:** Per-podcast "Exclude from Auto Feed Refresh" removes that subscription from automatic feed refresh. Feeds with recent failures are temporarily skipped unless the refresh path explicitly includes backoff feeds. Background scheduling uses the later of a feed's normal Radar due date and its active backoff expiry, so one broken, long-overdue feed cannot repeatedly request near-immediate wakes; unrelated healthy feeds can still schedule earlier.

**Individual manual refresh:** An Inactive podcast can still be refreshed from its own Podcast Detail page. If that individual refresh finds a new latest episode, Autohop schedules the normal auto-download and may send a new-episode notification when both notification toggles are enabled.

**Diagnostics:** Normal diagnostic logging preserves a compact but complete foreground/background refresh trace. Every cycle carries `refreshCycleID`, `refreshReason`, `trigger` (`manualButton`, `foregroundTimer`, `BGAppRefreshTask`), and `executionContext` (`manual`, `foregroundVisible`, `backgroundRefreshTask`, `backgroundAudioAlive`). `feed.refreshAll.plan` records eligible/due/selected/capped/deferred/backoff counts and state totals; `feed.cycleSummary` is the authoritative terminal record with outcome, attempted/completed/unfinished counts, backlog and elapsed time. Material feed changes retain `feed.refreshMerge`; failures, cancellation, Auto Download intent decisions, `background.wakeSummary`, requested-versus-effective scheduling, and backlog age remain immediate. The optional **Detailed Refresh Trace** toggle adds `feed.refreshAll.planDetail`, per-feed start/finish, 304, no-op and auto-download-decision narration for short Release Radar investigations. It is off by default so ordinary overnight logs span substantially longer without losing evidence that foreground or background work ran.

Unplugged refresh policy keeps the four-minute background-audio timer but suppresses its network work when another due-feed cycle completed in the preceding 90 seconds. Hourly `feed.backgroundEfficiencySummary` records cycles, completed feeds, material changes, zero-result cycles, distinct feed hosts, refresh wall time, execution context, and battery state. BGAppRefresh keeps its protected base batch; its optional follow-up is capped at two feeds while unplugged and may expand to four only on external power. `resources.stageDelta` attributes material physical-footprint growth to feed fetch/parse, feed merge, download settlement, widget artwork preparation, or widget persistence and invokes the existing high-footprint trim policy at those boundaries.

Every BGAppRefresh and BGProcessing execution also emits exactly one always-persisted `background.wakeSummary`. The summary records wake kind/outcome, elapsed and cold-bootstrap time, due/selected/attempted/completed feeds, unfinished feeds, downloads submitted/completed during the finite wake, Auto Archive passes/episode count, and widget projection events deferred. This makes wake frequency, useful work, deadline pressure, download submission, and zero-result archive behavior comparable from one diagnostic line per wake.

**Important limitation:** Schedule learning depends on being able to identify distinct episodes. Feeds should provide a stable unique GUID or audio URL per episode. If a publisher reuses the same GUID and audio URL for every release while only changing title/date, observations may collapse into one record and the profile may remain less accurate.

---

### 15.2 Auto Archive

| Setting | Type | Default | Description |
|---|---|---|---|
| Run Auto Archive Now | Button | — | Manually triggers the archive pass across all subscriptions immediately, using each podcast's Auto Archive rules. Normally runs automatically at most every 25 minutes. Shows a spinner while running. |
| Auto Archive Activity | Page link | — | Opens the newest-first local audit of automatic archives, including episode, podcast, exact date/time, rule, configured threshold, and measured age. The store retains the latest 500 events recorded after this feature was installed. |
| Played Episodes | Menu picker | **After Playing** | Global default for Rule 1 (see §10.4) applied to **new subscriptions only**. |
| Inactive Episodes | Menu picker | **1 Week** | Global default for Rule 2 applied to **new subscriptions only**. The specialist 30-minute bulletin option is intentionally limited to individual Podcast Settings. |
| Episode Limit | Menu picker | **1** | Global default for Rule 3 applied to **new subscriptions only**. |

The three pickers mirror the per-podcast Auto Archive rules (§10.4) and set the **global default** seeded into each podcast at the moment it becomes a real subscription. Stored in `AppSettings.defaultAutoArchiveSettings` (an `AutoArchiveSettings`). **Scope:** these defaults only ever apply to *new* subscriptions (add / OPML import / browse-preview activation, via `SubscriptionStore`); editing them **never** changes the Auto Archive settings of podcasts already subscribed — those keep their own per-podcast values (§10.4). There is no bulk "apply to all" action. The initial value matches the historical hardcoded defaults (After Playing / 1 Week / Keep 1), so existing users see no behavioural change.

**Footer note (shown in app):** "Auto Archive normally runs on its own (at most every 25 minutes). Auto Archive Activity explains every automatic decision. These defaults apply to every new podcast you subscribe to — existing podcasts keep their own settings. Played Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives downloaded-but-unplayed episodes that haven't been played within the set time of being downloaded. Episode Limit rotates automatic downloads while protecting manually downloaded and manually positioned Up Next episodes."

---

### 15.3 Downloading

| Setting | Type | Default | Description |
|---|---|---|---|
| Downloads | Navigation link | — | Opens the Downloads page showing active, queued, and completed downloads. |
| Download over WiFi | Toggle | **On** | Allow downloads on Wi-Fi networks. |
| Download over cellular | Toggle | **On** | Allow downloads over mobile data. On by default so the download-first queue can stay stocked when Wi-Fi is unavailable; turn off to restrict downloads to Wi-Fi. |

---

### 15.4 Controls

| Setting | Type | Default | Range | Description |
|---|---|---|---|---|
| Keep Screen Awake | Toggle | **Off** | — | Prevents the screen from dimming or locking while an episode is actively playing in the full-screen player. Has no effect when playback is paused. |
| Lock Screen Scrubbing | Toggle | **On** | — | Enables seeking from the Lock Screen and Control Centre scrubber. Turn off to prevent accidental seeks when the phone is in a pocket. |
| Up Next Badge | Toggle | **On** | — | Shows a number on the Autohop app icon counting how many downloaded episodes are ready to play. Turn off to clear the badge. |
| Skip back | Sheet (5s steps) | **15s** | 5 – 120s | Duration of the skip-back button in the player. Also controls the skip-back interval shown on the Lock Screen and in Control Centre. |
| Skip forward | Sheet (5s steps) | **30s** | 5 – 120s | Duration of the skip-forward button in the player. Also controls the skip-forward interval shown on the Lock Screen and in Control Centre. |

---

### 15.5 Default Playback

The same dark Speed / Trim Silence / Vocal Boost card used on the per-podcast Playback section (§10.2), plus the same shared Start skip / End skip trim rows, presented here as the **global defaults**. Stored in `AppSettings.defaultPlaybackPreference` (a `PlaybackPreference`). The shared card view is `Views/PlaybackControlsCard.swift`.

| Setting | Options | Default | Notes |
|---|---|---|---|
| Speed | 1.0x – 2.5x (0.1x steps) | **1.0x** | Default speed for new subscriptions and non-subscribed feed playback. |
| Vocal Boost | Off / Light / Standard / Strong | **Off** | See [Vocal Boost](#43-vocal-boost). |
| Trim Silence | Off / Low / Medium / High | **Off** | Audio episodes only. See [Trim Silence](#42-trim-silence). |
| Start skip | 0 – 300s (5s steps) | **0 (off)** | Auto-skips N seconds at episode start. |
| End skip | 0 – 300s (5s steps) | **0 (off)** | Auto-skips N seconds at episode end. |

**Scope:** These defaults apply in two places: (1) every **new subscription** snapshots the current default at the moment it becomes a real subscription (`SubscriptionStore` seeds `playbackPreference` on add / OPML import / browse-preview activation); (2) playback of episodes from **non-subscribed (browse-only) feeds** resolves the default **live** through `PlaybackPreferenceWorkflow.effectivePreference(for:)` — a browse feed always reflects the current default, even retroactively. Editing the default **never** changes the settings of podcasts already subscribed to; those keep their own per-podcast values (§10.2). The one-shot migrations that moved pre-existing users to 1.6x / Strong / Low affected per-subscription values only and are independent of this panel.

**Shared trim-row behaviour:** The global Start skip / End skip controls intentionally mirror the per-podcast rows exactly: minute/second display text, fixed minus/plus capsule controls, debounced writes, and live application to browse-feed playback without intermediate thrash.

---

### 15.6 Subscriptions

| Setting | Type | Description |
|---|---|---|
| Manage podcasts | Button | Closes the Menu sheet to reveal the Priority Stack (PodcastsView) — the home page that always sits beneath the Menu — as a full page, never inside the sheet. Used to reorder, add, or remove subscriptions. |
| Add RSS Feed | Navigation link | Opens the Add RSS Feed page to subscribe by entering a direct feed URL. |
| Import OPML | Button | Opens the system file picker to import an OPML file and reports the imported-show count when new subscriptions are added. See [Section 13](#13-opml-import--export). |
| Export OPML | Button | Exports the current subscription list as an OPML file. Disabled when the subscription list is empty. |

(Listening History is reached from the Menu, not this section.)

---

### 15.7 Sync (iCloud)

Cross-device sync over the user's private iCloud (CloudKit) database. **On by default for new users** so iPhone and Apple TV work together without an extra setup dependency; existing users retain their saved setting and anyone can turn it off. Stored in `AppSettings.iCloudSyncEnabled`; `App/SyncCoordinator.swift` owns lifecycle, callbacks, remote materialization, and explicit pulls over `Persistence/CloudSyncEngine.swift` (a `CKSyncEngine` wrapper). AppState only forwards compatibility and lifecycle entry points.

| Setting | Type | Default | Description |
|---|---|---|---|
| iCloud Sync | Toggle | **Off** | When on, syncs listening state through the user's private iCloud database. Version 1.3 ships only on iPhone; the retained Apple TV implementation can consume the same records during development but is not part of the 1.3 App Store offering. Synced data includes episode played/archived state, per-podcast settings, subscriptions, listening history, and the Up Next queue. |

**What syncs:** episode user-state (played / archived / completed / last-played), subscription settings + subscribe/unsubscribe, listening history (record-level last-write-wins by `lastListenedAt`), and listening stats (additive — each device owns its own per-day partition and the Stats page sums across devices on read). **What never syncs:** downloaded media files (per-device), global app settings (`AppSettings` — poll interval, download Wi-Fi/cellular toggles, skip seconds, sleep schedule, global Default Playback, recaps, launch screen, onboarding flags; these are local `UserDefaults`, roaming only via device backup-restore), the per-device Release Radar learned schedule (`refreshStats`), and catalog content (titles/descriptions/artwork re-hydrate from the feed). Per-podcast Download Filters sync as of July 2026 (they were backup/local-only in v1). Playback **position** does roam — it travels inside the listening-history record (`lastPositionSeconds`). Conflicts resolve with **field-level last-write-wins**; the episode loaded in the player on a device is never interrupted by a remote played/archived change ("active-player-wins"). Sync activity is traceable in the Diagnostic Log under `sync.*` event keys. DayStats conflict diagnostics include the stats device ID, local device ID, day key, cached system-field state, retry status, planned resolution, and per-session conflict count; repeated conflicts for the same record emit `sync.conflictStorm`. For this device's own DayStats partition, a conflict refreshes the server change tag while keeping the local full-day bucket pending, so the retry updates the server record instead of repeatedly colliding with a stale tag.

**CloudKit identity and repair:** CloudKit record names are type-namespaced
(`episode:`, `subscription:`, `subscription-order:`, `queue:`, `history:`,
`stats:`) because record IDs are unique across record types inside the shared
zone. Legacy unprefixed records still decode for existing iCloud data. A known
permanent legacy collision where a `HistoryEntry` record blocks an
`EpisodeState` save is logged once as `sync.pushQuarantined`, removed from the
hot retry loop, and left dirty locally so the next queue pass can send it under
the new `episode:` name. Restored pre-namespace save attempts are dropped before
sending; deletes are preserved. Fresh namespaced EpisodeState and
SubscriptionState records are written as full snapshots so clean local fields
are not omitted. Sparse remote fields with no modified timestamp are treated as
"no remote opinion" and cannot reset local settings to defaults. Priority Stack
order is a whole-list `subscription-order:current` generation, and every
successful upload is acknowledged against the exact version sent so a delayed
response cannot clear newer local work. A one-shot recovery pass reads legacy
unprefixed SubscriptionState records, restores settings only for podcasts that
still exist locally, and re-uploads complete `subscription:` records. Old
unprefixed CloudKit records may remain as recovery orphans until the namespaced
data is verified.

---

### 15.8 Storage

| Display | Description |
|---|---|
| Downloaded episodes | Count of all episodes currently downloaded to the device, across every subscription. To free storage, archive episodes manually or tighten the Episode Limit rule in per-podcast Auto Archive settings. |
| Total size | On-disk size of all downloaded media (computed by summing file sizes under `Autohop/Downloads`, shown via `ByteCountFormatter`). Loaded asynchronously on a background task so it never blocks the Storage section appearing. |
| Manage Downloads | Navigates to the Downloads page. |

---

### 15.9 About

| Item | Description |
|---|---|
| Open Source Acknowledgements | Navigation link to the third-party licences view. |
| Version | Displays the app version and build number (e.g. "1.0 (42)"). Tap 5 times to unlock the hidden Diagnostics section for the current session. |
| Diagnostic Log | Hidden until Diagnostics are unlocked. Normal mode shares a compact rotating log containing foreground/background refresh plans and cycle summaries, BGTask wake summaries, backlog age, material feed changes, downloads/watchdogs, Auto Archive outcomes, sync failures/conflicts, audio recovery, slow operations and five-minute resource heartbeats. **Detailed Refresh Trace** adds verbose per-feed plan candidates, item boundaries, 304 and no-op decisions only for short Release Radar investigations. With diagnostics off, full CPU/thread sampling and the 100 ms UI watchdog stop; a log-free five-minute physical-footprint safety check remains solely to preserve proactive cache trimming. Physical footprint remains the memory intervention threshold. Healthy playback timing is summarized every ten minutes, while slow ticks remain immediate. Download progress persists at 25% milestones; failures and first-byte/active-transfer watchdog classification remain unchanged. Export is queue-consistent, redacted, length-bounded and begins with build/mode/dropped-entry metadata. |

---

## 16. Support (In-App User Guide)

**Access:** Menu (☰) → **Support** (the last menu item). Code: `Views/SupportView.swift`; content data: `Views/SupportContent.swift` (`SupportGuide.sections`).

**What it is:** A native, dark-themed in-app User Guide that **mirrors the website Support page** (`kevmarl-site/support.html`). The two are kept in sync by hand — any change to support information is applied in both places.

**Structure:** Drill-down navigation. Support opens to a scannable list of topic rows (purple icon tile + title + one-line summary); tapping a topic pushes a detail page rendering just that section. Topics: Getting Started, Priority Stack, Up Next, Player, Audio Controls, CarPlay, Chapters, Downloads, Per-Podcast Settings, Sleep Timer, Sleep Schedule, Video Podcasts, Notifications, OPML Import & Export, iCloud Sync, Listening History, Stats, App Settings.

**Content blocks (native renderers):** paragraphs with inline Markdown bold, headings, bullet and numbered lists, tinted callouts (tip / note / warning), key-value and labelled tables (as cards), colour-coded status pills, and Queue-style swipe-action cards. The website's SVG diagrams are intentionally omitted — the surrounding text and tables carry the same information on a phone screen. See DESIGN.md `ListRow-SupportSection` and `Blocks-Support`.

---

## 17. Artwork Cache & Lazy Image Loading

**What it is:** A shared image-loading system for podcast and episode artwork, implemented by `Views/CachedArtworkImage.swift`. It replaces scattered direct artwork downloads with one app-wide cache path for visible UI thumbnails, prefetch work, Now Playing artwork, episode share cards, and notification thumbnails.

**Primary goals:**
- Prioritise artwork the user can see right now.
- Keep scrolling smooth on episode lists with many unique episode images.
- Avoid repeated network requests for the same artwork URL.
- Avoid decoding and storing full-size podcast covers when the UI only needs a 40-54 pt row thumbnail.
- Keep disk usage bounded and self-healing.

### User-facing behaviour

Artwork appears progressively. On-screen images load first; nearby episode images are prefetched just ahead of scrolling; off-screen prefetch work is cancelled when it is no longer useful. Placeholders remain visible until each image is ready.

This is especially important on Podcast Detail pages where a feed can expose a different image for every episode. The first visible rows get priority, then the next rows likely to be reached by scrolling are warmed in the background.

### Shared cache architecture

`CachedArtworkImage` is the SwiftUI component used by podcast/episode artwork call sites. `ArtworkImageCache` is the actor that owns the cache and load policy.

| Layer | Behaviour |
|---|---|
| Memory cache | `NSCache<NSString, UIImage>` stores decoded display variants, capped at 32 MB. Decoded variants and speculative prefetches are purged on backgrounding, memory warning, or a measured process footprint of at least 350 MB (with a five-minute anti-churn cooldown). |
| Disk cache | Stores original validated source bytes once per artwork URL under `Caches/Autohop/Artwork`. Display variants are not written separately. |
| Metadata | `_metadata.json` tracks original URL, byte size, created date, and last access date for every source file. Missing or changed files self-heal on later access/prune. |
| Pruning | Disk cache is capped at 250 MB and 90 days since last access. Pruning removes expired/missing entries first, then trims least-recently-used files until under budget. |
| Failure cooldown | Failed or invalid image URLs are held in a 5-minute negative cache, preventing fast scrolling from repeatedly retrying bad hosts. |

### Validation and safety

Remote artwork responses are accepted only when all of these are true:

- HTTP status is 2xx.
- MIME type is `image/*` when supplied.
- Response body is no larger than 5 MB.
- Expected content length is not greater than 5 MB.
- Image decoding succeeds before a UI image is cached.

Notification artwork uses the same `ArtworkImageCache.sourceData(for:)` path as UI artwork, so new-episode notification thumbnails share the same validation, source-byte disk cache, failure cooldown, and pruning rules.

### Downsampling

Fixed-size artwork call sites pass `targetSize` into `CachedArtworkImage`. The cache converts that to a pixel size using the current display scale and uses ImageIO thumbnail creation to decode near the displayed size.

Examples:

| UI location | Target |
|---|---|
| Priority Stack rows | 44 pt |
| Queue rows | 44 pt |
| Downloads rows | 44 pt |
| Stats show rows | 44 pt |
| Notification Settings rows | 44 pt |
| Mini-player artwork | 40 pt |
| Listening History rows | 54 pt |
| Podcast detail header | 128 pt |
| Podcast settings/detail artwork | 120 pt |
| Episode detail fallback artwork | 320 pt |
| Now Playing lock-screen artwork | 512 pt |

The source bytes are reused across all of these sizes; only decoded in-memory variants differ.

### Lazy loading and prefetch priority

The cache exposes three priorities:

| Priority | Use |
|---|---|
| `visible` | On-screen artwork and Now Playing artwork. Can cancel lower-priority prefetch work for the same variant. |
| `prefetch` | Nearby off-screen episode rows expected to appear soon. |
| `background` | Non-urgent consumers such as notification attachment source bytes. |

`PodcastDetailView` performs row-window prefetching:

- When an episode row appears, it prefetches artwork for the next 12 rows.
- It keeps a small 3-row look-behind window.
- It deduplicates URLs before prefetching, so shared podcast artwork is not fetched repeatedly.
- It cancels stale prefetches outside the active window.
- Visible row image requests always keep priority over prefetch work.

### Unified artwork consumers

The shared cache is used by:

- `CachedArtworkImage` in Priority, Discover, Search, Podcast Detail, Queue, Downloads, Stats, Settings, Notification Settings, Subscription Settings, mini-player, and Player artwork surfaces.
- `EpisodeShareSheet`, which requests artwork sized for the rendered share card.
- `NowPlayingService`, which requests 512 pt artwork and guards against late loads patching the wrong lock-screen card.
- `NotificationService`, which requests cached source bytes for new-episode notification thumbnails.

Feed description images shown inside episode descriptions intentionally remain `AsyncImage`. Those are arbitrary HTML content images, not canonical podcast/episode artwork, and they should not share the podcast artwork cache policy.

### Feed metadata refresh

Successful feed refreshes update stored subscription artwork URLs and authors when the RSS feed changes. This means changed podcast cover art can flow into every shared-cache call site after refresh, instead of remaining stuck on the artwork URL captured at subscription time.

---

## 18. First-Run Experience (New User Onboarding)

**What it is:** The experience a brand-new user gets on first install, designed to teach Autohop's core model — *subscribe → Autohop builds a download-first queue from your Priority Stack → it just plays* — and get them from install to first audio without forcing playback or any launch-time permission prompts. Strategy and the full phased plan live in `ONBOARDING.md` and `ONBOARDING_PLAN.md`.

**First-run state (`AppSettings`):** five flags, all default `false`, persisted like the other settings: `hasCompletedWelcome`, `hasSubscribedFirstShow`, `hasPlayedFirstEpisode`, `hasSeenDownloadFirstNote`, `dismissedGettingStarted`. On launch, `OnboardingCoordinator.reconcileExistingUser()` **reconciles existing users**: anyone who already has a real (non-browse) subscription is marked onboarded so upgraders never see the first-run flow (idempotent, only flips false→true). A brand-new install has zero subscriptions at bootstrap, so its flags stay false.

**"Real" vs browse subscriptions:** onboarding counts only real subscriptions (`browseDate == nil`) via `OnboardingCoordinator.realSubscriptionCount`. Opening a Podcast Detail preview creates an invisible browse subscription (§2.4) and does **not** count as "subscribed".

### Launch routing (`RootView`)
Decided while the launch splash is still visible:
- **Brand-new user** (`isFirstRunNoSubscriptions`: `!hasCompletedWelcome && realSubscriptionCount == 0`) → the **Welcome** screen is presented as a full-screen cover over the splash (shared purple background, so the hand-off is seamless).
- **Otherwise** → the user's **Open at launch** preference (§15.0, `AppSettings.launchScreen`): Player (root), Subscriptions, or Discover (the latter two pushed above the Player root).

(`hasPlayedFirstEpisode` still flips to true the first time `startPlayback` begins audio; it now drives the getting-started checklist rather than launch routing.)

### Welcome screen (`WelcomeView`)
Shown once. A 3-panel paged carousel — the core model, then "Listen your way" (speed / trim silence / vocal boost), then "Made for real life" (Sleep Schedule / Shared Listening) — over three always-visible CTAs, recording `hasCompletedWelcome = true` on any exit:
- **Find shows** → Discover (with Subscriptions behind it).
- **Import from another app** → in-place OPML import (`fileImporter` → `SubscriptionImportCoordinator.importOPML`), then Subscriptions showing the populated library; a confirmation toast reports the count.
- **I'll explore on my own** → Subscriptions (its guiding empty state).

### Starter packs (`StarterPacksView`)
A first-run "not sure where to start?" helper. Each pack is a genre's current Top-6 from Apple's public charts (`PodcastCharts`), scoped to the user's storefront — **chart-derived, zero-maintenance, always fresh, regionally correct**. "Add these shows" resolves each entry's RSS feed and subscribes to all at once through `SubscriptionImportCoordinator` (which resolves the first-subscription milestone silently, like a bulk import). Reached from the empty Subscriptions state ("Not sure where to start?") and a first-run banner at the top of Discover (shown only while `OnboardingCoordinator.realSubscriptionCount == 0`).

### Getting-started checklist (`GettingStartedChecklist`)
A dismissible momentum card at the top of the Priority Stack tracking three steps — subscribe (`hasSubscribedFirstShow`), play (`hasPlayedFirstEpisode`), reorder (a `UserDefaults` signal set in `PodcastsView.onMove`). Auto-hides when all three are done or the user dismisses it (`dismissedGettingStarted`). Its footer carries the one-time lean-defaults expectation note ("Autohop keeps the latest episode and tidies older ones…").

### First-subscription milestone + "You're all set" card
`OnboardingCoordinator` observes the narrow SubscriptionStore membership stream
and coalesces same-turn additions before evaluating the milestone. It sets
`hasSubscribedFirstShow` and emits typed `.firstSubscription(id)` output for a
**single deliberate subscribe**. AppRoutingCoordinator presents the existing
first-subscribe card and a temporary `.autohopFirstSubscription` compatibility
notification remains for un-migrated observers. A **bulk OPML import** (more than
one real sub in the coalesced change) flips the flag **silently** — no celebration.

`RootView` presents `FirstSubscribeCard` (a bottom sheet) in response. The card fires a success haptic, ensures the show's latest episode is downloading (`AppState.downloadLatestEpisode`, idempotent), and shows live download progress. **Play latest** plays immediately if the file is ready, or *arms a wait* and auto-starts the instant the download completes — a cued first listen with no autoplay ambush. On play it dismisses and returns to the full Player. **Add more shows** just dismisses (the user is already in the browse flow).

### Download-first education
The first time the first-subscribe card runs a download (`hasSeenDownloadFirstNote == false`), it shows a one-time note — "Autohop downloads episodes before playing, so they start instantly and work offline" — then sets the flag so it never repeats.

### Coach marks (tips)
A small, deliberately quiet tip system (`Views/CoachMark.swift`, `OnboardingTip`). OnboardingCoordinator enforces the policy: **one visible at a time**, **never re-shown** once dismissed (per-tip `tip.<case>.seen` in `UserDefaults`), and **at most 3 per session** (the rest surface later). Views call `OnboardingCoordinator.requestTip(_:)` on first arrival; `CoachMarkOverlay` (mounted once in RootView, behind sheets) renders the active tip as a dismissible bottom card with a "Got it" button. Triggers: **priorityStack** (Subscriptions with ≥1 show), **swipeActions** (Podcast Detail, once the user has a real subscription), **playerPanels** + **speed** (Player, when an episode is loaded), **sleepSchedule** (the Sleep Schedule page). Everything a tip teaches also lives in Menu → Support, so dismissing loses nothing.

### Empty states (every new-user-reachable screen points forward)
- **Player** (`PlayerView`): when there's nothing to play, shows a first-run state — *no subscriptions* → "Nothing playing yet" + **Find shows** (Discover); *subscribed but the first episode is still downloading* → "Getting your first episode" with a spinner + **View subscriptions**. A quiet leading nav button keeps it from ever being a dead end.
- **Subscriptions** (`PodcastsView`): "Your Priority Stack is empty" with **Find shows** and a working **Import subscriptions** (OPML).
- **Up Next / Listening History**: reassuring "builds itself" / "will show up here" copy.

---

## Appendix: Model Defaults Quick Reference

### `PlaybackPreference.default`
| Property | Default |
|---|---|
| speed | 1.0x |
| startSkipSeconds | 0 (off) |
| endSkipSeconds | 0 (off) |
| vocalBoostLevel | .off |
| trimSilence | .off |

> **Note on the 1.6x / Strong / Low values you may remember:** those are NOT the
> default. They were applied to *already-subscribed* shows of pre-existing users
> by one-shot first-launch migrations (`playbackSpeed160Migrated`,
> `vocalBoostLevelMigrated`, `trimSilenceLowDefaultMigrated`). A brand-new
> subscription is seeded from `AppSettings.defaultPlaybackPreference`, which
> uses `PlaybackPreference.newUserDefault` (1.0x / Strong / Off) on a fresh
> install. `PlaybackPreference.default` remains the legacy subscription decode
> fallback (1.0x / Off / Off), so this factory change cannot rewrite existing
> subscriptions. See §15.5.
> (Code caveat: `PlaybackPreference`'s member-wise init and decoder fall back to
> `.strong` vocal boost when the key is absent — a legacy-migration artifact that
> disagrees with `.default`; see ASSESSMENT.md B3.)

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
| notifyNewEpisodes | false |
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
| iCloudSyncEnabled | false |
| hasCompletedWelcome | false |
| hasSubscribedFirstShow | false |
| hasPlayedFirstEpisode | false |
| hasSeenDownloadFirstNote | false |
| dismissedGettingStarted | false |
| launchScreen | .player |
| defaultPlaybackPreference | PlaybackPreference.newUserDefault (1.0x / Strong / Off / no skips); user-adjustable and copied only into new subscriptions |
| defaultAutoArchiveSettings | AutoArchiveSettings.default (After Playing / 1 Week / keep 1) — global default seeded into new subscriptions only |

### `RefreshStats` / `FeedRefreshScheduling` / refresh-cycle defaults
| Property | Default |
|---|---|
| maxRecentPublishDates | 10 |
| maxReleaseObservations | 200 |
| defaultMinRecheckInterval | 5 minutes |
| minPublishInterval | 15 minutes |
| maxPublishInterval | 7 days |
| defaultPublishInterval | 6 hours |
| maxRecheckInterval | 24 hours |
| windowOpenFraction | 0.75 |
| missedReleaseEmptyFetchLimit | 10 empty post-window checks |
| missedReleaseMaxUrgencyAge | 8 hours |
| foregroundRefreshFeedLimit | 12 due feeds |
| backgroundRefreshFeedLimit | 8 due feeds |
| backgroundReleaseRadarReservedSlots | 6 protected slots for pre-window / active-window / missed-release feeds |
| backgroundStaleReservedSlots | up to 2 slots, oldest hard-ceiling candidate first |
| backgroundAudioMaximumSuccessfulCheckAge | 90 minutes |
| backgroundTaskMaximumSuccessfulCheckAge | 2 hours |
| bulletinMaximumSuccessfulCheckAge | 75 minutes |
| refreshDeferralMaxScoreBoost | 40 points |

### `Subscription.init` defaults
| Property | Default |
|---|---|
| notificationsEnabled | false |
| excludeFromAutoFeedRefresh | false |
| autoArchiveSettings | AutoArchiveSettings.default |
| downloadFilterSettings | DownloadFilterSettings.default (all filter groups off; match mode All; no rules) |
| playbackPreference | PlaybackPreference.default |
| browseDate | nil (nil = real subscription; non-nil = auto-created browse subscription) |

---

## 19. CarPlay

**What it is:** A native CarPlay Audio App surface for Autohop's playback queue and subscribed-show episode lists. CarPlay is another UI over the same `AppState`, queue, download manager, playback engine, archive behavior, speed preferences, and Shared Listening state used by the iPhone app.

**Entry behavior:**
- If an episode is currently loaded and valid metadata is available, CarPlay opens to **Now Playing**.
- If no episode is currently loaded, or cold-launch metadata is not ready, CarPlay opens to **Up Next** instead of a blank player.
- During app readiness, CarPlay shows a short loading state and then switches to Now Playing or Up Next.

**Screens:**
- **Now Playing** — current episode metadata, artwork when available, system playback controls, Subscriptions, Archive, a persistent speed adjustment page, Shared Listening toggle, and Shared Listening speed picker.
- **Up Next** — downloaded queue episodes with Play Now, Play Next, Play Last, and Archive actions.
- **Subscriptions** — real subscribed podcasts in priority order. Tapping a podcast opens its recent episode list, including played, archived, and not-yet-downloaded episodes; tapping an episode opens Play Now, Play Next, Play Last, and Archive actions.

**Download boundary:** Up Next remains downloaded-only. Subscription episode lists mirror the phone podcast detail page by showing recent episodes, but Play Now, Play Next, and Play Last on an episode not yet on device must first show a driver confirmation before starting a manual download. During that download, CarPlay shows a native loading/downloading state. CarPlay does not search, discover podcasts, refresh feeds, stream episodes, or expose subscription management.

**Actions:**
- **Play Now** starts the selected downloaded episode immediately; for an undownloaded subscription episode, it asks to download first, then plays.
- **Play Next** moves the selected episode directly after the currently playing episode, matching iPhone behavior. If there is no current episode, Play Next behaves as Play. For an undownloaded subscription episode, it asks to download first, then queues.
- **Play Last** moves the selected episode to the end of the queue, matching iPhone behavior. For an undownloaded subscription episode, it asks to download first, then queues.
- **Archive** removes the selected episode from the queue. Archiving the current episode advances to the next downloaded queue item when one exists; otherwise Now Playing is cleared and the empty queue state is shown.
- **Playback Speed** opens a slower/faster page using Autohop's existing preset speeds and the current episode's podcast settings as the base. The page stays open after each adjustment.
- **Shared Listening** controls the same global temporary override as iPhone. Disconnecting CarPlay does not change the Shared Listening state.
- **Playback Speed** shows the episode's configured effective speed directly on the Now Playing button (for example, `1.6x`) even while playback is paused or the audio engine is transitioning routes. Selecting it opens the existing Slower/Faster adjustment page.

**Empty state:** If there are no downloaded queue episodes, CarPlay shows a calm `No downloaded episodes` state without instructing the user to use the iPhone.

**Explicitly excluded from CarPlay v1:** Search, Discover, RSS entry, podcast settings, subscription management, feed refresh, streaming, Sleep Timer, Sleep Schedule, notifications, Stats, OPML import/export, diagnostics, sharing, and long-form episode browsing. Downloads are limited to explicit confirmation from Play Now, Play Next, or Play Last on a subscribed-show episode row.

---

## 20. Now Playing & Up Next Widgets

**What it is:** One adaptive iOS WidgetKit surface for downloaded Autohop
content. Home Screen families are small, medium, and large; Lock Screen and
StandBy families are accessory circular and accessory rectangular.

**Displayed content:**
- Home Screen widgets use a textured very-dark-charcoal glass background instead
  of flat black. iOS 26+ renders native Liquid Glass on the background sheen;
  older systems use a matching static fallback. Playback controls use an
  always-visible purple glass-style gradient and edge because WidgetKit can hide
  App Intent Toggle labels when native glass is attached directly to them. The
  deterministic styling adds no animation, network work, or timeline churn.
- Current episode first when one is loaded, followed by at most four downloaded
  Up Next episodes.
- If no current/queue episode is available, recently downloaded playable
  episodes are used before showing the Discover empty state.
- Remaining time is a static checkpoint refreshed after meaningful playback
  events, not a simulated live countdown.
- Small/medium/large widgets load at most 1/2/5 app-prepared 300-pixel JPEGs.
  The extension never downloads artwork or opens Autohop's database.
- Every Home Screen family applies its square crop after sizing, so widescreen
  video-episode thumbnails cannot escape the artwork frame.

**Interaction:**
- A play control toggles the current episode or performs Play Now for another
  downloaded row without foregrounding Autohop.
- Every intent re-resolves the stable subscription/episode identity and confirms
  the episode is still downloaded, unplayed, and unarchived before playback.
- Artwork/header links open Player; Up Next headings open the existing Up Next
  sheet; episode titles open Episode Detail; the empty state opens Discover.
- A stale or removed episode fails safely and causes the snapshot to correct
  itself rather than attempting playback from old paths.

**Lock Screen privacy:** The circular accessory shows only the Up Next count.
The rectangular accessory shows current/next title and podcast, marked
privacy-sensitive so system redaction can hide it on a locked device. Both use
system accentable rendering and system-owned backgrounds for tinted Lock Screen
and StandBy appearances.

**Persistence and refresh:** The app writes a versioned display-only snapshot
atomically into `group.com.kevinperry.autohop`; it contains no media URL/path,
CloudKit identifier, credential, or database object. Equivalent visible state
is hash-deduplicated. Corrupt snapshots are discarded, local thumbnail reads
are capped at 1 MB, and artwork garbage collection retains only the current and
one previous generation.
During a finite BGAppRefresh or BGProcessing execution, widget projection,
artwork preparation, App Group writes, and WidgetKit reloads are suppressed.
Change reasons are coalesced and publish once only when foreground or active
audio provides a safe execution opportunity; otherwise they remain pending
until the next foreground/domain event.
# tvOS Clean-Install Access and Offline Demo (Version 1.6)

<!-- AI CONTEXT — tvOS-only App Review and first-install capability. This does
not change iPhone authority or create an Autohop account system. -->

- Apple TV now guarantees an actionable first screen after a ten-second launch
  presentation deadline, even if local bootstrap or iCloud does not return.
- A completed setup screen explains the private-iCloud companion workflow and
  offers Explore Demo Library, Open Discover, Check iCloud Again and Settings.
- The Release build contains an offline, clearly labelled demo library with
  four synthetic shows, Up Next, Continue Listening, History, audio playback,
  video playback, speed/seek controls, Play Next, Archive, Reset and Exit.
- Demo media is first-party and bundled. Demo changes are in memory only and
  cannot write to the user's subscriptions, queue, history, CloudKit or Stats.

# Dynamic Apple TV Top Shelf (Version 1.6)

<!-- AI CONTEXT — tvOS-only system Home Screen projection. The containing app
publishes; the extension only renders content and records bounded operational
health without user content. -->

- When Autohop is placed in the Apple TV Dock, Top Shelf presents native poster
  cards grouped as Currently Playing/Watching (or idle Continue Listening) and
  Up Next.
- The live playing episode is always first regardless of queue rank, carries
  progress and is deduplicated from Up Next. While idle, Continue Listening is
  excluded when effectively finished and receives the same treatment.
- Both Select and Play/Pause start or resume the exact selected identity through
  normal playback. Deep links contain identity only; descriptions remain
  available inside the app's episode actions.
- Prepared 404×608/808×1216 artwork and progress come from an atomically replaced,
  bounded App Group snapshot. The extension performs no network, CloudKit,
  GRDB, RSS, statistics or queue work.
- Invalid, stale, empty or scope-mismatched data uses redesigned static artwork.
  Demo Library data is structurally excluded from publication.

# Apple TV Diagnostic Health (Version 1.6)

<!-- AI CONTEXT — Local, bounded and privacy-safe support evidence; Autohop
does not upload this data. -->

- Settings separates Top Shelf publisher, App Group, manifest and extension
  health and provides a safe manual refresh.
- Developer diagnostics show launch state/uptime, memory footprint, thermal
  state and session main-thread hang count/maximum.
- The redacted export correlates launch, sync, queue, playback, Discover, Demo,
  Top Shelf and performance events without podcast or episode titles.
- Settings caches expensive health inspection during focus movement and makes
  every health row a stable Siri Remote focus stop for progressive scrolling.
- Returning Apple TVs with durable library evidence retain the branded refresh
  presentation during ordinary iCloud catch-up instead of showing first-time
  setup; clean installs still receive prompt Demo/Discover access.
- Dynamic Top Shelf storage is a regenerable App Group cache with independent
  permission probes and bounded retry behaviour. Diagnostics show exact
  privacy-safe outcomes rather than repeatedly attempting a permanent failure.
- tvOS performance evidence excludes scene suspension, and CloudKit pull logs
  use compact per-type batch counts instead of thousands of record traces.
- Dynamic Top Shelf presents four narrower poster cards across HD layouts. Each
  card carries the purple Autohop brand backdrop and reuses locally cached
  podcast artwork before downloading or falling back to the waveform treatment.
- Apple TV Home Up Next mirrors iOS time metadata: partially played episodes
  show remaining time; untouched episodes show their total runtime. Synced
  positions are projected before rendering, never read during focus movement.
