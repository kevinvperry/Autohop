import Foundation

// AI CONTEXT — Widget-target compile witness only. Real playback is implemented
// in the containing Autohop application. Never add database or audio access here.

@available(iOS 17.0, *)
extension PlayAutohopEpisodeIntent {
    @MainActor
    func intentPlayback(
        subscriptionID: String,
        episodeKey: String
    ) async {
        // Intentionally empty. The system dispatches AudioPlaybackIntent to the
        // containing app's implementation.
    }
}
