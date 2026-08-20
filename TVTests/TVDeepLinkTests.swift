import XCTest
@testable import AutohopTV

// AI CONTEXT — Security regression matrix for identity-only tvOS Top Shelf
// routes. Unknown/malformed/over-specified URLs must fail closed.

final class TVDeepLinkTests: XCTestCase {
    func testValidDisplayAndPlayRoutesRoundTripEncodedIdentity() throws {
        let subscriptionID = UUID()
        for action in ["episode", "play"] {
            var components = URLComponents()
            components.scheme = "autohop"
            components.host = "tv"
            components.path = "/\(action)"
            components.queryItems = [
                .init(name: "subscriptionID", value: subscriptionID.uuidString),
                .init(name: "episodeKey", value: "feed|guid:episode / one?yes")
            ]
            let route = try XCTUnwrap(TVDeepLinkParser.parse(try XCTUnwrap(components.url)))
            XCTAssertEqual(route.action.rawValue, action)
            XCTAssertEqual(route.subscriptionID, subscriptionID)
            XCTAssertEqual(route.episodeKey, "feed|guid:episode / one?yes")
        }
    }

    func testMalformedAndOverSpecifiedRoutesAreRejected() {
        let id = UUID().uuidString
        let rejected = [
            "https://tv/play?subscriptionID=\(id)&episodeKey=x",
            "autohop://other/play?subscriptionID=\(id)&episodeKey=x",
            "autohop://tv/delete?subscriptionID=\(id)&episodeKey=x",
            "autohop://tv/play?subscriptionID=nope&episodeKey=x",
            "autohop://tv/play?subscriptionID=\(id)",
            "autohop://tv/play?subscriptionID=\(id)&episodeKey=x&streamURL=https://evil.invalid/a.mp3",
            "autohop://tv/play?subscriptionID=\(id)&subscriptionID=\(id)&episodeKey=x"
        ]
        for value in rejected {
            XCTAssertNil(TVDeepLinkParser.parse(URL(string: value)!))
        }
    }
}

