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

try MainActor.assumeIsolated {
    try runSmokeTest()
}
