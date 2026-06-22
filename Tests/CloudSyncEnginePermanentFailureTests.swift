// AI CONTEXT — Tests/CloudSyncEnginePermanentFailureTests.swift. Pure tests for
// CloudSyncEngine's permanent CloudKit push-failure and retired-pending-change
// classifiers. CKSyncEngine itself is not run in unit tests; these cases protect
// the Phase-1 quarantine guard and the Phase-2 namespace repair guard that
// discards restored pre-namespace saves before they can collide again. Keep the
// classifiers narrow: unrelated CK errors must stay retryable, and legacy
// deletes must not be retired by the legacy-save guard.
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class CloudSyncEnginePermanentFailureTests: XCTestCase {

    private let collisionDescription =
        "Error saving record to server: invalid attempt to update record from type 'HistoryEntry' to 'EpisodeState'"

    func testHistoryToEpisodeTypeCollisionIsPermanentForInvalidArguments() {
        XCTAssertTrue(CloudSyncEngine.isPermanentRecordTypeCollision(
            code: .invalidArguments,
            localizedDescription: collisionDescription,
            recordType: CloudKitSync.episodeRecordType
        ))
    }

    func testHistoryToEpisodeTypeCollisionIsPermanentForServerRejectedRequest() {
        XCTAssertTrue(CloudSyncEngine.isPermanentRecordTypeCollision(
            code: .serverRejectedRequest,
            localizedDescription: collisionDescription,
            recordType: CloudKitSync.episodeRecordType
        ))
    }

    func testUnrelatedInvalidArgumentsErrorRemainsRetryable() {
        XCTAssertFalse(CloudSyncEngine.isPermanentRecordTypeCollision(
            code: .invalidArguments,
            localizedDescription: "Invalid field value",
            recordType: CloudKitSync.episodeRecordType
        ))
    }

    func testCollisionTextOnOtherRecordTypeIsNotQuarantined() {
        XCTAssertFalse(CloudSyncEngine.isPermanentRecordTypeCollision(
            code: .invalidArguments,
            localizedDescription: collisionDescription,
            recordType: CloudKitSync.historyRecordType
        ))
    }

    func testLegacyPendingSaveIsRetiredAfterNamespaceMigration() {
        let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CKRecord.ID(recordName: "legacy-guid", zoneID: CloudKitSync.zoneID)
        )

        XCTAssertTrue(CloudSyncEngine.isRetiredLegacyPendingSave(change))
    }

    func testNamespacedPendingSaveIsKeptAfterNamespaceMigration() {
        let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CloudKitSync.episodeRecordID(syncKey: "sub|guid:episode")
        )

        XCTAssertFalse(CloudSyncEngine.isRetiredLegacyPendingSave(change))
    }

    func testLegacyPendingDeleteIsNotRetiredBySaveGuard() {
        let change = CKSyncEngine.PendingRecordZoneChange.deleteRecord(
            CKRecord.ID(recordName: "legacy-guid", zoneID: CloudKitSync.zoneID)
        )

        XCTAssertFalse(CloudSyncEngine.isRetiredLegacyPendingSave(change))
    }
}
