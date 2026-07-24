// AI CONTEXT — Tests/FeedRefreshMergeTests.swift. Guards the ParsedFeed
// overload of SubscriptionStore.updateEpisodes used by the tvOS feed refresh
// (so "Latest" tracks the phone): a re-fetched feed must add new episodes,
// advance `latestEpisode`, and PRESERVE local played/download state by guid.
// It also verifies the unchanged-feed fast path: identical refresh content must
// not emit a broad store invalidation or schedule redundant persistence work.
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

    func testIdenticalRefreshDoesNotPublishBroadStoreChange() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let feedURL = URL(string: "https://f.com/feed")!
        let published = Date(timeIntervalSince1970: 2_000_000)
        let feed = ParsedFeed(
            title: "Show", author: "Presenter", artworkURL: nil,
            latestEpisode: nil,
            episodes: [parsedEpisode(guid: "ep-one", title: "Episode", published: published)]
        )
        _ = store.materialize(parsedFeed: feed, feedURL: feedURL, subscriptionID: id)
        await store.flushPendingSaves()

        var broadChangeCount = 0
        let cancellable = store.objectWillChange.sink {
            broadChangeCount += 1
        }
        defer { cancellable.cancel() }

        store.beginChangeNotificationCoalescing()
        store.updateEpisodes(subscriptionID: id, from: feed)
        store.updateAuthor(subscriptionID: id, author: "Presenter")
        store.endChangeNotificationCoalescing()

        XCTAssertEqual(broadChangeCount, 0,
                       "An unchanged feed must not invalidate every store observer")
    }

    func testRefreshPreservesDownloadedAndLastPlayedTimestampsByGUID() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let feedURL = URL(string: "https://f.com/feed")!
        let published = Date(timeIntervalSince1970: 2_000_000)
        let feed = ParsedFeed(
            title: "Hourly Bulletin", author: nil, artworkURL: nil,
            latestEpisode: nil,
            episodes: [parsedEpisode(guid: "stable-guid", title: "Bulletin", published: published)]
        )
        _ = store.materialize(parsedFeed: feed, feedURL: feedURL, subscriptionID: id)
        let episodeID = try XCTUnwrap(store.subscription(id: id)?.episodes.first?.id)
        store.markEpisodeDownloaded(
            subscriptionID: id,
            episodeID: episodeID,
            localFileURL: URL(fileURLWithPath: "/tmp/stable-guid.mp3")
        )
        store.markEpisodePlaying(subscriptionID: id, episodeID: episodeID)
        let beforeRefresh = try XCTUnwrap(store.subscription(id: id)?.episodes.first)
        let downloadedAt = try XCTUnwrap(beforeRefresh.downloadedAt)
        let lastPlayedAt = try XCTUnwrap(beforeRefresh.lastPlayedAt)

        // A Worker that returns a complete 200 response every few minutes
        // repeatedly takes this merge path even when the GUID is unchanged.
        store.updateEpisodes(subscriptionID: id, from: feed)

        let refreshed = try XCTUnwrap(store.subscription(id: id)?.episodes.first)
        XCTAssertEqual(refreshed.downloadState, .downloaded)
        XCTAssertEqual(refreshed.downloadedAt, downloadedAt)
        XCTAssertEqual(refreshed.lastPlayedAt, lastPlayedAt)
    }
}
