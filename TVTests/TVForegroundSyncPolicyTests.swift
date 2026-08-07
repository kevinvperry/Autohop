import XCTest
@testable import AutohopTV

// AI CONTEXT — TVTests/TVForegroundSyncPolicyTests.swift
// PURPOSE: Regression coverage for the foreground queue-snapshot refresh gate.
// OWNERSHIP: Exercises only the pure TVForegroundSyncPolicy; no CloudKit
// account, database, app model, network request, or physical Apple TV exists.
// INVARIANT: A missing or maximum-age snapshot must fetch immediately, while a
// recent snapshot must not create redundant foreground CloudKit traffic.
// FAILURE MEANING: A failure indicates freshness/churn policy changed; do not
// compensate by adding timers or fetches in a SwiftUI view.
final class TVForegroundSyncPolicyTests: XCTestCase {
    func testMissingSnapshotFetchesImmediately() {
        XCTAssertTrue(TVForegroundSyncPolicy.shouldFetch(snapshotUpdatedAt: nil))
    }

    func testRecentSnapshotDoesNotRefetch() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(
            TVForegroundSyncPolicy.shouldFetch(
                snapshotUpdatedAt: now.addingTimeInterval(-60),
                now: now
            )
        )
    }

    func testSnapshotAtMaximumAgeRefetches() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(
            TVForegroundSyncPolicy.shouldFetch(
                snapshotUpdatedAt: now.addingTimeInterval(-TVForegroundSyncPolicy.maximumSnapshotAge),
                now: now
            )
        )
    }
}
