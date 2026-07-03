// AI CONTEXT — Tests/AppSettingsDefaultsTests.swift. Regression tests for
// global AppSettings defaults that are promised in SettingsView, SupportContent,
// FEATURES.md, and the website. These tests protect product-facing defaults
// rather than algorithmic behavior; update them only when the product decision
// and every user-facing description change together.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class AppSettingsDefaultsTests: XCTestCase {

    func testAutomaticDownloadsAreEnabledOnWifiAndCellularByDefault() {
        let settings = AppSettings.default

        XCTAssertTrue(settings.downloadOverWifi)
        XCTAssertTrue(settings.downloadOverCellular)
    }

    func testUserFacingGlobalDefaultsStayPrivateAndOptIn() {
        let settings = AppSettings.default

        XCTAssertFalse(settings.iCloudSyncEnabled)
        XCTAssertFalse(settings.notifyNewEpisodes)
        XCTAssertTrue(settings.showQueueBadge)
    }
}
