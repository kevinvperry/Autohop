// AdaptiveLayout is application-view infrastructure and is intentionally not
// part of the platform-neutral AutohopCore Swift package.
#if !AUTOHOP_SPM
import XCTest
@testable import Autohop

final class AdaptiveLayoutTests: XCTestCase {
    func testWidthBandBoundaries() {
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 0), .narrow)
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 339), .narrow)
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 340), .standard)
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 499), .standard)
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 500), .wide)
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 699), .wide)
        XCTAssertEqual(AdaptiveLayoutBand.classify(width: 700), .expansive)
    }

    func testGuttersIncreaseWithAvailableWidth() {
        XCTAssertEqual(AdaptiveLayoutMetrics.horizontalGutter(for: 320), 12)
        XCTAssertEqual(AdaptiveLayoutMetrics.horizontalGutter(for: 390), 16)
        XCTAssertEqual(AdaptiveLayoutMetrics.horizontalGutter(for: 600), 20)
        XCTAssertEqual(AdaptiveLayoutMetrics.horizontalGutter(for: 900), 28)
    }

    func testReadableWidthHierarchy() {
        XCTAssertLessThanOrEqual(
            AdaptiveContentStyle.prose.maximumWidth,
            AdaptiveContentStyle.list.maximumWidth
        )
        XCTAssertLessThan(
            AdaptiveContentStyle.list.maximumWidth,
            AdaptiveContentStyle.editorial.maximumWidth
        )
    }
}
#endif
