// AI CONTEXT — Tests/PodcastUserAgentTests.swift
// Protects the shared IAB-style podcast HTTP identity used by iOS and tvOS.
// The tests require stable app/device/OS differentiation while preventing
// accidental installation IDs or exact-hardware fingerprinting from entering
// feed, artwork, chapter, download or streaming requests.

import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class PodcastUserAgentTests: XCTestCase {
    func testIABStyleIdentityForIOS() {
        let value = PodcastUserAgent.make(
            appVersion: "1.5 beta!",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
            platform: .iPhone
        )

        XCTAssertEqual(value, "Autohop/1.5beta Apple iPhone iOS/26.1.0")
    }

    func testIABStyleIdentityForTVOS() {
        let value = PodcastUserAgent.make(
            appVersion: "0.1",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 2),
            platform: .appleTV
        )

        XCTAssertEqual(value, "Autohop/0.1 Apple AppleTV tvOS/26.0.2")
    }

    func testConfigurationPreservesOtherHeadersAndIdentifiesRequests() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["Accept": "application/rss+xml"]
        PodcastUserAgent.configure(configuration)

        XCTAssertEqual(configuration.httpAdditionalHeaders?["Accept"] as? String, "application/rss+xml")
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, PodcastUserAgent.value)

        var request = URLRequest(url: URL(string: "https://example.com/feed.xml")!)
        PodcastUserAgent.identify(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), PodcastUserAgent.value)
    }
}
