import XCTest
import AutohopCore
@testable import AutohopTV

// AI CONTEXT — Regression coverage for the lightweight RSS-description reader.
// The tvOS description sheet must preserve useful paragraph/list structure and
// decode entities without introducing WebKit, network work, or publisher HTML
// into SwiftUI Text. Failures here make show notes unreadable on Apple TV.
final class TVEpisodeDescriptionTextTests: XCTestCase {
    func testHTMLBecomesReadableStructuredText() {
        let source = "<p>First &amp; second</p><ul><li>Alpha</li><li>Beta</li></ul>"

        XCTAssertEqual(
            TVEpisodeDescriptionText.plainText(from: source),
            "First & second\n\n• Alpha\n\n• Beta"
        )
    }

    func testNumericEntitiesAreDecoded() {
        XCTAssertEqual(
            TVEpisodeDescriptionText.plainText(from: "Episode &#35;12 &#x2014; News"),
            "Episode #12 — News"
        )
    }

    func testPublisherNamedAndDoubleEscapedEntitiesAreDecoded() {
        XCTAssertEqual(
            TVEpisodeDescriptionText.plainText(
                from: "Billy&amp;rsquo;s Joke &ndash; JB&lsquo;s pick"
            ),
            "Billy’s Joke – JB‘s pick"
        )
    }

    func testTitleCopiedIntoDescriptionIsNotMeaningfulShowNotes() {
        var episode = Episode(
            subscriptionID: UUID(),
            guid: "description-title-fallback",
            title: "The Daily Update",
            audioURL: URL(string: "https://example.com/episode.mp3")!
        )
        episode.description = "<p>The Daily Update</p>"

        XCTAssertFalse(TVEpisodeDescriptionText.hasMeaningfulDescription(episode))
        episode.description = "<p>Today we explain the latest developments.</p>"
        XCTAssertTrue(TVEpisodeDescriptionText.hasMeaningfulDescription(episode))
    }

    func testMissingDescriptionProducesEmptyText() {
        XCTAssertEqual(TVEpisodeDescriptionText.plainText(from: nil), "")
        XCTAssertEqual(TVEpisodeDescriptionText.plainText(from: ""), "")
    }
}
