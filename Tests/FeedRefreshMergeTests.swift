// AI CONTEXT — Tests/FeedRefreshMergeTests.swift. Guards the ParsedFeed
// overload of SubscriptionStore.updateEpisodes used by the tvOS feed refresh
// (so "Latest" tracks the phone): a re-fetched feed must add new episodes,
// advance `latestEpisode`, and PRESERVE local played/download state by guid.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class FeedRefreshMergeTests: XCTestCase {

    private func parsedEpisode(guid: String, title: String, published: Date) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: title, description: nil, subtitle: nil, author: nil,
            publishedAt: published, durationSeconds: 1800,
            audioURL: URL(string: "https://e.com/\(guid).mp3"),
            artworkURL: nil, fileSizeBytes: nil, isExplicit: nil,
            chapters: [], externalChaptersURL: nil
        )
    }

    func testRefreshAddsNewEpisodesAdvancesLatestAndPreservesState() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let feedURL = URL(string: "https://f.com/feed")!
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)

        // Initial materialize with one (older) episode, which the user then plays.
        let initial = ParsedFeed(
            title: "Show", author: nil, artworkURL: nil, latestEpisode: nil,
            episodes: [parsedEpisode(guid: "ep-old", title: "Old", published: old)]
        )
        _ = store.materialize(parsedFeed: initial, feedURL: feedURL, subscriptionID: id)
        await store.flushPendingSaves()
        let oldEpisodeID = try XCTUnwrap(store.subscription(id: id)?.episodes.first { $0.guid == "ep-old" }?.id)
        store.markEpisodePlayed(subscriptionID: id, episodeID: oldEpisodeID)
        await store.flushPendingSaves()

        // Feed refresh delivers a newer episode on top of the existing one.
        let refreshed = ParsedFeed(
            title: "Show", author: nil, artworkURL: nil, latestEpisode: nil,
            episodes: [
                parsedEpisode(guid: "ep-new", title: "New", published: new),
                parsedEpisode(guid: "ep-old", title: "Old", published: old)
            ]
        )
        store.updateEpisodes(subscriptionID: id, from: refreshed)
        await store.flushPendingSaves()

        let sub = try XCTUnwrap(store.subscription(id: id))
        XCTAssertEqual(Set(sub.episodes.map(\.guid)), ["ep-new", "ep-old"], "New episode is merged in")
        XCTAssertEqual(sub.latestEpisode?.guid, "ep-new", "latestEpisode advances to the newest")
        XCTAssertEqual(sub.episodes.first { $0.guid == "ep-old" }?.playedState, .played,
                       "The refresh preserves local played state by guid")
    }
}
