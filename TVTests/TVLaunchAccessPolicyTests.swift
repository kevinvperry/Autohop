import XCTest
@testable import AutohopTV

// AI CONTEXT — Ensures no bootstrap state can visually trap a clean-install
// reviewer: clean-install loading becomes actionable at ten seconds, while a
// returning library remains branded through ordinary catch-up and receives a
// separate bounded recovery deadline.

final class TVLaunchAccessPolicyTests: XCTestCase {
    func testLoadingBecomesActionableAtDeadline() {
        XCTAssertFalse(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .loading(message: "Loading"),
            cleanInstallDeadlineReached: false,
            hasReturningLibraryEvidence: false,
            returningRecoveryDeadlineReached: false
        ))
        XCTAssertTrue(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .loading(message: "Loading"),
            cleanInstallDeadlineReached: true,
            hasReturningLibraryEvidence: false,
            returningRecoveryDeadlineReached: false
        ))
    }

    func testStableNonReadyStatesExposeSetupAndReadyDoesNot() {
        XCTAssertTrue(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .empty,
            cleanInstallDeadlineReached: false,
            hasReturningLibraryEvidence: false,
            returningRecoveryDeadlineReached: false
        ))
        XCTAssertTrue(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .recoverableFailure(message: "Unavailable"),
            cleanInstallDeadlineReached: false,
            hasReturningLibraryEvidence: true,
            returningRecoveryDeadlineReached: false
        ))
        XCTAssertFalse(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .ready,
            cleanInstallDeadlineReached: true,
            hasReturningLibraryEvidence: true,
            returningRecoveryDeadlineReached: true
        ))
    }

    func testReturningLibraryKeepsLoadingPresentationDuringNormalCatchUp() {
        XCTAssertFalse(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .loading(message: "Refreshing"),
            cleanInstallDeadlineReached: true,
            hasReturningLibraryEvidence: true,
            returningRecoveryDeadlineReached: false
        ))
        XCTAssertFalse(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .empty,
            cleanInstallDeadlineReached: true,
            hasReturningLibraryEvidence: true,
            returningRecoveryDeadlineReached: false
        ))
        XCTAssertTrue(TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: .loading(message: "Refreshing"),
            cleanInstallDeadlineReached: true,
            hasReturningLibraryEvidence: true,
            returningRecoveryDeadlineReached: true
        ))
    }
}
