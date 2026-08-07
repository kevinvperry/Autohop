import Foundation
import AutohopCore

// AI CONTEXT — Pure Library projection. It performs no persistence/network
// work and is safe to test independently of TVAppModel.
struct TVLibraryProjector {
    struct Projection {
        let subscriptions: [AutohopCore.Subscription]
        let tiles: [TVPodcastTileModel]
        let subscriptionsByID: [UUID: AutohopCore.Subscription]
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
            tiles: tiles,
            subscriptionsByID: Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        )
    }
}

