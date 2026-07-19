import Foundation

// AI CONTEXT — App/EpisodeCompletionWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Cross-domain transaction for every episode completion, whether produced by
// natural EOF, a seek/skip crossing EOF, or an explicit remote "next" command.
// PlaybackCoordinator owns engine callback installation and generation capture;
// this workflow owns the ordered completion effects that must span playback,
// history/Stats, downloaded media, subscription state, sleep services, Play
// Instant, and queue advancement.
//
// ORDERING INVARIANTS:
// 1. Reject stale engine generations before any mutation.
// 2. Discard a Play Instant return point when the interrupted episode completes.
// 3. Resolve Sleep Timer/Schedule boundary policy before queue advancement.
// 4. Persist completion/history and clear resume state before deleting media.
// 5. Mark the subscription episode played before selecting the next queue item.
// 6. A fired manual Sleep Timer stops all advancement.
// 7. A completed Play Instant episode restores/advances its interrupted session.
// 8. Ordinary completion waits 400 ms before advancing, preserving the former
//    engine teardown boundary.
//
// CONCURRENCY:
// MainActor-only. The workflow is invoked through PlaybackCoordinator's
// generation-aware callback or AppState's high-level manual completion façade.
// It owns no long-lived task and never installs a service callback.

@MainActor
final class EpisodeCompletionWorkflow {
    private let playbackCoordinator: PlaybackCoordinator
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let subscriptionStore: SubscriptionStore
    private let downloadManager: any DownloadManaging
    private let playbackPositionStore: PlaybackPositionStore
    private let logger: AppLogger
    private weak var playInstantWorkflow: PlayInstantWorkflow?
    private weak var transportWorkflow: PlaybackTransportWorkflow?
#if DEBUG
    private var testCancelPlayInstant: ((String) -> Void)?
    private var testFinishPlayInstant: ((String) async -> Void)?
    private var testPlayNext: ((Set<UUID>) async -> Void)?
#endif

    init(
        playbackCoordinator: PlaybackCoordinator,
        historyStatsCoordinator: HistoryStatsCoordinator,
        subscriptionStore: SubscriptionStore,
        downloadManager: any DownloadManaging,
        playbackPositionStore: PlaybackPositionStore,
        logger: AppLogger
    ) {
        self.playbackCoordinator = playbackCoordinator
        self.historyStatsCoordinator = historyStatsCoordinator
        self.subscriptionStore = subscriptionStore
        self.downloadManager = downloadManager
        self.playbackPositionStore = playbackPositionStore
        self.logger = logger
    }

#if DEBUG
    /// Characterization-only constructor retained for isolated ordering tests.
    /// Production composition uses typed navigation workflows.
    convenience init(
        playbackCoordinator: PlaybackCoordinator,
        historyStatsCoordinator: HistoryStatsCoordinator,
        subscriptionStore: SubscriptionStore,
        downloadManager: any DownloadManaging,
        playbackPositionStore: PlaybackPositionStore,
        logger: AppLogger,
        cancelPlayInstantSession: @escaping (String) -> Void,
        finishPlayInstantAndAdvance: @escaping (String) async -> Void,
        playNextEpisode: @escaping (Set<UUID>) async -> Void
    ) {
        self.init(
            playbackCoordinator: playbackCoordinator,
            historyStatsCoordinator: historyStatsCoordinator,
            subscriptionStore: subscriptionStore,
            downloadManager: downloadManager,
            playbackPositionStore: playbackPositionStore,
            logger: logger
        )
        testCancelPlayInstant = cancelPlayInstantSession
        testFinishPlayInstant = finishPlayInstantAndAdvance
        testPlayNext = playNextEpisode
    }
#endif

    func installNavigation(
        playInstantWorkflow: PlayInstantWorkflow,
        transportWorkflow: PlaybackTransportWorkflow
    ) {
        self.playInstantWorkflow = playInstantWorkflow
        self.transportWorkflow = transportWorkflow
    }

    func handle(
        _ episode: Episode,
        expectedGeneration: UInt64? = nil
    ) async {
        if let expectedGeneration,
           !playbackCoordinator.isCurrent(
                generation: expectedGeneration,
                episodeID: episode.id
           ) {
            logger.info(
                "player.staleCompletionIgnored",
                "Ignored stale episode completion callback",
                metadata: [
                    "episodeID": episode.id.uuidString,
                    "expectedGeneration": "\(expectedGeneration)",
                    "currentGeneration": "\(playbackCoordinator.generation)"
                ]
            )
            return
        }

        logger.info("player.finished", "Episode finished playback", metadata: [
            "episode": episode.title
        ])

        if playbackCoordinator.interruptedSession?.episodeID == episode.id {
            cancelPlayInstant(reason: "interruptedEpisodeCompleted")
            logger.info(
                "playInstant.returnDiscarded",
                "Discarded return point because the interrupted episode completed",
                metadata: ["episode": episode.title]
            )
        }

        let sleepTimerFired = playbackCoordinator.sleepTimerService.episodeFinished()
        let sleepSchedulePrompting = !sleepTimerFired
            && playbackCoordinator.sleepScheduleService.episodeFinished()

        historyStatsCoordinator.recordEpisodeCompleted(
            subscriptionID: episode.subscriptionID
        )
        playbackPositionStore.clear(for: episode)
        historyStatsCoordinator.mark(
            episode,
            status: .played,
            completionKind: .finishedNaturally,
            positionSeconds: episode.durationSeconds
        )

        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning(
                "player.finished",
                "Could not delete local file after playback",
                metadata: [
                    "episode": episode.title,
                    "error": String(describing: error)
                ]
            )
        }
        subscriptionStore.markEpisodePlayed(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )

        playbackCoordinator.isPlaying = false
        playbackCoordinator.clock.time = 0

        if playbackCoordinator.activePlayInstantEpisodeID == episode.id {
            if sleepTimerFired {
                cancelPlayInstant(reason: "sleepTimerFired")
                NowPlayingService.shared.clear()
                return
            }
            await finishPlayInstant(reason: "finishedNaturally")
            return
        }

        if sleepTimerFired {
            logger.info(
                "sleepTimer.episodeEnd",
                "Sleep timer stopped playback after episode finished",
                metadata: ["episode": episode.title]
            )
            NowPlayingService.shared.clear()
            return
        }

        if sleepSchedulePrompting {
            logger.info(
                "sleepSchedule.episodeEnd",
                "Sleep Schedule prompting at episode boundary, advancing under the chime",
                metadata: ["episode": episode.title]
            )
        }

        try? await Task.sleep(for: .seconds(0.4))
        guard !Task.isCancelled else { return }
        await playNext(excluding: [episode.id])
    }

    private func cancelPlayInstant(reason: String) {
#if DEBUG
        if let testCancelPlayInstant {
            testCancelPlayInstant(reason)
            return
        }
#endif
        playInstantWorkflow?.cancel(reason: reason)
    }

    private func finishPlayInstant(reason: String) async {
#if DEBUG
        if let testFinishPlayInstant {
            await testFinishPlayInstant(reason)
            return
        }
#endif
        await playInstantWorkflow?.finishAndAdvance(reason: reason)
    }

    private func playNext(excluding episodeIDs: Set<UUID>) async {
#if DEBUG
        if let testPlayNext {
            await testPlayNext(episodeIDs)
            return
        }
#endif
        await transportWorkflow?.playNextEpisode(excluding: episodeIDs)
    }
}
