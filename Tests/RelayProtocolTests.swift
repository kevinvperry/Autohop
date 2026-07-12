// AI CONTEXT — Protocol-level regression tests for relay v2. These cover the
// pure pieces shared by iOS and tvOS: URL normalization used for membership
// diffs, opaque-ID persistence used by targeted APNs wakes, and the exponential
// delay that prevents retry storms after relay pressure/failure.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
import UIKit
@testable import Autohop
#endif

final class RelayProtocolTests: XCTestCase {
    func testCanonicalizerMatchesRelayTrackingAndFragmentRules() throws {
        let input = try XCTUnwrap(URL(string: "HTTPS://Example.COM/feed.xml?utm_source=test&keep=yes#episode"))
        XCTAssertEqual(
            RelayFeedURLCanonicalizer.string(for: input),
            "https://example.com/feed.xml?keep=yes"
        )
    }

    func testCanonicalizerRejectsNonHTTPFeed() throws {
        let input = try XCTUnwrap(URL(string: "file:///private/feed.xml"))
        XCTAssertNil(RelayFeedURLCanonicalizer.string(for: input))
    }

    func testCanonicalizerMatchesJavaScriptRootSlash() throws {
        let input = try XCTUnwrap(URL(string: "https://EXAMPLE.com"))
        XCTAssertEqual(RelayFeedURLCanonicalizer.string(for: input), "https://example.com/")
    }

    func testOpaqueMappingSeparatesKnownAndUnknownIDs() {
        let suite = "RelayProtocolTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        RelayFeedMappingStore.replace(with: [
            RelayFeedDescriptor(id: "feed-a", url: "https://example.com/a.xml"),
            RelayFeedDescriptor(id: "feed-b", url: "https://example.com/b.xml")
        ], defaults: defaults)

        let result = RelayFeedMappingStore.urlStrings(
            for: ["feed-b", "missing", "feed-b"],
            defaults: defaults
        )
        XCTAssertEqual(result.known, ["https://example.com/b.xml"])
        XCTAssertEqual(result.unknown, ["missing"])
    }

    func testRetryPolicyDoublesAndCaps() {
        XCTAssertEqual(RelayRetryPolicy.delay(failureCount: 0), 0)
        XCTAssertEqual(RelayRetryPolicy.delay(failureCount: 1), 30)
        XCTAssertEqual(RelayRetryPolicy.delay(failureCount: 2), 60)
        XCTAssertEqual(RelayRetryPolicy.delay(failureCount: 3), 120)
        XCTAssertEqual(RelayRetryPolicy.delay(failureCount: 20), 15 * 60)
    }

    #if !AUTOHOP_SPM
    /// App-target coverage for the UIKit completion arbiter. The deadline and
    /// network path can arrive in either order; UIKit must be called once only.
    @MainActor
    func testRelayPushCompletionGateWorkWinsExactlyOnce() {
        var results: [UIBackgroundFetchResult] = []
        let gate = RelayPushCompletionGate(type: "feed-updated", feedIDCount: 1) {
            results.append($0)
        }

        gate.finish(result: .newData, source: .workFinished)
        gate.finish(result: .noData, source: .deadline)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first, .newData)
    }

    @MainActor
    func testRelayPushCompletionGateDeadlineWinsExactlyOnce() {
        var results: [UIBackgroundFetchResult] = []
        let gate = RelayPushCompletionGate(type: "feed-updated", feedIDCount: 2) {
            results.append($0)
        }

        gate.finish(result: .noData, source: .deadline)
        gate.finish(result: .newData, source: .workFinished)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first, .noData)
    }

    func testBackgroundTaskCompletionGateCanBeClaimedOnlyOnce() {
        let gate = BackgroundTaskCompletionGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }
    #endif
}
