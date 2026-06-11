import Foundation
import AutohopCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

func approx(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
    abs(a - b) < 0.001
}

let calendar = Calendar.current

func dayKey(daysAgo: Int) -> String {
    let date = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

func syntheticDay(daysAgo: Int, seconds: TimeInterval, show: UUID) -> DayStats {
    var hours = Array(repeating: TimeInterval(0), count: 24)
    hours[8] = seconds
    return DayStats(
        dayKey: dayKey(daysAgo: daysAgo),
        wallClockSeconds: seconds,
        hourSeconds: hours,
        perShowSeconds: [show.uuidString: seconds]
    )
}

@MainActor
func runSmokeTest() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("autohop-stats-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let statsURL = tempDir.appendingPathComponent("listening-stats.json")
    let legacyURL = tempDir.appendingPathComponent("playback-stats.json")

    let showA = UUID()
    let showB = UUID()

    // 1. Recording into today's bucket.
    let store = ListeningStatsStore(fileURL: statsURL, legacyFileURL: legacyURL)
    for _ in 0..<120 {
        store.addListeningTime(0.5, speed: 2.0, subscriptionID: showA, showTitle: "Show A")
    }
    store.addTrimSilenceSaved(12)
    store.addManualSkipForward(30)
    store.addAutoSkip(45)
    store.recordEpisodeStarted(subscriptionID: showA, showTitle: "Show A")
    store.recordEpisodeCompleted(subscriptionID: showA)

    let today = store.summary(for: .last(days: 1))
    require(today.days.count == 1, "Expected exactly one day bucket for .last(days: 1)")
    require(approx(today.wallClockSeconds, 60), "Expected 60s wall clock, got \(today.wallClockSeconds)")
    require(approx(today.timeSavedVariableSpeed, 30), "Expected 30s speed saving at 2.0x, got \(today.timeSavedVariableSpeed)")
    require(approx(today.timeSavedTrimSilence, 12), "Expected 12s trim saving")
    require(approx(today.timeSavedManualSkip, 30), "Expected 30s manual skip saving")
    require(approx(today.timeSavedAutoSkip, 45), "Expected 45s auto skip saving")
    require(today.manualSkipForwardCount == 1, "Expected 1 manual skip")
    require(today.episodesStarted == 1 && today.episodesCompleted == 1, "Expected 1 started + 1 completed")
    require(approx(today.hourSeconds.reduce(0, +), 60), "Hour histogram should sum to wall clock")
    require(approx(today.perShowSeconds[showA.uuidString] ?? 0, 60), "Expected per-show attribution")
    require(store.showTitles[showA.uuidString] == "Show A", "Expected show title captured")

    // 2. Period aggregation and streaks over synthetic history.
    // Qualifying days: today (60s), 1-3 days ago, then a gap, then 5-6 days ago.
    for daysAgo in [1, 2, 3, 5, 6] {
        store.importDay(syntheticDay(daysAgo: daysAgo, seconds: 600, show: showB))
    }
    store.save()

    let month = store.summary(for: .last(days: 30))
    require(month.days.count == 30, "Expected 30 zero-filled day buckets, got \(month.days.count)")
    require(approx(month.wallClockSeconds, 60 + 600 * 5), "Expected period total 3060s, got \(month.wallClockSeconds)")
    require(month.days.first!.dayKey == dayKey(daysAgo: 29), "Expected oldest-first day series")
    require(month.days.last!.dayKey == dayKey(daysAgo: 0), "Expected series to end today")
    require(approx(month.hourSeconds[8], 3000), "Expected synthetic listening bucketed at 8am")

    let tops = month.topShows(titles: store.showTitles, limit: 5)
    require(tops.count == 2, "Expected two shows in top list")
    require(tops[0].id == showB.uuidString && approx(tops[0].seconds, 3000), "Expected Show B ranked first")
    require(tops[1].title == "Show A", "Expected Show A title resolved")

    require(store.currentStreakDays == 4, "Expected current streak 4 (today + 3), got \(store.currentStreakDays)")
    require(store.longestStreakDays == 4, "Expected longest streak 4, got \(store.longestStreakDays)")

    let lifetime = store.summary(for: .lifetime)
    require(lifetime.days.count == 6, "Expected 6 recorded days in lifetime summary, got \(lifetime.days.count)")

    // 3. Persistence round-trip.
    let reloaded = ListeningStatsStore(fileURL: statsURL, legacyFileURL: legacyURL)
    require(approx(reloaded.lifetime.totalListeningSeconds, store.lifetime.totalListeningSeconds), "Expected lifetime to survive reload")
    require(reloaded.currentStreakDays == 4, "Expected streak to survive reload")
    require(reloaded.showTitles[showA.uuidString] == "Show A", "Expected titles to survive reload")

    // 4. Legacy baseline import on first launch.
    let migratedDir = tempDir.appendingPathComponent("migrated", isDirectory: true)
    try FileManager.default.createDirectory(at: migratedDir, withIntermediateDirectories: true)
    let migratedStatsURL = migratedDir.appendingPathComponent("listening-stats.json")
    let migratedLegacyURL = migratedDir.appendingPathComponent("playback-stats.json")

    let legacyStartedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let legacy = PlaybackStats(
        totalListeningSeconds: 1000,
        timeSavedVariableSpeed: 200,
        timeSavedTrimSilence: 100,
        startedAt: legacyStartedAt
    )
    try JSONEncoder().encode(legacy).write(to: migratedLegacyURL)

    let migrated = ListeningStatsStore(fileURL: migratedStatsURL, legacyFileURL: migratedLegacyURL)
    require(approx(migrated.lifetime.totalListeningSeconds, 1000), "Expected legacy listening total imported")
    require(approx(migrated.lifetime.totalTimeSaved, 300), "Expected legacy time saved imported")
    require(approx(migrated.startedAt.timeIntervalSince1970, legacyStartedAt.timeIntervalSince1970), "Expected legacy startedAt carried over")

    migrated.addListeningTime(10, speed: 1.6, subscriptionID: showA, showTitle: "Show A")
    require(approx(migrated.lifetime.totalListeningSeconds, 1010), "Expected baseline + new listening combined")

    // Baseline must not be re-imported on reload (no double counting).
    migrated.save()
    let migratedReloaded = ListeningStatsStore(fileURL: migratedStatsURL, legacyFileURL: migratedLegacyURL)
    require(approx(migratedReloaded.lifetime.totalListeningSeconds, 1010), "Expected no double import of legacy baseline")

    try? FileManager.default.removeItem(at: tempDir)
    print("ListeningStatsStore smoke test passed ✅")
}

// MARK: - ShowEngagementAnalyzer smoke test

func historyEntry(
    show: UUID,
    title: String,
    daysAgo: Int = 1,
    listened: TimeInterval,
    position: TimeInterval,
    duration: TimeInterval? = 3600,
    status: ListeningHistoryStatus,
    kind: CompletionKind? = nil,
    percent: Double? = nil
) -> ListeningHistoryEntry {
    ListeningHistoryEntry(
        id: UUID().uuidString,
        subscriptionID: show,
        episodeID: UUID(),
        episodeTitle: "Episode",
        podcastTitle: title,
        artworkURL: nil,
        publishedAt: nil,
        durationSeconds: duration,
        listenedSeconds: listened,
        lastPositionSeconds: position,
        lastListenedAt: calendar.date(byAdding: .day, value: -daysAgo, to: Date())!,
        status: status,
        completionKind: kind,
        completionPercent: percent,
        listenedDurationSeconds: listened,
        episodeDurationSeconds: duration
    )
}

func runEngagementSmokeTest() {
    let since = calendar.date(byAdding: .day, value: -30, to: Date())!
    let healthy = UUID()
    let abandoner = UUID()
    let archiver = UUID()
    let autoChurn = UUID()
    let legacy = UUID()

    var entries: [ListeningHistoryEntry] = []

    // Healthy show: 5 finished naturally.
    for _ in 0..<5 {
        entries.append(historyEntry(show: healthy, title: "Healthy", listened: 3600, position: 3600, status: .played, kind: .finishedNaturally, percent: 1.0))
    }

    // Serial abandoner: 4 episodes stopped around the 12-minute mark, then archived.
    for stop in [700.0, 720.0, 740.0, 760.0] {
        entries.append(historyEntry(show: abandoner, title: "Abandoner", listened: stop, position: stop, status: .archived, kind: .manuallyArchived, percent: stop / 3600))
    }

    // Archiver: 6 manually archived unplayed, 2 finished.
    for _ in 0..<6 {
        entries.append(historyEntry(show: archiver, title: "Archiver", listened: 0, position: 0, status: .archived, kind: .manuallyArchived, percent: 0))
    }
    for _ in 0..<2 {
        entries.append(historyEntry(show: archiver, title: "Archiver", listened: 3600, position: 3600, status: .played, kind: .finishedNaturally, percent: 1.0))
    }

    // Auto-churn: episode limit archived 4 unplayed, but 4 were finished —
    // half-weighted auto archives keep this below the struggle threshold.
    for _ in 0..<4 {
        entries.append(historyEntry(show: autoChurn, title: "AutoChurn", listened: 0, position: 0, status: .archived, kind: .autoArchived, percent: 0))
    }
    for _ in 0..<4 {
        entries.append(historyEntry(show: autoChurn, title: "AutoChurn", listened: 3600, position: 3600, status: .played, kind: .finishedNaturally, percent: 1.0))
    }

    // Legacy entries (nil kind/percent): archived with no listening → counts at auto weight.
    for _ in 0..<4 {
        entries.append(historyEntry(show: legacy, title: "Legacy", listened: 0, position: 0, duration: nil, status: .archived))
    }

    // In-progress episode must not count against the abandoner.
    entries.append(historyEntry(show: abandoner, title: "Abandoner", listened: 1800, position: 1800, status: .listened, percent: 0.5))

    // Stale entry outside the window must be ignored.
    entries.append(historyEntry(show: healthy, title: "Healthy", daysAgo: 45, listened: 0, position: 0, status: .archived, kind: .manuallyArchived, percent: 0))

    let engagements = ShowEngagementAnalyzer.engagements(entries: entries, since: since)
    let byID = Dictionary(uniqueKeysWithValues: engagements.map { ($0.subscriptionID, $0) })

    require(byID[healthy]?.completed == 5, "Expected 5 completed for healthy show")
    require(byID[healthy]?.struggleScore == 0, "Expected zero struggle for healthy show")
    require(byID[healthy]?.totalResolved == 5, "Expected stale entry excluded from healthy show")

    require(byID[abandoner]?.abandoned == 4, "Expected 4 abandoned episodes")
    require(byID[abandoner]?.totalResolved == 4, "Expected in-progress entry excluded")
    require(approx(byID[abandoner]?.medianStopSeconds ?? 0, 730), "Expected median stop of 730s")
    require(ShowEngagementAnalyzer.label(for: byID[abandoner]!) == "You usually stop around the 12-minute mark", "Unexpected abandoner label: \(ShowEngagementAnalyzer.label(for: byID[abandoner]!))")

    require(byID[archiver]?.archivedUnplayedDeliberate == 6, "Expected 6 deliberate unplayed archives")
    require(approx(byID[archiver]?.struggleScore ?? 0, 0.75), "Expected archiver score 0.75")
    require(ShowEngagementAnalyzer.label(for: byID[archiver]!) == "Archived 6 of the last 8 unplayed", "Unexpected archiver label")

    require(byID[autoChurn]?.archivedUnplayedAuto == 4, "Expected 4 auto archives")
    require(approx(byID[autoChurn]?.struggleScore ?? 0, 0.25), "Expected auto-churn score 0.25")

    require(byID[legacy]?.archivedUnplayedAuto == 4, "Expected legacy nil-kind archives at auto weight")

    let struggling = ShowEngagementAnalyzer.strugglingShows(entries: entries, since: since)
    let strugglingIDs = struggling.map(\.subscriptionID)
    require(strugglingIDs.contains(abandoner), "Expected abandoner flagged")
    require(strugglingIDs.contains(archiver), "Expected archiver flagged")
    require(!strugglingIDs.contains(healthy), "Expected healthy show not flagged")
    require(!strugglingIDs.contains(autoChurn), "Expected auto-churn below threshold")
    // Auto-only signal can never flag a show, even at a 100% archive rate —
    // that's the episode limit churning a high-volume feed, not drift.
    require(!strugglingIDs.contains(legacy), "Expected auto-only legacy show not flagged despite 0.5 score")

    let allAutoFeed = UUID()
    let allAutoEntries = (0..<55).map { _ in
        historyEntry(show: allAutoFeed, title: "Daily News", listened: 0, position: 0, status: .archived, kind: .autoArchived, percent: 0)
    }
    require(ShowEngagementAnalyzer.strugglingShows(entries: allAutoEntries, since: since).isEmpty, "Expected 55/55 auto-archived feed not flagged")
    require(strugglingIDs.first == abandoner, "Expected abandoner ranked first (score 1.0)")

    let muted = ShowEngagementAnalyzer.strugglingShows(entries: entries, since: since, excluding: [abandoner])
    require(!muted.map(\.subscriptionID).contains(abandoner), "Expected muted show excluded")

    // Below minResolvedEpisodes a show is never flagged, however bad the ratio.
    let tiny = UUID()
    let tinyEntries = (0..<3).map { _ in
        historyEntry(show: tiny, title: "Tiny", listened: 0, position: 0, status: .archived, kind: .manuallyArchived, percent: 0)
    }
    require(ShowEngagementAnalyzer.strugglingShows(entries: tinyEntries, since: since).isEmpty, "Expected 3 episodes to be below the minimum sample")

    print("ShowEngagementAnalyzer smoke test passed ✅")
}

try MainActor.assumeIsolated {
    try runSmokeTest()
}
runEngagementSmokeTest()
