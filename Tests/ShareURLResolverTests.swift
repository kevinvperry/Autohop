import XCTest
@testable import AutohopCore

final class ShareURLResolverTests: XCTestCase {
    func testEpisodePageWinsOverHTTPGuid() {
        let page = URL(string: "https://publisher.example/episodes/42")!
        let result = ShareURLResolver.episodeLink(
            episodePage: page,
            guid: "https://publisher.example/guid/42"
        )
        XCTAssertEqual(result, ResolvedShareLink(url: page, quality: .episodePage))
    }

    func testSafeHTTPGuidIsAProbableFallback() {
        let guid = "https://publisher.example/episodes/42"
        XCTAssertEqual(
            ShareURLResolver.episodeLink(episodePage: nil, guid: guid),
            ResolvedShareLink(url: URL(string: guid)!, quality: .probableEpisodePage)
        )
    }

    func testMissingPagesReturnNilInsteadOfAnEnclosure() {
        XCTAssertNil(ShareURLResolver.episodeLink(episodePage: nil, guid: "opaque-guid"))
    }

    func testRejectsCredentialsSensitiveQueriesAndPrivateNetworks() {
        let unsafe = [
            "https://user:secret@example.com/episode",
            "https://example.com/episode?token=secret",
            "http://127.0.0.1/episode",
            "http://10.0.0.2/episode",
            "http://192.168.1.2/episode",
            "http://169.254.1.2/episode",
            "file:///tmp/episode"
        ]
        for value in unsafe {
            XCTAssertNil(
                ShareURLResolver.validatedPublicWebURL(URL(string: value)!),
                "Expected rejection for \(value)"
            )
        }
    }

    func testAllowsOrdinaryPublisherQueryParameters() {
        let url = URL(string: "https://publisher.example/episode?id=42&utm_source=rss")!
        XCTAssertEqual(ShareURLResolver.validatedPublicWebURL(url), url)
    }
}
