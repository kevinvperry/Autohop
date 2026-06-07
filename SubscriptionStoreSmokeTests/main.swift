import Foundation
import AutohopCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("autohop-subscription-store-smoke-\(UUID().uuidString).json")

let feedURL = URL(string: "https://example.com/abc.xml")!
let audioURL = URL(string: "https://example.com/audio.aac")!
let parsedFeed = ParsedFeed(
    title: "774 ABC Melbourne Breakfast",
    author: "774 ABC Radio Melbourne",
    artworkURL: nil,
    latestEpisode: ParsedEpisode(
        guid: "abc-latest",
        title: "Breakfast - Friday",
        description: nil,
        subtitle: nil,
        author: nil,
        publishedAt: nil,
        durationSeconds: 100,
        audioURL: audioURL,
        artworkURL: nil,
        fileSizeBytes: nil,
        isExplicit: nil,
        chapters: [
            ParsedChapter(position: 1, title: "News", startSeconds: 0, durationSeconds: nil, source: .pscChapters)
        ],
        externalChaptersURL: nil
    )
)

let store = await SubscriptionStore(fileURL: fileURL)
let saved = try await store.add(parsedFeed: parsedFeed, feedURL: feedURL)
let savedCount = await store.subscriptions.count
require(savedCount == 1, "Expected one saved subscription")

do {
    _ = try await store.add(parsedFeed: parsedFeed, feedURL: feedURL)
    fatalError("Expected duplicate feed error")
} catch {
    // Expected.
}

await store.toggleChapter(subscriptionID: saved.id, position: 1)
let reloaded = await SubscriptionStore(fileURL: fileURL)
let subscription = await reloaded.subscription(id: saved.id)

require(subscription?.title == "774 ABC Melbourne Breakfast", "Expected persisted title")
require(subscription?.chapterFilter.skippedPositions == [1], "Expected persisted chapter filter")

let firstPublishedAt = Date(timeIntervalSince1970: 1_780_000_000)
let secondPublishedAt = Date(timeIntervalSince1970: 1_780_003_600)
let playedEpisodeID = await reloaded.subscription(id: saved.id)?.episodes.first?.id
require(playedEpisodeID != nil, "Expected an episode to mark as played")

await reloaded.markEpisodePlayed(subscriptionID: saved.id, episodeID: playedEpisodeID!)

var refreshedPlayedEpisode = Episode(subscriptionID: saved.id, guid: "abc-latest", title: "Breakfast - Friday", audioURL: audioURL)
refreshedPlayedEpisode.publishedAt = firstPublishedAt
await reloaded.updateEpisodes(subscriptionID: saved.id, episodes: [refreshedPlayedEpisode])
let refreshedSubscription = await reloaded.subscription(id: saved.id)
require(refreshedSubscription?.episodes.first?.playedState == .played, "Expected remembered played episode to stay played after refresh")
require(refreshedSubscription?.episodes.first?.downloadState == .notDownloaded, "Expected played episode to stay not downloaded after refresh")

var sameTitleNewDateEpisode = Episode(subscriptionID: saved.id, guid: "abc-new-date", title: "Breakfast - Friday", audioURL: audioURL)
sameTitleNewDateEpisode.publishedAt = secondPublishedAt
await reloaded.updateEpisodes(subscriptionID: saved.id, episodes: [sameTitleNewDateEpisode])
let newDateSubscription = await reloaded.subscription(id: saved.id)
require(newDateSubscription?.episodes.first?.playedState == .unplayed, "Expected same title with a different date to be treated as a new episode")

try? FileManager.default.removeItem(at: fileURL)

print("SubscriptionStoreSmoke passed: save, duplicate detection, reload, chapter filter persistence, and played episode persistence")
