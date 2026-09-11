import Foundation
import AutohopCore

// AI CONTEXT — Production/test construction seam for the tvOS application.
// Authoritative TV state lives in Application Support. Render-only projections
// remain in Caches. This container does not start network or sync work.

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
        let databaseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Autohop", isDirectory: true)
        if let databaseDirectory {
            try? FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
            migrateLegacyAuthoritativeFiles(from: legacyDatabaseDirectory, to: databaseDirectory)
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

    /// Copy-before-open migration. The purgeable originals are intentionally
    /// retained for rollback; all future writes target Application Support.
    static func migrateLegacyAuthoritativeFiles(from source: URL?, to destination: URL) {
        guard let source else { return }
        let names = [
            "autohop-tv.sqlite", "autohop-tv.sqlite-wal", "autohop-tv.sqlite-shm",
            "listening-stats.json", "listening-stats.backup.json"
        ]
        for name in names {
            let oldURL = source.appendingPathComponent(name)
            let newURL = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: oldURL.path),
                  !FileManager.default.fileExists(atPath: newURL.path) else { continue }
            try? FileManager.default.copyItem(at: oldURL, to: newURL)
        }
    }
}
