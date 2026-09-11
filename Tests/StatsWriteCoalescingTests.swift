// AI CONTEXT — Tests/StatsWriteCoalescingTests.swift. Regression test for AH-P1-004:
// listening-stats accumulation runs every 0.5s playback tick, and each tick used to
// issue a GRDB write transaction (recordStatsDay). These are now coalesced — the row
// holds the FULL day bucket, so a throttled flush re-writes the complete value with no
// data loss — and flushed on lifecycle save() checkpoints. The same test also
// protects the 2026-07-12 UI optimization: continuous playback may mutate the
// authoritative bucket every tick, but must not publish a revision every tick
// or publish the first tick twice when its initial persistence checkpoint runs.
// Completed downloads are deliberately different: their discrete settlement is
// immediately durable so background termination cannot erase the traffic fact.
// Discrete outcome tests also protect durable per-show attribution, which is the
// source of truth for long-range expanded Top Shows counts. Calendar-boundary,
// coverage-notice and canonical-feed fixtures protect the September 2026 Stats
// interpretation redesign.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class StatsWriteCoalescingTests: XCTestCase {

    @MainActor
    func testPerTickStatsWritesAreCoalesced() throws {
        // A real fileURL so the JSON saveThrottled() behaves as in production (30s gate);
        // otherwise save() never records lastSavedAt and would flush on every tick.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: dir.appendingPathComponent("stats.json"), legacyFileURL: nil)
        store.syncDatabase = db
        db._testStatsDayWriteCount = 0 // ignore any write from didSet/reload

        let sub = UUID()
        // Simulate 120 ticks (60s of playback at 0.5s each).
        for _ in 0..<120 {
            store.addListeningTime(0.5, speed: 1.0, subscriptionID: sub, showTitle: "Show")
        }

        XCTAssertLessThanOrEqual(store.revision, 2,
                                 "Playback ticks must coalesce Stats UI invalidations")

        // Without coalescing this would be 120 write transactions. The throttle is wall-clock
        // (30s) and these run in milliseconds, so only the first tick writes through.
        XCTAssertLessThanOrEqual(db._testStatsDayWriteCount, 2,
                                 "Per-tick stats writes must be coalesced, not one-per-tick")

        // A lifecycle save() must flush the coalesced bucket so the sync row is current.
        let beforeFlush = db._testStatsDayWriteCount
        store.save()
        XCTAssertEqual(db._testStatsDayWriteCount, beforeFlush + 1,
                       "save() should flush the pending stats day exactly once")
    }

    @MainActor
    func testCoalescedWriteStillPersistsFullDayValue() throws {
        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        store.syncDatabase = db

        let sub = UUID()
        for _ in 0..<10 {
            store.addListeningTime(0.5, speed: 1.0, subscriptionID: sub, showTitle: "Show")
        }
        store.flushPendingStatsDays()

        // The persisted sync row should reflect the FULL accumulated total (10 * 0.5 = 5s),
        // not just the value at the first (un-coalesced) write.
        let pending = try db.pendingStatsDays()
        let total = pending.reduce(0.0) { $0 + $1.wallClockSeconds }
        XCTAssertEqual(total, 5.0, accuracy: 0.001,
                       "Coalesced flush must persist the complete accumulated day value")
    }

    @MainActor
    func testDownloadAccountingPersistsAtSettlement() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-download-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("stats.json")
        let db = try AutohopDatabase()
        let store = ListeningStatsStore(fileURL: fileURL, legacyFileURL: nil)
        store.syncDatabase = db
        db._testStatsDayWriteCount = 0

        store.recordDownload(bytes: 42_000)

        XCTAssertEqual(
            db._testStatsDayWriteCount,
            1,
            "A completed background download must persist its discrete statistics immediately"
        )

        store.save()

        XCTAssertGreaterThanOrEqual(db._testStatsDayWriteCount, 1)
        let relaunched = ListeningStatsStore(fileURL: fileURL, legacyFileURL: nil)
        XCTAssertEqual(relaunched.summary(for: .lifetime).episodesDownloaded, 1)
        XCTAssertEqual(relaunched.summary(for: .lifetime).bytesDownloaded, 42_000)
    }

    @MainActor
    func testEpisodeOutcomesAreAttributedToTheirShow() {
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        let showA = UUID()
        let showB = UUID()

        store.recordEpisodeStarted(subscriptionID: showA, showTitle: "Show A")
        store.recordEpisodeCompleted(subscriptionID: showA)
        store.recordEpisodeCompleted(subscriptionID: showA)
        store.recordEpisodeStarted(subscriptionID: showB, showTitle: "Show B")
        store.recordEpisodeCompleted(subscriptionID: showB)

        let summary = store.summary(for: .lifetime)
        XCTAssertEqual(summary.episodesStarted, 2)
        XCTAssertEqual(summary.episodesCompleted, 3)
        XCTAssertEqual(summary.perShowEpisodesStarted[showA.uuidString], 1)
        XCTAssertEqual(summary.perShowEpisodesCompleted[showA.uuidString], 2)
        XCTAssertEqual(summary.perShowEpisodesStarted[showB.uuidString], 1)
        XCTAssertEqual(summary.perShowEpisodesCompleted[showB.uuidString], 1)
    }

    @MainActor
    func testVariableSpeedSavingsUseWallClockContract() {
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        let show = UUID()

        store.addListeningTime(100, speed: 1.4, subscriptionID: show, showTitle: "Show")

        let summary = store.summary(for: .lifetime)
        XCTAssertEqual(summary.wallClockSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(summary.timeSavedVariableSpeed, 40, accuracy: 0.001)
        XCTAssertEqual(summary.perShowTimeSaved[show.uuidString] ?? 0, 40, accuracy: 0.001)
    }

    @MainActor
    func testRenderedIntervalSplitsAcrossLocalMidnightAndHourBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 10 * 3600)!
        let store = ListeningStatsStore(
            fileURL: nil,
            legacyFileURL: nil,
            protectedDataAvailable: { true },
            calendarProvider: { calendar }
        )
        let midnight = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 0, minute: 0, second: 0
        ))!

        store.addListeningTime(
            2,
            speed: 1,
            subscriptionID: UUID(),
            showTitle: "Show",
            endedAt: midnight.addingTimeInterval(1)
        )

        let days = Dictionary(uniqueKeysWithValues: store.summary(for: .lifetime).days.map { ($0.dayKey, $0) })
        XCTAssertEqual(days["2026-09-04"]?.wallClockSeconds ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(days["2026-09-04"]?.hourSeconds[23] ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(days["2026-09-05"]?.wallClockSeconds ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(days["2026-09-05"]?.hourSeconds[0] ?? 0, 1, accuracy: 0.001)
    }

    @MainActor
    func testCanonicalShowIdentityCombinesResubscribeStatistics() {
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        let feedURL = URL(string: "HTTPS://Example.com/podcast.xml/#fragment")!
        let first = Subscription(feedURL: feedURL, title: "Show", priorityRank: 1)
        let second = Subscription(
            feedURL: URL(string: "https://example.com/podcast.xml")!,
            title: "Show",
            priorityRank: 1
        )
        store.addListeningTime(10, speed: 1, subscriptionID: first.id, showTitle: first.title)

        store.registerCanonicalShows([first, second])
        store.addListeningTime(
            5,
            speed: 1,
            subscriptionID: second.id,
            showTitle: second.title,
            feedURL: second.feedURL
        )

        let summary = store.summary(for: .lifetime)
        let canonical = StatsShowIdentity.key(for: second.feedURL)
        XCTAssertEqual(summary.perShowSeconds.count, 1)
        XCTAssertEqual(summary.perShowSeconds[canonical] ?? 0, 15, accuracy: 0.001)
    }

    func testCanonicalShowIdentityPreservesCaseSensitivePath() {
        let upperPath = URL(string: "https://example.com/Feed.xml")!
        let lowerPath = URL(string: "HTTPS://EXAMPLE.COM/feed.xml")!

        XCTAssertNotEqual(
            StatsShowIdentity.key(for: upperPath),
            StatsShowIdentity.key(for: lowerPath),
            "Only URL scheme and host are case-insensitive; feed paths may be case-sensitive"
        )
    }

    @MainActor
    func testLifetimeDisclosesMetricsIntroducedAfterRecordedHistoryBegan() {
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        store.importDay(DayStats(dayKey: "2026-06-01", wallClockSeconds: 60))

        let metrics = Set(store.summary(for: .lifetime).coverageNotices.map(\.metric))

        XCTAssertTrue(metrics.contains(.perShowTimeSaved))
        XCTAssertTrue(metrics.contains(.downloads))
        XCTAssertTrue(metrics.contains(.perShowOutcomes))
        XCTAssertTrue(metrics.contains(.durableOutcomes))
    }

    @MainActor
    func testDurableOutcomeIsIdempotentAndPreservesNaturalCompletion() {
        let store = ListeningStatsStore(fileURL: nil, legacyFileURL: nil)
        let subscription = Subscription(
            feedURL: URL(string: "https://example.com/feed")!,
            title: "Show",
            priorityRank: 1
        )
        var episode = Episode(
            subscriptionID: subscription.id,
            guid: "episode-guid",
            title: "Episode",
            audioURL: URL(string: "https://example.com/episode.mp3")!
        )
        episode.durationSeconds = 100

        store.recordEpisodeOutcome(
            episode: episode,
            subscription: subscription,
            completionKind: .finishedNaturally,
            positionSeconds: 100
        )
        store.recordEpisodeOutcome(
            episode: episode,
            subscription: subscription,
            completionKind: .autoArchived,
            positionSeconds: 100
        )
        store.recordEpisodeOutcome(
            episode: episode,
            subscription: subscription,
            completionKind: .finishedNaturally,
            positionSeconds: 100
        )

        let summary = store.summary(for: .lifetime)
        let outcomes = summary.episodeOutcomes
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.values.first?.completionKind, .finishedNaturally)
        XCTAssertEqual(summary.episodesCompleted, 1)
        XCTAssertEqual(
            summary.perShowEpisodesCompleted[StatsShowIdentity.key(for: subscription.feedURL)],
            1
        )
    }
}
