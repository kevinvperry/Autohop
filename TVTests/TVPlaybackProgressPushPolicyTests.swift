import XCTest
@testable import AutohopTV

final class TVPlaybackProgressPushPolicyTests: XCTestCase {
    func testFirstPlaybackProgressRequestsUpload() {
        XCTAssertTrue(
            TVPlaybackProgressPushPolicy.shouldRequestPush(
                now: Date(timeIntervalSince1970: 1_000),
                lastRequestedAt: .distantPast
            )
        )
    }

    func testRepeatedProgressWithinMinuteDoesNotRequestAnotherUpload() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(
            TVPlaybackProgressPushPolicy.shouldRequestPush(
                now: last.addingTimeInterval(59),
                lastRequestedAt: last
            )
        )
    }

    func testProgressAtOneMinuteRequestsUpload() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            TVPlaybackProgressPushPolicy.shouldRequestPush(
                now: last.addingTimeInterval(60),
                lastRequestedAt: last
            )
        )
    }
}
