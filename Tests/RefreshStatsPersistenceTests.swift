import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

// AI CONTEXT — Tests/RefreshStatsPersistenceTests.swift
// Compatibility tests for the Release Radar parse-memory quarantine fields
// persisted inside RefreshStats. Legacy JSON must decode with a disabled
// quarantine, while current payloads must preserve both the expiry and strike
// count. Keep these tests whenever RefreshStats gains non-optional persisted
// fields: old subscription rows remain valid upgrade inputs.
final class RefreshStatsPersistenceTests: XCTestCase {
    func testCycleMemoryCeilingStopsOnEitherProcessMeasure() {
        XCTAssertFalse(FeedParseMemorySafety.shouldStopCycle(
            footprintMB: 449,
            residentMB: 599
        ))
        XCTAssertTrue(FeedParseMemorySafety.shouldStopCycle(
            footprintMB: 450,
            residentMB: 100
        ))
        XCTAssertTrue(FeedParseMemorySafety.shouldStopCycle(
            footprintMB: 100,
            residentMB: 600
        ))
    }
    func testParseMemorySafetyUsesEitherMetricAtInclusiveBoundary() {
        XCTAssertNil(
            FeedParseMemorySafety.quarantineDecision(
                footprintDeltaMB: 199,
                residentDeltaMB: 199,
                previousConsecutiveHighMemoryParses: 0
            )
        )

        let footprintDecision = FeedParseMemorySafety.quarantineDecision(
            footprintDeltaMB: 200,
            residentDeltaMB: 0,
            previousConsecutiveHighMemoryParses: 0
        )
        XCTAssertEqual(footprintDecision?.consecutiveHighMemoryParses, 1)
        XCTAssertEqual(
            footprintDecision?.quarantineDuration,
            FeedParseMemorySafety.initialQuarantine
        )

        XCTAssertNotNil(
            FeedParseMemorySafety.quarantineDecision(
                footprintDeltaMB: 0,
                residentDeltaMB: 200,
                previousConsecutiveHighMemoryParses: 0
            )
        )
    }

    func testRepeatedUnsafeParseEscalatesQuarantine() {
        let decision = FeedParseMemorySafety.quarantineDecision(
            footprintDeltaMB: 250,
            residentDeltaMB: 0,
            previousConsecutiveHighMemoryParses: 1
        )

        XCTAssertEqual(decision?.consecutiveHighMemoryParses, 2)
        XCTAssertEqual(
            decision?.quarantineDuration,
            FeedParseMemorySafety.repeatedQuarantine
        )
    }

    func testLegacyPayloadDefaultsParseQuarantineState() throws {
        let stats = try JSONDecoder().decode(
            RefreshStats.self,
            from: Data("{}".utf8)
        )

        XCTAssertNil(stats.parseQuarantineUntil)
        XCTAssertEqual(stats.consecutiveHighMemoryParses, 0)
    }

    func testParseQuarantineStateRoundTrips() throws {
        let until = Date(timeIntervalSince1970: 1_780_000_000)
        let original = RefreshStats(
            parseQuarantineUntil: until,
            consecutiveHighMemoryParses: 2
        )

        let decoded = try JSONDecoder().decode(
            RefreshStats.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.parseQuarantineUntil, until)
        XCTAssertEqual(decoded.consecutiveHighMemoryParses, 2)
    }
}
