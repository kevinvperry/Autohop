// AI CONTEXT — Tests/HistorySyncTests.swift. Tests listening-history sync
// (SYNC_DESIGN.md step 5a): the type-namespaced CKRecord round-trip and the
// AutohopDatabase pending/record accessors. Resume fields merge by recency while
// accumulated listening and terminal evidence remain monotonic.
// No CloudKit network. Decomposition Stage 2 moved ListeningHistoryStore into
// Persistence and retained its shared-core target membership. The record-name parser
// assertions protect the Phase-2 legacy fallback
// for old unprefixed HistoryEntry records. Version-aware acknowledgement tests
// ensure an older in-flight save cannot clear a newer resume/history update;
// navigation-adoption tests require callers to receive the merged entry and
// prevent an older row that only improves totals from moving playback.
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
        XCTAssertNil(reloaded.first?.streamURL)
        XCTAssertNil(reloaded.first?.mediaKind)
    }

    func testPlayableHistoryFieldsRoundTrip() throws {
        var value = entry()
        value.streamURL = URL(string: "https://cdn.example.com/video.mp4")
        value.mediaKind = .video

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ListeningHistoryEntry.self, from: data)

        XCTAssertEqual(decoded.streamURL, value.streamURL)
        XCTAssertEqual(decoded.mediaKind, .video)
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

    func testDatabaseFallbackPreservesMonotonicHistoryEvidenceForTV() throws {
        let db = try AutohopDatabase()
        var completed = entry(listenedAt: Date(timeIntervalSince1970: 1_700_000_000))
        completed.listenedSeconds = 1_200
        completed.status = .played
        completed.completionKind = .finishedNaturally
        completed.completionPercent = 1
        try db.saveSyncedHistoryEntry(completed)

        var newerResume = completed
        newerResume.lastListenedAt = Date(timeIntervalSince1970: 1_700_000_100)
        newerResume.listenedSeconds = 60
        newerResume.lastPositionSeconds = 90
        newerResume.status = .listened
        newerResume.completionKind = nil
        newerResume.completionPercent = nil
        try db.saveSyncedHistoryEntry(newerResume)

        let merged = try XCTUnwrap(db.historyEntry(id: completed.id))
        XCTAssertEqual(merged.lastPositionSeconds, 90)
        XCTAssertEqual(merged.listenedSeconds, 1_200)
        XCTAssertEqual(merged.status, .played)
        XCTAssertEqual(merged.completionKind, .finishedNaturally)
        XCTAssertEqual(try db.pendingHistoryEntries().map(\.id), [completed.id])
    }

    func testHistoryMergePreservesAccumulatedListeningAndTerminalOutcome() {
        var completed = entry(listenedAt: Date(timeIntervalSince1970: 1_700_000_000))
        completed.listenedSeconds = 1_200
        completed.status = .played
        completed.completionKind = .finishedNaturally
        completed.completionPercent = 1

        var recentResume = completed
        recentResume.lastListenedAt = Date(timeIntervalSince1970: 1_700_000_100)
        recentResume.listenedSeconds = 60
        recentResume.lastPositionSeconds = 90
        recentResume.status = .listened
        recentResume.completionKind = nil
        recentResume.completionPercent = nil

        let merged = completed.mergedForSync(with: recentResume)

        XCTAssertEqual(merged.lastListenedAt, recentResume.lastListenedAt)
        XCTAssertEqual(merged.lastPositionSeconds, 90)
        XCTAssertEqual(merged.listenedSeconds, 1_200)
        XCTAssertEqual(merged.completionKind, .finishedNaturally)
        XCTAssertEqual(merged.status, .played)
    }

    @MainActor
    func testRemoteMergeAdoptsOnlyMergedNewerNavigationState() {
        let store = ListeningHistoryStore(fileURL: nil)
        var completed = entry(listenedAt: Date(timeIntervalSince1970: 1_700_000_100))
        completed.listenedSeconds = 600
        completed.status = .played
        completed.completionKind = .finishedNaturally
        completed.completionPercent = 1
        XCTAssertNotNil(store.applyRemote(completed))

        var olderLargerTotal = completed
        olderLargerTotal.lastListenedAt = Date(timeIntervalSince1970: 1_700_000_000)
        olderLargerTotal.listenedSeconds = 1_200
        olderLargerTotal.status = .listened
        olderLargerTotal.completionKind = nil
        olderLargerTotal.completionPercent = nil
        XCTAssertNil(
            store.applyRemote(olderLargerTotal),
            "An older row may improve monotonic totals but must not move playback navigation"
        )
        XCTAssertEqual(store.entries.first?.listenedSeconds, 1_200)

        var newerResume = olderLargerTotal
        newerResume.lastListenedAt = Date(timeIntervalSince1970: 1_700_000_200)
        newerResume.lastPositionSeconds = 90
        let navigation = store.applyRemote(newerResume)

        XCTAssertEqual(navigation?.lastPositionSeconds, 90)
        XCTAssertEqual(
            navigation?.status,
            .played,
            "The caller must receive merged terminal evidence, not the weaker raw resume row"
        )
    }
}
