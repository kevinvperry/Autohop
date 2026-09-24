# Autohop

<!--
AI CONTEXT — README.md
High-level product, feature, documentation, build, and licensing index for AI
agents. Treat FEATURES.md as the behaviour/default source of truth, PAGES.md as
the navigation/page-name source of truth, and SYNC_DESIGN.md as the CloudKit
source of truth. ASSESSMENT_2026-08-30.md is the latest whole-project audit
snapshot (superseding earlier assessments for that date), not a substitute for
post-audit Version 1.6.1 source and living documents. The
visible playback-order sheet is "Up Next"; the Swift implementation still uses
legacy `Queue*` type/property names in several places.
Priority Stack reordering uses a stable active-subscription UUID draft and one
atomic cross-device order generation; Inactive and hidden browse rows never share
its move-index space.
The checked-in production configuration includes the full iPhone and Apple TV
codebases. Cross-device synchronization uses only the user's private iCloud.
VERSION_1.4.md, VERSION_1.5.md and VERSION_1.6.md are closed historical
submission ledgers. VERSION_1.6.md records the tvOS submission sent on
22 August 2026 and the iOS-family submission sent on 30 August 2026.
VERSION_1.7.md is the canonical running ledger for every future change.
The abandoned Autohop Pro and Cloudflare relay prototypes have been removed.
The post-1.4 tvOS rebuild is implemented through automated Phase 6 hardening:
compact cached projections, targeted detail loading, truthful streaming states,
native video and read-only sync authority. iOS Version 1.6 was rejected for advertising metadata; 1.6.1 is now
approved and live, confirmed by the user on 8 September 2026. tvOS approval remains unconfirmed.
AppState decomposition Stages 0–14 are implementation-complete. Domain
coordinators and named workflows exclusively own playback, queue, downloads,
feed refresh/Release Radar, Auto Archive, history/Stats, onboarding, import,
private iCloud sync, chapters, media, Play Instant, runtime policy, and startup.
SwiftUI observes narrow owners directly. AppState is now only the process
singleton, composition root, and stable high-level façade retained for SwiftUI,
CarPlay, AppDelegate, BGTask, APNs, and file-open entry points. The remaining
release-candidate device matrix is validation, not an ownership extraction.
Version 1.4 adds one adaptive Home Screen / Lock Screen widget backed by a
device-local App Group display snapshot. Widget playback reuses the existing
transport workflow through AudioPlaybackIntent; the extension never opens the
database, streams media, or performs network requests.
Release update (2026-09-06): user confirmed Mac Menu crash resolved; issue closed.
User confirmed iOS-family 1.6.1 approved and live on 8 September 2026.
Its ledger is closed; all future changes belong in VERSION_1.7.md.
TV 1.6.1 (1) submitted for approval, user-confirmed 8 September 2026.
All future iOS/tvOS code changes belong together in VERSION_1.7.md.
Screenshot confirms prior TV 1.6 (15) Ready for Distribution.
-->

## Download Feed Filters — Version 1.7 design update

Choose automatic downloads by episode length, title or description in a guided, less cluttered editor. Turn on only the groups you need, read a plain-language summary of each rule, and preview matches with clear explanations. All existing filter options and immediate saving are retained.

## Podcast Replay — Version 1.7 development

Listen through a podcast's available back catalogue on your own schedule. Use its dedicated Podcast Settings section and guided setup to pick a starting episode and release time, apply existing Feed Filters, and let Episode Limit pause new releases until there is space. A Replay pill identifies enabled shows; private iCloud shares the release sequence and progress across updated devices, while downloads remain local. The enabling installation schedules releases; Apple TV consumes the queue and syncs listening outcomes. See [FEATURES.md](FEATURES.md) for behaviour and [the strategy/implementation record](Docs/PODCAST_REPLAY_IMPLEMENTATION_STRATEGY.md) for architecture and remaining device checks.

Choose Daily, Weekdays or your own days, with multiple release times for morning and afternoon listening. Or enable Binge Mode to prepare the next matching episode whenever a Replay episode starts, keeping one episode ahead while retaining your existing Up Next priority order. Episode Limit can be changed directly in Replay and mirrors Podcast Settings. Brief update/sync guidance replaces the device-confirmation step; the enabling device still schedules releases.

## tvOS release update — 8 September 2026

The user’s screenshot confirms tvOS 1.6 (15) Ready for Distribution; older
build-13 submission references below are historical. tvOS 1.6.1 (1), including
Top Shelf, is now submitted for approval (user-confirmed 8 September 2026). iOS remains 1.6.1 (17). Submission text and
validation are in [the TV package](Docs/AppStore/tvOS-1.6.1/SUBMISSION.md).
Approval of TV 1.6.1 is pending. All future iOS and tvOS code updates are
tracked together in VERSION_1.7.md; the submitted TV release scope is closed.


**The podcast player for people who are serious about listening.**

Autohop is a native iOS podcast player built around a single idea: your time is the finite resource, not your content. Most podcast apps treat your queue like a to-do list you manage manually. Autohop manages it for you — automatically, intelligently, and indefinitely — so you can focus on everything else.

## Current release — 8 September 2026

Version 1.6.1 is approved and live in the App Store, confirmed by the user.
Its release ledger is complete. All future changes belong in
[Version 1.7](VERSION_1.7.md). Earlier preparation notes below are historical.

## Version 1.6.1 resubmission preparation — 6 September 2026

The iOS 1.6 rejection concerns Advertising age-rating metadata. The replacement
1.6.1 combines both release ledgers. Copy-ready release/review text and outstanding
checks are in [the submission record](Docs/AppStore/1.6.1/SUBMISSION.md).
Preparation is not an upload, submission or approval.

## Downloads list update — 6 September 2026

Artwork is centred vertically; full-width text sits above a separate lower status
band, matching the subscription-list hierarchy.

Downloads now uses shared adaptive episode-row sizing and native Play, Play Next,
Play Last and Archive swipes. Transfer controls remain inline; archive buttons
are removed. See [feature reference](FEATURES.md).

## Subscription search — 6 September 2026

The mini-player hides while subscription search has focus and returns when editing
ends, freeing room for results without interrupting playback.

The magnifying glass beside Discover searches existing subscriptions by show or
publisher name through an inline field. Results preserve priority order;
Clear restores all shows. See [feature reference](FEATURES.md).

## Podcast episode navigation update — 6 September 2026

Episode rows on the subscription page now open Episode Detail from the whole
row, including its title. Inline episode expansion is removed; swipe actions
are unchanged. See [page reference](PAGES.md).

## Episode Detail layout update — 6 September 2026

Episode artwork now scales with the available window width, and playback/queue/
archive actions are centred beneath the header. See [design reference](DESIGN.md).

## Onboarding presentation update — 6 September 2026

Quick Tips hide while the first-subscription milestone is open. That sheet now
keeps its actions below scrolling content, and long Quick Tips can grow and
scroll within their actual viewport. See [onboarding reference](ONBOARDING.md).

## Discover and Mac updates — 6 September 2026

The latest Mac report shows the tip-only fix was insufficient. Menu now receives
its full dependency set explicitly. The user confirmed the Mac Menu crash
resolved on 6 September 2026; this issue is complete.

Category pages combine rotating Top-8 episode cards with Top-100 shows and reliable
show-cover artwork fallback. The iPad app on Apple-silicon Macs now has application
menus and discoverable shortcuts; a persistent status icon remains planned.
Mini-player omissions and the Mac Menu Quick Tip crash are fixed in source.
See the [session record](Docs/SESSION_CHANGES_2026-09-06.md),
[Mac implementation](Docs/MAC_MENU_STAGE_1.md), and
[mini-player audit](Docs/MINI_PLAYER_AUDIT_2026-09-06.md) for scope and verification.

## Product Vision

Autohop is a **priority-playlist focused podcast player** aimed at serious, high-volume podcast listeners who want a premium, low-friction experience. The goal is an "endless" listening experience that requires minimal engagement from the user once set up, allowing them to stay present in whatever they're actually doing — driving, exercising, working — while the app keeps their listening moving forward without interruption.

Autohop is built for people who already know what they love — who subscribe to more shows than they can easily keep up with and want a player that respects both their taste and their time. It keeps their shows organised, always in the right order, played exactly the way they want them.

## Core Design Goals

**1. Set your priorities once. Listen indefinitely.**
The Priority Stack is a ranked list of subscriptions the user orders once. Autohop works down that list, surfaces only downloaded episodes, and flows from one to the next without any user input. Finish an episode mid-commute and the next one starts automatically — no decisions required.

**2. Audio that is actually comfortable to listen to.**
Per-podcast Trim Silence, Vocal Boost, playback speed, −3…+3 dB Volume Adjustment, Mono Audio, and start/end skip let users dial in the right listening experience for every show independently. Quietly mastered podcasts can be raised without changing device volume or affecting other subscriptions.

**3. Surgical queue control when you want it.**
The priority system handles everything automatically, but when a user wants to override it — Play Next or Play Last — two swipe gestures put them back in control instantly. The queue always shows exactly where things stand via color-coded status pills and pin badges.

**4. Downloads first, always.**
Autohop is a download-first player. The queue only ever plays files already on the device: no buffering mid-episode, no stalling on a poor signal. Background downloads keep the queue stocked quietly. Auto-archive policies clean up finished episodes per-podcast on a configurable schedule.

**5. Built for the serious listener, not the median user.**
Autohop's positioning is deliberately premium and niche. The target user subscribes to 10–30+ podcasts, listens several hours a day, and is frustrated that every mainstream app makes them manage their queue manually. This is the gap Autohop fills.


## Current Feature Set

> **Current development boundary:** iPhone and Apple TV are separate targets.
> Both use the user's private iCloud account as their sole cross-device sync
> transport; no Autohop account, paid sync tier, or external relay exists.
> See [`RELEASE_1_3.md`](RELEASE_1_3.md) for the archive and App Store checklist.

- First-run onboarding: a Welcome carousel, chart-derived one-tap Starter Packs, guiding empty states, a "You're all set" first-subscribe moment that auto-downloads and cues your first episode, contextual coach marks, and a getting-started checklist — designed to teach the Priority Stack model without forcing playback or asking for permissions up front
- "Open at launch" setting — choose whether the app opens to the Player, your Subscriptions, or Discover each time
- Priority Stack: reliably reorder several active shows in one session; Inactive
  shows stay fixed below them, and the complete order syncs atomically
- Endless auto-advancing queue with Play Next / Play Last manual overrides
- Discover page: browse Apple Podcasts charts with Top-8 heroes, quick category rails, category pages with Top-8 episode carousels and Top-100 shows, a storefront country picker, and fixed US/UK/AU country spotlights
- Podcast search via the iTunes catalog — search by name, author, or keyword; browse episode list before subscribing; 30-day recently viewed history
- Download-first playback; background downloads via URLSession
- Trim Silence engine (Off / Low / Medium / High, per-podcast) — RMS-based, ported from Pocket Casts algorithm
- Vocal Boost (Off / Light / Standard / Strong, per-podcast) — Pocket Casts-derived dynamics chain (high-pass filter → dynamics processor → peak limiter) targeting clearer spoken audio
- Per-podcast playback speed (1.0–2.5x), start skip, and end skip, with mirrored trim controls in both Podcast Settings and Default Playback that show compact minute/second values and debounce persistence so live playback stays responsive
- Per-podcast Mono Audio fold-down for correcting presenter mixes that strongly favour the left or right channel, with a Stereo/Mono default for future subscriptions
- Chapter support with active-chapter filtering and disabled-chapter skipping
- Audio and video podcast support with landscape unlock for full-screen video
- Release Radar adaptive feed refresh — learns each podcast's release schedule from filter-eligible publish history and automatically selects a 2–3 minute active-window, 5 minute pre-window, 5–10 minute missed-release, or 15–60 minute surveillance cadence; HTTP conditional requests (ETag/304) keep checks tiny
- Tiered, low-overhead diagnostics — normal logs preserve foreground/background refresh cycles, backlog, BGTask wakes, downloads and failures; an optional Detailed Refresh Trace adds per-feed Release Radar evidence only when investigating scheduling
- Deadline-aware background feed refresh, four-minute background-audio cycles (seven routine feeds; hard ceiling ten for urgent windows), resource-aware budget reduction, deferred-feed fairness/age diagnostics, and per-podcast exclude-from-refresh
- Explainable Auto Archive with a 25-minute execution gate, per-pass eligibility diagnostics, and a local Activity page recording the rule, threshold, and measured age behind each automatic archive
- Per-podcast Download Filters for automatic RSS downloads by episode duration, title, and description
- Play Instant for absolute-favourite shows — a newly auto-downloaded episode can gently warn, interrupt active playback, bypass Up Next, then return to the exact interrupted position; a brief route loss safely arms the arrival for up to 30 minutes instead of losing it
- Auto-archive policies per subscription (after-played delay, inactive timeout, episode limit)
- Episode status tracking: Unplayed / Queued / Paused / Playing / Played / Archived / Inactive / Skipped
- Listening History: searchable per-episode log with 60-second minimum playback threshold, grouped by date
- Stats page: time listened, time saved, episodes finished, and an explicitly all-time streak over **7 Days** (the intentional Monday-to-now calendar week), displayed month/year, and Lifetime periods — with a listening heatmap, monthly trend chart, 24-hour listening clock, canonical-feed Top Shows, durable per-episode outcomes, coverage/health disclosures, JSON/CSV export and importable backup, and a "Shows You're Drifting From" engagement list; stats are computed locally and sync only through the user's private iCloud while iCloud Sync is enabled
- Sleep timer: duration presets, end-of-episode mode with episode count, volume fade-out, and auto-restart on quick resume
- Sleep Schedule: a recurring nightly sleep timer — during your active-hours window a soft chime asks "still listening?" over continuing playback; any control confirms, no response fades out and rewinds to where you drifted off. Includes a player top-bar indicator and a time-sensitive lock-screen "Still Listening" notification you can tap without unlocking
- Safe sharing: adaptive episode and podcast cards, validated publisher-page
  links, conditional Copy Link, and no automatic media-enclosure or RSS-address
  exposure
- Global Default Playback panel — set the speed, Vocal Boost, Trim Silence, and start/end skip applied to every new subscription and to playback of not-yet-subscribed feeds, without touching shows you've already tuned; it uses the same trim-control UI as per-podcast settings
- Private iCloud sync (on by default for new users) — keeps played/archived state,
  per-podcast settings, subscribe/unsubscribe, the atomic Priority Stack order,
  listening history (including your resume position), per-podcast Download
  Filters, and stats in step across your devices over your private CloudKit
  database; downloads and global app settings stay per-device
- OPML import and export for subscription portability
- New episode push notifications (global and per-podcast; permission requested only when you opt in)
- Keep screen awake during playback and lock screen scrubbing options
- Lock screen / Now Playing controls (MPRemoteCommandCenter)
- CarPlay audio support: Now Playing, Up Next actions, downloaded-only playback, Play Now, Play Next, Play Last, Archive, playback speed adjustment, and Shared Listening controls
- Interactive **Now Playing & Up Next widgets** for small, medium, and large
  Home Screen families plus circular and rectangular Lock Screen/StandBy
  accessories. They show downloaded episodes only, use local prepared artwork,
  support play/pause or Play Now without foregrounding, and deep-link to Player,
  Up Next, episode details, or Discover.
- In-app Support / User Guide (Menu → Support): native drill-down guide that mirrors the website Support page
- Diagnostic logging for feeds, downloads, queue, playback/audio routes, main-thread watchdog gaps, and resource metrics (hidden developer tool)
- Deadline-aware background reliability: phase-aware absolute download watchdog
  deadlines (60s foreground / 4min background), generation-safe single-cancel
  retries with fresh per-cycle 30/60/120-second ladders and persisted 15/30/60-minute
  post-exhaustion cooldowns, an active-runtime recovery path, per-host and cross-host
  circuit breakers that pause only automatic downloads to a failing CDN, bounded
  feed parsing (episode/character caps + a parse-memory quarantine for pathological
  feeds), and an opportunistic BGAppRefresh backlog batch that runs only under safe
  time, power, thermal, network, and download load

## Documentation Map

[Diagnostic reliability repairs](Docs/DIAGNOSTIC_REPAIRS_2026-09-20.md) records the current recovery, persistence and diagnostic contracts and their validation limits.

[Podcast Replay implementation strategy](Docs/PODCAST_REPLAY_IMPLEMENTATION_STRATEGY.md)
is a Version 1.7 proposal covering scheduled back-catalogue releases, Feed Filters,
Episode Limit capacity, Replay pills and caught-up decisions. It is not implemented.


| File | Purpose |
|---|---|
| [`FEATURES.md`](FEATURES.md) | **Source of truth** for every feature, setting label, default, and behaviour. Update this first when any model/view/setting changes, then propagate to the website and App Store copy. |
| [`PAGES.md`](PAGES.md) | Canonical page names, code names, and the full navigation structure. |
| [`DESIGN.md`](DESIGN.md) | Design system — labelled, reusable UI patterns (the Up Next sheet is the canonical episode-row reference), plus the current glass-ready app icon recipe. |
| [`APPSTORE_ROADMAP.md`](APPSTORE_ROADMAP.md) | Live checklist of everything required before App Store submission (v1 = iPhone only), with drafted listing copy, review notes, and screenshot shot list. Updated as each step completes. |
| [`Docs/CARPLAY_CODE_STRATEGY.md`](Docs/CARPLAY_CODE_STRATEGY.md) | CarPlay implementation plan, phase gates, and release sequencing. |
| [`Docs/CARPLAY_PHASE9_QA.md`](Docs/CARPLAY_PHASE9_QA.md) | CarPlay simulator/hardware QA status and manual checklist. |
| [`SYNC_DESIGN.md`](SYNC_DESIGN.md) | Cross-device iCloud (CloudKit) sync design + build status — transport, conflict strategy, the `@Synced` field-level dirty-tracking, and per-domain merge rules. |
| [`APPSTATE_DECOMPOSITION_PROPOSAL.md`](APPSTATE_DECOMPOSITION_PROPOSAL.md) | Authoritative staged AppState ownership-migration design and implementation status. |
| [`APPSTATE_DECOMPOSITION_BASELINE.md`](APPSTATE_DECOMPOSITION_BASELINE.md) | Stage 0 source, automated-test, diagnostic, and device-only regression baseline. |
| [`Docs/WIDGETS_IMPLEMENTATION_PROPOSAL.md`](Docs/WIDGETS_IMPLEMENTATION_PROPOSAL.md) | Widget architecture, privacy/performance invariants, staged execution ledger, and device validation gates. |
| [`project_autohop.md`](project_autohop.md) | Fast machine-readable project brief: architecture, feature map, sync coverage, build notes, and licensing orientation. |
| [`VERSION_1.6.1.md`](VERSION_1.6.1.md) | Closed ledger for Version 1.6.1, approved and live. |
| [`VERSION_1.7.md`](VERSION_1.7.md) | Canonical running ledger for all future changes after the 1.6.1 release. |
| [`ASSESSMENT_2026-08-30.md`](ASSESSMENT_2026-08-30.md) | Latest whole-project point-in-time audit snapshot; Version 1.6.1 source and living documents supersede it where behavior changed later. |
| [`Docs/STATS_AUDIT_2026-08-30.md`](Docs/STATS_AUDIT_2026-08-30.md) | Historical Stats audit evidence plus a prominent resolution map to the implemented September redesign. |
| [`ASSESSMENT_2026-07-24.md`](ASSESSMENT_2026-07-24.md) / [`DEEP_SCAN_2026-06-28.md`](DEEP_SCAN_2026-06-28.md) / [`ASSESSMENT.md`](ASSESSMENT.md) | Earlier historical assessment context. Re-verify every finding against current source before acting. |
| [`NOTICE`](NOTICE) | Third-party derivation details (Pocket Casts), per-file licence status. |
| [`LICENSE`](LICENSE) / [`LICENSE-MPL-2.0.md`](LICENSE-MPL-2.0.md) | MIT for the project; MPL-2.0 text plus a project note listing the four covered files and acknowledging Pocket Casts as a broader source of design ideas and inspiration. |

Source files carry structured `AI CONTEXT` header comments (purpose,
responsibilities, collaborators, invariants) written for machine consumption —
read a file's header before modifying it. Update that header in the same task
when purpose, collaborators or invariants change, including compatibility fixes.
Keep the affected living documents and Version 1.7 ledger aligned; appending a
change note does not replace correcting obsolete guidance in the main sections.

Current session audits: [iOS 27 navigation](Docs/IOS27_NAVIGATION_BACK_AUDIT.md)
and [Sleep Schedule design](Docs/SLEEP_SCHEDULE_DESIGN_AUDIT.md). These distinguish
implemented changes, simulator evidence and outstanding physical-device checks.

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
