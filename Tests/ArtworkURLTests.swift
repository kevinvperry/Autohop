// CATEGORY REGRESSIONS (2026-09-06): Also covers JSON null/malformed artwork
// templates, 600px resolution, primary-before-channel candidate ordering and
// deduplication, plus fallback Codable round trips and old cache compatibility.
// App-only coverage remains excluded from AUTOHOP_SPM builds.

// AI CONTEXT — Tests/ArtworkURLTests.swift. Guards ArtworkURL.upscaled — the
// best-effort mzstatic/iTunes art upscaler used by the tvOS artwork loader.
// The contract: upgrade recognized resizable URLs that are too small; leave
// everything else (self-hosted, unknown, already-large) untouched.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class ArtworkURLTests: XCTestCase {

    #if !AUTOHOP_SPM
    func testCategoryArtworkHandlesJSONNullAndMalformedTemplates() throws {
        let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            #"{"episodeArtwork":null,"icon":{"template":"https://example.com/show/{w}x{h}{c}.{f}"}}"#.utf8
        )) as? [String: Any])
        XCTAssertNil(CategoryEpisodeArtwork.url(from: item["episodeArtwork"]))
        XCTAssertEqual(CategoryEpisodeArtwork.url(from: item["icon"])?.absoluteString,
                       "https://example.com/show/600x600bb.jpg")
        for invalid: Any in [NSNull(), [:], ["template": ""],
                             ["template": "/relative.jpg"],
                             ["template": "https://example.com/{unknown}.jpg"]] {
            XCTAssertNil(CategoryEpisodeArtwork.url(from: invalid))
        }
    }

    func testChartEpisodeArtworkFallbackSurvivesCacheRoundTrip() throws {
        let primary = URL(string: "https://example.com/episode.jpg")!
        let fallback = URL(string: "https://example.com/show.jpg")!
        let episode = ChartEpisode(id: "1", rank: 1, title: "Episode", showName: "Show",
                                   artworkURL: primary, fallbackArtworkURL: fallback,
                                   releaseDateString: nil, collectionId: "2")
        let decoded = try JSONDecoder().decode(ChartEpisode.self, from: JSONEncoder().encode(episode))
        XCTAssertEqual(decoded, episode)
        let legacy = Data(#"{"id":"1","rank":1,"title":"Episode","showName":"Show"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChartEpisode.self, from: legacy).fallbackArtworkURL)
    }

    func testArtworkRequestTriesEpisodeBeforeChannelFallback() {
        let episodeURL = URL(string: "https://example.com/episode.png")!
        let channelURL = URL(string: "https://example.com/channel.jpg")!

        XCTAssertEqual(
            ArtworkImageRequest(primaryURL: episodeURL, fallbackURL: channelURL).candidateURLs,
            [episodeURL, channelURL]
        )
    }

    func testArtworkRequestUsesChannelWhenEpisodeURLIsMissingAndDeduplicatesMatches() {
        let channelURL = URL(string: "https://example.com/channel.jpg")!

        XCTAssertEqual(
            ArtworkImageRequest(primaryURL: nil, fallbackURL: channelURL).candidateURLs,
            [channelURL]
        )
        XCTAssertEqual(
            ArtworkImageRequest(primaryURL: channelURL, fallbackURL: channelURL).candidateURLs,
            [channelURL]
        )
    }
    #endif

    func testUpscalesSmallMzstaticURL() {
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/abc/def/300x300bb.jpg")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 1000)
        XCTAssertEqual(out?.absoluteString, "https://is1-ssl.mzstatic.com/image/thumb/abc/def/1000x1000bb.jpg")
    }

    func testPreservesSuffixlessAndOtherExtensions() {
        let url = URL(string: "https://cdn.example.com/art/64x64.png")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 600)
        XCTAssertEqual(out?.absoluteString, "https://cdn.example.com/art/600x600.png")
    }

    func testDoesNotShrinkAlreadyLargeArt() {
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/x/y/3000x3000bb.jpg")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 1000)
        XCTAssertEqual(out?.absoluteString, url?.absoluteString, "Never downscale a larger source")
    }

    func testLeavesNonResizableURLUnchanged() {
        let url = URL(string: "https://example.com/podcast/cover-art.jpg")
        XCTAssertEqual(ArtworkURL.upscaled(url, toMinimumPixels: 1000)?.absoluteString, url?.absoluteString)
    }

    func testNonImageExtensionUnchanged() {
        let url = URL(string: "https://example.com/a/300x300.mp3")
        XCTAssertEqual(ArtworkURL.upscaled(url, toMinimumPixels: 1000)?.absoluteString, url?.absoluteString)
    }

    func testNilAndPreservesQuery() {
        XCTAssertNil(ArtworkURL.upscaled(nil, toMinimumPixels: 1000))
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/x/y/200x200bb.jpg?v=2")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 800)
        XCTAssertEqual(out?.absoluteString, "https://is1-ssl.mzstatic.com/image/thumb/x/y/800x800bb.jpg?v=2")
    }
}
