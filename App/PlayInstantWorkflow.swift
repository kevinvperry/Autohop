import AVFoundation
import Foundation

// AI CONTEXT — App/PlayInstantWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Exclusive Play Instant state-machine implementation. PlaybackCoordinator owns
// its mutable session storage and delayed transition Task; this workflow owns
// eligibility, warning, interruption capture, candidate sequencing, restoration,
// and cancellation policy. PlaybackMediaWorkflow supplies local-file and
// position effects. PlaybackStartWorkflow and PlaybackTransportWorkflow are
// connected weakly after graph construction to avoid a transfer/start cycle;
// AppState retains only compatibility commands.
//
// INVARIANTS:
// - Only successfully automatic, downloaded, filter-included episodes enter.
// - Playback must already be active; Play Instant never starts from idle.
// - The interrupted episode/position is captured once per Instant session.
// - A two-second gentle warning precedes every forced switch.
// - Eligibility and local-file availability are revalidated after the delay.
// - Completion restores the interrupted episode unless another Instant candidate
//   is waiting; deliberate user navigation cancels the return point.
// - The transition Task is stored/cancelled by PlaybackCoordinator, never AppState.
//
// CONCURRENCY:
// MainActor-only. Delayed transitions verify cancellation and current episode
// identity before applying any state change.

@MainActor
final class PlayInstantWorkflow {
    private let playback: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let logger: AppLogger
    private let mediaWorkflow: PlaybackMediaWorkflow
    private weak var startWorkflow: PlaybackStartWorkflow?
    private weak var transportWorkflow: PlaybackTransportWorkflow?

    init(
        playback: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        logger: AppLogger,
        mediaWorkflow: PlaybackMediaWorkflow
    ) {
        self.playback = playback
        self.subscriptionStore = subscriptionStore
        self.logger = logger
        self.mediaWorkflow = mediaWorkflow
    }

    func installPlaybackWorkflows(
        startWorkflow: PlaybackStartWorkflow,
        transportWorkflow: PlaybackTransportWorkflow
    ) {
        self.startWorkflow = startWorkflow
        self.transportWorkflow = transportWorkflow
    }

    func enqueueIfEligible(episodeID: UUID, subscriptionID: UUID) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID),
              subscription.autoArchiveSettings.playInstantEnabled,
              let episode = subscriptionStore.episode(
                subscriptionID: subscriptionID,
                episodeID: episodeID
              ),
              subscription.downloadFilterSettings.evaluation(for: episode).isIncluded,
              episode.downloadState == .downloaded,
              playback.currentEpisode?.id != episodeID,
              playback.isPlaying || playback.engine.isPlaying else {
            return
        }

        let candidate = PlaybackCoordinator.PlayInstantCandidate(
            episodeID: episodeID,
            subscriptionID: subscriptionID
        )
        guard playback.activePlayInstantEpisodeID != episodeID,
              !playback.playInstantQueue.contains(candidate) else {
            return
        }
        playback.playInstantQueue.append(candidate)
        logger.info("playInstant.queued", "Queued automatically downloaded episode for instant playback", metadata: [
            "episode": episode.title,
            "podcast": subscription.title,
            "queueDepth": "\(playback.playInstantQueue.count)"
        ])
        beginTransitionIfNeeded()
    }

    func finishAndAdvance(reason: String) async {
        playback.activePlayInstantEpisodeID = nil
        if !playback.playInstantQueue.isEmpty {
            playWarningTone()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await startNextCandidate()
            return
        }
        await restoreInterruptedSession(reason: reason)
    }

    func cancel(reason: String) {
        let hadSession = playback.interruptedSession != nil
            || playback.activePlayInstantEpisodeID != nil
            || !playback.playInstantQueue.isEmpty
        playback.playInstantTransitionTask?.cancel()
        playback.playInstantTransitionTask = nil
        playback.playInstantWarningPlayer?.stop()
        playback.playInstantWarningPlayer = nil
        playback.playInstantQueue.removeAll()
        playback.interruptedSession = nil
        playback.activePlayInstantEpisodeID = nil
        if hadSession {
            logger.info(
                "playInstant.cancelled",
                "Cancelled Play Instant return session after deliberate user action",
                metadata: ["reason": reason]
            )
        }
    }

    private func beginTransitionIfNeeded() {
        guard playback.activePlayInstantEpisodeID == nil,
              playback.playInstantTransitionTask == nil,
              !playback.playInstantQueue.isEmpty,
              let interruptedEpisode = playback.currentEpisode,
              playback.isPlaying || playback.engine.isPlaying else {
            return
        }

        if playback.interruptedSession == nil {
            playback.interruptedSession = PlaybackCoordinator.InterruptedSession(
                episodeID: interruptedEpisode.id,
                subscriptionID: interruptedEpisode.subscriptionID,
                position: playback.clock.time
            )
        }
        let expectedCurrentID = interruptedEpisode.id
        playWarningTone()
        logger.info("playInstant.warning", "Warning before switching to Play Instant episode", metadata: [
            "interruptedEpisode": interruptedEpisode.title,
            "delaySeconds": "2"
        ])

        playback.playInstantTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.playback.playInstantTransitionTask = nil
            guard self.playback.currentEpisode?.id == expectedCurrentID,
                  self.playback.isPlaying || self.playback.engine.isPlaying else {
                self.cancel(reason: "playbackChangedDuringWarning")
                return
            }
            self.playback.interruptedSession?.position = self.playback.clock.time
            self.mediaWorkflow.saveCurrentPosition()
            await self.startNextCandidate()
        }
    }

    private func startNextCandidate() async {
        while !playback.playInstantQueue.isEmpty {
            let candidate = playback.playInstantQueue.removeFirst()
            guard let subscription = subscriptionStore.subscription(
                id: candidate.subscriptionID
            ),
                  subscription.autoArchiveSettings.playInstantEnabled,
                  let episode = subscriptionStore.episode(
                    subscriptionID: candidate.subscriptionID,
                    episodeID: candidate.episodeID
                  ),
                  episode.downloadState == .downloaded,
                  mediaWorkflow.localFileExists(for: episode) else {
                continue
            }

            playback.activePlayInstantEpisodeID = episode.id
            logger.info("playInstant.started", "Starting Play Instant episode", metadata: [
                "episode": episode.title,
                "podcast": subscription.title,
                "remainingInstantQueue": "\(playback.playInstantQueue.count)"
            ])
            if await startWorkflow?.start(
                episode: episode,
                resumeFrom: 0
            ) == true {
                return
            }
            playback.activePlayInstantEpisodeID = nil
        }
        await restoreInterruptedSession(reason: "noPlayableInstantCandidate")
    }

    private func restoreInterruptedSession(reason: String) async {
        guard let interrupted = playback.interruptedSession else {
            cancel(reason: "missingInterruptedSession")
            return
        }
        playback.interruptedSession = nil
        playback.activePlayInstantEpisodeID = nil
        guard let episode = subscriptionStore.episode(
            subscriptionID: interrupted.subscriptionID,
            episodeID: interrupted.episodeID
        ),
              episode.downloadState == .downloaded,
              mediaWorkflow.localFileExists(for: episode) else {
            logger.warning(
                "playInstant.restoreUnavailable",
                "Interrupted episode was no longer available to resume",
                metadata: [
                    "episodeID": interrupted.episodeID.uuidString,
                    "reason": reason
                ]
            )
            await transportWorkflow?.playNextEpisode()
            return
        }
        logger.info("playInstant.restoring", "Returning to episode interrupted by Play Instant", metadata: [
            "episode": episode.title,
            "positionSeconds": String(format: "%.1f", interrupted.position),
            "reason": reason
        ])
        _ = await startWorkflow?.start(
            episode: episode,
            resumeFrom: interrupted.position
        )
    }

    private func playWarningTone() {
        guard let data = PlaybackCueService.makePlayInstantWarningWAV() else {
            return
        }
        playback.playInstantWarningPlayer = try? AVAudioPlayer(data: data)
        playback.playInstantWarningPlayer?.volume = 0.22
        playback.playInstantWarningPlayer?.prepareToPlay()
        playback.playInstantWarningPlayer?.play()
    }
}
