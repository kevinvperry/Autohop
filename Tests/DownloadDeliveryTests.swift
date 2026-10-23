import XCTest
@testable import Autohop

final class DownloadDeliveryTests: XCTestCase {
    func testDirectRetainsCanonicalURL() throws {
        let source = URL(string: "https://podcast.example/episode.mp3?tracking=123")!
        XCTAssertEqual(try DownloadDelivery.direct.request(for: source).url, source)
    }

    func testRelayKeepsSourceAndCredentialOutOfRequestURL() throws {
        let source = URL(string: "https://podcast.example/episode.mp3?tracking=123")!
        let request = try DownloadDelivery.luxembourg(endpoint: URL(string: "https://relay.example")!, token: "test-token")
            .request(for: source)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/audio")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let encoded = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Autohop-Source"))
        XCTAssertEqual(Data(base64Encoded: encoded), Data(source.absoluteString.utf8))
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
    }

    func testRejectsUnsafeConfigurationAndCredentialedEnclosures() {
        for endpoint in ["http://relay.example", "https://user:pass@relay.example", "https://relay.example?key=value"] {
            XCTAssertThrowsError(try DownloadDelivery.luxembourg(endpoint: URL(string: endpoint)!, token: "secret")
                .request(for: URL(string: "https://podcast.example/a.mp3")!))
        }
        XCTAssertThrowsError(try DownloadDelivery.luxembourg(endpoint: URL(string: "https://relay.example")!, token: "secret")
            .request(for: URL(string: "https://user:password@podcast.example/a.mp3")!))
    }

    func testDoesNotAcceptRedirectsOrUnmarkedResponsesAsRelayDownloads() {
        for status in [200, 302, 503] {
            let response = HTTPURLResponse(url: URL(string: "https://relay.example/v1/audio")!, statusCode: status,
                httpVersion: nil, headerFields: status == 200 ? [:] : ["X-Autohop-Relay": "lu-v1"])!
            XCTAssertFalse(DownloadDelivery.validateRelayResponse(response))
        }
    }

    func testRelayRequiresSameFinalURLAndIdentityHeader() {
        let requestURL = URL(string: "https://relay.example/v1/audio")!
        let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Autohop-Relay": "lu-v1"])!
        XCTAssertTrue(DownloadDelivery.validateRelayResponse(response, requestURL: requestURL))
        XCTAssertFalse(DownloadDelivery.validateRelayResponse(response, requestURL: URL(string: "https://other.example/v1/audio")))
        XCTAssertFalse(DownloadDelivery.validateRelayResponse(response))
    }

    func testOldSettingsRemainOptedOutAndNewSettingsRoundTrip() throws {
        var settings = AppSettings.default
        let original = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "adReduction")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.adReduction.enabled)
        XCTAssertTrue(old.adReduction.publicSubscriptionIDs.isEmpty)
        settings.adReduction.enabled = true
        settings.adReduction.endpoint = "https://relay.example"
        settings.adReduction.publicSubscriptionIDs = [UUID()]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testReceiptIsBoundToCompletedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: DownloadDeliveryReceipt.url(for: file)) }
        try DownloadDeliveryReceipt.write(for: file, relay: true)
        XCTAssertEqual(DownloadDeliveryReceipt.read(for: file)?.method, "luxembourg")
        XCTAssertNil(DownloadDeliveryReceipt.read(for: file.appendingPathExtension("other")))
    }
}
