import AVFoundation
import Foundation

// AI CONTEXT — PlaybackCore/PlaybackControlling.swift
// Phase 0 of Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md (§4.2 move 3): the
// playback-engine seam, MOVED VERBATIM out of Playback/PlaybackEngine.swift
// into AutohopCore so every platform target can compile against it. Two
// conformers: iOS PlaybackEngine (Playback/, app target only — AVAudioEngine
// trim-silence/vocal-boost path, unchanged) and StreamingPlaybackEngine
// (PlaybackCore/, AVPlayer-only, serves tvOS and later the watch). The ONLY
// additions over the historical protocol are `capabilities` and
// `updateEpisodeTrim`: surfaces read capability flags instead of hardcoding
// platforms, while a settings edit can update the active session's end boundary
// without restarting audio. Start trim is retained for session consistency but
// never seeks an episode that is already underway.
// Do not add iOS-only requirements here; platform-specific behavior belongs on
// the concrete engines behind capability flags.
public protocol PlaybackControlling {
    var onEpisodeFinished: ((Episode) -> Void)? { get set }
    var onTimeUpdate: ((TimeInterval) -> Void)? { get set }
    var onPlaybackInterrupted: (() -> Void)? { get set }
    var onPlaybackResumed: (() -> Void)? { get set }
    /// Called when the user taps skip-forward. Parameter is seconds actually skipped.
    var onManualSkipForward: ((TimeInterval) -> Void)? { get set }
    /// Called when start/end skip fires automatically. Parameter is seconds skipped.
    var onAutoSkip: ((TimeInterval) -> Void)? { get set }
    /// Called from the buffer-read loop (background thread) with seconds of silence removed.
    var onTrimSilenceSaved: ((TimeInterval) -> Void)? { get set }
    var currentEpisode: Episode? { get }
    var isPlaying: Bool { get }
    var videoPlayer: AVPlayer? { get }
    /// What this engine can do on this platform — UI reads these flags instead
    /// of hardcoding platform checks (Phase 0, tvOS proposal §4.2 move 4).
    var capabilities: PlaybackCapabilities { get }

    func play(_ episode: Episode, preference: PlaybackPreference, filter: ChapterFilter) async throws
    func pause()
    func resume()
    func skipForward(seconds: TimeInterval)
    func skipBackward(seconds: TimeInterval)
    func seek(to seconds: TimeInterval)
    func updatePlaybackSpeed(_ speed: Double)
    func updateVocalBoost(_ level: VocalBoostLevel)
    func updateTrimSilence(_ amount: TrimSilenceAmount)
    func updateEpisodeTrim(startSkipSeconds: TimeInterval, endSkipSeconds: TimeInterval)
    /// Applies chapters that were fetched after playback already started (e.g. an
    /// external `podcast:chapters` JSON feed) to the live session, so chapter
    /// display and chapter-skip filtering work without the fetch having blocked
    /// the first audio frame. No-op if `episodeID` is no longer the one playing.
    func updateChapters(_ chapters: [Chapter], filter: ChapterFilter, for episodeID: UUID)
    func stop()
    /// Set the output volume on the active playback path. 0 = silent, 1 = full.
    func setVolume(_ volume: Float)
}
