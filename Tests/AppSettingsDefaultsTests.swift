// AI CONTEXT — Tests/AppSettingsDefaultsTests.swift. Regression tests for
// global AppSettings defaults that are promised in SettingsView, SupportContent,
// FEATURES.md, and the website. These tests protect product-facing defaults
// rather than algorithmic behavior; update them only when the product decision
// and every user-facing description change together. Also protects specialist
// Auto Archive values whose persisted raw value and exact duration are part of
// the per-podcast settings contract. Play Instant tests also protect its opt-in
// default and backward-compatible decoding for pre-Version-1.4 subscriptions.
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

    func testFreshInstallEnablesCloudSyncAndUsefulNotifications() {
        let settings = AppSettings.default

        XCTAssertTrue(settings.iCloudSyncEnabled)
        XCTAssertTrue(settings.notifyNewEpisodes)
        XCTAssertTrue(settings.recapWeeklyEnabled)
        XCTAssertFalse(settings.recapMonthlyEnabled)
        XCTAssertFalse(settings.recapYearlyEnabled)
        XCTAssertTrue(settings.showQueueBadge)
    }

    func testLegacySettingsWithoutNewDefaultFieldsRemainOptedOut() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertFalse(decoded.iCloudSyncEnabled)
        XCTAssertFalse(decoded.notifyNewEpisodes)
        XCTAssertFalse(decoded.recapWeeklyEnabled)
    }

    func testFreshUserDefaultsNewSubscriptionsToStrongVocalBoost() {
        XCTAssertEqual(
            AppSettings.default.defaultPlaybackPreference.vocalBoostLevel,
            .strong
        )
        // The legacy/per-subscription fallback deliberately remains Off.
        XCTAssertEqual(PlaybackPreference.default.vocalBoostLevel, .off)
    }

    func testExistingSavedDefaultVocalBoostIsPreserved() throws {
        var settings = AppSettings.default
        settings.defaultPlaybackPreference.vocalBoostLevel = .light

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.defaultPlaybackPreference.vocalBoostLevel, .light)
    }

    func testLegacySettingsWithoutGlobalPlaybackDefaultRemainOff() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.defaultPlaybackPreference.vocalBoostLevel, .off)
    }

    func testThirtyMinuteInactiveArchiveOptionHasStablePersistenceAndDuration() throws {
        let option = AutoArchiveSettings.AfterInactive.minutes30

        XCTAssertEqual(option.title, "30 Minutes")
        XCTAssertEqual(option.interval, 30 * 60)

        let encoded = try JSONEncoder().encode(option)
        XCTAssertEqual(try JSONDecoder().decode(AutoArchiveSettings.AfterInactive.self, from: encoded), option)
    }

    func testLegacyFortyMinuteInactiveArchiveOptionMigratesToThirtyMinutes() throws {
        let legacy = Data(#""minutes40""#.utf8)

        XCTAssertEqual(
            try JSONDecoder().decode(AutoArchiveSettings.AfterInactive.self, from: legacy),
            .minutes30
        )
    }

    func testPlayInstantDefaultsOffAndRoundTripsWhenEnabled() throws {
        XCTAssertFalse(AutoArchiveSettings.default.playInstantEnabled)

        let enabled = AutoArchiveSettings(playInstantEnabled: true)
        let decoded = try JSONDecoder().decode(
            AutoArchiveSettings.self,
            from: JSONEncoder().encode(enabled)
        )
        XCTAssertTrue(decoded.playInstantEnabled)
        XCTAssertEqual(decoded.afterPlayed, enabled.afterPlayed)
        XCTAssertEqual(decoded.afterInactive, enabled.afterInactive)
        XCTAssertEqual(decoded.episodeLimit, enabled.episodeLimit)
    }

    func testLegacyAutoArchivePayloadDefaultsPlayInstantOff() throws {
        let legacyJSON = Data(#"{"afterPlayed":"afterPlaying","afterInactive":"days7","episodeLimit":1}"#.utf8)

        let decoded = try JSONDecoder().decode(AutoArchiveSettings.self, from: legacyJSON)
        XCTAssertFalse(decoded.playInstantEnabled)
        XCTAssertEqual(decoded.afterPlayed, .afterPlaying)
        XCTAssertEqual(decoded.afterInactive, .days7)
        XCTAssertEqual(decoded.episodeLimit, .one)
    }
}
