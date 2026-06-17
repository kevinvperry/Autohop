import SwiftUI

// AI CONTEXT — Views/SupportContent.swift
// The data model AND full content for the in-app Support / User Guide
// (rendered by SupportView, reached from the last Menu item). This MIRRORS the
// website Support page at kevmarl-site/support.html — the two are kept in sync
// by hand: whenever the support info changes, edit BOTH this file and
// support.html so the app and website always match. Content is pure data
// (SupportBlock values) so edits map cleanly onto the website's HTML blocks.
// Inline **bold** uses Markdown (parsed via AttributedString in SupportView).
// The website's SVG diagrams are intentionally omitted here — the surrounding
// text and tables carry the same information on a phone screen.

// MARK: - Block model

enum SupportCalloutStyle {
    case tip, note, warning

    var symbol: String {
        switch self {
        case .tip: return "lightbulb.fill"
        case .note: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .tip: return .purple
        case .note: return Color(red: 0.36, green: 0.6, blue: 1.0)
        case .warning: return Color(red: 0.96, green: 0.55, blue: 0.26)
        }
    }
}

struct SupportPill: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
}

struct SupportSwipeAction: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let color: Color
}

/// A single rendered element within a support section.
enum SupportBlock {
    case paragraph(String)
    case heading(String)
    case bullets([String])
    case steps([String])
    case callout(SupportCalloutStyle, String)
    /// `headers == nil` → two-column key/value rows. Otherwise each row's first
    /// cell is the title and the remaining cells are labelled by `headers`.
    case table(headers: [String]?, rows: [[String]])
    case pills([SupportPill])
    case swipe(rightTitle: String, right: [SupportSwipeAction],
               leftTitle: String, left: [SupportSwipeAction])
}

// MARK: - Section model

struct SupportSection: Identifiable {
    let id: String
    let icon: String          // SF Symbol
    let title: String
    let summary: String       // one-line subtitle for the drill-down list
    let blocks: [SupportBlock]
}

// MARK: - Shared colours (mirror the website status pills)

private enum SupportColor {
    static let gray = Color(white: 0.55)
    static let teal = Color(red: 0.05, green: 0.58, blue: 0.53)
    static let yellow = Color(red: 0.79, green: 0.54, blue: 0.02)
    static let green = Color(red: 0.09, green: 0.64, blue: 0.29)
    static let blue = Color(red: 0.15, green: 0.39, blue: 0.92)
    static let purple = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let orange = Color(red: 0.92, green: 0.35, blue: 0.05)
}

// MARK: - Content

enum SupportGuide {

    static let sections: [SupportSection] = [
        gettingStarted, priorityStack, queue, player, audioControls, chapters,
        downloads, podcastSettings, sleepTimer, sleepSchedule, video,
        notifications, opml, listeningHistory, stats, appSettings,
    ]

    // MARK: Getting Started

    private static let gettingStarted = SupportSection(
        id: "getting-started", icon: "sparkles", title: "Getting Started",
        summary: "Add your first podcast and let the queue fill itself",
        blocks: [
            .heading("Finding and adding podcasts"),
            .paragraph("Tap the **+** button in the top-right corner of the Priority page to open **Discover** — a browsing page of the Apple Podcasts charts, with a Top-8 carousel, genre rows, and a country picker. Tap the search bar at the top of Discover to search the catalog by show name, author, or keyword — results appear automatically as you type."),
            .paragraph("Tap any result to open the podcast preview. You'll see the full episode list straight away. You can browse episodes, read descriptions, and even play or queue individual episodes before deciding to subscribe."),
            .paragraph("When you're ready, tap **Subscribe**. The podcast is added to the top of your Priority Stack and Autohop begins checking it for new episodes immediately."),
            .callout(.tip, "**Not sure yet?** Any podcast you open is automatically saved in **Recently Viewed** for 30 days. Come back to it any time from the search screen — your place in the episode list is right where you left it."),
            .heading("How the queue fills automatically"),
            .paragraph("Once you have subscriptions and at least one downloaded episode, Autohop builds your queue automatically. You don't need to add episodes manually — the queue is drawn from downloaded, unplayed episodes across all your subscriptions, ordered by each podcast's priority rank. The Priority Stack section walks through this with an example."),
            .paragraph("Tap **Play** on any episode and Autohop advances through the queue without any further input from you."),
            .heading("The three main pages"),
            .table(headers: nil, rows: [
                ["Priority", "Your ranked list of subscriptions. Drag to reorder. This page controls the automatic queue order."],
                ["Queue", "Your current playback queue — all downloaded, unplayed episodes in priority order, with any manual overrides applied."],
                ["Downloads", "Active downloads, completed downloads, and archived episodes."],
            ]),
        ]
    )

    // MARK: Priority Stack

    private static let priorityStack = SupportSection(
        id: "priority-stack", icon: "list.number", title: "Priority Stack",
        summary: "Rank your shows once; the queue follows",
        blocks: [
            .paragraph("The Priority Stack is the core of Autohop. It's a ranked list of your subscriptions that determines the order episodes play. Shows at the top of the list are heard first."),
            .callout(.tip, "**How it works:** You rank shows once. Autohop plays every ready episode of show #1 before moving to show #2, and refills the queue automatically as new episodes download."),
            .heading("Reordering subscriptions"),
            .steps([
                "Tap **Reorder** in the top toolbar to enter edit mode.",
                "Drag the handle on the right side of any row to move it up or down.",
                "Tap **Done** when finished. The queue updates immediately.",
            ]),
            .heading("How priority affects playback"),
            .paragraph("When an episode finishes, Autohop picks the next episode from the subscription with the highest priority rank that has a downloaded, unplayed episode available. If your top-ranked show has no downloaded episodes, Autohop moves to the next show, and so on."),
            .callout(.tip, "**Example:** If \"Hard Fork\" is ranked #1 and \"Huberman Lab\" is ranked #2, Autohop will always play all available Hard Fork episodes before moving to Huberman Lab — unless you use Play Next / Play Last to override."),
            .heading("Refreshing feeds manually"),
            .paragraph("Tap the **↺ refresh** button in the toolbar to check all subscriptions for new episodes immediately. A spinner replaces the button while the refresh is in progress."),
            .heading("Episode status pills"),
            .paragraph("Each row shows a colour-coded pill indicating the status of the latest episode. An episode you listened to completion keeps its **Played** pill even after it is later archived:"),
            .pills([
                SupportPill(label: "Unplayed", color: SupportColor.gray),
                SupportPill(label: "Queued", color: SupportColor.teal),
                SupportPill(label: "Paused", color: SupportColor.yellow),
                SupportPill(label: "Playing", color: SupportColor.green),
                SupportPill(label: "Played", color: SupportColor.blue),
                SupportPill(label: "Archived", color: SupportColor.purple),
                SupportPill(label: "Inactive", color: SupportColor.orange),
            ]),
        ]
    )

    // MARK: Queue

    private static let queue = SupportSection(
        id: "queue", icon: "square.stack", title: "Queue",
        summary: "Swipe actions, pins, and what's up next",
        blocks: [
            .paragraph("The Queue sheet shows all episodes that are ready to play, in the order Autohop will play them. Open it by tapping the **Queue** button in the player toolbar."),
            .heading("Swipe actions"),
            .swipe(
                rightTitle: "Swipe Right",
                right: [
                    SupportSwipeAction(label: "Play", detail: "Start this episode immediately", color: SupportColor.green),
                    SupportSwipeAction(label: "Play Next", detail: "Move to front of queue", color: SupportColor.blue),
                ],
                leftTitle: "Swipe Left",
                left: [
                    SupportSwipeAction(label: "Archive", detail: "Mark as done, remove from queue", color: SupportColor.purple),
                    SupportSwipeAction(label: "Play Last", detail: "Push to end of queue", color: SupportColor.orange),
                ]
            ),
            .callout(.note, "**Note:** Full swipe is disabled on both sides — all actions require a deliberate partial swipe and tap to prevent accidental triggers."),
            .heading("Pin badges"),
            .paragraph("Episodes manually positioned in the queue show a pin badge above their duration:"),
            .bullets([
                "**Blue pin** — Play Next (promoted to front)",
                "**Orange pin** — Play Last (demoted to end)",
            ]),
            .heading("Up Next indicator"),
            .paragraph("The episode immediately after the currently playing one is labelled \"Up Next\" in the queue so you always know what's coming."),
        ]
    )

    // MARK: Player

    private static let player = SupportSection(
        id: "player", icon: "play.circle.fill", title: "Player",
        summary: "Panels, controls, and lock-screen integration",
        blocks: [
            .paragraph("The player has two or three swipeable panels depending on whether the current episode has chapter data. Swipe left and right to move between them."),
            .table(headers: ["Panel", "Contents", "When shown"], rows: [
                ["Now Playing", "Artwork, episode title, podcast name, scrubber, playback controls, skip buttons, audio row", "Always"],
                ["Details", "Full episode description and show notes", "Always"],
                ["Chapters", "Chapter list with timestamps. Tap any chapter to jump to it.", "Only when the episode has chapter data"],
            ]),
            .heading("Playback controls"),
            .bullets([
                "**Skip back / Skip forward** — Jumps by the number of seconds configured in Settings (default 15s back / 30s forward).",
                "**Scrubber** — Drag to seek to any position. Shows elapsed and remaining time.",
                "**Audio controls button** — Opens the Audio Controls sheet for speed, trim silence, and vocal boost.",
                "**Sleep timer** — Tap the moon icon to set a sleep timer.",
                "**Queue button** — Opens the queue sheet.",
            ]),
            .heading("Lock screen & Control Centre"),
            .paragraph("Autohop integrates with iOS Now Playing controls. Play/pause, skip forward, skip back, and scrubbing all work from the Lock Screen, Control Centre, and CarPlay."),
            .heading("Return to Player button"),
            .paragraph("The player is always running underneath every other page — playback never stops when you navigate away. Every page in the app has a **play.circle.fill** button (▶) in the top-left toolbar. Tap it to jump back to the player from anywhere."),
        ]
    )

    // MARK: Audio Controls

    private static let audioControls = SupportSection(
        id: "audio-controls", icon: "slider.horizontal.3", title: "Audio Controls",
        summary: "Speed, Trim Silence, Vocal Boost, Shared Listening",
        blocks: [
            .paragraph("Tap the audio controls button in the player to open the Audio Controls sheet. Speed, Trim Silence, and Vocal Boost apply to the **current podcast** and are saved permanently — they are not global settings. The one exception is Shared Listening, a global temporary override at the top of the sheet."),
            .heading("Playback Speed"),
            .paragraph("Tap **−** or **+** to adjust speed in 0.1× steps. Range: 1.0× to 2.5×. The default for new subscriptions is 1.6×."),
            .paragraph("Speed changes take effect immediately and persist for that podcast."),
            .heading("Trim Silence"),
            .paragraph("Trim Silence removes quiet gaps in audio — pauses between sentences, dead air between questions — without affecting speech. The algorithm analyses audio in real time using RMS (root mean square) energy measurement. It shortens the gaps between speech, never the speech itself; higher levels remove shorter and shorter gaps."),
            .table(headers: ["Level", "Effect", "Best for"], rows: [
                ["Off", "No processing", "Music, narrative, sound-designed shows"],
                ["Low", "Removes only the longest gaps", "Default — works well for most shows"],
                ["Medium", "Removes medium and long gaps", "Conversational interviews"],
                ["High", "Aggressively removes all gaps", "Dense panel discussions, Q&A formats"],
            ]),
            .callout(.tip, "**Tip:** Trim Silence and Vocal Boost activate the AVAudioEngine processing path. Video episodes always use the standard AVPlayer path — Trim Silence has no effect on video podcasts."),
            .heading("Vocal Boost"),
            .paragraph("Vocal Boost applies EQ enhancement to make speech clearer and more present — particularly useful at high speeds, in noisy environments, or with podcasts recorded on low-quality microphones."),
            .table(headers: ["Level", "Effect"], rows: [
                ["Off", "No EQ processing"],
                ["Light", "Subtle presence boost — barely perceptible"],
                ["Standard", "Moderate clarity enhancement"],
                ["Strong", "Maximum clarity — default for new subscriptions"],
            ]),
            .callout(.note, "**Note:** Vocal Boost processes audio through a high-pass filter, dynamic compressor, and peak limiter — all tuned for spoken voice. Strong also increases perceived loudness, which is intentional. Use your device volume for overall level."),
            .heading("Shared Listening"),
            .paragraph("Shared Listening is built for the moments you're not listening alone — a car stereo with passengers, a kitchen speaker, a road trip. If your shows are set to 1.6× or 1.7× with Trim Silence on, that's perfect through headphones but uncomfortable for a group."),
            .paragraph("Flip the **Shared Listening** toggle at the top of the Audio Controls sheet and every podcast temporarily plays at a relaxed group speed with Trim Silence switched off. Your per-podcast settings are never altered — turn the toggle off and everything returns exactly as it was."),
            .table(headers: ["Behaviour", "Detail"], rows: [
                ["Speed options", "1× / 1.1× / 1.2× / 1.3× — always starts at 1× when activated"],
                ["Trim Silence", "Paused for all podcasts while active"],
                ["Vocal Boost", "Unaffected — voices stay clear on the car stereo"],
                ["Persistence", "Stays on across app restarts until you switch it off"],
                ["Your settings", "Untouched — everything resumes instantly when deactivated"],
            ]),
            .callout(.tip, "**Tip:** While Shared Listening is on, the audio controls button in the player turns **white** (just like the sleep timer when it's running), and the per-podcast Speed and Trim Silence rows are greyed out so it's always obvious the override is in charge."),
            .callout(.note, "**Unique to Autohop:** No mainstream podcast app — Apple Podcasts, Pocket Casts, or Overcast — offers a one-tap global speed override for group listening. Everywhere else you'd have to change each show's speed by hand and change it all back later."),
        ]
    )

    // MARK: Chapters

    private static let chapters = SupportSection(
        id: "chapters", icon: "list.bullet.indent", title: "Chapters",
        summary: "Jump to or permanently skip chapters",
        blocks: [
            .paragraph("If a podcast episode includes chapter data, a Chapters panel appears as the third tab in the player. It lists all chapters with their titles and timestamps."),
            .heading("Jumping to a chapter"),
            .paragraph("Tap any chapter row to jump to that position in the episode immediately."),
            .heading("Disabling chapters"),
            .paragraph("**Tap** any chapter row to toggle it between enabled and disabled. Disabled chapters are shown with a strikethrough and skipped automatically during playback — Autohop jumps past them without any input. This is useful for sponsor reads, recurring segments, or intros you've already heard many times."),
            .paragraph("Tap a disabled chapter row again to re-enable it. The currently playing chapter cannot be disabled."),
            .callout(.tip, "**Tip:** Chapter skips are stored per-podcast, not per-episode. Disabling a chapter at position 1 skips the first chapter on every future episode of that podcast — perfect for permanently skipping a show's recurring intro or sponsor read that always appears in the same slot."),
        ]
    )

    // MARK: Downloads

    private static let downloads = SupportSection(
        id: "downloads", icon: "arrow.down.circle", title: "Downloads",
        summary: "Download-first playback, background & cellular",
        blocks: [
            .paragraph("Autohop is a **download-first** player. Episodes must be downloaded before they can be played. The app never streams directly from the internet during playback."),
            .heading("Downloading an episode"),
            .paragraph("In the Queue or Priority pages, swipe right on an episode that hasn't been downloaded yet and tap **Download**. A progress bar appears in the episode row while downloading."),
            .paragraph("You can also tap the **Download** button that appears inline in the episode metadata row for any undownloaded episode."),
            .heading("Background downloads"),
            .paragraph("Downloads continue in the background even when Autohop is not the active app. If a download is in progress and you lock your phone or switch apps, it will complete automatically using iOS background URL sessions."),
            .heading("Pausing and cancelling"),
            .paragraph("Open the **Downloads** page to see all active downloads. Tap a download row to pause it. Tap again to resume. Swipe left to cancel."),
            .heading("Cellular downloads"),
            .paragraph("By default, Autohop downloads over Wi-Fi only. To also download over mobile data, go to **Settings → Downloading** and turn on **Download over cellular**. You can also turn off **Download over WiFi** if you want full manual control."),
            .heading("Storage"),
            .paragraph("Downloaded episode files are stored in the app's private storage. Go to **Settings → Storage** to see how many episodes are currently downloaded. Episodes are automatically removed when archived (manually or by auto-archive policy)."),
        ]
    )

    // MARK: Per-Podcast Settings

    private static let podcastSettings = SupportSection(
        id: "podcast-settings", icon: "gearshape", title: "Per-Podcast Settings",
        summary: "Independent speed, skips, and auto-archive rules",
        blocks: [
            .paragraph("Every podcast has its own independent settings. To access them, tap any podcast row in the Priority page to open its episode list, then tap the **gear icon** (⚙) in the top-right toolbar."),
            .heading("Playback settings"),
            .table(headers: ["Setting", "Description"], rows: [
                ["Speed", "Playback speed for this podcast (1.0× – 2.5×). Default: 1.6×"],
                ["Vocal Boost", "EQ enhancement level (Off / Light / Standard / Strong). Default: Strong"],
                ["Trim Silence", "Silence removal level (Off / Low / Medium / High). Default: Low"],
                ["Start Skip", "Seconds to skip at the beginning of every episode. Measured in real file time, independent of playback speed. Range: 0–300s. Default: off. Primary use case: skipping a recurring show intro or theme music."],
                ["End Skip", "Seconds to skip at the end of every episode. Measured in real file time, independent of playback speed. Range: 0–300s. Default: off. Primary use case: skipping a recurring outro or trailing ad read."],
            ]),
            .heading("Auto-archive policy"),
            .paragraph("Auto-archive has three independent rules that work together to keep your storage tidy. Each is set per podcast and works on its own — whichever one matches first sends the episode to the archive and frees its storage."),
            .paragraph("**After Played** — how soon a finished episode is archived and its file deleted:"),
            .table(headers: ["Option", "Behaviour"], rows: [
                ["Never", "Played episodes are kept until manually archived."],
                ["After Playing (default)", "Archived as soon as the episode finishes."],
                ["After 24h", "Archived 24 hours after completion."],
                ["After 2 Days", "Archived 2 days after completion."],
                ["After 1 Week", "Archived 1 week after completion."],
            ]),
            .paragraph("**After Inactive** — how long an unplayed, untouched episode is kept before being archived. Options range from Never to 90 Days. Default: **1 Week**. Useful for news or daily shows where old episodes become irrelevant quickly."),
            .paragraph("**Episode Limit** — keep only the N most recently published episodes; older ones are archived automatically. Options: No Limit, 1 (default), 2, 3, 4, 5, or 10 episodes."),
            .callout(.tip, "**Tip:** The defaults (archive immediately after playing, inactive episodes gone after 1 week, keep 1 episode) are designed for high-volume listeners who want zero maintenance."),
            .heading("Exclude from auto-refresh"),
            .paragraph("Toggle this on to stop Autohop polling this podcast's RSS feed for new episodes. The podcast and all its downloaded episodes stay in your library — you just won't receive new ones automatically. The intended use case is finished or completed shows you want to keep but no longer need updates from."),
            .heading("Notifications"),
            .paragraph("Toggle on to receive a notification when a new episode from this podcast is available. **Off by default** — notifications are opt-in per show, so you only hear about the podcasts you choose. The global notification toggle in Settings must also be on."),
        ]
    )

    // MARK: Sleep Timer

    private static let sleepTimer = SupportSection(
        id: "sleep-timer", icon: "moon.zzz", title: "Sleep Timer",
        summary: "One-shot timer by duration or episode count",
        blocks: [
            .paragraph("The sleep timer automatically pauses playback after a set duration. Tap the **moon icon** in the player toolbar to open the Sleep Timer sheet."),
            .heading("Setting a timer"),
            .paragraph("Choose a duration — **5 min, 10 min, 15 min, 30 min, 45 min,** or **1 hour** — and tap to start immediately."),
            .paragraph("Or use **End of Episode** mode: set a count (1–10 episodes) using the stepper, then tap **Set**. Autohop pauses after that many episodes finish."),
            .paragraph("While a timer is active, the moon icon shows a countdown badge. Tap the moon again to see the active timer, extend it by +5 minutes, or cancel it."),
            .callout(.tip, "**Tip:** \"End of Episode\" mode (count: 1) is the most natural option for falling asleep — playback stops cleanly at the end of the episode without cutting off mid-sentence."),
        ]
    )

    // MARK: Sleep Schedule

    private static let sleepSchedule = SupportSection(
        id: "sleep-schedule", icon: "bed.double.fill", title: "Sleep Schedule",
        summary: "A recurring nightly timer that checks if you're awake",
        blocks: [
            .paragraph("Sleep Schedule is a **recurring, nightly sleep timer** — set it up once and it works every night, no taps required at bedtime. It's an Autohop exclusive: nothing like it exists in Apple Podcasts, Pocket Casts or Overcast."),
            .heading("Setting it up"),
            .steps([
                "Open the **Menu** (☰) → **Sleep Schedule**.",
                "Turn on the toggle and choose your **Active Hours** — for example 9:00pm to 6:00am. The window can cross midnight.",
                "Choose how often Autohop should check in: **10, 15, 20, 40 or 60 minutes**, or **End of Episode** to ask at each episode boundary.",
            ]),
            .heading("How a night works"),
            .paragraph("Start playing anything during your active hours and the schedule arms itself. After the chosen duration, a **soft, meditative chime** plays over your podcast — playback doesn't stop — asking, in effect, \"are you still listening?\""),
            .bullets([
                "**Still awake?** Tap any control — play/pause on the lock screen, an earbud tap, skip forward or back, the on-screen button, or the **\"Still Listening\" button on the lock-screen notification** (no need to unlock your phone). Playback simply continues and the cycle restarts.",
                "**Asleep?** If you don't respond within a minute, playback fades out gently, pauses, and **rewinds to the moment the chime began** — so in the morning you resume from the last thing you actually heard.",
            ]),
            .callout(.tip, "**Tip:** Setting the regular Sleep Timer from the player overrides the schedule for that session — handy for nights when you want a fixed cutoff instead of check-ins."),
        ]
    )

    // MARK: Video

    private static let video = SupportSection(
        id: "video", icon: "film", title: "Video Podcasts",
        summary: "Full-screen video, landscape, and audio processing",
        blocks: [
            .paragraph("Autohop supports both audio and video podcast feeds. Video episodes are detected automatically from the RSS feed."),
            .heading("Playback"),
            .paragraph("Video episodes open in the native iOS video player embedded in the player view. Tap the **full screen** button to expand to landscape full-screen mode."),
            .heading("Landscape orientation"),
            .paragraph("Autohop unlocks landscape rotation when a video episode is playing full-screen. Rotate your device to landscape and the video fills the screen. Rotating back to portrait returns to the standard player view."),
            .heading("Audio processing on video"),
            .paragraph("Trim Silence and Vocal Boost are not applied to video episodes — video always uses the standard AVPlayer playback path. Playback speed and skip settings still apply to video."),
        ]
    )

    // MARK: Notifications

    private static let notifications = SupportSection(
        id: "notifications", icon: "bell", title: "Notifications",
        summary: "Opt-in, per-podcast new-episode alerts",
        blocks: [
            .paragraph("Autohop can notify you when new episodes from your subscriptions are downloaded and ready to play."),
            .heading("Enabling notifications"),
            .steps([
                "Go to **Settings → Release Radar → Notification Settings** and turn on the **New episode notifications** master toggle.",
                "iOS will prompt for notification permission the first time — tap **Allow**. If you previously denied permission, the page shows a banner with an **Open iOS Settings** shortcut.",
                "Then turn on the toggle for each podcast you want to hear about — right there on the Notification Settings page, or in each podcast's own settings.",
            ]),
            .heading("Per-podcast control"),
            .paragraph("Notifications are **off by default for every podcast** — you opt in only for the shows you want to hear about. The Notification Settings page lists every subscription with its own toggle, plus **Enable All** / **Disable All** buttons. Both the master toggle and the per-podcast toggle must be on for a notification to fire."),
            .callout(.note, "**Note:** Autohop uses local notifications only. No data leaves your device to deliver them — they are generated entirely on-device when the app detects a new episode."),
        ]
    )

    // MARK: OPML

    private static let opml = SupportSection(
        id: "opml", icon: "arrow.up.arrow.down", title: "OPML Import & Export",
        summary: "Migrate or back up your subscription list",
        blocks: [
            .paragraph("OPML is a standard format for transferring podcast subscription lists between apps. Use it to migrate from another podcast player or to back up your subscriptions."),
            .heading("Importing from another app"),
            .steps([
                "Export your subscriptions as an OPML file from your current podcast app.",
                "In Autohop, go to **Settings → Subscriptions → Import OPML**.",
                "Select the OPML file from Files or your Downloads folder.",
                "Autohop imports all feeds. Duplicates are skipped automatically.",
            ]),
            .heading("Exporting your subscriptions"),
            .steps([
                "Go to **Settings → Subscriptions → Export OPML**.",
                "The standard iOS share sheet opens — save to Files, AirDrop, or email it to yourself.",
            ]),
            .callout(.tip, "**Tip:** Export regularly as a backup. OPML files capture all your feed URLs and subscription order, so you can restore your entire library to a new device or app quickly."),
        ]
    )

    // MARK: Listening History

    private static let listeningHistory = SupportSection(
        id: "listening-history", icon: "clock.arrow.circlepath", title: "Listening History",
        summary: "A searchable record of what you've played",
        blocks: [
            .paragraph("Autohop keeps a searchable record of every episode you've listened to. Access it from the **Menu (☰) → Listening History**, or from **Settings → Subscriptions → Listening History**."),
            .paragraph("Only episodes with at least 1 minute of actual playback are shown — episodes that were archived or skipped before the 1-minute mark are excluded."),
            .heading("Stats header"),
            .paragraph("The top of the page shows two summary stats: **Listening Time** (total audio time consumed across qualifying episodes) and **Episodes** (total count of played or archived episodes with at least 1 minute of playback)."),
            .heading("History list"),
            .paragraph("Episodes are grouped by date — Today, Yesterday, then older dates. Each row shows the podcast artwork, episode title, podcast name, and a status badge with how much you listened:"),
            .bullets([
                "**Listened** — you played part of the episode but didn't finish it. Shows time remaining.",
                "**Played** — episode marked as played.",
                "**Archived** — episode was archived.",
            ]),
            .heading("Search"),
            .paragraph("Tap the search bar at the top to filter history by episode title or podcast name. Results update as you type."),
        ]
    )

    // MARK: Stats

    private static let stats = SupportSection(
        id: "stats", icon: "chart.bar", title: "Stats",
        summary: "On-device listening insights and time saved",
        blocks: [
            .paragraph("Access your listening stats from the **Menu (☰) → Stats**."),
            .paragraph("Pick a time period at the top of the page — **This Week, the current month (e.g. June), the current year (e.g. 2026), or Lifetime** — and every chart below responds to it. The first three are calendar periods that start fresh and fill in as they go: This Week runs Monday to Sunday (resets every Monday), the month resets on the 1st, and the year resets on January 1st. All stats are computed and stored entirely on your device."),
            .heading("What the page shows"),
            .table(headers: nil, rows: [
                ["Hero card", "Total time listened in the period, time saved by Autohop, episodes finished, and your current listening streak (a day counts once you listen for at least a minute)."],
                ["Listening Heatmap", "A calendar-style grid (This Week and current-month views) where each square is a day, with weeks starting on Monday — the deeper the purple, the more you listened. The caption calls out your busiest day. On the year and Lifetime views this becomes a month-by-month bar chart."],
                ["Listening Clock", "A 24-hour dial showing when you listen — midnight at the top, noon at the bottom. The caption shows your peak listening hour."],
                ["Top Shows", "Your most-listened podcasts for the period, ranked with artwork and relative listening bars. Shows you've unsubscribed from still appear. Tap any show to expand a detail card — episodes finished, time saved on that show, its share of your listening, average completion, and how soon after release you typically listen. Tap Show All to see your top 50, including how each show's rank moved against the previous comparable period (the previous week, month, or year)."],
                ["Shows You're Drifting From", "On This Week and current-month views, Autohop highlights up to five subscribed shows you appear to be losing interest in — either ones you keep abandoning part-way or archiving unplayed, or “ghost” subscriptions whose episodes keep downloading and aging out without you ever finishing one (a sign you might want to unsubscribe). Each row has a specific insight and a completion bar. Tap a show to expand its detail card (with a shortcut to the podcast's settings), or long-press to hide it or unsubscribe. A show you genuinely keep up with — finishing some episodes and letting the rest cycle — is never flagged, and the section only appears when a show qualifies."],
                ["Data Downloaded", "How much data Autohop downloaded in the selected period, with the number of episodes and the average size each. Only successful downloads count (a re-download counts again). This is measured on your device and counts from the update that introduced it — it won't include downloads from before then, so the Lifetime figure builds up over time."],
            ]),
            .heading("Time Saved breakdown"),
            .table(headers: nil, rows: [
                ["Skipping", "Total time saved by tapping the skip-forward button. Each tap adds the skip amount to this total."],
                ["Variable Speed", "Time saved by listening faster than 1×. Calculated as the difference between your set speed and real-time playback."],
                ["Trim Silence", "Time saved by silence removal. Counts only the frames actually dropped from the audio stream."],
                ["Auto Skipping", "Time saved by per-podcast start skip and end skip settings firing automatically at episode boundaries."],
            ]),
            .paragraph("The **Total** row sums all four categories. Time saved totals you accumulated in earlier versions of Autohop are preserved and included in the Lifetime view."),
        ]
    )

    // MARK: App Settings

    private static let appSettings = SupportSection(
        id: "app-settings", icon: "wrench.and.screwdriver", title: "App Settings",
        summary: "Release Radar, downloading, controls, and more",
        blocks: [
            .paragraph("Access global settings via the hamburger menu (☰) on the Priority page → **Settings**."),
            .heading("Release Radar"),
            .paragraph("Autohop learns each podcast's release schedule and starts watching its feed just before a new episode is expected. Checks are tiny — the feed is only downloaded when it has actually changed — so new episodes appear within minutes of release without draining battery or data."),
            .table(headers: nil, rows: [
                ["Radar sensitivity", "How often a feed is re-checked while a new episode drop is imminent. Range: 1–60 minutes. Default: 5 minutes. Lower means new episodes appear faster."],
                ["Notification Settings", "Opens the Notification Settings page — the global master toggle (off by default), Enable All / Disable All, and a per-podcast toggle for every subscription."],
            ]),
            .heading("Auto-Archive"),
            .table(headers: nil, rows: [
                ["Run Auto Archive Now", "Manually trigger the auto-archive pass across all podcasts. Checks every subscription against its per-podcast Auto Archive rules. Runs automatically at most every 30 minutes."],
            ]),
            .heading("Downloading"),
            .table(headers: nil, rows: [
                ["Downloads", "Navigate to the Downloads page showing active, completed, and recently archived episodes."],
                ["Download over WiFi", "Allow downloads on Wi-Fi networks. On by default."],
                ["Download over cellular", "Allow downloads over mobile data. Off by default — turn on to download over cellular as well as Wi-Fi."],
            ]),
            .heading("Controls"),
            .table(headers: nil, rows: [
                ["Keep Screen Awake", "Prevents the screen from dimming or locking while an episode is actively playing in the full-screen player. Has no effect when playback is paused. Off by default."],
                ["Lock Screen Scrubbing", "Allows seeking from the Lock Screen and Control Centre scrubber. On by default. Turn off to prevent accidental seeks when your phone is in your pocket."],
                ["Queue Badge", "Shows a number on the Autohop app icon counting how many downloaded episodes are ready to play. On by default. Turn off to clear the badge."],
                ["Skip back", "Duration of the skip-back button in the player. Range: 5–120 seconds in 5-second steps. Default: 15s."],
                ["Skip forward", "Duration of the skip-forward button in the player. Range: 5–120 seconds in 5-second steps. Default: 30s."],
            ]),
            .heading("Subscriptions"),
            .table(headers: nil, rows: [
                ["Manage podcasts", "Navigate to the Priority page to reorder, add, or remove subscriptions."],
                ["Add RSS Feed", "Enter a podcast RSS URL directly to subscribe to a show not found in the search directory."],
                ["Listening History", "View your full listening history — grouped by date, searchable. Also accessible from the Menu (☰)."],
                ["Import OPML", "Import subscriptions from another podcast app. See the OPML Import & Export section."],
                ["Export OPML", "Export your subscription list as an OPML file for backup or migration."],
            ]),
            .heading("Storage"),
            .paragraph("Shows the count of currently downloaded episodes. To free storage, archive episodes in the Queue or adjust the Episode Limit in your per-podcast auto-archive settings."),
            .heading("About"),
            .paragraph("Shows the app version number and a link to Open Source Acknowledgements."),
            .callout(.tip, "**Having an issue?** Get in touch from the Contact page at kevmarl.com — include your iOS version and a description of what happened."),
        ]
    )
}
