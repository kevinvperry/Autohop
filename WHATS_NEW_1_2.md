# What's New in Autohop 1.2

## CarPlay Support

Autohop now works on your car's dashboard. Connect your iPhone and Autohop appears in CarPlay with everything you need to keep listening without touching your phone.

**What you get in CarPlay:**
- Now Playing screen with artwork, scrubber, and transport controls
- Up Next — your downloaded queue, right on the dash
- Play Next, Archive, and playback speed controls
- All actions route through your existing queue and settings — nothing gets out of sync

CarPlay plays only downloaded episodes, keeping things reliable on the road. No browsing, searching, or downloading from the car — just listening.

---

## Smarter Background Refresh

Autohop now stays more reliably up to date, even when you haven't opened the app in a while.

**What changed:**
- **Overnight catch-up** — when your phone is charging on Wi-Fi overnight, Autohop runs a full sweep of all your feeds and downloads new episodes so your queue is ready for the morning
- **Background listening** — Autohop now refreshes feeds while you're listening with the screen off, so new episodes from your next show are already downloaded before the current one finishes
- **Release Radar protection** — when iOS grants only a short background wake, Autohop prioritises the shows most likely to have just published rather than wasting the slot on shows that rarely release

---

## Release Radar v2 — Smarter Schedule Learning

Release Radar, which learns when each of your podcasts publishes and checks at the right time, has been significantly improved.

**What's better:**
- Learns which days of the week each show actually publishes, not just how often — a Monday/Wednesday/Friday show no longer wastes refresh slots on weekends
- Self-corrects when a show changes its schedule — recent episodes count more than old ones, so a show that moved from Tuesday to Thursday catches up within a few weeks
- Daily shows, weekday-only shows, weekly shows, and news bulletins are now classified more accurately — in testing, "unknown schedule" feeds dropped from ~38% to ~10% of a typical library
- Watch windows are sized around when a show actually tends to publish, not a broad average

**New transparency tools:**
- **Release Radar Data** (Podcast Settings → Feed) — see exactly what Autohop has learned about any show: its schedule type, confidence, publish-time window, per-day watch intensity, and why it did or didn't qualify as Daily or Weekly
- **Feed Refresh Schedule** (App Settings → Release Radar) — a table of every active podcast showing when Autohop will next check it, grouped by behaviour, with a countdown to the next expected window. Includes a **Rebuild Prediction** button that fetches the last 100 episodes to sharpen a feed's schedule prediction

---

## Download Filters

New per-podcast rules that control which episodes get automatically downloaded.

Set filters by **episode duration**, **title keywords**, or **description keywords** — with include or exclude modes. Episodes that don't match your filters stay visible in the episode list with a grey Skipped label but won't download automatically.

Useful for: skipping bonus/premium episodes by title, ignoring very short filler episodes, or only downloading episodes above a certain length.

Filters are set per-podcast in Podcast Settings → Download Filters and include a live preview of your current feed showing which episodes would be skipped.

---

## Expanded Discover Charts

The Discover page now has two full chart pages you can dive into.

**Top Episodes** — tap **See All** on the Top Episodes hero to open a full Top 50 episode chart for your selected country. An editorial layout mixes large feature cards (every 7th rank) with compact ranked rows, each showing the episode's artwork, title, show name, and how recently it was published. Tap any entry to open the show's episode list.

**Top Podcasts** — tap **See All** on the Top Podcasts hero to open a full Top 50 show chart for your selected country, with the same editorial layout. Each entry shows the show's artwork, title, author, and category. Tap to open the show's episode list and subscribe directly.

---

## Up Next Animations

Swipe actions in the Up Next sheet now have clear, satisfying animations that show exactly what's happening:

- **Play Next / Play Last** — a directional badge flashes at the leading edge (blue arrow up / orange arrow down) and the row visibly glides to the top or bottom of the list
- **Archive** — the row slides toward the right while shrinking and fading, with a purple archive-box badge appearing as it goes, then the gap closes cleanly behind it
- All actions include a matched haptic so the gesture feels physical

---

## Up Next Shortcuts

Expanding an episode row in Up Next now shows two shortcut buttons in the bottom corner:

- **Podcast list** — jumps straight to that show's episode list
- **Settings** — jumps straight to that podcast's settings

Both close Up Next and open the target page in its place, so you're never more than a tap away from adjusting a show's settings mid-session.

---

## Renamed: Queue → Up Next

The playback queue sheet is now called **Up Next** throughout the app and in CarPlay, replacing the previous "Queue" label. Everything works the same way — the name better describes what the sheet actually shows.

---

## Listening Recaps

Opt in to automatic listening summaries delivered as notifications.

Choose from **weekly**, **monthly**, and **yearly** recaps — each one links into your Stats page for the matching period so you can see the full breakdown. All off by default; turn them on in Notification Settings → Listening Recaps.

---

## Inactive Subscription Improvements

Podcasts you've marked as Inactive (excluded from auto-refresh) now behave more consistently:

- Settings, manual feed refresh, notifications, and Subscribe/Unsubscribe remain fully available on the podcast's page
- When you re-activate a podcast, it returns to its original position in your Priority Stack — it no longer lands at the bottom
- The saved return position syncs across your devices via iCloud
- "Shows You're Drifting From" on the Stats page no longer includes Inactive podcasts

---

## Auto Archive Improvements

Two fixes to how Auto Archive behaves:

- **Inactive Episodes** now measures inactivity from when an episode was **downloaded**, not when it was published. An episode you download today gets a fresh inactivity window regardless of its publish date. Episodes that have never been downloaded are fully exempt from this rule.
- **Episode Limit** no longer counts episodes stuck in a failed download state. A broken download no longer takes up a slot and push out an episode you actually have.

---

## Player — Episode Artwork

The main player view now shows the episode's own artwork when the podcast provides it, rather than always showing the podcast's logo. Falls back to the podcast artwork when no episode-specific image is available.

---

## Stats Improvements

- Stats now opens to **This Week** by default instead of the current month
- **This / Last** toggle lets you switch between the current and most recently completed period for Week, Month, and Year views
- The Published and Released tiles in the Player's Details panel now show different information — Published shows which day the episode came out, Released shows what time

---

## Stability & Bug Fixes

- Fixed video episodes pausing when navigating away from the app or locking the screen — video now transitions to Picture in Picture automatically to keep playback running
- Fixed AirPods and speaker handover causing playback to pause unexpectedly when switching audio routes
- Fixed iCloud sync not correctly restoring per-podcast settings after a CloudKit migration
- Fixed Inactive podcasts appearing as unsubscribed in Search, Discover, and episode routing
- Fixed a crash in Episode Detail view
- Fixed a background refresh build issue that caused the refresh return value to be dropped
- Fixed download eligibility not honouring per-podcast Wi-Fi settings
- Modernised video playback internals to remove use of deprecated Apple APIs
- General performance and reliability improvements throughout

---

## New App Icon

Autohop has a refreshed app icon for 1.2 — brighter background, stronger contrast on the waveform bars and skip chevron, designed to hold up well on the iOS home screen and in CarPlay.
