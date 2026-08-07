import Combine
import CloudKit
import Foundation
import AutohopCore

// AI CONTEXT — Private-iCloud lifecycle and foreground freshness workflow. Extracted from TVAppModel without changing
// product policy; this extension is tvOS-only and coordinated through focused
// observable state owners defined in TVAppFeatureModels.swift.

extension TVAppModel {
    // MARK: - Sync

    private var pendingPlayNextRequestsDefaultsKey: String {
        "com.autohop.tv.pendingPlayNextRequests.v1"
    }

    func startCloudSync() {
        restorePendingPlayNextOverlay()
        // pushesSubscriptionState: false — HARD one-way rule (2026-07-11,
        // Kevin's directive after the purge-rebuild default-settings damage):
        // the TV must have ZERO ability to alter subscription settings,
        // subscribed state, or priority ranking on the phone. The engine
        // structurally refuses to push SubscriptionState records in this mode
        // (dirty rows never queued; restored pending saves dropped; legacy
        // recovery skipped). Episode played-state, history, stats, and the
        // queue snapshot still push — those are the TV's legitimate outputs.
        // Consequence: subscribe-on-TV stays local to the TV.
        let engine = CloudSyncEngine(
            containerIdentifier: "iCloud.com.kevinperry.autohop",
            subscriptionStore: subscriptionStore,
            capabilities: .tvCompanion
        )
        engine.onSubscriptionNeedsMaterialization = { [weak self] state in
            await self?.materializeRemoteSubscription(state)
        }
        // Notify-only (persistence happens in the engine): re-render Up Next
        // the moment a newer phone-authored queue snapshot lands. The hop back
        // to the main actor is the await; refreshLibrary itself is synchronous.
        engine.onRemoteQueueSnapshotChanged = { [weak self] in
            await MainActor.run { self?.scheduleLibraryRefresh() }
        }
        // Notify-only: re-render Home when a listening-history entry lands, so
        // Continue Watching populates the moment the paused-on-iPhone episode's
        // resume position syncs (it's read from the DB, not Observation-tracked).
        // COALESCED + history-cache invalidation — see scheduleLibraryRefresh's
        // header and continueListeningCache below.
        engine.onRemoteHistoryChanged = { [weak self] in
            await MainActor.run {
                self?.historyNeedsReload = true
                self?.historyModel.invalidate()
                self?.scheduleLibraryRefresh()
            }
        }
        cloudSyncEngine = engine
        engine.start()
    }

    /// Applies a local presentation pin synchronously, then sends a narrow
    /// command to the phone instead of mutating the phone-authored queue
    /// snapshot on Apple TV. The local overlay survives intervening stale
    /// snapshots; the next authoritative phone snapshot confirms and clears it.
    func requestPlayNext(_ row: TVQueueRowModel) async {
        guard let episode = row.episode else {
            AppLogger.shared.warning("tv.playNextRejected", "Play Next row has no resolved episode", metadata: [
                "rowKey": row.id,
                "title": row.title
            ], alwaysPersist: true)
            return
        }
        // The row ID comes from the phone-authored QueueSnapshot and is the
        // exact identity present in the TV projection. A reconstructed local
        // Episode can legitimately carry a different subscription-scoped key;
        // using that derived key was why the old optimistic move found no row.
        let derivedEpisodeKey = PlaybackPositionStore.key(for: episode)
        let request = QueuePlayNextRequest(
            action: .playNext,
            episodeKey: row.id,
            subscriptionID: row.subscriptionID,
            episodeTitle: row.title
        )
        enqueuePendingPlayNextRequest(request)
        queueModel.pendingPlayNextEpisodeKey = request.episodeKey
        queueModel.pendingUnpinEpisodeKeys.remove(request.episodeKey)
        let previousFirstKey = upNextItems.first?.episodeKey ?? "none"
        let matchedIndex = upNextItems.firstIndex { $0.episodeKey == request.episodeKey }
        let locallyPinnedItems = TVQueueProjector.pinToFront(
            upNextItems,
            episodeKey: request.episodeKey
        )
        upNextItems = locallyPinnedItems
        upNextEpisodes = locallyPinnedItems.compactMap(\.episode)
        queueRows = TVQueueProjector.rows(
            from: locallyPinnedItems,
            subscriptionsByID: subscriptionsByID
        )
        AppLogger.shared.info("tv.playNextPinnedLocally", "Pinned Play Next immediately on Apple TV", metadata: [
            "afterFirstKey": locallyPinnedItems.first?.episodeKey ?? "none",
            "beforeFirstKey": previousFirstKey,
            "changed": "\(previousFirstKey != locallyPinnedItems.first?.episodeKey)",
            "derivedEpisodeKey": derivedEpisodeKey,
            "episodeSubscriptionID": episode.subscriptionID.uuidString,
            "requestID": request.id.uuidString,
            "requestKey": request.episodeKey,
            "rowSubscriptionID": row.subscriptionID.uuidString,
            "matchedIndex": matchedIndex.map(String.init) ?? "none",
            "episode": episode.title,
            "rowCount": "\(locallyPinnedItems.count)"
        ], alwaysPersist: true)

        guard let engine = cloudSyncEngine, engine.isActivated else {
            AppLogger.shared.warning("tv.playNextUnavailable", "Play Next is pinned locally but iCloud is not active", metadata: [
                "episode": episode.title,
                "requestID": request.id.uuidString,
                "requestKey": request.episodeKey
            ], alwaysPersist: true)
            return
        }
        guard await engine.submitPlayNextRequest(request) else { return }
        removePendingPlayNextRequest(id: request.id)
        AppLogger.shared.info("tv.playNextRequested", "Requested Play Next from Apple TV", metadata: [
            "requestID": request.id.uuidString,
            "episode": episode.title,
            "requestKey": request.episodeKey
        ], alwaysPersist: true)
    }

    /// Mirrors iPhone Unpin: remove either Play Next or Play Last status,
    /// restore the episode's natural Priority Stack position immediately, and
    /// ask the phone authority to persist and republish that state via iCloud.
    func requestUnpin(_ row: TVQueueRowModel) async {
        guard row.episode != nil, row.pinState != nil else {
            AppLogger.shared.warning("tv.unpinRejected", "Unpin row has no resolved pinned episode", metadata: [
                "rowKey": row.id,
                "title": row.title
            ], alwaysPersist: true)
            return
        }
        let request = QueuePlayNextRequest(
            action: .unpin,
            episodeKey: row.id,
            subscriptionID: row.subscriptionID,
            episodeTitle: row.title
        )
        enqueuePendingPlayNextRequest(request)
        if queueModel.pendingPlayNextEpisodeKey == row.id {
            queueModel.pendingPlayNextEpisodeKey = nil
        }
        queueModel.pendingUnpinEpisodeKeys.insert(row.id)
        let previousIndex = upNextItems.firstIndex { $0.episodeKey == row.id }
        let locallyUnpinnedItems = TVQueueProjector.unpin(
            upNextItems,
            episodeKey: row.id,
            subscriptionsByID: subscriptionsByID
        )
        upNextItems = locallyUnpinnedItems
        upNextEpisodes = locallyUnpinnedItems.compactMap(\.episode)
        queueRows = TVQueueProjector.rows(
            from: locallyUnpinnedItems,
            subscriptionsByID: subscriptionsByID
        )
        AppLogger.shared.info("tv.unpinAppliedLocally", "Unpinned episode immediately on Apple TV", metadata: [
            "afterIndex": locallyUnpinnedItems.firstIndex { $0.episodeKey == row.id }.map(String.init) ?? "none",
            "beforeIndex": previousIndex.map(String.init) ?? "none",
            "episode": row.title,
            "requestID": request.id.uuidString,
            "requestKey": request.episodeKey
        ], alwaysPersist: true)

        guard let engine = cloudSyncEngine, engine.isActivated else {
            AppLogger.shared.warning("tv.unpinUnavailable", "Episode is unpinned locally but iCloud is not active", metadata: [
                "episode": row.title,
                "requestID": request.id.uuidString
            ], alwaysPersist: true)
            return
        }
        guard await engine.submitPlayNextRequest(request) else { return }
        removePendingPlayNextRequest(id: request.id)
        AppLogger.shared.info("tv.unpinRequested", "Requested Unpin from Apple TV", metadata: [
            "episode": row.title,
            "requestID": request.id.uuidString,
            "requestKey": request.episodeKey
        ], alwaysPersist: true)
    }

    func materializeRemoteSubscription(_ state: SubscriptionSyncState) async {
        let entry = SurvivalKitEntry(
            subscriptionID: state.subscriptionID,
            feedURL: state.feedURL,
            priorityRank: state.priorityRank,
            title: state.title
        )
        rememberMaterializationCandidate(entry)
        let succeeded = await materializeFeed(
            url: state.feedURL,
            subscriptionID: state.subscriptionID,
            priorityRank: state.priorityRank
        )
        if succeeded {
            subscriptionStore.applyRemoteSubscriptionState(state)
        } else {
            scheduleMaterializationRetry(entry)
        }
        refreshLibrary()
    }

    /// Targeted library prime, retried until the engine has finished its async
    /// activation (account status check). Fetches all subscription records
    /// (kicking off materialisation) AND the Up Next queue snapshot directly,
    /// bypassing the cold-start delta stream. Call at launch and on foreground
    /// so the Library populates fast and Up Next mirrors the phone quickly.
    /// Idempotent — re-priming on foreground also picks up subscriptions added
    /// on the phone since the last launch.
    func primeLibraryFromCloudSoon(reason: String) async {
        // ~15 s of retries at 1 s intervals — enough for the account check +
        // activation; gives up quietly if sync never comes up (e.g. no iCloud).
        for _ in 0..<15 {
            guard let engine = cloudSyncEngine, engine.isActivated else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            await flushPendingPlayNextRequests(using: engine)
            // ORDER MATTERS (reordered 2026-07-11, Kevin's real-device round 5:
            // "old shows in Up Next for ~30 s" + a stale Resume card): the queue
            // snapshot and listening history are each ONE cheap targeted fetch,
            // while fetchAllSubscriptionsNow paginates all 113 subscription
            // records. Fetching the cheap, user-facing state FIRST and rendering
            // immediately means Up Next and Continue Listening are phone-correct
            // within a couple of seconds; the subscription sweep then fills in
            // catalogs behind it (each landing record re-renders via the store
            // observer).
            syncStatus = .updating
            retryPendingMaterializationsNow()
            let fetched = await engine.fetchQueueSnapshotNow(reason: reason)
            refreshLibrary()
            // Queue truth is independent of the much larger first-time Library
            // and history queries. Report Up Next current as soon as its
            // singleton lands instead of showing “Updating” for the entire
            // ten-minute cold-zone materialization.
            if let snapshot = subscriptionStore.syncedQueueSnapshot() {
                syncStatus = .upToDate(snapshot.updatedAt, generation: snapshot.generation)
            } else if !fetched {
                syncStatus = .unavailable
            }

            let shouldFetchHistory = syncCoordinator.shouldPrimeHistory(maximumAge: 15 * 60)
                || reason == "launch"
            // One full membership sweep repairs subscriptions that disappeared
            // before durable materialisation shipped and therefore are absent
            // from both the current database and old survival kit. Manual Check
            // for Updates is also an explicit request for this authoritative
            // sweep; ordinary foreground activation remains projection-only.
            let needsDurableMaterializationMigration = !UserDefaults.standard.bool(
                forKey: durableMaterializationMigrationKey
            )
            let shouldFetchSubscriptions = reason == "bootstrap"
                || reason == "tv.manualRetry"
                || librarySubscriptions.isEmpty
                || needsDurableMaterializationMigration
            let migrationKey = durableMaterializationMigrationKey
            let historyTask = shouldFetchHistory
                ? sharedRecentHistoryPrime(engine: engine, reason: reason)
                : nil
            let subscriptionTask = shouldFetchSubscriptions ? Task { [weak self] in
                _ = await engine.fetchAllSubscriptionsNow(reason: reason)
                if needsDurableMaterializationMigration {
                    UserDefaults.standard.set(true, forKey: migrationKey)
                }
                self?.refreshLibrary()
            } : nil
            // A foreground queue/history recovery must not re-download and
            // reapply the complete subscription zone. Bootstrap owns the full
            // library prime; later activations use compact projections only.
            if let subscriptionTask { await subscriptionTask.value }
            if let historyTask { _ = await historyTask.value }
            refreshLibrary()
            // Phase 2: projection-first TV does not sweep the entire RSS
            // library. Queue v2 is self-contained; targeted detail enrichment
            // may fetch one feed in a later phase, but sync never triggers an
            // all-subscription network/parse pass.
            return
        }
        syncStatus = subscriptionStore.syncedQueueSnapshot().map {
            .cached($0.updatedAt, generation: $0.generation)
        } ?? .unavailable
    }

    // AI CONTEXT — Queue commands use a tiny durable tvOS outbox. The UI is
    // immediate and local; these requests guarantee eventual delivery when
    // CloudKit activation or connectivity is temporarily unavailable. Saving
    // the same UUID again is safe because its record ID is stable and the
    // phone-side consumer is idempotent.
    private func pendingPlayNextRequests() -> [QueuePlayNextRequest] {
        guard let data = UserDefaults.standard.data(forKey: pendingPlayNextRequestsDefaultsKey),
              let requests = try? JSONDecoder().decode([QueuePlayNextRequest].self, from: data)
        else { return [] }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    private func savePendingPlayNextRequests(_ requests: [QueuePlayNextRequest]) {
        if requests.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingPlayNextRequestsDefaultsKey)
        } else if let data = try? JSONEncoder().encode(requests) {
            UserDefaults.standard.set(data, forKey: pendingPlayNextRequestsDefaultsKey)
        }
    }

    private func enqueuePendingPlayNextRequest(_ request: QueuePlayNextRequest) {
        var requests = pendingPlayNextRequests()
        // One episode can have only one pending pin intent. When Apple TV is
        // offline, the latest user choice (Pin or Unpin) replaces an older
        // queued choice instead of replaying contradictory commands later.
        requests.removeAll { $0.id == request.id || $0.episodeKey == request.episodeKey }
        requests.append(request)
        savePendingPlayNextRequests(Array(requests.suffix(20)))
    }

    private func removePendingPlayNextRequest(id: UUID) {
        savePendingPlayNextRequests(pendingPlayNextRequests().filter { $0.id != id })
    }

    private func restorePendingPlayNextOverlay() {
        let requests = pendingPlayNextRequests()
        queueModel.pendingPlayNextEpisodeKey = requests.last(where: { $0.action == .playNext })?.episodeKey
        queueModel.pendingUnpinEpisodeKeys = Set(
            requests.filter { $0.action == .unpin }.map(\.episodeKey)
        )
    }

    private func flushPendingPlayNextRequests(using engine: CloudSyncEngine) async {
        for request in pendingPlayNextRequests() {
            guard await engine.submitPlayNextRequest(request) else { return }
            removePendingPlayNextRequest(id: request.id)
            AppLogger.shared.info("tv.queueCommandOutboxFlushed", "Delivered pending Apple TV queue command", metadata: [
                "action": request.action.rawValue,
                "requestID": request.id.uuidString,
                "episode": request.episodeTitle
            ], alwaysPersist: true)
        }
    }

    // MARK: - Library state + kit write-back

    /// Mirrors scenePhase — set by AutohopTVApp's onChange. Gates the
    /// freshness poll below so a backgrounded TV app isn't fetching.
    var isSceneActive: Bool {
        get { syncCoordinator.isSceneActive }
        set { syncCoordinator.isSceneActive = newValue }
    }

    /// CONTINUE-LISTENING FRESHNESS SAFETY NET. CloudKit changes are the primary
    /// path. While frontmost, the TV uses the bounded
    /// TVForegroundSyncPolicy fallback so a missed notification cannot leave
    /// Home/Up Next stale for the former five-to-ten-minute window. Equality
    /// guards keep a no-change poll render-free.
    func startForegroundFreshnessPolling() {
        syncCoordinator.startForegroundPolling { [weak self] in
            await self?.performForegroundFreshnessPoll()
        }
    }

    func performForegroundFreshnessPoll() async {
        guard isSceneActive, let engine = cloudSyncEngine, engine.isActivated else { return }
        let snapshot = subscriptionStore.syncedQueueSnapshot()
        let shouldFetchQueue = TVForegroundSyncPolicy.shouldFetch(
            snapshotUpdatedAt: snapshot?.updatedAt
        )
        let shouldFetchHistory = syncCoordinator.shouldPrimeHistory(
            maximumAge: TVForegroundSyncPolicy.maximumSnapshotAge
        )
        guard shouldFetchQueue || shouldFetchHistory else { return }

        syncStatus = .updating
        if shouldFetchQueue {
            _ = await engine.fetchQueueSnapshotNow(reason: "tv.freshnessPoll")
        }
        if shouldFetchHistory {
            _ = await syncCoordinator.sharedRecentHistoryPrime(reason: "tv.freshnessPoll")?.value
            historyNeedsReload = true
            historyModel.invalidate()
        }
        refreshLibrary()
        if let snapshot = subscriptionStore.syncedQueueSnapshot() {
            syncStatus = .upToDate(snapshot.updatedAt, generation: snapshot.generation)
        }
    }

    /// One owner for launch/foreground history recovery. Scene activation can
    /// race bootstrap while the first CloudKit query is still in flight; the
    /// old code started a second ~3,000-record sweep because
    /// `lastHistoryPrimeAt` changed only after completion.
    func sharedRecentHistoryPrime(
        engine: CloudSyncEngine,
        reason: String
    ) -> Task<Int, Never> {
        // `engine` remains in the signature while callers migrate; the single
        // engine owner is now TVSyncCoordinator.
        _ = engine
        return syncCoordinator.sharedRecentHistoryPrime(reason: reason)
            ?? Task { 0 }
    }

}
