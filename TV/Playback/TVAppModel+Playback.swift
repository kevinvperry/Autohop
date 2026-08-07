import AutohopCore

// AI CONTEXT — Temporary root facade for view compatibility. Playback request
// resolution and companion write-back are owned by TVPlaybackCoordinator.
extension TVAppModel {
    func handleBackgrounded() {
        playbackCoordinator.checkpoint()
    }

    func beginPlayback(_ episode: Episode, restartFromBeginning: Bool = false) async {
        await playbackCoordinator.beginPlayback(
            episode,
            candidateHistory: cachedContinueEntry,
            resolver: episodeResolver,
            restartFromBeginning: restartFromBeginning
        )
    }

    func beginDiscoverPlayback(_ episode: Episode, subscription: Subscription) async {
        await playbackCoordinator.beginDiscoverPlayback(episode, subscription: subscription)
    }

    func archiveEpisode(_ episode: Episode) {
        playbackCoordinator.archiveEpisode(episode)
    }
}
