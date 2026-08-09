import Foundation

// AI CONTEXT — Models/AppSettings.swift
// Global (non-per-podcast) settings value type, persisted by SettingsStore as
// JSON. These are currently local/device settings only: CloudKit sync covers
// subscriptions, episode state, listening history, and stats, but not AppSettings.
// Keep every default synchronized with FEATURES.md, SYNC_DESIGN.md, SettingsView,
// SupportContent, and the website Support/Privacy pages. In particular,
// downloadOverWifi and downloadOverCellular both intentionally default true:
// a fresh install should keep the download-first queue stocked on Wi-Fi and
// mobile data unless the user chooses to restrict either network type.
// Diagnostic logging has two local-only switches: the master enables compact
// outcome-focused logging/resource monitoring; verboseDiagnosticLoggingEnabled
// adds short-term per-feed Release Radar traces and defaults off.

/// Which screen Autohop opens to on a normal cold launch (set in App Settings →
/// Startup). The first-run Welcome flow always takes precedence for brand-new
/// users; this applies once onboarding is complete. See RootView launch routing.
enum LaunchScreen: String, Codable, CaseIterable, Identifiable, Sendable {
    case player
    case subscriptions
    case discover

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .player:        return "Player"
        case .subscriptions: return "Subscriptions"
        case .discover:      return "Discover"
        }
    }
}

// podcastPollMinutes is retained only for backward-compatible decoding of
// existing settings files. Version 1.4 Release Radar scheduling is automatic;
// runtime code must not consult this legacy value. The *Migrated flags
// are one-shot first-launch migration markers (e.g. moving existing users to
// the 1.6x speed / Strong boost / Low trim defaults) — never remove a flag
// once shipped or the migration will re-run. Defaults here must stay in sync
// with the FEATURES.md "Model Defaults Quick Reference" appendix.
// recapWeeklyEnabled defaults true for a fresh Version 1.5 install; monthly and
// yearly remain false. Older decoded settings with a missing recap field retain
// the historical false fallback so this product-default change never opts in an
// existing user.
// The hasCompletedWelcome / hasSubscribedFirstShow / hasPlayedFirstEpisode /
// hasSeenDownloadFirstNote / dismissedGettingStarted flags drive the first-run
// onboarding experience (see ONBOARDING_PLAN.md) — all default false so a fresh
// install is treated as a new user, and existing installs decode them as false
// too (they will be reconciled on first launch by AppState).
struct AppSettings: Equatable, Codable {
    var podcastPollMinutes: Int
    var downloadOverWifi: Bool
    var downloadOverCellular: Bool
    var notifyNewEpisodes: Bool
    var skipBackSeconds: TimeInterval
    var skipForwardSeconds: TimeInterval
    var keepScreenAwakeDuringPlayback: Bool
    var lockScreenScrubbingEnabled: Bool
    var diagnosticLoggingEnabled: Bool
    // Detailed per-feed/queue/widget trace. OFF by default; normal diagnostics
    // retain cycle summaries, failures, changes, background wakes and backlog.
    var verboseDiagnosticLoggingEnabled: Bool
    var showQueueBadge: Bool
    // Shared Listening: global temporary override — caps speed (1.0–1.3x) and
    // disables Trim Silence on ALL podcasts without touching per-sub settings.
    var sharedListeningActive: Bool
    var sharedListeningSpeed: Double
    // Sleep Schedule: nightly recurring sleep timer. Window is minutes from
    // midnight (may span it); duration 0 = prompt at end of episode.
    var sleepScheduleEnabled: Bool
    var sleepScheduleStartMinutes: Int
    var sleepScheduleEndMinutes: Int
    var sleepScheduleDurationMinutes: Int
    var lastAutoArchiveRunAt: Date?
    var autoArchiveDefaultMigrated: Bool
    var vocalBoostLevelMigrated: Bool
    var trimSilenceLowDefaultMigrated: Bool
    var playbackSpeed160Migrated: Bool
    var autoArchiveSettingsMigrated: Bool
    // Cross-device iCloud sync (CloudKit). ON for a fresh install so iPhone and
    // Apple TV can become useful together without a hidden setup dependency.
    // Existing saved settings remain authoritative.
    var iCloudSyncEnabled: Bool
    // Listening Recaps: periodic stats-summary notifications (Mechanism B — a
    // teaser notification that deep-links into the Stats "Last" view). Weekly is
    // ON for new users; monthly/yearly remain OFF.
    var recapWeeklyEnabled: Bool
    var recapMonthlyEnabled: Bool
    var recapYearlyEnabled: Bool
    // First-run onboarding state (see ONBOARDING_PLAN.md). All default false.
    var hasCompletedWelcome: Bool
    var hasSubscribedFirstShow: Bool
    var hasPlayedFirstEpisode: Bool
    var hasSeenDownloadFirstNote: Bool
    var dismissedGettingStarted: Bool
    // Which screen the app opens to on a normal cold launch (App Settings → Startup).
    var launchScreen: LaunchScreen
    // Default playback settings (speed / trim silence / vocal boost / start /
    // end skip) applied to every NEW subscription at the moment it becomes a
    // real subscription, and used live for playback of non-subscribed (browse)
    // feeds. Editing this NEVER touches existing subscriptions' own settings —
    // see AppState.effectivePreference(for:) and SubscriptionStore seeding.
    var defaultPlaybackPreference: PlaybackPreference
    // Default Auto Archive settings applied to every NEW subscription at subscribe
    // time. Editing this NEVER touches existing subscriptions — each subscription
    // keeps its own independent AutoArchiveSettings after that point.
    var defaultAutoArchiveSettings: AutoArchiveSettings

    static let `default` = AppSettings(
        podcastPollMinutes: 5,
        downloadOverWifi: true,
        downloadOverCellular: true,
        notifyNewEpisodes: true,
        skipBackSeconds: 15,
        skipForwardSeconds: 30,
        keepScreenAwakeDuringPlayback: false,
        lockScreenScrubbingEnabled: true,
        diagnosticLoggingEnabled: false,
        verboseDiagnosticLoggingEnabled: false,
        showQueueBadge: true,
        sharedListeningActive: false,
        sharedListeningSpeed: 1.0,
        sleepScheduleEnabled: false,
        sleepScheduleStartMinutes: 21 * 60,
        sleepScheduleEndMinutes: 6 * 60,
        sleepScheduleDurationMinutes: 20,
        lastAutoArchiveRunAt: nil,
        autoArchiveDefaultMigrated: false,
        vocalBoostLevelMigrated: false,
        trimSilenceLowDefaultMigrated: false,
        playbackSpeed160Migrated: false,
        autoArchiveSettingsMigrated: false,
        iCloudSyncEnabled: true,
        recapWeeklyEnabled: true,
        recapMonthlyEnabled: false,
        recapYearlyEnabled: false,
        hasCompletedWelcome: false,
        hasSubscribedFirstShow: false,
        hasPlayedFirstEpisode: false,
        hasSeenDownloadFirstNote: false,
        dismissedGettingStarted: false,
        launchScreen: .player,
        // Fresh installs start new subscriptions with Strong Vocal Boost.
        // Saved AppSettings and existing per-subscription preferences remain
        // authoritative and are never rewritten by this factory value.
        defaultPlaybackPreference: .newUserDefault,
        defaultAutoArchiveSettings: .default
    )

    private enum CodingKeys: String, CodingKey {
        case podcastPollMinutes
        case downloadOverWifi
        case downloadOverCellular
        case notifyNewEpisodes
        case skipBackSeconds
        case skipForwardSeconds
        case keepScreenAwakeDuringPlayback
        case lockScreenScrubbingEnabled
        case diagnosticLoggingEnabled
        case verboseDiagnosticLoggingEnabled
        case showQueueBadge
        case sharedListeningActive
        case sharedListeningSpeed
        case sleepScheduleEnabled
        case sleepScheduleStartMinutes
        case sleepScheduleEndMinutes
        case sleepScheduleDurationMinutes
        case lastAutoArchiveRunAt
        case autoArchiveDefaultMigrated
        case vocalBoostLevelMigrated
        case trimSilenceLowDefaultMigrated
        case playbackSpeed160Migrated
        case autoArchiveSettingsMigrated
        case iCloudSyncEnabled
        case recapWeeklyEnabled
        case recapMonthlyEnabled
        case recapYearlyEnabled
        case hasCompletedWelcome
        case hasSubscribedFirstShow
        case hasPlayedFirstEpisode
        case hasSeenDownloadFirstNote
        case dismissedGettingStarted
        case launchScreen
        case defaultPlaybackPreference
        case defaultAutoArchiveSettings
    }

    init(
        podcastPollMinutes: Int,
        downloadOverWifi: Bool,
        downloadOverCellular: Bool,
        notifyNewEpisodes: Bool,
        skipBackSeconds: TimeInterval,
        skipForwardSeconds: TimeInterval,
        keepScreenAwakeDuringPlayback: Bool,
        lockScreenScrubbingEnabled: Bool,
        diagnosticLoggingEnabled: Bool,
        verboseDiagnosticLoggingEnabled: Bool,
        showQueueBadge: Bool,
        sharedListeningActive: Bool,
        sharedListeningSpeed: Double,
        sleepScheduleEnabled: Bool,
        sleepScheduleStartMinutes: Int,
        sleepScheduleEndMinutes: Int,
        sleepScheduleDurationMinutes: Int,
        lastAutoArchiveRunAt: Date?,
        autoArchiveDefaultMigrated: Bool,
        vocalBoostLevelMigrated: Bool,
        trimSilenceLowDefaultMigrated: Bool,
        playbackSpeed160Migrated: Bool,
        autoArchiveSettingsMigrated: Bool,
        iCloudSyncEnabled: Bool,
        recapWeeklyEnabled: Bool,
        recapMonthlyEnabled: Bool,
        recapYearlyEnabled: Bool,
        hasCompletedWelcome: Bool,
        hasSubscribedFirstShow: Bool,
        hasPlayedFirstEpisode: Bool,
        hasSeenDownloadFirstNote: Bool,
        dismissedGettingStarted: Bool,
        launchScreen: LaunchScreen,
        defaultPlaybackPreference: PlaybackPreference,
        defaultAutoArchiveSettings: AutoArchiveSettings
    ) {
        self.podcastPollMinutes = podcastPollMinutes
        self.downloadOverWifi = downloadOverWifi
        self.downloadOverCellular = downloadOverCellular
        self.notifyNewEpisodes = notifyNewEpisodes
        self.skipBackSeconds = skipBackSeconds
        self.skipForwardSeconds = skipForwardSeconds
        self.keepScreenAwakeDuringPlayback = keepScreenAwakeDuringPlayback
        self.lockScreenScrubbingEnabled = lockScreenScrubbingEnabled
        self.diagnosticLoggingEnabled = diagnosticLoggingEnabled
        self.verboseDiagnosticLoggingEnabled = verboseDiagnosticLoggingEnabled
        self.showQueueBadge = showQueueBadge
        self.sharedListeningActive = sharedListeningActive
        self.sharedListeningSpeed = sharedListeningSpeed
        self.sleepScheduleEnabled = sleepScheduleEnabled
        self.sleepScheduleStartMinutes = sleepScheduleStartMinutes
        self.sleepScheduleEndMinutes = sleepScheduleEndMinutes
        self.sleepScheduleDurationMinutes = sleepScheduleDurationMinutes
        self.lastAutoArchiveRunAt = lastAutoArchiveRunAt
        self.autoArchiveDefaultMigrated = autoArchiveDefaultMigrated
        self.vocalBoostLevelMigrated = vocalBoostLevelMigrated
        self.trimSilenceLowDefaultMigrated = trimSilenceLowDefaultMigrated
        self.playbackSpeed160Migrated = playbackSpeed160Migrated
        self.autoArchiveSettingsMigrated = autoArchiveSettingsMigrated
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.recapWeeklyEnabled = recapWeeklyEnabled
        self.recapMonthlyEnabled = recapMonthlyEnabled
        self.recapYearlyEnabled = recapYearlyEnabled
        self.hasCompletedWelcome = hasCompletedWelcome
        self.hasSubscribedFirstShow = hasSubscribedFirstShow
        self.hasPlayedFirstEpisode = hasPlayedFirstEpisode
        self.hasSeenDownloadFirstNote = hasSeenDownloadFirstNote
        self.dismissedGettingStarted = dismissedGettingStarted
        self.launchScreen = launchScreen
        self.defaultPlaybackPreference = defaultPlaybackPreference
        self.defaultAutoArchiveSettings = defaultAutoArchiveSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        podcastPollMinutes = try container.decodeIfPresent(Int.self, forKey: .podcastPollMinutes) ?? Self.default.podcastPollMinutes
        downloadOverWifi = try container.decodeIfPresent(Bool.self, forKey: .downloadOverWifi) ?? Self.default.downloadOverWifi
        downloadOverCellular = try container.decodeIfPresent(Bool.self, forKey: .downloadOverCellular) ?? Self.default.downloadOverCellular
        // Missing keys identify an older persisted settings payload, not a new
        // install. Keep the historical false values so changing Version 1.5's
        // factory defaults cannot alter an existing user's choices.
        notifyNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .notifyNewEpisodes) ?? false
        skipBackSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .skipBackSeconds) ?? Self.default.skipBackSeconds
        skipForwardSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .skipForwardSeconds) ?? Self.default.skipForwardSeconds
        keepScreenAwakeDuringPlayback = try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwakeDuringPlayback) ?? Self.default.keepScreenAwakeDuringPlayback
        lockScreenScrubbingEnabled = try container.decodeIfPresent(Bool.self, forKey: .lockScreenScrubbingEnabled) ?? Self.default.lockScreenScrubbingEnabled
        diagnosticLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .diagnosticLoggingEnabled) ?? Self.default.diagnosticLoggingEnabled
        verboseDiagnosticLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .verboseDiagnosticLoggingEnabled) ?? Self.default.verboseDiagnosticLoggingEnabled
        showQueueBadge = try container.decodeIfPresent(Bool.self, forKey: .showQueueBadge) ?? Self.default.showQueueBadge
        sharedListeningActive = try container.decodeIfPresent(Bool.self, forKey: .sharedListeningActive) ?? Self.default.sharedListeningActive
        sharedListeningSpeed = try container.decodeIfPresent(Double.self, forKey: .sharedListeningSpeed) ?? Self.default.sharedListeningSpeed
        sleepScheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .sleepScheduleEnabled) ?? Self.default.sleepScheduleEnabled
        sleepScheduleStartMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepScheduleStartMinutes) ?? Self.default.sleepScheduleStartMinutes
        sleepScheduleEndMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepScheduleEndMinutes) ?? Self.default.sleepScheduleEndMinutes
        sleepScheduleDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepScheduleDurationMinutes) ?? Self.default.sleepScheduleDurationMinutes
        lastAutoArchiveRunAt = try container.decodeIfPresent(Date.self, forKey: .lastAutoArchiveRunAt)
        autoArchiveDefaultMigrated = try container.decodeIfPresent(Bool.self, forKey: .autoArchiveDefaultMigrated) ?? Self.default.autoArchiveDefaultMigrated
        vocalBoostLevelMigrated = try container.decodeIfPresent(Bool.self, forKey: .vocalBoostLevelMigrated) ?? Self.default.vocalBoostLevelMigrated
        trimSilenceLowDefaultMigrated = try container.decodeIfPresent(Bool.self, forKey: .trimSilenceLowDefaultMigrated) ?? Self.default.trimSilenceLowDefaultMigrated
        playbackSpeed160Migrated = try container.decodeIfPresent(Bool.self, forKey: .playbackSpeed160Migrated) ?? Self.default.playbackSpeed160Migrated
        autoArchiveSettingsMigrated = try container.decodeIfPresent(Bool.self, forKey: .autoArchiveSettingsMigrated) ?? Self.default.autoArchiveSettingsMigrated
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
        recapWeeklyEnabled = try container.decodeIfPresent(Bool.self, forKey: .recapWeeklyEnabled) ?? false
        recapMonthlyEnabled = try container.decodeIfPresent(Bool.self, forKey: .recapMonthlyEnabled) ?? Self.default.recapMonthlyEnabled
        recapYearlyEnabled = try container.decodeIfPresent(Bool.self, forKey: .recapYearlyEnabled) ?? Self.default.recapYearlyEnabled
        hasCompletedWelcome = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedWelcome) ?? Self.default.hasCompletedWelcome
        hasSubscribedFirstShow = try container.decodeIfPresent(Bool.self, forKey: .hasSubscribedFirstShow) ?? Self.default.hasSubscribedFirstShow
        hasPlayedFirstEpisode = try container.decodeIfPresent(Bool.self, forKey: .hasPlayedFirstEpisode) ?? Self.default.hasPlayedFirstEpisode
        hasSeenDownloadFirstNote = try container.decodeIfPresent(Bool.self, forKey: .hasSeenDownloadFirstNote) ?? Self.default.hasSeenDownloadFirstNote
        dismissedGettingStarted = try container.decodeIfPresent(Bool.self, forKey: .dismissedGettingStarted) ?? Self.default.dismissedGettingStarted
        launchScreen = try container.decodeIfPresent(LaunchScreen.self, forKey: .launchScreen) ?? Self.default.launchScreen
        // A missing key means this is an older *existing* settings payload, not
        // a fresh install. Preserve the historical Off fallback instead of
        // silently opting that user into the new factory preference.
        defaultPlaybackPreference = try container.decodeIfPresent(
            PlaybackPreference.self,
            forKey: .defaultPlaybackPreference
        ) ?? PlaybackPreference.default
        defaultAutoArchiveSettings = try container.decodeIfPresent(AutoArchiveSettings.self, forKey: .defaultAutoArchiveSettings) ?? Self.default.defaultAutoArchiveSettings
    }
}
