import Foundation
import AutohopCore

// AI CONTEXT — Persistent tvOS-only preference for browse-only Discover.
// Library playback remains governed by each synced subscription's preference.
// Discover subscriptions are transient, so TVPlaybackCoordinator reads this
// value at the request boundary and applies it only to `.discover` playback.
enum TVDiscoverPlaybackSettings {
    static let key = "tv.discover.defaultPlaybackSpeed"
    static let defaultSpeed = 1.0

    static var speed: Double {
        let stored = UserDefaults.standard.object(forKey: key) as? Double
        guard let stored,
              PlaybackPreference.speedOptions.contains(where: { abs($0 - stored) < 0.001 }) else {
            return defaultSpeed
        }
        return stored
    }
}
