// AI CONTEXT — Tests/RSSParserTests.swift. XCTest unit tests for RSSParser
// against bundled XML fixtures. Runs in BOTH the SwiftPM `AutohopCoreTests`
// target (`swift test`) and the Xcode test bundle — so it imports the shared
// AutohopCore library module (RSSParser, ParsedFeed, Episode, Chapter all live
// there), not the app module.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore   // `swift test` (SwiftPM AutohopCoreTests target)
#else
@testable import Autohop       // Xcode test bundle (app module)
#endif

final class RSSParserTests: XCTestCase {
    func testParsesABCBreakfastFixture() throws {
        let data = try fixtureData(named: "ABCBreakfastSampleFeed", extension: "xml")

        let feed = try RSSParser().parse(data: data)
        let episode = try XCTUnwrap(feed.latestEpisode)

        XCTAssertEqual(feed.title, "774 ABC Melbourne Breakfast")
        XCTAssertEqual(feed.author, "774 ABC Radio Melbourne")
        XCTAssertEqual(feed.artworkURL?.absoluteString, "https://tvblackbox.com.au/wp-content/uploads/2025/01/Sharnelle-and-Bob.jpg")

        XCTAssertEqual(episode.guid, "abc-breakfast-2026-05-29")
        XCTAssertEqual(episode.title, "Breakfast - Friday, 29th May 2026")
        XCTAssertEqual(episode.subtitle, "Breakfast with Sharnelle Vella and Bob Murphy")
        XCTAssertEqual(episode.author, "774 ABC Radio Melbourne")
        XCTAssertEqual(episode.durationSeconds, 8_700)
        XCTAssertEqual(episode.audioURL?.absoluteString, "https://example.com/audio/abc-breakfast-2026-05-29.aac")
        XCTAssertEqual(episode.fileSizeBytes, 210_763_776)
        XCTAssertEqual(episode.externalChaptersURL?.absoluteString, "https://example.com/chapters/abc-breakfast-2026-05-29.json")

        XCTAssertEqual(episode.chapters.count, 5)
        XCTAssertEqual(episode.chapters[0].position, 1)
        XCTAssertEqual(episode.chapters[0].title, "Welcome To Country")
        XCTAssertEqual(episode.chapters[0].startSeconds, 0)
        XCTAssertEqual(episode.chapters[0].source, .pscChapters)
        XCTAssertEqual(episode.chapters[1].position, 2)
        XCTAssertEqual(episode.chapters[1].title, "774 ABC Breakfast 5:35am-6:00am")
        XCTAssertEqual(episode.chapters[1].startSeconds, 50)
        XCTAssertEqual(episode.chapters[4].position, 5)
        XCTAssertEqual(episode.chapters[4].title, "6:30AM News")
        XCTAssertEqual(episode.chapters[4].startSeconds, 3_300)
    }

    func testParsesFeedWithImageEnclosureAndBareAmpersands() throws {
        let data = try fixtureData(named: "ThreeAWMelbourneNewsSampleFeed", extension: "xml")

        let feed = try RSSParser().parse(data: data)
        let episode = try XCTUnwrap(feed.latestEpisode)

        XCTAssertEqual(feed.title, "3AW Melbourne News")
        XCTAssertEqual(feed.artworkURL?.absoluteString, "https://www.omnycontent.com/image.jpg?t=1673225975&size=Large")
        XCTAssertEqual(episode.title, "3AW Melbourne News 6:00pm - Sunday, 31st May 2026")
        XCTAssertEqual(episode.durationSeconds, 223)
        XCTAssertEqual(episode.audioURL?.absoluteString, "https://pdst.fm/e/traffic.omny.fm/audio.mp3?utm_source=Podcast&in_playlist=e2540967")
        XCTAssertEqual(episode.artworkURL?.absoluteString, "https://www.omnycontent.com/image.jpg?t=1673225975&size=Large")
        XCTAssertEqual(episode.fileSizeBytes, 3_614_728)
    }

    func testParsesVideoPodcastEnclosure() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Windows Weekly</title>
            <item>
              <guid>ww-985</guid>
              <title>WW 985: Putting the Mental in Experimental</title>
              <pubDate>Mon, 1 Jun 2026 12:00:00 GMT</pubDate>
              <enclosure url="https://cdn.twit.tv/members/ww/ww_985/ww_985_h264m_861529-707adfc3.mp4" length="2510468263" type="video/mp4"/>
              <itunes:duration xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">02:22:00</itunes:duration>
            </item>
          </channel>
        </rss>
        """

        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)

        XCTAssertEqual(episode.audioURL?.absoluteString, "https://cdn.twit.tv/members/ww/ww_985/ww_985_h264m_861529-707adfc3.mp4")
        XCTAssertEqual(episode.mediaKind, .video)
        XCTAssertEqual(episode.fileSizeBytes, 2_510_468_263)
    }

    func testParsesThreeAWBreakfastInlinePSCChapters() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss
          xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
          xmlns:psc="http://podlove.org/simple-chapters"
          version="2.0">
          <channel>
            <title>3AW Breakfast with Ross and Russel</title>
            <item>
              <title>3AW Breakfast with Ross Stevenson &amp; Russel Howcroft - Fri 22nd May, 2026 - Highlights</title>
              <guid isPermaLink="false">6b1533d9-8c7e-492e-b7e4-b4510174464d</guid>
              <pubDate>Thu, 21 May 2026 22:40:48 +0000</pubDate>
              <itunes:duration>5576</itunes:duration>
              <enclosure url="https://pdst.fm/e/traffic.omny.fm/audio.mp3" length="89272550" type="audio/mpeg"/>
              <psc:chapters>
                <psc:chapter start="00:00:00" title="3AW Breakfast with Ross Stevenson &amp; Russel Howcroft - Fri 22nd May, 2026 - Highlights"/>
                <psc:chapter start="00:16:48" title="Marker 01"/>
                <psc:chapter start="00:34:34" title="Marker 02"/>
                <psc:chapter start="00:53:00" title="Marker 03"/>
                <psc:chapter start="01:18:38" title="Marker 04"/>
              </psc:chapters>
            </item>
          </channel>
        </rss>
        """

        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)

        XCTAssertEqual(feed.title, "3AW Breakfast with Ross and Russel")
        XCTAssertEqual(episode.chapters.count, 5)
        // Single-encoded `&amp;` in a chapter title must decode to `&`.
        XCTAssertEqual(
            episode.chapters[0].title,
            "3AW Breakfast with Ross Stevenson & Russel Howcroft - Fri 22nd May, 2026 - Highlights"
        )
        // The episode title carrying the same entity decodes too.
        XCTAssertEqual(
            episode.title,
            "3AW Breakfast with Ross Stevenson & Russel Howcroft - Fri 22nd May, 2026 - Highlights"
        )
        XCTAssertEqual(episode.chapters[1].title, "Marker 01")
        XCTAssertEqual(episode.chapters[1].startSeconds, 1_008)
        XCTAssertEqual(episode.chapters[4].title, "Marker 04")
        XCTAssertEqual(episode.chapters[4].startSeconds, 4_718)
    }

    func testParsesEpisodeWebLinkForSharing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Some Show</title>
            <link>https://example.com</link>
            <item>
              <guid isPermaLink="false">abc-123</guid>
              <title>An Episode</title>
              <link>https://example.com/episodes/an-episode</link>
              <enclosure url="https://cdn.example.com/an-episode.mp3" length="100" type="audio/mpeg"/>
            </item>
          </channel>
        </rss>
        """

        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)

        // The item-level <link> is captured (not the channel <link>).
        XCTAssertEqual(episode.episodeLink?.absoluteString, "https://example.com/episodes/an-episode")
        XCTAssertEqual(episode.audioURL?.absoluteString, "https://cdn.example.com/an-episode.mp3")
    }

    func testEpisodeWebLinkAbsentWhenItemHasNoLink() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Some Show</title>
            <link>https://example.com</link>
            <item>
              <guid isPermaLink="false">abc-123</guid>
              <title>An Episode</title>
              <enclosure url="https://cdn.example.com/an-episode.mp3" length="100" type="audio/mpeg"/>
            </item>
          </channel>
        </rss>
        """

        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)

        // Channel <link> must NOT leak into the episode's link.
        XCTAssertNil(episode.episodeLink)
    }

    func testDecodesDoubleEncodedEntitiesInTitle() throws {
        // Real-world Omny/Megaphone feeds double-encode: source `&amp;amp;` arrives
        // from XMLParser as a literal `&amp;`. The parser must repair it to `&`.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>KIIS &amp;amp; Co</title>
            <item>
              <guid isPermaLink="false">abc-123</guid>
              <title>Lauren's hit &amp;amp; run &amp;#8212; bonus</title>
              <enclosure url="https://e.com/a.mp3" length="1" type="audio/mpeg"/>
            </item>
          </channel>
        </rss>
        """
        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)

        XCTAssertEqual(episode.title, "Lauren's hit & run — bonus")
        XCTAssertEqual(feed.title, "KIIS & Co")
        // guid must NOT be entity-decoded (identity field).
        XCTAssertEqual(episode.guid, "abc-123")
    }

    func testDecodesDoubleEncodedEntitiesInChapterTitle() throws {
        // Chapter titles are XML attributes, so they follow the same single-layer
        // XMLParser decode + double-encode repair path as element text. A source
        // `&amp;amp;` arrives as a literal `&amp;` and must be repaired to `&`.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss
          xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
          xmlns:psc="http://podlove.org/simple-chapters"
          version="2.0">
          <channel>
            <title>Show</title>
            <item>
              <title>Ep</title>
              <guid isPermaLink="false">abc-123</guid>
              <enclosure url="https://e.com/a.mp3" length="1" type="audio/mpeg"/>
              <psc:chapters>
                <psc:chapter start="00:00:00" title="Ross &amp;amp; Russel"/>
                <psc:chapter start="00:01:00" title="Tom &amp; Jerry"/>
              </psc:chapters>
            </item>
          </channel>
        </rss>
        """
        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)

        XCTAssertEqual(episode.chapters.count, 2)
        XCTAssertEqual(episode.chapters[0].title, "Ross & Russel")
        XCTAssertEqual(episode.chapters[1].title, "Tom & Jerry")
    }

    func testLeavesCorrectlyEncodedTitleUntouched() throws {
        // Single-encoded `&amp;` is fully decoded by XMLParser to `&`; the repair
        // pass must be a no-op (no entities remain) and not corrupt anything.
        let xml = "<rss version=\"2.0\"><channel><title>S</title><item><title>Tom &amp; Jerry</title><enclosure url=\"https://e.com/a.mp3\" length=\"1\" type=\"audio/mpeg\"/></item></channel></rss>"
        let feed = try RSSParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(try XCTUnwrap(feed.latestEpisode).title, "Tom & Jerry")
    }

    func testMixedAmpersandRepairAndNoQuadraticBlowup() throws {
        // A bare `&` in a URL query, a valid named entity, and a valid numeric entity must all be
        // handled: bare ones escaped (then decoded by XMLParser to `&`), valid ones preserved.
        let title = "A & B &amp; C &#8212; D"
        let xml = "<rss version=\"2.0\"><channel><title>S</title><item><title>\(title)</title>"
            + "<enclosure url=\"https://e.com/a.mp3?x=1&y=2\" length=\"1\" type=\"audio/mpeg\"/></item></channel></rss>"
        let feed = try RSSParser().parse(data: Data(xml.utf8))
        let episode = try XCTUnwrap(feed.latestEpisode)
        XCTAssertEqual(episode.title, "A & B & C — D")
        XCTAssertEqual(episode.audioURL?.absoluteString, "https://e.com/a.mp3?x=1&y=2")

        // Performance: the ampersand-repair prepass must be linear. The old removeSubrange-per-
        // ampersand pass was O(n²) and took ~25 min on this input. Test the prepass directly (not
        // via full parse) so we measure only the repair, not XMLParser's own large-node handling.
        let many = String(repeating: "Tom & Jerry & friends ", count: 60_000) // ~120k bare ampersands
        let bigData = Data(many.utf8)
        let start = Date()
        let repaired = RSSParser.dataByEscapingBareAmpersands(in: bigData)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "Ampersand repair should be linear, not O(n²)")
        // Sanity: every bare ampersand was escaped.
        XCTAssertFalse(String(data: repaired, encoding: .utf8)!.contains(" & "))
    }

    private func fixtureData(named name: String, extension fileExtension: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}
