import Foundation
import CloudKit
import Combine

// AI CONTEXT — Persistence/CloudSyncEngine.swift
// CKSyncEngine wrapper for cross-device sync (SYNC_DESIGN.md, steps 3b/4).
// OPT-IN: only runs while AppSettings.iCloudSyncEnabled is true (AppState drives
// start/stop). Syncs episode user-state AND subscription settings.
//
// Push: observes SubscriptionStore changes (debounced), scans the database for
// pending Episode/Subscription sync-states (dirty fields), and queues saves.
// Records are built by CloudKitSync, starting from cached CKRecord system fields
// so updates carry the right change tag.
// Pull: fetched server records are decoded and merged into the local store via
// SubscriptionStore.applyRemote*; a remote subscription for a podcast not present
// here triggers `onSubscriptionNeedsMaterialization` (AppState fetches the feed).
//
// Cannot be exercised by `swift test` (CKSyncEngine needs a container,
// entitlements, and a signed-in account) — verified by building and running on a
// real device (Simulator can't trigger CloudKit sync). The pure mapping/merge it
// relies on is unit-tested.
//
// Observability: every stage logs through AppLogger with `sync.*` event keys
// (lifecycle, queued/pushed/fetched batch counts, conflicts, materialisation,
// account changes). Local-DB writes that were once `try?`-swallowed now go
// through runDB() and log failures. ERROR-level sync events use
// alwaysPersist:true so they survive even when the Diagnostics toggle is off —
// since this is a since-launch backup feature, a user reporting "my data didn't
// sync" must leave a trace. Verbosity is "balanced": batch summaries, not one
// line per record.
final class CloudSyncEngine: NSObject, CKSyncEngineDelegate {
    private let container: CKContainer
    private let subscriptionStore: SubscriptionStore
    private let database: AutohopDatabase?
    private let stateURL: URL?
    private let logger = AppLogger.shared

    private var engine: CKSyncEngine?
    private var isStarting = false
    private var cancellables = Set<AnyCancellable>()

    /// Invoked when a remote subscription record arrives for a podcast not on
    /// this device — the app layer fetches the feed and creates it, then
    /// re-applies the state. Set by AppState (which owns FeedService).
    var onSubscriptionNeedsMaterialization: ((SubscriptionSyncState) async -> Void)?

    /// Invoked when a remote listening-history entry arrives — the app layer
    /// (ListeningHistoryStore) merges it with record-level LWW. Set by AppState.
    var onRemoteHistoryEntry: ((ListeningHistoryEntry) async -> Void)?

    /// Invoked after another device's stats partition was stored — the app layer
    /// (ListeningStatsStore) reloads its remote cache and refreshes. Set by AppState.
    var onRemoteStatsChanged: (() async -> Void)?

    /// Lifecycle is driven by the caller (AppState start/stop based on the
    /// opt-in setting), so the engine doesn't read the settings store itself.
    /// - Parameter database: the store's record database, passed explicitly so
    ///   the engine can read it off the main actor (it's thread-safe).
    init(
        containerIdentifier: String,
        subscriptionStore: SubscriptionStore,
        database: AutohopDatabase?
    ) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.subscriptionStore = subscriptionStore
        self.database = database
        self.stateURL = Self.defaultStateURL()
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard engine == nil, !isStarting else {
            logger.info("sync.startSkipped", "Sync start ignored — engine already running or starting")
            return
        }
        isStarting = true
        // Only spin up the engine when there's a usable iCloud account —
        // otherwise CKSyncEngine retries auth failures in a hot loop.
        Task { [weak self] in
            guard let self else { return }
            let status: CKAccountStatus?
            do {
                status = try await self.container.accountStatus()
            } catch {
                status = nil
                self.logger.error("sync.accountStatusFailed", "Could not read iCloud account status", metadata: [
                    "error": "\(error)"
                ], alwaysPersist: true)
            }
            await MainActor.run {
                self.isStarting = false
                guard status == .available, self.engine == nil else {
                    self.logger.warning("sync.startAborted", "Sync not started", metadata: [
                        "accountStatus": Self.accountStatusLabel(status),
                        "engineExists": "\(self.engine != nil)"
                    ])
                    return
                }
                self.activateEngine()
            }
        }
    }

    private func activateEngine() {
        let restoredState = loadState()
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: restoredState,
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        // Ensure our custom zone exists, then queue any already-dirty state.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitSync.zoneID))])
        observeStoreChanges()
        logger.info("sync.engineActivated", "CKSyncEngine activated", metadata: [
            "restoredState": "\(restoredState != nil)",
            "device": DeviceIdentity.current
        ])
        Task { await queuePendingLocalChanges() }
    }

    func stop() {
        cancellables.removeAll()
        engine = nil
        logger.info("sync.stopped", "Sync engine stopped")
    }

    /// Call when AppSettings.iCloudSyncEnabled changes.
    func syncEnabledChanged(_ enabled: Bool) {
        logger.info("sync.toggle", "iCloud sync setting changed", metadata: ["enabled": "\(enabled)"])
        if enabled { start() } else { stop() }
    }

    private func observeStoreChanges() {
        subscriptionStore.objectWillChange
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.queuePendingLocalChanges() }
            }
            .store(in: &cancellables)
    }

    private func queuePendingLocalChanges() async {
        guard let engine, let database else { return }
        let episodes = (try? database.pendingEpisodeSyncStates()) ?? []
        let subscriptions = (try? database.pendingSubscriptionSyncStates()) ?? []
        let history = (try? database.pendingHistoryEntries()) ?? []
        let stats = (try? database.pendingStatsDays()) ?? []
        let deviceID = DeviceIdentity.current

        var changes = episodes.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.episodeRecordID(guid: $0.guid))
        }
        changes += subscriptions.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.subscriptionRecordID(id: $0.subscriptionID))
        }
        changes += history.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.historyRecordID(id: $0.id))
        }
        changes += stats.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.statsRecordID(deviceID: deviceID, dayKey: $0.dayKey))
        }
        guard !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
        logger.info("sync.queued", "Queued local changes to push", metadata: [
            "episodes": "\(episodes.count)",
            "subscriptions": "\(subscriptions.count)",
            "history": "\(history.count)",
            "stats": "\(stats.count)",
            "device": deviceID
        ])
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            saveState(event.stateSerialization)
        case .accountChange(let event):
            await handleAccountChange(event)
        case .fetchedRecordZoneChanges(let event):
            await handleFetchedChanges(event)
        case .sentRecordZoneChanges(let event):
            await handleSentChanges(event)
        case .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { [weak self] recordID in
            self?.recordToSave(for: recordID)
        }
    }

    // MARK: - Push record construction

    private func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
        guard let database else { return nil }
        let name = recordID.recordName

        // Episode? (recordName == guid)
        if let state = try? database.episodeSyncState(guid: name) {
            let record = cachedOrNewRecord(
                systemFields: try? database.episodeSystemFields(guid: name),
                recordType: CloudKitSync.episodeRecordType, recordID: recordID
            )
            CloudKitSync.populate(record, from: state)
            return record
        }

        // Subscription? (recordName == subscriptionID UUID)
        if let id = UUID(uuidString: name), let state = try? database.subscriptionSyncState(id: id) {
            let record = cachedOrNewRecord(
                systemFields: try? database.subscriptionSystemFields(id: id),
                recordType: CloudKitSync.subscriptionRecordType, recordID: recordID
            )
            CloudKitSync.populate(record, from: state)
            return record
        }

        // History entry? (recordName == composite history key)
        if let entry = try? database.historyEntry(id: name) {
            let record = cachedOrNewRecord(
                systemFields: try? database.historySystemFields(id: name),
                recordType: CloudKitSync.historyRecordType, recordID: recordID
            )
            CloudKitSync.populate(record, from: entry)
            return record
        }

        // Stats partition? (recordName == "deviceID:dayKey")
        if let dayKey = Self.statsDayKey(fromRecordName: name), let day = try? database.statsDay(dayKey: dayKey) {
            let record = cachedOrNewRecord(
                systemFields: try? database.statsSystemFields(dayKey: dayKey),
                recordType: CloudKitSync.statsRecordType, recordID: recordID
            )
            CloudKitSync.populate(record, deviceID: DeviceIdentity.current, day: day)
            return record
        }

        return nil // nothing local to send (e.g. a since-deleted record)
    }

    /// Extracts the dayKey from a "deviceID:dayKey" stats record name.
    private static func statsDayKey(fromRecordName name: String) -> String? {
        let parts = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return String(parts[1])
    }

    private func cachedOrNewRecord(systemFields: Data?, recordType: String, recordID: CKRecord.ID) -> CKRecord {
        if let systemFields, let cached = Self.record(fromSystemFields: systemFields) {
            return cached
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    // MARK: - Pull / apply

    private func handleFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        for modification in event.modifications {
            await applyRemote(record: modification.record)
        }
        guard !event.modifications.isEmpty || !event.deletions.isEmpty else { return }
        logger.info("sync.fetched", "Applied remote changes", metadata: [
            "applied": "\(event.modifications.count)",
            "deletions": "\(event.deletions.count)"
        ])
    }

    /// Applies a server record to the local store and caches its system fields.
    /// Shared by the fetch path and the serverRecordChanged conflict path.
    private func applyRemote(record: CKRecord) async {
        let name = record.recordID.recordName
        switch record.recordType {
        case CloudKitSync.episodeRecordType:
            guard let remote = CloudKitSync.episodeSyncState(from: record) else {
                logDecodeFailure(record)
                return
            }
            await MainActor.run { _ = subscriptionStore.applyRemoteEpisodeState(remote) }
            runDB("storeEpisodeSystemFields", metadata: ["guid": name]) {
                try self.database?.storeEpisodeSystemFields(Self.systemFields(of: record), guid: name)
            }

        case CloudKitSync.subscriptionRecordType:
            guard let remote = CloudKitSync.subscriptionSyncState(from: record) else {
                logDecodeFailure(record)
                return
            }
            let outcome = await MainActor.run { subscriptionStore.applyRemoteSubscriptionState(remote) }
            runDB("storeSubscriptionSystemFields", metadata: ["id": remote.subscriptionID.uuidString]) {
                try self.database?.storeSubscriptionSystemFields(Self.systemFields(of: record), id: remote.subscriptionID)
            }
            if case .needsMaterialization(let state) = outcome {
                logger.info("sync.materialize", "Remote subscription needs local materialisation", metadata: [
                    "id": state.subscriptionID.uuidString,
                    "feedURL": state.feedURL.absoluteString
                ])
                await onSubscriptionNeedsMaterialization?(state)
            }

        case CloudKitSync.historyRecordType:
            guard let remote = CloudKitSync.historyEntry(from: record) else {
                logDecodeFailure(record)
                return
            }
            // App layer merges (record-level LWW) and persists the clean row.
            await onRemoteHistoryEntry?(remote)
            runDB("storeHistorySystemFields", metadata: ["id": remote.id]) {
                try self.database?.storeHistorySystemFields(Self.systemFields(of: record), id: remote.id)
            }

        case CloudKitSync.statsRecordType:
            guard let (deviceID, day) = CloudKitSync.statsPartition(from: record) else {
                logDecodeFailure(record)
                return
            }
            guard deviceID != DeviceIdentity.current else { return } // our own record echoed back
            runDB("applyRemoteStatsPartition", metadata: ["device": deviceID]) {
                try self.database?.applyRemoteStatsPartition(deviceID: deviceID, day: day)
            }
            await onRemoteStatsChanged?()

        default:
            logger.warning("sync.unknownRecordType", "Ignored remote record of unknown type", metadata: [
                "type": record.recordType,
                "name": name
            ])
        }
    }

    private func logDecodeFailure(_ record: CKRecord) {
        logger.warning("sync.decodeFailed", "Could not decode remote record", metadata: [
            "type": record.recordType,
            "name": record.recordID.recordName
        ])
    }

    /// Runs a throwing local-database write, logging any failure as an
    /// always-persisted error. These were previously `try?`-swallowed, which hid
    /// the exact bugs (lost system fields, never-cleared dirty stamps) that make
    /// sync misbehave. Success is intentionally silent to keep the log readable.
    private func runDB(_ op: String, metadata: [String: String] = [:], _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            var md = metadata
            md["op"] = op
            md["error"] = "\(error)"
            logger.error("sync.dbWriteFailed", "Local sync-state write failed", metadata: md, alwaysPersist: true)
        }
    }

    private static func accountStatusLabel(_ status: CKAccountStatus?) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        case .none: return "error"
        @unknown default: return "unknown"
        }
    }

    private func handleSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
        for saved in event.savedRecords {
            markSaved(saved)
        }
        if !event.savedRecords.isEmpty {
            logger.info("sync.pushed", "Pushed local records to iCloud", metadata: [
                "saved": "\(event.savedRecords.count)"
            ])
        }

        for failure in event.failedRecordSaves {
            let record = failure.record
            switch failure.error.code {
            case .serverRecordChanged:
                // Field-level merge against the server's copy, then retry.
                logger.info("sync.conflict", "Server record changed — merging then retrying", metadata: [
                    "type": record.recordType,
                    "name": record.recordID.recordName,
                    "hasServerRecord": "\(failure.error.serverRecord != nil)"
                ])
                if let serverRecord = failure.error.serverRecord {
                    await applyRemote(record: serverRecord)
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                }
            case .zoneNotFound, .userDeletedZone:
                logger.warning("sync.zoneRecreate", "Sync zone missing — recreating and re-queuing record", metadata: [
                    "code": "\(failure.error.code.rawValue)",
                    "name": record.recordID.recordName
                ])
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitSync.zoneID))])
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .unknownItem:
                logger.info("sync.recordGone", "Record no longer on server — dropping change", metadata: [
                    "type": record.recordType,
                    "name": record.recordID.recordName
                ])
            default:
                // Transient — CKSyncEngine will retry automatically. Recorded so a
                // user who never sees their data sync has a trail of the CK errors.
                logger.error("sync.pushFailed", "Record push failed (will retry)", metadata: [
                    "type": record.recordType,
                    "name": record.recordID.recordName,
                    "code": "\(failure.error.code.rawValue)",
                    "error": "\(failure.error.localizedDescription)"
                ], alwaysPersist: true)
            }
        }
    }

    /// Caches system fields and clears the dirty stamp for a successfully saved record.
    /// DB writes here were previously `try?`-swallowed; a failure leaves the record
    /// permanently dirty (it re-pushes every sync), so they are logged as errors.
    private func markSaved(_ record: CKRecord) {
        let name = record.recordID.recordName
        switch record.recordType {
        case CloudKitSync.episodeRecordType:
            runDB("markSaved.episode", metadata: ["guid": name]) {
                try self.database?.storeEpisodeSystemFields(Self.systemFields(of: record), guid: name)
                try self.database?.markSynced(episodeGuids: [name], subscriptionIDs: [])
            }
        case CloudKitSync.subscriptionRecordType:
            if let id = UUID(uuidString: name) {
                runDB("markSaved.subscription", metadata: ["id": name]) {
                    try self.database?.storeSubscriptionSystemFields(Self.systemFields(of: record), id: id)
                    try self.database?.markSynced(episodeGuids: [], subscriptionIDs: [id])
                }
            }
        case CloudKitSync.historyRecordType:
            runDB("markSaved.history", metadata: ["id": name]) {
                try self.database?.storeHistorySystemFields(Self.systemFields(of: record), id: name)
                try self.database?.markSynced(episodeGuids: [], subscriptionIDs: [], historyIDs: [name])
            }
        case CloudKitSync.statsRecordType:
            if let dayKey = Self.statsDayKey(fromRecordName: name) {
                runDB("markSaved.stats", metadata: ["dayKey": dayKey]) {
                    try self.database?.storeStatsSystemFields(Self.systemFields(of: record), dayKey: dayKey)
                    try self.database?.markSynced(episodeGuids: [], subscriptionIDs: [], statsDayKeys: [dayKey])
                }
            }
        default:
            break
        }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            logger.info("sync.accountSignIn", "iCloud account signed in", metadata: ["engineExists": "\(engine != nil)"])
            if engine == nil {
                await MainActor.run { self.start() }
            } else {
                await queuePendingLocalChanges()
            }
        case .signOut:
            logger.warning("sync.accountSignOut", "iCloud account signed out — local data retained, nothing pushed")
        case .switchAccounts:
            logger.warning("sync.accountSwitch", "iCloud account switched — local data retained, nothing pushed")
        @unknown default:
            logger.warning("sync.accountUnknownChange", "Unknown iCloud account change type")
        }
    }

    // MARK: - State persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            // A corrupt token forces a full re-fetch — not fatal, but worth a trace.
            logger.warning("sync.stateDecodeFailed", "Could not decode saved sync state — will re-fetch", metadata: [
                "error": "\(error)"
            ])
            return nil
        }
    }

    private func saveState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            // Losing the token only forces a fuller fetch next launch.
            logger.warning("sync.stateSaveFailed", "Could not persist sync state token", metadata: [
                "error": "\(error)"
            ])
        }
    }

    private static func defaultStateURL() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Autohop/cloudkit-sync-state.json")
    }

    // MARK: - CKRecord system-field helpers

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }
}
