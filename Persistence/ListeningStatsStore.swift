import Foundation

// AI CONTEXT — Persistence/ListeningStatsStore.swift
// Data layer for the Stats page. Buckets all listening activity per LOCAL
// calendar day in DayStats records (wall-clock seconds, 24-hour histogram,
// per-show seconds and per-show time saved keyed by subscription UUID with a
// title map that survives unsubscribes, four time-saved categories, episodes
// started/completed, manual skip count). Persisted to listening-stats.json; saves throttled to
// 30 s during playback and force-flushed on pause/background (AutohopApp).
// Legacy lifetime totals from playback-stats.json are imported once as
// `legacyBaseline` so pre-daily-bucketing history isn't lost.
// QUERY API (used by StatsView): summary(for: .last(days:)/.lifetime),
// lifetime (legacy PlaybackStats shape), currentStreakDays/longestStreakDays
// (a day counts at ≥ 60 s), previousPeriodShowSeconds (rank-movement badges).
// FED BY AppState hooks: 0.5 s playback tick, SilenceDetector trim callbacks,
// startPlayback (episode started), handleEpisodeFinished (completed).

// MARK: - PlaybackStats (lifetime summary)

/// Lifetime aggregate shape consumed by `StatsView`. Also the on-disk format of the
/// legacy `playback-stats.json`, which is imported once as `legacyBaseline` so totals
/// accumulated before daily bucketing existed are not lost.
public struct PlaybackStats: Codable {
    public var totalListeningSeconds: TimeInterval = 0
    public var timeSavedVariableSpeed: TimeInterval = 0
    public var timeSavedTrimSilence: TimeInterval = 0
    public var timeSavedManualSkip: TimeInterval = 0
    public var timeSavedAutoSkip: TimeInterval = 0
    public var startedAt: Date = Date()

    public init(
        totalListeningSeconds: TimeInterval = 0,
        timeSavedVariableSpeed: TimeInterval = 0,
        timeSavedTrimSilence: TimeInterval = 0,
        timeSavedManualSkip: TimeInterval = 0,
        timeSavedAutoSkip: TimeInterval = 0,
        startedAt: Date = Date()
    ) {
        self.totalListeningSeconds = totalListeningSeconds
        self.timeSavedVariableSpeed = timeSavedVariableSpeed
        self.timeSavedTrimSilence = timeSavedTrimSilence
        self.timeSavedManualSkip = timeSavedManualSkip
        self.timeSavedAutoSkip = timeSavedAutoSkip
        self.startedAt = startedAt
    }

    public var totalTimeSaved: TimeInterval {
        timeSavedVariableSpeed + timeSavedTrimSilence + timeSavedManualSkip + timeSavedAutoSkip
    }
}

// MARK: - DayStats (one bucket per calendar day)

/// All listening activity for one local calendar day. A populated record is a few
/// hundred bytes, so lifetime retention is cheap and any period query (30d/90d/1y/
/// lifetime) is just a sum over buckets.
public struct DayStats: Codable, Equatable {
    /// Local calendar day, "yyyy-MM-dd".
    public var dayKey: String
    /// Real time spent listening (wall clock, unaffected by speed/trim).
    public var wallClockSeconds: TimeInterval
    /// Wall-clock seconds per hour of day (24 buckets) — feeds the listening clock.
    public var hourSeconds: [TimeInterval]
    /// Wall-clock seconds per subscription, keyed by `Subscription.id.uuidString`.
    public var perShowSeconds: [String: TimeInterval]
    /// Total time saved (all four categories) per subscription, keyed by
    /// `Subscription.id.uuidString`. Added 2026-06; days recorded before then
    /// have an empty map, so per-period sums can undercount the category totals.
    public var perShowTimeSaved: [String: TimeInterval]
    public var timeSavedVariableSpeed: TimeInterval
    public var timeSavedTrimSilence: TimeInterval
    public var timeSavedManualSkip: TimeInterval
    public var timeSavedAutoSkip: TimeInterval
    public var episodesStarted: Int
    public var episodesCompleted: Int
    public var manualSkipForwardCount: Int

    public init(
        dayKey: String,
        wallClockSeconds: TimeInterval = 0,
        hourSeconds: [TimeInterval] = Array(repeating: 0, count: 24),
        perShowSeconds: [String: TimeInterval] = [:],
        perShowTimeSaved: [String: TimeInterval] = [:],
        timeSavedVariableSpeed: TimeInterval = 0,
        timeSavedTrimSilence: TimeInterval = 0,
        timeSavedManualSkip: TimeInterval = 0,
        timeSavedAutoSkip: TimeInterval = 0,
        episodesStarted: Int = 0,
        episodesCompleted: Int = 0,
        manualSkipForwardCount: Int = 0
    ) {
        self.dayKey = dayKey
        self.wallClockSeconds = wallClockSeconds
        self.hourSeconds = hourSeconds
        self.perShowSeconds = perShowSeconds
        self.perShowTimeSaved = perShowTimeSaved
        self.timeSavedVariableSpeed = timeSavedVariableSpeed
        self.timeSavedTrimSilence = timeSavedTrimSilence
        self.timeSavedManualSkip = timeSavedManualSkip
        self.timeSavedAutoSkip = timeSavedAutoSkip
        self.episodesStarted = episodesStarted
        self.episodesCompleted = episodesCompleted
        self.manualSkipForwardCount = manualSkipForwardCount
    }

    public var totalTimeSaved: TimeInterval {
        timeSavedVariableSpeed + timeSavedTrimSilence + timeSavedManualSkip + timeSavedAutoSkip
    }

    /// Sums this day's buckets with another device's same-day partition — the
    /// core of additive cross-device stats (SYNC_DESIGN.md step 5b). NEVER
    /// last-write-wins: each device contributes its own listening for the day.
    public func merged(with other: DayStats) -> DayStats {
        var r = self
        r.wallClockSeconds += other.wallClockSeconds
        for h in 0..<24 { r.hourSeconds[h] += other.hourSeconds[h] }
        for (k, v) in other.perShowSeconds { r.perShowSeconds[k, default: 0] += v }
        for (k, v) in other.perShowTimeSaved { r.perShowTimeSaved[k, default: 0] += v }
        r.timeSavedVariableSpeed += other.timeSavedVariableSpeed
        r.timeSavedTrimSilence += other.timeSavedTrimSilence
        r.timeSavedManualSkip += other.timeSavedManualSkip
        r.timeSavedAutoSkip += other.timeSavedAutoSkip
        r.episodesStarted += other.episodesStarted
        r.episodesCompleted += other.episodesCompleted
        r.manualSkipForwardCount += other.manualSkipForwardCount
        return r
    }

    // MARK: Codable — graceful decoding of day buckets saved before perShowTimeSaved existed

    enum CodingKeys: String, CodingKey {
        case dayKey, wallClockSeconds, hourSeconds, perShowSeconds, perShowTimeSaved
        case timeSavedVariableSpeed, timeSavedTrimSilence, timeSavedManualSkip, timeSavedAutoSkip
        case episodesStarted, episodesCompleted, manualSkipForwardCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        wallClockSeconds = try c.decode(TimeInterval.self, forKey: .wallClockSeconds)
        hourSeconds = try c.decode([TimeInterval].self, forKey: .hourSeconds)
        perShowSeconds = try c.decode([String: TimeInterval].self, forKey: .perShowSeconds)
        // Absent in JSON written before per-show time-saved tracking (2026-06).
        perShowTimeSaved = try c.decodeIfPresent([String: TimeInterval].self, forKey: .perShowTimeSaved) ?? [:]
        timeSavedVariableSpeed = try c.decode(TimeInterval.self, forKey: .timeSavedVariableSpeed)
        timeSavedTrimSilence = try c.decode(TimeInterval.self, forKey: .timeSavedTrimSilence)
        timeSavedManualSkip = try c.decode(TimeInterval.self, forKey: .timeSavedManualSkip)
        timeSavedAutoSkip = try c.decode(TimeInterval.self, forKey: .timeSavedAutoSkip)
        episodesStarted = try c.decode(Int.self, forKey: .episodesStarted)
        episodesCompleted = try c.decode(Int.self, forKey: .episodesCompleted)
        manualSkipForwardCount = try c.decode(Int.self, forKey: .manualSkipForwardCount)
    }
}

// MARK: - Period summary

/// Aggregate of the day buckets inside a period — everything a stats page needs
/// for one selected time range.
public struct ListeningStatsSummary {
    public var wallClockSeconds: TimeInterval = 0
    public var timeSavedVariableSpeed: TimeInterval = 0
    public var timeSavedTrimSilence: TimeInterval = 0
    public var timeSavedManualSkip: TimeInterval = 0
    public var timeSavedAutoSkip: TimeInterval = 0
    public var episodesStarted: Int = 0
    public var episodesCompleted: Int = 0
    public var manualSkipForwardCount: Int = 0
    /// Wall-clock seconds per subscription UUID string, summed over the period.
    public var perShowSeconds: [String: TimeInterval] = [:]
    /// Time saved per subscription UUID string, summed over the period. Empty
    /// contributions from days recorded before per-show tracking (2026-06).
    public var perShowTimeSaved: [String: TimeInterval] = [:]
    /// Wall-clock seconds per hour of day (24 buckets), summed over the period.
    public var hourSeconds: [TimeInterval] = Array(repeating: 0, count: 24)
    /// One entry per day in the period (zero-filled), oldest first — feeds heatmaps.
    public var days: [DayStats] = []

    public var totalTimeSaved: TimeInterval {
        timeSavedVariableSpeed + timeSavedTrimSilence + timeSavedManualSkip + timeSavedAutoSkip
    }

    /// Top shows by listening time, resolved against the store's title map.
    public func topShows(titles: [String: String], limit: Int = 10) -> [(id: String, title: String, seconds: TimeInterval)] {
        perShowSeconds
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (id: $0.key, title: titles[$0.key] ?? "Unknown show", seconds: $0.value) }
    }
}

public enum StatsPeriod: Equatable {
    case last(days: Int)
    /// The current calendar week so far — Monday 00:00 up to now. Resets each
    /// Monday. Variable length (1 day on Monday … up to 7 by Sunday).
    case currentWeek
    /// The current calendar month so far — the 1st 00:00 up to now. Resets on
    /// the 1st of each month.
    case currentMonth
    /// The current calendar year so far — Jan 1 00:00 up to now. Resets on Jan 1.
    case currentYear
    case lifetime
}

// MARK: - On-disk container

private struct ListeningStatsData: Codable {
    var days: [String: DayStats] = [:]
    /// Subscription titles captured at write time, so stats survive unsubscribes.
    var showTitles: [String: String] = [:]
    /// Totals imported from the legacy `playback-stats.json` (pre-daily-bucket era).
    var legacyBaseline: PlaybackStats?
    var startedAt: Date = Date()
}

// MARK: - ListeningStatsStore

@MainActor
public final class ListeningStatsStore: ObservableObject {
    @Published public private(set) var revision: Int = 0

    private var data = ListeningStatsData()
    private var lastSavedAt: Date?
    private let calendar = Calendar.current
    private let fileURL: URL?
    private let legacyFileURL: URL?

    /// Record store for cross-device stats sync; set by AppState. nil = no sync.
    var syncDatabase: AutohopDatabase? {
        didSet { reloadRemoteStats() }
    }
    /// Other devices' day partitions (dayKey → list), summed with local buckets
    /// on every read. Never merged into `data.days` (that would double-count).
    private var remoteByDayKey: [String: [DayStats]] = [:]

    /// Reloads remote partitions from the database and refreshes the Stats view.
    /// Also the handler the sync engine calls when a remote partition arrives.
    public func reloadRemoteStats() {
        remoteByDayKey = (try? syncDatabase?.remoteStatsByDayKey()) ?? [:]
        bumpRevision()
    }

    /// This device's bucket for `key`, summed with every other device's partition.
    private func combinedDay(_ key: String) -> DayStats {
        var day = data.days[key] ?? DayStats(dayKey: key)
        for remote in remoteByDayKey[key] ?? [] { day = day.merged(with: remote) }
        return day
    }

    private func allDayKeys() -> [String] {
        Array(Set(data.days.keys).union(remoteByDayKey.keys))
    }

    // The sync database row stores the FULL day bucket, not a delta, so these writes can be
    // coalesced freely: until flushed the in-memory `data.days` is authoritative, and the next
    // flush re-writes the complete, current bucket. This avoids ~2 SQLite write transactions per
    // second during playback (addListeningTime fires every 0.5 s).
    private var pendingStatsDayKeys = Set<String>()
    private var lastStatsDayWriteAt: Date?
    private let statsDayWriteThrottle: TimeInterval = 10

    private func recordDayPending(_ day: DayStats) {
        guard syncDatabase != nil else { return }
        pendingStatsDayKeys.insert(day.dayKey)
        if let last = lastStatsDayWriteAt, Date().timeIntervalSince(last) < statsDayWriteThrottle {
            return // coalesce — flushed on the throttle window or at a lifecycle checkpoint
        }
        flushPendingStatsDays()
    }

    /// Writes every coalesced day bucket to the sync database. Called on the write throttle and at
    /// lifecycle checkpoints (pause / background / explicit save) so the sync projection is current
    /// without a write on every playback tick.
    public func flushPendingStatsDays() {
        guard let syncDatabase, !pendingStatsDayKeys.isEmpty else { return }
        for key in pendingStatsDayKeys {
            if let day = data.days[key] {
                try? syncDatabase.recordStatsDay(day)
            }
        }
        pendingStatsDayKeys.removeAll()
        lastStatsDayWriteAt = Date()
    }

    /// A day counts toward streaks once it has at least this much listening.
    public static let streakMinimumSeconds: TimeInterval = 60

    private nonisolated static func statsURL(_ name: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/\(name)")
    }

    public convenience init() {
        self.init(
            fileURL: Self.statsURL("listening-stats.json"),
            legacyFileURL: Self.statsURL("playback-stats.json")
        )
    }

    /// Custom URLs are for smoke tests; production callers use `init()`.
    public init(fileURL: URL?, legacyFileURL: URL?) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        load()
        importLegacyBaselineIfNeeded()
    }

    // MARK: - Recording

    public func addListeningTime(_ seconds: TimeInterval, speed: Double, subscriptionID: UUID, showTitle: String) {
        guard seconds > 0 else { return }
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        var day = bucket(for: now)

        day.wallClockSeconds += seconds
        day.hourSeconds[min(max(hour, 0), 23)] += seconds
        let showKey = subscriptionID.uuidString
        day.perShowSeconds[showKey, default: 0] += seconds
        if speed > 1.0 {
            // Time that would have elapsed at 1× minus time actually elapsed.
            let saved = seconds * (speed - 1.0) / speed
            day.timeSavedVariableSpeed += saved
            day.perShowTimeSaved[showKey, default: 0] += saved
        }

        data.days[day.dayKey] = day
        data.showTitles[showKey] = showTitle
        recordDayPending(day)
        bumpRevision()
        saveThrottled()
    }

    public func addManualSkipForward(_ seconds: TimeInterval, subscriptionID: UUID? = nil) {
        guard seconds > 0 else { return }
        mutateToday {
            $0.timeSavedManualSkip += seconds
            $0.manualSkipForwardCount += 1
            if let key = subscriptionID?.uuidString {
                $0.perShowTimeSaved[key, default: 0] += seconds
            }
        }
    }

    public func addAutoSkip(_ seconds: TimeInterval, subscriptionID: UUID? = nil) {
        guard seconds > 0 else { return }
        mutateToday {
            $0.timeSavedAutoSkip += seconds
            if let key = subscriptionID?.uuidString {
                $0.perShowTimeSaved[key, default: 0] += seconds
            }
        }
    }

    public func addTrimSilenceSaved(_ seconds: TimeInterval, subscriptionID: UUID? = nil) {
        guard seconds > 0 else { return }
        mutateToday {
            $0.timeSavedTrimSilence += seconds
            if let key = subscriptionID?.uuidString {
                $0.perShowTimeSaved[key, default: 0] += seconds
            }
        }
    }

    public func recordEpisodeStarted(subscriptionID: UUID, showTitle: String) {
        data.showTitles[subscriptionID.uuidString] = showTitle
        mutateToday { $0.episodesStarted += 1 }
    }

    public func recordEpisodeCompleted(subscriptionID: UUID) {
        mutateToday { $0.episodesCompleted += 1 }
    }

    /// Replaces the bucket for the day's `dayKey`. For backfill/migration tooling
    /// and smoke tests — normal recording goes through the add/record methods.
    public func importDay(_ day: DayStats) {
        data.days[day.dayKey] = day
        recordDayPending(day)
        bumpRevision()
        saveThrottled()
    }

    // MARK: - Queries

    /// Titles for resolving `perShowSeconds` keys, including unsubscribed shows.
    public var showTitles: [String: String] { data.showTitles }

    /// When stats collection first began (carried over from the legacy store if imported).
    public var startedAt: Date { data.legacyBaseline?.startedAt ?? data.startedAt }

    /// Lifetime totals in the legacy shape consumed by `StatsView`.
    public var lifetime: PlaybackStats {
        var stats = data.legacyBaseline ?? PlaybackStats(startedAt: data.startedAt)
        for key in allDayKeys() {
            let day = combinedDay(key)
            stats.totalListeningSeconds += day.wallClockSeconds
            stats.timeSavedVariableSpeed += day.timeSavedVariableSpeed
            stats.timeSavedTrimSilence += day.timeSavedTrimSilence
            stats.timeSavedManualSkip += day.timeSavedManualSkip
            stats.timeSavedAutoSkip += day.timeSavedAutoSkip
        }
        return stats
    }

    public func summary(for period: StatsPeriod) -> ListeningStatsSummary {
        let buckets: [DayStats]
        switch period {
        case .last(let count):
            buckets = recentDays(count)
        case .currentWeek:
            buckets = days(from: startOfCurrentWeek())
        case .currentMonth:
            buckets = days(from: startOfCurrentMonth())
        case .currentYear:
            buckets = days(from: startOfCurrentYear())
        case .lifetime:
            buckets = allDayKeys().sorted().map { combinedDay($0) }
        }

        var result = ListeningStatsSummary(days: buckets)
        for day in buckets {
            result.wallClockSeconds += day.wallClockSeconds
            result.timeSavedVariableSpeed += day.timeSavedVariableSpeed
            result.timeSavedTrimSilence += day.timeSavedTrimSilence
            result.timeSavedManualSkip += day.timeSavedManualSkip
            result.timeSavedAutoSkip += day.timeSavedAutoSkip
            result.episodesStarted += day.episodesStarted
            result.episodesCompleted += day.episodesCompleted
            result.manualSkipForwardCount += day.manualSkipForwardCount
            for (show, seconds) in day.perShowSeconds {
                result.perShowSeconds[show, default: 0] += seconds
            }
            for (show, seconds) in day.perShowTimeSaved {
                result.perShowTimeSaved[show, default: 0] += seconds
            }
            for hour in 0..<24 {
                result.hourSeconds[hour] += day.hourSeconds[hour]
            }
        }
        return result
    }

    /// Per-show seconds for the window of the same length immediately before
    /// `period` — feeds rank-movement badges in the Top Shows list. Returns nil
    /// for `.lifetime`, which has no previous period to compare against.
    public func previousPeriodShowSeconds(for period: StatsPeriod) -> [String: TimeInterval]? {
        var totals: [String: TimeInterval] = [:]
        switch period {
        case .lifetime:
            return nil
        case .last(let count):
            let today = calendar.startOfDay(for: Date())
            for offset in count..<(count * 2) {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                for (show, seconds) in combinedDay(dayKey(for: date)).perShowSeconds {
                    totals[show, default: 0] += seconds
                }
            }
        case .currentWeek:
            // Compare against the previous full Monday–Sunday week.
            guard let lastMonday = calendar.date(byAdding: .day, value: -7, to: startOfCurrentWeek()) else { return nil }
            accumulate(&totals, from: lastMonday, upTo: startOfCurrentWeek())
        case .currentMonth:
            // Compare against the previous full calendar month.
            let thisMonth = startOfCurrentMonth()
            guard let prevMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) else { return nil }
            accumulate(&totals, from: prevMonth, upTo: thisMonth)
        case .currentYear:
            // Compare against the previous full calendar year.
            let thisYear = startOfCurrentYear()
            guard let prevYear = calendar.date(byAdding: .year, value: -1, to: thisYear) else { return nil }
            accumulate(&totals, from: prevYear, upTo: thisYear)
        }
        return totals
    }

    /// Adds every day's per-show seconds in the half-open range [start, end).
    private func accumulate(_ totals: inout [String: TimeInterval], from start: Date, upTo end: Date) {
        var cursor = calendar.startOfDay(for: start)
        let stop = calendar.startOfDay(for: end)
        while cursor < stop {
            for (show, seconds) in combinedDay(dayKey(for: cursor)).perShowSeconds {
                totals[show, default: 0] += seconds
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
    }

    /// Consecutive days with listening ending today (or yesterday, if today is
    /// still empty — an unfinished today doesn't break the streak).
    public var currentStreakDays: Int {
        var cursor = calendar.startOfDay(for: Date())
        var streak = 0
        if !qualifies(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        while qualifies(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    public var longestStreakDays: Int {
        let qualifyingKeys = Set(
            allDayKeys().filter { combinedDay($0).wallClockSeconds >= Self.streakMinimumSeconds }
        )
        guard !qualifyingKeys.isEmpty else { return 0 }

        var longest = 0
        for key in qualifyingKeys {
            guard let date = dayDate(from: key) else { continue }
            // Only walk forward from streak starts (no qualifying day before this one).
            if let previous = calendar.date(byAdding: .day, value: -1, to: date),
               qualifyingKeys.contains(dayKey(for: previous)) {
                continue
            }
            var length = 0
            var cursor = date
            while qualifyingKeys.contains(dayKey(for: cursor)) {
                length += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            longest = max(longest, length)
        }
        return longest
    }

    // MARK: - Persistence

    public func save() {
        // A full save is a real persistence checkpoint (pause / background / shutdown) — make sure
        // any coalesced stats-day writes reach the sync database too.
        flushPendingStatsDays()
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: url, options: [.atomic])
            lastSavedAt = Date()
        } catch {
            AppLogger.shared.warning("stats.saveFailed", "Could not save listening stats", metadata: [
                "error": String(describing: error)
            ])
        }
    }

    // MARK: - Private

    private func mutateToday(_ change: (inout DayStats) -> Void) {
        var day = bucket(for: Date())
        change(&day)
        data.days[day.dayKey] = day
        recordDayPending(day)
        bumpRevision()
        saveThrottled()
    }

    private func bucket(for date: Date) -> DayStats {
        let key = dayKey(for: date)
        return data.days[key] ?? DayStats(dayKey: key)
    }

    /// Day buckets for the last `count` days ending today, zero-filled, oldest first.
    private func recentDays(_ count: Int) -> [DayStats] {
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return combinedDay(dayKey(for: date))
        }
    }

    /// Monday 00:00 of the week containing `date`, independent of locale
    /// (the app treats Monday as the first day of the week for Stats).
    func startOfWeek(for date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        // Gregorian weekday: Sun=1 … Sat=7, so Monday=2.
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    }

    /// Monday 00:00 of the current week.
    func startOfCurrentWeek() -> Date { startOfWeek(for: Date()) }

    /// The 1st 00:00 of the current month.
    func startOfCurrentMonth() -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))
            ?? calendar.startOfDay(for: Date())
    }

    /// Jan 1 00:00 of the current year.
    func startOfCurrentYear() -> Date {
        calendar.date(from: calendar.dateComponents([.year], from: Date()))
            ?? calendar.startOfDay(for: Date())
    }

    /// Day buckets from `start` (start-of-day) through today, oldest first.
    private func days(from start: Date) -> [DayStats] {
        let first = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: Date())
        let span = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        return (0..<max(span, 1)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            return combinedDay(dayKey(for: date))
        }
    }

    private func qualifies(_ date: Date) -> Bool {
        combinedDay(dayKey(for: date)).wallClockSeconds >= Self.streakMinimumSeconds
    }

    private func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func dayDate(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func bumpRevision() {
        revision &+= 1
    }

    private func saveThrottled() {
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 30 { return }
        save()
    }

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let encoded = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(ListeningStatsData.self, from: encoded)
        else { return }
        data = loaded
    }

    /// One-time import of the legacy lifetime totals, so "time saved" doesn't reset
    /// to zero for existing users. The legacy file is left in place untouched.
    private func importLegacyBaselineIfNeeded() {
        guard data.legacyBaseline == nil, data.days.isEmpty,
              let legacyURL = legacyFileURL,
              FileManager.default.fileExists(atPath: legacyURL.path),
              let encoded = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(PlaybackStats.self, from: encoded)
        else { return }
        data.legacyBaseline = legacy
        data.startedAt = legacy.startedAt
        save()
        AppLogger.shared.info("stats.legacyImport", "Imported legacy playback stats as lifetime baseline", metadata: [
            "totalListeningSeconds": "\(Int(legacy.totalListeningSeconds))"
        ])
    }
}
