// AI CONTEXT — Tests/EpisodeDiffPersistTests.swift. Regression test for P1
// (ASSESSMENT.md): AutohopDatabase.write() must diff episodes against the
// last-persisted snapshot and only re-encode + re-project the rows that actually
// changed, instead of the old delete-all-then-reinsert-everything path that
// re-wrote every episode row (and ran a per-episode sync-state round-trip) on any
// subscription change. Asserts via the `_testEpisodeRowPayloadWrites` seam plus
// load-back correctness (value change, reorder/insert, delete).
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
