// AI CONTEXT — Tests/PersistResilienceTests.swift. Regression test for the
// 2026-06-15 data-loss bug: a stale/incompatible sync-state payload (left by an
// older projection shape, e.g. before SubscriptionSyncState gained `feedURL`)
// must NOT throw inside persist() and roll back the whole transaction — it must
// re-seed a fresh projection so subscription/episode persistence keeps working.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class PersistResilienceTests: XCTestCase {

    func testPersistSurvivesUndecodableSubscriptionSyncRow() throws {
        let db = try AutohopDatabase()
        let sub = Subscription(id: UUID(), feedURL: URL(string: "https://f.com/feed")!, title: "Show", priorityRank: 1)

        // Simulate a row written by an older projection shape that no longer decodes.
        try db._testWriteCorruptSubscriptionSyncRow(id: sub.id)

        // persist() must NOT throw — the decode failure should re-seed, not roll back.
        XCTAssertNoThrow(try db.persist(current: [sub], previous: [:]))

        // The subscription row actually persisted...
        XCTAssertEqual(try db.loadSubscriptions().count, 1)
        // ...and the sync projection was re-seeded (decodable + pending to push).
        XCTAssertEqual(try db.pendingSubscriptionSyncStates().count, 1)
    }

    func testProactiveHealReseedsUndecodableRowWithoutAnEdit() throws {
        let db = try AutohopDatabase()
        let sub = Subscription(id: UUID(), feedURL: URL(string: "https://f.com/feed")!, title: "Show", priorityRank: 1)
        try db.persist(current: [sub], previous: [:]) // normal good state

        // Corrupt the row as an older shape would leave it.
        try db._testWriteCorruptSubscriptionSyncRow(id: sub.id)
        XCTAssertTrue(try db.pendingSubscriptionSyncStates().isEmpty) // corrupt row skipped

        // The launch-time heal re-seeds it WITHOUT any edit/persist.
        try db.reseedUndecodableSyncState(for: [sub])
        XCTAssertEqual(try db.pendingSubscriptionSyncStates().count, 1)
    }
}
