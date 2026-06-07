import Foundation
import MediaPlayer
import UIKit

/// Manages the lock-screen / Control Centre Now Playing card and remote controls.
///
/// Call `configure(onPlayPause:onSeek:onSkipForward:onSkipBackward:onNextTrack:)` once
/// from `AppState.bootstrap()` to register the hardware/AirPods command handlers.
@MainActor
final class NowPlayingService {

    static let shared = NowPlayingService()

    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var commandsRegistered = false
    private var onSeek: ((TimeInterval) -> Void)?

    private init() {}

    // MARK: - Command registration

    func configure(
        onPlayPause: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void,
        onSkipForward: @escaping (TimeInterval) -> Void,
        onSkipBackward: @escaping (TimeInterval) -> Void,
        onNextTrack: @escaping () -> Void
    ) {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        self.onSeek = onSeek

        let center = MPRemoteCommandCenter.shared()

        // Play / pause / toggle
        center.playCommand.addTarget  { _ in onPlayPause(); return .success }
        center.pauseCommand.addTarget { _ in onPlayPause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in onPlayPause(); return .success }

        // Skip forward / backward (AirPods double/triple tap, lock screen buttons)
        updateSkipIntervals(forward: 30, backward: 15)
        center.skipForwardCommand.addTarget { event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            onSkipForward(e.interval)
            return .success
        }
        center.skipBackwardCommand.addTarget { event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            onSkipBackward(e.interval)
            return .success
        }

        // Next episode
        center.nextTrackCommand.addTarget { _ in onNextTrack(); return .success }

        // Previous track — not meaningful for a podcast queue, keep disabled
        center.previousTrackCommand.isEnabled = false

        // Scrubber — registered separately so it can be toggled at runtime
        refreshScrubbingCommand(enabled: true)
    }

    /// Enable or disable the lock screen scrubber without re-registering all commands.
    func refreshScrubbingCommand(enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.removeTarget(nil)
        guard enabled, let onSeek else { return }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            onSeek(e.positionTime)
            return .success
        }
    }

    func updateSkipIntervals(forward: TimeInterval, backward: TimeInterval) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: max(1, forward))]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: max(1, backward))]
    }

    // MARK: - Now Playing info

    func update(
        episode: Episode,
        podcastTitle: String,
        currentTime: TimeInterval,
        duration: TimeInterval?,
        speed: Double,
        isPlaying: Bool,
        artworkURL: URL?
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:                   episode.title,
            MPMediaItemPropertyArtist:                  podcastTitle,
            MPMediaItemPropertyAlbumTitle:              podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate:        isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType:           MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        // Use cached artwork immediately if available, then load if not.
        if let url = artworkURL, let cached = artworkCache[url] {
            info[MPMediaItemPropertyArtwork] = cached
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let url = artworkURL, artworkCache[url] == nil {
            loadAndCacheArtwork(url: url)
        }
    }

    /// Lightweight update called every 0.5 s — only refreshes position and rate.
    func updateTime(currentTime: TimeInterval, isPlaying: Bool, speed: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate]        = isPlaying ? speed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo   = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Artwork loading

    private func loadAndCacheArtwork(url: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            // Patch into current now-playing info if still the same URL.
            artworkCache[url] = artwork
            if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
