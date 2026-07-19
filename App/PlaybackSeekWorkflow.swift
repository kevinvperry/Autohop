import Foundation

// AI CONTEXT — App/PlaybackSeekWorkflow.swift
//
// PURPOSE:
// Single implementation for scrubber, skip-forward, skip-backward, chapter, and
// remote seeks. It owns boundary clamping, manual-skip Stats credit, Sleep
// Schedule confirmation, synchronous engine stop at EOF, Now Playing position,
// and delegation into the ordered completion transaction.
//
// COMPLETION INVARIANT:
// A requested position at/past EOF stops the engine synchronously before
// scheduling completion. This prevents either playback backend from emitting a
// competing EOF callback or restarting its buffer loop at zero.
//
// CONCURRENCY:
// MainActor-only. Completion is scheduled asynchronously only after playback
// state and the visible clock have reached their terminal values.

@MainActor
final class PlaybackSeekWorkflow {
    private let playback: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let logger: AppLogger
    private let preferenceWorkflow: PlaybackPreferenceWorkflow
    private let completionWorkflow: EpisodeCompletionWorkflow

    init(
        playback: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        logger: AppLogger,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        completionWorkflow: EpisodeCompletionWorkflow
    ) {
        self.playback = playback
        self.subscriptionStore = subscriptionStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.logger = logger
        self.preferenceWorkflow = preferenceWorkflow
        self.completionWorkflow = completionWorkflow
    }

    func skipForward(seconds: TimeInterval) {
        let duration = playback.currentEpisode?.durationSeconds
        let actualSkipped = PlaybackSeekBoundaryPolicy.actualForwardSkip(
            from: playback.clock.time,
            seconds: seconds,
            duration: duration
        )
        if actualSkipped > 0 {
            historyStatsCoordinator.recordManualSkipForward(
                actualSkipped,
                subscriptionID: playback.currentEpisode?.subscriptionID
            )
        }
        seek(to: playback.clock.time + seconds)
    }

    func seek(to requestedTime: TimeInterval) {
        if playback.sleepScheduleService.isPrompting {
            playback.sleepScheduleService.userResponded()
            logger.info(
                "sleepSchedule.stillListening",
                "User confirmed still listening via seek/skip"
            )
        }

        let duration = playback.currentEpisode?.durationSeconds
        let target = PlaybackPositionStore.clampedTime(
            requestedTime,
            duration: duration
        )
        logger.info("player.seek", "Seeking episode", metadata: [
            "episode": playback.currentEpisode?.title ?? "none",
            "target": "\(Int(target))",
            "requested": "\(Int(requestedTime))"
        ])

        if PlaybackSeekBoundaryPolicy.reachesCompletion(
            requestedTime: requestedTime,
            duration: duration
        ),
           let episode = playback.currentEpisode {
            playback.engine.stop()
            playback.clock.time = duration ?? target
            playback.isPlaying = false
            logger.info(
                "player.seekCompleted",
                "Seek reached episode end; completing instead of restarting at EOF",
                metadata: [
                    "episode": episode.title,
                    "requested": String(format: "%.2f", requestedTime),
                    "duration": duration.map {
                        String(format: "%.2f", $0)
                    } ?? "unknown"
                ]
            )
            Task { @MainActor [weak completionWorkflow] in
                await completionWorkflow?.handle(episode)
            }
            return
        }

        playback.engine.seek(to: target)
        playback.clock.time = target
        if let episode = playback.currentEpisode,
           let subscription = subscriptionStore.subscription(
            id: episode.subscriptionID
           ) {
            NowPlayingService.shared.updateTime(
                currentTime: target,
                isPlaying: playback.isPlaying,
                speed: preferenceWorkflow.effectiveSpeed(for: subscription)
            )
        }
    }
}
