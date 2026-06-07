import Foundation

protocol QueueServicing {
    func nextPlayableEpisode(from subscriptions: [Subscription]) -> Episode?
    func downloadedQueue(from subscriptions: [Subscription]) -> [Episode]
}

final class QueueService: QueueServicing {
    func nextPlayableEpisode(from subscriptions: [Subscription]) -> Episode? {
        downloadedQueue(from: subscriptions).first
    }

    func downloadedQueue(from subscriptions: [Subscription]) -> [Episode] {
        subscriptions
            .sorted { $0.priorityRank < $1.priorityRank }
            .flatMap { subscription in
                let episodes = subscription.episodes.isEmpty
                    ? subscription.latestEpisode.map { [$0] } ?? []
                    : subscription.episodes
                return episodes
                    .filter { episode in
                        episode.downloadState == .downloaded &&
                        (episode.localFileURL != nil || episode.localFileName != nil) &&
                        episode.playedState != .played &&
                        episode.playedState != .archived
                    }
                    .sorted {
                        ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast)
                    }
                    .map { episode -> Episode in
                        var queuedEpisode = episode
                        queuedEpisode.subscriptionID = subscription.id
                        return queuedEpisode
                    }
            }
    }
}
