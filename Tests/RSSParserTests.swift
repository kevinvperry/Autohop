import XCTest
@testable import Autohop

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
        XCTAssertEqual(episode.chapters[1].title, "Marker 01")
        XCTAssertEqual(episode.chapters[1].startSeconds, 1_008)
        XCTAssertEqual(episode.chapters[4].title, "Marker 04")
        XCTAssertEqual(episode.chapters[4].startSeconds, 4_718)
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
