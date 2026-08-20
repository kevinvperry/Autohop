import XCTest
import AutohopCore
@testable import AutohopTV

// AI CONTEXT — Guards the single-owner Siri Remote transport contract. Native
// AVKit owns video commands; Autohop owns commands only where its custom audio
// UI has no AVPlayerViewController transport implementation.
final class TVPlayerTransportPolicyTests: XCTestCase {
    func testNativeAVKitExclusivelyOwnsVideoTransport() {
        XCTAssertEqual(TVPlayerTransportPolicy.owner(for: .video), .avKit)
    }

    func testAutohopOwnsAudioAndPreflightTransport() {
        XCTAssertEqual(TVPlayerTransportPolicy.owner(for: .audio), .autohop)
        XCTAssertEqual(TVPlayerTransportPolicy.owner(for: nil), .autohop)
    }
}
