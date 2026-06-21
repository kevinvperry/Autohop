// AI CONTEXT — Tests/EpisodeDiffPersistTests.swift. Regression test for P1
// (ASSESSMENT.md): AutohopDatabase.write() must diff episodes against the
// last-persisted snapshot and only re-encode + re-project the rows that actually
// changed, instead of the old delete-all-then-reinsert-everything path that
// re-wrote every episode row (and ran a per-episode sync-state round-trip) on any
// subscription change. Asserts via the `_testEpisodeRowPayloadWrites` seam plus
// load-back correctness (value change, reorder/insert, delete), including
// subscription-scoped episode sync rows when two feeds reuse the same GUID.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class EpisodeDiffPersistTests: XCTestCase {

    private func makeEpisode(_ subID: UUID, _ n: Int) -> Episode {
        Episode(
            id: UUID(),
            subscriptionID: subID,
            guid: "guid-\(n)",
            title: "Episode \(n)",
            audioURL: URL(string: "https://f.com/ep\(n).mp3")!
        )
    }

    private func makeSub(episodeCount: Int) -> Subscription {
        let id = UUID()
        var sub = Subscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Show", priorityRank: 1)
        sub.episodes = (0..<episodeCount).map { makeEpisode(id, $0) }
        return sub
    }

    func testUnchangedEpisodesAreNotRewrittenWhenOnlySubscriptionFieldChanges() throws {
        let db = try AutohopDatabase()
        let sub = makeSub(episodeCount: 3)

        try db.persist(current: [sub], previous: [:])
        XCTAssertEqual(db._testEpisodeRowPayloadWrites, 3) // first sighting inserts all

        // Change only a non-episode field; episodes are byte-for-byte identical.
        db._testEpisodeRowPayloadWrites = 0
        var changed = sub
        changed.priorityRank = 5
        try db.persist(current: [changed], previous: [sub.id: sub])

        XCTAssertEqual(db._testEpisodeRowPayloadWrites, 0, "no episode changed → no episode payload writes")
        XCTAssertEqual(try db.loadSubscriptions().first?.priorityRank, 5)
    }

    func testOnlyTheChangedEpisodeIsRewritten() throws {
        let db = try AutohopDatabase()
        let sub = makeSub(episodeCount: 3)
        try db.persist(current: [sub], previous: [:])

        db._testEpisodeRowPayloadWrites = 0
        var changed = sub
        changed.episodes[1].playedState = .played
        try db.persist(current: [changed], previous: [sub.id: sub])

        XCTAssertEqual(db._testEpisodeRowPayloadWrites, 1, "exactly one episode changed")

        let loaded = try XCTUnwrap(try db.loadSubscriptions().first)
        XCTAssertEqual(loaded.episodes[1].playedState, .played)
        XCTAssertEqual(loaded.episodes[0].playedState, .unplayed)
        XCTAssertEqual(loaded.episodes[2].playedState, .unplayed)

        // Only the touched episode produced a pending sync projection.
        let pending = try db.pendingEpisodeSyncStates()
        XCTAssertEqual(pending.count, 1)
    }

    func testEpisodeSyncStateIsScopedBySubscriptionWhenGuidsMatch() throws {
        let db = try AutohopDatabase()
        let sharedGUID = "shared-guid"
        let firstID = UUID()
        let secondID = UUID()

        var first = Subscription(id: firstID, feedURL: URL(string: "https://f.com/one")!, title: "One", priorityRank: 1)
        var firstEpisode = Episode(subscriptionID: firstID, guid: sharedGUID, title: "Episode", audioURL: URL(string: "https://f.com/one.mp3")!)
        firstEpisode.playedState = .played
        first.episodes = [firstEpisode]
        first.latestEpisode = firstEpisode

        var second = Subscription(id: secondID, feedURL: URL(string: "https://f.com/two")!, title: "Two", priorityRank: 2)
        var secondEpisode = Episode(subscriptionID: secondID, guid: sharedGUID, title: "Episode", audioURL: URL(string: "https://f.com/two.mp3")!)
        secondEpisode.playedState = .archived
        second.episodes = [secondEpisode]
        second.latestEpisode = secondEpisode

        try db.persist(current: [first, second], previous: [:])

        let pending = try db.pendingEpisodeSyncStates()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(Set(pending.map(\.guid)), Set([sharedGUID]))
        XCTAssertEqual(Set(pending.map(\.syncKey)).count, 2)
        XCTAssertEqual(try db.episodeSyncState(subscriptionID: firstID, guid: sharedGUID)?.playedState, .played)
        XCTAssertEqual(try db.episodeSyncState(subscriptionID: secondID, guid: sharedGUID)?.playedState, .archived)
    }

    func testPrependedEpisodeInsertsOneRowAndPreservesOrder() throws {
        let db = try AutohopDatabase()
        let sub = makeSub(episodeCount: 3)
        try db.persist(current: [sub], previous: [:])

        db._testEpisodeRowPayloadWrites = 0
        var changed = sub
        let newEpisode = makeEpisode(sub.id, 99)
        changed.episodes.insert(newEpisode, at: 0) // feed refresh prepends newest

        try db.persist(current: [changed], previous: [sub.id: sub])

        XCTAssertEqual(db._testEpisodeRowPayloadWrites, 1, "only the new episode is encoded; the rest just shift orderIndex")

        let loaded = try XCTUnwrap(try db.loadSubscriptions().first)
        XCTAssertEqual(loaded.episodes.map(\.guid), ["guid-99", "guid-0", "guid-1", "guid-2"])
    }

    func testRemovedEpisodeIsDeletedWithoutRewritingOthers() throws {
        let db = try AutohopDatabase()
        let sub = makeSub(episodeCount: 3)
        try db.persist(current: [sub], previous: [:])

        db._testEpisodeRowPayloadWrites = 0
        var changed = sub
        changed.episodes.remove(at: 0)

        try db.persist(current: [changed], previous: [sub.id: sub])

        XCTAssertEqual(db._testEpisodeRowPayloadWrites, 0, "deletes don't re-encode payloads")

        let loaded = try XCTUnwrap(try db.loadSubscriptions().first)
        XCTAssertEqual(loaded.episodes.map(\.guid), ["guid-1", "guid-2"])
    }
}
