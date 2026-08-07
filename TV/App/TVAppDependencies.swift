import Foundation
import AutohopCore

// AI CONTEXT — Production/test construction seam for the tvOS application.
// Rebuildable TV databases live in Caches. CloudKit remains the sole durable
// cross-device transport; this container does not start network or sync work.

@MainActor
struct TVAppDependencies {
    let subscriptionStore: SubscriptionStore
    let projectionStore: TVProjectionStore?
    let listeningStatsStore: ListeningStatsStore
    let playbackModel: TVPlaybackModel
    let survivalKitStore: SurvivalKitStore
    let episodeFeedLoader: EpisodeFeedLoader

    static func production() -> TVAppDependencies {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let databaseDirectory = cachesDirectory?.appendingPathComponent("Autohop", isDirectory: true)
        if let databaseDirectory {
            try? FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        }

        let store = SubscriptionStore(
            deferredLoadDatabasePath: databaseDirectory?.appendingPathComponent("autohop-tv.sqlite").path
        )
        let projectionStore = databaseDirectory.flatMap {
            try? TVProjectionStore(path: $0.appendingPathComponent("autohop-tv-projections.sqlite").path)
        }
        let statsStore = ListeningStatsStore(
            fileURL: databaseDirectory?.appendingPathComponent("listening-stats.json"),
            legacyFileURL: nil
        )
        statsStore.attachSyncDatabase(from: store)

        return TVAppDependencies(
            subscriptionStore: store,
            projectionStore: projectionStore,
            listeningStatsStore: statsStore,
            playbackModel: TVPlaybackModel(subscriptionStore: store, statsStore: statsStore),
            survivalKitStore: SurvivalKitStore(),
            episodeFeedLoader: EpisodeFeedLoader()
        )
    }
}

