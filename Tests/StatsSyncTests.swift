// AI CONTEXT — Tests/StatsSyncTests.swift. Tests cross-device stats sync
// (SYNC_DESIGN.md step 5b): the ADDITIVE per-(deviceID,dayKey) partition model.
// Covers DayStats.merged, the type-namespaced CKRecord round-trip, legacy
// record-name parse compatibility, the database stats accessors, and the key
// behaviour — summary() sums local + remote partitions (NOT LWW). The
// namespaced/legacy parse tests protect the Phase-2 CloudKit namespace repair
// for DayStats without changing the additive sync contract. The system-fields
// invariant protects DayStats conflict repair: caching the server change tag for
// this device's own partition must not mark the full local day bucket synced.
// Version-aware acknowledgement coverage prevents an older day upload from
// clearing a newer accumulated full-day value.
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
        d.perShowEpisodesStarted["show1"] = 1
        d.perShowEpisodesCompleted["show1"] = 1
        return d
    }

    func testMergedSumsAdditively() {
        let a = day("2026-06-14", seconds: 600)
        let b = day("2026-06-14", seconds: 300)
        let m = a.merged(with: b)
        XCTAssertEqual(m.wallClockSeconds, 900)
        XCTAssertEqual(m.episodesCompleted, 2)
        XCTAssertEqual(m.perShowSeconds["show1"], 900)
        XCTAssertEqual(m.perShowEpisodesStarted["show1"], 2)
        XCTAssertEqual(m.perShowEpisodesCompleted["show1"], 2)
    }

    func testStatsRecordRoundTripAndDeviceID() {
        let d = day("2026-06-14", seconds: 600)
        let record = CloudKitSync.makeRecord(deviceID: "deviceA", day: d)
        XCTAssertEqual(record.recordType, CloudKitSync.statsRecordType)
        XCTAssertEqual(record.recordID.recordName, CloudKitSync.statsRecordName(deviceID: "deviceA", dayKey: "2026-06-14"))

        let parsed = CloudKitSync.statsPartition(from: record)
        XCTAssertEqual(parsed?.deviceID, "deviceA")
        XCTAssertEqual(parsed?.day.wallClockSeconds, 600)
    }

    func testStatsRecordNameParserAcceptsLegacyAndNamespacedIDs() {
        XCTAssertEqual(CloudKitSync.statsDayKey(fromRecordName: "deviceA:2026-06-14"), "2026-06-14")
        XCTAssertEqual(
            CloudKitSync.statsDayKey(fromRecordName: CloudKitSync.statsRecordName(deviceID: "deviceA", dayKey: "2026-06-14")),
            "2026-06-14"
        )
    }

    func testDatabaseStatsPendingAndRemote() throws {
        let db = try AutohopDatabase()

        try db.recordStatsDay(day("2026-06-14", seconds: 600))
        XCTAssertEqual(try db.pendingStatsDays().count, 1)
        XCTAssertFalse(try db.acknowledgeStatsDay(day("2026-06-14", seconds: 600)))
        XCTAssertTrue(try db.pendingStatsDays().isEmpty)

        try db.applyRemoteStatsPartition(deviceID: "other", day: day("2026-06-14", seconds: 300))
        XCTAssertEqual(try db.remoteStatsByDayKey()["2026-06-14"]?.count, 1)
    }

    func testOldAcknowledgementLeavesNewerStatsDayPending() throws {
        let db = try AutohopDatabase()
        let old = day("2026-06-14", seconds: 600)
        let newer = day("2026-06-14", seconds: 900)
        try db.recordStatsDay(old)
        try db.recordStatsDay(newer)

        XCTAssertTrue(try db.acknowledgeStatsDay(old))
        XCTAssertEqual(try db.pendingStatsDays().first?.wallClockSeconds, 900)
        XCTAssertFalse(try db.acknowledgeStatsDay(newer))
        XCTAssertTrue(try db.pendingStatsDays().isEmpty)
    }

    func testStatsSystemFieldRefreshDoesNotClearPendingDay() throws {
        let db = try AutohopDatabase()

        try db.recordStatsDay(day("2026-06-14", seconds: 600))
        XCTAssertEqual(try db.pendingStatsDays().map(\.dayKey), ["2026-06-14"])

        let refreshedSystemFields = Data("server-change-tag".utf8)
        try db.storeStatsSystemFields(refreshedSystemFields, dayKey: "2026-06-14")

        XCTAssertEqual(try db.statsSystemFields(dayKey: "2026-06-14"), refreshedSystemFields)
        XCTAssertEqual(
            try db.pendingStatsDays().map(\.dayKey),
            ["2026-06-14"],
            "Caching server system fields for a DayStats conflict must keep the local full-day bucket pending"
        )
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
