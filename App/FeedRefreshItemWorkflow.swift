import Foundation

// AI CONTEXT — App/FeedRefreshItemWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Exclusive transaction for refreshing and merging one podcast feed. It owns
// conditional HTTP validators, unchanged-fetch accounting, eligible release
// observation learning, old-latest media cleanup, rolling one-item replacement,
// autorelease-scoped metadata/episode merge, browse-preview isolation, Up Next
// invalidation, automatic-download candidate scheduling, failure backoff, and
// per-feed resource diagnostics.
//
// ORDERING:
// - Validators and observations commit before the episode merge.
// - Obsolete latest media is protected when it is currently playing.
// - Browse previews merge display data but stop before queue/download effects.
// - Automatic intent scheduling happens only after the authoritative merged
//   subscription is re-read.
// - Inactive-app transport drops do not poison feed-health backoff.
//
// This workflow refreshes exactly one feed. Cycle budgeting, joining,
// cancellation, fairness backlog, and memory batching belong to the cycle owner.

@MainActor
final class FeedRefreshItemWorkflow {
    private let feedService: any FeedServicing
    private let subscriptionStore: SubscriptionStore
    private let downloadManager: any DownloadManaging
    private let playback: PlaybackCoordinator
    private let feedRefreshCoordinator: FeedRefreshCoordinator
    private let downloadActionsWorkflow: DownloadActionsWorkflow
    private let autoDownloadIntentWorkflow: AutoDownloadIntentWorkflow
    private let queueCoordinator: QueueCoordinator
    private let releaseRadarWorkflow: ReleaseRadarWorkflow
    private let logger: AppLogger
    private let failureBackoffInterval: TimeInterval
    private let runtimeWorkflow: AppRuntimeWorkflow

    init(
        feedService: any FeedServicing,
        subscriptionStore: SubscriptionStore,
        downloadManager: any DownloadManaging,
        playback: PlaybackCoordinator,
        feedRefreshCoordinator: FeedRefreshCoordinator,
        downloadActionsWorkflow: DownloadActionsWorkflow,
        autoDownloadIntentWorkflow: AutoDownloadIntentWorkflow,
        queueCoordinator: QueueCoordinator,
        releaseRadarWorkflow: ReleaseRadarWorkflow,
        logger: AppLogger,
        failureBackoffInterval: TimeInterval,
        runtimeWorkflow: AppRuntimeWorkflow
    ) {
        self.feedService = feedService
        self.subscriptionStore = subscriptionStore
        self.downloadManager = downloadManager
        self.playback = playback
        self.feedRefreshCoordinator = feedRefreshCoordinator
        self.downloadActionsWorkflow = downloadActionsWorkflow
        self.autoDownloadIntentWorkflow = autoDownloadIntentWorkflow
        self.queueCoordinator = queueCoordinator
        self.releaseRadarWorkflow = releaseRadarWorkflow
        self.logger = logger
        self.failureBackoffInterval = failureBackoffInterval
        self.runtimeWorkflow = runtimeWorkflow
    }

    func refresh(
        _ subscription: Subscription,
        episodeLimit: Int?,
        refreshUpNextAfterMerge: Bool
    ) async {
        runtimeWorkflow.logResourceSnapshot(
            reason: "feed.refresh.before",
            extra: releaseRadarWorkflow.feedMetadata(
                for: subscription,
                includeURL: false
            ),
            force: false
        )
        logger.info(
            "feed.refresh",
            "Refreshing podcast feed",
            metadata: releaseRadarWorkflow.feedMetadata(for: subscription)
        )
        let knownKeys = Set(
            subscription.episodes.map(
                RefreshStats.releaseObservationKey(for:)
            )
        )
        do {
            let outcome = try await feedService.refreshIfModified(
                feedURL: subscription.feedURL,
                subscriptionID: subscription.id,
                episodeLimit: episodeLimit,
                validators: FeedValidators(
                    etag: subscription.refreshStats.etag,
                    lastModified: subscription.refreshStats.lastModified
                )
            )
            feedRefreshCoordinator.failureBackoffUntil.removeValue(
                forKey: subscription.id
            )
            guard case .updated(let result, let validators) = outcome else {
                var stats = subscription.refreshStats
                stats.recordFetch(foundNewEpisode: false)
                subscriptionStore.updateRefreshStats(
                    subscriptionID: subscription.id,
                    stats: stats
                )
                logger.info(
                    "feed.notModified",
                    "Feed unchanged (304)",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false
                    )
                )
                return
            }

            let oldLatestGUID = subscription.latestEpisode?.guid
            var stats = subscription.refreshStats
            stats.etag = validators.etag
            stats.lastModified = validators.lastModified
            let filters = subscriptionStore.subscription(id: subscription.id)?
                .downloadFilterSettings ?? subscription.downloadFilterSettings
            let newlyObserved = stats.recordEpisodeObservations(
                result.episodes,
                previouslyKnownEpisodeKeys: knownKeys,
                downloadFilterSettings: filters
            )
            let newEligibleEpisode = result.episodes.first {
                !knownKeys.contains(
                    RefreshStats.releaseObservationKey(for: $0)
                ) && filters.evaluation(for: $0).isIncluded
            }
            let latestChanged = oldLatestGUID != result.latestEpisode.guid
            let latestChangedEligible = latestChanged
                && filters.evaluation(for: result.latestEpisode).isIncluded
            stats.recordFetch(
                foundNewEpisode:
                    newEligibleEpisode != nil || latestChangedEligible,
                publishedAt: newEligibleEpisode?.publishedAt
                    ?? (latestChangedEligible
                        ? result.latestEpisode.publishedAt
                        : nil)
            )
            subscriptionStore.updateRefreshStats(
                subscriptionID: subscription.id,
                stats: stats
            )
            let oldLatestWasDownloaded =
                subscription.latestEpisode?.downloadState == .downloaded

            if let oldLatest = subscription.latestEpisode,
               latestChanged,
               playback.currentEpisode?.id != oldLatest.id {
                if oldLatest.localFileURL != nil {
                    logger.info(
                        "feed.cleanupOldLatest",
                        "Deleting old latest episode after new feed item",
                        metadata: releaseRadarWorkflow.feedMetadata(
                            for: subscription,
                            includeURL: false,
                            extra: ["episode": oldLatest.title]
                        )
                    )
                    try? await downloadManager.deleteLocalFile(for: oldLatest)
                    subscriptionStore.markEpisodeNotDownloaded(
                        subscriptionID: oldLatest.subscriptionID,
                        episodeID: oldLatest.id
                    )
                }
                downloadActionsWorkflow
                    .cleanupSupersededRollingLatestIfNeeded(
                        oldLatest: oldLatest,
                        newLatest: result.latestEpisode,
                        feedEpisodeCount: result.episodes.count,
                        subscription: subscription,
                        baseMetadata: releaseRadarWorkflow.feedMetadata(
                            for: subscription,
                            includeURL: false
                        )
                    )
            }

            logger.info(
                "feed.refreshMerge",
                "Merging refreshed feed episodes",
                metadata: releaseRadarWorkflow.feedMetadata(
                    for: subscription,
                    includeURL: false,
                    extra: [
                        "oldLatest": oldLatestGUID ?? "none",
                        "newLatest": result.latestEpisode.guid,
                        "episodeCount": "\(result.episodes.count)",
                        "newlyObservedEpisodes": "\(newlyObserved)",
                        "latestChanged": "\(latestChanged)",
                        "releaseSignal":
                            "\(newEligibleEpisode != nil || latestChangedEligible)"
                    ]
                )
            )
            autoreleasepool {
                subscriptionStore.updateEpisodes(
                    subscriptionID: subscription.id,
                    episodes: result.episodes
                )
                if let artworkURL = result.artworkURL {
                    subscriptionStore.updateArtworkURL(
                        subscriptionID: subscription.id,
                        artworkURL: artworkURL
                    )
                }
                subscriptionStore.updateAuthor(
                    subscriptionID: subscription.id,
                    author: result.author
                )
                subscriptionStore.updateDescription(
                    subscriptionID: subscription.id,
                    description: result.description
                )
                subscriptionStore.updateCategories(
                    subscriptionID: subscription.id,
                    categories: result.categories
                )
                subscriptionStore.updateIsExplicit(
                    subscriptionID: subscription.id,
                    isExplicit: result.isExplicit
                )
            }

            if subscriptionStore.subscription(id: subscription.id)?
                .browseDate != nil {
                logger.info(
                    "feed.refresh",
                    "Skipping auto-download for browse preview",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false
                    )
                )
                return
            }
            if refreshUpNextAfterMerge {
                queueCoordinator.scheduleRecompute(
                    reason: "feed.refresh.\(subscription.title)"
                )
            }
            let updated = subscriptionStore.subscription(id: subscription.id)
            guard let candidate = updated.flatMap({
                autoDownloadIntentWorkflow.newestCandidate(in: $0)
            }) else {
                logger.info(
                    "feed.refresh",
                    "No eligible episode found for auto-download",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false
                    )
                )
                return
            }
            guard result.latestEpisode.guid != oldLatestGUID
                    || oldLatestWasDownloaded == false else {
                logger.info(
                    "feed.refresh",
                    "No new download needed",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false
                    )
                )
                return
            }
            autoDownloadIntentWorkflow.schedule(
                episode: candidate,
                subscriptionID: subscription.id,
                podcastTitle: result.subscriptionTitle,
                refreshUpNextAfterMerge: refreshUpNextAfterMerge
            )
            logger.info(
                "feed.refresh",
                "Feed refresh completed",
                metadata: releaseRadarWorkflow.feedMetadata(
                    for: subscription,
                    includeURL: false,
                    extra: [
                        "podcast": result.subscriptionTitle,
                        "episodeCount": "\(result.episodes.count)",
                        "autoDownload": "scheduled"
                    ]
                )
            )
            runtimeWorkflow.logResourceSnapshot(reason: "feed.refresh.afterSuccess", extra: [
                "podcast": result.subscriptionTitle,
                "subscriptionID": subscription.id.uuidString,
                "feedHash": releaseRadarWorkflow.feedHash(
                    for: subscription.feedURL
                ),
                "episodeCount": "\(result.episodes.count)"
            ], force: false)
        } catch {
            if Self.isCancellationError(error) {
                logger.info(
                    "feed.refreshCancelled",
                    "Feed refresh cancelled",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false
                    )
                )
                return
            }
            if Self.isTransientTransportError(error),
               !runtimeWorkflow.isAppForeground {
                logger.info(
                    "feed.refreshDeferred",
                    "Feed refresh dropped while app inactive — no backoff applied",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false,
                        extra: ["error": String(describing: error)]
                    )
                )
                return
            }
            let backoffUntil = runtimeWorkflow.now.addingTimeInterval(
                failureBackoffInterval
            )
            feedRefreshCoordinator.failureBackoffUntil[subscription.id] =
                backoffUntil
            logger.error(
                "feed.refreshFailed",
                "Feed refresh failed",
                metadata: releaseRadarWorkflow.feedMetadata(
                    for: subscription,
                    includeURL: false,
                    extra: [
                        "error": String(describing: error),
                        "backoffUntil": backoffUntil.formatted(
                            date: .omitted,
                            time: .standard
                        )
                    ]
                )
            )
            runtimeWorkflow.logResourceSnapshot(
                reason: "feed.refresh.afterFailure",
                extra: releaseRadarWorkflow.feedMetadata(
                    for: subscription,
                    includeURL: false
                ),
                force: true
            )
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        if case FeedServiceError.timedOut = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && (
                nsError.code == NSURLErrorTimedOut
                    || nsError.code == NSURLErrorNetworkConnectionLost
            )
    }
}
