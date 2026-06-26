import Foundation
import UIKit

// ============================================================================
// AI CONTEXT - CarPlay/CarPlayEpisodePresenter.swift
//
// PURPOSE: Read-only projection from Autohop's downloaded queue model into the
// small row model used by CarPlay list templates. This keeps CarPlay template
// code from knowing how to look up podcast titles, artwork fallbacks, playback
// progress, or current-episode state.
//
// CURRENT SCOPE: Phase 8 tested projection. Rows remain presentation data only:
// episode title, podcast title, optional artwork URL, optional progress, and
// whether the row is currently playing. Playback/archive/pin actions are routed
// by CarPlayCoordinator/CarPlayActionRouter, not by this presenter. No download
// or feed-refresh action belongs here.
// ============================================================================

struct CarPlayEpisodeRow: Identifiable, Equatable {
    let id: UUID
    let episode: Episode
    let title: String
    let podcastTitle: String
    let artworkURL: URL?
    let playbackProgress: Double?
    let isCurrentEpisode: Bool
}

@MainActor
struct CarPlayEpisodePresenter {
    func rows(from appState: AppState) -> [CarPlayEpisodeRow] {
        appState.downloadedQueue.compactMap { episode in
            guard let subscription = appState.subscriptionStore.subscription(id: episode.subscriptionID),
                  let podcastTitle = appState.podcastTitle(for: episode)
            else {
                return nil
            }

            return CarPlayEpisodeRow(
                id: episode.id,
                episode: episode,
                title: episode.title,
                podcastTitle: podcastTitle,
                artworkURL: episode.artworkURL ?? subscription.artworkURL,
                playbackProgress: progress(for: episode, appState: appState),
                isCurrentEpisode: appState.currentPlayerEpisode?.id == episode.id
            )
        }
    }

    func currentMetadata(from appState: AppState) -> (episode: Episode, podcastTitle: String, artworkURL: URL?, speed: Double)? {
        guard let episode = appState.currentPlayerEpisode,
              let subscription = appState.subscriptionStore.subscription(id: episode.subscriptionID)
        else { return nil }

        return (
            episode,
            subscription.title,
            episode.artworkURL ?? subscription.artworkURL,
            appState.effectiveSpeed(for: subscription)
        )
    }

    private func progress(for episode: Episode, appState: AppState) -> Double? {
        guard let duration = episode.durationSeconds, duration > 0 else { return nil }
        let elapsed = appState.effectivePlaybackTime(for: episode)
        guard elapsed > 0 else { return nil }
        return min(1, max(0, elapsed / duration))
    }
}
