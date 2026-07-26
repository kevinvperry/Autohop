import Foundation

// AI CONTEXT — PlaybackCore/StreamingPlaybackState.swift
// Truthful AVPlayer lifecycle shared by tvOS and future streaming surfaces.
// Calling AVPlayer.play() is not success: a remote item becomes ready/fails
// asynchronously. StreamingPlaybackEngine publishes this state and rejects
// callbacks from stale player generations. UI must render from this state,
// never infer playback merely from a requested command.

public enum StreamingPlaybackFailure: Error, Equatable, Sendable {
    case noSource
    case network(String)
    case http(Int)
    case unsupportedMedia
    case drm
    case notPlayable
    case noVideoTrack
    case timedOut
    case itemFailed(String)
    case playerFailed(String)
    case cancelled
    case unknown(String)

    public var userMessage: String {
        switch self {
        case .noSource: return "This episode doesn't provide a playable media link."
        case .network: return "The media couldn't be reached. Check your connection and try again."
        case .http(let status): return "The media server returned an error (HTTP \(status))."
        case .unsupportedMedia: return "This media format isn't supported on this Apple TV."
        case .drm: return "This protected media can't be played in Autohop."
        case .notPlayable: return "This media format can't be played on this Apple TV."
        case .noVideoTrack: return "This episode is marked as video, but no playable video track was found."
        case .timedOut: return "Playback took too long to start. Check your connection and try again."
        case .itemFailed, .playerFailed: return "Playback failed. Check your connection and try again."
        case .cancelled: return "Playback was cancelled."
        case .unknown: return "Playback couldn't start. Please try again."
        }
    }
}

public enum StreamingPlaybackState: Equatable, Sendable {
    case idle
    case resolvingSource
    case loadingAsset
    case preparingItem
    case ready
    case buffering
    case playing
    case paused
    case ended
    case failed(StreamingPlaybackFailure)

    public var isPlaying: Bool { self == .playing }
    public var isBuffering: Bool { self == .buffering || self == .loadingAsset || self == .preparingItem }
}
