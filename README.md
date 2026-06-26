# Autohop

**The podcast player for people who are serious about listening.**

Autohop is a native iOS podcast player built around a single idea: your time is the finite resource, not your content. Most podcast apps treat your queue like a to-do list you manage manually. Autohop manages it for you — automatically, intelligently, and indefinitely — so you can focus on everything else.

## Product Vision

Autohop is a **priority-playlist focused podcast player** aimed at serious, high-volume podcast listeners who want a premium, low-friction experience. The goal is an "endless" listening experience that requires minimal engagement from the user once set up, allowing them to stay present in whatever they're actually doing — driving, exercising, working — while the app keeps their listening moving forward without interruption.

Autohop is built for people who already know what they love — who subscribe to more shows than they can easily keep up with and want a player that respects both their taste and their time. It keeps their shows organised, always in the right order, played exactly the way they want them.

## Core Design Goals

**1. Set your priorities once. Listen indefinitely.**
The Priority Stack is a ranked list of subscriptions the user orders once. Autohop works down that list, surfaces only downloaded episodes, and flows from one to the next without any user input. Finish an episode mid-commute and the next one starts automatically — no decisions required.

**2. Audio that is actually comfortable to listen to.**
Per-podcast Trim Silence (four levels), per-podcast Vocal Boost (four intensities), per-podcast playback speed, and per-podcast start/end skip let users dial in the right listening experience for every show independently. A dense interview podcast can be compressed and crisp; a narrative show can stay natural and relaxed.

**3. Surgical queue control when you want it.**
The priority system handles everything automatically, but when a user wants to override it — Play Next or Play Last — two swipe gestures put them back in control instantly. The queue always shows exactly where things stand via color-coded status pills and pin badges.

**4. Downloads first, always.**
Autohop is a download-first player. The queue only ever plays files already on the device: no buffering mid-episode, no stalling on a poor signal. Background downloads keep the queue stocked quietly. Auto-archive policies clean up finished episodes per-podcast on a configurable schedule.

**5. Built for the serious listener, not the median user.**
Autohop's positioning is deliberately premium and niche. The target user subscribes to 10–30+ podcasts, listens several hours a day, and is frustrated that every mainstream app makes them manage their queue manually. This is the gap Autohop fills.


## Current Feature Set

- First-run onboarding: a Welcome carousel, chart-derived one-tap Starter Packs, guiding empty states, a "You're all set" first-subscribe moment that auto-downloads and cues your first episode, contextual coach marks, and a getting-started checklist — designed to teach the Priority Stack model without forcing playback or asking for permissions up front
- "Open at launch" setting — choose whether the app opens to the Player, your Subscriptions, or Discover each time
- Priority Stack: drag-ranked subscriptions feed the queue automatically in order
- Endless auto-advancing queue with Play Next / Play Last manual overrides
- Discover page: browse Apple Podcasts charts (Top-8 hero cards plus per-genre rails) with a storefront country picker, plus two fixed "Top Podcasts · Country" spotlight heroes (US/UK/AU) woven into the feed
- Podcast search via the iTunes catalog — search by name, author, or keyword; browse episode list before subscribing; 30-day recently viewed history
- Download-first playback; background downloads via URLSession
- Trim Silence engine (Off / Low / Medium / High, per-podcast) — RMS-based, ported from Pocket Casts algorithm
- Vocal Boost (Off / Light / Standard / Strong, per-podcast) — Pocket Casts-derived dynamics chain (high-pass filter → dynamics processor → peak limiter) targeting clearer spoken audio
- Per-podcast playback speed (1.0–2.5x), start skip, and end skip
- Chapter support with active-chapter filtering and disabled-chapter skipping
- Audio and video podcast support with landscape unlock for full-screen video
- Release Radar adaptive feed refresh — learns each podcast's release schedule from filter-eligible publish history, starts checking daily shows before the expected release time, and protects release-window candidates during short background wakes; HTTP conditional requests (ETag/304) keep checks tiny
- Background feed refresh (BGAppRefreshTask, due-date priority scheduling, protected Release Radar slots) and per-podcast exclude-from-refresh
- Per-podcast Download Filters for automatic RSS downloads by episode duration, title, and description
- Auto-archive policies per subscription (after-played delay, inactive timeout, episode limit)
- Episode status tracking: Unplayed / Queued / Paused / Playing / Played / Archived / Inactive / Skipped
- Listening History: searchable per-episode log with 60-second minimum playback threshold, grouped by date
- Stats page: time listened, time saved, episodes finished, and streaks over calendar-anchored This Week / this month / this year / Lifetime periods — with a listening heatmap, monthly trend chart, 24-hour listening clock, top shows with tap-to-expand per-show detail cards (episodes finished, per-show time saved, listening share, cadence), and a "Shows You're Drifting From" engagement list; all data stays on device
- Sleep timer: duration presets, end-of-episode mode with episode count, volume fade-out, and auto-restart on quick resume
- Sleep Schedule: a recurring nightly sleep timer (Autohop exclusive) — during your active-hours window a soft chime asks "still listening?" over continuing playback; any control confirms, no response fades out and rewinds to where you drifted off. Includes a player top-bar indicator and a time-sensitive lock-screen "Still Listening" notification you can tap without unlocking
- Episode share cards: rendered artwork card exported through the system share sheet
- Global Default Playback panel — set the speed, Vocal Boost, Trim Silence, and start/end skip applied to every new subscription and to playback of not-yet-subscribed feeds, without touching shows you've already tuned
- Optional iCloud sync (off by default) — keeps played/archived state, per-podcast settings, subscribe/unsubscribe, listening history, and stats in step across your devices over your private CloudKit database; downloads stay per-device
- OPML import and export for subscription portability
- New episode push notifications (global and per-podcast; permission requested only when you opt in)
- Keep screen awake during playback and lock screen scrubbing options
- Lock screen / Now Playing controls (MPRemoteCommandCenter)
- In-app Support / User Guide (Menu → Support): native drill-down guide that mirrors the website Support page
- Diagnostic logging for feeds, downloads, queue, playback/audio routes, main-thread watchdog gaps, and resource metrics (hidden developer tool)

## Documentation Map

| File | Purpose |
|---|---|
| [`FEATURES.md`](FEATURES.md) | **Source of truth** for every feature, setting label, default, and behaviour. Update this first when any model/view/setting changes, then propagate to the website and App Store copy. |
| [`PAGES.md`](PAGES.md) | Canonical page names, code names, and the full navigation structure. |
| [`DESIGN.md`](DESIGN.md) | Design system — labelled, reusable UI patterns (the Queue page is the canonical reference). |
| [`APPSTORE_ROADMAP.md`](APPSTORE_ROADMAP.md) | Live checklist of everything required before App Store submission (v1 = iPhone only), with drafted listing copy, review notes, and screenshot shot list. Updated as each step completes. |
| [`SYNC_DESIGN.md`](SYNC_DESIGN.md) | Cross-device iCloud (CloudKit) sync design + build status — transport, conflict strategy, the `@Synced` field-level dirty-tracking, and per-domain merge rules. |
| [`ASSESSMENT.md`](ASSESSMENT.md) | Machine-oriented code/feature/security assessment: performance, bugs, stale code, and security findings with `file:line` anchors and severities. |
| [`NOTICE`](NOTICE) | Third-party derivation details (Pocket Casts), per-file licence status. |
| [`LICENSE`](LICENSE) / [`LICENSE-MPL-2.0.md`](LICENSE-MPL-2.0.md) | MIT for the project; MPL-2.0 text plus a project note listing the four covered files and acknowledging Pocket Casts as a broader source of design ideas and inspiration. |

Source files carry structured `AI CONTEXT` header comments (purpose,
responsibilities, collaborators, invariants) written for machine consumption —
read a file's header before modifying it.

## Build Notes

- The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. After adding/removing source files, run `xcodegen generate`. Never edit project settings only in Xcode's UI — mirror them into `project.yml` or the next regeneration will discard them.
- Open `Autohop.xcodeproj` in Xcode.
- Select the Autohop target, configure Signing & Capabilities, and choose a development team.
- Build and run on an iPhone or simulator using iOS 17 or later.
- Smoke tests run via SwiftPM: `swift run RSSParserSmoke`, `swift run OPMLSmoke`, `swift run SubscriptionStoreSmoke`, `swift run DownloadManagerSmoke`, `swift run StatsSmoke`.

## Scope

The app remains focused on podcast queue automation, downloaded media playback, video podcast support, and clear diagnostic tooling.

## License

Autohop is open source under the [MIT License](LICENSE), with four exceptions licensed under the [Mozilla Public License 2.0](LICENSE-MPL-2.0.md) because they contain code derived from [Pocket Casts for iOS](https://github.com/Automattic/pocket-casts-ios) (© Automattic, Inc.): [`Playback/SilenceDetector.swift`](Playback/SilenceDetector.swift) and [`Models/SilenceGapAccounting.swift`](Models/SilenceGapAccounting.swift) (silence-trim algorithm/constants), [`Playback/PlaybackEngine.swift`](Playback/PlaybackEngine.swift) (Vocal Boost signal chain), and [`Models/Synced.swift`](Models/Synced.swift) (the `Synced`/`ModifiedDate` property wrapper). Autohop also acknowledges Pocket Casts as a broader source of design ideas and inspiration (per-podcast audio effects, the audio-controls sheet, up-next queue, auto-archive, on-device stats, and field-level sync discipline). See [NOTICE](NOTICE) and [`LICENSE-MPL-2.0.md`](LICENSE-MPL-2.0.md) for full derivation and acknowledgement details.
