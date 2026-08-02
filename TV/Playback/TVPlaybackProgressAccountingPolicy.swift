import Foundation

// AI CONTEXT — Pure tvOS playback-accounting boundary.
// AVPlayer time observation reports both natural playback ticks and explicit
// seeks through the same callback. Only short, positive movement represents
// audio/video the user actually consumed. Resume restoration, scrubbing,
// skip-forward and route recovery can jump minutes or hours and must update the
// saved position without increasing listening totals. Kept pure for regression
// tests and intentionally confined to the TV target.
enum TVPlaybackProgressAccountingPolicy {
    static let maximumNaturalTick: TimeInterval = 5

    static func isNaturalPlaybackDelta(_ delta: TimeInterval) -> Bool {
        delta > 0 && delta < maximumNaturalTick
    }
}
