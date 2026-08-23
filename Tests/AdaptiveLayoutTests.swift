// AI CONTEXT — Tests/AdaptiveLayoutTests.swift. Regression coverage for the
// shared responsive sizing policy used by iPhone, iPad, Mac-compatible and
// future variable-width layouts. It protects width-band boundaries, readable
// content limits, and the whole iOS-family app's phone-baseline scaling of
// navigation, persistent-player, artwork and decorative assets. AdaptiveLayout is
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
        XCTAssertEqual(AdaptiveLayoutMetrics.episodeListSurfaceWidth(for: 390), 350)
        XCTAssertEqual(AdaptiveLayoutMetrics.episodeListSurfaceWidth(for: 1_024), 860)
        XCTAssertEqual(AdaptiveLayoutMetrics.episodeListSurfaceWidth(for: 1_440), 860)
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

    func testDiscoverNavigationChromeGrowsAcrossLargeViewportBands() {
        let standard = AdaptiveEditorialMetrics(containerWidth: 390)
        let wide = AdaptiveEditorialMetrics(containerWidth: 600)
        let expansive = AdaptiveEditorialMetrics(containerWidth: 1_024)

        XCTAssertEqual(standard.navigationTitleFontSize, 17)
        XCTAssertLessThan(standard.navigationTitleFontSize, wide.navigationTitleFontSize)
        XCTAssertLessThan(wide.navigationTitleFontSize, expansive.navigationTitleFontSize)
        XCTAssertLessThan(standard.navigationBackSymbolSize, wide.navigationBackSymbolSize)
        XCTAssertLessThan(wide.navigationBackSymbolSize, expansive.navigationBackSymbolSize)
        XCTAssertLessThan(standard.navigationControlSize, wide.navigationControlSize)
        XCTAssertEqual(wide.navigationControlSize, 44)
        XCTAssertEqual(expansive.navigationControlSize, 44)
        XCTAssertLessThanOrEqual(expansive.navigationBackSymbolSize, expansive.navigationControlSize)
        XCTAssertEqual(standard.scaled(40), 40)
        XCTAssertEqual(wide.scaled(40), 46, accuracy: 0.001)
        XCTAssertEqual(expansive.scaled(40), 52, accuracy: 0.001)
    }

    func testPersistentMiniPlayerGrowsWithoutChangingPhoneBaseline() {
        let standard = AdaptiveEditorialMetrics(containerWidth: 390)
        let wide = AdaptiveEditorialMetrics(containerWidth: 600)
        let expansive = AdaptiveEditorialMetrics(containerWidth: 1_024)

        XCTAssertEqual(standard.miniPlayerArtworkSize, 40)
        XCTAssertEqual(wide.miniPlayerArtworkSize, 46)
        XCTAssertEqual(expansive.miniPlayerArtworkSize, 52)
        XCTAssertEqual(standard.miniPlayerControlSize, 44)
        XCTAssertEqual(wide.miniPlayerControlSize, 48)
        XCTAssertEqual(expansive.miniPlayerControlSize, 52)
    }

    func testPodcastHeaderOnlyCentersWhenContentColumnIsTrulyWide() {
        XCTAssertFalse(AdaptiveEditorialMetrics(containerWidth: 390).usesCenteredPodcastHeader)
        XCTAssertFalse(AdaptiveEditorialMetrics(containerWidth: 599).usesCenteredPodcastHeader)
        XCTAssertTrue(AdaptiveEditorialMetrics(containerWidth: 600).usesCenteredPodcastHeader)
        XCTAssertTrue(AdaptiveEditorialMetrics(containerWidth: 1_024).usesCenteredPodcastHeader)
    }

    func testSettingsShortcutSidebarOnlyAppearsInExpansiveLayouts() {
        XCTAssertFalse(AdaptiveEditorialMetrics(containerWidth: 390).usesSettingsShortcutSidebar)
        XCTAssertFalse(AdaptiveEditorialMetrics(containerWidth: 699).usesSettingsShortcutSidebar)
        XCTAssertTrue(AdaptiveEditorialMetrics(containerWidth: 700).usesSettingsShortcutSidebar)
        XCTAssertTrue(AdaptiveEditorialMetrics(containerWidth: 1_024).usesSettingsShortcutSidebar)
    }

    func testListRowsPreservePhoneDensityAndGrowOnLargerColumns() {
        let phone = AdaptiveListRowMetrics(containerWidth: 390)
        let splitView = AdaptiveListRowMetrics(containerWidth: 600)
        let fullScreen = AdaptiveListRowMetrics(containerWidth: 1_024)

        XCTAssertEqual(phone.artworkSize, 44)
        XCTAssertEqual(phone.minimumRowHeight, 44)
        XCTAssertEqual(splitView.artworkSize, 52)
        XCTAssertEqual(fullScreen.artworkSize, 60)
        XCTAssertLessThan(phone.primaryFontSize, splitView.primaryFontSize)
        XCTAssertLessThan(splitView.primaryFontSize, fullScreen.primaryFontSize)
        XCTAssertLessThan(phone.verticalPadding, fullScreen.verticalPadding)
        XCTAssertLessThan(phone.compactControlSize, splitView.compactControlSize)
        XCTAssertLessThan(splitView.compactControlSize, fullScreen.compactControlSize)
        XCTAssertLessThan(phone.leadingMarkerWidth, fullScreen.leadingMarkerWidth)
    }

    func testDetailElementsScaleAsOneSystemAcrossLargerColumns() {
        let phone = AdaptiveEditorialMetrics(containerWidth: 390)
        let splitView = AdaptiveEditorialMetrics(containerWidth: 600)
        let fullScreen = AdaptiveEditorialMetrics(containerWidth: 1_024)

        XCTAssertEqual(phone.detailTitleFontSize, 22)
        XCTAssertEqual(phone.detailDescriptionFontSize, 13)
        XCTAssertEqual(phone.detailPublisherFontSize, 15)
        XCTAssertEqual(phone.primaryButtonFontSize, 17)
        XCTAssertEqual(phone.primaryButtonHeight, 46)
        XCTAssertLessThan(phone.detailTitleFontSize, splitView.detailTitleFontSize)
        XCTAssertLessThan(splitView.detailTitleFontSize, fullScreen.detailTitleFontSize)
        XCTAssertLessThan(phone.detailDescriptionFontSize, splitView.detailDescriptionFontSize)
        XCTAssertLessThan(splitView.detailDescriptionFontSize, fullScreen.detailDescriptionFontSize)
        XCTAssertLessThan(phone.detailPublisherFontSize, splitView.detailPublisherFontSize)
        XCTAssertLessThan(splitView.detailPublisherFontSize, fullScreen.detailPublisherFontSize)
        XCTAssertLessThan(phone.primaryButtonFontSize, splitView.primaryButtonFontSize)
        XCTAssertLessThan(splitView.primaryButtonFontSize, fullScreen.primaryButtonFontSize)
        XCTAssertLessThan(phone.primaryButtonHeight, splitView.primaryButtonHeight)
        XCTAssertLessThan(splitView.primaryButtonHeight, fullScreen.primaryButtonHeight)
        XCTAssertEqual(phone.detailsMediaMaximumWidth, 720)
        XCTAssertEqual(fullScreen.detailsMediaMaximumWidth, 720)
        XCTAssertEqual(phone.detailsMetaCardMinimumWidth, 150)
        XCTAssertEqual(splitView.detailsMetaCardMinimumWidth, 170)
        XCTAssertEqual(fullScreen.detailsMetaCardMinimumWidth, 190)
        XCTAssertLessThan(phone.detailsMetaKeyFontSize, splitView.detailsMetaKeyFontSize)
        XCTAssertLessThan(splitView.detailsMetaKeyFontSize, fullScreen.detailsMetaKeyFontSize)
        XCTAssertEqual(phone.chapterSelectionControlSize, 24)
        XCTAssertEqual(splitView.chapterSelectionControlSize, 28)
        XCTAssertEqual(fullScreen.chapterSelectionControlSize, 32)
        XCTAssertLessThan(phone.chapterCheckmarkFontSize, splitView.chapterCheckmarkFontSize)
        XCTAssertLessThan(splitView.chapterCheckmarkFontSize, fullScreen.chapterCheckmarkFontSize)
    }
}
#endif
