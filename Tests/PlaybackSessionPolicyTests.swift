// AI CONTEXT — Tests/PlaybackSessionPolicyTests.swift. Pins the playback
// DECISIONS extracted from AppState in Phase 0 item 4 (tvOS proposal):
// effective preference (browse-feed + Shared Listening overrides), resume-vs-
// start-skip start resolution, speed cycling/normalization, and chapter
// prev/next navigation. These are exact ports of historical AppState behavior
// shared by every playback surface — treat a failure as a real on-device
// behavior change, not test rot.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class PlaybackSessionPolicyTests: XCTestCase {

    private func makePreference(speed: Double, trim: TrimSilenceAmount = .low) -> PlaybackPreference {
        PlaybackPreference(
            speed: speed,
            startSkipSeconds: 0,
            endSkipSeconds: 0,
            vocalBoostLevel: .strong,
            trimSilence: trim
        )
    }

    // MARK: - Effective preference

    func testSubscribedFeedUsesItsOwnPreference() {
        let own = makePreference(speed: 1.8)
        let result = PlaybackSessionPolicy.effectivePreference(
            subscriptionPreference: own,
            isBrowseFeed: false,
            defaultPreference: makePreference(speed: 1.2),
            sharedListeningSpeed: nil
        )
        XCTAssertEqual(result, own)
    }

    func testBrowseFeedAlwaysFollowsGlobalDefault() {
        let global = makePreference(speed: 1.2)
        let result = PlaybackSessionPolicy.effectivePreference(
            subscriptionPreference: makePreference(speed: 1.8),
            isBrowseFeed: true,
            defaultPreference: global,
            sharedListeningSpeed: nil
        )
        XCTAssertEqual(result, global)
    }

    func testSharedListeningOverridesSpeedAndForcesTrimOff() {
        let result = PlaybackSessionPolicy.effectivePreference(
            subscriptionPreference: makePreference(speed: 1.8, trim: .low),
            isBrowseFeed: false,
            defaultPreference: makePreference(speed: 1.2),
            sharedListeningSpeed: 1.1
        )
        XCTAssertEqual(result.speed, 1.1)
        XCTAssertEqual(result.trimSilence, .off)
        // Everything else keeps the subscription's own values.
        XCTAssertEqual(result.vocalBoostLevel, .strong)
    }

    // MARK: - Start resolution

    func testResumeBeyondStartSkipSeeksAndIsNotFresh() {
        let start = PlaybackSessionPolicy.startResolution(resumeTime: 300, startSkipSeconds: 15)
        XCTAssertEqual(start.seekTarget, 300)
        XCTAssertEqual(start.reportedStartTime, 300)
        XCTAssertFalse(start.isFreshStart)
    }

    func testNoResumeReportsStartSkipAndIsFresh() {
        let start = PlaybackSessionPolicy.startResolution(resumeTime: 0, startSkipSeconds: 15)
        XCTAssertNil(start.seekTarget)
        XCTAssertEqual(start.reportedStartTime, 15)
        XCTAssertTrue(start.isFreshStart)
    }

    func testResumeEqualToStartSkipCountsAsFresh() {
        // Historical rule: `resume > startSkip` wins; equality is a fresh start.
        let start = PlaybackSessionPolicy.startResolution(resumeTime: 15, startSkipSeconds: 15)
        XCTAssertNil(start.seekTarget)
        XCTAssertTrue(start.isFreshStart)
    }

    // MARK: - Speed selection

    func testCycledSpeedAdvancesAndWraps() {
        XCTAssertEqual(PlaybackSessionPolicy.cycledSpeed(after: 1.0, options: [1.0, 1.5, 2.0]), 1.5)
        XCTAssertEqual(PlaybackSessionPolicy.cycledSpeed(after: 2.0, options: [1.0, 1.5, 2.0]), 1.0)
    }

    func testCycledSpeedToleratesFloatNoiseAndUnknownSpeeds() {
        // ±0.01 tolerance finds the current option despite Double noise.
        XCTAssertEqual(PlaybackSessionPolicy.cycledSpeed(after: 1.4999, options: [1.0, 1.5, 2.0]), 2.0)
        // An unknown speed cycles from the first option.
        XCTAssertEqual(PlaybackSessionPolicy.cycledSpeed(after: 3.7, options: [1.0, 1.5, 2.0]), 1.5)
        XCTAssertNil(PlaybackSessionPolicy.cycledSpeed(after: 1.0, options: []))
    }

    func testNormalizedSpeedPicksNearestOption() {
        XCTAssertEqual(PlaybackSessionPolicy.normalizedSpeed(closestTo: 1.62, options: [1.0, 1.6, 2.0]), 1.6)
        XCTAssertEqual(PlaybackSessionPolicy.normalizedSpeed(closestTo: 9.0, options: [1.0, 1.6, 2.0]), 2.0)
        XCTAssertEqual(PlaybackSessionPolicy.normalizedSpeed(closestTo: 1.3, options: []), 1.3)
    }

    // MARK: - Chapter navigation

    private func makeChapters() -> [Chapter] {
        [
            Chapter(position: 0, title: "Intro", startSeconds: 0, source: .pscChapters),
            Chapter(position: 2, title: "Topic", startSeconds: 120, source: .pscChapters),
            Chapter(position: 5, title: "Outro", startSeconds: 900, source: .pscChapters)
        ]
    }

    func testChapterNavigationMovesWithinActiveList() {
        let chapters = makeChapters()
        XCTAssertEqual(PlaybackSessionPolicy.previousChapterStart(from: chapters[1], in: chapters), 0)
        XCTAssertEqual(PlaybackSessionPolicy.nextChapterStart(from: chapters[1], in: chapters), 900)
    }

    func testChapterNavigationStopsAtListEdges() {
        let chapters = makeChapters()
        XCTAssertNil(PlaybackSessionPolicy.previousChapterStart(from: chapters[0], in: chapters))
        XCTAssertNil(PlaybackSessionPolicy.nextChapterStart(from: chapters[2], in: chapters))
    }

    func testChapterNotInActiveListNavigatesNowhere() {
        // e.g. the current chapter was filtered out after chapters updated.
        let orphan = Chapter(position: 9, title: "Gone", startSeconds: 50, source: .pscChapters)
        XCTAssertNil(PlaybackSessionPolicy.previousChapterStart(from: orphan, in: makeChapters()))
        XCTAssertNil(PlaybackSessionPolicy.nextChapterStart(from: orphan, in: makeChapters()))
    }
}
