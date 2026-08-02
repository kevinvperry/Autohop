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
// - Active playback triggers immediately. A qualifying arrival while playback is
//   inactive remains armed for 30 minutes and triggers only after safe playback
//   becomes active again; it never starts through an unavailable route/speaker.
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
    static let pendingLifetime: TimeInterval = 30 * 60

    static func expiryDate(forQueuedAt queuedAt: Date) -> Date {
        queuedAt.addingTimeInterval(pendingLifetime)
    }

    static func isExpired(
        _ candidate: PlaybackCoordinator.PlayInstantCandidate,
        now: Date
    ) -> Bool {
        candidate.expiresAt <= now
    }

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
        playback.playInstantPlaybackBecameActive = { [weak self] in
            self?.playbackDidBecomeActive()
        }
    }

    func enqueueIfEligible(episodeID: UUID, subscriptionID: UUID) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            logRejected(reason: "subscriptionUnavailable", episodeID: episodeID)
            return
        }
        guard subscription.autoArchiveSettings.playInstantEnabled else {
            logRejected(reason: "settingDisabled", episodeID: episodeID, podcast: subscription.title)
            return
        }
        guard let episode = subscriptionStore.episode(
                subscriptionID: subscriptionID,
                episodeID: episodeID
              ) else {
            logRejected(reason: "episodeUnavailable", episodeID: episodeID, podcast: subscription.title)
            return
        }
        guard subscription.downloadFilterSettings.evaluation(for: episode).isIncluded else {
            logRejected(reason: "filterExcluded", episodeID: episodeID, episode: episode.title, podcast: subscription.title)
            return
        }
        guard episode.downloadState == .downloaded else {
            logRejected(reason: "notDownloaded", episodeID: episodeID, episode: episode.title, podcast: subscription.title)
            return
        }
        guard playback.currentEpisode?.id != episodeID else {
            logRejected(reason: "alreadyCurrent", episodeID: episodeID, episode: episode.title, podcast: subscription.title)
            return
        }

        let now = Date()
        let candidate = PlaybackCoordinator.PlayInstantCandidate(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            queuedAt: now,
            expiresAt: Self.expiryDate(forQueuedAt: now)
        )
        guard playback.activePlayInstantEpisodeID != episodeID,
              !playback.playInstantQueue.contains(where: {
                  $0.episodeID == episodeID && $0.subscriptionID == subscriptionID
              }) else {
            logRejected(reason: "duplicateCandidate", episodeID: episodeID, episode: episode.title, podcast: subscription.title)
            return
        }
        playback.playInstantQueue.append(candidate)
        let playbackActive = playback.isPlaying || playback.engine.isPlaying
        let routeSafe = hasPrivateOrExternalAudioRoute
        let canTriggerImmediately = playbackActive && routeSafe
        logger.info(canTriggerImmediately ? "playInstant.queued" : "playInstant.armed", canTriggerImmediately
            ? "Queued automatically downloaded episode for instant playback"
            : "Armed automatically downloaded episode until safe playback resumes", metadata: [
            "episode": episode.title,
            "podcast": subscription.title,
            "queueDepth": "\(playback.playInstantQueue.count)",
            "playbackActive": "\(playbackActive)",
            "routeSafe": "\(routeSafe)",
            "outputs": currentOutputNames,
            "expiresInSeconds": "\(Int(Self.pendingLifetime))"
        ])
        scheduleExpiryCheck()
        beginTransitionIfNeeded()
    }

    func playbackDidBecomeActive() {
        guard playback.activePlayInstantEpisodeID == nil,
              playback.playInstantTransitionTask == nil else { return }
        pruneExpiredCandidates()
        guard !playback.playInstantQueue.isEmpty else { return }

        if playback.playInstantQueue.contains(where: {
            $0.episodeID == playback.currentEpisode?.id
        }) {
            let currentID = playback.currentEpisode?.id
            playback.playInstantQueue.removeAll { $0.episodeID == currentID }
            logger.info(
                "playInstant.satisfiedManually",
                "Removed armed Play Instant episode because the user started it directly"
            )
            scheduleExpiryCheck()
            return
        }
        guard hasPrivateOrExternalAudioRoute else {
            logger.info(
                "playInstant.awaitingSafeRoute",
                "Kept an armed Play Instant episode pending because playback is using the built-in speaker",
                metadata: [
                    "queueDepth": "\(playback.playInstantQueue.count)",
                    "outputs": currentOutputNames
                ]
            )
            return
        }
        logger.info(
            "playInstant.resumedTrigger",
            "Safe playback resumed with an armed Play Instant episode",
            metadata: ["queueDepth": "\(playback.playInstantQueue.count)"]
        )
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
        playback.playInstantExpiryTask?.cancel()
        playback.playInstantExpiryTask = nil
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
        pruneExpiredCandidates()
        guard playback.activePlayInstantEpisodeID == nil,
              playback.playInstantTransitionTask == nil,
              !playback.playInstantQueue.isEmpty,
              let interruptedEpisode = playback.currentEpisode,
              playback.isPlaying || playback.engine.isPlaying,
              hasPrivateOrExternalAudioRoute else {
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
                  self.playback.isPlaying || self.playback.engine.isPlaying,
                  self.hasPrivateOrExternalAudioRoute else {
                self.cancel(reason: "playbackChangedDuringWarning")
                return
            }
            self.playback.interruptedSession?.position = self.playback.clock.time
            self.mediaWorkflow.saveCurrentPosition()
            await self.startNextCandidate()
        }
    }

    /// Play Instant is intentionally more conservative than ordinary playback:
    /// it may interrupt an already-playing episode only on a private or external
    /// route. This prevents an armed download from unexpectedly speaking through
    /// the iPhone receiver or speaker after AirPods are removed.
    private var hasPrivateOrExternalAudioRoute: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.contains { output in
            output.portType != .builtInSpeaker && output.portType != .builtInReceiver
        }
    }

    private var currentOutputNames: String {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private func startNextCandidate() async {
        pruneExpiredCandidates()
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
            scheduleExpiryCheck()
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

    private func pruneExpiredCandidates(now: Date = Date()) {
        let expired = playback.playInstantQueue.filter {
            Self.isExpired($0, now: now)
        }
        guard !expired.isEmpty else { return }
        playback.playInstantQueue.removeAll { Self.isExpired($0, now: now) }
        for candidate in expired {
            logger.info(
                "playInstant.expired",
                "Armed Play Instant episode expired into its normal Up Next position",
                metadata: [
                    "episodeID": candidate.episodeID.uuidString,
                    "armedSeconds": "\(Int(now.timeIntervalSince(candidate.queuedAt)))"
                ]
            )
        }
        scheduleExpiryCheck()
    }

    private func scheduleExpiryCheck() {
        playback.playInstantExpiryTask?.cancel()
        playback.playInstantExpiryTask = nil
        guard let expiry = playback.playInstantQueue.map(\.expiresAt).min() else { return }
        let delay = max(0, expiry.timeIntervalSinceNow)
        playback.playInstantExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.playback.playInstantExpiryTask = nil
            self.pruneExpiredCandidates()
        }
    }

    private func logRejected(
        reason: String,
        episodeID: UUID,
        episode: String = "unknown",
        podcast: String = "unknown"
    ) {
        logger.info(
            "playInstant.ineligible",
            "Automatic download did not qualify for Play Instant",
            metadata: [
                "reason": reason,
                "episodeID": episodeID.uuidString,
                "episode": episode,
                "podcast": podcast,
                "isPlaying": "\(playback.isPlaying)",
                "enginePlaying": "\(playback.engine.isPlaying)"
            ]
        )
    }
}
