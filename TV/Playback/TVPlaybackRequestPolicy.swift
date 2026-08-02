import AutohopCore

// AI CONTEXT — Pure tvOS playback request ownership and presentation identity.
// A tile tap may arrive while AVAsset validation for an older tap is suspended.
// Only the newest generation may publish failure/resume UI. Reopening the same
// enclosure is presentation-only and must not restart or rebuffer the stream.
struct TVPlaybackRequestOwnership {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func owns(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

enum TVPlaybackPresentationPolicy {
    static func representsSameEpisode(_ current: Episode?, as selected: Episode) -> Bool {
        guard let current else { return false }
        return current.id == selected.id
            || current.audioURL == selected.audioURL
            || PlaybackPositionStore.key(for: current)
                == PlaybackPositionStore.key(for: selected)
    }
}
