import Foundation
import XCTest
@testable import Autohop

// AI CONTEXT — Stage 3/6 security characterization for widget navigation.
// These tests prove all documented routes, round-trip percent encoding for
// URL/GUID-style episode keys, and rejection of malformed or expansive input.

final class WidgetDeepLinkParserTests: XCTestCase {
    private let parser = WidgetDeepLinkParser()
    private let subscriptionID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000123"
    )!

    func testSimpleRoutesProduceTypedCommands() {
        XCTAssertEqual(
            parser.parse(WidgetDeepLink.player),
            .destination(.player)
        )
        XCTAssertEqual(
            parser.parse(WidgetDeepLink.upNext),
            .destination(.upNext)
        )
        XCTAssertEqual(
            parser.parse(WidgetDeepLink.discover),
            .destination(.discover)
        )
    }

    func testEpisodeIdentityRoundTripsReservedCharacters() throws {
        let identity = WidgetEpisodeIdentity(
            subscriptionID: subscriptionID,
            episodeKey: "guid:https://example.com/show/42?a=b&c=d"
        )
        let url = try XCTUnwrap(WidgetDeepLink.episode(identity))

        XCTAssertEqual(
            parser.parse(url),
            .destination(.episode(identity))
        )
    }

    func testRejectsUnknownMalformedAndCredentialedRoutes() {
        let rejected = [
            URL(string: "https://player")!,
            URL(string: "autohop://unknown")!,
            URL(string: "autohop://player/extra")!,
            URL(string: "autohop://user:password@player")!,
            URL(string: "autohop://episode/not-a-uuid/key")!,
            URL(string: "autohop://episode/\(subscriptionID.uuidString)")!
        ]

        for url in rejected {
            XCTAssertEqual(parser.parse(url), .rejected, "\(url)")
        }
    }

    func testRejectsOversizedEpisodeKey() {
        let url = URL(
            string: "autohop://episode/\(subscriptionID.uuidString)/"
                + String(repeating: "a", count: 2_049)
        )!

        XCTAssertEqual(parser.parse(url), .rejected)
    }
}
