// AI CONTEXT — Tests/AdaptiveLayoutTests.swift. Regression coverage for the
// shared responsive sizing policy used by iPhone, iPad, Mac-compatible and
// future variable-width layouts. It protects width-band boundaries, readable
// content limits, and Discover's phone-baseline scaling of text, artwork and
// decorative assets. AdaptiveLayout is application-view infrastructure and is
// intentionally not part of the platform-neutral AutohopCore Swift package.
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

    func testEditorialContentScalePreservesPhoneAndGrowsWithViewport() {
        let narrow = AdaptiveEditorialMetrics(containerWidth: 320)
        let standard = AdaptiveEditorialMetrics(containerWidth: 390)
        let wide = AdaptiveEditorialMetrics(containerWidth: 600)
        let expansive = AdaptiveEditorialMetrics(containerWidth: 1_024)

        XCTAssertEqual(standard.contentScale, 1)
        XCTAssertLessThan(narrow.contentScale, standard.contentScale)
        XCTAssertLessThan(standard.contentScale, wide.contentScale)
        XCTAssertLessThan(wide.contentScale, expansive.contentScale)

        XCTAssertEqual(standard.scaled(40), 40)
        XCTAssertGreaterThan(wide.scaled(40), standard.scaled(40))
        XCTAssertGreaterThan(expansive.scaled(40), wide.scaled(40))
    }

    func testDiscoverArtworkAndAssetsGrowAcrossLayoutBands() {
        let standard = AdaptiveEditorialMetrics(containerWidth: 390)
        let wide = AdaptiveEditorialMetrics(containerWidth: 600)
        let expansive = AdaptiveEditorialMetrics(containerWidth: 1_024)

        XCTAssertLessThan(standard.shelfArtworkSize, wide.shelfArtworkSize)
        XCTAssertLessThan(wide.shelfArtworkSize, expansive.shelfArtworkSize)
        XCTAssertLessThan(standard.heroArtworkSize, wide.heroArtworkSize)
        XCTAssertLessThan(wide.heroArtworkSize, expansive.heroArtworkSize)
        XCTAssertLessThan(standard.heroGhostRankSize, wide.heroGhostRankSize)
        XCTAssertLessThan(wide.heroGhostRankSize, expansive.heroGhostRankSize)
        XCTAssertLessThan(standard.shelfPlaceholderIconSize, wide.shelfPlaceholderIconSize)
        XCTAssertLessThan(wide.shelfPlaceholderIconSize, expansive.shelfPlaceholderIconSize)
    }
}
#endif
