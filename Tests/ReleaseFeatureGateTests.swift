// AI CONTEXT — Tests/ReleaseFeatureGateTests.swift
// Xcode-only characterization of the shipping feature boundary. The companion
// Scripts/validate-release.sh check protects project.yml and signed archives;
// this test proves the compiled app module resolves the release-gate constants
// to the expected disabled values in the ordinary test configuration.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class ReleaseFeatureGateTests: XCTestCase {
    #if !AUTOHOP_SPM
    func testDevelopmentOnlyProductSurfacesDefaultOff() {
        XCTAssertFalse(ReleaseFeatures.autohopPro)
        XCTAssertFalse(ReleaseFeatures.relayService)
        XCTAssertFalse(ReleaseFeatures.submitTVApp)
    }
    #endif
}
