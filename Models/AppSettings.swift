import Foundation

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
    var lastAutoArchiveRunAt: Date?
    var autoArchiveDefaultMigrated: Bool
    var vocalBoostLevelMigrated: Bool
    var trimSilenceLowDefaultMigrated: Bool
    var playbackSpeed160Migrated: Bool
    var autoArchiveSettingsMigrated: Bool

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
        showQueueBadge: true,
        lastAutoArchiveRunAt: nil,
        autoArchiveDefaultMigrated: false,
        vocalBoostLevelMigrated: false,
        trimSilenceLowDefaultMigrated: false,
        playbackSpeed160Migrated: false,
        autoArchiveSettingsMigrated: false
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
        case lastAutoArchiveRunAt
        case autoArchiveDefaultMigrated
        case vocalBoostLevelMigrated
        case trimSilenceLowDefaultMigrated
        case playbackSpeed160Migrated
        case autoArchiveSettingsMigrated
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
        lastAutoArchiveRunAt: Date?,
        autoArchiveDefaultMigrated: Bool,
        vocalBoostLevelMigrated: Bool,
        trimSilenceLowDefaultMigrated: Bool,
        playbackSpeed160Migrated: Bool,
        autoArchiveSettingsMigrated: Bool
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
        self.lastAutoArchiveRunAt = lastAutoArchiveRunAt
        self.autoArchiveDefaultMigrated = autoArchiveDefaultMigrated
        self.vocalBoostLevelMigrated = vocalBoostLevelMigrated
        self.trimSilenceLowDefaultMigrated = trimSilenceLowDefaultMigrated
        self.playbackSpeed160Migrated = playbackSpeed160Migrated
        self.autoArchiveSettingsMigrated = autoArchiveSettingsMigrated
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
        lastAutoArchiveRunAt = try container.decodeIfPresent(Date.self, forKey: .lastAutoArchiveRunAt)
        autoArchiveDefaultMigrated = try container.decodeIfPresent(Bool.self, forKey: .autoArchiveDefaultMigrated) ?? Self.default.autoArchiveDefaultMigrated
        vocalBoostLevelMigrated = try container.decodeIfPresent(Bool.self, forKey: .vocalBoostLevelMigrated) ?? Self.default.vocalBoostLevelMigrated
        trimSilenceLowDefaultMigrated = try container.decodeIfPresent(Bool.self, forKey: .trimSilenceLowDefaultMigrated) ?? Self.default.trimSilenceLowDefaultMigrated
        playbackSpeed160Migrated = try container.decodeIfPresent(Bool.self, forKey: .playbackSpeed160Migrated) ?? Self.default.playbackSpeed160Migrated
        autoArchiveSettingsMigrated = try container.decodeIfPresent(Bool.self, forKey: .autoArchiveSettingsMigrated) ?? Self.default.autoArchiveSettingsMigrated
    }
}
