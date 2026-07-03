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

    public private(set) var currentEpisode: Episode?
    public var isPlaying: Bool {
        guard let player else { return false }
        return player.rate != 0
    }
    /// Exposed only for video episodes so a platform view (e.g. tvOS
    /// AVPlayerViewController) can render the surface.
    public var videoPlayer: AVPlayer? {
        currentEpisode?.mediaKind == .video ? player : nil
    }
    public let capabilities: PlaybackCapabilities

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var speed: Double = 1.0
    private var endSkipSeconds: TimeInterval = 0
    private var didFinishCurrent = false
    private var chapters: [Chapter] = []
    private var chapterFilter = ChapterFilter()
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

        let item = AVPlayerItem(url: assetURL)
        let newPlayer = AVPlayer(playerItem: item)
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

    private func removeObservers() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func activateAudioSessionIfAvailable() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
