// AI CONTEXT — Tests/HistorySyncTests.swift. Tests listening-history sync
// (SYNC_DESIGN.md step 5a): the type-namespaced CKRecord round-trip and the
// AutohopDatabase pending/record accessors. Record-level LWW by lastListenedAt.
// No CloudKit network. Decomposition Stage 2 moved ListeningHistoryStore into
// Persistence and retained its shared-core target membership; its record-level
// merge and local JSON format remain unchanged. The record-name parser
// assertions protect the Phase-2 legacy fallback
// for old unprefixed HistoryEntry records. Version-aware acknowledgement tests
// ensure an older in-flight save cannot clear a newer resume/history update.
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

    func testLegacyListeningHistoryJSONRoundTripsWithoutSchemaLoss() throws {
        // AI CONTEXT — This is the pre-rich-completion local JSON shape written
        // by ListeningHistoryStore before CompletionKind fields existed. Stage 2
        // physically moved the store; the fixture protects its on-disk decoding
        // compatibility independently of CloudKit.
        let legacyJSON = """
        [{
          "id": "sub|guid:g1",
          "subscriptionID": "11111111-1111-1111-1111-111111111111",
          "episodeID": "22222222-2222-2222-2222-222222222222",
          "episodeTitle": "Legacy Episode",
          "podcastTitle": "Legacy Podcast",
          "durationSeconds": 1800,
          "listenedSeconds": 600,
          "lastPositionSeconds": 650,
          "lastListenedAt": 721692800,
          "status": "listened"
        }]
        """

        let decoded = try JSONDecoder().decode(
            [ListeningHistoryEntry].self,
            from: Data(legacyJSON.utf8)
        )
        let reencoded = try JSONEncoder().encode(decoded)
        let reloaded = try JSONDecoder().decode([ListeningHistoryEntry].self, from: reencoded)

        XCTAssertEqual(reloaded, decoded)
        XCTAssertEqual(reloaded.first?.episodeTitle, "Legacy Episode")
        XCTAssertNil(reloaded.first?.completionKind)
        XCTAssertNil(reloaded.first?.completionPercent)
    }

    func testHistoryRecordRoundTrip() {
        let e = entry()
        let record = CloudKitSync.makeRecord(from: e)
        XCTAssertEqual(record.recordType, CloudKitSync.historyRecordType)
        XCTAssertEqual(record.recordID.recordName, CloudKitSync.historyRecordName(id: e.id))

        let decoded = CloudKitSync.historyEntry(from: record)
        XCTAssertEqual(decoded?.id, e.id)
        XCTAssertEqual(decoded?.episodeTitle, "Episode")
        XCTAssertEqual(decoded?.podcastTitle, "Podcast")
        XCTAssertEqual(decoded?.listenedSeconds, 600)
        XCTAssertEqual(decoded?.lastListenedAt, e.lastListenedAt)
    }

    func testHistoryRecordNameParserAcceptsLegacyAndNamespacedIDs() {
        let id = "sub|guid:g1"
        XCTAssertEqual(CloudKitSync.historyID(fromRecordName: id), id)
        XCTAssertEqual(CloudKitSync.historyID(fromRecordName: CloudKitSync.historyRecordName(id: id)), id)
    }

    // MARK: - Database pending tracking

    func testRecordedEntryIsPendingUntilMarkedSynced() throws {
        let db = try AutohopDatabase()
        let e = entry()

        try db.recordHistoryEntry(e)
        XCTAssertEqual(try db.pendingHistoryEntries().count, 1)
        XCTAssertEqual(try db.historyEntry(id: e.id)?.episodeTitle, "Episode")

        XCTAssertFalse(try db.acknowledgeHistoryEntry(e))
        XCTAssertTrue(try db.pendingHistoryEntries().isEmpty)
    }

    func testOldAcknowledgementLeavesNewerHistoryEntryPending() throws {
        let db = try AutohopDatabase()
        let old = entry(listenedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var newer = old
        newer.lastListenedAt = Date(timeIntervalSince1970: 1_700_000_100)
        newer.lastPositionSeconds = 900

        try db.recordHistoryEntry(old)
        try db.recordHistoryEntry(newer)

        XCTAssertTrue(try db.acknowledgeHistoryEntry(old))
        XCTAssertEqual(try db.pendingHistoryEntries().first?.lastPositionSeconds, 900)
        XCTAssertFalse(try db.acknowledgeHistoryEntry(newer))
        XCTAssertTrue(try db.pendingHistoryEntries().isEmpty)
    }

    func testSyncedHistoryEntryIsNotPending() throws {
        let db = try AutohopDatabase()
        try db.saveSyncedHistoryEntry(entry())
        XCTAssertTrue(try db.pendingHistoryEntries().isEmpty) // adopted from server, not re-pushed
    }
}
