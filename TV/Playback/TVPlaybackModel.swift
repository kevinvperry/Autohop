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
    /// TV LISTENING STATS (2026-07-11): every playback tick's forward delta is
    /// recorded via addListeningTime (same call the iPhone makes), plus episode
    /// started/completed and manual skip-forward events. DayStats sync is
    /// additive per (deviceID, dayKey) — the phone's Stats page sums this TV's
    /// partition in automatically (SYNC_DESIGN.md 5b). The store internally
    /// coalesces sync-DB writes (~10 s throttle), so per-tick calls are cheap;
    /// checkpoint() flushes buckets BEFORE the CloudKit force-push so the
    /// engine's queue scan sees the freshest day rows (same ordering rule as
    /// iOS's lifecycle flush).
    private let statsStore: ListeningStatsStore

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
    /// Effective playback speed for the stats time-saved calculation — seeded
    /// from the subscription's playbackPreference on play, updated by setSpeed.
    private var currentSpeed: Double = 1.0

    /// The underlying AVPlayer for ANY media kind (audio included) — see
    /// StreamingPlaybackEngine.avPlayer's header for why this differs from
    /// the shared protocol's video-only `videoPlayer`.
    var avPlayer: AVPlayer? { engine.avPlayer }
    var currentChapters: [Chapter] { engine.currentChapters }
    var capabilities: PlaybackCapabilities { engine.capabilities }

    init(subscriptionStore: SubscriptionStore, statsStore: ListeningStatsStore) {
        self.subscriptionStore = subscriptionStore
        self.statsStore = statsStore
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
        currentSpeed = subscription.playbackPreference.speed
        subscriptionStore.markEpisodePlaying(subscriptionID: subscription.id, episodeID: episode.id)
        statsStore.recordEpisodeStarted(subscriptionID: subscription.id, showTitle: subscription.title)
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

    // MARK: - Chapters (windowed-player navigation, 2026-07-11 — Kevin's
    // round 9: "chapter control is only available in full screen view").
    // Uses PlaybackSessionPolicy's prev/next-start logic (Phase 0) over the
    // engine's active (filter-applied) chapter list.

    /// The active chapter at the current playhead, nil when the episode has
    /// no chapters (drives whether the windowed player shows chapter controls).
    var currentChapter: Chapter? {
        currentChapters.last { $0.startSeconds <= currentTime }
            ?? currentChapters.first
    }

    func skipToNextChapter() {
        guard let current = currentChapter,
              let target = PlaybackSessionPolicy.nextChapterStart(from: current, in: currentChapters)
        else { return }
        engine.seek(to: target)
    }

    func skipToPreviousChapter() {
        guard let current = currentChapter else { return }
        // Standard player semantics: mid-chapter goes back to the CURRENT
        // chapter's start; near the start (< 3 s in) goes to the previous one.
        if currentTime - current.startSeconds > 3 {
            engine.seek(to: current.startSeconds)
            return
        }
        guard let target = PlaybackSessionPolicy.previousChapterStart(from: current, in: currentChapters) else {
            engine.seek(to: current.startSeconds)
            return
        }
        engine.seek(to: target)
    }

    func skipForward(_ seconds: TimeInterval = 30) {
        engine.skipForward(seconds: seconds)
        // Same stats semantics as iPhone: a deliberate skip forward is time saved.
        statsStore.addManualSkipForward(seconds, subscriptionID: currentSubscriptionID)
    }
    func skipBackward(_ seconds: TimeInterval = 15) { engine.skipBackward(seconds: seconds) }
    func setSpeed(_ speed: Double) {
        engine.updatePlaybackSpeed(speed)
        currentSpeed = speed
    }

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
        // Stats buckets flush BEFORE the force-push so the engine's queue scan
        // sees the freshest day rows (same ordering as iOS's lifecycle flush).
        statsStore.flushPendingStatsDays(reason: "tv.checkpoint")
        statsStore.save()
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
        if time > currentTime {
            let delta = time - currentTime
            sessionListenedSeconds += delta
            // A forward tick is genuine listened time — record it into the
            // synced day bucket. The < 5 s guard keeps a forward SEEK's jump
            // (skip-30 lands here as one big delta) out of the wall-clock
            // stats; real ticks arrive every ~0.5 s.
            if delta < 5, let subscriptionID = currentSubscriptionID {
                statsStore.addListeningTime(
                    delta,
                    speed: currentSpeed,
                    subscriptionID: subscriptionID,
                    showTitle: currentSubscriptionTitle
                )
            }
        }
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
        statsStore.recordEpisodeCompleted(subscriptionID: subscription.id)

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
