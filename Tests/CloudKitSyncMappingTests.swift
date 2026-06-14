// AI CONTEXT — Tests/CloudKitSyncMappingTests.swift. Unit tests for the
// field-level last-write-wins merge (EpisodeSyncState.merged) and the
// CKRecord <-> EpisodeSyncState mapping (CloudKitSync) — the testable core of
// build step 3a. No network or CKSyncEngine; CKRecords are constructed in-memory.
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class CloudKitSyncMappingTests: XCTestCase {

    private func episode(guid: String = "g1") -> Episode {
        Episode(subscriptionID: UUID(), guid: guid, title: "t", audioURL: URL(string: "https://e.com/a.mp3")!)
    }

    // MARK: - Field-level merge

    func testCleanLocalAlwaysAdoptsRemote() {
        let subID = UUID()
        var ep = episode(); ep.playedState = .unplayed
        var local = EpisodeSyncState(episode: ep, subscriptionID: subID)
        local.markClean() // no local opinion

        var remoteEp = episode(); remoteEp.playedState = .played
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: subID, dirtyAt: Date())

        let merged = local.merged(withRemote: remote)
        XCTAssertEqual(merged.playedState, .played)
        XCTAssertFalse(merged.hasPendingChanges) // adopted remote, nothing to push
    }

    func testNewerLocalWinsAndStaysDirty() {
        let subID = UUID()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        var localEp = episode(); localEp.playedState = .played
        var local = EpisodeSyncState(episode: localEp, subscriptionID: subID, dirtyAt: new)

        var remoteEp = episode(); remoteEp.playedState = .archived
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: subID, dirtyAt: old)

        local = local.merged(withRemote: remote)
        XCTAssertEqual(local.playedState, .played)        // local newer → kept
        XCTAssertTrue(local.$playedState.hasPendingChange) // still dirty → will push
    }

    func testOlderLocalYieldsToRemoteAndBecomesClean() {
        let subID = UUID()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        var localEp = episode(); localEp.playedState = .played
        var local = EpisodeSyncState(episode: localEp, subscriptionID: subID, dirtyAt: old)

        var remoteEp = episode(); remoteEp.playedState = .archived
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: subID, dirtyAt: new)

        local = local.merged(withRemote: remote)
        XCTAssertEqual(local.playedState, .archived)        // remote newer → adopted
        XCTAssertFalse(local.$playedState.hasPendingChange) // clean now
    }

    func testPerFieldIndependence() {
        let subID = UUID()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        // Local: playedState newer; wasCompleted clean.
        var localEp = episode(); localEp.playedState = .played; localEp.wasCompleted = false
        var local = EpisodeSyncState(episode: localEp, subscriptionID: subID, dirtyAt: new)
        local.$wasCompleted = Synced(wrappedValue: false, modifiedAt: nil)

        // Remote: playedState older; wasCompleted true (authored).
        var remoteEp = episode(); remoteEp.playedState = .archived; remoteEp.wasCompleted = true
        let remote = EpisodeSyncState(episode: remoteEp, subscriptionID: subID, dirtyAt: old)

        local = local.merged(withRemote: remote)
        XCTAssertEqual(local.playedState, .played)   // local newer kept
        XCTAssertTrue(local.wasCompleted)            // remote adopted (local was clean)
    }

    // MARK: - CKRecord mapping

    func testRecordRoundTrip() throws {
        let subID = UUID()
        var ep = episode(guid: "abc"); ep.playedState = .played; ep.wasCompleted = true
        ep.lastPlayedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let state = EpisodeSyncState(episode: ep, subscriptionID: subID)

        let record = CloudKitSync.makeRecord(from: state)
        XCTAssertEqual(record.recordID.recordName, "abc")
        XCTAssertEqual(record.recordType, CloudKitSync.episodeRecordType)

        let decoded = try XCTUnwrap(CloudKitSync.episodeSyncState(from: record))
        XCTAssertEqual(decoded.guid, "abc")
        XCTAssertEqual(decoded.subscriptionID, subID)
        XCTAssertEqual(decoded.playedState, .played)
        XCTAssertTrue(decoded.wasCompleted)
        XCTAssertEqual(decoded.lastPlayedAt, ep.lastPlayedAt)
    }

    func testCleanFieldsAreNotWritten() {
        let subID = UUID()
        var ep = episode(guid: "abc"); ep.playedState = .played
        var state = EpisodeSyncState(episode: ep, subscriptionID: subID)
        state.markClean()
        // Dirty only playedState.
        state.playedState = .archived

        let record = CloudKitSync.makeRecord(from: state)
        XCTAssertNotNil(record["playedState"])              // dirty → written
        XCTAssertNil(record["wasCompletedModifiedAt"])      // clean → preserved/untouched
        XCTAssertNil(record["lastPlayedAtModifiedAt"])
    }

    func testPopulateDoesNotClobberCleanServerFields() throws {
        let subID = UUID()
        // Existing server record already has wasCompleted authored.
        var seedEp = episode(guid: "abc"); seedEp.wasCompleted = true
        let serverState = EpisodeSyncState(episode: seedEp, subscriptionID: subID)
        let record = CloudKitSync.makeRecord(from: serverState)

        // Local change touches only playedState.
        let ep = episode(guid: "abc")
        var local = EpisodeSyncState(episode: ep, subscriptionID: subID)
        local.markClean()
        local.playedState = .played

        CloudKitSync.populate(record, from: local)

        // playedState updated, wasCompleted preserved from the server record.
        let decoded = try XCTUnwrap(CloudKitSync.episodeSyncState(from: record))
        XCTAssertEqual(decoded.playedState, .played)
        XCTAssertTrue(decoded.wasCompleted)
    }
}
