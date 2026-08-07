import Foundation
import AutohopCore

// AI CONTEXT — tvOS playback request/write-back owner. It deliberately does
// not observe or control AVPlayer directly; TVPlaybackModel and
// StreamingPlaybackEngine remain the only player state machine.

@MainActor
final class TVPlaybackCoordinator {
    private let playbackModel: TVPlaybackModel
    private let subscriptionStore: SubscriptionStore
    var onArchiveSuppression: ((String) -> Void)?
    var onHistoryInvalidated: (() -> Void)?
    var onProjectionRefreshRequested: (() -> Void)?
    var onSyncFlushRequested: ((String) -> Void)?

    init(playbackModel: TVPlaybackModel, subscriptionStore: SubscriptionStore) {
        self.playbackModel = playbackModel
        self.subscriptionStore = subscriptionStore
    }

    func beginPlayback(
        _ episode: Episode,
        candidateHistory: ListeningHistoryEntry?,
        resolver: TVEpisodeResolver,
        restartFromBeginning: Bool = false
    ) async {
        let history = candidateHistory.flatMap {
            resolver.historyEntry($0, belongsTo: episode) ? $0 : nil
        } ?? subscriptionStore.listeningHistoryEntry(matching: episode)
        let resolution = resolver.playbackResolution(for: episode, candidateHistory: history)
        await playbackModel.play(
            episode: resolution.episode,
            subscription: resolution.subscription,
            resumePositionOverride: restartFromBeginning
                ? 0
                : resolution.historyEntry?.lastPositionSeconds,
            historyEntryID: resolution.historyEntry?.id,
            displayPodcastTitle: resolution.historyEntry?.podcastTitle,
            verifyVideoIfAmbiguous: resolution.needsAssetMediaProbe
        )
    }

    func archiveEpisode(_ episode: Episode) {
        let isCurrent = playbackModel.isCurrentEpisode(episode)
        let canonicalEpisode = TVEpisodeResolver.canonicalized(episode)
        if isCurrent { playbackModel.stopAndClear() }
        onArchiveSuppression?(PlaybackPositionStore.key(for: episode))
        subscriptionStore.markListeningHistoryArchived(episode: episode)
        let authored = subscriptionStore.markCompanionEpisodeArchived(
            canonicalEpisode,
            preferredSubscriptionID: canonicalEpisode.subscriptionID
        )
        AppLogger.shared.info("tv.episodeArchived", "Episode archived from Apple TV", metadata: [
            "episodeID": episode.id.uuidString,
            "subscriptionID": episode.subscriptionID.uuidString,
            "sourceGUID": episode.guid,
            "canonicalGUID": canonicalEpisode.guid,
            "wasCurrent": "\(isCurrent)",
            "stateAuthored": "\(authored)",
            "component": "playback"
        ], alwaysPersist: true)
        onHistoryInvalidated?()
        onProjectionRefreshRequested?()
        onSyncFlushRequested?("tv.episodeArchived")
    }

    func checkpoint() {
        playbackModel.checkpoint()
    }
}
