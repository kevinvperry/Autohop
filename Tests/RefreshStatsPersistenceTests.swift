import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

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
