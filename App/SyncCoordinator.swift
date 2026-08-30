//
//  SyncCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 10 exclusive iOS owner of CloudSyncEngine construction, callback
//  installation, opt-in lifecycle, remote subscription materialization,
//  history/Stats routing, active-player identity protection, and deferred
//  private-iCloud pushes.
//
//  PRODUCTION BOOTSTRAP: primeSubscriptionsNow is called on iPhone foreground
//  re-entry. CloudSyncEngine also primes once after activation. Keep both: the
//  activation query establishes the normal fast path, while foreground retries
//  a transient zone/network failure. The engine's capability guard guarantees
//  this authority operation cannot run from tvOS.
//
//  This extraction does not change CloudKit containers, record types, keys,
//  identity, merge policy, pending-row durability, or platform authorship.
//  Download/media state never enters CloudKit. AppState retains only thin
//  lifecycle/AppDelegate-compatible commands.
//  Failed iPhone RSS materialisation is retried from the durable local remote
//  projection; never assume CloudKit will redeliver an unchanged record after
//  its change token advances. Unresolvable tvOS queue commands expire after the
//  policy lifetime and persistent warnings are rate-limited.
//

import Foundation

@MainActor
final class SyncCoordinator {
    static let cloudKitContainerID = "iCloud.com.kevinperry.autohop"

    private let engine: CloudSyncEngine
    private let feedService: FeedServicing
    private let subscriptionStore: SubscriptionStore
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let queueCoordinator: QueueCoordinator
    private let logger: AppLogger
    private var currentEpisodeProvider: () -> Episode? = { nil }
    private var callbacksInstalled = false
    private var materializationRetryTasks: [UUID: Task<Void, Never>] = [:]

    private struct PendingMaterialization: Codable {
        var subscriptionID: UUID
        var attempts: Int
        var nextAttemptAt: Date
    }

    private struct QueueCommandWarning: Codable {
        var requestID: UUID
        var lastLoggedAt: Date
    }

    private let materializationRetryKey = "com.autohop.sync.pendingMaterializations.v1"
    private let queueCommandWarningKey = "com.autohop.sync.queueCommandWarnings.v1"

    init(
        feedService: FeedServicing,
        subscriptionStore: SubscriptionStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        queueCoordinator: QueueCoordinator,
        logger: AppLogger? = nil
    ) {
        self.feedService = feedService
        self.subscriptionStore = subscriptionStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.queueCoordinator = queueCoordinator
        self.logger = logger ?? .shared
        self.engine = CloudSyncEngine(
            containerIdentifier: Self.cloudKitContainerID,
            subscriptionStore: subscriptionStore,
            database: subscriptionStore.database
        )
    }

    func observePlayback(_ playbackCoordinator: PlaybackCoordinator) {
        currentEpisodeProvider = { [weak playbackCoordinator] in
            playbackCoordinator?.engine.currentEpisode
        }
        subscriptionStore.nowPlayingEpisodeSyncKeyProvider = { [weak self] in
            guard let episode = self?.currentEpisodeProvider() else { return nil }
            return EpisodeSyncState.syncKey(
                subscriptionID: episode.subscriptionID,
                guid: episode.guid
            )
        }
    }

    func startIfEnabled(_ enabled: Bool) {
        installCallbacksIfNeeded()
        if enabled {
            engine.start()
            Task { await retryPendingMaterializations(reason: "sync.start", force: true) }
        } else {
            cancelScheduledMaterializationRetries()
        }
    }

    func syncEnabledChanged(_ enabled: Bool) {
        installCallbacksIfNeeded()
        engine.syncEnabledChanged(enabled)
        if enabled {
            Task { await retryPendingMaterializations(reason: "sync.enabled", force: true) }
        } else {
            cancelScheduledMaterializationRetries()
        }
    }

    func flushDeferredPushes(reason: String) {
        engine.flushDeferredPushes(reason: reason)
    }

    func fetchAllNow(reason: String) async {
        await engine.fetchAllSubscriptionsNow(reason: reason)
        await engine.fetchAllHistoryNow(reason: reason)
        await retryPendingMaterializations(reason: reason, force: true)
    }

    func primeSubscriptionsNow(reason: String) async {
        await engine.fetchAllSubscriptionsNow(reason: reason)
        await retryPendingMaterializations(reason: reason, force: true)
    }

    private func installCallbacksIfNeeded() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true
        engine.onSubscriptionNeedsMaterialization = { [weak self] state in
            await self?.materializeRemoteSubscription(state)
        }
        engine.onRemoteHistoryEntry = { [weak self] entry in
            self?.historyStatsCoordinator.applyRemoteHistory(entry)
        }
        engine.onRemoteStatsChanged = { [weak self] in
            self?.historyStatsCoordinator.reloadRemoteStats()
        }
        engine.onRemotePlayNextRequest = { [weak self] request in
            await self?.applyRemoteQueueCommand(request) ?? false
        }
    }

    private func applyRemoteQueueCommand(_ request: QueuePlayNextRequest) async -> Bool {
        let processedKey = "com.autohop.sync.processedPlayNextRequests.v1"
        var processed = UserDefaults.standard.stringArray(forKey: processedKey) ?? []
        if processed.contains(request.id.uuidString) { return true }

        guard let subscription = subscriptionStore.subscription(id: request.subscriptionID),
              let episode = (subscription.episodes + [subscription.latestEpisode].compactMap { $0 })
                .first(where: { PlaybackPositionStore.key(for: $0) == request.episodeKey })
        else {
            if QueueCommandResolutionPolicy.isExpired(createdAt: request.createdAt) {
                markQueueCommandProcessed(request.id, processed: &processed)
                removeQueueCommandWarning(request.id)
                logger.warning("sync.queueCommandExpired", "Expired an unresolvable Apple TV queue command", metadata: [
                    "requestID": request.id.uuidString,
                    "action": request.action.rawValue,
                    "ageHours": "\(Int(Date().timeIntervalSince(request.createdAt) / 3600))"
                ], alwaysPersist: true)
                return true
            }
            let shouldPersist = shouldPersistQueueCommandWarning(request.id)
            logger.warning("sync.playNextUnresolved", "Could not resolve companion Play Next request", metadata: [
                "requestID": request.id.uuidString,
                "episode": request.episodeTitle,
                "subscriptionID": request.subscriptionID.uuidString,
                "persistentWarning": shouldPersist ? "true" : "suppressed"
            ], alwaysPersist: shouldPersist)
            return false
        }

        let previousPinState: QueuePinState? = if queueCoordinator.isPinnedNext(episode) {
            .playNext
        } else if queueCoordinator.isPinnedLast(episode) {
            .playLast
        } else {
            nil
        }
        switch request.action {
        case .playNext:
            queueCoordinator.playNext(episode)
        case .unpin:
            queueCoordinator.unpin(episode)
        }
        markQueueCommandProcessed(request.id, processed: &processed)
        removeQueueCommandWarning(request.id)
        logger.info("sync.queueCommandApplied", "Applied Apple TV queue command", metadata: [
            "action": request.action.rawValue,
            "requestID": request.id.uuidString,
            "requestKey": request.episodeKey,
            "sourceDeviceID": request.sourceDeviceID,
            "previousPinState": previousPinState?.rawValue ?? "none",
            "episode": episode.title
        ], alwaysPersist: true)
        return true
    }

    private func materializeRemoteSubscription(_ state: SubscriptionSyncState) async {
        if state.subscribed == false
            || subscriptionStore.subscriptions.contains(where: { $0.feedURL == state.feedURL }) {
            subscriptionStore.applyRemoteSubscriptionState(state)
            removePendingMaterialization(state.subscriptionID)
            return
        }

        do {
            let result = try await feedService.refresh(
                feedURL: state.feedURL,
                subscriptionID: state.subscriptionID,
                episodeLimit: 50
            )
            _ = try subscriptionStore.addSubscription(
                id: state.subscriptionID,
                feedURL: state.feedURL,
                title: result.subscriptionTitle,
                description: result.description,
                author: result.author,
                artworkURL: result.artworkURL,
                categories: result.categories,
                isExplicit: result.isExplicit,
                latestEpisode: result.latestEpisode,
                insertAtBottom: true,
                reindexRanks: false,
                initialNotificationsEnabled: state.notificationsEnabled
            )
            subscriptionStore.updateEpisodes(
                subscriptionID: state.subscriptionID,
                episodes: result.episodes
            )
            subscriptionStore.applyRemoteSubscriptionState(state)
            removePendingMaterialization(state.subscriptionID)
        } catch {
            logger.error("sync.materializeFailed", "Could not materialise synced subscription", metadata: [
                "feedHost": state.feedURL.host ?? "unknown"
            ])
            enqueueMaterializationRetry(state.subscriptionID)
        }
    }

    private func markQueueCommandProcessed(_ id: UUID, processed: inout [String]) {
        processed.append(id.uuidString)
        if processed.count > 50 { processed.removeFirst(processed.count - 50) }
        UserDefaults.standard.set(processed, forKey: "com.autohop.sync.processedPlayNextRequests.v1")
    }

    private func queueCommandWarnings() -> [QueueCommandWarning] {
        guard let data = UserDefaults.standard.data(forKey: queueCommandWarningKey) else { return [] }
        return (try? JSONDecoder().decode([QueueCommandWarning].self, from: data)) ?? []
    }

    private func shouldPersistQueueCommandWarning(_ id: UUID, now: Date = Date()) -> Bool {
        var warnings = queueCommandWarnings().filter {
            now.timeIntervalSince($0.lastLoggedAt) < QueueCommandResolutionPolicy.unresolvedLifetime
        }
        let previous = warnings.first(where: { $0.requestID == id })?.lastLoggedAt
        let shouldPersist = QueueCommandResolutionPolicy.shouldPersistWarning(lastLoggedAt: previous, now: now)
        if shouldPersist {
            warnings.removeAll { $0.requestID == id }
            warnings.append(QueueCommandWarning(requestID: id, lastLoggedAt: now))
            if let data = try? JSONEncoder().encode(warnings) {
                UserDefaults.standard.set(data, forKey: queueCommandWarningKey)
            }
        }
        return shouldPersist
    }

    private func removeQueueCommandWarning(_ id: UUID) {
        let warnings = queueCommandWarnings().filter { $0.requestID != id }
        if let data = try? JSONEncoder().encode(warnings) {
            UserDefaults.standard.set(data, forKey: queueCommandWarningKey)
        }
    }

    private func pendingMaterializations() -> [PendingMaterialization] {
        guard let data = UserDefaults.standard.data(forKey: materializationRetryKey) else { return [] }
        return (try? JSONDecoder().decode([PendingMaterialization].self, from: data)) ?? []
    }

    private func savePendingMaterializations(_ pending: [PendingMaterialization]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: materializationRetryKey)
    }

    private func enqueueMaterializationRetry(_ id: UUID) {
        var pending = pendingMaterializations()
        let attempts = (pending.first(where: { $0.subscriptionID == id })?.attempts ?? 0) + 1
        let delays: [TimeInterval] = [30, 120, 600, 900]
        let delay = delays[min(attempts - 1, delays.count - 1)]
        pending.removeAll { $0.subscriptionID == id }
        pending.append(PendingMaterialization(
            subscriptionID: id,
            attempts: attempts,
            nextAttemptAt: Date().addingTimeInterval(delay)
        ))
        savePendingMaterializations(pending)
        scheduleMaterializationRetry(id: id, delay: delay)
    }

    private func scheduleMaterializationRetry(id: UUID, delay: TimeInterval) {
        materializationRetryTasks[id]?.cancel()
        materializationRetryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retryMaterialization(id: id, reason: "retry.timer")
        }
    }

    private func retryPendingMaterializations(reason: String, force: Bool) async {
        let now = Date()
        // Recover clean projections left by failures from builds that predate
        // the explicit retry queue. Token advancement means CloudKit may never
        // deliver those unchanged records again.
        let pendingAtStart = pendingMaterializations()
        let queuedIDs = Set(pendingAtStart.map(\.subscriptionID))
        for state in subscriptionStore.unmaterializedSyncedSubscriptionStates()
        where !queuedIDs.contains(state.subscriptionID) {
            await materializeRemoteSubscription(state)
        }
        for pending in pendingAtStart
        where force || pending.nextAttemptAt <= now {
            await retryMaterialization(id: pending.subscriptionID, reason: reason)
        }
    }

    private func retryMaterialization(id: UUID, reason: String) async {
        guard subscriptionStore.subscription(id: id) == nil,
              let state = subscriptionStore.syncedSubscriptionState(id: id),
              state.subscribed else {
            removePendingMaterialization(id)
            return
        }
        logger.info("sync.materializeRetry", "Retrying synced subscription materialisation", metadata: [
            "reason": reason,
            "feedHost": state.feedURL.host ?? "unknown"
        ])
        await materializeRemoteSubscription(state)
    }

    private func removePendingMaterialization(_ id: UUID) {
        materializationRetryTasks[id]?.cancel()
        materializationRetryTasks[id] = nil
        var pending = pendingMaterializations()
        pending.removeAll { $0.subscriptionID == id }
        savePendingMaterializations(pending)
    }

    private func cancelScheduledMaterializationRetries() {
        materializationRetryTasks.values.forEach { $0.cancel() }
        materializationRetryTasks.removeAll()
    }
}
