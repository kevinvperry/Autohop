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
final class CloudSyncEngine: NSObject, CKSyncEngineDelegate {
    private let container: CKContainer
    private let subscriptionStore: SubscriptionStore
    private let database: AutohopDatabase?
    private let stateURL: URL?

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
        guard engine == nil, !isStarting else { return }
        isStarting = true
        // Only spin up the engine when there's a usable iCloud account —
        // otherwise CKSyncEngine retries auth failures in a hot loop.
        Task { [weak self] in
            guard let self else { return }
            let status = try? await self.container.accountStatus()
            await MainActor.run {
                self.isStarting = false
                guard status == .available, self.engine == nil else { return }
                self.activateEngine()
            }
        }
    }

    private func activateEngine() {
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        // Ensure our custom zone exists, then queue any already-dirty state.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitSync.zoneID))])
        observeStoreChanges()
        Task { await queuePendingLocalChanges() }
    }

    func stop() {
        cancellables.removeAll()
        engine = nil
    }

    /// Call when AppSettings.iCloudSyncEnabled changes.
    func syncEnabledChanged(_ enabled: Bool) {
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

        var changes = episodes.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.episodeRecordID(guid: $0.guid))
        }
        changes += subscriptions.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.subscriptionRecordID(id: $0.subscriptionID))
        }
        changes += history.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.historyRecordID(id: $0.id))
        }
        guard !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
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

        return nil // nothing local to send (e.g. a since-deleted record)
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
    }

    /// Applies a server record to the local store and caches its system fields.
    /// Shared by the fetch path and the serverRecordChanged conflict path.
    private func applyRemote(record: CKRecord) async {
        switch record.recordType {
        case CloudKitSync.episodeRecordType:
            guard let remote = CloudKitSync.episodeSyncState(from: record) else { return }
            await MainActor.run { _ = subscriptionStore.applyRemoteEpisodeState(remote) }
            try? database?.storeEpisodeSystemFields(Self.systemFields(of: record), guid: record.recordID.recordName)

        case CloudKitSync.subscriptionRecordType:
            guard let remote = CloudKitSync.subscriptionSyncState(from: record) else { return }
            let outcome = await MainActor.run { subscriptionStore.applyRemoteSubscriptionState(remote) }
            try? database?.storeSubscriptionSystemFields(Self.systemFields(of: record), id: remote.subscriptionID)
            if case .needsMaterialization(let state) = outcome {
                await onSubscriptionNeedsMaterialization?(state)
            }

        case CloudKitSync.historyRecordType:
            guard let remote = CloudKitSync.historyEntry(from: record) else { return }
            // App layer merges (record-level LWW) and persists the clean row.
            await onRemoteHistoryEntry?(remote)
            try? database?.storeHistorySystemFields(Self.systemFields(of: record), id: remote.id)

        default:
            break
        }
    }

    private func handleSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
        for saved in event.savedRecords {
            markSaved(saved)
        }

        for failure in event.failedRecordSaves {
            let record = failure.record
            switch failure.error.code {
            case .serverRecordChanged:
                // Field-level merge against the server's copy, then retry.
                if let serverRecord = failure.error.serverRecord {
                    await applyRemote(record: serverRecord)
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                }
            case .zoneNotFound, .userDeletedZone:
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitSync.zoneID))])
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .unknownItem:
                break // record gone on the server; drop the change
            default:
                break // transient — CKSyncEngine will retry automatically
            }
        }
    }

    /// Caches system fields and clears the dirty stamp for a successfully saved record.
    private func markSaved(_ record: CKRecord) {
        let name = record.recordID.recordName
        switch record.recordType {
        case CloudKitSync.episodeRecordType:
            try? database?.storeEpisodeSystemFields(Self.systemFields(of: record), guid: name)
            try? database?.markSynced(episodeGuids: [name], subscriptionIDs: [])
        case CloudKitSync.subscriptionRecordType:
            if let id = UUID(uuidString: name) {
                try? database?.storeSubscriptionSystemFields(Self.systemFields(of: record), id: id)
                try? database?.markSynced(episodeGuids: [], subscriptionIDs: [id])
            }
        case CloudKitSync.historyRecordType:
            try? database?.storeHistorySystemFields(Self.systemFields(of: record), id: name)
            try? database?.markSynced(episodeGuids: [], subscriptionIDs: [], historyIDs: [name])
        default:
            break
        }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            if engine == nil {
                await MainActor.run { self.start() }
            } else {
                await queuePendingLocalChanges()
            }
        case .signOut, .switchAccounts:
            break // local data is retained; nothing pushed while signed out
        @unknown default:
            break
        }
    }

    // MARK: - State persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            // Losing the token only forces a fuller fetch next launch.
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
