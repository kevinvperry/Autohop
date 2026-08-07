import Foundation
import AutohopCore

// AI CONTEXT — Bounded, targeted episode-detail repository. It may load only
// the selected subscription; it must never sweep all feeds.
@MainActor
final class TVEpisodeDetailRepository {
    private let store: SubscriptionStore
    private let projectionStore: TVProjectionStore?
    private let feedLoader: EpisodeFeedLoader

    init(
        store: SubscriptionStore,
        projectionStore: TVProjectionStore?,
        feedLoader: EpisodeFeedLoader
    ) {
        self.store = store
        self.projectionStore = projectionStore
        self.feedLoader = feedLoader
    }

    func cachedRows(subscriptionID: UUID) -> [TVEpisodeRowModel]? {
        guard let projectionStore,
              let projection = try? projectionStore.loadEpisodes(subscriptionID: subscriptionID)
        else { return nil }
        return projection.episodes.map(TVEpisodeRowModel.init)
    }

    func refreshRows(
        subscriptionID: UUID,
        feedURL: URL,
        limit: Int = 25
    ) async throws -> [TVEpisodeRowModel] {
        let parsed = try await feedLoader.fetch(feedURL: feedURL, limit: limit)
        try Task.checkCancellation()
        store.updateEpisodes(subscriptionID: subscriptionID, from: parsed)
        let episodes = Array((store.subscription(id: subscriptionID)?.episodes ?? []).prefix(limit))
        let projection = TVEpisodeProjection(subscriptionID: subscriptionID, episodes: episodes)
        Task.detached(priority: .utility) { [projectionStore] in
            try? projectionStore?.saveEpisodes(projection)
        }
        return episodes.map(TVEpisodeRowModel.init)
    }
}
