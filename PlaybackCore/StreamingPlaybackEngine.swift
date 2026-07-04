import AVFoundation
import Foundation

// AI CONTEXT — PlaybackCore/StreamingPlaybackEngine.swift
// Phase 0 of Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md (§4.2 moves 3 + 5): the
// platform-neutral AVPlayer-only engine behind PlaybackControlling. Plays a
// local file when one exists, else STREAMS from the episode's enclosure URL
// when `capabilities.streaming` allows (asset resolution = `resolvedAssetURL`,
// the seam FUTURE_VERSIONS.md Tier 1 "instant play" will reuse on iPhone).
// Serves tvOS (Phase 3) and later the watch's Phase 3 engine; NOT used by the
// iPhone app today — iOS keeps Playback/PlaybackEngine.swift (AVAudioEngine
// trim-silence/vocal-boost path). Trim Silence / Vocal Boost are no-ops here
// (capability flags say so); speed uses AVPlayer.rate; start-skip seeks before
// play; end-skip finishes early via the periodic observer and credits
// onAutoSkip. Main-thread convention like PlaybackEngine (not actor-isolated;
// callbacks fire on the main queue via the periodic observer / notification
// queue). AVAudioSession setup is compiled out on macOS so the class stays
// headless-testable (Tests/StreamingPlaybackEngineTests.swift covers asset
// resolution and the no-source failure path; live playback is device work).
public final class StreamingPlaybackEngine: PlaybackControlling {

    public enum StreamingPlaybackError: Error, Equatable {
        /// No local file and streaming is not permitted by capabilities.
        case noPlayableSource
    }

    public var onEpisodeFinished: ((Episode) -> Void)?
    public var onTimeUpdate: ((TimeInterval) -> Void)?
    public var onPlaybackInterrupted: (() -> Void)?
    public var onPlaybackResumed: (() -> Void)?
    public var onManualSkipForward: ((TimeInterval) -> Void)?
    public var onAutoSkip: ((TimeInterval) -> Void)?
    public var onTrimSilenceSaved: ((TimeInterval) -> Void)?
    /// Fires true while the player is stalled waiting for enough buffered data
    /// to play at the requested rate (streaming start-up, or a mid-stream
    /// stall), false once it's actually playing. Drives the TV player's
    /// buffering spinner (Kevin's request 2026-07-04). KVO on
    /// `AVPlayer.timeControlStatus`.
    public var onBufferingChanged: ((Bool) -> Void)?

    public private(set) var currentEpisode: Episode?
    public var isPlaying: Bool {
        guard let player else { return false }
        return player.rate != 0
    }
    /// Exposed only for video episodes — matches PlaybackControlling's shared
    /// semantic (iPhone's PlaybackEngine hosts audio via AVAudioEngine, so
    /// `videoPlayer == nil` there means "no AVPlayerViewController surface
    /// needed"). Do not change this gating; it's relied on by that contract.
    public var videoPlayer: AVPlayer? {
        currentEpisode?.mediaKind == .video ? player : nil
    }
    /// tvOS Phase 3 (§8 item 1): the underlying AVPlayer regardless of media
    /// kind — this engine is AVPlayer-only for BOTH audio and video, so a
    /// platform using ONE `AVPlayerViewController` surface for both (per the
    /// proposal's PC-derived pattern) needs the player even for audio
    /// episodes, unlike `videoPlayer`. Not part of `PlaybackControlling` —
    /// concrete-type-only, so this can never affect iPhone's `PlaybackEngine`.
    public var avPlayer: AVPlayer? { player }
    public let capabilities: PlaybackCapabilities

    public private(set) var isBuffering = false

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var speed: Double = 1.0
    private var endSkipSeconds: TimeInterval = 0
    private var didFinishCurrent = false
    private var chapters: [Chapter] = []
    private var chapterFilter = ChapterFilter()
    /// A warm, paused player pre-buffering a likely-next asset (Continue
    /// Listening) — see `preload`. Adopted directly by `play()` when its URL
    /// matches, so playback starts near-instantly.
    private var preloadPlayer: AVPlayer?
    private var preloadURL: URL?
    /// App-layer hook that resolves an episode to an on-disk file (e.g. via the
    /// platform's DownloadManager). nil result = no local file.
    private let localFileResolver: (Episode) -> URL?

    public init(
        capabilities: PlaybackCapabilities = .tvStreaming,
        localFileResolver: @escaping (Episode) -> URL? = { _ in nil }
    ) {
        self.capabilities = capabilities
        self.localFileResolver = localFileResolver
    }

    // MARK: - Asset resolution (§4.2 move 5)

    /// `local file → else enclosure URL (when capability allows)`. Pure and
    /// static so the iPhone Tier 1 "instant play" feature can adopt the same
    /// rule later without instantiating this engine.
    public static func resolvedAssetURL(
        for episode: Episode,
        capabilities: PlaybackCapabilities,
        localFileResolver: (Episode) -> URL? = { _ in nil }
    ) -> URL? {
        if let resolved = localFileResolver(episode) {
            return resolved
        }
        if let localFileURL = episode.localFileURL,
           FileManager.default.fileExists(atPath: localFileURL.path) {
            return localFileURL
        }
        return capabilities.streaming ? episode.audioURL : nil
    }

    // MARK: - Preloading (warm the likely-next asset)

    /// Starts pre-buffering an episode's asset in a paused, muted background
    /// player so a later `play()` of the SAME episode starts almost instantly
    /// (Kevin 2026-07-04: the Continue Listening episode is the one most
    /// likely to be played next). Idempotent per URL; no-op when streaming
    /// isn't permitted or the asset can't be resolved. Cheap to call on every
    /// Home render — a matching URL is left untouched.
    public func preload(_ episode: Episode) {
        guard let assetURL = Self.resolvedAssetURL(
            for: episode,
            capabilities: capabilities,
            localFileResolver: localFileResolver
        ) else { return }

        // Already warming this exact asset, or it's the one currently playing.
        if preloadURL == assetURL || currentEpisode?.id == episode.id { return }

        clearPreload()
        let item = AVPlayerItem(url: assetURL)
        // Ask AVFoundation to build a healthy forward buffer while paused.
        item.preferredForwardBufferDuration = 30
        let warm = AVPlayer(playerItem: item)
        warm.automaticallyWaitsToMinimizeStalling = true
        warm.isMuted = true
        // A paused player with an item fills its forward buffer.
        preloadPlayer = warm
        preloadURL = assetURL
    }

    private func clearPreload() {
        preloadPlayer?.pause()
        preloadPlayer = nil
        preloadURL = nil
    }

    // MARK: - PlaybackControlling

    public func play(_ episode: Episode, preference: PlaybackPreference, filter: ChapterFilter) async throws {
        guard let assetURL = Self.resolvedAssetURL(
            for: episode,
            capabilities: capabilities,
            localFileResolver: localFileResolver
        ) else {
            throw StreamingPlaybackError.noPlayableSource
        }

        stop()
        activateAudioSessionIfAvailable()

        // Adopt the warm pre-buffered player when it matches (near-instant
        // start); otherwise build a fresh one.
        let newPlayer: AVPlayer
        if let preloadPlayer, preloadURL == assetURL {
            newPlayer = preloadPlayer
            newPlayer.isMuted = false
            self.preloadPlayer = nil
            self.preloadURL = nil
        } else {
            clearPreload()
            newPlayer = AVPlayer(playerItem: AVPlayerItem(url: assetURL))
        }
        guard let item = newPlayer.currentItem else {
            throw StreamingPlaybackError.noPlayableSource
        }

        player = newPlayer
        currentEpisode = episode
        speed = preference.speed
        endSkipSeconds = max(0, preference.endSkipSeconds)
        chapterFilter = filter
        chapters = []
        didFinishCurrent = false

        installObservers(on: newPlayer, item: item, episode: episode)

        if preference.startSkipSeconds > 0 {
            // play() is async, so the un-awaited seek overload is unavailable
            // here — await the async variant (also guarantees the skip landed
            // before the first frame plays).
            await newPlayer.seek(to: CMTime(seconds: preference.startSkipSeconds, preferredTimescale: 600))
            onAutoSkip?(preference.startSkipSeconds)
        }
        newPlayer.play()
        applyRate()
    }

    public func pause() {
        player?.pause()
    }

    public func resume() {
        player?.play()
        applyRate()
        onPlaybackResumed?()
    }

    public func skipForward(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        seek(to: currentTimeSeconds + seconds)
        onManualSkipForward?(seconds)
    }

    public func skipBackward(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        seek(to: max(0, currentTimeSeconds - seconds))
    }

    public func seek(to seconds: TimeInterval) {
        let target = max(0, seconds.isFinite ? seconds : 0)
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    public func updatePlaybackSpeed(_ speed: Double) {
        self.speed = speed
        if isPlaying { applyRate() }
    }

    // DSP effects need the complete-file AVAudioEngine path (iOS engine only);
    // capabilities report them unavailable, so these are deliberate no-ops.
    public func updateVocalBoost(_ level: VocalBoostLevel) {}
    public func updateTrimSilence(_ amount: TrimSilenceAmount) {}

    public func updateChapters(_ chapters: [Chapter], filter: ChapterFilter, for episodeID: UUID) {
        guard currentEpisode?.id == episodeID else { return }
        self.chapters = chapters
        self.chapterFilter = filter
    }

    /// Chapters for the current session (transport-bar markers on TV, Phase 3).
    public var currentChapters: [Chapter] { chapters }

    public func stop() {
        removeObservers()
        player?.pause()
        player = nil
        currentEpisode = nil
        chapters = []
        didFinishCurrent = false
        setBuffering(false)
    }

    public func setVolume(_ volume: Float) {
        player?.volume = min(max(volume, 0), 1)
    }

    // MARK: - Internals

    private var currentTimeSeconds: TimeInterval {
        guard let time = player?.currentTime().seconds, time.isFinite else { return 0 }
        return max(0, time)
    }

    private func applyRate() {
        guard let player else { return }
        let rate = Float(speed)
        if player.rate != 0 || rate > 0 {
            player.rate = rate.isFinite && rate > 0 ? rate : 1.0
        }
    }

    private func installObservers(on player: AVPlayer, item: AVPlayerItem, episode: Episode) {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.didFinishCurrent else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.onTimeUpdate?(seconds)

            // End-skip: treat the final N seconds as finished (outro skip),
            // crediting the skipped span like the iOS engine does.
            if self.endSkipSeconds > 0 {
                let duration = item.duration.seconds
                if duration.isFinite, duration > 0, seconds >= duration - self.endSkipSeconds {
                    self.finishCurrentEpisode(episode, autoSkipped: max(0, duration - seconds))
                }
            }
        }

        // Buffering: `.waitingToPlayAtSpecifiedRate` = stalled waiting for
        // data. Report the transition so the UI can show/hide its spinner.
        // Seed the initial value immediately (KVO only fires on change).
        setBuffering(player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                self?.setBuffering(observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finishCurrentEpisode(episode, autoSkipped: 0)
        }
    }

    private func finishCurrentEpisode(_ episode: Episode, autoSkipped: TimeInterval) {
        guard !didFinishCurrent else { return }
        didFinishCurrent = true
        if autoSkipped > 0 { onAutoSkip?(autoSkipped) }
        player?.pause()
        onEpisodeFinished?(episode)
    }

    private func setBuffering(_ value: Bool) {
        guard value != isBuffering else { return }
        isBuffering = value
        onBufferingChanged?(value)
    }

    private func removeObservers() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    private func activateAudioSessionIfAvailable() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
