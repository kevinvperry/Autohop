// AI CONTEXT — Tests/PodcastSearchTests.swift
// Regression contract for Phase 1 Discover Search. Apple Search requests must
// always carry the selected storefront and shows/episodes must remain separate
// entities; otherwise Apple silently falls back to US ranking or returns one
// flat result type.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class PodcastSearchTests: XCTestCase {
    func testShowRequestUsesSelectedStorefrontAndShowEntity() throws {
        let url = PodcastSearchRequest.url(
            query: "news daily",
            countryCode: "AU",
            entity: "podcast",
            limit: 20
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(values["term"], "news daily")
        XCTAssertEqual(values["country"], "au")
        XCTAssertEqual(values["media"], "podcast")
        XCTAssertEqual(values["entity"], "podcast")
        XCTAssertEqual(values["limit"], "20")
    }

    func testEpisodeRequestCannotCollapseIntoShowRequest() throws {
        let url = PodcastSearchRequest.url(
            query: "climate",
            countryCode: "gb",
            entity: "podcastEpisode",
            limit: 25
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(values["country"], "gb")
        XCTAssertEqual(values["entity"], "podcastEpisode")
    }

    func testInvalidStorefrontDoesNotReachApple() {
        let normalized = PodcastSearchStorefront.normalized("australia")
        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized.allSatisfy(\.isLetter))
    }

    func testEpisodeRankingPrefersAccuracyBeforeRecency() {
        let exactOlder = episode(id: 1, title: "Jimmy Carr", daysAgo: 20)
        let weakNewer = episode(id: 2, title: "A comedy roundtable", show: "Comedy Weekly", daysAgo: 0)

        let ordered = PodcastEpisodeSearchRanking.ordered([weakNewer, exactOlder], query: "Jimmy Carr")

        XCTAssertEqual(ordered.map(\.id), [1, 2])
    }

    func testEpisodeRankingUsesNewestDateInsideSameAccuracyTier() {
        let older = episode(id: 1, title: "Jimmy Carr interview from London", daysAgo: 20)
        let newer = episode(id: 2, title: "Jimmy Carr interview at home", daysAgo: 1)

        let ordered = PodcastEpisodeSearchRanking.ordered([older, newer], query: "Jimmy Carr")

        XCTAssertEqual(ordered.map(\.id), [2, 1])
    }

    func testMyLibrarySearchExcludesBrowsePreviewsAndFindsLocalEpisodes() {
        var subscribed = Subscription(
            feedURL: URL(string: "https://example.com/subscribed.xml")!,
            title: "The Comedy Hour",
            author: "Example Network",
            priorityRank: 1
        )
        var episode = Episode(
            subscriptionID: subscribed.id,
            guid: "jimmy-carr",
            title: "Jimmy Carr joins the panel",
            audioURL: URL(string: "https://example.com/episode.mp3")!
        )
        episode.publishedAt = Date()
        subscribed.episodes = [episode]

        var preview = Subscription(
            feedURL: URL(string: "https://example.com/preview.xml")!,
            title: "Jimmy Carr Preview",
            author: "Preview Network",
            priorityRank: 2
        )
        preview.browseDate = Date()

        let results = PodcastLibrarySearch.search([subscribed, preview], query: "Jimmy Carr")

        XCTAssertTrue(results.shows.isEmpty)
        XCTAssertEqual(results.episodes.map(\.id), [episode.id])
    }

    func testCreatorGroupingUsesExactCleanAuthorMetadata() {
        let validA = show(id: 1, title: "Show One", author: "Example Studios")
        let validB = show(id: 2, title: "Show Two", author: " example studios ")
        let email = show(id: 3, title: "Show Three", author: "editor@example.com")
        let unknown = show(id: 4, title: "Show Four", author: "Unknown")

        let groups = PodcastCreatorGrouping.groups(from: [validA, validB, email, unknown], query: "Example")

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Example Studios")
        XCTAssertEqual(groups.first?.shows.count, 2)
    }

    func testEpisodeReconciliationPrefersRSSGUID() {
        var subscription = Subscription(
            feedURL: URL(string: "https://example.com/feed.xml")!,
            title: "Example",
            priorityRank: 1
        )
        let wrongTitleMatch = Episode(
            subscriptionID: subscription.id,
            guid: "wrong-guid",
            title: "Catalog title",
            audioURL: URL(string: "https://example.com/one.mp3")!
        )
        let guidMatch = Episode(
            subscriptionID: subscription.id,
            guid: "rss-guid-123",
            title: "Publisher changed this title",
            audioURL: URL(string: "https://example.com/two.mp3")!
        )
        subscription.episodes = [wrongTitleMatch, guidMatch]
        let result = PodcastEpisodeSearchResult(
            id: 1,
            podcastID: 2,
            title: "Catalog title",
            podcastTitle: "Example",
            publisher: "Publisher",
            feedURL: subscription.feedURL,
            artworkURL: nil,
            releaseDate: nil,
            duration: nil,
            genre: "",
            episodeGUID: "rss-guid-123"
        )

        XCTAssertEqual(PodcastEpisodeReconciliation.matchingEpisode(result: result, in: subscription)?.id, guidMatch.id)
    }

    func testEpisodeReconciliationRejectsFuzzyTitle() {
        var subscription = Subscription(
            feedURL: URL(string: "https://example.com/feed.xml")!,
            title: "Example",
            priorityRank: 1
        )
        subscription.episodes = [Episode(
            subscriptionID: subscription.id,
            guid: "one",
            title: "Jimmy Carr extended interview",
            audioURL: URL(string: "https://example.com/one.mp3")!
        )]
        let result = PodcastEpisodeSearchResult(
            id: 1,
            podcastID: 2,
            title: "Jimmy Carr interview",
            podcastTitle: "Example",
            publisher: "Publisher",
            feedURL: subscription.feedURL,
            artworkURL: nil,
            releaseDate: nil,
            duration: nil,
            genre: ""
        )

        XCTAssertNil(PodcastEpisodeReconciliation.matchingEpisode(result: result, in: subscription))
    }

    private func episode(
        id: Int,
        title: String,
        show: String = "Example Show",
        daysAgo: Int
    ) -> PodcastEpisodeSearchResult {
        PodcastEpisodeSearchResult(
            id: id,
            podcastID: 100,
            title: title,
            podcastTitle: show,
            publisher: "Example Publisher",
            feedURL: URL(string: "https://example.com/feed.xml")!,
            artworkURL: nil,
            releaseDate: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()),
            duration: 1_800,
            genre: "Comedy"
        )
    }

    private func show(id: Int, title: String, author: String) -> PodcastSearchResult {
        PodcastSearchResult(
            id: id,
            title: title,
            author: author,
            feedURL: URL(string: "https://example.com/\(id).xml")!,
            artworkURL: nil,
            episodeCount: 1,
            genre: "Comedy"
        )
    }
}
