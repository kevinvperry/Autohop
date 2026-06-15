// AI CONTEXT — Tests/SyncGuardsTests.swift. Tests the step-6 sync guards:
// active-player-wins (a remote played/archived change must not interrupt the
// episode loaded in the player) and self-heal (a remote state stashed before an
// episode existed locally is applied when the feed later brings it in).
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class SyncGuardsTests: XCTestCase {

    private func episode(_ guid: String, sub: UUID) -> Episode {
        Episode(subscriptionID: sub, guid: guid, title: guid, audioURL: URL(string: "https://e.com/\(guid).mp3")!)
    }

    private func makeStore(sub: UUID, seed: Episode) throws -> SubscriptionStore {
        let store = SubscriptionStore.inMemory()
        _ = try store.addSubscription(id: sub, feedURL: URL(string: "https://f.com/feed")!, title: "Show",
                                      author: nil, artworkURL: nil, latestEpisode: seed)
        return store
    }

    func testActivePlayerWinsKeepsLocalStateForLoadedEpisode() async throws {
        let sub = UUID()
        let ep = episode("g1", sub: sub)
        let store = try makeStore(sub: sub, seed: ep)
        await store.flushPendingSaves()

        // The player has g1 loaded on this device.
        store.nowPlayingGuidProvider = { "g1" }

        // A remote record says g1 was archived elsewhere.
        var remoteEp = ep
        remoteEp.playedState = .archived
        store.applyRemoteEpisodeState(EpisodeSyncState(episode: remoteEp, subscriptionID: sub, dirtyAt: Date()))
        await store.flushPendingSaves()

        // The loaded episode is NOT interrupted — stays unplayed locally.
        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.playedState, .unplayed)
    }

    func testRemoteStillAppliesWhenEpisodeNotLoaded() async throws {
        let sub = UUID()
        let ep = episode("g1", sub: sub)
        let store = try makeStore(sub: sub, seed: ep)
        await store.flushPendingSaves()

        store.nowPlayingGuidProvider = { "something-else" } // g1 is NOT loaded

        var remoteEp = ep
        remoteEp.playedState = .archived
        store.applyRemoteEpisodeState(EpisodeSyncState(episode: remoteEp, subscriptionID: sub, dirtyAt: Date()))
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscription(id: sub)?.episodes.first?.playedState, .archived)
    }

    func testSelfHealAppliesStashedRemoteStateOnEpisodeArrival() async throws {
        let sub = UUID()
        let store = try makeStore(sub: sub, seed: episode("seed", sub: sub))
        await store.flushPendingSaves()

        // Remote state arrives for an episode not present locally yet.
        var orphan = episode("new-ep", sub: sub)
        orphan.playedState = .played
        orphan.wasCompleted = true
        let updated = store.applyRemoteEpisodeState(EpisodeSyncState(episode: orphan, subscriptionID: sub, dirtyAt: Date()))
        XCTAssertFalse(updated) // not local yet → stashed as a projection

        // The feed later brings the episode in, fresh/unplayed.
        store.updateEpisodes(subscriptionID: sub, episodes: [episode("new-ep", sub: sub)])
        await store.flushPendingSaves()

        let healed = store.subscription(id: sub)?.episodes.first { $0.guid == "new-ep" }
        XCTAssertEqual(healed?.playedState, .played)
        XCTAssertEqual(healed?.wasCompleted, true)
    }
}
