import Foundation

// AI CONTEXT — App/FeedRefreshItemWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Exclusive transaction for refreshing and merging one podcast feed. It owns
// conditional HTTP validators, unchanged-fetch accounting, eligible release
// observation learning, old-latest media cleanup, rolling one-item replacement,
// autorelease-scoped metadata/episode merge, browse-preview isolation, Up Next
// invalidation, automatic-download candidate scheduling, failure backoff, and
// per-feed resource diagnostics. Normal diagnostics retain changes, failures,
// backoff, and auto-download decisions; routine request/304/no-op narration is
// verbose-only because FeedRefreshCycleWorkflow emits the correlated cycle
// summary used for foreground/background refresh diagnosis.
//
// ORDERING:
// - Validators and observations commit before the episode merge.
// - A feed merge is one observer-notification transaction. Store setters are
//   equality-guarded, so semantically unchanged HTTP-200 payloads author no
//   persistence or projections. Per-stage timings identify the remaining cost.
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
        var memorySample = ResourceMonitor.shared.memoryFootprintSample()
        let memoryContext = releaseRadarWorkflow.feedMetadata(
            for: subscription,
            includeURL: false
        )
        runtimeWorkflow.logResourceSnapshot(
            reason: "feed.refresh.before",
            extra: releaseRadarWorkflow.feedMetadata(
                for: subscription,
                includeURL: false
            ),
            force: false
        )
        logger.verbose(
            "feed.refresh",
            "Refreshing podcast feed",
            metadata: releaseRadarWorkflow.feedMetadata(
                for: subscription,
                includeURL: false
            )
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
            let parseMemoryBefore = memorySample
            memorySample = ResourceMonitor.shared.logMemoryStageDelta(
                stage: "feed.fetchParse",
                from: memorySample,
                context: memoryContext
            )
            let parseFootprintDelta =
                memorySample.footprintMB - parseMemoryBefore.footprintMB
            let parseResidentDelta =
                memorySample.residentMemoryMB
                    - parseMemoryBefore.residentMemoryMB
            let highMemoryParse =
                parseFootprintDelta >= 200 || parseResidentDelta >= 200
            feedRefreshCoordinator.failureBackoffUntil.removeValue(
                forKey: subscription.id
            )
            guard case .updated(let result, let validators) = outcome else {
                var stats = subscription.refreshStats
                if stats.parseQuarantineUntil.map({
                    $0 <= runtimeWorkflow.now
                }) ?? false {
                    stats.parseQuarantineUntil = nil
                    stats.consecutiveHighMemoryParses = 0
                }
                stats.recordFetch(foundNewEpisode: false)
                subscriptionStore.updateRefreshStats(
                    subscriptionID: subscription.id,
                    stats: stats
                )
                logger.verbose(
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
            if highMemoryParse {
                stats.consecutiveHighMemoryParses += 1
                let quarantineHours =
                    stats.consecutiveHighMemoryParses > 1 ? 12.0 : 6.0
                stats.parseQuarantineUntil = runtimeWorkflow.now
                    .addingTimeInterval(quarantineHours * 60 * 60)
                logger.warning(
                    "feed.parseMemoryQuarantine",
                    "Automatic refresh paused after extreme feed parse memory growth",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false,
                        extra: [
                            "footprintDeltaMB": "\(parseFootprintDelta)",
                            "residentDeltaMB": "\(parseResidentDelta)",
                            "consecutiveHighMemoryParses":
                                "\(stats.consecutiveHighMemoryParses)",
                            "quarantineHours": "\(Int(quarantineHours))",
                            "quarantineUntil":
                                stats.parseQuarantineUntil?.ISO8601Format()
                                    ?? "unknown"
                        ]
                    )
                )
            } else {
                stats.parseQuarantineUntil = nil
                stats.consecutiveHighMemoryParses = 0
            }
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

            let mergeMetadata = releaseRadarWorkflow.feedMetadata(
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
            if latestChanged || newlyObserved > 0 {
                feedRefreshCoordinator.activeCycleMaterialChangeCount += 1
                logger.info(
                    "feed.refreshMerge",
                    "Merging changed feed episodes",
                    metadata: mergeMetadata
                )
            } else {
                logger.verbose(
                    "feed.refreshMerge",
                    "Merging refreshed feed metadata without a release change",
                    metadata: mergeMetadata
                )
            }
            let mergeStartedAt = CFAbsoluteTimeGetCurrent()
            var mergeStageMilliseconds: [String: Double] = [:]
            func measure(_ name: String, _ operation: () -> Void) {
                let startedAt = CFAbsoluteTimeGetCurrent()
                operation()
                mergeStageMilliseconds[name] =
                    (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            }
            autoreleasepool {
                subscriptionStore.beginChangeNotificationCoalescing()
                defer {
                    subscriptionStore.endChangeNotificationCoalescing()
                }
                measure("episodes") {
                    subscriptionStore.updateEpisodes(
                        subscriptionID: subscription.id,
                        episodes: result.episodes
                    )
                }
                if let artworkURL = result.artworkURL {
                    measure("artwork") {
                        subscriptionStore.updateArtworkURL(
                            subscriptionID: subscription.id,
                            artworkURL: artworkURL
                        )
                    }
                }
                measure("author") {
                    subscriptionStore.updateAuthor(
                        subscriptionID: subscription.id,
                        author: result.author
                    )
                }
                measure("description") {
                    subscriptionStore.updateDescription(
                        subscriptionID: subscription.id,
                        description: result.description
                    )
                }
                measure("categories") {
                    subscriptionStore.updateCategories(
                        subscriptionID: subscription.id,
                        categories: result.categories
                    )
                }
                measure("explicit") {
                    subscriptionStore.updateIsExplicit(
                        subscriptionID: subscription.id,
                        isExplicit: result.isExplicit
                    )
                }
            }
            let mergeMs =
                (CFAbsoluteTimeGetCurrent() - mergeStartedAt) * 1_000
            _ = ResourceMonitor.shared.logMemoryStageDelta(
                stage: "feed.merge",
                from: memorySample,
                context: memoryContext.merging([
                    "episodeCount": "\(result.episodes.count)",
                    "latestChanged": "\(latestChanged)"
                ]) { _, new in new }
            )
            if mergeMs >= 100 {
                logger.warning(
                    "ui.mainActorOperationSlow",
                    "Feed merge occupied the main actor",
                    metadata: releaseRadarWorkflow.feedMetadata(
                        for: subscription,
                        includeURL: false,
                        extra: [
                            "operation": "feed.merge",
                            "durationMs": String(
                                format: "%.1f",
                                mergeMs
                            ),
                            "episodeCount": "\(result.episodes.count)",
                            "latestChanged": "\(latestChanged)",
                            "stageMs": mergeStageMilliseconds
                                .sorted { $0.key < $1.key }
                                .map {
                                    "\($0.key)=\(String(format: "%.1f", $0.value))"
                                }
                                .joined(separator: ",")
                        ]
                    )
                )
            }

            if subscriptionStore.subscription(id: subscription.id)?
                .browseDate != nil {
                logger.verbose(
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
                logger.verbose(
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
                logger.verbose(
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
                refreshUpNextAfterMerge: refreshUpNextAfterMerge,
                detectionContext:
                    feedRefreshCoordinator.activeCycleDiagnostics?
                        .executionContext.rawValue ?? "singleFeedManual",
                sceneActive: runtimeWorkflow.isSceneActive,
                batteryState:
                    ResourceMonitor.shared.externalPowerStateLabel,
                detectedAt: runtimeWorkflow.now,
                sceneActivationSequence:
                    runtimeWorkflow.sceneActivationSequence
            )
            logger.verbose(
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
