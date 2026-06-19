// AI CONTEXT — Tests/StatsSyncTests.swift. Tests cross-device stats sync
// (SYNC_DESIGN.md step 5b): the ADDITIVE per-(deviceID,dayKey) partition model.
// Covers DayStats.merged, the CKRecord round-trip, the database stats accessors,
// and the key behaviour — summary() sums local + remote partitions (NOT LWW).
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class StatsSyncTests: XCTestCase {

    private func day(_ key: String, seconds: TimeInterval) -> DayStats {
        var d = DayStats(dayKey: key)
        d.wallClockSeconds = seconds
        d.episodesCompleted = 1
        d.perShowSeconds["show1"] = seconds
        return d
    }

    func testMergedSumsAdditively() {
        let a = day("2026-06-14", seconds: 600)
        let b = day("2026-06-14", seconds: 300)
        let m = a.merged(with: b)
        XCTAssertEqual(m.wallClockSeconds, 900)
        XCTAssertEqual(m.episodesCompleted, 2)
        XCTAssertEqual(m.perShowSeconds["show1"], 900)
    }

    func testStatsRecordRoundTripAndDeviceID() {
        let d = day("2026-06-14", seconds: 600)
        let record = CloudKitSync.makeRecord(deviceID: "deviceA", day: d)
        XCTAssertEqual(record.recordType, CloudKitSync.statsRecordType)
        XCTAssertEqual(record.recordID.recordName, "deviceA:2026-06-14")

        let parsed = CloudKitSync.statsPartition(from: record)
        XCTAssertEqual(parsed?.deviceID, "deviceA")
        XCTAssertEqual(parsed?.day.wallClockSeconds, 600)
    }

    func testDatabaseStatsPendingAndRemote() throws {
        let db = try AutohopDatabase()

        try db.recordStatsDay(day("2026-06-14", seconds: 600))
        XCTAssertEqual(try db.pendingStatsDays().count, 1)
        try db.markSynced(episodeGuids: [], subscriptionIDs: [], statsDayKeys: ["2026-06-14"])
        XCTAssertTrue(try db.pendingStatsDays().isEmpty)

        try db.applyRemoteStatsPartition(deviceID: "other", day: day("2026-06-14", seconds: 300))
        XCTAssertEqual(try db.remoteStatsByDayKey()["2026-06-14"]?.count, 1)
    }

    @MainActor
    func testSummarySumsLocalAndRemotePartitions() throws {
        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        store.syncDatabase = db

        store.importDay(day("2026-06-14", seconds: 600))                       // this device
        try db.applyRemoteStatsPartition(deviceID: "other", day: day("2026-06-14", seconds: 300)) // another device
        store.reloadRemoteStats()

        let summary = store.summary(for: .lifetime)
        XCTAssertEqual(summary.wallClockSeconds, 900) // additive, not last-write-wins
    }
}
