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
        if enabled { engine.start() }
    }

    func syncEnabledChanged(_ enabled: Bool) {
        installCallbacksIfNeeded()
        engine.syncEnabledChanged(enabled)
    }

    func flushDeferredPushes(reason: String) {
        engine.flushDeferredPushes(reason: reason)
    }

    func fetchAllNow(reason: String) async {
        await engine.fetchAllSubscriptionsNow(reason: reason)
        await engine.fetchAllHistoryNow(reason: reason)
    }

    func primeSubscriptionsNow(reason: String) async {
        await engine.fetchAllSubscriptionsNow(reason: reason)
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
            logger.warning("sync.playNextUnresolved", "Could not resolve companion Play Next request", metadata: [
                "requestID": request.id.uuidString,
                "episode": request.episodeTitle,
                "subscriptionID": request.subscriptionID.uuidString
            ], alwaysPersist: true)
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
        processed.append(request.id.uuidString)
        if processed.count > 50 { processed.removeFirst(processed.count - 50) }
        UserDefaults.standard.set(processed, forKey: processedKey)
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
        } catch {
            logger.error("sync.materializeFailed", "Could not materialise synced subscription", metadata: [
                "feedHost": state.feedURL.host ?? "unknown"
            ])
        }
    }
}
