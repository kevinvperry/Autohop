// AI CONTEXT — Tests/StatsWriteCoalescingTests.swift. Regression test for AH-P1-004:
// listening-stats accumulation runs every 0.5s playback tick, and each tick used to
// issue a GRDB write transaction (recordStatsDay). These are now coalesced — the row
// holds the FULL day bucket, so a throttled flush re-writes the complete value with no
// data loss — and flushed on lifecycle save() checkpoints. The same test also
// protects the 2026-07-12 UI optimization: continuous playback may mutate the
// authoritative bucket every tick, but must not publish a revision every tick
// or publish the first tick twice when its initial persistence checkpoint runs.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class StatsWriteCoalescingTests: XCTestCase {

    @MainActor
    func testPerTickStatsWritesAreCoalesced() throws {
        // A real fileURL so the JSON saveThrottled() behaves as in production (30s gate);
        // otherwise save() never records lastSavedAt and would flush on every tick.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: dir.appendingPathComponent("stats.json"), legacyFileURL: nil)
        store.syncDatabase = db
        db._testStatsDayWriteCount = 0 // ignore any write from didSet/reload

        let sub = UUID()
        // Simulate 120 ticks (60s of playback at 0.5s each).
        for _ in 0..<120 {
            store.addListeningTime(0.5, speed: 1.0, subscriptionID: sub, showTitle: "Show")
        }

        XCTAssertLessThanOrEqual(store.revision, 2,
                                 "Playback ticks must coalesce Stats UI invalidations")

        // Without coalescing this would be 120 write transactions. The throttle is wall-clock
        // (30s) and these run in milliseconds, so only the first tick writes through.
        XCTAssertLessThanOrEqual(db._testStatsDayWriteCount, 2,
                                 "Per-tick stats writes must be coalesced, not one-per-tick")

        // A lifecycle save() must flush the coalesced bucket so the sync row is current.
        let beforeFlush = db._testStatsDayWriteCount
        store.save()
        XCTAssertEqual(db._testStatsDayWriteCount, beforeFlush + 1,
                       "save() should flush the pending stats day exactly once")
    }

    @MainActor
    func testCoalescedWriteStillPersistsFullDayValue() throws {
        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        store.syncDatabase = db

        let sub = UUID()
        for _ in 0..<10 {
            store.addListeningTime(0.5, speed: 1.0, subscriptionID: sub, showTitle: "Show")
        }
        store.flushPendingStatsDays()

        // The persisted sync row should reflect the FULL accumulated total (10 * 0.5 = 5s),
        // not just the value at the first (un-coalesced) write.
        let pending = try db.pendingStatsDays()
        let total = pending.reduce(0.0) { $0 + $1.wallClockSeconds }
        XCTAssertEqual(total, 5.0, accuracy: 0.001,
                       "Coalesced flush must persist the complete accumulated day value")
    }

    @MainActor
    func testDownloadAccountingDefersPersistenceUntilCheckpoint() throws {
        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        store.syncDatabase = db
        db._testStatsDayWriteCount = 0

        store.recordDownload(bytes: 42_000)

        XCTAssertEqual(
            db._testStatsDayWriteCount,
            0,
            "Download settlement must not synchronously flush statistics"
        )

        store.save()

        XCTAssertEqual(
            db._testStatsDayWriteCount,
            1,
            "A lifecycle checkpoint must persist deferred download accounting"
        )
    }
}
