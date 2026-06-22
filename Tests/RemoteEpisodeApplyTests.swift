// AI CONTEXT — Tests/RemoteEpisodeApplyTests.swift. Tests SubscriptionStore's
// remote-apply path (applyRemoteEpisodeState) — the local side of CloudKit
// episode sync (SYNC_DESIGN.md step 3b). Uses an in-memory store; no CloudKit.
// Includes the sparse-remote regression guard from the namespace repair: an
// absent remote field must not reset clean local played/completed state.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class RemoteEpisodeApplyTests: XCTestCase {

    private func makeStoreWithEpisode() throws -> (store: SubscriptionStore, sub: UUID, episode: Episode) {
        let store = SubscriptionStore.inMemory()
        let sub = UUID()
        let episode = Episode(subscriptionID: sub, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        _ = try store.addSubscription(
            id: sub,
            feedURL: URL(string: "https://f.com/feed")!,
            title: "Show",
            author: nil,
            artworkURL: nil,
            latestEpisode: episode
        )
        return (store, sub, episode)
    }

    func testRemotePlayedAppliesToCleanLocal() async throws {
        let (store, sub, episode) = try makeStoreWithEpisode()
        await store.flushPendingSaves()

        var remoteEp = episode
        remoteEp.playedState = .played
        remoteEp.wasCompleted = true
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: sub, dirtyAt: Date())

        let updated = store.applyRemoteEpisodeState(remote)
        await store.flushPendingSaves()

        XCTAssertTrue(updated)
        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.playedState, .played)
        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.wasCompleted, true)
    }

    func testNewerLocalChangeBeatsOlderRemote() async throws {
        let (store, sub, episode) = try makeStoreWithEpisode()

        // Local marks played now → dirty projection with a recent stamp.
        store.markEpisodePlayed(subscriptionID: sub, episodeID: episode.id)
        await store.flushPendingSaves()

        // Remote says unplayed, but from long ago.
        var remoteEp = episode
        remoteEp.playedState = .unplayed
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: sub, dirtyAt: Date(timeIntervalSince1970: 1_000))

        store.applyRemoteEpisodeState(remote)
        await store.flushPendingSaves()

        // Local (newer) wins.
        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.playedState, .played)
    }

    func testSparseRemoteEpisodeDoesNotResetCleanLocalState() async throws {
        let (store, sub, episode) = try makeStoreWithEpisode()

        store.markEpisodePlayed(subscriptionID: sub, episodeID: episode.id)
        await store.flushPendingSaves()
        let syncKey = EpisodeSyncState.syncKey(subscriptionID: sub, guid: episode.guid)
        try store.database?.markSynced(episodeSyncKeys: [syncKey], subscriptionIDs: [])

        let sparseRemote = EpisodeSyncState(
            guid: episode.guid,
            subscriptionID: sub,
            playedState: Synced(wrappedValue: .unplayed),
            wasCompleted: Synced(wrappedValue: false),
            lastPlayedAt: Synced(wrappedValue: nil)
        )

        store.applyRemoteEpisodeState(sparseRemote)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.playedState, .played)
    }

    func testRemoteArchiveClearsLocalDownload() async throws {
        let (store, sub, episode) = try makeStoreWithEpisode()

        // This device has the episode downloaded.
        var downloaded = episode
        downloaded.downloadState = .downloaded
        downloaded.localFileURL = URL(fileURLWithPath: "/tmp/autohop-test-\(episode.id).mp3")
        downloaded.localFileName = "\(episode.id).mp3"
        store.updateLatestEpisode(subscriptionID: sub, episode: downloaded)
        await store.flushPendingSaves()

        // Capture the file-delete request surfaced to AppState.
        var deleteRequest: Episode?
        store.onEpisodeFileShouldDelete = { deleteRequest = $0 }

        // Another device archives the episode.
        var remoteEp = episode
        remoteEp.playedState = .archived
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: sub, dirtyAt: Date())

        let updated = store.applyRemoteEpisodeState(remote)
        await store.flushPendingSaves()

        XCTAssertTrue(updated)
        let result = store.subscription(id: sub)?.episodes.first
        XCTAssertEqual(result?.playedState, .archived)
        XCTAssertEqual(result?.downloadState, .notDownloaded)
        XCTAssertNil(result?.localFileURL)
        XCTAssertNil(result?.localFileName)

        // The delete callback fired with the file fields still populated so the
        // DownloadManager can locate the media file.
        XCTAssertEqual(deleteRequest?.id, episode.id)
        XCTAssertEqual(deleteRequest?.localFileName, "\(episode.id).mp3")
        XCTAssertNotNil(deleteRequest?.localFileURL)
    }

    func testRemotePlayedWithNoLocalDownloadSkipsDeleteCallback() async throws {
        let (store, sub, episode) = try makeStoreWithEpisode()
        await store.flushPendingSaves()

        // No local download → the delete callback must not fire.
        var deleteFired = false
        store.onEpisodeFileShouldDelete = { _ in deleteFired = true }

        var remoteEp = episode
        remoteEp.playedState = .played
        remoteEp.wasCompleted = true
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: sub, dirtyAt: Date())

        let updated = store.applyRemoteEpisodeState(remote)
        await store.flushPendingSaves()

        XCTAssertTrue(updated)
        XCTAssertFalse(deleteFired)
        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.downloadState, .notDownloaded)
    }

    func testUnknownEpisodeIsNotApplied() async throws {
        let (store, sub, _) = try makeStoreWithEpisode()
        await store.flushPendingSaves()

        var orphan = Episode(subscriptionID: sub, guid: "not-here", title: "X", audioURL: URL(string: "https://e.com/x.mp3")!)
        orphan.playedState = .played
        let remote = EpisodeSyncState(episode: orphan, subscriptionID: sub, dirtyAt: Date())

        let updated = store.applyRemoteEpisodeState(remote)
        XCTAssertFalse(updated) // no local episode with that guid
    }
}
