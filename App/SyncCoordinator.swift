//
//  SyncCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 10 exclusive iOS owner of CloudSyncEngine construction, callback
//  installation, opt-in lifecycle, remote subscription materialization,
//  history/Stats routing, active-player identity protection, deferred pushes,
//  and explicit Relay sync-nudge pulls.
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
    private let logger: AppLogger
    private var currentEpisodeProvider: () -> Episode? = { nil }
    private weak var relayCoordinator: RelayCoordinator?
    private var callbacksInstalled = false

    init(
        feedService: FeedServicing,
        subscriptionStore: SubscriptionStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        logger: AppLogger? = nil
    ) {
        self.feedService = feedService
        self.subscriptionStore = subscriptionStore
        self.historyStatsCoordinator = historyStatsCoordinator
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

    /// Connects successful CloudKit pushes to the optional Relay nudge policy.
    /// The CloudSyncEngine callback remains private to this domain owner.
    func installRelayNudge(_ relayCoordinator: RelayCoordinator) {
        self.relayCoordinator = relayCoordinator
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
        engine.onLocalChangesPushed = { [weak self] in
            await MainActor.run {
                self?.relayCoordinator?.localChangesPushed()
            }
        }
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
                reindexRanks: false
            )
            subscriptionStore.updateEpisodes(
                subscriptionID: state.subscriptionID,
                episodes: result.episodes
            )
            subscriptionStore.applyRemoteSubscriptionState(state)
        } catch {
            logger.error("sync.materializeFailed", "Could not materialise synced subscription", metadata: [
                "url": state.feedURL.absoluteString
            ])
        }
    }
}
