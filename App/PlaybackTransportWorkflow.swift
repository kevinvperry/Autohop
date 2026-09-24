// AI CONTEXT — Diagnostic repairs, 20 September 2026.
// Resume reflects engine.isPlaying while a delayed rebuild is pending; the guarded engine
// callback publishes success. Keep sleep settings and user transport intent intact.
// Evidence and validation limits: Docs/DIAGNOSTIC_REPAIRS_2026-09-20.md.

import Foundation

// PLAY INSTANT: Pause/resume of the active interruption preserves its return
// session. Pausing the warning cancels the pending forced switch.
// BINGE (Version 1.7): successful resume records the same idempotent Replay
// start event, including a queued episode adopted while the player was paused.
// AI CONTEXT — App/PlaybackTransportWorkflow.swift
// REPLAY (Version 1.7, 2026-09-12): A failed/missing Replay head blocks automatic queue scanning instead of silently skipping the reservation; explicit selection remains available.
//
// PURPOSE:
// High-level playback transport and queue-selection transaction. It owns
// play/pause/resume decisions, transactional queue reads, ordinary next-item
// selection, explicit episode selection, skip-to-episode, position checkpoints,
// Play Instant cancellation boundaries, and empty-queue terminal state.
//
// INVARIANTS:
// - Queue selection recomputes synchronously after completion/archive mutations.
// - Existing/current downloaded media is preferred before scanning Up Next.
// - Deliberate episode changes cancel Play Instant restoration.
// - Pause persists the freshest position and history/Stats before returning.
// - Resume reuses a still-loaded engine session; otherwise it executes the
//   PlaybackStartWorkflow transaction.
// - Empty queue clears playback/Now Playing and publishes one user message.

@MainActor
final class PlaybackTransportWorkflow {
    private let playback: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let queueCoordinator: QueueCoordinator
    private let playbackPositionStore: PlaybackPositionStore
    private let checkpointWorkflow: PlaybackCheckpointWorkflow
    private let logger: AppLogger
    private let preferenceWorkflow: PlaybackPreferenceWorkflow
    private let startWorkflow: PlaybackStartWorkflow
    private let playInstantWorkflow: PlayInstantWorkflow
    private let runtimeWorkflow: AppRuntimeWorkflow

    init(
        playback: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        queueCoordinator: QueueCoordinator,
        playbackPositionStore: PlaybackPositionStore,
        checkpointWorkflow: PlaybackCheckpointWorkflow,
        logger: AppLogger,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        startWorkflow: PlaybackStartWorkflow,
        playInstantWorkflow: PlayInstantWorkflow,
        runtimeWorkflow: AppRuntimeWorkflow
    ) {
        self.playback = playback
        self.subscriptionStore = subscriptionStore
        self.queueCoordinator = queueCoordinator
        self.playbackPositionStore = playbackPositionStore
        self.checkpointWorkflow = checkpointWorkflow
        self.logger = logger
        self.preferenceWorkflow = preferenceWorkflow
        self.startWorkflow = startWorkflow
        self.playInstantWorkflow = playInstantWorkflow
        self.runtimeWorkflow = runtimeWorkflow
    }

    func togglePlayPause() async {
        runtimeWorkflow.logResourceSnapshot(reason: "player.toggle")
        logger.info("player.toggle", "Play/pause pressed", metadata: [
            "isPlaying": "\(playback.isPlaying)",
            "episode": playback.currentEpisode?.title ?? "none"
        ])
        if playback.sleepScheduleService.isPrompting {
            playback.sleepScheduleService.userResponded()
            logger.info(
                "sleepSchedule.stillListening",
                "User confirmed still listening via play/pause"
            )
        }

        if playback.isPlaying {
            // Pausing an already-started Instant episode must preserve its return point.
            // Only an unfinished warning is cancelled by pause.
            if playback.activePlayInstantEpisodeID == nil
                && playback.playInstantTransitionTask != nil {
                playInstantWorkflow.cancel(reason: "pausedDuringPlayInstant")
            }
            playback.engine.pause()
            playback.isPlaying = false
            checkpointWorkflow.checkpoint(reason: "playback.pause")
            updateNowPlayingTime(isPlaying: false)
            return
        }

        guard let episode = playback.currentEpisode else {
            await playNextEpisode()
            return
        }
        if playback.engine.currentEpisode?.id == episode.id {
            playback.engine.setVolume(1)
            playback.engine.resume()
            playback.isPlaying = playback.engine.isPlaying
            subscriptionStore.recordPodcastReplayStart(subscriptionID: episode.subscriptionID, episode: episode)
            if playback.sleepTimerService.checkAutoRestart() {
                logger.info(
                    "sleepTimer.autoRestart",
                    "Sleep timer auto-restarted on manual resume"
                )
            }
            playback.sleepScheduleService.playbackResumed()
            updateNowPlayingTime(isPlaying: playback.isPlaying)
        } else if episode.downloadState == .downloaded,
                  episode.localFileURL != nil || episode.localFileName != nil {
            _ = await startWorkflow.start(
                episode: episode,
                resumeFrom: playback.clock.time
            )
        } else {
            playback.currentEpisode = nil
            playback.clock.time = 0
            await playNextEpisode()
        }
    }

    func playNextEpisode(excluding excludedEpisodeIDs: Set<UUID> = []) async {
        saveCurrentPosition()
        queueCoordinator.recompute(reason: "queue.playNextRead")
        runtimeWorkflow.logResourceSnapshot(reason: "queue.playNext")
        logger.info("queue.playNext", "Looking for next playable episode", metadata: [
            "queueCount": "\(queueCoordinator.episodes.count)",
            "excludedCount": "\(excludedEpisodeIDs.count)"
        ])

        if let restored = playback.currentEpisode,
           restored.downloadState == .downloaded,
           restored.localFileURL != nil || restored.localFileName != nil,
           !excludedEpisodeIDs.contains(restored.id),
           await startWorkflow.start(
                episode: restored,
                resumeFrom: playback.clock.time
           ) {
            return
        }
        for episode in queueCoordinator.episodes
        where !excludedEpisodeIDs.contains(episode.id) {
            if await startWorkflow.start(
                episode: episode,
                resumeFrom: playbackPositionStore.savedTime(for: episode)
            ) {
                return
            }
            if subscriptionStore.subscription(id: episode.subscriptionID)?.autoArchiveSettings.replay?.contains(episode) == true {
                playback.message = "Waiting for this Podcast Replay episode to download. Try again when it is ready."
                return
            }
        }

        playback.currentEpisode = nil
        playback.clock.time = 0
        playback.isPlaying = false
        NowPlayingService.shared.clear()
        playback.message = "No downloaded podcast episodes are ready."
        logger.warning("queue.empty", "No downloaded podcast episodes are ready")
    }

    func playEpisode(_ episode: Episode) async {
        if hasPlayInstantSession {
            playInstantWorkflow.cancel(reason: "selectedDifferentEpisode")
        }
        saveCurrentPosition()
        queueCoordinator.removePins(for: episode.id)
        let resumeTime = playbackPositionStore.savedTime(for: episode)
        runtimeWorkflow.logResourceSnapshot(
            reason: "player.playEpisode",
            extra: ["episode": episode.title]
        )
        logger.info("player.playEpisode", "Playing selected episode", metadata: [
            "episode": episode.title,
            "resume": "\(Int(resumeTime))"
        ])
        _ = await startWorkflow.start(
            episode: episode,
            resumeFrom: resumeTime
        )
    }

    func skipToEpisode(_ episode: Episode) async {
        if hasPlayInstantSession {
            playInstantWorkflow.cancel(reason: "skippedToDifferentEpisode")
        }
        saveCurrentPosition()
        logger.info("queue.skipToEpisode", "Skipping to episode", metadata: [
            "episode": episode.title
        ])
        playback.engine.stop()
        playback.isPlaying = false
        playback.clock.time = 0
        _ = await startWorkflow.start(
            episode: episode,
            resumeFrom: playbackPositionStore.savedTime(for: episode)
        )
    }

    private var hasPlayInstantSession: Bool {
        playback.activePlayInstantEpisodeID != nil
            || playback.playInstantTransitionTask != nil
            || playback.interruptedSession != nil
    }

    private func saveCurrentPosition() {
        guard let episode = playback.currentEpisode, playback.clock.time > 0 else {
            return
        }
        playbackPositionStore.save(
            episode: episode,
            timeSeconds: playback.clock.time
        )
    }

    private func updateNowPlayingTime(isPlaying: Bool) {
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return
        }
        NowPlayingService.shared.updateTime(
            currentTime: playback.clock.time,
            isPlaying: isPlaying,
            speed: preferenceWorkflow.effectiveSpeed(for: subscription)
        )
    }
}
