// AI CONTEXT — SubscriptionStoreSmokeTests/main.swift (SubscriptionStoreSmoke
// executable). CLI smoke test for SubscriptionStore add/merge/priority-rank/
// browse-subscription behaviour against a temp file; fatalErrors on failure.
// Also carries the focused Release Radar regression checks that do not need the
// full app/dependency graph: RefreshStats legacy decoding and history caps,
// release-observation persistence, learned schedule classification (hourly,
// burst, weekday, weekly, unreliable dates), learned-window due prediction,
// missed-release urgency expiry, learning/random cadence decay, and
// FeedRefreshPrioritizer ordering for missed, active, learning, ranked, stale,
// and random due feeds, plus pure refresh-budget selection.
import Foundation
import Combine
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
require(subscription?.refreshStats.releaseObservations.count == 1, "Expected initial release observation to persist")
require(subscription?.refreshStats.releaseObservations.first?.dateQuality == .missing, "Expected missing publish date to be recorded")

var refreshStatsNotificationCount = 0
let refreshStatsNotificationToken = await reloaded.objectWillChange.sink {
    refreshStatsNotificationCount += 1
}
let refreshStatsOnlyDate = Date(timeIntervalSince1970: 1_780_050_000)
var refreshStatsOnly = subscription!.refreshStats
refreshStatsOnly.recordFetch(foundNewEpisode: false, at: refreshStatsOnlyDate)
await reloaded.updateRefreshStats(subscriptionID: saved.id, stats: refreshStatsOnly)
require(refreshStatsNotificationCount == 0, "Expected refresh-stat-only updates to persist quietly")
await reloaded.flushPendingSaves()
let refreshStatsReloaded = await SubscriptionStore(fileURL: fileURL)
let persistedQuietStats = await refreshStatsReloaded.subscription(id: saved.id)?.refreshStats
require(
    persistedQuietStats?.lastFetchedAt == refreshStatsOnlyDate,
    "Expected quiet refresh stats to persist"
)
await reloaded.updateTitle(subscriptionID: saved.id, title: "774 ABC Melbourne Breakfast Updated")
require(refreshStatsNotificationCount == 1, "Expected visible subscription edits to notify observers")
refreshStatsNotificationToken.cancel()

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
require(legacyStats.releaseObservations.isEmpty, "Expected missing releaseObservations to default to empty")

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

// ── Release observation history: longer, per-episode, capped ─────────────────
var observationStats = RefreshStats()
var existingEpisode = Episode(subscriptionID: saved.id, guid: "existing-observation", title: "Already Known", audioURL: audioURL)
existingEpisode.publishedAt = now
let existingKey = RefreshStats.releaseObservationKey(for: existingEpisode)
let existingRecorded = observationStats.recordEpisodeObservations(
    [existingEpisode],
    previouslyKnownEpisodeKeys: [existingKey],
    at: now
)
require(existingRecorded == 1, "Expected existing episode to be recorded once")
require(observationStats.releaseObservations.first?.wasNewWhenFirstSeen == false, "Expected known episode to be marked as not new when first seen")

for offset in 0..<(RefreshStats.maxReleaseObservations + 25) {
    var episode = Episode(
        subscriptionID: saved.id,
        guid: "observation-\(offset)",
        title: "Observation \(offset)",
        audioURL: URL(string: "https://example.com/audio-\(offset).aac")!
    )
    episode.publishedAt = now.addingTimeInterval(TimeInterval(offset) * 3600)
    observationStats.recordEpisodeObservations(
        [episode],
        previouslyKnownEpisodeKeys: [],
        at: now.addingTimeInterval(TimeInterval(offset) * 3600)
    )
}
require(
    observationStats.releaseObservations.count == RefreshStats.maxReleaseObservations,
    "Expected release observations capped at \(RefreshStats.maxReleaseObservations)"
)
require(
    observationStats.releaseObservations == observationStats.releaseObservations.sorted { ($0.publishedAt ?? $0.firstSeenAt) < ($1.publishedAt ?? $1.firstSeenAt) },
    "Expected release observations kept in chronological order"
)

// ── FeedScheduleProfiler: learned schedule classes ───────────────────────────
var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    DateComponents(
        calendar: utcCalendar,
        timeZone: utcCalendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    ).date!
}

func observation(_ guid: String, publishedAt: Date?) -> FeedReleaseObservation {
    FeedReleaseObservation(
        episodeKey: "guid:\(guid)",
        guid: guid,
        title: guid,
        audioURL: audioURL,
        publishedAt: publishedAt,
        firstSeenAt: publishedAt ?? now,
        lastSeenAt: publishedAt ?? now,
        dateQuality: publishedAt == nil ? .missing : .plausible,
        wasNewWhenFirstSeen: true
    )
}

let hourlyObservations = (0..<8).map {
    observation("hourly-\($0)", publishedAt: makeDate(2026, 1, 5, $0, 15))
}
let hourlyProfile = FeedScheduleProfiler.profile(from: hourlyObservations, calendar: utcCalendar)
require(hourlyProfile.kind == .hourly, "Expected hourly :15 feed profile")
require(hourlyProfile.typicalMinuteOfHour == 15, "Expected hourly profile to learn minute 15")

let burstObservations = (0..<4).flatMap { dayOffset in
    [
        observation("burst-\(dayOffset)-a", publishedAt: makeDate(2026, 1, 5 + dayOffset, 8, 3)),
        observation("burst-\(dayOffset)-b", publishedAt: makeDate(2026, 1, 5 + dayOffset, 8, 22)),
        observation("burst-\(dayOffset)-c", publishedAt: makeDate(2026, 1, 5 + dayOffset, 8, 45))
    ]
}
let burstProfile = FeedScheduleProfiler.profile(from: burstObservations, calendar: utcCalendar)
require(burstProfile.kind == .burst, "Expected multi-episode morning window to be profiled as burst")

let weekdayObservations = [
    makeDate(2026, 1, 5, 9, 30),
    makeDate(2026, 1, 6, 9, 31),
    makeDate(2026, 1, 7, 9, 29),
    makeDate(2026, 1, 8, 9, 30),
    makeDate(2026, 1, 9, 9, 32),
    makeDate(2026, 1, 12, 9, 30),
    makeDate(2026, 1, 13, 9, 31),
    makeDate(2026, 1, 14, 9, 29),
    makeDate(2026, 1, 15, 9, 30),
    makeDate(2026, 1, 16, 9, 32)
].enumerated().map { observation("weekday-\($0.offset)", publishedAt: $0.element) }
let weekdayProfile = FeedScheduleProfiler.profile(from: weekdayObservations, calendar: utcCalendar)
require(weekdayProfile.kind == .dailyWeekdays, "Expected Monday-Friday morning profile")

let weeklyObservations = [
    makeDate(2026, 1, 7, 7, 0),
    makeDate(2026, 1, 14, 7, 2),
    makeDate(2026, 1, 21, 6, 58),
    makeDate(2026, 1, 28, 7, 1)
].enumerated().map { observation("weekly-\($0.offset)", publishedAt: $0.element) }
let weeklyProfile = FeedScheduleProfiler.profile(from: weeklyObservations, calendar: utcCalendar)
require(weeklyProfile.kind == .weekly, "Expected Wednesday weekly profile")

let unreliableProfile = FeedScheduleProfiler.profile(
    from: (0..<6).map { observation("missing-\($0)", publishedAt: nil) },
    calendar: utcCalendar
)
require(unreliableProfile.kind == .unreliableDates, "Expected missing RSS dates to be marked unreliable")

// ── FeedRefreshScheduling: learned windows drive due dates ───────────────────
let fiveMinutes: TimeInterval = 5 * 60
let hourlyActive = FeedRefreshScheduling.prediction(
    profile: hourlyProfile,
    latestPublishedAt: makeDate(2026, 1, 5, 9, 15),
    publishDates: hourlyObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 5, 10, 0)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 5, 10, 14),
    calendar: utcCalendar
)
require(hourlyActive.state == .activeWindow, "Expected hourly feed to be active near :15")
require(hourlyActive.nextDueAt <= makeDate(2026, 1, 5, 10, 14), "Expected overdue hourly check inside active window")

let hourlyQuiet = FeedRefreshScheduling.prediction(
    profile: hourlyProfile,
    latestPublishedAt: makeDate(2026, 1, 5, 10, 15),
    publishDates: hourlyObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 5, 10, 16)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 5, 10, 20),
    calendar: utcCalendar
)
require(hourlyQuiet.state == .quiet, "Expected hourly feed to stand down after current-hour episode arrives")
require(hourlyQuiet.nextDueAt == makeDate(2026, 1, 5, 11, 12), "Expected next hourly pre-window at :12")

let burstActive = FeedRefreshScheduling.prediction(
    profile: burstProfile,
    latestPublishedAt: makeDate(2026, 1, 8, 8, 3),
    publishDates: burstObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 8, 8, 20)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 8, 8, 30),
    calendar: utcCalendar
)
require(burstActive.state == .activeWindow, "Expected burst feed to keep checking after first episode in burst")

let weekdayWeekendQuiet = FeedRefreshScheduling.prediction(
    profile: weekdayProfile,
    latestPublishedAt: makeDate(2026, 1, 9, 9, 32),
    publishDates: weekdayObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 10, 12, 0)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 10, 12, 0),
    calendar: utcCalendar
)
require(weekdayWeekendQuiet.state == .quiet, "Expected weekday feed to stay quiet on Saturday")
require(weekdayWeekendQuiet.nextDueAt == makeDate(2026, 1, 12, 9, 15), "Expected next weekday pre-window on Monday")

let weekdayMissed = FeedRefreshScheduling.prediction(
    profile: weekdayProfile,
    latestPublishedAt: makeDate(2026, 1, 9, 9, 32),
    publishDates: weekdayObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 12, 10, 0)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 12, 10, 30),
    calendar: utcCalendar
)
require(weekdayMissed.state == .missedRelease, "Expected missing Monday episode to enter missed-release checks")
require(weekdayMissed.nextDueAt <= makeDate(2026, 1, 12, 10, 30), "Expected missed-release feed to remain due")

let weekdayMissedExpiredByEmptyChecks = FeedRefreshScheduling.prediction(
    profile: weekdayProfile,
    latestPublishedAt: makeDate(2026, 1, 9, 9, 32),
    publishDates: weekdayObservations.compactMap(\.publishedAt),
    stats: RefreshStats(
        lastFetchedAt: makeDate(2026, 1, 12, 10, 40),
        consecutiveEmptyFetches: FeedRefreshScheduling.missedReleaseEmptyFetchLimit
    ),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 12, 10, 45),
    calendar: utcCalendar
)
require(
    weekdayMissedExpiredByEmptyChecks.state == .fallback,
    "Expected repeated empty missed-release checks to expire high-priority urgency"
)
require(
    weekdayMissedExpiredByEmptyChecks.recheckInterval == 60 * 60,
    "Expected expired missed-release surveillance to use a low-frequency cadence"
)
require(
    weekdayMissedExpiredByEmptyChecks.nextDueAt > makeDate(2026, 1, 12, 10, 45),
    "Expected expired missed-release feed not to remain immediately due after a recent empty check"
)

let weeklyWeekendQuiet = FeedRefreshScheduling.prediction(
    profile: weeklyProfile,
    latestPublishedAt: makeDate(2026, 1, 7, 7, 0),
    publishDates: weeklyObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 10, 12, 0)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 10, 12, 0),
    calendar: utcCalendar
)
require(weeklyWeekendQuiet.state == .quiet, "Expected Wednesday weekly feed to stay quiet on Saturday")
require(weeklyWeekendQuiet.nextDueAt == makeDate(2026, 1, 14, 6, 30), "Expected next weekly pre-window on Wednesday")

let weeklyMissedExpiredByAge = FeedRefreshScheduling.prediction(
    profile: weeklyProfile,
    latestPublishedAt: makeDate(2026, 1, 7, 7, 0),
    publishDates: weeklyObservations.compactMap(\.publishedAt),
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 14, 15, 0)),
    minRecheckInterval: fiveMinutes,
    now: makeDate(2026, 1, 14, 16, 0),
    calendar: utcCalendar
)
require(
    weeklyMissedExpiredByAge.state == .fallback,
    "Expected old missed-release windows to expire even without enough empty checks"
)
require(
    weeklyMissedExpiredByAge.nextDueAt <= makeDate(2026, 1, 14, 16, 0),
    "Expected aged-out missed-release feed to be eligible only as low-priority fallback work"
)

let oneMinute: TimeInterval = 60
let learningScheduleProfile = FeedScheduleProfile(
    kind: .learning,
    confidence: 0.1,
    observationCount: 0,
    reliableDateCount: 0,
    activeWeekdays: [],
    reason: "Still learning"
)
let freshLearning = FeedRefreshScheduling.prediction(
    profile: learningScheduleProfile,
    latestPublishedAt: nil,
    publishDates: [],
    stats: RefreshStats(
        lastFetchedAt: makeDate(2026, 1, 5, 10, 0),
        consecutiveEmptyFetches: 1
    ),
    minRecheckInterval: oneMinute,
    now: makeDate(2026, 1, 5, 10, 2),
    calendar: utcCalendar
)
require(freshLearning.state == .learning, "Expected learning profile to remain in learning state")
require(freshLearning.recheckInterval == oneMinute, "Expected fresh learning feeds to honor 1-minute Radar briefly")

let decayedLearning = FeedRefreshScheduling.prediction(
    profile: learningScheduleProfile,
    latestPublishedAt: nil,
    publishDates: [],
    stats: RefreshStats(
        lastFetchedAt: makeDate(2026, 1, 5, 10, 0),
        consecutiveEmptyFetches: 7
    ),
    minRecheckInterval: oneMinute,
    now: makeDate(2026, 1, 5, 10, 3),
    calendar: utcCalendar
)
require(decayedLearning.recheckInterval == 4 * oneMinute, "Expected repeated empty learning checks to decay from 1 minute")
require(decayedLearning.nextDueAt > makeDate(2026, 1, 5, 10, 3), "Expected decayed learning feed not to stay immediately due")

let randomScheduleProfile = FeedScheduleProfile(
    kind: .random,
    confidence: 0.7,
    observationCount: 12,
    reliableDateCount: 12,
    activeWeekdays: [],
    reason: "No stable schedule"
)
let randomBaseline = FeedRefreshScheduling.prediction(
    profile: randomScheduleProfile,
    latestPublishedAt: nil,
    publishDates: [],
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 5, 10, 0)),
    minRecheckInterval: oneMinute,
    now: makeDate(2026, 1, 5, 10, 10),
    calendar: utcCalendar
)
require(randomBaseline.state == .randomSurveillance, "Expected random profile to use random surveillance state")
require(randomBaseline.recheckInterval == 15 * oneMinute, "Expected random feeds to floor 1-minute Radar at 15 minutes")
require(randomBaseline.nextDueAt > makeDate(2026, 1, 5, 10, 10), "Expected random baseline not to remain due every minute")

let recentRandom = FeedRefreshScheduling.prediction(
    profile: randomScheduleProfile,
    latestPublishedAt: nil,
    publishDates: [],
    stats: RefreshStats(
        lastFetchedAt: makeDate(2026, 1, 5, 10, 0),
        lastNewEpisodeAt: makeDate(2026, 1, 5, 9, 30)
    ),
    minRecheckInterval: oneMinute,
    now: makeDate(2026, 1, 5, 10, 6),
    calendar: utcCalendar
)
require(recentRandom.recheckInterval == 5 * oneMinute, "Expected recent random activity to boost checks without falling to 1 minute")

let unreliableScheduleProfile = FeedScheduleProfile(
    kind: .unreliableDates,
    confidence: 0.75,
    observationCount: 8,
    reliableDateCount: 0,
    activeWeekdays: [],
    reason: "Dates missing"
)
let unreliableBaseline = FeedRefreshScheduling.prediction(
    profile: unreliableScheduleProfile,
    latestPublishedAt: nil,
    publishDates: [],
    stats: RefreshStats(lastFetchedAt: makeDate(2026, 1, 5, 10, 0)),
    minRecheckInterval: oneMinute,
    now: makeDate(2026, 1, 5, 10, 10),
    calendar: utcCalendar
)
require(unreliableBaseline.recheckInterval == 15 * oneMinute, "Expected unreliable-date feeds to floor 1-minute Radar at 15 minutes")

// ── FeedRefreshPrioritizer: due feeds are ranked by release likelihood ───────
let priorityNow = makeDate(2026, 1, 5, 10, 30)
let learningProfile = FeedScheduleProfile(
    kind: .learning,
    confidence: 0.25,
    observationCount: 2,
    reliableDateCount: 2,
    activeWeekdays: [],
    reason: "Still learning"
)
let learningPrediction = FeedRefreshPrediction(
    nextDueAt: priorityNow.addingTimeInterval(-60),
    state: .learning,
    profileKind: .learning,
    recheckInterval: fiveMinutes,
    reason: "Learning check"
)
let activePriority = FeedRefreshPrioritizer.priority(
    prediction: hourlyActive,
    profile: hourlyProfile,
    priorityRank: 5,
    lastFetchedAt: makeDate(2026, 1, 5, 10, 0),
    now: makeDate(2026, 1, 5, 10, 14)
)
let learningPriority = FeedRefreshPrioritizer.priority(
    prediction: learningPrediction,
    profile: learningProfile,
    priorityRank: 5,
    lastFetchedAt: priorityNow.addingTimeInterval(-5 * 60),
    now: priorityNow
)
require(activePriority.score > learningPriority.score, "Expected active learned window to outrank ordinary learning check")

let missedPriority = FeedRefreshPrioritizer.priority(
    prediction: weekdayMissed,
    profile: weekdayProfile,
    priorityRank: 5,
    lastFetchedAt: makeDate(2026, 1, 12, 10, 0),
    now: makeDate(2026, 1, 12, 10, 30)
)
require(missedPriority.score > activePriority.score, "Expected missed release to outrank active release window")

let expiredMissedPriority = FeedRefreshPrioritizer.priority(
    prediction: weeklyMissedExpiredByAge,
    profile: weeklyProfile,
    priorityRank: 5,
    lastFetchedAt: makeDate(2026, 1, 14, 15, 0),
    now: makeDate(2026, 1, 14, 16, 0)
)
require(
    expiredMissedPriority.score < activePriority.score,
    "Expected expired missed-release urgency to fall behind an active release window"
)

let highRankPriority = FeedRefreshPrioritizer.priority(
    prediction: learningPrediction,
    profile: learningProfile,
    priorityRank: 1,
    lastFetchedAt: priorityNow.addingTimeInterval(-5 * 60),
    now: priorityNow
)
let lowerRankPriority = FeedRefreshPrioritizer.priority(
    prediction: learningPrediction,
    profile: learningProfile,
    priorityRank: 6,
    lastFetchedAt: priorityNow.addingTimeInterval(-5 * 60),
    now: priorityNow
)
require(highRankPriority.score > lowerRankPriority.score, "Expected user priority rank to lift otherwise equal feeds")

let randomProfile = FeedScheduleProfile(
    kind: .random,
    confidence: 0.7,
    observationCount: 12,
    reliableDateCount: 12,
    activeWeekdays: [],
    reason: "No stable schedule"
)
let randomPrediction = FeedRefreshPrediction(
    nextDueAt: priorityNow.addingTimeInterval(-60),
    state: .randomSurveillance,
    profileKind: .random,
    recheckInterval: fiveMinutes,
    reason: "Random surveillance"
)
let staleRandomPriority = FeedRefreshPrioritizer.priority(
    prediction: randomPrediction,
    profile: randomProfile,
    priorityRank: 5,
    lastFetchedAt: priorityNow.addingTimeInterval(-12 * 60 * 60),
    now: priorityNow
)
let freshRandomPriority = FeedRefreshPrioritizer.priority(
    prediction: randomPrediction,
    profile: randomProfile,
    priorityRank: 5,
    lastFetchedAt: priorityNow.addingTimeInterval(-5 * 60),
    now: priorityNow
)
require(staleRandomPriority.score > freshRandomPriority.score, "Expected stale due random feed to outrank fresh due random feed")

// ── FeedRefreshBudgeting: caps are pure and preserve priority order ───────────
struct BudgetCandidate {
    let id: String
    let state: FeedRefreshWindowState
}

let budgetCandidates = [
    BudgetCandidate(id: "learning-a", state: .learning),
    BudgetCandidate(id: "random-a", state: .randomSurveillance),
    BudgetCandidate(id: "active-a", state: .activeWindow),
    BudgetCandidate(id: "learning-b", state: .learning),
    BudgetCandidate(id: "pre-a", state: .preWindow)
]

let unlimitedBudget = FeedRefreshBudgeting.select(
    candidates: budgetCandidates,
    policy: FeedRefreshBudgetPolicy(maxSelections: nil),
    state: { $0.state }
)
require(
    unlimitedBudget.selected.map(\.id) == budgetCandidates.map(\.id),
    "Expected unlimited budget to select every candidate in priority order"
)
require(unlimitedBudget.cappedOutCount == 0, "Expected unlimited budget to defer nothing")

let cappedBudget = FeedRefreshBudgeting.select(
    candidates: budgetCandidates,
    policy: FeedRefreshBudgetPolicy(maxSelections: 2),
    state: { $0.state }
)
require(
    cappedBudget.selected.map(\.id) == ["learning-a", "random-a"],
    "Expected capped budget to select the first two prioritized candidates"
)
require(
    cappedBudget.deferred.map(\.id) == ["active-a", "learning-b", "pre-a"],
    "Expected capped budget to defer all candidates past the cap"
)

let bypassBudget = FeedRefreshBudgeting.select(
    candidates: budgetCandidates,
    policy: FeedRefreshBudgetPolicy(
        maxSelections: 2,
        capBypassStates: [.activeWindow, .preWindow]
    ),
    state: { $0.state }
)
require(
    bypassBudget.selected.map(\.id) == ["learning-a", "random-a", "active-a", "pre-a"],
    "Expected active/pre-window candidates to bypass the cap without changing order"
)
require(
    bypassBudget.deferred.map(\.id) == ["learning-b"],
    "Expected only non-bypass candidates past the normal budget to be deferred"
)

// Regression (Podcast Detail crash): a feed that repeats a guid must collapse to
// one episode and never produce duplicate Identifiable ids (which crashes
// SwiftUI ForEach on tap). A second merge must also not trap on the guid-keyed
// dictionary built from the stored episodes.
let dupGUID = "dup-guid-regression"
let dupA = Episode(subscriptionID: saved.id, guid: dupGUID, title: "Dup A", audioURL: audioURL)
let dupB = Episode(subscriptionID: saved.id, guid: dupGUID, title: "Dup B", audioURL: audioURL)
await reloaded.updateEpisodes(subscriptionID: saved.id, episodes: [dupA, dupB])
let dupResult = await reloaded.subscription(id: saved.id)?.episodes ?? []
require(dupResult.filter { $0.guid == dupGUID }.count == 1, "Expected duplicate-guid feed items to collapse to one episode")
require(Set(dupResult.map { $0.id }).count == dupResult.count, "Expected unique episode ids after merging a duplicate-guid feed")
await reloaded.updateEpisodes(subscriptionID: saved.id, episodes: [dupA, dupB]) // must not crash on re-merge

print("SubscriptionStoreSmoke passed: save, duplicate detection, reload, chapter filter persistence, played episode persistence, release observations, schedule profiling, learned-window scheduling, feed refresh scheduling, refresh prioritization, refresh budgeting, and duplicate-guid dedup")
