import Foundation
import GRDB

// AI CONTEXT — Persistence/AutohopDatabase.swift
// GRDB (SQLite) backing store introduced as build-step 1 of the cross-device
// sync work (see SYNC_DESIGN.md). Replaces the single subscriptions.json blob
// with one row per subscription and one row per episode, written incrementally
// inside a single transaction. This is a like-for-like backend swap:
// SubscriptionStore keeps its identical @Published [Subscription] facade and
// public API; only persistence moved here.
//
// WRITE PATH (`persist(current:previous:)` → `write(_:previous:into:)`): diffs
// against the prior snapshot so only genuinely-changed rows touch disk
// (ASSESSMENT.md P1, resolved 2026-06-18). Per subscription: the subscription row
// + its sync projection are rewritten only when a NON-episode field changed (the
// episode-stripped value differs); episodes are diffed by `id` — a value-changed
// episode re-encodes its payload + re-projects sync state, an episode that merely
// moved gets a cheap `orderIndex`-only UPDATE (no re-encode, no re-projection),
// added episodes insert, removed episodes delete. This replaced an older
// delete-all-then-reinsert path whose per-episode sync round-trip amplified writes
// on every episode state change. `_testEpisodeRowPayloadWrites` is the test seam
// that counts payload encodes so the diff can be asserted. `replaceAll` (one-time
// JSON import) passes `previous: nil` so every episode is treated as new.
//
// Also hosts the field-level sync-state projections (steps 2-4): per-episode and
// per-subscription rows with a JSON payload + indexed `hasPendingChanges` + a
// cached CKRecord `systemFields` blob, maintained centrally from `persist`.

/// SQLite-backed persistence for subscriptions, episodes, and their sync state.
/// Thread-safe: GRDB's `DatabaseQueue` serialises all access; the JSON
/// encoder/decoder are only touched inside those serialised closures, so the
/// type is safe to share across threads.
final class AutohopDatabase: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Test seam: when set, the next `persist(current:previous:)` throws instead of
    /// writing, simulating a disk-full / locked-database failure so tests can verify
    /// the store does not advance its persisted snapshot past an unwritten change.
    var _testFailNextPersist = false

    /// Test seam: counts how many episode-row payloads were encoded + written
    /// (inserts + value-changed updates), so tests can prove the episode-level
    /// diff only touches changed rows (P1). `orderIndex`-only updates and deletes
    /// are deliberately not counted — they don't re-encode a payload.
    var _testEpisodeRowPayloadWrites = 0

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory database for tests.
    init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_subscriptions_and_episodes") { db in
            try db.create(table: "subscription") { t in
                t.column("id", .text).primaryKey()
                t.column("feedURL", .text).notNull().unique()
                t.column("priorityRank", .integer).notNull().defaults(to: 0)
                t.column("browseDate", .double)
                t.column("excludeFromAutoFeedRefresh", .boolean).notNull().defaults(to: false)
                t.column("latestEpisodeID", .text)
                t.column("payload", .blob).notNull()
            }

            try db.create(table: "episode") { t in
                t.column("id", .text).primaryKey()
                t.column("subscriptionID", .text)
                    .notNull()
                    .indexed()
                    .references("subscription", onDelete: .cascade)
                t.column("guid", .text).notNull().indexed()
                t.column("orderIndex", .integer).notNull().defaults(to: 0)
                t.column("payload", .blob).notNull()
            }
        }

        // Build step 2: field-level sync-state projections (see SyncState.swift).
        // Stored independently of the domain tables (NOT cascade-deleted) so an
        // unsubscribe can leave a `subscribed = false` tombstone to push.
        // `hasPendingChanges` is indexed so "what needs syncing" is a cheap query.
        migrator.registerMigration("v2_sync_state") { db in
            try db.create(table: "subscription_sync_state") { t in
                t.column("subscriptionID", .text).primaryKey()
                t.column("payload", .blob).notNull()
                t.column("hasPendingChanges", .boolean).notNull().defaults(to: false).indexed()
            }
            try db.create(table: "episode_sync_state") { t in
                t.column("guid", .text).primaryKey()
                t.column("subscriptionID", .text).notNull().indexed()
                t.column("payload", .blob).notNull()
                t.column("hasPendingChanges", .boolean).notNull().defaults(to: false).indexed()
            }
        }

        // Build step 3b: cache the last-known CKRecord system fields per episode
        // so CKSyncEngine can save updates with the correct change tag (avoiding
        // perpetual serverRecordChanged conflicts).
        migrator.registerMigration("v3_cloudkit_system_fields") { db in
            try db.alter(table: "episode_sync_state") { t in
                t.add(column: "systemFields", .blob)
            }
        }

        // Build step 4: same CKRecord system-field cache for subscription records.
        migrator.registerMigration("v4_subscription_system_fields") { db in
            try db.alter(table: "subscription_sync_state") { t in
                t.add(column: "systemFields", .blob)
            }
        }

        // Build step 5a: listening-history sync. Record-level LWW by
        // `lastListenedAt` — the whole entry (denormalized title/artwork) is the
        // payload, so no per-field projection is needed.
        migrator.registerMigration("v5_history_sync_state") { db in
            try db.create(table: "history_sync_state") { t in
                t.column("id", .text).primaryKey()
                t.column("payload", .blob).notNull()
                t.column("lastListenedAt", .double).notNull().defaults(to: 0)
                t.column("hasPendingChanges", .boolean).notNull().defaults(to: false).indexed()
                t.column("systemFields", .blob)
            }
        }

        // Build step 5b: stats sync. ADDITIVE, not LWW — each device owns its own
        // (deviceID, dayKey) partition. `stats_sync_state` holds THIS device's
        // day buckets pending push; `remote_stats` holds OTHER devices' partitions
        // so the Stats page can sum across devices on read.
        migrator.registerMigration("v6_stats_sync") { db in
            try db.create(table: "stats_sync_state") { t in
                t.column("dayKey", .text).primaryKey()
                t.column("payload", .blob).notNull()
                t.column("hasPendingChanges", .boolean).notNull().defaults(to: false).indexed()
                t.column("systemFields", .blob)
            }
            try db.create(table: "remote_stats") { t in
                t.column("id", .text).primaryKey() // "deviceID:dayKey"
                t.column("dayKey", .text).notNull().indexed()
                t.column("payload", .blob).notNull()
            }
        }

        return migrator
    }

    // MARK: - Row types

    private struct SubscriptionRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "subscription"
        var id: String
        var feedURL: String
        var priorityRank: Int
        var browseDate: Date?
        var excludeFromAutoFeedRefresh: Bool
        var latestEpisodeID: String?
        var payload: Data
    }

    private struct EpisodeRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "episode"
        var id: String
        var subscriptionID: String
        var guid: String
        var orderIndex: Int
        var payload: Data
    }

    private struct SubscriptionSyncRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "subscription_sync_state"
        var subscriptionID: String
        var payload: Data
        var hasPendingChanges: Bool
        var systemFields: Data?
    }

    private struct EpisodeSyncRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "episode_sync_state"
        var guid: String
        var subscriptionID: String
        var payload: Data
        var hasPendingChanges: Bool
        var systemFields: Data?
    }

    private struct HistorySyncRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "history_sync_state"
        var id: String
        var payload: Data
        var lastListenedAt: Double
        var hasPendingChanges: Bool
        var systemFields: Data?
    }

    private struct StatsSyncRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "stats_sync_state"
        var dayKey: String
        var payload: Data
        var hasPendingChanges: Bool
        var systemFields: Data?
    }

    private struct RemoteStatsRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "remote_stats"
        var id: String
        var dayKey: String
        var payload: Data
    }

    // MARK: - Loading

    /// Reconstructs every subscription (with its episodes and latestEpisode)
    /// from the row tables. Ordering of subscriptions is left to the caller —
    /// SubscriptionStore re-normalises priority on load exactly as before.
    func loadSubscriptions() throws -> [Subscription] {
        try dbQueue.read { db in
            let subRows = try SubscriptionRow
                .order(Column("priorityRank"))
                .fetchAll(db)

            return try subRows.map { row in
                var subscription = try decoder.decode(Subscription.self, from: row.payload)

                let episodeRows = try EpisodeRow
                    .filter(Column("subscriptionID") == row.id)
                    .order(Column("orderIndex"))
                    .fetchAll(db)
                let episodes = try episodeRows.map { try decoder.decode(Episode.self, from: $0.payload) }

                subscription.episodes = episodes
                if let latestID = row.latestEpisodeID {
                    subscription.latestEpisode = episodes.first { $0.id.uuidString == latestID } ?? episodes.first
                } else {
                    subscription.latestEpisode = nil
                }
                return subscription
            }
        }
    }

    var isEmpty: Bool {
        (try? dbQueue.read { db in try SubscriptionRow.fetchCount(db) == 0 }) ?? true
    }

    // MARK: - Incremental persist

    /// Writes only what changed between `previous` and `current` inside a single
    /// transaction: removed subscriptions are deleted (cascading to episodes),
    /// and a subscription whose value differs is fully rewritten (row + episode
    /// rows). Unchanged subscriptions touch no disk.
    func persist(current: [Subscription], previous: [UUID: Subscription]) throws {
        if _testFailNextPersist {
            _testFailNextPersist = false
            throw _TestPersistError.injectedFailure
        }
        try dbQueue.write { db in
            let currentIDs = Set(current.map(\.id))

            for removedID in previous.keys where !currentIDs.contains(removedID) {
                try SubscriptionRow.deleteOne(db, key: removedID.uuidString)
                // Leave a tombstone so other devices learn about the unsubscribe.
                try tombstoneSubscriptionSyncState(removedID, into: db)
            }

            for subscription in current {
                let prior = previous[subscription.id]
                if let prior, prior == subscription { continue }
                try write(subscription, previous: prior, into: db)
            }
        }
    }

    /// Bulk replace — used by the one-time JSON import.
    func replaceAll(with subscriptions: [Subscription]) throws {
        try dbQueue.write { db in
            try EpisodeRow.deleteAll(db)
            try SubscriptionRow.deleteAll(db)
            for subscription in subscriptions {
                try write(subscription, previous: nil, into: db)
            }
        }
    }

    /// Proactively repairs sync-state rows left by an older projection shape so
    /// the first launch after an upgrade heals cleanly (rather than waiting for
    /// each subscription to be edited). For every loaded subscription whose
    /// projection row is missing or undecodable, a fresh (fully-dirty) projection
    /// is re-seeded so it pushes; undecodable episode rows are likewise repaired.
    /// A no-op once everything decodes.
    func reseedUndecodableSyncState(for subscriptions: [Subscription]) throws {
        try dbQueue.write { db in
            for subscription in subscriptions {
                let subRow = try SubscriptionSyncRow.fetchOne(db, key: subscription.id.uuidString)
                let subDecodes = subRow.flatMap { try? decoder.decode(SubscriptionSyncState.self, from: $0.payload) } != nil
                if !subDecodes {
                    try save(subscriptionState: SubscriptionSyncState(subscription: subscription, subscribed: true), into: db)
                }

                for episode in subscription.episodes {
                    guard let epRow = try EpisodeSyncRow.fetchOne(db, key: episode.guid) else { continue }
                    let epDecodes = (try? decoder.decode(EpisodeSyncState.self, from: epRow.payload)) != nil
                    guard !epDecodes else { continue }
                    if EpisodeSyncState.isPristine(episode) {
                        try EpisodeSyncRow.deleteOne(db, key: episode.guid)
                    } else {
                        try save(episodeState: EpisodeSyncState(episode: episode, subscriptionID: subscription.id), into: db)
                    }
                }
            }
        }
    }

    // MARK: - Private write helpers

    /// Writes a subscription incrementally, diffing against `previous` (the
    /// last-persisted snapshot of the same subscription, or `nil` for a first
    /// sighting / bulk import). Only rows that actually changed touch disk:
    ///
    /// - the subscription row + its sync projection are rewritten only when a
    ///   non-episode field changed (persist() also calls us when *only* an
    ///   episode changed, in which case the stripped subscription is identical);
    /// - an episode row is re-encoded + re-projected only when its value changed;
    ///   an episode that merely moved gets a cheap `orderIndex`-only update;
    ///   added episodes are inserted; removed episodes are deleted.
    ///
    /// This replaces the old delete-all-then-reinsert path, whose per-episode
    /// sync-state round-trip caused write amplification on every episode state
    /// change (download complete / played / archived / duration learned).
    private func write(_ subscription: Subscription, previous: Subscription?, into db: Database) throws {
        var stripped = subscription
        stripped.episodes = []
        stripped.latestEpisode = nil

        var priorStripped = previous
        priorStripped?.episodes = []
        priorStripped?.latestEpisode = nil

        // Only rewrite the subscription row + re-project its sync state when a
        // non-episode field actually changed.
        if priorStripped != stripped {
            let subRow = SubscriptionRow(
                id: subscription.id.uuidString,
                feedURL: subscription.feedURL.absoluteString,
                priorityRank: subscription.priorityRank,
                browseDate: subscription.browseDate,
                excludeFromAutoFeedRefresh: subscription.excludeFromAutoFeedRefresh,
                latestEpisodeID: subscription.latestEpisode?.id.uuidString,
                payload: try encoder.encode(stripped)
            )
            try subRow.save(db)
            try recordSubscriptionSyncState(subscription, into: db)
        }

        // Index the previous episodes by id, remembering their position so a pure
        // reorder (e.g. a feed refresh prepending new episodes) only rewrites the
        // cheap orderIndex column rather than re-encoding every payload.
        let priorEpisodes = previous?.episodes ?? []
        var priorByID = [String: Episode](minimumCapacity: priorEpisodes.count)
        var priorIndexByID = [String: Int](minimumCapacity: priorEpisodes.count)
        for (index, episode) in priorEpisodes.enumerated() {
            let key = episode.id.uuidString
            priorByID[key] = episode
            priorIndexByID[key] = index
        }

        var currentIDs = Set<String>(minimumCapacity: subscription.episodes.count)
        for (index, episode) in subscription.episodes.enumerated() {
            let key = episode.id.uuidString
            currentIDs.insert(key)

            if let prior = priorByID[key] {
                if prior != episode {
                    // Value changed → rewrite the row and re-project sync state.
                    try writeEpisodeRow(episode, subscriptionID: subscription.id, orderIndex: index, into: db)
                    try recordEpisodeSyncState(episode, subscriptionID: subscription.id, into: db)
                } else if priorIndexByID[key] != index {
                    // Only the position changed → cheap orderIndex update, no
                    // re-encode and no sync re-projection (no field changed).
                    try db.execute(
                        sql: "UPDATE episode SET orderIndex = ? WHERE id = ?",
                        arguments: [index, key]
                    )
                }
                // Identical value + position → nothing to write.
            } else {
                // New episode.
                try writeEpisodeRow(episode, subscriptionID: subscription.id, orderIndex: index, into: db)
                try recordEpisodeSyncState(episode, subscriptionID: subscription.id, into: db)
            }
        }

        // Delete rows for episodes that are no longer present.
        for key in priorByID.keys where !currentIDs.contains(key) {
            try EpisodeRow.deleteOne(db, key: key)
        }
    }

    private func writeEpisodeRow(_ episode: Episode, subscriptionID: UUID, orderIndex: Int, into db: Database) throws {
        let episodeRow = EpisodeRow(
            id: episode.id.uuidString,
            subscriptionID: subscriptionID.uuidString,
            guid: episode.guid,
            orderIndex: orderIndex,
            payload: try encoder.encode(episode)
        )
        try episodeRow.save(db)
        _testEpisodeRowPayloadWrites += 1
    }

    // MARK: - Sync-state recording (build step 2)

    /// Updates the subscription's sync projection, stamping only the fields that
    /// changed. A first sighting seeds a fully-dirty projection (a new local
    /// subscription must be pushed in full).
    private func recordSubscriptionSyncState(_ subscription: Subscription, into db: Database) throws {
        var state: SubscriptionSyncState
        // Use try? so a stale/incompatible payload (e.g. an older projection
        // shape) re-seeds a fresh projection instead of throwing — a decode
        // failure here must NEVER roll back the whole persist transaction.
        if let row = try SubscriptionSyncRow.fetchOne(db, key: subscription.id.uuidString),
           let decoded = try? decoder.decode(SubscriptionSyncState.self, from: row.payload) {
            state = decoded
            state.apply(subscription, subscribed: true)
        } else {
            state = SubscriptionSyncState(subscription: subscription, subscribed: true)
        }
        try save(subscriptionState: state, into: db)
    }

    /// Updates an episode's sync projection. Pristine, never-tracked episodes are
    /// skipped so the dirty set stays limited to episodes the user actually
    /// touched (played/archived) — matching Pocket Casts' modified-flag semantics.
    private func recordEpisodeSyncState(_ episode: Episode, subscriptionID: UUID, into db: Database) throws {
        // try? on the decode so a stale payload re-seeds rather than throwing
        // and rolling back the whole persist transaction.
        if let row = try EpisodeSyncRow.fetchOne(db, key: episode.guid),
           var state = try? decoder.decode(EpisodeSyncState.self, from: row.payload) {
            state.apply(episode)
            try save(episodeState: state, into: db)
        } else if !EpisodeSyncState.isPristine(episode) {
            let state = EpisodeSyncState(episode: episode, subscriptionID: subscriptionID)
            try save(episodeState: state, into: db)
        }
        // pristine + untracked → nothing to record yet.
    }

    private func tombstoneSubscriptionSyncState(_ id: UUID, into db: Database) throws {
        guard let row = try SubscriptionSyncRow.fetchOne(db, key: id.uuidString),
              var state = try? decoder.decode(SubscriptionSyncState.self, from: row.payload)
        else { return } // no row, or an incompatible payload — nothing to tombstone
        state.subscribed = false // stamps the field dirty
        try save(subscriptionState: state, into: db)
    }

    private func save(subscriptionState state: SubscriptionSyncState, into db: Database) throws {
        let existingSystemFields = try SubscriptionSyncRow.fetchOne(db, key: state.subscriptionID.uuidString)?.systemFields
        let row = SubscriptionSyncRow(
            subscriptionID: state.subscriptionID.uuidString,
            payload: try encoder.encode(state),
            hasPendingChanges: state.hasPendingChanges,
            systemFields: existingSystemFields
        )
        try row.save(db)
    }

    private func save(episodeState state: EpisodeSyncState, into db: Database) throws {
        // Preserve any cached CKRecord system fields across re-saves.
        let existingSystemFields = try EpisodeSyncRow.fetchOne(db, key: state.guid)?.systemFields
        let row = EpisodeSyncRow(
            guid: state.guid,
            subscriptionID: state.subscriptionID.uuidString,
            payload: try encoder.encode(state),
            hasPendingChanges: state.hasPendingChanges,
            systemFields: existingSystemFields
        )
        try row.save(db)
    }

    // MARK: - Sync-state queries (consumed by the CloudKit step)

    /// Episode projections with unsynced local changes. A row that can't decode
    /// (stale shape) is skipped rather than failing the whole query.
    func pendingEpisodeSyncStates() throws -> [EpisodeSyncState] {
        try dbQueue.read { db in
            try EpisodeSyncRow
                .filter(Column("hasPendingChanges") == true)
                .fetchAll(db)
                .compactMap { try? decoder.decode(EpisodeSyncState.self, from: $0.payload) }
        }
    }

    /// Subscription projections with unsynced local changes. Undecodable rows skipped.
    func pendingSubscriptionSyncStates() throws -> [SubscriptionSyncState] {
        try dbQueue.read { db in
            try SubscriptionSyncRow
                .filter(Column("hasPendingChanges") == true)
                .fetchAll(db)
                .compactMap { try? decoder.decode(SubscriptionSyncState.self, from: $0.payload) }
        }
    }

    /// Clears the dirty stamps on the given projections after a successful push.
    func markSynced(episodeGuids: [String], subscriptionIDs: [UUID], historyIDs: [String] = [], statsDayKeys: [String] = []) throws {
        try dbQueue.write { db in
            for guid in episodeGuids {
                guard let row = try EpisodeSyncRow.fetchOne(db, key: guid),
                      var state = try? decoder.decode(EpisodeSyncState.self, from: row.payload) else { continue }
                state.markClean()
                try save(episodeState: state, into: db)
            }
            for id in subscriptionIDs {
                guard let row = try SubscriptionSyncRow.fetchOne(db, key: id.uuidString),
                      var state = try? decoder.decode(SubscriptionSyncState.self, from: row.payload) else { continue }
                state.markClean()
                try save(subscriptionState: state, into: db)
            }
            for id in historyIDs {
                guard var row = try HistorySyncRow.fetchOne(db, key: id) else { continue }
                row.hasPendingChanges = false
                try row.save(db)
            }
            for dayKey in statsDayKeys {
                guard var row = try StatsSyncRow.fetchOne(db, key: dayKey) else { continue }
                row.hasPendingChanges = false
                try row.save(db)
            }
        }
    }

    /// Single episode projection by guid.
    func episodeSyncState(guid: String) throws -> EpisodeSyncState? {
        try dbQueue.read { db in
            guard let row = try EpisodeSyncRow.fetchOne(db, key: guid) else { return nil }
            return try decoder.decode(EpisodeSyncState.self, from: row.payload)
        }
    }

    /// Upsert a projection directly (used when applying a merged remote change).
    func saveEpisodeSyncState(_ state: EpisodeSyncState) throws {
        try dbQueue.write { db in try save(episodeState: state, into: db) }
    }

    /// Cached CKRecord system fields for an episode, if we've seen its server record.
    func episodeSystemFields(guid: String) throws -> Data? {
        try dbQueue.read { db in
            try EpisodeSyncRow.fetchOne(db, key: guid)?.systemFields
        }
    }

    /// Store CKRecord system fields for an episode (no-op if the projection row
    /// doesn't exist yet).
    func storeEpisodeSystemFields(_ data: Data?, guid: String) throws {
        try dbQueue.write { db in
            guard var row = try EpisodeSyncRow.fetchOne(db, key: guid) else { return }
            row.systemFields = data
            try row.save(db)
        }
    }

    // MARK: Subscription sync-state accessors

    func subscriptionSyncState(id: UUID) throws -> SubscriptionSyncState? {
        try dbQueue.read { db in
            guard let row = try SubscriptionSyncRow.fetchOne(db, key: id.uuidString) else { return nil }
            return try decoder.decode(SubscriptionSyncState.self, from: row.payload)
        }
    }

    func saveSubscriptionSyncState(_ state: SubscriptionSyncState) throws {
        try dbQueue.write { db in try save(subscriptionState: state, into: db) }
    }

    func subscriptionSystemFields(id: UUID) throws -> Data? {
        try dbQueue.read { db in
            try SubscriptionSyncRow.fetchOne(db, key: id.uuidString)?.systemFields
        }
    }

    func storeSubscriptionSystemFields(_ data: Data?, id: UUID) throws {
        try dbQueue.write { db in
            guard var row = try SubscriptionSyncRow.fetchOne(db, key: id.uuidString) else { return }
            row.systemFields = data
            try row.save(db)
        }
    }

    // MARK: Listening-history sync-state accessors (build step 5a)

    /// Records a locally-changed history entry as pending (preserving any cached
    /// system fields). Called from ListeningHistoryStore on every mutation.
    func recordHistoryEntry(_ entry: ListeningHistoryEntry) throws {
        try dbQueue.write { db in
            let existing = try HistorySyncRow.fetchOne(db, key: entry.id)?.systemFields
            let row = HistorySyncRow(
                id: entry.id,
                payload: try encoder.encode(entry),
                lastListenedAt: entry.lastListenedAt.timeIntervalSince1970,
                hasPendingChanges: true,
                systemFields: existing
            )
            try row.save(db)
        }
    }

    /// Upserts a history entry already reconciled with the server (clean — not re-pushed).
    func saveSyncedHistoryEntry(_ entry: ListeningHistoryEntry) throws {
        try dbQueue.write { db in
            let existing = try HistorySyncRow.fetchOne(db, key: entry.id)?.systemFields
            let row = HistorySyncRow(
                id: entry.id,
                payload: try encoder.encode(entry),
                lastListenedAt: entry.lastListenedAt.timeIntervalSince1970,
                hasPendingChanges: false,
                systemFields: existing
            )
            try row.save(db)
        }
    }

    func pendingHistoryEntries() throws -> [ListeningHistoryEntry] {
        try dbQueue.read { db in
            try HistorySyncRow
                .filter(Column("hasPendingChanges") == true)
                .fetchAll(db)
                .compactMap { try? decoder.decode(ListeningHistoryEntry.self, from: $0.payload) }
        }
    }

    func historyEntry(id: String) throws -> ListeningHistoryEntry? {
        try dbQueue.read { db in
            guard let row = try HistorySyncRow.fetchOne(db, key: id) else { return nil }
            return try decoder.decode(ListeningHistoryEntry.self, from: row.payload)
        }
    }

    func historySystemFields(id: String) throws -> Data? {
        try dbQueue.read { db in
            try HistorySyncRow.fetchOne(db, key: id)?.systemFields
        }
    }

    func storeHistorySystemFields(_ data: Data?, id: String) throws {
        try dbQueue.write { db in
            guard var row = try HistorySyncRow.fetchOne(db, key: id) else { return }
            row.systemFields = data
            try row.save(db)
        }
    }

    // MARK: Stats sync-state accessors (build step 5b)

    /// Records THIS device's day bucket as pending push (preserving system fields).
    /// Test seam: counts `recordStatsDay` calls so tests can assert the per-tick stats
    /// writes during playback are coalesced rather than issued ~twice a second.
    var _testStatsDayWriteCount = 0

    func recordStatsDay(_ day: DayStats) throws {
        _testStatsDayWriteCount += 1
        try dbQueue.write { db in
            let existing = try StatsSyncRow.fetchOne(db, key: day.dayKey)?.systemFields
            let row = StatsSyncRow(
                dayKey: day.dayKey,
                payload: try encoder.encode(day),
                hasPendingChanges: true,
                systemFields: existing
            )
            try row.save(db)
        }
    }

    func pendingStatsDays() throws -> [DayStats] {
        try dbQueue.read { db in
            try StatsSyncRow
                .filter(Column("hasPendingChanges") == true)
                .fetchAll(db)
                .compactMap { try? decoder.decode(DayStats.self, from: $0.payload) }
        }
    }

    func statsDay(dayKey: String) throws -> DayStats? {
        try dbQueue.read { db in
            guard let row = try StatsSyncRow.fetchOne(db, key: dayKey) else { return nil }
            return try decoder.decode(DayStats.self, from: row.payload)
        }
    }

    func statsSystemFields(dayKey: String) throws -> Data? {
        try dbQueue.read { db in
            try StatsSyncRow.fetchOne(db, key: dayKey)?.systemFields
        }
    }

    func storeStatsSystemFields(_ data: Data?, dayKey: String) throws {
        try dbQueue.write { db in
            guard var row = try StatsSyncRow.fetchOne(db, key: dayKey) else { return }
            row.systemFields = data
            try row.save(db)
        }
    }

    enum _TestPersistError: Error { case injectedFailure }

    /// Test seam: writes an undecodable subscription sync payload, simulating a
    /// row left by an older projection shape (the bug this guards against).
    func _testWriteCorruptSubscriptionSyncRow(id: UUID) throws {
        try dbQueue.write { db in
            let row = SubscriptionSyncRow(
                subscriptionID: id.uuidString,
                payload: Data("not-decodable".utf8),
                hasPendingChanges: false,
                systemFields: nil
            )
            try row.save(db)
        }
    }

    /// Upserts another device's day partition (for summing on read).
    func applyRemoteStatsPartition(deviceID: String, day: DayStats) throws {
        try dbQueue.write { db in
            let row = RemoteStatsRow(
                id: "\(deviceID):\(day.dayKey)",
                dayKey: day.dayKey,
                payload: try encoder.encode(day)
            )
            try row.save(db)
        }
    }

    /// All other-device day partitions, grouped by dayKey, for the Stats page to
    /// sum with the local buckets.
    func remoteStatsByDayKey() throws -> [String: [DayStats]] {
        try dbQueue.read { db in
            var result: [String: [DayStats]] = [:]
            for row in try RemoteStatsRow.fetchAll(db) {
                guard let day = try? decoder.decode(DayStats.self, from: row.payload) else { continue }
                result[row.dayKey, default: []].append(day)
            }
            return result
        }
    }
}
