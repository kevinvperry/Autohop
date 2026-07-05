import Foundation
import CloudKit
import Combine

// AI CONTEXT — Persistence/CloudSyncEngine.swift
// CKSyncEngine wrapper for cross-device sync (SYNC_DESIGN.md).
// OPT-IN: only runs while AppSettings.iCloudSyncEnabled is true (AppState drives
// start/stop). Syncs episode user-state, subscription settings, listening
// history, and additive per-device listening stats. Downloads and catalog content
// never sync.
//
// Pull: handleFetchedChanges wraps the apply loop in SubscriptionStore.begin/
// endChangeNotificationCoalescing so a fetch burst (e.g. 18 records after cold
// launch) fires ONE objectWillChange instead of one per record — the per-record
// version showed as a main-thread hang burst right after launch.
//
// Push: observes SubscriptionStore changes (debounced 1 s), scans the database
// for pending sync-state rows (dirty fields/partitions), and queues saves in two
// LANES. Fast lane (episode user-state + subscription settings — discrete user
// actions) queues immediately on the store debounce. Slow lane (listening
// history + stats day rows) is continuously re-dirtied by playback, so
// slow-lane-ONLY dirt is held for a ~60 s debounce (slowLanePushTask) instead of
// waking CloudKit per store change — the 2026-07-03 log review found 8 CK pushes
// in ~2 min of playback, each saving 1–2 stats/history records. Slow rows
// piggyback on any fast-lane push (a CK request is going out anyway), and
// flushDeferredPushes(reason:) queues them immediately at lifecycle checkpoints
// (pause / background / resign-active — AppState.flushDeferredSyncPushes, called
// AFTER ListeningStatsStore has flushed day buckets into the sync database).
// Coalescing only delays WHEN records are queued, never what they contain: rows
// stay dirty in the local DB until a push succeeds (markSaved), so nothing is
// lost if the app dies before a deferred push. Records
// are built by CloudKitSync, starting from cached CKRecord system fields so
// updates carry the right change tag. Outbound CloudKit record names are now
// type-namespaced (`episode:...`, `history:...`, etc.) so records of different
// types cannot collide inside the shared zone; restored pre-namespace pending
// saves are dropped and replaced by freshly queued namespaced saves. Cached
// legacy system fields are ignored when their CKRecord.ID no longer matches.
// Known-permanent CloudKit type collisions are quarantined in memory and left
// dirty locally so the namespaced retry can repair/re-send them.
//
// REPAIR INVARIANTS: never mark a quarantined permanent collision as synced; the
// local dirty row is the repair source. `activateEngine()` queues dirty local
// rows at startup, so post-namespace builds project those rows to `episode:`
// IDs. `isRetiredLegacyPendingSave` intentionally retires only restored legacy
// `.saveRecord` changes; legacy `.deleteRecord` changes are preserved to avoid
// dropping unsubscribe/tombstone intent.
// Namespace data-loss repair: if cached systemFields point at a legacy record
// name, the engine treats the namespaced record as fresh and asks CloudKitSync to
// write a full snapshot (not a sparse dirty-field overlay). On first activation
// it also makes a one-shot query for legacy unprefixed SubscriptionState records
// and lets SubscriptionStore restore settings for podcasts that still exist.
//
// Pull: fetched server records are decoded and merged into the local store via
// SubscriptionStore.applyRemote*, ListeningHistoryStore, and ListeningStatsStore;
// a remote subscription for a podcast not present here triggers
// `onSubscriptionNeedsMaterialization` (AppState fetches the feed).
//
// Cannot be exercised by `swift test` (CKSyncEngine needs a container,
// entitlements, and a signed-in account) — verified by building and running on a
// real device (Simulator can't trigger CloudKit sync). The pure mapping/merge it
// relies on is unit-tested.
//
// Observability: every stage logs through AppLogger with `sync.*` event keys
// (lifecycle, queued/pushed/fetched batch counts, conflicts, materialisation,
// account changes). `sync.slowLaneDeferred` marks history/stats-only dirt held
// for the slow-lane debounce; `sync.queued` carries a `slowLane` label
// (piggyback vs. the flush reason) so the log shows why a push went out. Local-DB writes that were once `try?`-swallowed now go
// through runDB() and log failures. ERROR-level sync events use
// alwaysPersist:true so they survive even when the Diagnostics toggle is off —
// since this is a since-launch backup feature, a user reporting "my data didn't
// sync" must leave a trace. Verbosity is "balanced": batch summaries, not one
// line per record. Stats sync conflicts are enriched with device/day identity
// and tracked per recordName; repeated conflicts produce sync.conflictStorm so
// DayStats loops are visible without hand-counting log lines. For this device's
// own DayStats partition, a serverRecordChanged response refreshes the cached
// server system fields/change tag but keeps the local full-day bucket dirty, so
// the retry updates the current server record instead of fighting the same stale
// change tag again.
// PUBLIC since tvOS Phase 1: the TV app consumes AutohopCore as a library
// import (unlike the iOS target, which compiles these sources directly), so
// the engine's lifecycle surface (init/start/stop/toggle/flush + the three
// materialization callbacks and the CKSyncEngineDelegate witnesses) is public.
// Internals (queue passes, quarantine, conflict tracking) stay internal.
public final class CloudSyncEngine: NSObject, CKSyncEngineDelegate {
    private let container: CKContainer
    private let subscriptionStore: SubscriptionStore
    private let database: AutohopDatabase?
    private let stateURL: URL?
    private let logger = AppLogger.shared

    private var engine: CKSyncEngine?
    private var isStarting = false
    private var cancellables = Set<AnyCancellable>()
    private var quarantinedRecordKeys = Set<QuarantinedRecordKey>()
    private var conflictTrackers: [String: ConflictTracker] = [:]

    /// Slow-lane (history/stats) push debounce. Batches a playback session's
    /// continuous stats/history churn into roughly one CloudKit push per minute;
    /// lifecycle checkpoints (pause/background) flush sooner via
    /// `flushDeferredPushes`, so at most this window of already-persisted local
    /// rows is waiting to upload at any moment.
    static let slowLaneDebounceSeconds: TimeInterval = 60
    /// Non-nil while a deferred slow-lane push is scheduled. MainActor-confined:
    /// mutated only inside `MainActor.run` blocks and `stop()` (which, like the
    /// rest of the engine lifecycle, is driven from the main thread by AppState).
    private var slowLanePushTask: Task<Void, Never>?

    private let conflictStormThreshold = 5
    private let conflictStormWindow: TimeInterval = 5 * 60
    private let conflictStormRelogInterval: TimeInterval = 60

    private static let legacySubscriptionRecoveryCompletedKey =
        "com.autohop.sync.legacySubscriptionRecovery.v1.completed"

    private struct ConflictTracker {
        var firstSeenAt: Date
        var lastSeenAt: Date
        var count: Int
        var lastStormLoggedAt: Date?
    }

    /// Invoked when a remote subscription record arrives for a podcast not on
    /// this device — the app layer fetches the feed and creates it, then
    /// re-applies the state. Set by AppState (which owns FeedService).
    public var onSubscriptionNeedsMaterialization: ((SubscriptionSyncState) async -> Void)?

    /// Invoked when a remote listening-history entry arrives — the app layer
    /// (ListeningHistoryStore) merges it with record-level LWW. Set by AppState.
    public var onRemoteHistoryEntry: ((ListeningHistoryEntry) async -> Void)?

    /// Invoked AFTER a remote history entry was applied (whichever branch) —
    /// NOTIFY-ONLY, persistence already happened. Read-only history surfaces
    /// (tvOS Continue Watching, which reads the sync DB directly and isn't
    /// Observation-tracked) refresh here so a landing resume position appears
    /// without waiting for some other sync event to re-render. Set by the TV.
    public var onRemoteHistoryChanged: (() async -> Void)?

    /// Invoked after another device's stats partition was stored — the app layer
    /// (ListeningStatsStore) reloads its remote cache and refreshes. Set by AppState.
    public var onRemoteStatsChanged: (() async -> Void)?

    /// Invoked after a NEWER remote queue snapshot was adopted (2026-07-04) —
    /// NOTIFY-ONLY: persistence already happened in the engine
    /// (saveSyncedQueueSnapshot, LWW by updatedAt). Read-only queue surfaces
    /// (tvOS TVAppModel) refresh their rendered queue here.
    public var onRemoteQueueSnapshotChanged: (() async -> Void)?

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

    /// Library-consumer entry point (tvOS Phase 1): the store's record database
    /// is an internal type, so external targets construct the engine from the
    /// SubscriptionStore facade and this pulls the database internally.
    public convenience init(containerIdentifier: String, subscriptionStore: SubscriptionStore) {
        self.init(
            containerIdentifier: containerIdentifier,
            subscriptionStore: subscriptionStore,
            database: subscriptionStore.database
        )
    }

    // MARK: - Lifecycle

    public func start() {
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
        Task {
            await recoverLegacySubscriptionSettingsIfNeeded()
            await queuePendingLocalChanges(slowLane: .flush(reason: "engineActivated"))
        }
    }

    public func stop() {
        cancellables.removeAll()
        slowLanePushTask?.cancel()
        slowLanePushTask = nil
        engine = nil
        logger.info("sync.stopped", "Sync engine stopped")
    }

    /// Call when AppSettings.iCloudSyncEnabled changes.
    public func syncEnabledChanged(_ enabled: Bool) {
        logger.info("sync.toggle", "iCloud sync setting changed", metadata: ["enabled": "\(enabled)"])
        if enabled { start() } else { stop() }
    }

    private func observeStoreChanges() {
        subscriptionStore.objectWillChange
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.queuePendingLocalChanges(slowLane: .coalesce) }
            }
            .store(in: &cancellables)
    }

    /// Queues any deferred slow-lane (history/stats) changes immediately, along
    /// with whatever else is pending. The app layer calls this at lifecycle
    /// checkpoints — pause, scene backgrounding, resign-active — AFTER
    /// ListeningStatsStore has flushed its coalesced day buckets into the sync
    /// database, so the scan sees the freshest rows. No-op while stopped.
    public func flushDeferredPushes(reason: String) {
        guard engine != nil else { return }
        Task { [weak self] in
            await self?.queuePendingLocalChanges(slowLane: .flush(reason: reason))
        }
    }

    /// Targeted fetch of the single `queue:current` record, applied through the
    /// normal pull path (`applyRemote`), bypassing the full CKSyncEngine delta
    /// stream. Used by read-only queue surfaces (tvOS) at launch/foreground so
    /// the Up Next queue mirrors the phone's within seconds instead of after
    /// the whole change stream has drained (Kevin's real-device finding: the
    /// TV queue cycled through stale episodes for ~10 min before the snapshot
    /// surfaced). Requires an active account; a `.unknownItem` (nothing
    /// authored yet) is expected and silent. Returns true when a snapshot was
    /// fetched and applied.
    @discardableResult
    public func fetchQueueSnapshotNow(reason: String) async -> Bool {
        guard engine != nil else { return false }
        do {
            let record = try await container.privateCloudDatabase.record(for: CloudKitSync.queueSnapshotRecordID)
            await applyRemote(record: record)
            logger.info("sync.queueSnapshotFetched", "Targeted queue-snapshot fetch applied", metadata: [
                "reason": reason
            ])
            return true
        } catch let error as CKError where error.code == .unknownItem {
            // No queue authored yet — normal on a fresh account.
            return false
        } catch {
            logger.warning("sync.queueSnapshotFetchFailed", "Targeted queue-snapshot fetch failed (will still arrive via the change stream)", metadata: [
                "reason": reason,
                "error": "\(error)"
            ])
            return false
        }
    }

    /// True once the underlying CKSyncEngine has been activated (the async
    /// account-status check passed). Targeted primes/fetches are no-ops until
    /// then, so callers poll this before priming at launch.
    public var isActivated: Bool { engine != nil }

    /// Targeted fetch of EVERY current subscription record in the zone, applied
    /// immediately — bypassing CKSyncEngine's cold-start delta stream, which can
    /// take minutes to surface the initial record set on a fresh install (the
    /// "No Library Yet" blank Kevin saw for ~5 min). Each applied subscription
    /// routes through `applyRemote` → `applyRemoteSubscriptionState`, which
    /// kicks off local materialisation (feed fetch) right away, so the Library
    /// populates in seconds. Legacy unprefixed records are skipped (the normal
    /// namespace-repair path owns those). Returns the number applied; 0 is a
    /// normal result on a brand-new account with nothing synced yet.
    @discardableResult
    public func fetchAllSubscriptionsNow(reason: String) async -> Int {
        guard engine != nil else { return 0 }
        let query = CKQuery(recordType: CloudKitSync.subscriptionRecordType, predicate: NSPredicate(value: true))
        let database = container.privateCloudDatabase
        var applied = 0
        var cursor: CKQueryOperation.Cursor?
        do {
            repeat {
                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
                if let cursor {
                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults)
                } else {
                    page = try await database.records(matching: query, inZoneWith: CloudKitSync.zoneID, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults)
                }
                for (_, result) in page.matchResults {
                    guard case .success(let record) = result else { continue }
                    // Skip legacy unprefixed records — namespace repair owns them.
                    if CloudKitSync.isLegacySubscriptionRecordName(record.recordID.recordName) { continue }
                    await applyRemote(record: record)
                    applied += 1
                }
                cursor = page.queryCursor
            } while cursor != nil
            logger.info("sync.subscriptionsPrimed", "Targeted subscription prime applied", metadata: [
                "reason": reason, "count": "\(applied)"
            ])
            return applied
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // Nothing synced yet / zone not created — normal on a fresh account.
            return 0
        } catch {
            logger.warning("sync.subscriptionsPrimeFailed", "Targeted subscription prime failed (records will still arrive via the change stream)", metadata: [
                "reason": reason, "error": "\(error)"
            ])
            return applied
        }
    }

    /// Targeted fetch of EVERY listening-history record in the zone, applied
    /// immediately — the Continue Watching / cross-device resume surface. Same
    /// motivation as `fetchAllSubscriptionsNow`: history rides the SLOW lane and
    /// surfaces late in the cold change stream, so the paused-on-iPhone episode
    /// could take many minutes (or, with no re-render trigger, never) to appear
    /// on the TV. Each record routes through `applyRemote`, which persists it
    /// (LWW) and fires `onRemoteHistoryChanged` so the UI refreshes.
    @discardableResult
    public func fetchAllHistoryNow(reason: String) async -> Int {
        guard engine != nil else { return 0 }
        let query = CKQuery(recordType: CloudKitSync.historyRecordType, predicate: NSPredicate(value: true))
        let database = container.privateCloudDatabase
        var applied = 0
        var cursor: CKQueryOperation.Cursor?
        do {
            repeat {
                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
                if let cursor {
                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults)
                } else {
                    page = try await database.records(matching: query, inZoneWith: CloudKitSync.zoneID, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults)
                }
                for (_, result) in page.matchResults {
                    guard case .success(let record) = result else { continue }
                    await applyRemote(record: record)
                    applied += 1
                }
                cursor = page.queryCursor
            } while cursor != nil
            logger.info("sync.historyPrimed", "Targeted history prime applied", metadata: [
                "reason": reason, "count": "\(applied)"
            ])
            return applied
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return 0
        } catch {
            logger.warning("sync.historyPrimeFailed", "Targeted history prime failed (records will still arrive via the change stream)", metadata: [
                "reason": reason, "error": "\(error)"
            ])
            return applied
        }
    }

    /// How a queue pass treats slow-lane pending changes. Fast lane = episode
    /// user-state + subscription settings (discrete user actions). Slow lane =
    /// listening history + stats day rows (playback re-dirties them continuously,
    /// so pushing per store change produced 1–2-record CloudKit saves every few
    /// seconds — see the file header).
    enum SlowLaneDisposition {
        /// Store-change observer path: slow-lane-only dirt waits for the
        /// slow-lane debounce instead of waking CloudKit per change.
        case coalesce
        /// Queue everything now: engine activation, account sign-in, slow-lane
        /// debounce expiry, and lifecycle checkpoints (`flushDeferredPushes`).
        case flush(reason: String)
    }

    /// Pure lane policy (unit-tested headless in SyncPushCoalescingTests):
    /// defer the slow lane only when the caller allows coalescing, there is
    /// slow-lane dirt, and no fast-lane push is going out anyway — when one is,
    /// the slow rows piggyback on it at zero extra request cost.
    static func shouldDeferSlowLane(_ disposition: SlowLaneDisposition, fastCount: Int, slowCount: Int) -> Bool {
        guard case .coalesce = disposition else { return false }
        return fastCount == 0 && slowCount > 0
    }

    private func scheduleSlowLanePush(historyCount: Int, statsCount: Int) async {
        await MainActor.run {
            guard self.slowLanePushTask == nil else { return } // keep the earliest deadline
            self.logger.info("sync.slowLaneDeferred", "History/stats-only changes held for slow-lane debounce", metadata: [
                "history": "\(historyCount)",
                "stats": "\(statsCount)",
                "debounceSeconds": "\(Int(Self.slowLaneDebounceSeconds))"
            ])
            self.slowLanePushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.slowLaneDebounceSeconds))
                guard let self, !Task.isCancelled else { return }
                // Clear the handle BEFORE flushing: if the flush scan comes back
                // empty (rows already piggybacked onto a fast-lane push), a stale
                // non-nil handle would block every future slow-lane schedule.
                await MainActor.run { self.slowLanePushTask = nil }
                await self.queuePendingLocalChanges(slowLane: .flush(reason: "slowLaneDebounce"))
            }
        }
    }

    private func cancelSlowLanePush() async {
        await MainActor.run {
            self.slowLanePushTask?.cancel()
            self.slowLanePushTask = nil
        }
    }

    private func queuePendingLocalChanges(slowLane: SlowLaneDisposition) async {
        guard let engine, let database else { return }
        // A read failure here is not "nothing pending" — treating it as such would
        // silently drop a sync push with no trace. Log each failure (the next store
        // change re-runs this and can recover) instead of swallowing with `try?`.
        // ERROR events use alwaysPersist so a "my data didn't sync" report leaves a
        // trail even with the Diagnostics toggle off.
        func read<T>(_ label: String, _ body: () throws -> [T]) -> [T] {
            do {
                return try body()
            } catch {
                logger.error("sync.readFailed", "Failed to read pending \(label)", metadata: [
                    "error": String(describing: error)
                ], alwaysPersist: true)
                return []
            }
        }
        let episodes = read("episode sync states", database.pendingEpisodeSyncStates)
        let subscriptions = read("subscription sync states", database.pendingSubscriptionSyncStates)
        let history = read("history entries", database.pendingHistoryEntries)
        let stats = read("stats days", database.pendingStatsDays)
        let pendingQueue = (try? database.pendingQueueSnapshot()) ?? nil
        let deviceID = DeviceIdentity.current

        let episodeChanges = episodes.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.episodeRecordID(for: $0))
        }.filter { !isQuarantined($0) }
        let subscriptionChanges = subscriptions.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.subscriptionRecordID(id: $0.subscriptionID))
        }.filter { !isQuarantined($0) }
        let historyChanges = history.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.historyRecordID(id: $0.id))
        }.filter { !isQuarantined($0) }
        let statsChanges = stats.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitSync.statsRecordID(deviceID: deviceID, dayKey: $0.dayKey))
        }.filter { !isQuarantined($0) }

        // Queue snapshot rides the FAST lane: it changes on discrete queue
        // events (play/archive/pin/download-complete), and it's the record
        // other devices' core surface renders from — freshness matters.
        let queueChanges: [CKSyncEngine.PendingRecordZoneChange] = pendingQueue != nil
            ? [.saveRecord(CloudKitSync.queueSnapshotRecordID)].filter { !isQuarantined($0) }
            : []

        let fastChanges = episodeChanges + subscriptionChanges + queueChanges
        let slowChanges = historyChanges + statsChanges

        if Self.shouldDeferSlowLane(slowLane, fastCount: fastChanges.count, slowCount: slowChanges.count) {
            // Playback churn: only history/stats rows are dirty. Hold them for
            // the slow-lane debounce instead of a 1–2-record CloudKit push per
            // store change. The rows stay dirty locally, so nothing is lost if
            // the timer never fires — the next flush or queue pass picks them up.
            await scheduleSlowLanePush(historyCount: historyChanges.count, statsCount: statsChanges.count)
            return
        }

        let changes = fastChanges + slowChanges
        guard !changes.isEmpty else { return }
        // Whatever the slow-lane timer was waiting on is being queued right now
        // (piggybacked on a fast-lane push, or explicitly flushed) — drop it.
        await cancelSlowLanePush()
        engine.state.add(pendingRecordZoneChanges: changes)
        let statsDayKeys = stats.map(\.dayKey).sorted()
        let cachedStatsSystemFieldCount = stats.reduce(into: 0) { count, day in
            if ((try? database.statsSystemFields(dayKey: day.dayKey)) ?? nil) != nil {
                count += 1
            }
        }
        let slowLaneLabel: String
        switch slowLane {
        case .coalesce: slowLaneLabel = "piggyback"
        case .flush(let reason): slowLaneLabel = reason
        }
        logger.info("sync.queued", "Queued local changes to push", metadata: [
            "episodes": "\(episodeChanges.count)",
            "subscriptions": "\(subscriptionChanges.count)",
            "history": "\(historyChanges.count)",
            "stats": "\(statsChanges.count)",
            "queue": "\(queueChanges.count)",
            "statsDayKeys": statsDayKeys.joined(separator: ","),
            "statsSystemFieldsCached": "\(cachedStatsSystemFieldCount)",
            "statsRecordNames": statsDayKeys.map { CloudKitSync.statsRecordName(deviceID: deviceID, dayKey: $0) }.joined(separator: ","),
            "quarantined": "\((episodes.count + subscriptions.count + history.count + stats.count + (pendingQueue != nil ? 1 : 0)) - changes.count)",
            "slowLane": slowLaneLabel,
            "device": deviceID
        ])
    }

    private func recoverLegacySubscriptionSettingsIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.legacySubscriptionRecoveryCompletedKey) else { return }

        do {
            let records = try await fetchLegacySubscriptionRecords()
            var decoded = 0
            var recovered = 0
            var skippedUnknown = 0

            for record in records {
                guard let state = CloudKitSync.subscriptionSyncState(from: record) else {
                    logger.warning("sync.legacySubscriptionRecoveryDecodeFailed", "Could not decode legacy subscription record", metadata: [
                        "name": record.recordID.recordName
                    ])
                    continue
                }
                decoded += 1

                let didRecover = await MainActor.run {
                    subscriptionStore.recoverSettingsFromLegacySubscriptionState(state)
                }
                if didRecover {
                    recovered += 1
                    engine?.state.add(pendingRecordZoneChanges: [
                        .saveRecord(CloudKitSync.subscriptionRecordID(id: state.subscriptionID))
                    ])
                } else {
                    skippedUnknown += 1
                }
            }

            UserDefaults.standard.set(true, forKey: Self.legacySubscriptionRecoveryCompletedKey)
            logger.warning("sync.legacySubscriptionRecovery", "Legacy subscription settings recovery completed", metadata: [
                "decoded": "\(decoded)",
                "recovered": "\(recovered)",
                "skippedUnknown": "\(skippedUnknown)"
            ])
        } catch {
            logger.error("sync.legacySubscriptionRecoveryFailed", "Failed to recover legacy subscription settings", metadata: [
                "error": "\(error)"
            ], alwaysPersist: true)
        }
    }

    private func fetchLegacySubscriptionRecords() async throws -> [CKRecord] {
        let query = CKQuery(recordType: CloudKitSync.subscriptionRecordType, predicate: NSPredicate(value: true))
        let database = container.privateCloudDatabase
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: nil,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            } else {
                page = try await database.records(
                    matching: query,
                    inZoneWith: CloudKitSync.zoneID,
                    desiredKeys: nil,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            }

            for (recordID, result) in page.matchResults {
                switch result {
                case .success(let record):
                    if CloudKitSync.isLegacySubscriptionRecordName(record.recordID.recordName) {
                        records.append(record)
                    }
                case .failure(let error):
                    logger.warning("sync.legacySubscriptionRecoveryRecordFailed", "Could not fetch legacy subscription record", metadata: [
                        "name": recordID.recordName,
                        "error": "\(error)"
                    ])
                }
            }

            cursor = page.queryCursor
        } while cursor != nil

        return records
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
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

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var retiredLegacyChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        for change in syncEngine.state.pendingRecordZoneChanges where scope.contains(change) {
            if isQuarantined(change) { continue }
            if Self.isRetiredLegacyPendingSave(change) {
                retiredLegacyChanges.append(change)
                continue
            }
            pendingChanges.append(change)
        }

        if !retiredLegacyChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: retiredLegacyChanges)
            logger.info("sync.legacyPendingDropped", "Dropped restored pre-namespace pending saves", metadata: [
                "count": "\(retiredLegacyChanges.count)"
            ])
        }
        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { [weak self] recordID in
            self?.recordToSave(for: recordID)
        }
    }

    // MARK: - Push record construction

    private func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
        guard let database else { return nil }
        let name = recordID.recordName
        let episodeSyncKey = CloudKitSync.episodeSyncKey(fromRecordName: name)
        let subscriptionID = CloudKitSync.subscriptionID(fromRecordName: name)
        let historyID = CloudKitSync.historyID(fromRecordName: name)
        let statsDayKey = CloudKitSync.statsDayKey(fromRecordName: name)

        // A nil from any lookup means "not this record type" (normal — try the next
        // branch); a THROW means a real read/decode error. Swallowing the throw with
        // `try?` would silently drop a queued push. So `try` here, and log genuine
        // failures in the catch. (systemFields stays `try?` — a missing cached blob
        // is normal for a new record and cachedOrNewRecord handles nil.)
        do {
            // Episode? (current recordName == episode:<subscriptionID|guid:<guid>);
            // fall back to restored legacy pending names only when unambiguous.
            if let state = try database.episodeSyncState(syncKey: episodeSyncKey)
                ?? database.legacyEpisodeSyncState(guid: name) {
                let target = cachedOrNewRecord(
                    systemFields: try? database.episodeSystemFields(syncKey: state.syncKey),
                    recordType: CloudKitSync.episodeRecordType, recordID: recordID
                )
                CloudKitSync.populate(target.record, from: state, includeCleanFields: target.requiresFullSnapshot)
                return target.record
            }

            // Subscription? (current recordName == subscription:<subscriptionID>).
            if let id = subscriptionID, let state = try database.subscriptionSyncState(id: id) {
                let target = cachedOrNewRecord(
                    systemFields: try? database.subscriptionSystemFields(id: id),
                    recordType: CloudKitSync.subscriptionRecordType, recordID: recordID
                )
                CloudKitSync.populate(target.record, from: state, includeCleanFields: target.requiresFullSnapshot)
                return target.record
            }

            // History entry? (current recordName == history:<composite history key>).
            if let entry = try database.historyEntry(id: historyID) {
                let target = cachedOrNewRecord(
                    systemFields: try? database.historySystemFields(id: historyID),
                    recordType: CloudKitSync.historyRecordType, recordID: recordID
                )
                CloudKitSync.populate(target.record, from: entry)
                return target.record
            }

            // Stats partition? (current recordName == stats:<deviceID>:<dayKey>).
            if let dayKey = statsDayKey, let day = try database.statsDay(dayKey: dayKey) {
                let target = cachedOrNewRecord(
                    systemFields: try? database.statsSystemFields(dayKey: dayKey),
                    recordType: CloudKitSync.statsRecordType, recordID: recordID
                )
                CloudKitSync.populate(target.record, deviceID: DeviceIdentity.current, day: day)
                return target.record
            }

            // Queue snapshot? (fixed recordName == queue:current — one per account).
            if CloudKitSync.isQueueSnapshotRecordName(name),
               let snapshot = try database.pendingQueueSnapshot() {
                let target = cachedOrNewRecord(
                    systemFields: try? database.queueSnapshotSystemFields(),
                    recordType: CloudKitSync.queueSnapshotRecordType, recordID: recordID
                )
                CloudKitSync.populate(target.record, from: snapshot)
                return target.record
            }
        } catch {
            logger.error("sync.recordBuildFailed", "Failed to read local state while building a record to push", metadata: [
                "recordName": name,
                "error": String(describing: error)
            ], alwaysPersist: true)
            return nil
        }

        // No branch matched and nothing threw. Usually a record deleted locally
        // between queueing and push (benign), but it is also the only place a
        // queued push can silently vanish — log at warning so it is observable.
        logger.warning("sync.recordNotFound", "No local state matched a queued push record", metadata: [
            "recordName": name
        ])
        return nil
    }

    private struct RecordBuildTarget {
        var record: CKRecord
        var requiresFullSnapshot: Bool
    }

    private func cachedOrNewRecord(systemFields: Data?, recordType: String, recordID: CKRecord.ID) -> RecordBuildTarget {
        if let systemFields,
           let cached = Self.record(fromSystemFields: systemFields),
           cached.recordType == recordType,
           cached.recordID == recordID {
            return RecordBuildTarget(record: cached, requiresFullSnapshot: false)
        }
        return RecordBuildTarget(
            record: CKRecord(recordType: recordType, recordID: recordID),
            requiresFullSnapshot: true
        )
    }

    // MARK: - Pull / apply

    private func handleFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        // Coalesce store notifications across the whole apply burst: each applyRemote
        // save fires its own objectWillChange, so a post-launch fetch of N records
        // produced N whole-app SwiftUI invalidations back-to-back (observed as a
        // main-thread hang burst right after cold launch). One notification at the
        // end is enough — views re-read the final state.
        await MainActor.run { subscriptionStore.beginChangeNotificationCoalescing() }
        for modification in event.modifications {
            await applyRemote(record: modification.record)
        }
        await MainActor.run { subscriptionStore.endChangeNotificationCoalescing() }
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
            runDB("storeEpisodeSystemFields", metadata: ["syncKey": remote.syncKey]) {
                try self.database?.storeEpisodeSystemFields(Self.systemFields(of: record), syncKey: remote.syncKey)
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
            if let onRemoteHistoryEntry {
                // iOS: the app layer (ListeningHistoryStore) merges with
                // record-level LWW and persists the clean row itself.
                await onRemoteHistoryEntry(remote)
            } else {
                // BUG FIX (found via tvOS real-device testing, 2026-07-04):
                // history was the ONLY record type whose PERSISTENCE depended
                // entirely on the app callback — episode/subscription/stats
                // records are written by the engine/store directly. A platform
                // that never wired the callback (the TV app) silently dropped
                // every synced history entry, i.e. every cross-device resume
                // position. Fall back to persisting the entry as clean
                // synced state so no consumer can ever lose it; platforms with
                // their own in-memory history store still use the callback.
                runDB("saveSyncedHistoryEntry", metadata: ["id": remote.id]) {
                    try self.database?.saveSyncedHistoryEntry(remote)
                }
            }
            runDB("storeHistorySystemFields", metadata: ["id": remote.id]) {
                try self.database?.storeHistorySystemFields(Self.systemFields(of: record), id: remote.id)
            }
            await onRemoteHistoryChanged?()

        case CloudKitSync.queueSnapshotRecordType:
            guard let remote = CloudKitSync.queueSnapshot(from: record) else {
                logDecodeFailure(record)
                return
            }
            // Persisted by the ENGINE directly (per the 2026-07-04 lesson from
            // the history-record bug: never make a record type's persistence
            // depend on an optional app callback). LWW-by-updatedAt inside
            // saveSyncedQueueSnapshot protects a local author's newer pending
            // queue. The callback is notify-only.
            var adopted = false
            runDB("saveSyncedQueueSnapshot") {
                adopted = try self.database?.saveSyncedQueueSnapshot(remote) ?? false
            }
            runDB("storeQueueSnapshotSystemFields") {
                try self.database?.storeQueueSnapshotSystemFields(Self.systemFields(of: record))
            }
            if adopted {
                await onRemoteQueueSnapshotChanged?()
            }

        case CloudKitSync.statsRecordType:
            guard let (deviceID, day) = CloudKitSync.statsPartition(from: record) else {
                logDecodeFailure(record)
                return
            }
            if deviceID == DeviceIdentity.current {
                // This is our own per-device partition, often delivered as the
                // server side of a serverRecordChanged conflict. Cache the server
                // change tag, but do not mark the local full-day bucket clean:
                // the pending local row remains the source of truth for the retry.
                runDB("storeLocalStatsSystemFields", metadata: [
                    "device": deviceID,
                    "dayKey": day.dayKey
                ]) {
                    try self.database?.storeStatsSystemFields(Self.systemFields(of: record), dayKey: day.dayKey)
                }
                return
            }
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

    private func conflictMetadata(
        for record: CKRecord,
        hasServerRecord: Bool,
        conflictCount: Int,
        firstSeenAt: Date
    ) -> [String: String] {
        var metadata = [
            "hasServerRecord": "\(hasServerRecord)",
            "willRetry": "\(hasServerRecord)",
            "sessionConflictCount": "\(conflictCount)",
            "firstConflictAt": ISO8601DateFormatter().string(from: firstSeenAt)
        ]

        if record.recordType == CloudKitSync.statsRecordType,
           let identity = CloudKitSync.statsIdentity(fromRecordName: record.recordID.recordName) {
            let localDeviceID = DeviceIdentity.current
            let hasCachedSystemFields: Bool
            if let database {
                hasCachedSystemFields = ((try? database.statsSystemFields(dayKey: identity.dayKey)) ?? nil) != nil
            } else {
                hasCachedSystemFields = false
            }
            metadata.merge([
                "statsDeviceID": identity.deviceID,
                "localDeviceID": localDeviceID,
                "statsDayKey": identity.dayKey,
                "isLocalStatsPartition": "\(identity.deviceID == localDeviceID)",
                "hasCachedSystemFields": "\(hasCachedSystemFields)",
                "statsConflictResolution": identity.deviceID == localDeviceID
                    ? "cacheServerFieldsRetryLocalDay"
                    : "applyRemotePartition"
            ]) { _, new in new }
        }

        return metadata
    }

    private func updateConflictTracker(recordName: String) -> (count: Int, firstSeenAt: Date, shouldLogStorm: Bool) {
        let now = Date()
        var tracker = conflictTrackers[recordName] ?? ConflictTracker(
            firstSeenAt: now,
            lastSeenAt: now,
            count: 0,
            lastStormLoggedAt: nil
        )
        if now.timeIntervalSince(tracker.firstSeenAt) > conflictStormWindow {
            tracker = ConflictTracker(
                firstSeenAt: now,
                lastSeenAt: now,
                count: 0,
                lastStormLoggedAt: nil
            )
        }

        tracker.count += 1
        tracker.lastSeenAt = now
        let shouldLogStorm = tracker.count >= conflictStormThreshold
            && (tracker.lastStormLoggedAt.map { now.timeIntervalSince($0) >= conflictStormRelogInterval } ?? true)
        if shouldLogStorm {
            tracker.lastStormLoggedAt = now
        }
        conflictTrackers[recordName] = tracker
        return (tracker.count, tracker.firstSeenAt, shouldLogStorm)
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
                let conflictUpdate = updateConflictTracker(recordName: record.recordID.recordName)
                let metadata = conflictMetadata(
                    for: record,
                    hasServerRecord: failure.error.serverRecord != nil,
                    conflictCount: conflictUpdate.count,
                    firstSeenAt: conflictUpdate.firstSeenAt
                )
                logger.info("sync.conflict", "Server record changed — merging then retrying", metadata: [
                    "type": record.recordType,
                    "name": record.recordID.recordName
                ].merging(metadata) { _, new in new })
                if conflictUpdate.shouldLogStorm {
                    logger.warning("sync.conflictStorm", "Repeated sync conflicts for the same record", metadata: [
                        "type": record.recordType,
                        "name": record.recordID.recordName
                    ].merging(metadata) { _, new in new })
                }
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
                if Self.isPermanentRecordTypeCollision(
                    code: failure.error.code,
                    localizedDescription: failure.error.localizedDescription,
                    recordType: record.recordType
                ) {
                    quarantinePermanentPushFailure(record: record, error: failure.error)
                    continue
                }
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

    static func isPermanentRecordTypeCollision(
        code: CKError.Code,
        localizedDescription: String,
        recordType: String
    ) -> Bool {
        guard recordType == CloudKitSync.episodeRecordType else { return false }
        guard code == .invalidArguments || code == .serverRejectedRequest else { return false }
        return localizedDescription.contains("invalid attempt to update record from type")
            && localizedDescription.contains("HistoryEntry")
            && localizedDescription.contains("EpisodeState")
    }

    private func quarantinePermanentPushFailure(record: CKRecord, error: CKError) {
        let key = QuarantinedRecordKey(recordID: record.recordID)
        let wasInserted = quarantinedRecordKeys.insert(key).inserted
        engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        guard wasInserted else { return }

        logger.error("sync.pushQuarantined", "Permanent CloudKit record-type collision quarantined pending namespace migration", metadata: [
            "type": record.recordType,
            "name": record.recordID.recordName,
            "code": "\(error.code.rawValue)",
            "reason": "recordTypeCollision",
            "action": "suppressedUntilNamespaceMigration",
            "error": error.localizedDescription
        ], alwaysPersist: true)
    }

    private func isQuarantined(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
        guard let recordID = Self.recordID(from: change) else { return false }
        return isQuarantined(recordID)
    }

    private func isQuarantined(_ recordID: CKRecord.ID) -> Bool {
        quarantinedRecordKeys.contains(QuarantinedRecordKey(recordID: recordID))
    }

    private static func recordID(from change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            return recordID
        @unknown default:
            return nil
        }
    }

    static func isRetiredLegacyPendingSave(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
        switch change {
        case .saveRecord(let recordID):
            return !CloudKitSync.isCurrentRecordName(recordID.recordName)
        case .deleteRecord:
            return false
        @unknown default:
            return false
        }
    }

    private struct QuarantinedRecordKey: Hashable {
        let recordName: String
        let zoneName: String
        let ownerName: String

        init(recordID: CKRecord.ID) {
            self.recordName = recordID.recordName
            self.zoneName = recordID.zoneID.zoneName
            self.ownerName = recordID.zoneID.ownerName
        }
    }

    /// Caches system fields and clears the dirty stamp for a successfully saved record.
    /// DB writes here were previously `try?`-swallowed; a failure leaves the record
    /// permanently dirty (it re-pushes every sync), so they are logged as errors.
    private func markSaved(_ record: CKRecord) {
        let name = record.recordID.recordName
        switch record.recordType {
        case CloudKitSync.episodeRecordType:
            let syncKey = CloudKitSync.episodeSyncKey(from: record)
                ?? CloudKitSync.episodeSyncKey(fromRecordName: name)
            runDB("markSaved.episode", metadata: ["syncKey": syncKey]) {
                try self.database?.storeEpisodeSystemFields(Self.systemFields(of: record), syncKey: syncKey)
                try self.database?.markSynced(episodeSyncKeys: [syncKey], subscriptionIDs: [])
            }
        case CloudKitSync.subscriptionRecordType:
            if let id = CloudKitSync.subscriptionID(fromRecordName: name) {
                runDB("markSaved.subscription", metadata: ["id": id.uuidString]) {
                    try self.database?.storeSubscriptionSystemFields(Self.systemFields(of: record), id: id)
                    try self.database?.markSynced(episodeSyncKeys: [], subscriptionIDs: [id])
                }
            }
        case CloudKitSync.historyRecordType:
            let id = CloudKitSync.historyID(fromRecordName: name)
            runDB("markSaved.history", metadata: ["id": id]) {
                try self.database?.storeHistorySystemFields(Self.systemFields(of: record), id: id)
                try self.database?.markSynced(episodeSyncKeys: [], subscriptionIDs: [], historyIDs: [id])
            }
        case CloudKitSync.statsRecordType:
            if let dayKey = CloudKitSync.statsDayKey(fromRecordName: name) {
                runDB("markSaved.stats", metadata: ["dayKey": dayKey]) {
                    try self.database?.storeStatsSystemFields(Self.systemFields(of: record), dayKey: dayKey)
                    try self.database?.markSynced(episodeSyncKeys: [], subscriptionIDs: [], statsDayKeys: [dayKey])
                }
            }
        case CloudKitSync.queueSnapshotRecordType:
            runDB("markSaved.queueSnapshot") {
                try self.database?.storeQueueSnapshotSystemFields(Self.systemFields(of: record))
                try self.database?.markQueueSnapshotSynced()
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
                await queuePendingLocalChanges(slowLane: .flush(reason: "accountSignIn"))
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
