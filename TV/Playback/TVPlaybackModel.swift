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
    private(set) var playbackState: StreamingPlaybackState = .idle
    /// Stored Observation-tracked bridge to the engine's player. A computed
    /// passthrough did not invalidate SwiftUI when AVPlayer was installed,
    /// leaving physical Apple TV permanently on “Preparing video…”.
    private(set) var avPlayer: AVPlayer?
    /// Non-nil after a failed `play()`/mid-stream stall — see file header.
    private(set) var errorMessage: String?
    /// Increments for every user/auto-advance playback request. Async AVAsset
    /// validation is re-entrant on MainActor; without request ownership an
    /// older request could return after a newer tile tap and clear/overwrite
    /// the new player's presentation state.
    private var requestOwnership = TVPlaybackRequestOwnership()
    private(set) var playbackRequestGeneration: UInt64 = 0

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
    private var currentSubscription: Subscription?
    /// Authoritative phone-authored history key for an orphan/recovered row.
    /// Without this override, playback would create a second history record
    /// under the compatibility feed's GUID and future resume would split.
    private var currentHistoryEntryID: String?
    private var lastHistoryWriteAt: Date?
    private var lastProgressPushRequestedAt = Date.distantPast
    private var sessionListenedSeconds: TimeInterval = 0
    private let historyWriteInterval: TimeInterval = 20
    /// Effective playback speed for the stats time-saved calculation — seeded
    /// from the subscription's playbackPreference on play, updated by setSpeed.
    /// Observation-visible so native video transport controls can display the
    /// active rate and refresh their checked menu item after a change.
    private(set) var currentSpeed: Double = 1.0

    /// The underlying AVPlayer for ANY media kind (audio included) — see
    /// StreamingPlaybackEngine.avPlayer's header for why this differs from
    /// the shared protocol's video-only `videoPlayer`.
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
        engine.onPlayerChanged = { [weak self] player in
            self?.avPlayer = player
        }
        engine.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.playbackState = state
            self.isPlaying = state.isPlaying
            self.isBuffering = state.isBuffering
            if case .failed(let failure) = state {
                self.errorMessage = failure.userMessage
            }
            AppLogger.shared.info("tv.playback", "Playback lifecycle changed", metadata: [
                "state": String(describing: state),
                "episodeID": self.currentEpisode?.id.uuidString ?? "none",
                "mediaKind": self.currentEpisode.map { String(describing: $0.mediaKind) } ?? "none",
                "expectedSpeed": String(format: "%.2f", self.currentSpeed),
                "actualRate": String(format: "%.2f", Double(self.avPlayer?.rate ?? 0.0)),
                "defaultRate": String(format: "%.2f", Double(self.avPlayer?.defaultRate ?? 0.0)),
                "position": String(format: "%.1f", self.currentTime),
                "requestGeneration": "\(self.playbackRequestGeneration)"
            ], alwaysPersist: true)
        }
        configureRemoteCommands()
    }

    /// Pre-buffer a likely-next episode (the Continue Listening hero) so
    /// tapping it starts near-instantly. Cheap + idempotent; safe to call on
    /// every Home render.
    func preload(episode: Episode) {
        engine.preload(episode)
    }

    func play(
        episode: Episode,
        subscription: Subscription,
        resumePositionOverride: TimeInterval? = nil,
        historyEntryID: String? = nil,
        displayPodcastTitle: String? = nil,
        verifyVideoIfAmbiguous: Bool = false
    ) async {
        let requestGeneration = requestOwnership.begin()
        playbackRequestGeneration = requestGeneration
        let episode = verifyVideoIfAmbiguous
            ? await TVMediaTrackProbe.shared.resolvingAmbiguousMediaKind(for: episode)
            : episode
        guard requestOwnership.owns(requestGeneration) else { return }
        AppLogger.shared.info("tv.playback", "Playback requested", metadata: [
            "episodeID": episode.id.uuidString,
            "host": episode.audioURL.host ?? "unknown",
            "mediaKind": String(describing: episode.mediaKind),
            "podcast": displayPodcastTitle ?? subscription.title,
            "speed": String(format: "%.2f", subscription.playbackPreference.speed),
            "resumeOverride": resumePositionOverride.map { String(format: "%.1f", $0) } ?? "none",
            "assetExtension": episode.audioURL.pathExtension.lowercased()
        ], alwaysPersist: true)
        flushProgress()
        currentEpisode = episode
        currentSubscriptionID = subscription.id
        currentSubscription = subscription
        currentHistoryEntryID = historyEntryID
        currentSubscriptionTitle = displayPodcastTitle ?? subscription.title
        currentTime = 0
        sessionListenedSeconds = 0
        lastHistoryWriteAt = Date()
        lastProgressPushRequestedAt = Date.distantPast
        errorMessage = nil
        currentSpeed = subscription.playbackPreference.speed
        let catalogStateAuthored = subscriptionStore.markCompanionEpisodePlaying(
            episode,
            preferredSubscriptionID: subscription.id
        )
        AppLogger.shared.info("tv.playback.catalogState", "TV authored playing state for cross-device sync", metadata: [
            "episodeID": episode.id.uuidString,
            "subscriptionID": subscription.id.uuidString,
            "catalogMatch": "\(catalogStateAuthored)"
        ], alwaysPersist: true)
        statsStore.recordEpisodeStarted(subscriptionID: subscription.id, showTitle: subscription.title)
        do {
            try await engine.play(episode, preference: subscription.playbackPreference, filter: subscription.chapterFilter)
            guard requestOwnership.owns(requestGeneration) else { return }
            // Cross-device RESUME (fix, 2026-07-04 — previously never
            // implemented; write-back existed but the read side didn't):
            // position roams in the synced ListeningHistoryEntry. Same
            // resume-vs-start-skip rule as iPhone (PlaybackSessionPolicy):
            // a resume beyond the start-skip wins and seeks; the engine has
            // already applied the start-skip itself otherwise.
            let resumePosition = resumePositionOverride
                ?? subscriptionStore.savedListeningPosition(for: episode)
                ?? 0
            let start = PlaybackSessionPolicy.startResolution(
                resumeTime: resumePosition,
                startSkipSeconds: subscription.playbackPreference.startSkipSeconds
            )
            if let seekTarget = start.seekTarget {
                await engine.seekAndWait(to: seekTarget)
            }
            guard requestOwnership.owns(requestGeneration) else { return }
            AppLogger.shared.info("tv.playbackStartResolved", "Playback settings and resume applied", metadata: [
                "mediaKind": String(describing: episode.mediaKind),
                "speed": String(format: "%.2f", subscription.playbackPreference.speed),
                "resumeInput": String(format: "%.1f", resumePosition),
                "resolvedStart": String(format: "%.1f", start.reportedStartTime)
            ], alwaysPersist: true)
            currentTime = start.reportedStartTime
            updateNowPlayingInfo()
        } catch {
            guard requestOwnership.owns(requestGeneration) else { return }
            if let failure = error as? StreamingPlaybackFailure, failure == .cancelled {
                return
            }
            // currentEpisode/currentSubscriptionID stay set on purpose — see
            // file header's Failure UX note.
            if let failure = error as? StreamingPlaybackFailure {
                errorMessage = failure.userMessage
            } else {
                errorMessage = "Couldn't play \"\(episode.title)\". Check your connection and try again."
            }
        }
    }

    /// Presentation taps on the episode that is already playing must only
    /// reopen the player UI. Restarting the stream caused another 20–30 second
    /// buffer, reset the resume seek and raced the still-live AVPlayer.
    func isCurrentEpisode(_ episode: Episode) -> Bool {
        TVPlaybackPresentationPolicy.representsSameEpisode(currentEpisode, as: episode)
    }

    /// Re-attempts the episode/subscription currently loaded, after a failure.
    func retry() async {
        guard let episode = currentEpisode,
              let subscription = currentSubscription
        else { return }
        await play(
            episode: episode,
            subscription: subscription,
            resumePositionOverride: currentTime,
            historyEntryID: currentHistoryEntryID,
            displayPodcastTitle: currentSubscriptionTitle,
            verifyVideoIfAmbiguous: false
        )
    }

    func togglePlayPause() {
        guard errorMessage == nil else { return }
        if isPlaying {
            engine.pause()
            AppLogger.shared.info("tv.playback.command", "Pause requested", metadata: playbackDiagnosticMetadata())
            checkpoint()
        } else {
            // Reassert before every resume. StreamingPlaybackEngine also keeps
            // AVPlayer.defaultRate aligned, but this makes TV ownership explicit.
            engine.updatePlaybackSpeed(currentSpeed)
            engine.resume()
            AppLogger.shared.info("tv.playback.command", "Resume requested", metadata: playbackDiagnosticMetadata())
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
        updateNowPlayingInfo()
    }
    func skipBackward(_ seconds: TimeInterval = 15) {
        engine.skipBackward(seconds: seconds)
        updateNowPlayingInfo()
    }
    func setSpeed(_ speed: Double) {
        engine.updatePlaybackSpeed(speed)
        currentSpeed = speed
        updateNowPlayingInfo()
        AppLogger.shared.info("tv.playback.speed", "Playback speed changed", metadata: playbackDiagnosticMetadata())
        checkpoint()
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
        requestOwnership.invalidate()
        playbackRequestGeneration = requestOwnership.generation
        flushProgress()
        engine.stop()
        currentEpisode = nil
        currentSubscriptionID = nil
        currentSubscription = nil
        currentHistoryEntryID = nil
        isPlaying = false
        playbackState = .idle
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Progress + auto-advance

    private func handleTimeUpdate(_ time: TimeInterval) {
        if time > currentTime {
            let delta = time - currentTime
            // AI CONTEXT — Both lifetime history and daily Stats must use the
            // SAME natural-playback gate. Previously only Stats rejected large
            // forward jumps; `sessionListenedSeconds` still credited the resume
            // seek (and any scrub) as time actually heard. That made a two-hour
            // resume instantly add two hours to synced listening history.
            if TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(delta) {
                sessionListenedSeconds += delta
            }
            if TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(delta),
               let subscriptionID = currentSubscriptionID {
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
            requestProgressPushIfDue()
        }
    }

    private func flushProgress() {
        guard let episode = currentEpisode,
              let subscription = currentSubscription
        else { return }
        subscriptionStore.recordListeningProgress(
            episode: episode,
            podcastTitle: currentSubscriptionTitle,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSecondsDelta: sessionListenedSeconds,
            positionSeconds: currentTime,
            durationSeconds: episode.durationSeconds,
            historyEntryID: currentHistoryEntryID,
            playbackSpeed: currentSpeed
        )
        AppLogger.shared.info("tv.playback.progressPersisted", "TV listening position saved locally", metadata: [
            "episodeID": episode.id.uuidString,
            "historyEntryID": currentHistoryEntryID ?? "generated",
            "position": String(format: "%.1f", currentTime),
            "listenedDelta": String(format: "%.1f", sessionListenedSeconds),
            "duration": episode.durationSeconds.map { String(format: "%.1f", $0) } ?? "unknown",
            "mediaKind": String(describing: episode.mediaKind),
            "playbackSpeed": String(format: "%.2f", currentSpeed)
        ])
        sessionListenedSeconds = 0
        lastHistoryWriteAt = Date()
    }

    /// Direct history-database writes do not publish SubscriptionStore's
    /// objectWillChange, so CloudSyncEngine's ordinary observer cannot discover
    /// them. Ask the TV composition root to queue the slow lane at most once per
    /// minute during uninterrupted playback; pause/exit checkpoints remain
    /// immediate.
    private func requestProgressPushIfDue() {
        let now = Date()
        guard TVPlaybackProgressPushPolicy.shouldRequestPush(
            now: now,
            lastRequestedAt: lastProgressPushRequestedAt
        ) else { return }
        lastProgressPushRequestedAt = now
        AppLogger.shared.info("tv.playback.progressPushRequested", "Queued periodic TV listening-history upload", metadata: playbackDiagnosticMetadata())
        onPlaybackCheckpoint?()
    }

    private func playbackDiagnosticMetadata() -> [String: String] {
        [
            "episodeID": currentEpisode?.id.uuidString ?? "none",
            "mediaKind": currentEpisode.map { String(describing: $0.mediaKind) } ?? "none",
            "position": String(format: "%.1f", currentTime),
            "expectedSpeed": String(format: "%.2f", currentSpeed),
            "actualRate": String(format: "%.2f", Double(avPlayer?.rate ?? 0.0)),
            "defaultRate": String(format: "%.2f", Double(avPlayer?.defaultRate ?? 0.0)),
            "state": String(describing: playbackState),
            "requestGeneration": "\(playbackRequestGeneration)"
        ]
    }

    private func handleFinished(_ episode: Episode) {
        guard let subscription = currentSubscription
        else { return }
        subscriptionStore.markListeningHistoryFinished(
            episode: episode,
            podcastTitle: currentSubscriptionTitle,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            finishedPositionSeconds: episode.durationSeconds ?? currentTime,
            historyEntryID: currentHistoryEntryID
        )
        sessionListenedSeconds = 0
        _ = subscriptionStore.markCompanionEpisodePlayed(
            episode,
            preferredSubscriptionID: subscription.id
        )
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? currentSpeed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: currentSpeed,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime
        ]
        if let duration = episode.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
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
