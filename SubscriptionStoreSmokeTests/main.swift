// AI CONTEXT — SubscriptionStoreSmokeTests/main.swift (SubscriptionStoreSmoke
// executable). CLI smoke test for SubscriptionStore add/merge/priority-rank/
// browse-subscription behaviour against a temp file; fatalErrors on failure.
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
await store.flushPendingSaves()
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

// ── FeedRefreshScheduling: sparse feeds (hourly news bulletins) ──────────────
// A feed exposing a single item has no derivable cadence. It must poll at the
// Release Radar cadence from the last fetch, not stall on the 6 h default.
let now = Date(timeIntervalSince1970: 1_780_100_000)
let radar: TimeInterval = 5 * 60

let sparseStats = RefreshStats(
    lastFetchedAt: now.addingTimeInterval(-10 * 60),
    lastNewEpisodeAt: now.addingTimeInterval(-60 * 60),
    consecutiveEmptyFetches: 0
)
let sparseDue = FeedRefreshScheduling.nextDueAt(
    latestPublishedAt: now.addingTimeInterval(-60 * 60),
    publishDates: [now.addingTimeInterval(-60 * 60)],
    stats: sparseStats,
    minRecheckInterval: radar,
    now: now
)
require(
    sparseDue == sparseStats.lastFetchedAt!.addingTimeInterval(radar),
    "Expected single-item feed to be due one radar interval after last fetch"
)
require(sparseDue <= now, "Expected single-item feed fetched 10 min ago to be due now")

// Hiatus decay still applies to sparse feeds so dormant ones back off.
var dormantStats = sparseStats
dormantStats.consecutiveEmptyFetches = 8
let dormantDue = FeedRefreshScheduling.nextDueAt(
    latestPublishedAt: now.addingTimeInterval(-60 * 60),
    publishDates: [now.addingTimeInterval(-60 * 60)],
    stats: dormantStats,
    minRecheckInterval: radar,
    now: now
)
require(dormantDue > sparseDue, "Expected empty fetches to decay the recheck cadence")

// ── FeedRefreshScheduling: known cadence keeps the phase-locked window ───────
let hourlyDates = (1...5).map { now.addingTimeInterval(TimeInterval(-$0) * 3600) }
let hourlyStats = RefreshStats(lastFetchedAt: now.addingTimeInterval(-30 * 60))
let hourlyDue = FeedRefreshScheduling.nextDueAt(
    latestPublishedAt: hourlyDates[0],
    publishDates: hourlyDates,
    stats: hourlyStats,
    minRecheckInterval: radar,
    now: hourlyDates[0].addingTimeInterval(10 * 60)
)
require(
    hourlyDue == hourlyDates[0].addingTimeInterval(0.75 * 3600),
    "Expected hourly feed to open its check window at 45 min past the latest episode"
)

// ── RefreshStats: legacy JSON without recentPublishDates still decodes ───────
let legacyJSON = #"{"consecutiveEmptyFetches":2,"lastFetchedAt":760000000}"#.data(using: .utf8)!
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .secondsSince1970
let legacyStats = try legacyDecoder.decode(RefreshStats.self, from: legacyJSON)
require(legacyStats.consecutiveEmptyFetches == 2, "Expected legacy RefreshStats to decode")
require(legacyStats.recentPublishDates.isEmpty, "Expected missing recentPublishDates to default to empty")

// ── RefreshStats: publish-date history dedupes and caps ──────────────────────
var historyStats = RefreshStats()
for hour in 0..<15 {
    let published = now.addingTimeInterval(TimeInterval(hour) * 3600)
    historyStats.recordFetch(foundNewEpisode: true, publishedAt: published, at: published)
    historyStats.recordFetch(foundNewEpisode: true, publishedAt: published, at: published)
}
require(
    historyStats.recentPublishDates.count == RefreshStats.maxRecentPublishDates,
    "Expected publish-date history capped at \(RefreshStats.maxRecentPublishDates)"
)
require(
    historyStats.recentPublishDates == historyStats.recentPublishDates.sorted(),
    "Expected publish-date history kept in ascending order"
)
// With history alone, an hourly single-item feed now has a known cadence.
let derived = FeedRefreshScheduling.knownPublishInterval(publishDates: historyStats.recentPublishDates)
require(derived == 3600, "Expected hourly cadence derived from persisted publish history")

print("SubscriptionStoreSmoke passed: save, duplicate detection, reload, chapter filter persistence, played episode persistence, and feed refresh scheduling")
