import Foundation
import AVFoundation
import MediaPlayer
import Observation
import AutohopCore

// AI CONTEXT — TV/Playback/TVPlaybackModel.swift
// Phase 3 (Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md §8): the tvOS playback
// composition — owns a single StreamingPlaybackEngine (PlaybackCore),
// auto-advances through the streaming Priority Stack on finish (mirrors the
// iPhone's "mark played → next queue episode" policy, minus download gating),
// and writes position back through SubscriptionStore.recordListeningProgress /
// markListeningHistoryFinished so a phone⇄TV resume round-trip works (history
// entries are whole-record LWW by lastListenedAt — SYNC_DESIGN.md).
// OWNERSHIP: created once by TVAppModel and handed to the tab views; its
// `upNextProvider`/`subscriptionProvider` closures are wired by TVAppModel
// AFTER both objects exist, avoiding an init-order back-reference.
// HISTORY WRITE CADENCE: every `historyWriteInterval` seconds during playback,
// on pause/dismiss, and once more (as a status transition, not a progress
// tick) at natural finish — not every 0.5s tick, to avoid the same CloudKit
// push-storm PERSISTENCE/CloudSyncEngine's slow lane was built to avoid on
// iPhone. `sessionListenedSeconds` resets after each flush; a backward jump
// (seek) does not count as negative listened time.
// FAILURE UX (§8 item 5): `errorMessage` is set on a failed `play()` but
// `currentEpisode` STAYS set, so the presenting cover stays open showing a
// retry card (TVPlayerView) instead of silently dismissing to a dead list —
// streaming means network errors are a normal, expected case here.
@MainActor
@Observable
final class TVPlaybackModel {
    private let engine = StreamingPlaybackEngine()
    private let subscriptionStore: SubscriptionStore

    private(set) var currentEpisode: Episode?
    private(set) var currentSubscriptionTitle: String = ""
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    /// True while the stream is buffering (start-up or a mid-stream stall) —
    /// drives the player page's buffering spinner.
    private(set) var isBuffering = false
    /// Non-nil after a failed `play()`/mid-stream stall — see file header.
    private(set) var errorMessage: String?

    /// Supplied by TVAppModel post-init: the live streaming queue, for
    /// auto-advance on finish.
    var upNextProvider: (() -> [Episode])?
    /// Supplied by TVAppModel post-init: resolves an episode's owning
    /// subscription (title/artwork/playback preference/chapter filter).
    var subscriptionProvider: ((UUID) -> Subscription?)?
    /// Supplied by TVAppModel post-init: force-push the just-written position to
    /// CloudKit NOW (bypassing the engine's ~60 s slow-lane debounce) so a pause
    /// or player exit reaches the phone promptly instead of up to a minute late.
    /// Safe to call right after a progress write — `recordListeningProgress`
    /// persists synchronously, so the pending row is on disk before the flush.
    var onPlaybackCheckpoint: (() -> Void)?

    private var currentSubscriptionID: UUID?
    private var lastHistoryWriteAt: Date?
    private var sessionListenedSeconds: TimeInterval = 0
    private let historyWriteInterval: TimeInterval = 20

    /// The underlying AVPlayer for ANY media kind (audio included) — see
    /// StreamingPlaybackEngine.avPlayer's header for why this differs from
    /// the shared protocol's video-only `videoPlayer`.
    var avPlayer: AVPlayer? { engine.avPlayer }
    var currentChapters: [Chapter] { engine.currentChapters }
    var capabilities: PlaybackCapabilities { engine.capabilities }

    init(subscriptionStore: SubscriptionStore) {
        self.subscriptionStore = subscriptionStore
        engine.onTimeUpdate = { [weak self] time in
            self?.handleTimeUpdate(time)
        }
        engine.onEpisodeFinished = { [weak self] episode in
            self?.handleFinished(episode)
        }
        engine.onBufferingChanged = { [weak self] buffering in
            self?.isBuffering = buffering
        }
        configureRemoteCommands()
    }

    /// Pre-buffer a likely-next episode (the Continue Listening hero) so
    /// tapping it starts near-instantly. Cheap + idempotent; safe to call on
    /// every Home render.
    func preload(episode: Episode) {
        engine.preload(episode)
    }

    func play(episode: Episode, subscription: Subscription) async {
        flushProgress()
        currentEpisode = episode
        currentSubscriptionID = subscription.id
        currentSubscriptionTitle = subscription.title
        currentTime = 0
        sessionListenedSeconds = 0
        lastHistoryWriteAt = Date()
        errorMessage = nil
        subscriptionStore.markEpisodePlaying(subscriptionID: subscription.id, episodeID: episode.id)
        do {
            try await engine.play(episode, preference: subscription.playbackPreference, filter: subscription.chapterFilter)
            // Cross-device RESUME (fix, 2026-07-04 — previously never
            // implemented; write-back existed but the read side didn't):
            // position roams in the synced ListeningHistoryEntry. Same
            // resume-vs-start-skip rule as iPhone (PlaybackSessionPolicy):
            // a resume beyond the start-skip wins and seeks; the engine has
            // already applied the start-skip itself otherwise.
            let resumePosition = subscriptionStore.savedListeningPosition(for: episode) ?? 0
            let start = PlaybackSessionPolicy.startResolution(
                resumeTime: resumePosition,
                startSkipSeconds: subscription.playbackPreference.startSkipSeconds
            )
            if let seekTarget = start.seekTarget {
                engine.seek(to: seekTarget)
            }
            currentTime = start.reportedStartTime
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            // currentEpisode/currentSubscriptionID stay set on purpose — see
            // file header's Failure UX note.
            errorMessage = "Couldn't play \"\(episode.title)\". Check your connection and try again."
            isPlaying = false
        }
    }

    /// Re-attempts the episode/subscription currently loaded, after a failure.
    func retry() async {
        guard let episode = currentEpisode,
              let subscriptionID = currentSubscriptionID,
              let subscription = subscriptionProvider?(subscriptionID)
        else { return }
        await play(episode: episode, subscription: subscription)
    }

    func togglePlayPause() {
        guard errorMessage == nil else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
            checkpoint()
        } else {
            engine.resume()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    func skipForward(_ seconds: TimeInterval = 30) { engine.skipForward(seconds: seconds) }
    func skipBackward(_ seconds: TimeInterval = 15) { engine.skipBackward(seconds: seconds) }
    func setSpeed(_ speed: Double) { engine.updatePlaybackSpeed(speed) }

    /// Called when the player cover is dismissed (Menu / onExitCommand).
    /// Audio keeps playing in the background (UIBackgroundModes: audio);
    /// this flushes the position AND force-pushes it so a phone pickup is
    /// current right away.
    func dismissedCover() {
        checkpoint()
    }

    /// Persist the current position locally, then force-push it to CloudKit
    /// immediately. Used on pause, player exit, and app backgrounding so a
    /// TV-side position reaches the phone within seconds rather than sitting on
    /// the engine's slow-lane debounce.
    func checkpoint() {
        flushProgress()
        onPlaybackCheckpoint?()
    }

    func stopAndClear() {
        flushProgress()
        engine.stop()
        currentEpisode = nil
        currentSubscriptionID = nil
        isPlaying = false
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Progress + auto-advance

    private func handleTimeUpdate(_ time: TimeInterval) {
        if time > currentTime { sessionListenedSeconds += (time - currentTime) }
        currentTime = time
        if let lastHistoryWriteAt, Date().timeIntervalSince(lastHistoryWriteAt) >= historyWriteInterval {
            flushProgress()
        }
        updateNowPlayingElapsed()
    }

    private func flushProgress() {
        guard let episode = currentEpisode,
              let subscriptionID = currentSubscriptionID,
              let subscription = subscriptionProvider?(subscriptionID)
        else { return }
        subscriptionStore.recordListeningProgress(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSecondsDelta: sessionListenedSeconds,
            positionSeconds: currentTime,
            durationSeconds: episode.durationSeconds
        )
        sessionListenedSeconds = 0
        lastHistoryWriteAt = Date()
    }

    private func handleFinished(_ episode: Episode) {
        guard let subscriptionID = currentSubscriptionID,
              let subscription = subscriptionProvider?(subscriptionID)
        else { return }
        subscriptionStore.markListeningHistoryFinished(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            finishedPositionSeconds: episode.durationSeconds ?? currentTime
        )
        sessionListenedSeconds = 0
        subscriptionStore.markEpisodePlayed(subscriptionID: subscription.id, episodeID: episode.id)

        // Auto-advance through the streaming Priority Stack — same policy
        // shape as iPhone's mark-played-then-advance, minus download gating.
        guard let next = upNextProvider?().first(where: { $0.id != episode.id }),
              let nextSubscription = subscriptionProvider?(next.subscriptionID)
        else {
            stopAndClear()
            return
        }
        Task { await play(episode: next, subscription: nextSubscription) }
    }

    // MARK: - Now Playing (MPNowPlayingInfoCenter + remote commands)

    private func updateNowPlayingInfo() {
        guard let episode = currentEpisode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: currentSubscriptionTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime
        ]
        if let duration = episode.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Registers Siri Remote / Control Center transport commands once. Native
    /// play/pause/skip on the remote route here even while the app is
    /// backgrounded and audio keeps playing.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, !self.isPlaying, self.currentEpisode != nil else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
    }
}
