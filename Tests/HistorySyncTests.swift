// AI CONTEXT — Tests/HistorySyncTests.swift. Tests listening-history sync
// (SYNC_DESIGN.md step 5a): the CKRecord round-trip and the AutohopDatabase
// pending/record accessors. Record-level LWW by lastListenedAt. No CloudKit
// network. (The applyRemote merge itself lives in ListeningHistoryStore in the
// app target and is exercised by the on-device build.)
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class HistorySyncTests: XCTestCase {

    private func entry(id: String = "sub|guid:g1", listenedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ListeningHistoryEntry {
        ListeningHistoryEntry(
            id: id,
            subscriptionID: UUID(),
            episodeID: UUID(),
            episodeTitle: "Episode",
            podcastTitle: "Podcast",
            artworkURL: URL(string: "https://e.com/art.jpg"),
            publishedAt: Date(timeIntervalSince1970: 1_690_000_000),
            durationSeconds: 1800,
            listenedSeconds: 600,
            lastPositionSeconds: 650,
            lastListenedAt: listenedAt,
            status: .listened
        )
    }

    // MARK: - CKRecord round-trip

    func testHistoryRecordRoundTrip() {
        let e = entry()
        let record = CloudKitSync.makeRecord(from: e)
        XCTAssertEqual(record.recordType, CloudKitSync.historyRecordType)
        XCTAssertEqual(record.recordID.recordName, e.id)

        let decoded = CloudKitSync.historyEntry(from: record)
        XCTAssertEqual(decoded?.id, e.id)
        XCTAssertEqual(decoded?.episodeTitle, "Episode")
        XCTAssertEqual(decoded?.podcastTitle, "Podcast")
        XCTAssertEqual(decoded?.listenedSeconds, 600)
        XCTAssertEqual(decoded?.lastListenedAt, e.lastListenedAt)
    }

    // MARK: - Database pending tracking

    func testRecordedEntryIsPendingUntilMarkedSynced() throws {
        let db = try AutohopDatabase()
        let e = entry()

        try db.recordHistoryEntry(e)
        XCTAssertEqual(try db.pendingHistoryEntries().count, 1)
        XCTAssertEqual(try db.historyEntry(id: e.id)?.episodeTitle, "Episode")

        try db.markSynced(episodeGuids: [], subscriptionIDs: [], historyIDs: [e.id])
        XCTAssertTrue(try db.pendingHistoryEntries().isEmpty)
    }

    func testSyncedHistoryEntryIsNotPending() throws {
        let db = try AutohopDatabase()
        try db.saveSyncedHistoryEntry(entry())
        XCTAssertTrue(try db.pendingHistoryEntries().isEmpty) // adopted from server, not re-pushed
    }
}
