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
