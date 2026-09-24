import Foundation
import AutohopCore

// AI CONTEXT — Production/test construction seam for the tvOS application.
// Physical tvOS stores library, stats and projections in writable Caches.
// Caches are purgeable; CloudKit and survival-kit recovery remain essential. This container does not start network or sync work.

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
        let legacyDatabaseDirectory = cachesDirectory?.appendingPathComponent("Autohop", isDirectory: true)
        // Physical tvOS denies Application Support creation. Reuse the existing
        // Caches database (including its WAL); do not copy individual SQLite files.
        // Caches can be purged, so survival-kit/CloudKit recovery remains required.
        let databaseDirectory = legacyDatabaseDirectory
        if let databaseDirectory {
            do {
                try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
                AppLogger.shared.info("tv.storage.selected", "Using tvOS cache-backed library and stats", metadata: ["location": "Library/Caches/Autohop"], alwaysPersist: true)
            } catch {
                AppLogger.shared.error("tv.storage.failed", "Could not prepare TV storage", metadata: ["error": error.localizedDescription], alwaysPersist: true)
            }
        }

        let store = SubscriptionStore(
            deferredLoadDatabasePath: databaseDirectory?.appendingPathComponent("autohop-tv.sqlite").path
        )
        let projectionStore = legacyDatabaseDirectory.flatMap {
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
