import Foundation

// AI CONTEXT — App/EpisodeDispositionWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Ordered user-initiated episode disposition transaction. It owns Mark Played,
// Archive, Archive and Play Next, Archive Current and Play Next, and Unarchive.
// The workflow coordinates playback teardown, resume-state removal, terminal
// Listening History metadata, media cancellation/deletion, subscription state,
// queue pins, download projections, user messaging, and Play Instant boundaries.
//
// ORDERING / DURABILITY:
// - Active playback is stopped and Now Playing cleared before its episode is
//   mutated or deleted.
// - The last durable playback position is read before its resume row is cleared.
// - Listening History records the explicit completion reason before media and
//   subscription state are settled.
// - Archive cancels an in-flight transfer before file deletion.
// - Queue pins are removed only after archive state commits.
// - Archive-and-next advances only when the archived episode was current.
//
// INVARIANTS:
// This workflow does not choose Auto Archive eligibility or queue order. It
// executes an already-authorized disposition and delegates Play Instant
// restoration/advancement and ordinary next selection through narrow effects.

@MainActor
final class EpisodeDispositionWorkflow {
    private let playback: PlaybackCoordinator
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let subscriptionStore: SubscriptionStore
    private let downloadManager: any DownloadManaging
    private let downloadCoordinator: DownloadCoordinator
    private let queueCoordinator: QueueCoordinator
    private let playbackPositionStore: PlaybackPositionStore
    private let logger: AppLogger
    private weak var playInstantWorkflow: PlayInstantWorkflow?
    private weak var transportWorkflow: PlaybackTransportWorkflow?

    init(
        playback: PlaybackCoordinator,
        historyStatsCoordinator: HistoryStatsCoordinator,
        subscriptionStore: SubscriptionStore,
        downloadManager: any DownloadManaging,
        downloadCoordinator: DownloadCoordinator,
        queueCoordinator: QueueCoordinator,
        playbackPositionStore: PlaybackPositionStore,
        logger: AppLogger
    ) {
        self.playback = playback
        self.historyStatsCoordinator = historyStatsCoordinator
        self.subscriptionStore = subscriptionStore
        self.downloadManager = downloadManager
        self.downloadCoordinator = downloadCoordinator
        self.queueCoordinator = queueCoordinator
        self.playbackPositionStore = playbackPositionStore
        self.logger = logger
    }

    func installNavigation(
        playInstantWorkflow: PlayInstantWorkflow,
        transportWorkflow: PlaybackTransportWorkflow
    ) {
        self.playInstantWorkflow = playInstantWorkflow
        self.transportWorkflow = transportWorkflow
    }

    func markPlayed(_ episode: Episode) async {
        let completesPlayInstant = playback.activePlayInstantEpisodeID == episode.id
        logger.info("episode.markPlayed", "Marking episode as played", metadata: [
            "episode": episode.title
        ])
        if playback.currentEpisode?.id == episode.id {
            stopCurrentPlayback()
        }

        let savedPosition = playbackPositionStore.savedTime(for: episode)
        playbackPositionStore.clear(for: episode)
        historyStatsCoordinator.mark(
            episode,
            status: .played,
            completionKind: .markedPlayed,
            positionSeconds: savedPosition > 0 ? savedPosition : nil
        )

        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning("episode.markPlayed", "Could not delete local file", metadata: [
                "episode": episode.title,
                "error": String(describing: error)
            ])
        }

        subscriptionStore.markEpisodePlayed(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        downloadCoordinator.progressModel.progress.removeValue(forKey: episode.id)
        downloadCoordinator.message = "Marked \(episode.title) as played."
        if completesPlayInstant {
            await playInstantWorkflow?.finishAndAdvance(
                reason: "markedPlayed"
            )
        }
    }

    func archive(
        _ episode: Episode,
        completionKind: CompletionKind = .manuallyArchived
    ) async {
        logger.info("episode.archive", "Archiving episode", metadata: [
            "episode": episode.title
        ])
        if playback.currentEpisode?.id == episode.id {
            if playback.activePlayInstantEpisodeID == episode.id
                || playback.interruptedSession != nil {
                playInstantWorkflow?.cancel(
                    reason: "archiveCurrentEpisode"
                )
            }
            stopCurrentPlayback()
        }

        let archivedPosition = playbackPositionStore.savedTime(for: episode)
        playbackPositionStore.clear(for: episode)
        historyStatsCoordinator.mark(
            episode,
            status: .archived,
            completionKind: completionKind,
            positionSeconds: archivedPosition > 0 ? archivedPosition : nil
        )

        downloadManager.cancelDownload(episodeID: episode.id)
        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning("episode.archive", "Could not delete local file", metadata: [
                "episode": episode.title,
                "error": String(describing: error)
            ])
        }

        subscriptionStore.markEpisodeArchived(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        queueCoordinator.removePins(for: episode.id)
        downloadCoordinator.progressModel.progress.removeValue(forKey: episode.id)
        downloadCoordinator.message = "Archived \(episode.title)."
        downloadCoordinator.rebuildDownloadedActivities(
            from: subscriptionStore.subscriptions
        )
    }

    func archiveAndPlayNext(_ episode: Episode) async {
        let wasCurrentEpisode = playback.currentEpisode?.id == episode.id
        logger.info(
            "episode.archiveAndPlayNext",
            "Archiving and advancing queue",
            metadata: [
                "episode": episode.title,
                "wasCurrent": "\(wasCurrentEpisode)"
            ]
        )
        await archive(episode)
        if wasCurrentEpisode {
            await transportWorkflow?.playNextEpisode(
                excluding: [episode.id]
            )
        }
    }

    func archiveCurrentAndPlayNext() async {
        guard let episode = playback.currentEpisode else { return }
        await archiveAndPlayNext(episode)
    }

    func unarchive(_ episode: Episode) {
        subscriptionStore.markEpisodeUnarchived(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        logger.info("episode.unarchive", "Unarchived episode", metadata: [
            "episode": episode.title
        ])
    }

    private func stopCurrentPlayback() {
        playback.engine.stop()
        playback.currentEpisode = nil
        playback.clock.time = 0
        playback.isPlaying = false
        NowPlayingService.shared.clear()
    }
}
