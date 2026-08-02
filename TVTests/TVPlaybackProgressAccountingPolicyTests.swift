import XCTest
@testable import AutohopTV

// AI CONTEXT — Protects tvOS listening totals from resume/scrub inflation.
// AVPlayer sends seeks and ordinary playback through one time callback; this
// test fixes the classification boundary independently of a player/device.
final class TVPlaybackProgressAccountingPolicyTests: XCTestCase {
    func testNaturalPlaybackTicksAreCounted() {
        XCTAssertTrue(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(0.5))
        XCTAssertTrue(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(4.9))
    }

    func testResumeAndScrubJumpsAreNotCounted() {
        XCTAssertFalse(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(5))
        XCTAssertFalse(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(2_197))
        XCTAssertFalse(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(4_960))
    }

    func testBackwardOrStationaryUpdatesAreNotCounted() {
        XCTAssertFalse(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(0))
        XCTAssertFalse(TVPlaybackProgressAccountingPolicy.isNaturalPlaybackDelta(-30))
    }
}
