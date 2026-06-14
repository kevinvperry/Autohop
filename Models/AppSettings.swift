import Foundation

// AI CONTEXT — Models/AppSettings.swift
// Global (non-per-podcast) settings value type, persisted by SettingsStore as
// JSON. podcastPollMinutes is the Release Radar sensitivity (how often a feed
// is re-checked while a drop is imminent, default 5 min). The *Migrated flags
// are one-shot first-launch migration markers (e.g. moving existing users to
// the 1.6x speed / Strong boost / Low trim defaults) — never remove a flag
// once shipped or the migration will re-run. Defaults here must stay in sync
// with the FEATURES.md "Model Defaults Quick Reference" appendix.
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
    // Cross-device iCloud sync (CloudKit). Opt-in, OFF by default so the
    // on-device privacy stance holds until the user explicitly enables it.
    var iCloudSyncEnabled: Bool

    static let `default` = AppSettings(
        podcastPollMinutes: 5,
        downloadOverWifi: true,
        downloadOverCellular: false,
        notifyNewEpisodes: false,
        skipBackSeconds: 15,
        skipForwardSeconds: 30,
        keepScreenAwakeDuringPlayback: false,
        lockScreenScrubbingEnabled: true,
        diagnosticLoggingEnabled: false,
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
        iCloudSyncEnabled: false
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
        iCloudSyncEnabled: Bool
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        podcastPollMinutes = try container.decodeIfPresent(Int.self, forKey: .podcastPollMinutes) ?? Self.default.podcastPollMinutes
        downloadOverWifi = try container.decodeIfPresent(Bool.self, forKey: .downloadOverWifi) ?? Self.default.downloadOverWifi
        downloadOverCellular = try container.decodeIfPresent(Bool.self, forKey: .downloadOverCellular) ?? Self.default.downloadOverCellular
        notifyNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .notifyNewEpisodes) ?? Self.default.notifyNewEpisodes
        skipBackSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .skipBackSeconds) ?? Self.default.skipBackSeconds
        skipForwardSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .skipForwardSeconds) ?? Self.default.skipForwardSeconds
        keepScreenAwakeDuringPlayback = try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwakeDuringPlayback) ?? Self.default.keepScreenAwakeDuringPlayback
        lockScreenScrubbingEnabled = try container.decodeIfPresent(Bool.self, forKey: .lockScreenScrubbingEnabled) ?? Self.default.lockScreenScrubbingEnabled
        diagnosticLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .diagnosticLoggingEnabled) ?? Self.default.diagnosticLoggingEnabled
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
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? Self.default.iCloudSyncEnabled
    }
}
