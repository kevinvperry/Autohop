import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

// AI CONTEXT — Regression coverage for AirPods automatic-ear-detection route
// transitions. A stale currentRoute that still names the removed AirPods must
// not cancel the pending playback pause.
final class AudioRouteLossPolicyTests: XCTestCase {
    func testRemovedDeviceCannotReplaceItself() {
        XCTAssertFalse(
            AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: "Bluetooth|airpods-1",
                previousOutputIdentifier: "Bluetooth|airpods-1",
                currentOutputIsBuiltIn: false
            )
        )
    }

    func testBuiltInFallbackDoesNotCancelPause() {
        XCTAssertFalse(
            AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: "Speaker|iphone",
                previousOutputIdentifier: "Bluetooth|airpods-1",
                currentOutputIsBuiltIn: true
            )
        )
    }

    func testMissingPreviousRouteDoesNotProveReplacement() {
        XCTAssertFalse(
            AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: "Bluetooth|airpods-1",
                previousOutputIdentifier: nil,
                currentOutputIsBuiltIn: false
            )
        )
    }

    func testDistinctWirelessReplacementCancelsPendingPause() {
        XCTAssertTrue(
            AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: "Bluetooth|airpods-2",
                previousOutputIdentifier: "Bluetooth|airpods-1",
                currentOutputIsBuiltIn: false
            )
        )
    }

    func testExplicitNewDeviceSignalConfirmsSameAirPodsReturned() {
        XCTAssertTrue(
            AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: "Bluetooth|airpods-1",
                previousOutputIdentifier: "Bluetooth|airpods-1",
                currentOutputIsBuiltIn: false,
                explicitNewDeviceSignal: true
            )
        )
    }
}
