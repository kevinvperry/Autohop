import Foundation

// AI CONTEXT — App-side execution witness for PlayAutohopEpisodeIntent.
// Bootstraps the one production graph if necessary, then delegates all identity
// validation and transport policy to WidgetPlaybackIntentHandler.

@available(iOS 17.0, *)
extension PlayAutohopEpisodeIntent {
    @MainActor
    func intentPlayback(
        subscriptionID: String,
        episodeKey: String
    ) async {
        let appState = AppState.sharedOrBootstrap()
        await WidgetPlaybackIntentHandler(appState: appState).perform(
            subscriptionID: subscriptionID,
            episodeKey: episodeKey
        )
    }
}
