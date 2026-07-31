import Foundation

// AI CONTEXT — App/DownloadActionsWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// User/platform-facing download command workflow layered over
// DownloadTransferWorkflow. It owns latest-episode selection, ordinary queue
// download, CarPlay download-and-wait, local-download deletion, pause,
// resume-with-clean-restart fallback, watchdog retry lookup, cancel, archive
// from Downloads, and startup orphan reconciliation.
//
// RELIABILITY:
// - CarPlay waits only while store/progress/activity state says the transfer is
//   active and returns the authoritative downloaded Episode.
// - Resume first consumes DownloadManager resume data; a failed resume retires
//   task identity, resume data, partial media, failed activity, and store state
//   before one clean restart.
// - Startup reconciliation compares durable `.downloading` rows and activities
//   against DownloadManager's reconstructed live URLSession identities.
// - Deleting the current episode stops playback and clears its resume position
//   before media removal.
//
// This workflow does not implement automatic eligibility, Auto Archive policy,
// queue ordering, or the transfer loop itself.

@MainActor
final class DownloadActionsWorkflow {
    private let playback: PlaybackCoordinator
    private let downloadCoordinator: DownloadCoordinator
    private let downloadManager: any DownloadManaging
    private let subscriptionStore: SubscriptionStore
    private let playbackPositionStore: PlaybackPositionStore
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let logger: AppLogger
    private let transferWorkflow: DownloadTransferWorkflow
    private let dispositionWorkflow: EpisodeDispositionWorkflow

    init(
        playback: PlaybackCoordinator,
        downloadCoordinator: DownloadCoordinator,
        downloadManager: any DownloadManaging,
        subscriptionStore: SubscriptionStore,
        playbackPositionStore: PlaybackPositionStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        logger: AppLogger,
        transferWorkflow: DownloadTransferWorkflow,
        dispositionWorkflow: EpisodeDispositionWorkflow
    ) {
        self.playback = playback
        self.downloadCoordinator = downloadCoordinator
        self.downloadManager = downloadManager
        self.subscriptionStore = subscriptionStore
        self.playbackPositionStore = playbackPositionStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.logger = logger
        self.transferWorkflow = transferWorkflow
        self.dispositionWorkflow = dispositionWorkflow
    }

    func downloadLatestEpisode(for subscription: Subscription) async {
        guard let episode = subscription.newestEpisode else {
            downloadCoordinator.message =
                "No latest episode available for \(subscription.title)."
            logger.warning("download.latest", "No latest episode available", metadata: [
                "podcast": subscription.title
            ])
            return
        }
        await transferWorkflow.download(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true,
            isAutomatic: false
        )
    }

    func downloadEpisodeForQueue(_ episode: Episode) async {
        guard let subscription = subscriptionStore.subscription(
            id: episode.subscriptionID
        ) else {
            return
        }
        await transferWorkflow.download(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true,
            isAutomatic: false
        )
    }

    func downloadEpisodeForCarPlayAction(_ episode: Episode) async -> Episode? {
        guard let subscription = subscriptionStore.subscription(
            id: episode.subscriptionID
        ) else {
            return nil
        }
        if let readyEpisode = playableDownloadedEpisode(
            subscriptionID: subscription.id,
            episodeID: episode.id
        ) {
            return readyEpisode
        }
        let episodeToDownload = subscriptionStore.episode(
            subscriptionID: subscription.id,
            episodeID: episode.id
        ) ?? episode
        await transferWorkflow.download(
            episodeToDownload,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: false,
            isAutomatic: false
        )
        return await waitForCarPlayDownloadedEpisode(
            subscriptionID: subscription.id,
            episodeID: episode.id
        )
    }

    func deleteDownloadedEpisode(_ episode: Episode) async {
        logger.info("episode.deleteDownload", "Deleting downloaded episode", metadata: [
            "episode": episode.title
        ])
        if playback.currentEpisode?.id == episode.id {
            playback.engine.stop()
            playback.currentEpisode = nil
            playback.clock.time = 0
            playback.isPlaying = false
            playbackPositionStore.clear(for: episode)
            NowPlayingService.shared.clear()
        }

        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning(
                "episode.deleteDownload",
                "Could not delete local file",
                metadata: [
                    "episode": episode.title,
                    "error": String(describing: error)
                ]
            )
        }
        subscriptionStore.markEpisodeNotDownloaded(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        downloadCoordinator.message = "Removed \(episode.title) from Up Next."
    }

    func pauseDownload(_ activity: DownloadActivity) {
        logger.info("download.pauseRequested", "Download pause requested", metadata: [
            "episode": activity.episodeTitle,
            "episodeID": activity.episodeID.uuidString
        ])
        downloadManager.pauseDownload(episodeID: activity.episodeID)
        downloadCoordinator.activityStore.pause(episodeID: activity.episodeID)
        downloadCoordinator.message = "Paused \(activity.episodeTitle)."
    }

    func resumeDownload(_ activity: DownloadActivity) async {
        guard let episode = subscriptionStore.episode(
            subscriptionID: activity.subscriptionID,
            episodeID: activity.episodeID
        ),
              let subscription = subscriptionStore.subscription(
                id: activity.subscriptionID
              ) else {
            logger.warning("download.resume", "Could not find episode to resume", metadata: [
                "episode": activity.episodeTitle,
                "episodeID": activity.episodeID.uuidString
            ])
            return
        }

        downloadCoordinator.clearWatchdogRetryState(for: episode.id)
        downloadCoordinator.markActiveRuntimeFallbackEligible(
            episodeID: episode.id
        )
        logger.info("download.resumeAttempt", "Attempting download resume", metadata: [
            "episode": episode.title,
            "previousStatus": activity.status.rawValue,
            "manualCircuitBypass": "true"
        ])
        await transferWorkflow.download(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true,
            isAutomatic: false
        )
        let updatedEpisode = subscriptionStore.episode(
            subscriptionID: activity.subscriptionID,
            episodeID: activity.episodeID
        )
        guard updatedEpisode?.downloadState == .failed else { return }

        logger.warning(
            "download.resumeFallback",
            "Resume failed — restarting download from scratch",
            metadata: ["episode": episode.title]
        )
        downloadCoordinator.message = "Restarting download from the beginning."
        downloadManager.cancelDownload(episodeID: episode.id)
        downloadManager.clearResumeData(episodeID: episode.id)
        try? await downloadManager.deleteLocalFile(for: episode)
        subscriptionStore.markEpisodeNotDownloaded(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        downloadCoordinator.activityStore.remove(episodeID: episode.id)
        await transferWorkflow.download(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true,
            isAutomatic: false
        )
    }

    func retryWatchdogCancelledDownload(episodeID: UUID) async {
        guard let activity = downloadCoordinator.activityStore.activeActivities.first(
            where: { $0.episodeID == episodeID }
        ),
              let episode = subscriptionStore.episode(
                subscriptionID: activity.subscriptionID,
                episodeID: episodeID
              ),
              let subscription = subscriptionStore.subscription(
                id: activity.subscriptionID
              ) else {
            logger.info(
                "download.watchdogRetrySkipped",
                "Watchdog retry skipped — episode no longer active",
                metadata: ["episodeID": episodeID.uuidString]
            )
            return
        }
        logger.info(
            "download.watchdogRetry",
            "Retrying watchdog-paused download",
            metadata: [
                "episode": episode.title,
                "podcast": subscription.title,
                "automatic":
                    "\(downloadCoordinator.isAutomaticDownload(episodeID: episodeID))"
            ]
        )
        let isAutomatic = downloadCoordinator.isAutomaticDownload(
            episodeID: episodeID
        )
        await transferWorkflow.download(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: false,
            isAutomatic: isAutomatic
        )
    }

    func cancelDownload(_ activity: DownloadActivity) {
        logger.info("download.cancelRequested", "Download cancel requested", metadata: [
            "episode": activity.episodeTitle,
            "episodeID": activity.episodeID.uuidString
        ])
        downloadManager.cancelDownload(episodeID: activity.episodeID)
        downloadCoordinator.clearWatchdogRetryState(
            for: activity.episodeID
        )
        downloadCoordinator.progressModel.progress.removeValue(
            forKey: activity.episodeID
        )
        if let episode = subscriptionStore.episode(
            subscriptionID: activity.subscriptionID,
            episodeID: activity.episodeID
        ),
           let subscription = subscriptionStore.subscription(
            id: activity.subscriptionID
           ) {
            downloadCoordinator.activityStore.fail(
                episode: episode,
                podcastTitle: subscription.title,
                error: "Cancelled"
            )
            subscriptionStore.markEpisodeDownloadFailed(
                subscriptionID: activity.subscriptionID,
                episodeID: activity.episodeID
            )
        }
        downloadCoordinator.message = "Cancelled \(activity.episodeTitle)."
    }

    func archiveDownload(_ activity: DownloadActivity) async {
        logger.info(
            "download.archiveRequested",
            "Archive requested from Downloads page",
            metadata: [
                "episode": activity.episodeTitle,
                "episodeID": activity.episodeID.uuidString,
                "status": activity.status.rawValue
            ]
        )
        downloadManager.cancelDownload(episodeID: activity.episodeID)
        downloadCoordinator.clearWatchdogRetryState(
            for: activity.episodeID
        )
        downloadCoordinator.progressModel.progress.removeValue(
            forKey: activity.episodeID
        )
        downloadCoordinator.activityStore.remove(episodeID: activity.episodeID)

        if let episode = subscriptionStore.episode(
            subscriptionID: activity.subscriptionID,
            episodeID: activity.episodeID
        ) {
            await dispositionWorkflow.archive(episode)
        } else {
            logger.warning(
                "download.archiveRequested",
                "Episode not found in store — only URLSession task cancelled",
                metadata: ["episodeID": activity.episodeID.uuidString]
            )
            downloadCoordinator.message = "Archived \(activity.episodeTitle)."
        }
    }

    func reconcileOrphanedDownloads() async {
        let activeIDs = await downloadManager.activeDownloadEpisodeIDs()
        var orphanCount = 0

        for subscription in subscriptionStore.subscriptions {
            for episode in subscription.episodes
            where episode.downloadState == .downloading
                && !activeIDs.contains(episode.id) {
                subscriptionStore.markEpisodeDownloadFailed(
                    subscriptionID: subscription.id,
                    episodeID: episode.id
                )
                downloadCoordinator.progressModel.progress.removeValue(
                    forKey: episode.id
                )
                orphanCount += 1
                logger.warning(
                    "download.orphanRecovered",
                    "Cleared orphaned downloading state on startup",
                    metadata: [
                        "episode": episode.title,
                        "episodeID": episode.id.uuidString
                    ]
                )
            }
        }

        for activity in downloadCoordinator.activityStore.activeActivities
        where activity.status == .downloading
            && !activeIDs.contains(activity.episodeID) {
                if let episode = subscriptionStore.episode(
                    subscriptionID: activity.subscriptionID,
                    episodeID: activity.episodeID
                ),
                   let subscription = subscriptionStore.subscription(
                    id: activity.subscriptionID
                   ) {
                    downloadCoordinator.activityStore.fail(
                        episode: episode,
                        podcastTitle: subscription.title,
                        error: "Interrupted"
                    )
                } else {
                    downloadCoordinator.activityStore.remove(
                        episodeID: activity.episodeID
                    )
                }
                orphanCount += 1
                logger.warning(
                    "download.orphanRecovered",
                    "Cleared orphaned activity store entry on startup",
                    metadata: [
                        "episode": activity.episodeTitle,
                        "episodeID": activity.episodeID.uuidString
                    ]
                )
        }

        if orphanCount > 0 {
            logger.info(
                "download.reconcile",
                "Startup download reconciliation complete",
                metadata: ["orphanCount": "\(orphanCount)"]
            )
        }
        refreshDownloadedActivities()
        historyStatsCoordinator.refreshHistoryProjection()
    }

    func refreshDownloadedActivities() {
        downloadCoordinator.rebuildDownloadedActivities(
            from: subscriptionStore.subscriptions
        )
    }

    /// Retires an obsolete transfer when a rolling one-item feed replaces its
    /// sole enclosure. The cancellation identity is recorded before touching
    /// DownloadManager so the transfer workflow classifies the resulting
    /// paused/cancelled callback as superseded rather than failed.
    func cleanupSupersededRollingLatestIfNeeded(
        oldLatest: Episode,
        newLatest: Episode,
        feedEpisodeCount: Int,
        subscription: Subscription,
        baseMetadata: [String: String]
    ) {
        guard feedEpisodeCount == 1, oldLatest.guid != newLatest.guid else {
            return
        }
        let hadPendingQueueEntry = downloadCoordinator.pendingQueue.contains {
            $0.episode.id == oldLatest.id
        }
        let hadTrackedDownload = downloadCoordinator.activityStore
            .activeActivities
            .contains { $0.episodeID == oldLatest.id }
        let hadProgress =
            downloadCoordinator.progressModel.progress[oldLatest.id] != nil
        let shouldCancel = oldLatest.downloadState == .queued
            || oldLatest.downloadState == .downloading
            || hadPendingQueueEntry
            || hadTrackedDownload
            || hadProgress
        guard shouldCancel else { return }

        downloadCoordinator.supersededCancellationIDs.insert(oldLatest.id)
        downloadManager.cancelDownload(episodeID: oldLatest.id)
        downloadCoordinator.pendingQueue.removeAll {
            $0.episode.id == oldLatest.id
        }
        downloadCoordinator.progressModel.progress.removeValue(
            forKey: oldLatest.id
        )
        downloadCoordinator.activityStore.remove(episodeID: oldLatest.id)
        subscriptionStore.markEpisodeNotDownloaded(
            subscriptionID: oldLatest.subscriptionID,
            episodeID: oldLatest.id
        )
        refreshDownloadedActivities()

        var metadata = baseMetadata
        metadata.merge([
            "oldEpisode": oldLatest.title,
            "oldEpisodeID": oldLatest.id.uuidString,
            "oldDownloadState": oldLatest.downloadState.rawValue,
            "newEpisode": newLatest.title,
            "newEpisodeID": newLatest.id.uuidString,
            "feedEpisodeCount": "\(feedEpisodeCount)",
            "hadPendingQueueEntry": "\(hadPendingQueueEntry)",
            "hadTrackedDownload": "\(hadTrackedDownload)",
            "hadProgress": "\(hadProgress)"
        ]) { _, new in new }
        logger.info(
            "feed.cleanupSupersededLatest",
            "Cancelled superseded one-item feed download",
            metadata: metadata
        )
    }

    private func waitForCarPlayDownloadedEpisode(
        subscriptionID: UUID,
        episodeID: UUID
    ) async -> Episode? {
        for _ in 0..<3600 {
            if Task.isCancelled { return nil }
            if let episode = playableDownloadedEpisode(
                subscriptionID: subscriptionID,
                episodeID: episodeID
            ) {
                return episode
            }
            guard downloadIsActive(
                subscriptionID: subscriptionID,
                episodeID: episodeID
            ) else {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func playableDownloadedEpisode(
        subscriptionID: UUID,
        episodeID: UUID
    ) -> Episode? {
        guard let episode = subscriptionStore.episode(
            subscriptionID: subscriptionID,
            episodeID: episodeID
        ),
              episode.downloadState == .downloaded,
              episode.localFileURL != nil || episode.localFileName != nil else {
            return nil
        }
        return episode
    }

    private func downloadIsActive(
        subscriptionID: UUID,
        episodeID: UUID
    ) -> Bool {
        if downloadCoordinator.pendingQueue.contains(where: {
            $0.subscriptionID == subscriptionID && $0.episode.id == episodeID
        }) {
            return true
        }
        if downloadCoordinator.progressModel.progress[episodeID] != nil {
            return true
        }
        if downloadCoordinator.activityStore.activeActivities.contains(where: {
            $0.subscriptionID == subscriptionID
                && $0.episodeID == episodeID
                && ($0.status == .downloading
                    || $0.status == .waitingToRetry
                    || $0.status == .paused)
        }) {
            return true
        }
        if let episode = subscriptionStore.episode(
            subscriptionID: subscriptionID,
            episodeID: episodeID
        ) {
            return episode.downloadState == .queued
                || episode.downloadState == .downloading
        }
        return false
    }
}
