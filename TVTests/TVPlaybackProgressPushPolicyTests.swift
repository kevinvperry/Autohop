import XCTest
@testable import AutohopTV

// AI CONTEXT — TVTests/TVPlaybackProgressPushPolicyTests.swift
// PURPOSE: Locks the throttling boundary for tvOS playback-position uploads.
// OWNERSHIP: Tests the pure TVPlaybackProgressPushPolicy independently of
// AVPlayer, CloudKit, ListeningHistoryStore, and TVPlaybackModel lifecycle.
// INVARIANT: The first progress observation uploads; subsequent observations
// are suppressed until one minute has elapsed, limiting CloudKit churn while
// preserving cross-device resume freshness.
// FAILURE MEANING: Treat a changed interval as a sync-product decision and
// update SYNC_DESIGN.md; do not work around it in player callbacks.
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
