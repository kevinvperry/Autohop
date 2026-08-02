import XCTest
@testable import AutohopTV

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
