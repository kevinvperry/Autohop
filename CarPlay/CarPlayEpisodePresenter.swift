import Foundation
import UIKit

// ============================================================================
// AI CONTEXT - CarPlay/CarPlayEpisodePresenter.swift
//
// PURPOSE: Read-only projection from Autohop's downloaded queue/subscription
// model into the small row models used by CarPlay list templates. This keeps
// CarPlay template code from knowing how to look up podcast titles, artwork
// fallbacks, playback progress, subscription priority order, or current-episode
// state.
//
// CURRENT SCOPE: Tested projection for Up Next plus the CarPlay Subscriptions
// browser. Up Next remains downloaded-only. Subscription episode lists mirror
// PodcastDetailView by showing the subscription's recent feed episodes, including
// played, archived, and not-yet-downloaded rows; the coordinator asks for driver
// confirmation and routes the manual download before Play Now/Next/Last when
// needed.
// Rows remain presentation data only: subscription title/counts, episode title,
// podcast title, optional artwork URL, optional progress, current-episode state,
// and whether a download is required. Playback/archive/pin/download actions are
// routed by CarPlayCoordinator/CarPlayActionRouter, not by this presenter. No
// feed-refresh, search, podcast discovery, or subscription-management action
// belongs here.
// ============================================================================

struct CarPlaySubscriptionRow: Identifiable, Equatable {
    let id: UUID
    let subscription: Subscription
    let title: String
    let artworkURL: URL?
    let availableEpisodeCount: Int
    let isInactive: Bool
}

struct CarPlayEpisodeRow: Identifiable, Equatable {
    let id: UUID
    let episode: Episode
    let title: String
    let podcastTitle: String
    let artworkURL: URL?
    let playbackProgress: Double?
    let isCurrentEpisode: Bool
    let requiresDownload: Bool
}

@MainActor
struct CarPlayEpisodePresenter {
    func subscriptionRows(from appState: AppState) -> [CarPlaySubscriptionRow] {
        appState.subscriptionStore.subscriptions
            .filter { $0.browseDate == nil }
            .sorted {
                if $0.priorityRank != $1.priorityRank {
                    return $0.priorityRank < $1.priorityRank
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .map { subscription in
                CarPlaySubscriptionRow(
                    id: subscription.id,
                    subscription: subscription,
                    title: subscription.title,
                    artworkURL: subscription.artworkURL,
                    availableEpisodeCount: availableEpisodes(in: subscription).count,
                    isInactive: subscription.excludeFromAutoFeedRefresh
                )
            }
    }

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
                isCurrentEpisode: appState.currentPlayerEpisode?.id == episode.id,
                requiresDownload: requiresDownload(episode)
            )
        }
    }

    func episodeRows(for subscription: Subscription, appState: AppState) -> [CarPlayEpisodeRow] {
        availableEpisodes(in: subscription)
            .sorted {
                if ($0.publishedAt ?? .distantPast) != ($1.publishedAt ?? .distantPast) {
                    return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .map { episode in
                var projectedEpisode = episode
                projectedEpisode.subscriptionID = subscription.id
                return CarPlayEpisodeRow(
                    id: projectedEpisode.id,
                    episode: projectedEpisode,
                    title: projectedEpisode.title,
                    podcastTitle: subscription.title,
                    artworkURL: projectedEpisode.artworkURL ?? subscription.artworkURL,
                    playbackProgress: progress(for: projectedEpisode, appState: appState),
                    isCurrentEpisode: appState.currentPlayerEpisode?.id == projectedEpisode.id,
                    requiresDownload: requiresDownload(projectedEpisode)
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

    private func availableEpisodes(in subscription: Subscription) -> [Episode] {
        let episodes = subscription.episodes.isEmpty
            ? subscription.latestEpisode.map { [$0] } ?? []
            : subscription.episodes
        return episodes.map { episode in
            var projectedEpisode = episode
            projectedEpisode.subscriptionID = subscription.id
            return projectedEpisode
        }
    }

    private func requiresDownload(_ episode: Episode) -> Bool {
        episode.downloadState != .downloaded ||
        (episode.localFileURL == nil && episode.localFileName == nil)
    }
}
