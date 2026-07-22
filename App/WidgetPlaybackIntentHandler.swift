import Foundation

// AI CONTEXT — App/WidgetPlaybackIntentHandler.swift
//
// PURPOSE:
// Stage 3 security/policy boundary for widget playback. It resolves the
// untrusted stable identity at perform time, permits only downloaded and
// unarchived/unplayed media, toggles the current item or delegates deliberate
// selection to AppState's existing PlaybackTransportWorkflow façade, and asks
// the widget projection to correct itself after every outcome.
//
// INVARIANTS:
// No second player, direct engine calls, database access, queue mutation, or
// stale Episode.id assumptions. Selecting another row retains Play Now's
// existing Play Instant cancellation and position-checkpoint semantics.

@MainActor
struct WidgetPlaybackIntentHandler {
    let appState: AppState
    private let logger = AppLogger.shared

    func perform(subscriptionID: String, episodeKey: String) async {
        guard let id = UUID(uuidString: subscriptionID),
              !episodeKey.isEmpty,
              let episode = resolve(subscriptionID: id, episodeKey: episodeKey),
              isPlayable(episode) else {
            logger.warning(
                "widget.intentRejected",
                "Widget playback identity is stale or not playable",
                metadata: [
                    "subscriptionID": subscriptionID,
                    "hasEpisodeKey": "\(!episodeKey.isEmpty)"
                ],
                alwaysPersist: true
            )
            appState.requestWidgetSnapshotPublication(
                reason: "intent.rejected"
            )
            return
        }

        let current = appState.playbackCoordinator.currentEpisode
        if current.map(stableIdentity) == stableIdentity(episode) {
            await appState.togglePlayPause()
        } else {
            await appState.playEpisode(episode)
        }
        logger.info(
            "widget.intentPerformed",
            "Widget playback action completed",
            metadata: [
                "episode": episode.title,
                "action": current.map(stableIdentity) == stableIdentity(episode)
                    ? "toggle"
                    : "playNow"
            ]
        )
        appState.requestWidgetSnapshotPublication(
            reason: "intent.completed"
        )
    }

    private func resolve(
        subscriptionID: UUID,
        episodeKey: String
    ) -> Episode? {
        guard let subscription = appState.subscriptionStore.subscription(
            id: subscriptionID
        ) else { return nil }
        let candidates = subscription.episodes.isEmpty
            ? subscription.latestEpisode.map { [$0] } ?? []
            : subscription.episodes
        return candidates.first {
            PlaybackPositionStore.key(for: $0) == episodeKey
        }
    }

    private func isPlayable(_ episode: Episode) -> Bool {
        episode.downloadState == .downloaded
            && (episode.localFileURL != nil || episode.localFileName != nil)
            && episode.playedState != .played
            && episode.playedState != .archived
    }

    private func stableIdentity(_ episode: Episode) -> String {
        "\(episode.subscriptionID.uuidString)|\(PlaybackPositionStore.key(for: episode))"
    }
}
