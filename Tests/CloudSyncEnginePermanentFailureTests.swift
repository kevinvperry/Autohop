// AI CONTEXT — Tests/CloudSyncEnginePermanentFailureTests.swift. Pure tests for
// CloudSyncEngine's permanent CloudKit push-failure and retired-pending-change
// classifiers plus targeted queue/subscription compatibility and account
// fingerprint and empty-environment bootstrap classifiers. CKSyncEngine itself
// is not run in unit tests; these cases protect
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

    func testPhoneBootstrapsLocalLibraryWhenRemoteEnvironmentIsEmpty() {
        XCTAssertTrue(CloudSyncEngine.shouldBootstrapEmptySubscriptionEnvironment(
            pushesSubscriptionState: true,
            remoteRecordCount: 0,
            localSubscriptionCount: 134,
            alreadyAttempted: false
        ))
    }

    func testTVCanNeverBootstrapSubscriptionState() {
        XCTAssertFalse(CloudSyncEngine.shouldBootstrapEmptySubscriptionEnvironment(
            pushesSubscriptionState: false,
            remoteRecordCount: 0,
            localSubscriptionCount: 134,
            alreadyAttempted: false
        ))
    }

    func testNonemptyRemoteEnvironmentAndRepeatedAttemptDoNotBootstrap() {
        XCTAssertFalse(CloudSyncEngine.shouldBootstrapEmptySubscriptionEnvironment(
            pushesSubscriptionState: true,
            remoteRecordCount: 1,
            localSubscriptionCount: 134,
            alreadyAttempted: false
        ))
        XCTAssertFalse(CloudSyncEngine.shouldBootstrapEmptySubscriptionEnvironment(
            pushesSubscriptionState: true,
            remoteRecordCount: 0,
            localSubscriptionCount: 134,
            alreadyAttempted: true
        ))
    }

    func testReadOnlyCompanionConsumesLegacySubscriptionWhenNoCurrentRecordExists() {
        let id = UUID()
        let legacy = CKRecord(
            recordType: CloudKitSync.subscriptionRecordType,
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: CloudKitSync.zoneID)
        )

        let selection = CloudSyncEngine.preferredSubscriptionRecords(
            from: [legacy],
            allowLegacyFallback: true
        )

        XCTAssertEqual(selection.records.map(\.recordID), [legacy.recordID])
        XCTAssertEqual(selection.current, 0)
        XCTAssertEqual(selection.legacyFallback, 1)
        XCTAssertEqual(selection.legacyShadowed, 0)
    }

    func testNamespacedSubscriptionAlwaysWinsOverLegacyRecord() {
        let id = UUID()
        let legacy = CKRecord(
            recordType: CloudKitSync.subscriptionRecordType,
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: CloudKitSync.zoneID)
        )
        let current = CKRecord(
            recordType: CloudKitSync.subscriptionRecordType,
            recordID: CloudKitSync.subscriptionRecordID(id: id)
        )

        let selection = CloudSyncEngine.preferredSubscriptionRecords(
            from: [legacy, current],
            allowLegacyFallback: true
        )

        XCTAssertEqual(selection.records.map(\.recordID), [current.recordID])
        XCTAssertEqual(selection.current, 1)
        XCTAssertEqual(selection.legacyFallback, 0)
        XCTAssertEqual(selection.legacyShadowed, 1)
    }

    func testPhoneAuthorityLeavesLegacyRecordToNamespaceRecovery() {
        let id = UUID()
        let legacy = CKRecord(
            recordType: CloudKitSync.subscriptionRecordType,
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: CloudKitSync.zoneID)
        )

        let selection = CloudSyncEngine.preferredSubscriptionRecords(
            from: [legacy],
            allowLegacyFallback: false
        )

        XCTAssertTrue(selection.records.isEmpty)
        XCTAssertEqual(selection.legacyFallback, 0)
        XCTAssertEqual(selection.legacyShadowed, 1)
    }

    func testAccountFingerprintIsStableAndSeparatesAccounts() {
        let first = CloudSyncEngine.accountFingerprint(forRecordName: "account-a")
        XCTAssertEqual(first, CloudSyncEngine.accountFingerprint(forRecordName: "account-a"))
        XCTAssertNotEqual(first, CloudSyncEngine.accountFingerprint(forRecordName: "account-b"))
        XCTAssertEqual(first.count, 16)
        XCTAssertFalse(first.contains("account-a"))
    }

    func testMissingQueueRecordIsHealthyNotAuthoredState() {
        XCTAssertEqual(
            CloudSyncEngine.queueSnapshotFetchResult(forCloudKitErrorCode: .unknownItem),
            .notAuthored
        )
    }

    func testMissingProductionZoneIsHealthyNotAuthoredState() {
        XCTAssertEqual(
            CloudSyncEngine.queueSnapshotFetchResult(forCloudKitErrorCode: .zoneNotFound),
            .notAuthored
        )
    }

    func testQueueNetworkFailureRemainsFailure() {
        XCTAssertEqual(
            CloudSyncEngine.queueSnapshotFetchResult(forCloudKitErrorCode: .networkUnavailable),
            .failed
        )
    }

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

    // MARK: - Read-only subscription-state mode (2026-07-11)
    // The classifier behind `pushesSubscriptionState: false` — a device in
    // that mode (the TV) drops every pending SubscriptionState change, save
    // OR delete, and nothing else.

    func testSubscriptionStateChangeIsDetectedForSaveAndDelete() {
        let zone = CKRecordZone.ID(zoneName: "AutohopSync", ownerName: CKCurrentUserDefaultName)
        let subscriptionRecordID = CKRecord.ID(recordName: "subscription:\(UUID().uuidString)", zoneID: zone)

        XCTAssertTrue(CloudSyncEngine.isSubscriptionStateChange(.saveRecord(subscriptionRecordID)))
        XCTAssertTrue(CloudSyncEngine.isSubscriptionStateChange(.deleteRecord(subscriptionRecordID)))
    }

    func testNonSubscriptionChangesAreNotBlockedByReadOnlyMode() {
        let zone = CKRecordZone.ID(zoneName: "AutohopSync", ownerName: CKCurrentUserDefaultName)
        let episodeID = CKRecord.ID(recordName: "episode:\(UUID().uuidString)|guid:abc", zoneID: zone)
        let historyID = CKRecord.ID(recordName: "history:some-entry", zoneID: zone)
        let statsID = CKRecord.ID(recordName: "stats:\(UUID().uuidString):2026-07-11", zoneID: zone)
        let queueID = CKRecord.ID(recordName: "queue:current", zoneID: zone)

        for id in [episodeID, historyID, statsID, queueID] {
            XCTAssertFalse(
                CloudSyncEngine.isSubscriptionStateChange(.saveRecord(id)),
                "\(id.recordName) must still push from a subscription-state read-only device"
            )
        }
    }
}
