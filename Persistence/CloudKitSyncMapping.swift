import Foundation
import CloudKit

// AI CONTEXT — Persistence/CloudKitSyncMapping.swift
// Two things live here: (1) `DeviceIdentity` — the stable per-device UUID used to
// partition stats records by (deviceID, dayKey); (2) `CloudKitSync` — the PURE
// mapping between sync-state projections / history / stats and CloudKit CKRecords
// (no networking, no CKSyncEngine), so it is fully unit-testable on macOS. The
// detailed schema/merge contract is documented on the `CloudKitSync` enum below.

// Stable per-device identifier for stats partitioning (SYNC_DESIGN.md step 5b).
// Generated once and persisted in UserDefaults — stats records are keyed by
// (deviceID, dayKey) so each device owns its own partition and they sum on read.
public enum DeviceIdentity {
    private static let key = "com.autohop.sync.deviceID"
    public static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}

// AI CONTEXT — Persistence/CloudKitSyncMapping.swift
// Pure mapping between the sync-state projections and CloudKit CKRecords (see
// SYNC_DESIGN.md, steps 3a/4). No networking, no CKSyncEngine — just the record
// schema and value translation, so it is fully unit-testable on macOS.
//
// Schema: one record per episode (type "EpisodeState", recordName = guid) and
// one per subscription (type "SubscriptionState", recordName = subscriptionID),
// both in a dedicated custom zone. Each syncable field is stored alongside a
// `<field>ModifiedAt` date carrying that field's authoritative server timestamp
// — the basis for the field-level last-write-wins merge.
//
// OUTBOUND RULE: populate() writes only fields with a pending local change, so
// pushing a record that changed one field never clobbers the server's value/
// stamp for the others (the outbound analogue of the inbound merge).
public enum CloudKitSync {
    public static let zoneName = "AutohopSync"
    public static let episodeRecordType = "EpisodeState"
    public static let subscriptionRecordType = "SubscriptionState"
    public static let historyRecordType = "HistoryEntry"
    public static let statsRecordType = "DayStats"

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    public static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func episodeRecordID(guid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: guid, zoneID: zoneID)
    }

    public static func subscriptionRecordID(id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    public static func historyRecordID(id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    // MARK: - Episode mapping

    private enum Key {
        static let subscriptionID = "subscriptionID"
        static let playedState = "playedState"
        static let playedStateModifiedAt = "playedStateModifiedAt"
        static let wasCompleted = "wasCompleted"
        static let wasCompletedModifiedAt = "wasCompletedModifiedAt"
        static let lastPlayedAt = "lastPlayedAt"
        static let lastPlayedAtModifiedAt = "lastPlayedAtModifiedAt"
    }

    /// Overlays the state's *dirty* fields onto an existing (or freshly created)
    /// CKRecord, preserving any field the state hasn't locally changed.
    public static func populate(_ record: CKRecord, from state: EpisodeSyncState) {
        record[Key.subscriptionID] = state.subscriptionID.uuidString

        if let modifiedAt = state.$playedState.modifiedAt {
            record[Key.playedState] = state.playedState.rawValue
            record[Key.playedStateModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$wasCompleted.modifiedAt {
            record[Key.wasCompleted] = state.wasCompleted ? 1 : 0
            record[Key.wasCompletedModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$lastPlayedAt.modifiedAt {
            // Only set the date when non-nil; the modifiedAt presence is what
            // marks the field as authored.
            record[Key.lastPlayedAt] = state.lastPlayedAt
            record[Key.lastPlayedAtModifiedAt] = modifiedAt
        }
    }

    /// Builds a fresh CKRecord for an episode state (used when no server record
    /// exists yet).
    public static func makeRecord(from state: EpisodeSyncState) -> CKRecord {
        let record = CKRecord(recordType: episodeRecordType, recordID: episodeRecordID(guid: state.guid))
        populate(record, from: state)
        return record
    }

    /// Decodes a server CKRecord into an EpisodeSyncState whose per-field
    /// `modifiedAt` carries the server's authoritative timestamps (the basis for
    /// the merge). Returns nil only if the required identity is unreadable.
    public static func episodeSyncState(from record: CKRecord, subscriptionID fallbackSubscriptionID: UUID? = nil) -> EpisodeSyncState? {
        let guid = record.recordID.recordName

        guard let subscriptionID = (record[Key.subscriptionID] as? String).flatMap(UUID.init(uuidString:))
            ?? fallbackSubscriptionID
        else { return nil }

        let playedState = (record[Key.playedState] as? String).flatMap(PlayedState.init(rawValue:)) ?? .unplayed
        let playedStateStamp = record[Key.playedStateModifiedAt] as? Date

        let wasCompleted = ((record[Key.wasCompleted] as? Int) ?? 0) != 0
        let wasCompletedStamp = record[Key.wasCompletedModifiedAt] as? Date

        let lastPlayedAt = record[Key.lastPlayedAt] as? Date
        let lastPlayedAtStamp = record[Key.lastPlayedAtModifiedAt] as? Date

        return EpisodeSyncState(
            guid: guid,
            subscriptionID: subscriptionID,
            playedState: Synced(wrappedValue: playedState, modifiedAt: playedStateStamp),
            wasCompleted: Synced(wrappedValue: wasCompleted, modifiedAt: wasCompletedStamp),
            lastPlayedAt: Synced(wrappedValue: lastPlayedAt, modifiedAt: lastPlayedAtStamp)
        )
    }

    // MARK: - Subscription mapping

    private enum SubKey {
        static let feedURL = "feedURL"
        static let subscribed = "subscribed"
        static let subscribedModifiedAt = "subscribedModifiedAt"
        static let title = "title"
        static let titleModifiedAt = "titleModifiedAt"
        static let priorityRank = "priorityRank"
        static let priorityRankModifiedAt = "priorityRankModifiedAt"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationsEnabledModifiedAt = "notificationsEnabledModifiedAt"
        static let excludeFromAutoFeedRefresh = "excludeFromAutoFeedRefresh"
        static let excludeFromAutoFeedRefreshModifiedAt = "excludeFromAutoFeedRefreshModifiedAt"
        static let playbackPreference = "playbackPreference"
        static let playbackPreferenceModifiedAt = "playbackPreferenceModifiedAt"
        static let autoArchiveSettings = "autoArchiveSettings"
        static let autoArchiveSettingsModifiedAt = "autoArchiveSettingsModifiedAt"
        static let chapterFilter = "chapterFilter"
        static let chapterFilterModifiedAt = "chapterFilterModifiedAt"
    }

    public static func makeRecord(from state: SubscriptionSyncState) -> CKRecord {
        let record = CKRecord(recordType: subscriptionRecordType, recordID: subscriptionRecordID(id: state.subscriptionID))
        populate(record, from: state)
        return record
    }

    /// Overlays only the dirty fields onto the record (preserving server values
    /// for fields unchanged locally). `feedURL` is constant and always written.
    public static func populate(_ record: CKRecord, from state: SubscriptionSyncState) {
        record[SubKey.feedURL] = state.feedURL.absoluteString

        if let modifiedAt = state.$subscribed.modifiedAt {
            record[SubKey.subscribed] = state.subscribed ? 1 : 0
            record[SubKey.subscribedModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$title.modifiedAt {
            record[SubKey.title] = state.title
            record[SubKey.titleModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$priorityRank.modifiedAt {
            record[SubKey.priorityRank] = state.priorityRank
            record[SubKey.priorityRankModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$notificationsEnabled.modifiedAt {
            record[SubKey.notificationsEnabled] = state.notificationsEnabled ? 1 : 0
            record[SubKey.notificationsEnabledModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$excludeFromAutoFeedRefresh.modifiedAt {
            record[SubKey.excludeFromAutoFeedRefresh] = state.excludeFromAutoFeedRefresh ? 1 : 0
            record[SubKey.excludeFromAutoFeedRefreshModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$playbackPreference.modifiedAt {
            record[SubKey.playbackPreference] = try? jsonEncoder.encode(state.playbackPreference)
            record[SubKey.playbackPreferenceModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$autoArchiveSettings.modifiedAt {
            record[SubKey.autoArchiveSettings] = try? jsonEncoder.encode(state.autoArchiveSettings)
            record[SubKey.autoArchiveSettingsModifiedAt] = modifiedAt
        }
        if let modifiedAt = state.$chapterFilter.modifiedAt {
            record[SubKey.chapterFilter] = try? jsonEncoder.encode(state.chapterFilter)
            record[SubKey.chapterFilterModifiedAt] = modifiedAt
        }
    }

    public static func subscriptionSyncState(from record: CKRecord) -> SubscriptionSyncState? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let feedURLString = record[SubKey.feedURL] as? String,
              let feedURL = URL(string: feedURLString)
        else { return nil }

        func decodeStruct<T: Decodable>(_ key: String, default fallback: T) -> T {
            guard let data = record[key] as? Data else { return fallback }
            return (try? jsonDecoder.decode(T.self, from: data)) ?? fallback
        }

        return SubscriptionSyncState(
            subscriptionID: id,
            feedURL: feedURL,
            subscribed: Synced(wrappedValue: ((record[SubKey.subscribed] as? Int) ?? 1) != 0,
                               modifiedAt: record[SubKey.subscribedModifiedAt] as? Date),
            title: Synced(wrappedValue: (record[SubKey.title] as? String) ?? "",
                          modifiedAt: record[SubKey.titleModifiedAt] as? Date),
            priorityRank: Synced(wrappedValue: (record[SubKey.priorityRank] as? Int) ?? 0,
                                 modifiedAt: record[SubKey.priorityRankModifiedAt] as? Date),
            notificationsEnabled: Synced(wrappedValue: ((record[SubKey.notificationsEnabled] as? Int) ?? 0) != 0,
                                         modifiedAt: record[SubKey.notificationsEnabledModifiedAt] as? Date),
            excludeFromAutoFeedRefresh: Synced(wrappedValue: ((record[SubKey.excludeFromAutoFeedRefresh] as? Int) ?? 0) != 0,
                                               modifiedAt: record[SubKey.excludeFromAutoFeedRefreshModifiedAt] as? Date),
            playbackPreference: Synced(wrappedValue: decodeStruct(SubKey.playbackPreference, default: PlaybackPreference.default),
                                       modifiedAt: record[SubKey.playbackPreferenceModifiedAt] as? Date),
            autoArchiveSettings: Synced(wrappedValue: decodeStruct(SubKey.autoArchiveSettings, default: AutoArchiveSettings.default),
                                        modifiedAt: record[SubKey.autoArchiveSettingsModifiedAt] as? Date),
            chapterFilter: Synced(wrappedValue: decodeStruct(SubKey.chapterFilter, default: ChapterFilter()),
                                  modifiedAt: record[SubKey.chapterFilterModifiedAt] as? Date)
        )
    }

    // MARK: - Listening-history mapping (record-level LWW by lastListenedAt)

    private enum HistKey {
        static let entry = "entry"
        static let lastListenedAt = "lastListenedAt"
    }

    public static func makeRecord(from entry: ListeningHistoryEntry) -> CKRecord {
        let record = CKRecord(recordType: historyRecordType, recordID: historyRecordID(id: entry.id))
        populate(record, from: entry)
        return record
    }

    /// History is merged at the record level (whole entry wins by lastListenedAt),
    /// so the full entry is always written as a JSON blob.
    public static func populate(_ record: CKRecord, from entry: ListeningHistoryEntry) {
        record[HistKey.entry] = try? jsonEncoder.encode(entry)
        record[HistKey.lastListenedAt] = entry.lastListenedAt
    }

    public static func historyEntry(from record: CKRecord) -> ListeningHistoryEntry? {
        guard let data = record[HistKey.entry] as? Data else { return nil }
        return try? jsonDecoder.decode(ListeningHistoryEntry.self, from: data)
    }

    // MARK: - Stats mapping (per-device partition; recordName = "deviceID:dayKey")

    private enum StatsKey {
        static let deviceID = "deviceID"
        static let dayKey = "dayKey"
        static let day = "day"
    }

    public static func statsRecordID(deviceID: String, dayKey: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(deviceID):\(dayKey)", zoneID: zoneID)
    }

    public static func makeRecord(deviceID: String, day: DayStats) -> CKRecord {
        let record = CKRecord(recordType: statsRecordType, recordID: statsRecordID(deviceID: deviceID, dayKey: day.dayKey))
        populate(record, deviceID: deviceID, day: day)
        return record
    }

    public static func populate(_ record: CKRecord, deviceID: String, day: DayStats) {
        record[StatsKey.deviceID] = deviceID
        record[StatsKey.dayKey] = day.dayKey
        record[StatsKey.day] = try? jsonEncoder.encode(day)
    }

    /// Decodes a server stats record. Returns the owning deviceID (so a device
    /// can skip its own records) and the day partition.
    public static func statsPartition(from record: CKRecord) -> (deviceID: String, day: DayStats)? {
        guard let deviceID = record[StatsKey.deviceID] as? String,
              let data = record[StatsKey.day] as? Data,
              let day = try? jsonDecoder.decode(DayStats.self, from: data)
        else { return nil }
        return (deviceID, day)
    }
}
