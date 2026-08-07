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
    public var onStateChanged: ((StreamingPlaybackState) -> Void)?
    /// Publishes the concrete player whenever it is installed or cleared.
    /// UI adapters must not poll the computed `avPlayer` passthrough because
    /// the engine itself is deliberately not Observation-coupled.
    public var onPlayerChanged: ((AVPlayer?) -> Void)?

    public private(set) var currentEpisode: Episode?
    public private(set) var state: StreamingPlaybackState = .idle
    public var isPlaying: Bool { state.isPlaying }
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

    public var isBuffering: Bool { state.isBuffering }

    private var player: AVPlayer? {
        didSet {
            guard oldValue !== player else { return }
            onPlayerChanged?(player)
        }
    }
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var failedObserver: NSObjectProtocol?
    private var playbackGeneration: UInt64 = 0
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
        guard episode.mediaKind != .video else { return }
        guard let assetURL = Self.resolvedAssetURL(
            for: episode,
            capabilities: capabilities,
            localFileResolver: localFileResolver
        ) else { return }

        // Already warming this exact asset, or it's the one currently playing.
        if preloadURL == assetURL || currentEpisode?.id == episode.id { return }

        clearPreload()
        let item = AVPlayerItem(asset: Self.asset(for: assetURL))
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

    /// AVFoundation otherwise emits its generic system identity for streamed
    /// enclosures. AVURLAssetHTTPUserAgentKey is Apple's supported API for
    /// applying the same IAB-style podcast identity as URLSession.
    private static func asset(for url: URL) -> AVURLAsset {
        guard url.isFileURL == false else { return AVURLAsset(url: url) }
        return AVURLAsset(
            url: url,
            options: [AVURLAssetHTTPUserAgentKey: PodcastUserAgent.value]
        )
    }

    // MARK: - PlaybackControlling

    public func play(_ episode: Episode, preference: PlaybackPreference, filter: ChapterFilter) async throws {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        stopCurrentPlayer(resetState: false)
        transition(to: .resolvingSource)
        guard let assetURL = Self.resolvedAssetURL(
            for: episode,
            capabilities: capabilities,
            localFileResolver: localFileResolver
        ) else {
            transition(to: .failed(.noSource))
            throw StreamingPlaybackFailure.noSource
        }

        activateAudioSessionIfAvailable(for: episode.mediaKind)
        transition(to: .loadingAsset)
        let asset = Self.asset(for: assetURL)
        do {
            try await validate(asset: asset, mediaKind: episode.mediaKind)
        } catch let failure as StreamingPlaybackFailure {
            transition(to: .failed(failure))
            throw failure
        } catch {
            let failure = classifyAssetError(error)
            transition(to: .failed(failure))
            throw failure
        }

        // Adopt the warm pre-buffered player when it matches (near-instant
        // start); otherwise build a fresh one.
        let newPlayer: AVPlayer
        if episode.mediaKind != .video, let preloadPlayer, preloadURL == assetURL {
            newPlayer = preloadPlayer
            newPlayer.isMuted = false
            self.preloadPlayer = nil
            self.preloadURL = nil
        } else {
            clearPreload()
            newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        guard let item = newPlayer.currentItem else {
            transition(to: .failed(.noSource))
            throw StreamingPlaybackFailure.noSource
        }

        player = newPlayer
        currentEpisode = episode
        speed = preference.speed
        endSkipSeconds = max(0, preference.endSkipSeconds)
        chapterFilter = filter
        chapters = episode.chapters
        didFinishCurrent = false

        transition(to: .preparingItem)
        installObservers(on: newPlayer, item: item, episode: episode, generation: generation)

        let deadline = Date().addingTimeInterval(20)
        while item.status == .unknown, Date() < deadline {
            try Task.checkCancellation()
            guard generation == playbackGeneration else { throw StreamingPlaybackFailure.cancelled }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard generation == playbackGeneration else { throw StreamingPlaybackFailure.cancelled }
        guard item.status == .readyToPlay else {
            let failure: StreamingPlaybackFailure = item.status == .failed
                ? .itemFailed(item.error?.localizedDescription ?? "unknown")
                : .timedOut
            transition(to: .failed(failure))
            throw failure
        }
        transition(to: .ready)

        if preference.startSkipSeconds > 0 {
            // play() is async, so the un-awaited seek overload is unavailable
            // here — await the async variant (also guarantees the skip landed
            // before the first frame plays).
            await newPlayer.seek(to: CMTime(seconds: preference.startSkipSeconds, preferredTimescale: 600))
            onAutoSkip?(preference.startSkipSeconds)
        }
        applyRate(to: newPlayer)
        newPlayer.playImmediately(atRate: effectiveRate)
        transition(to: newPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .playing)
    }

    public func pause() {
        player?.pause()
        if currentEpisode != nil { transition(to: .paused) }
    }

    public func resume() {
        if let player {
            applyRate(to: player)
            player.playImmediately(atRate: effectiveRate)
        }
        transition(to: player?.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .playing)
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

    /// Performs an exact seek and waits for AVPlayer to acknowledge it. tvOS
    /// uses this for cross-device resume: a fire-and-forget seek issued just
    /// after `play()` could lose a race with remote-item startup and leave the
    /// episode playing from zero even though the Home card showed progress.
    public func seekAndWait(to seconds: TimeInterval) async {
        guard let player else { return }
        let target = max(0, seconds.isFinite ? seconds : 0)
        await player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    public func updatePlaybackSpeed(_ speed: Double) {
        self.speed = speed
        if let player {
            player.defaultRate = effectiveRate
            if isPlaying { player.rate = effectiveRate }
        }
    }

    // DSP effects need the complete-file AVAudioEngine path (iOS engine only);
    // capabilities report them unavailable, so these are deliberate no-ops.
    public func updateVocalBoost(_ level: VocalBoostLevel) {}
    public func updateVolumeAdjustment(_ adjustment: Int) {
        // Streaming/tvOS is not a Version 1.4 shipping surface. Keep protocol
        // compatibility without pretending AVPlayer.volume can amplify above 1.
    }
    public func updateTrimSilence(_ amount: TrimSilenceAmount) {}
    /// Streaming/tvOS currently remains AVPlayer-only; the iPhone audio engine
    /// performs the Mono fold-down. Retain preference compatibility as a no-op.
    public func updateAudioChannelMode(_ mode: AudioChannelMode) {}

    /// AI CONTEXT — tvOS/streaming live trim update. Only end trim can affect an
    /// already-started AVPlayer session; start trim remains a next-play setting.
    public func updateEpisodeTrim(startSkipSeconds: TimeInterval, endSkipSeconds: TimeInterval) {
        self.endSkipSeconds = max(0, endSkipSeconds)
    }

    public func updateChapters(_ chapters: [Chapter], filter: ChapterFilter, for episodeID: UUID) {
        guard currentEpisode?.id == episodeID else { return }
        self.chapters = chapters
        self.chapterFilter = filter
    }

    public func updateChapterFilter(_ filter: ChapterFilter, for episodeID: UUID) {
        guard currentEpisode?.id == episodeID else { return }
        chapterFilter = filter
        guard let item = player?.currentItem, let episode = currentEpisode else { return }
        skipDisabledChapterIfNeeded(at: currentTimeSeconds, episode: episode, item: item)
    }

    /// Chapters for the current session (transport-bar markers on TV, Phase 3).
    public var currentChapters: [Chapter] { chapters }

    public func stop() {
        playbackGeneration &+= 1
        stopCurrentPlayer(resetState: true)
    }

    private func stopCurrentPlayer(resetState: Bool) {
        removeObservers()
        player?.pause()
        player = nil
        currentEpisode = nil
        chapters = []
        didFinishCurrent = false
        if resetState { transition(to: .idle) }
    }

    public func setVolume(_ volume: Float) {
        player?.volume = min(max(volume, 0), 1)
    }

    // MARK: - Internals

    private var currentTimeSeconds: TimeInterval {
        guard let time = player?.currentTime().seconds, time.isFinite else { return 0 }
        return max(0, time)
    }

    private func validate(asset: AVURLAsset, mediaKind: EpisodeMediaKind) async throws {
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw StreamingPlaybackFailure.notPlayable }
        if mediaKind == .video {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else { throw StreamingPlaybackFailure.noVideoTrack }
        }
    }

    private func classifyAssetError(_ error: Error) -> StreamingPlaybackFailure {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .network(nsError.localizedDescription) }
        if nsError.domain == AVFoundationErrorDomain {
            if nsError.code == AVError.contentIsProtected.rawValue { return .drm }
            if nsError.code == AVError.fileFormatNotRecognized.rawValue { return .unsupportedMedia }
        }
        return .unknown(nsError.localizedDescription)
    }

    private var effectiveRate: Float {
        let requested = Float(speed)
        return requested.isFinite && requested > 0 ? requested : 1.0
    }

    /// `play()` resumes at `defaultRate`; setting only `rate` is transient and
    /// AVPlayer may restore 1× after a pause/buffer transition. Keep both values
    /// aligned, then use `playImmediately(atRate:)` for explicit resumption.
    private func applyRate(to player: AVPlayer) {
        player.defaultRate = effectiveRate
        if player.rate != 0 {
            player.rate = effectiveRate
        }
    }

    private func installObservers(on player: AVPlayer, item: AVPlayerItem, episode: Episode, generation: UInt64) {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, generation == self.playbackGeneration, !self.didFinishCurrent else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.onTimeUpdate?(seconds)
            self.skipDisabledChapterIfNeeded(at: seconds, episode: episode, item: item)

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
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    if abs(observedPlayer.rate - self.effectiveRate) > 0.001 {
                        observedPlayer.defaultRate = self.effectiveRate
                        observedPlayer.rate = self.effectiveRate
                    }
                    self.transition(to: .playing)
                case .waitingToPlayAtSpecifiedRate: self.transition(to: .buffering)
                case .paused where self.state.isPlaying || self.state.isBuffering: self.transition(to: .paused)
                default: break
                }
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration, observedItem.status == .failed else { return }
                self.transition(to: .failed(.itemFailed(observedItem.error?.localizedDescription ?? "unknown")))
            }
        }
        playerStatusObservation = player.observe(\.status, options: [.new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration, observedPlayer.status == .failed else { return }
                self.transition(to: .failed(.playerFailed(observedPlayer.error?.localizedDescription ?? "unknown")))
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finishCurrentEpisode(episode, autoSkipped: 0)
        }
        failedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, generation == self.playbackGeneration else { return }
            self.transition(to: .failed(.itemFailed(item.error?.localizedDescription ?? "failedToPlayToEnd")))
        }
    }

    private func finishCurrentEpisode(_ episode: Episode, autoSkipped: TimeInterval) {
        guard !didFinishCurrent else { return }
        didFinishCurrent = true
        if autoSkipped > 0 { onAutoSkip?(autoSkipped) }
        player?.pause()
        transition(to: .ended)
        onEpisodeFinished?(episode)
    }

    /// Mirrors the iOS engine's position filter for tvOS/streaming playback.
    private func skipDisabledChapterIfNeeded(at seconds: TimeInterval, episode: Episode, item: AVPlayerItem) {
        let ordered = chapters.sorted { $0.startSeconds < $1.startSeconds }
        guard let current = ordered.last(where: { $0.startSeconds <= seconds }),
              !chapterFilter.allows(position: current.position) else { return }
        if let next = ordered.first(where: {
            $0.startSeconds > seconds && chapterFilter.allows(position: $0.position)
        }) {
            seek(to: next.startSeconds)
            return
        }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            finishCurrentEpisode(episode, autoSkipped: max(0, duration - seconds))
        }
    }

    private func transition(to newState: StreamingPlaybackState) {
        guard state != newState else { return }
        let wasBuffering = state.isBuffering
        state = newState
        if wasBuffering != newState.isBuffering { onBufferingChanged?(newState.isBuffering) }
        onStateChanged?(newState)
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
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        failedObserver = nil
    }

    private func activateAudioSessionIfAvailable(for mediaKind: EpisodeMediaKind) {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let mode: AVAudioSession.Mode = mediaKind == .video ? .moviePlayback : .spokenAudio
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: mode)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
