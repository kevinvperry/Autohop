import Foundation
import AutohopCore

// AI CONTEXT — Pure Library projection. It performs no persistence/network
// work and is safe to test independently of TVAppModel. Its refresh policy is
// revision-based: never use synthesized Subscription equality as a no-change
// check because that recursively compares every embedded episode.
struct TVLibraryProjector {
    struct Projection {
        let subscriptions: [AutohopCore.Subscription]
        let tiles: [TVPodcastTileModel]
    }

    static func project(
        subscriptions: [AutohopCore.Subscription],
        pendingEntries: [SurvivalKitEntry]
    ) -> Projection {
        let library = subscriptions
            .filter { $0.browseDate == nil }
            .sorted { $0.priorityRank < $1.priorityRank }
        let tiles = (library.map {
            TVPodcastTileModel(
                id: $0.id,
                title: $0.title,
                author: $0.author,
                artworkURL: $0.artworkURL,
                feedURL: $0.feedURL,
                priorityRank: $0.priorityRank,
                isMaterializing: false
            )
        } + pendingEntries.map {
            TVPodcastTileModel(
                id: $0.subscriptionID,
                title: $0.title,
                author: nil,
                artworkURL: nil,
                feedURL: $0.feedURL,
                priorityRank: $0.priorityRank,
                isMaterializing: true
            )
        }).sorted { $0.priorityRank < $1.priorityRank }
        return Projection(
            subscriptions: library,
            tiles: tiles
        )
    }
}

enum TVLibraryProjectionRefreshPolicy {
    static func shouldRebuild(
        lastRevision: UInt64?,
        currentRevision: UInt64,
        explicitlyInvalidated: Bool
    ) -> Bool {
        explicitlyInvalidated || lastRevision != currentRevision
    }
}
