import AutohopCore

// AI CONTEXT — Temporary root facade for view compatibility. Playback request
// resolution and companion write-back are owned by TVPlaybackCoordinator.
extension TVAppModel {
    func handleBackgrounded() {
        playbackCoordinator.checkpoint()
        let candidate = topShelfCandidate()
        Task { await topShelfPublisher.publishImmediately(candidate: candidate, reason: "backgroundCheckpoint") }
    }

    func beginPlayback(_ episode: Episode, restartFromBeginning: Bool = false) async {
        consumePendingDiscoverPlayNextIfNeeded(episode)
        await playbackCoordinator.beginPlayback(
            episode,
            candidateHistory: cachedContinueEntry,
            resolver: episodeResolver,
            restartFromBeginning: restartFromBeginning
        )
        scheduleTopShelfPublication(reason: "playbackStarted")
    }

    func beginDiscoverPlayback(_ episode: Episode, subscription: Subscription) async {
        consumePendingDiscoverPlayNextIfNeeded(episode)
        await playbackCoordinator.beginDiscoverPlayback(episode, subscription: subscription)
        scheduleTopShelfPublication(reason: "discoverPlaybackStarted")
    }

    func archiveEpisode(_ episode: Episode) {
        playbackCoordinator.archiveEpisode(episode)
    }

    /// Browse-only Discover episodes are held in a local Play Next overlay
    /// because tvOS must not create an iPhone subscription as a side effect.
    /// Once playback consumes that request, remove the overlay immediately so
    /// the playing episode cannot be reinserted by a stale queue snapshot.
    private func consumePendingDiscoverPlayNextIfNeeded(_ episode: Episode) {
        let key = PlaybackPositionStore.key(for: episode)
        guard queueModel.pendingDiscoverPlayNextItem?.episodeKey == key else { return }
        queueModel.pendingDiscoverPlayNextItem = nil
        if queueModel.pendingPlayNextEpisodeKey == key {
            queueModel.pendingPlayNextEpisodeKey = nil
        }
        upNextItems.removeAll { $0.episodeKey == key }
        upNextEpisodes = upNextItems.compactMap(\.episode)
        queueRows = projectQueueRows(from: upNextItems)
        AppLogger.shared.info("tv.discover.playNextConsumed", "Consumed browse-only Discover Play Next request", metadata: [
            "queueRows": "\(queueRows.count)"
        ], alwaysPersist: true)
    }
}
