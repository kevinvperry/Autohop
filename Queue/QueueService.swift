import Foundation

// AI CONTEXT — Queue/QueueService.swift
// REPLAY (Version 1.7, 2026-09-12): Replay membership is logical before local download; already downloaded ordinary items remain visible and consume owner-local capacity.
// Replay returns logical released entries even before local download; callers
// preserve order and use the existing download-before-play path. Ordinary feeds
// retain downloaded-only eligibility.
// Pure, stateless queue-ordering logic — THE core "Priority Stack" rule:
// walk subscriptions by ascending priorityRank; within each podcast, order
// episodes oldest-published first; include ONLY episodes that are downloaded
// (with a local file), not played, and not archived. Browse subscriptions are
// filtered out upstream by SubscriptionStore accessors. Manual Play Next /
// Play Last overrides are NOT applied here — QueueModel.applyPins (same
// directory) layers the pinned-ID lists on top; AppState delegates to it.
// PUBLIC + in AutohopCore since Phase 0 (tvOS proposal §4.2) so every surface
// (iPhone, CarPlay, tvOS, watch) composes the queue from one implementation.
public protocol QueueServicing {
    func nextPlayableEpisode(from subscriptions: [Subscription]) -> Episode?
    func downloadedQueue(from subscriptions: [Subscription]) -> [Episode]
}

public final class QueueService: QueueServicing {
    public init() {}

    public func nextPlayableEpisode(from subscriptions: [Subscription]) -> Episode? {
        downloadedQueue(from: subscriptions).first
    }

    public func downloadedQueue(from subscriptions: [Subscription]) -> [Episode] {
        subscriptions
            .sorted { $0.priorityRank < $1.priorityRank }
            .flatMap { subscription in
                let episodes = subscription.episodes.isEmpty
                    ? subscription.latestEpisode.map { [$0] } ?? []
                    : subscription.episodes
                if let replay = subscription.autoArchiveSettings.replay {
                    let replayKeys = Set(replay.outstanding.map(\.key))
                    let manual = episodes.filter {
                        !replayKeys.contains($0.audioURL.absoluteString) &&
                        $0.downloadState == .downloaded && $0.playedState != .played && $0.playedState != .archived
                    }
                    return subscription.replayQueueEpisodes.filter { replay.enabled || $0.downloadState == .downloaded } + manual
                }
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
