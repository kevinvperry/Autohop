import Foundation

// AI CONTEXT — Pure cadence policy for tvOS listening-history uploads.
// Local position is persisted every 20 seconds, but direct database writes do
// not emit SubscriptionStore.objectWillChange. This policy permits the TV
// playback model to explicitly queue CloudKit no more than once per minute.
struct TVPlaybackProgressPushPolicy {
    static let minimumInterval: TimeInterval = 60

    static func shouldRequestPush(
        now: Date,
        lastRequestedAt: Date
    ) -> Bool {
        now.timeIntervalSince(lastRequestedAt) >= minimumInterval
    }
}
