import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// AI CONTEXT — Persistence/ListeningStatsStore.swift
// Data layer for the Stats page. Buckets all listening activity per LOCAL
// calendar day in DayStats records (wall-clock seconds, 24-hour histogram,
// per-show seconds and per-show time saved keyed by a canonical feed digest with
// a title map that survives unsubscribes/resubscribes, per-show episode
// start/completion counts and durable episode outcomes,
// four time-saved categories, global episodes started/completed, manual skip
// count, and bytes/episodes downloaded (forward-only from June 2026)). Download
// settlement is persisted immediately; rendered playback saves are throttled.
// Persisted to listening-stats.json using a checksummed generation envelope;
// every day has durable revision/hash metadata mirrored in SQLite and CloudKit.
// Startup reconciles the file and SQLite deterministically, and own CloudKit
// partitions can restore absent local state. JSON backup/import and CSV export
// are exposed by StatsView, alongside persisted save/sync/recovery health.
// Ordinary saves are throttled to
// 30 s during playback and force-flushed on pause / sleep-timer or sleep-schedule
// pause / background by PlaybackCheckpointWorkflow. Day-bucket writes into the sync
// database are separately coalesced on a 30 s throttle (recordDayPending /
// flushPendingStatsDays below); SwiftUI revision publication from continuous
// playback is separately coalesced to 10 seconds so rendered-buffer callbacks do
// not invalidate every Stats consumer. A pending-revision bit prevents the first
// interval's immediate persistence checkpoint from publishing it twice.
// Discrete events still publish immediately. Identity-v2 stores the active
// partition ID in a ThisDeviceOnly Keychain item. Pre-cutover buckets become an
// unsynced inherited base, preventing backup-restored devices from duplicating
// their common history when each receives a fresh installation identity.
// DOWNSTREAM, CloudSyncEngine holds stats/history-
// only CloudKit pushes on a further ~60 s slow-lane debounce, flushed at the
// same lifecycle checkpoints through SyncCoordinator — always AFTER this
// store's save()/flush so the scan sees current rows.
// Diagnostics are rate-limited summaries: routine playback batching is emitted
// at most every five minutes, while lifecycle checkpoints, failures, and slow
// writes remain immediately visible. This keeps diagnostic I/O out of playback.
// stats_sync_state. These low-frequency breadcrumbs help correlate DayStats
// CloudKit conflicts and playback pressure without logging every rendered interval.
// Legacy totals from playback-stats.json are imported once as `legacyBaseline`
// with a cutover timestamp. They are included in any selected period that fully
// contains the known legacy interval, without fabricating daily attribution.
// PERIODS: summary(for: StatsPeriod) aggregates a window; StatsPeriod includes
// the current calendar week/month/year, .lifetime, AND the previous concluded
// week/month/year (.previousWeek/.previousMonth/.previousYear) — the latter
// power the Stats "This/Last" toggle and the Listening Recap notifications,
// computed via the bounded days(from:upTo:) helper. previousPeriodShowSeconds
// handles the new cases too (a "Last" view compares against the period before it).
// QUERY API (used by StatsView): summary(for: .last(days:)/.lifetime),
// lifetime (legacy PlaybackStats shape), currentStreakDays/longestStreakDays
// (a day counts at ≥ 60 s), previousPeriodShowSeconds (rank-movement badges).
// FED BY PlaybackCoordinator/HistoryStatsCoordinator: rendered playback intervals,
// skip/trim callbacks, PlaybackStartWorkflow, and EpisodeCompletionWorkflow.

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

/// Stable podcast identity used by Stats. Subscription UUIDs describe one
/// installation's subscription row and change after unsubscribe/resubscribe;
/// this privacy-safe digest of the canonical feed URL does not.
public enum StatsShowIdentity {
    public static func key(for feedURL: URL) -> String {
        let canonical = canonicalFeedURL(feedURL)
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "feed:\(digest)"
    }

    public static func matches(_ statsKey: String, subscription: Subscription) -> Bool {
        statsKey == subscription.id.uuidString || statsKey == key(for: subscription.feedURL)
    }

    private static func canonicalFeedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.scheme == "http", components.port == 80 { components.port = nil }
        if components.scheme == "https", components.port == 443 { components.port = nil }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

/// Immutable episode-resolution evidence retained independently of the capped,
/// mutable resume-history projection. The dictionary key in DayStats is the
/// stable episode identity, making repeated disposition callbacks idempotent.
public struct DurableEpisodeOutcome: Codable, Equatable, Sendable {
    public var showID: String
    public var occurredAt: Date
    public var completionKind: CompletionKind
    public var positionSeconds: TimeInterval?
    public var durationSeconds: TimeInterval?

    public init(
        showID: String,
        occurredAt: Date,
        completionKind: CompletionKind,
        positionSeconds: TimeInterval?,
        durationSeconds: TimeInterval?
    ) {
        self.showID = showID
        self.occurredAt = occurredAt
        self.completionKind = completionKind
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }

    public var completionFraction: Double? {
        guard let positionSeconds, let durationSeconds, durationSeconds > 0 else { return nil }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }
}

// MARK: - DayStats (one bucket per calendar day)

/// All listening activity for one local calendar day. A populated record is a few
/// hundred bytes, so lifetime retention is cheap and any period query (30d/90d/1y/
/// lifetime) is just a sum over buckets.
public struct DayStats: Codable, Equatable, Sendable {
    /// Local calendar day, "yyyy-MM-dd".
    public var dayKey: String
    /// Real time spent listening (wall clock, unaffected by speed/trim).
    public var wallClockSeconds: TimeInterval
    /// Wall-clock seconds per hour of day (24 buckets) — feeds the listening clock.
    public var hourSeconds: [TimeInterval]
    /// Wall-clock seconds per show. New writes use `StatsShowIdentity`; legacy
    /// buckets may retain `Subscription.id.uuidString` until catalogue migration.
    public var perShowSeconds: [String: TimeInterval]
    /// Total time saved (all four categories) per subscription, keyed by
    /// `StatsShowIdentity`. Added 2026-06; days recorded before then
    /// have an empty map, so per-period sums can undercount the category totals.
    public var perShowTimeSaved: [String: TimeInterval]
    /// Episode starts/completions attributed to the same stable show key
    /// as perShowSeconds. Added 2026-08; older buckets decode as empty maps.
    public var perShowEpisodesStarted: [String: Int]
    public var perShowEpisodesCompleted: [String: Int]
    public var timeSavedVariableSpeed: TimeInterval
    public var timeSavedTrimSilence: TimeInterval
    public var timeSavedManualSkip: TimeInterval
    public var timeSavedAutoSkip: TimeInterval
    public var episodesStarted: Int
    public var episodesCompleted: Int
    public var manualSkipForwardCount: Int
    /// Bytes downloaded on this day (sum of completed episode download sizes).
    /// Forward-only: tracking began June 2026, so days before then are 0 and
    /// any period sum reflects traffic since this build, not all-time history.
    public var bytesDownloaded: Int64
    /// Number of episodes whose download completed on this day — pairs with
    /// `bytesDownloaded` for the "N episodes · avg size" stat line.
    public var episodesDownloaded: Int
    /// Title snapshot for the shows in `perShowSeconds`, keyed by subscription
    /// identity. Synced with the day so another device can label shows it has
    /// never subscribed to (otherwise remote-only shows render as "Unknown show").
    /// Local-only buckets normally leave this empty — it is populated when the day
    /// is written for sync (see `flushPendingStatsDays`).
    public var showTitles: [String: String]
    /// Idempotent episode-resolution facts, added in September 2026. Unlike
    /// ListeningHistoryEntry these are not pruned and are not replaced by a
    /// newer resume-position snapshot.
    public var episodeOutcomes: [String: DurableEpisodeOutcome]

    public init(
        dayKey: String,
        wallClockSeconds: TimeInterval = 0,
        hourSeconds: [TimeInterval] = Array(repeating: 0, count: 24),
        perShowSeconds: [String: TimeInterval] = [:],
        perShowTimeSaved: [String: TimeInterval] = [:],
        perShowEpisodesStarted: [String: Int] = [:],
        perShowEpisodesCompleted: [String: Int] = [:],
        timeSavedVariableSpeed: TimeInterval = 0,
        timeSavedTrimSilence: TimeInterval = 0,
        timeSavedManualSkip: TimeInterval = 0,
        timeSavedAutoSkip: TimeInterval = 0,
        episodesStarted: Int = 0,
        episodesCompleted: Int = 0,
        manualSkipForwardCount: Int = 0,
        bytesDownloaded: Int64 = 0,
        episodesDownloaded: Int = 0,
        showTitles: [String: String] = [:],
        episodeOutcomes: [String: DurableEpisodeOutcome] = [:]
    ) {
        self.dayKey = dayKey
        self.wallClockSeconds = wallClockSeconds
        self.hourSeconds = hourSeconds
        self.perShowSeconds = perShowSeconds
        self.perShowTimeSaved = perShowTimeSaved
        self.perShowEpisodesStarted = perShowEpisodesStarted
        self.perShowEpisodesCompleted = perShowEpisodesCompleted
        self.timeSavedVariableSpeed = timeSavedVariableSpeed
        self.timeSavedTrimSilence = timeSavedTrimSilence
        self.timeSavedManualSkip = timeSavedManualSkip
        self.timeSavedAutoSkip = timeSavedAutoSkip
        self.episodesStarted = episodesStarted
        self.episodesCompleted = episodesCompleted
        self.manualSkipForwardCount = manualSkipForwardCount
        self.bytesDownloaded = bytesDownloaded
        self.episodesDownloaded = episodesDownloaded
        self.showTitles = showTitles
        self.episodeOutcomes = episodeOutcomes
    }

    public var totalTimeSaved: TimeInterval {
        timeSavedVariableSpeed + timeSavedTrimSilence + timeSavedManualSkip + timeSavedAutoSkip
    }

    /// Sums this day's buckets with another device's same-day partition — the
    /// core of additive cross-device stats (SYNC_DESIGN.md step 5b). NEVER
    /// last-write-wins: each device contributes its own listening for the day.
    public func merged(with other: DayStats) -> DayStats {
        var r = self
        let duplicateNaturalCompletions = Set(episodeOutcomes.keys)
            .intersection(other.episodeOutcomes.keys)
            .compactMap { key -> String? in
                guard episodeOutcomes[key]?.completionKind == .finishedNaturally,
                      other.episodeOutcomes[key]?.completionKind == .finishedNaturally
                else { return nil }
                return episodeOutcomes[key]?.showID
            }
        r.wallClockSeconds += other.wallClockSeconds
        for h in 0..<24 { r.hourSeconds[h] += other.hourSeconds[h] }
        for (k, v) in other.perShowSeconds { r.perShowSeconds[k, default: 0] += v }
        for (k, v) in other.perShowTimeSaved { r.perShowTimeSaved[k, default: 0] += v }
        for (k, v) in other.perShowEpisodesStarted { r.perShowEpisodesStarted[k, default: 0] += v }
        for (k, v) in other.perShowEpisodesCompleted { r.perShowEpisodesCompleted[k, default: 0] += v }
        r.timeSavedVariableSpeed += other.timeSavedVariableSpeed
        r.timeSavedTrimSilence += other.timeSavedTrimSilence
        r.timeSavedManualSkip += other.timeSavedManualSkip
        r.timeSavedAutoSkip += other.timeSavedAutoSkip
        r.episodesStarted += other.episodesStarted
        r.episodesCompleted += other.episodesCompleted
        r.episodesCompleted = max(0, r.episodesCompleted - duplicateNaturalCompletions.count)
        for showID in duplicateNaturalCompletions {
            r.perShowEpisodesCompleted[showID, default: 0] = max(
                0,
                r.perShowEpisodesCompleted[showID, default: 0] - 1
            )
        }
        r.manualSkipForwardCount += other.manualSkipForwardCount
        r.bytesDownloaded += other.bytesDownloaded
        r.episodesDownloaded += other.episodesDownloaded
        // Combine label snapshots; this device's own labels win on conflict.
        r.showTitles.merge(other.showTitles) { mine, _ in mine }
        for (key, outcome) in other.episodeOutcomes {
            if let existing = r.episodeOutcomes[key] {
                r.episodeOutcomes[key] = Self.preferredOutcome(existing, outcome)
            } else {
                r.episodeOutcomes[key] = outcome
            }
        }
        return r
    }

    static func preferredOutcome(
        _ lhs: DurableEpisodeOutcome,
        _ rhs: DurableEpisodeOutcome
    ) -> DurableEpisodeOutcome {
        let lhsRank = outcomeRank(lhs.completionKind)
        let rhsRank = outcomeRank(rhs.completionKind)
        if lhsRank != rhsRank { return lhsRank > rhsRank ? lhs : rhs }
        // Same-strength duplicate callbacks keep the original resolution time;
        // a retry must not move an outcome into a later reporting period.
        return lhs.occurredAt <= rhs.occurredAt ? lhs : rhs
    }

    private static func outcomeRank(_ kind: CompletionKind) -> Int {
        switch kind {
        case .finishedNaturally: return 4
        case .markedPlayed: return 3
        case .manuallyArchived: return 2
        case .autoArchived: return 1
        }
    }

    // MARK: Codable — graceful decoding of day buckets saved before perShowTimeSaved existed

    enum CodingKeys: String, CodingKey {
        case dayKey, wallClockSeconds, hourSeconds, perShowSeconds, perShowTimeSaved
        case perShowEpisodesStarted, perShowEpisodesCompleted
        case timeSavedVariableSpeed, timeSavedTrimSilence, timeSavedManualSkip, timeSavedAutoSkip
        case episodesStarted, episodesCompleted, manualSkipForwardCount
        case bytesDownloaded, episodesDownloaded, showTitles, episodeOutcomes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        wallClockSeconds = try c.decode(TimeInterval.self, forKey: .wallClockSeconds)
        // Normalize to exactly 24 buckets. Persisted data is normally 24, but a
        // record decoded from CloudKit (another device, older or corrupt data)
        // can be any length; merged(with:) and the period aggregation index
        // 0..<24 unconditionally, so a short array here would crash. Pad with
        // zeros and truncate any excess.
        let decodedHours = try c.decode([TimeInterval].self, forKey: .hourSeconds)
        if decodedHours.count == 24 {
            hourSeconds = decodedHours
        } else {
            var normalized = Array(decodedHours.prefix(24))
            if normalized.count < 24 {
                normalized.append(contentsOf: Array(repeating: 0, count: 24 - normalized.count))
            }
            hourSeconds = normalized
        }
        perShowSeconds = try c.decode([String: TimeInterval].self, forKey: .perShowSeconds)
        // Absent in JSON written before per-show time-saved tracking (2026-06).
        perShowTimeSaved = try c.decodeIfPresent([String: TimeInterval].self, forKey: .perShowTimeSaved) ?? [:]
        perShowEpisodesStarted = try c.decodeIfPresent([String: Int].self, forKey: .perShowEpisodesStarted) ?? [:]
        perShowEpisodesCompleted = try c.decodeIfPresent([String: Int].self, forKey: .perShowEpisodesCompleted) ?? [:]
        timeSavedVariableSpeed = try c.decode(TimeInterval.self, forKey: .timeSavedVariableSpeed)
        timeSavedTrimSilence = try c.decode(TimeInterval.self, forKey: .timeSavedTrimSilence)
        timeSavedManualSkip = try c.decode(TimeInterval.self, forKey: .timeSavedManualSkip)
        timeSavedAutoSkip = try c.decode(TimeInterval.self, forKey: .timeSavedAutoSkip)
        episodesStarted = try c.decode(Int.self, forKey: .episodesStarted)
        episodesCompleted = try c.decode(Int.self, forKey: .episodesCompleted)
        manualSkipForwardCount = try c.decode(Int.self, forKey: .manualSkipForwardCount)
        // Absent in JSON written before download-data tracking (2026-06).
        bytesDownloaded = try c.decodeIfPresent(Int64.self, forKey: .bytesDownloaded) ?? 0
        episodesDownloaded = try c.decodeIfPresent(Int.self, forKey: .episodesDownloaded) ?? 0
        // Absent in local buckets and in day records synced before title snapshots.
        showTitles = try c.decodeIfPresent([String: String].self, forKey: .showTitles) ?? [:]
        episodeOutcomes = try c.decodeIfPresent([String: DurableEpisodeOutcome].self, forKey: .episodeOutcomes) ?? [:]
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
    /// Bytes downloaded over the period (forward-only, since June 2026).
    public var bytesDownloaded: Int64 = 0
    /// Episodes downloaded over the period — pairs with `bytesDownloaded`.
    public var episodesDownloaded: Int = 0
    /// Wall-clock seconds per stable show identity, summed over the period.
    public var perShowSeconds: [String: TimeInterval] = [:]
    /// Time saved per stable show identity, summed over the period. Empty
    /// contributions from days recorded before per-show tracking (2026-06).
    public var perShowTimeSaved: [String: TimeInterval] = [:]
    /// Durable per-show outcome counts. Empty contributions identify buckets
    /// written before attribution was introduced and are recovered in StatsView
    /// from retained episode/history evidence where possible.
    public var perShowEpisodesStarted: [String: Int] = [:]
    public var perShowEpisodesCompleted: [String: Int] = [:]
    /// Wall-clock seconds per hour of day (24 buckets), summed over the period.
    public var hourSeconds: [TimeInterval] = Array(repeating: 0, count: 24)
    /// One entry per day in the period (zero-filled), oldest first — feeds heatmaps.
    public var days: [DayStats] = []
    /// Stable episode outcome facts within this period, keyed by episode
    /// identity. These survive the bounded resume-history store.
    public var episodeOutcomes: [String: DurableEpisodeOutcome] = [:]
    /// Lifetime listening imported from the pre-day-bucket store. Included in
    /// `wallClockSeconds`, but unavailable to date/hour/show visual breakdowns.
    public var legacyUnbucketedListeningSeconds: TimeInterval = 0
    /// True when the selected range intersects only part of the unbucketed
    /// legacy interval. The legacy total is deliberately excluded because it
    /// cannot be apportioned accurately, and the UI must disclose that.
    public var excludesPartiallyOverlappingLegacyBaseline = false
    /// Metrics introduced after Stats launched. Any boundary later than the
    /// selected range start means that metric is only partially covered.
    public var coverageNotices: [StatsCoverageNotice] = []

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

public struct StatsCoverageNotice: Equatable, Identifiable {
    public enum Metric: String, Equatable {
        case perShowTimeSaved = "Per-show time saved"
        case downloads = "Download data"
        case perShowOutcomes = "Per-show outcomes"
        case durableOutcomes = "Durable outcome history"
    }

    public var metric: Metric
    public var trackedSince: Date
    public var id: String { metric.rawValue }
}

public enum StatsPeriod: Equatable, Hashable {
    case last(days: Int)
    /// The current calendar week so far — Monday 00:00 up to now. Resets each
    /// Monday. Variable length (1 day on Monday … up to 7 by Sunday).
    case currentWeek
    /// The current calendar month so far — the 1st 00:00 up to now. Resets on
    /// the 1st of each month.
    case currentMonth
    /// The current calendar year so far — Jan 1 00:00 up to now. Resets on Jan 1.
    case currentYear
    /// The previous full calendar week (the Monday–Sunday before the current one).
    /// Powers the Stats "Last" toggle and the weekly Listening Recap.
    case previousWeek
    /// The previous full calendar month.
    case previousMonth
    /// The previous full calendar year.
    case previousYear
    case lifetime
}

public struct StatsHealthSnapshot: Equatable {
    public var recordedDayCount: Int
    public var remoteDeviceCount: Int
    public var pendingDayCount: Int
    public var lastLocalSave: Date?
    public var lastSuccessfulSync: Date?
    public var recoveryStatus: String
}

// MARK: - On-disk container

private struct ListeningStatsData: Codable {
    var days: [String: DayStats] = [:]
    /// Revision of each locally-authored day within `storageGenerationID`.
    /// Added in the reconciliation format; old files default to zero and are
    /// backfilled on their first database attachment.
    var dayRevisions: [String: UInt64] = [:]
    /// Read-only historical base inherited when the old backup-restorable
    /// UserDefaults device ID is retired. It remains visible locally but is not
    /// uploaded under the new identity, preventing two restored devices from
    /// both re-uploading the same pre-cutover totals.
    var inheritedDays: [String: DayStats] = [:]
    var lineageDeviceIDs: Set<String> = []
    var retiredGenerationIDs: Set<String> = []
    var importedArchiveIDs: Set<String> = []
    /// Maps historical subscription UUID keys to canonical feed identities.
    /// Populated from the live subscription catalogue and retained so future
    /// skips/completions continue using the canonical key.
    var canonicalShowIDs: [String: String] = [:]
    var lastRecoveryAt: Date?
    var lastRecoveryMessage: String?
    /// Subscription titles captured at write time, so stats survive unsubscribes.
    var showTitles: [String: String] = [:]
    /// Totals imported from the legacy `playback-stats.json` (pre-daily-bucket era).
    var legacyBaseline: PlaybackStats?
    /// End of the unbucketed legacy interval. Optional for files written before
    /// this marker existed; those infer cutover from the earliest local bucket.
    var legacyBaselineEndedAt: Date?
    var startedAt: Date = Date()

    var isSemanticallyValid: Bool {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              legacyBaselineEndedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              lastRecoveryAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              legacyBaseline.map(Self.isValid) ?? true else { return false }
        return days.allSatisfy { key, day in
            key == day.dayKey && day.isSemanticallyValid
        } && inheritedDays.allSatisfy { key, day in
            key == day.dayKey && day.isSemanticallyValid
        }
    }

    private enum CodingKeys: String, CodingKey {
        case days, dayRevisions, inheritedDays, lineageDeviceIDs, retiredGenerationIDs, importedArchiveIDs
        case canonicalShowIDs
        case lastRecoveryAt, lastRecoveryMessage
        case showTitles, legacyBaseline, legacyBaselineEndedAt, startedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `days` is the format discriminator. Requiring it prevents a damaged
        // outer integrity envelope from being misread as an empty legacy payload.
        days = try c.decode([String: DayStats].self, forKey: .days)
        dayRevisions = try c.decodeIfPresent([String: UInt64].self, forKey: .dayRevisions) ?? [:]
        inheritedDays = try c.decodeIfPresent([String: DayStats].self, forKey: .inheritedDays) ?? [:]
        lineageDeviceIDs = try c.decodeIfPresent(Set<String>.self, forKey: .lineageDeviceIDs) ?? []
        retiredGenerationIDs = try c.decodeIfPresent(Set<String>.self, forKey: .retiredGenerationIDs) ?? []
        importedArchiveIDs = try c.decodeIfPresent(Set<String>.self, forKey: .importedArchiveIDs) ?? []
        canonicalShowIDs = try c.decodeIfPresent([String: String].self, forKey: .canonicalShowIDs) ?? [:]
        lastRecoveryAt = try c.decodeIfPresent(Date.self, forKey: .lastRecoveryAt)
        lastRecoveryMessage = try c.decodeIfPresent(String.self, forKey: .lastRecoveryMessage)
        showTitles = try c.decodeIfPresent([String: String].self, forKey: .showTitles) ?? [:]
        legacyBaseline = try c.decodeIfPresent(PlaybackStats.self, forKey: .legacyBaseline)
        legacyBaselineEndedAt = try c.decodeIfPresent(Date.self, forKey: .legacyBaselineEndedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    }

    static func isValid(_ stats: PlaybackStats) -> Bool {
        let seconds = [
            stats.totalListeningSeconds,
            stats.timeSavedVariableSpeed,
            stats.timeSavedTrimSilence,
            stats.timeSavedManualSkip,
            stats.timeSavedAutoSkip
        ]
        return seconds.allSatisfy { $0.isFinite && $0 >= 0 }
            && stats.startedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

private struct ListeningStatsArchive: Codable {
    static let schemaVersion = 1
    var schemaVersion: Int
    var archiveID: String
    var exportedAt: Date
    var days: [String: DayStats]
    var showTitles: [String: String]
    var coveredDeviceIDs: Set<String>
    var coveredGenerationIDs: Set<String>
    var legacyBaseline: PlaybackStats?
    var legacyBaselineEndedAt: Date?
    var startedAt: Date
}

private extension DayStats {
    mutating func remapShow(from oldKey: String, to newKey: String) -> Bool {
        guard oldKey != newKey else { return false }
        var changed = false
        func moveSeconds(_ map: inout [String: TimeInterval]) {
            guard let value = map.removeValue(forKey: oldKey) else { return }
            map[newKey, default: 0] += value
            changed = true
        }
        func moveCounts(_ map: inout [String: Int]) {
            guard let value = map.removeValue(forKey: oldKey) else { return }
            map[newKey, default: 0] += value
            changed = true
        }
        moveSeconds(&perShowSeconds)
        moveSeconds(&perShowTimeSaved)
        moveCounts(&perShowEpisodesStarted)
        moveCounts(&perShowEpisodesCompleted)
        if let title = showTitles.removeValue(forKey: oldKey) {
            if showTitles[newKey] == nil { showTitles[newKey] = title }
            changed = true
        }
        for key in Array(episodeOutcomes.keys) where episodeOutcomes[key]?.showID == oldKey {
            guard var outcome = episodeOutcomes.removeValue(forKey: key) else { continue }
            outcome.showID = newKey
            let suffix = key.hasPrefix("\(oldKey)|")
                ? String(key.dropFirst(oldKey.count))
                : "|legacy:\(key)"
            let remappedKey = newKey + suffix
            if let existing = episodeOutcomes[remappedKey] {
                episodeOutcomes[remappedKey] = Self.preferredOutcome(existing, outcome)
            } else {
                episodeOutcomes[remappedKey] = outcome
            }
            changed = true
        }
        return changed
    }

    var isSemanticallyValid: Bool {
        let seconds = [wallClockSeconds, timeSavedVariableSpeed,
                       timeSavedTrimSilence, timeSavedManualSkip,
                       timeSavedAutoSkip]
        return !dayKey.isEmpty
            && hourSeconds.count == 24
            && seconds.allSatisfy { $0.isFinite && $0 >= 0 }
            && hourSeconds.allSatisfy { $0.isFinite && $0 >= 0 }
            && perShowSeconds.values.allSatisfy { $0.isFinite && $0 >= 0 }
            && perShowTimeSaved.values.allSatisfy { $0.isFinite && $0 >= 0 }
            && perShowEpisodesStarted.values.allSatisfy { $0 >= 0 }
            && perShowEpisodesCompleted.values.allSatisfy { $0 >= 0 }
            && episodesStarted >= 0
            && episodesCompleted >= 0
            && manualSkipForwardCount >= 0
            && bytesDownloaded >= 0
            && episodesDownloaded >= 0
            && episodeOutcomes.values.allSatisfy {
                !$0.showID.isEmpty
                    && $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
                    && ($0.positionSeconds.map { $0.isFinite && $0 >= 0 } ?? true)
                    && ($0.durationSeconds.map { $0.isFinite && $0 >= 0 } ?? true)
            }
    }
}

// MARK: - ListeningStatsStore

@MainActor
public final class ListeningStatsStore: ObservableObject {
    @Published public private(set) var revision: Int = 0
    private(set) var persistenceState: DurableStoreLoadState = .absent

    private var data = ListeningStatsData()
    /// Memoized period summaries (see `summary(for:)`), invalidated when
    /// `summaryCacheRevision` no longer matches the published `revision` or the
    /// local day rolls over (period windows are date-relative).
    private var summaryCache: [StatsPeriod: ListeningStatsSummary] = [:]
    private var summaryCacheRevision = -1
    private var summaryCacheDayKey = ""
    private var lastSavedAt: Date?
    /// Playback updates the authoritative in-memory bucket every 0.5 s, but Stats
    /// UI consumers do not need 2 Hz invalidations. Publish at most once per 10 s;
    /// explicit mutations and lifecycle save checkpoints force the final revision.
    private var lastPlaybackRevisionAt: Date?
    /// True only when a playback tick changed data after the last published
    /// playback revision. Prevents an immediate saveThrottled() checkpoint from
    /// publishing the same first tick twice.
    private var playbackRevisionPending = false
    private let playbackRevisionInterval: TimeInterval = 10
    /// Re-read for every attribution/query so a long-running playback process
    /// follows time-zone and calendar changes without requiring a relaunch.
    private let calendarProvider: () -> Calendar
    private var calendar: Calendar { calendarProvider() }
    private var significantTimeObservers: [NSObjectProtocol] = []
    private let fileURL: URL?
    private let legacyFileURL: URL?
    private let protectedDataAvailable: () -> Bool
    private var protectedDataObserver: NSObjectProtocol?
    private var storageGenerationID = UUID().uuidString
    private var storageRevision: UInt64 = 0
    private static let storageSchemaVersion = 1

    /// Record store for cross-device stats sync; connected by
    /// HistoryStatsCoordinator. nil = no sync.
    var syncDatabase: AutohopDatabase? {
        didSet { reconcileWithSyncDatabase() }
    }

    /// Library-consumer wiring (tvOS, 2026-07-11): AutohopDatabase is internal
    /// to AutohopCore, so external targets (the TV app imports AutohopCore as a
    /// library) can't assign `syncDatabase` directly — this pulls it from the
    /// SubscriptionStore facade instead, mirroring CloudSyncEngine's public
    /// convenience init. iOS (which compiles these sources into the app target)
    /// keeps assigning `syncDatabase` directly; both paths are equivalent.
    public func attachSyncDatabase(from store: SubscriptionStore) {
        syncDatabase = store.database
    }
    /// Other devices' day partitions (dayKey → list), summed with local buckets
    /// on every read. Never merged into `data.days` (that would double-count).
    private var remoteByDayKey: [String: [DayStats]] = [:]

    /// Reloads remote partitions from the database and refreshes the Stats view.
    /// Also the handler the sync engine calls when a remote partition arrives.
    public func reloadRemoteStats() {
        reconcileWithSyncDatabase()
    }

    /// This device's bucket for `key`, summed with every other device's partition.
    private func combinedDay(_ key: String) -> DayStats {
        var day = data.inheritedDays[key] ?? DayStats(dayKey: key)
        if let local = data.days[key] { day = day.merged(with: local) }
        for remote in remoteByDayKey[key] ?? [] { day = day.merged(with: remote) }
        return day
    }

    private func allDayKeys() -> [String] {
        Array(Set(data.days.keys).union(data.inheritedDays.keys).union(remoteByDayKey.keys))
    }

    // The sync database row stores the FULL day bucket, not a delta, so these writes can be
    // coalesced freely: until flushed the in-memory `data.days` is authoritative, and the next
    // flush re-writes the complete, current bucket. This avoids ~2 SQLite write transactions per
    // second during playback (addListeningTime fires every 0.5 s).
    private var pendingStatsDayKeys = Set<String>()
    private var lastStatsDayWriteAt: Date?
    private let statsDayWriteThrottle: TimeInterval = 30
    private let routineDiagnosticInterval: TimeInterval = 5 * 60
    private var lastPendingDiagnosticAt: Date?
    private var lastFlushDiagnosticAt: Date?

    private func recordDayPending(
        _ day: DayStats,
        allowImmediateFlush: Bool = true
    ) {
        guard persistenceState.allowsPersistence else { return }
        guard syncDatabase != nil else { return }
        let now = Date()
        let inserted = pendingStatsDayKeys.insert(day.dayKey).inserted
        let secondsSinceLastFlush = lastStatsDayWriteAt.map { now.timeIntervalSince($0) }
        let throttled = secondsSinceLastFlush.map { $0 < statsDayWriteThrottle } ?? false
        if lastPendingDiagnosticAt.map({ now.timeIntervalSince($0) >= routineDiagnosticInterval }) ?? true {
            lastPendingDiagnosticAt = now
            AppLogger.shared.info("stats.pendingMarked", "Marked listening stats day pending for sync", metadata: [
                "dayKey": day.dayKey,
                "inserted": "\(inserted)",
                "pendingDayCount": "\(pendingStatsDayKeys.count)",
                "throttled": "\(throttled)",
                "secondsSinceLastFlush": secondsSinceLastFlush.map { String(format: "%.1f", $0) } ?? "none",
                "wallClockSeconds": "\(Int(day.wallClockSeconds.rounded()))",
                "showCount": "\(day.perShowSeconds.count)"
            ])
        }
        if throttled || !allowImmediateFlush {
            return // coalesce — flushed on the throttle window or at a lifecycle checkpoint
        }
        flushPendingStatsDays(reason: "throttle")
    }

    /// Writes every coalesced day bucket to the sync database. Called on the write throttle and at
    /// lifecycle checkpoints (pause / background / explicit save) so the sync projection is current
    /// without a write on every playback tick.
    public func flushPendingStatsDays(reason: String = "manual") {
        guard let syncDatabase, !pendingStatsDayKeys.isEmpty else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let pendingBefore = pendingStatsDayKeys
        var writtenKeys: [String] = []
        // Only drop keys that actually wrote. Clearing a key whose write failed
        // would mean that day never gets re-attempted and silently never syncs.
        var failedKeys = Set<String>()
        for key in pendingBefore {
            guard let localDay = data.days[key] else { continue } // no bucket to write — drop the key
            let day = syncReadyDay(localDay)
            do {
                try syncDatabase.recordStatsDay(day, metadata: metadata(for: day))
                writtenKeys.append(key)
            } catch {
                failedKeys.insert(key)
                AppLogger.shared.error("sync.statsMarkerFailed", "Failed to record stats day for sync", metadata: [
                    "dayKey": key,
                    "error": String(describing: error)
                ], alwaysPersist: true)
            }
        }
        // Retain only the keys that failed, so the next flush retries them.
        pendingStatsDayKeys = failedKeys
        lastStatsDayWriteAt = Date()
        let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        let now = Date()
        let routineSummaryDue = lastFlushDiagnosticAt.map({ now.timeIntervalSince($0) >= routineDiagnosticInterval }) ?? true
        if reason != "throttle" || !failedKeys.isEmpty || durationMs >= 50 || routineSummaryDue {
            lastFlushDiagnosticAt = now
            AppLogger.shared.info("stats.flush", "Flushed coalesced listening stats days to sync database", metadata: [
                "reason": reason,
                "pendingBefore": "\(pendingBefore.count)",
                "written": "\(writtenKeys.count)",
                "failed": "\(failedKeys.count)",
                "remaining": "\(pendingStatsDayKeys.count)",
                "dayKeys": writtenKeys.sorted().joined(separator: ","),
                "failedDayKeys": failedKeys.sorted().joined(separator: ","),
                "durationMs": String(format: "%.1f", durationMs)
            ])
        }
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

    private static var systemProtectedDataAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    public convenience init() {
        self.init(
            fileURL: Self.statsURL("listening-stats.json"),
            legacyFileURL: Self.statsURL("playback-stats.json")
        )
    }

    /// Custom URLs are for smoke tests; production callers use `init()`.
    public convenience init(fileURL: URL?, legacyFileURL: URL?) {
        self.init(
            fileURL: fileURL,
            legacyFileURL: legacyFileURL,
            protectedDataAvailable: { Self.systemProtectedDataAvailable }
        )
    }

    init(
        fileURL: URL?,
        legacyFileURL: URL?,
        protectedDataAvailable: @escaping () -> Bool,
        calendarProvider: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }
    ) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.protectedDataAvailable = protectedDataAvailable
        self.calendarProvider = calendarProvider
        load()
        importLegacyBaselineIfNeeded()
        installSignificantTimeObservers()
    }

    deinit {
        for observer in significantTimeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Recording

    public func addListeningTime(
        _ seconds: TimeInterval,
        speed: Double,
        subscriptionID: UUID,
        showTitle: String,
        feedURL: URL? = nil,
        endedAt: Date = Date()
    ) {
        guard seconds > 0 else { return }
        let showKey = canonicalShowKey(
            subscriptionID: subscriptionID,
            feedURL: feedURL,
            showTitle: showTitle
        )
        let segments = listeningSegments(seconds: seconds, endedAt: endedAt)
        for segment in segments {
            var day = bucket(for: segment.date)
            day.wallClockSeconds += segment.seconds
            day.hourSeconds[segment.hour] += segment.seconds
            day.perShowSeconds[showKey, default: 0] += segment.seconds
            if speed > 1.0 {
                // `seconds` is elapsed wall time. At S× speed that interval consumes
                // seconds*S of media, so the time avoided versus 1× is seconds*(S-1).
                // Do not divide by speed here; that formula applies only when the
                // input is media time rather than this API's wall-clock contract.
                let saved = segment.seconds * (speed - 1.0)
                day.timeSavedVariableSpeed += saved
                day.perShowTimeSaved[showKey, default: 0] += saved
            }

            data.days[day.dayKey] = day
            storageRevision &+= 1
            data.dayRevisions[day.dayKey] = storageRevision
            recordDayPending(day)
        }
        data.showTitles[showKey] = showTitle
        playbackRevisionPending = true
        bumpPlaybackRevisionIfNeeded(now: endedAt)
        saveThrottled()
    }

    public func addManualSkipForward(
        _ seconds: TimeInterval,
        subscriptionID: UUID? = nil,
        feedURL: URL? = nil,
        showTitle: String? = nil
    ) {
        guard seconds > 0 else { return }
        let key = subscriptionID.map {
            canonicalShowKey(subscriptionID: $0, feedURL: feedURL, showTitle: showTitle)
        }
        mutateToday {
            $0.timeSavedManualSkip += seconds
            $0.manualSkipForwardCount += 1
            if let key {
                $0.perShowTimeSaved[key, default: 0] += seconds
            }
        }
    }

    public func addAutoSkip(
        _ seconds: TimeInterval,
        subscriptionID: UUID? = nil,
        feedURL: URL? = nil,
        showTitle: String? = nil
    ) {
        guard seconds > 0 else { return }
        let key = subscriptionID.map {
            canonicalShowKey(subscriptionID: $0, feedURL: feedURL, showTitle: showTitle)
        }
        mutateToday {
            $0.timeSavedAutoSkip += seconds
            if let key {
                $0.perShowTimeSaved[key, default: 0] += seconds
            }
        }
    }

    public func addTrimSilenceSaved(
        _ seconds: TimeInterval,
        subscriptionID: UUID? = nil,
        feedURL: URL? = nil,
        showTitle: String? = nil
    ) {
        guard seconds > 0 else { return }
        let key = subscriptionID.map {
            canonicalShowKey(subscriptionID: $0, feedURL: feedURL, showTitle: showTitle)
        }
        mutateToday {
            $0.timeSavedTrimSilence += seconds
            if let key {
                $0.perShowTimeSaved[key, default: 0] += seconds
            }
        }
    }

    public func recordEpisodeStarted(
        subscriptionID: UUID,
        showTitle: String,
        feedURL: URL? = nil
    ) {
        let key = canonicalShowKey(
            subscriptionID: subscriptionID,
            feedURL: feedURL,
            showTitle: showTitle
        )
        data.showTitles[key] = showTitle
        mutateToday {
            $0.episodesStarted += 1
            $0.perShowEpisodesStarted[key, default: 0] += 1
        }
    }

    public func recordEpisodeCompleted(
        subscriptionID: UUID,
        feedURL: URL? = nil,
        showTitle: String? = nil
    ) {
        let key = canonicalShowKey(
            subscriptionID: subscriptionID,
            feedURL: feedURL,
            showTitle: showTitle
        )
        mutateToday {
            $0.episodesCompleted += 1
            $0.perShowEpisodesCompleted[key, default: 0] += 1
        }
    }

    /// Registers every currently known subscription and rewrites historical
    /// UUID-keyed local buckets to the canonical feed identity. This is
    /// additive when an unsubscribe/resubscribe created more than one UUID and
    /// is idempotent on subsequent Stats-page openings.
    public func registerCanonicalShows(_ subscriptions: [Subscription]) {
        var localKeysChanged = Set<String>()
        var inheritedChanged = false
        for subscription in subscriptions {
            let oldKey = subscription.id.uuidString
            let newKey = StatsShowIdentity.key(for: subscription.feedURL)
            data.canonicalShowIDs[oldKey] = newKey
            data.showTitles[newKey] = subscription.title
            for key in data.days.keys {
                guard var day = data.days[key], day.remapShow(from: oldKey, to: newKey) else { continue }
                data.days[key] = day
                localKeysChanged.insert(key)
            }
            for key in data.inheritedDays.keys {
                guard var day = data.inheritedDays[key], day.remapShow(from: oldKey, to: newKey) else { continue }
                data.inheritedDays[key] = day
                inheritedChanged = true
            }
            if let oldTitle = data.showTitles.removeValue(forKey: oldKey), data.showTitles[newKey] == nil {
                data.showTitles[newKey] = oldTitle
            }
        }
        guard !localKeysChanged.isEmpty || inheritedChanged else { return }
        for key in localKeysChanged {
            storageRevision &+= 1
            data.dayRevisions[key] = storageRevision
            if let day = data.days[key] { recordDayPending(day, allowImmediateFlush: false) }
        }
        storageRevision &+= 1
        bumpRevision()
        save()
    }

    /// Stores an idempotent episode outcome independently of mutable/capped
    /// ListeningHistory. Stronger terminal evidence (natural completion before
    /// automatic cleanup, for example) is never replaced by weaker evidence.
    public func recordEpisodeOutcome(
        episode: Episode,
        subscription: Subscription?,
        completionKind: CompletionKind,
        positionSeconds: TimeInterval?,
        occurredAt: Date = Date()
    ) {
        let showID = canonicalShowKey(
            subscriptionID: episode.subscriptionID,
            feedURL: subscription?.feedURL,
            showTitle: subscription?.title ?? episode.author
        )
        let trimmedGUID = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodeIdentity = !trimmedGUID.isEmpty
            ? "\(showID)|guid:\(trimmedGUID)"
            : "\(showID)|url:\(episode.audioURL.absoluteString)"
        let candidate = DurableEpisodeOutcome(
            showID: showID,
            occurredAt: occurredAt,
            completionKind: completionKind,
            positionSeconds: positionSeconds,
            durationSeconds: episode.durationSeconds
        )
        var replacesNaturalCompletion = false

        // Remove an older copy authored on a different local day so the same
        // episode is never counted twice after its disposition changes.
        for key in data.days.keys where key != dayKey(for: occurredAt) {
            guard var day = data.days[key], let existing = day.episodeOutcomes[episodeIdentity] else { continue }
            guard DayStats.preferredOutcome(existing, candidate) == candidate else { return }
            replacesNaturalCompletion = replacesNaturalCompletion
                || existing.completionKind == .finishedNaturally
            day.episodeOutcomes.removeValue(forKey: episodeIdentity)
            data.days[key] = day
            storageRevision &+= 1
            data.dayRevisions[key] = storageRevision
            recordDayPending(day, allowImmediateFlush: false)
        }

        var day = bucket(for: occurredAt)
        if let existing = day.episodeOutcomes[episodeIdentity],
           DayStats.preferredOutcome(existing, candidate) == existing {
            return
        }
        if let existing = day.episodeOutcomes[episodeIdentity] {
            replacesNaturalCompletion = replacesNaturalCompletion
                || existing.completionKind == .finishedNaturally
        }
        day.episodeOutcomes[episodeIdentity] = candidate
        if completionKind == .finishedNaturally, !replacesNaturalCompletion {
            day.episodesCompleted += 1
            day.perShowEpisodesCompleted[showID, default: 0] += 1
        }
        data.days[day.dayKey] = day
        storageRevision &+= 1
        data.dayRevisions[day.dayKey] = storageRevision
        recordDayPending(day)
        bumpRevision()
        saveThrottled()
    }

    /// Records one completed episode download of `bytes` against today's bucket.
    /// Called from DownloadTransferWorkflow's success path. Forward-only — there is no
    /// historical byte data to backfill, so totals accrue from this build onward.
    public func recordDownload(bytes: Int64) {
        guard bytes > 0 else { return }
        mutateToday(persistImmediately: false) {
            $0.bytesDownloaded += bytes
            $0.episodesDownloaded += 1
        }
        // A completed background transfer is a discrete durable fact. Unlike
        // rendered playback intervals, it must not wait for a later lifecycle
        // checkpoint that the process may never receive.
        save()
    }

    /// Replaces the bucket for the day's `dayKey`. For backfill/migration tooling
    /// and smoke tests — normal recording goes through the add/record methods.
    public func importDay(_ day: DayStats) {
        data.days[day.dayKey] = day
        storageRevision &+= 1
        data.dayRevisions[day.dayKey] = storageRevision
        recordDayPending(day)
        bumpRevision()
        saveThrottled()
    }

    // MARK: - Queries

    /// Titles for resolving `perShowSeconds` keys, including unsubscribed shows
    /// and shows that only exist on other devices (their labels arrive in the
    /// synced day partitions). Local labels take precedence over remote snapshots.
    public var showTitles: [String: String] {
        var merged = data.showTitles
        for days in remoteByDayKey.values {
            for day in days {
                merged.merge(day.showTitles) { mine, _ in mine }
            }
        }
        return merged
    }

    /// When stats collection first began (carried over from the legacy store if imported).
    public var startedAt: Date { data.legacyBaseline?.startedAt ?? data.startedAt }

    public var healthSnapshot: StatsHealthSnapshot {
        let durablePending = Set((try? syncDatabase?.pendingStatsDays().map(\.dayKey)) ?? [])
        return StatsHealthSnapshot(
            recordedDayCount: Set(data.days.keys).union(data.inheritedDays.keys).count,
            remoteDeviceCount: (try? syncDatabase?.remoteStatsDeviceIDs().count) ?? 0,
            pendingDayCount: pendingStatsDayKeys.union(durablePending).count,
            lastLocalSave: lastSavedAt,
            lastSuccessfulSync: (try? syncDatabase?.lastSuccessfulStatsSync()) ?? nil,
            recoveryStatus: data.lastRecoveryMessage ?? "No recovery needed"
        )
    }

    public enum ArchiveError: LocalizedError {
        case invalidArchive
        case alreadyImported
        case overlapsExistingDays

        public var errorDescription: String? {
            switch self {
            case .invalidArchive: return "This is not a valid Autohop Stats archive."
            case .alreadyImported: return "This Stats archive has already been imported."
            case .overlapsExistingDays:
                return "This archive overlaps Stats already on this device. Import it into an empty installation to avoid double-counting."
            }
        }
    }

    /// A portable, idempotence-tagged backup of the currently visible daily
    /// aggregates. Imported data becomes a local inherited base and is never
    /// re-uploaded as a new device partition.
    public func makeJSONExport() throws -> URL {
        let coveredDeviceIDs = data.lineageDeviceIDs
            .union([DeviceIdentity.current])
            .union((try? syncDatabase?.remoteStatsDeviceIDs()) ?? [])
        let archive = ListeningStatsArchive(
            schemaVersion: ListeningStatsArchive.schemaVersion,
            archiveID: UUID().uuidString,
            exportedAt: Date(),
            days: Dictionary(uniqueKeysWithValues: allDayKeys().map { ($0, combinedDay($0)) }),
            showTitles: showTitles,
            coveredDeviceIDs: coveredDeviceIDs,
            coveredGenerationIDs: data.retiredGenerationIDs.union([storageGenerationID]),
            legacyBaseline: data.legacyBaseline,
            legacyBaselineEndedAt: data.legacyBaselineEndedAt,
            startedAt: data.startedAt
        )
        let envelope = try IntegrityCheckedStoreEnvelope.make(
            payload: archive,
            schemaVersion: ListeningStatsArchive.schemaVersion,
            generationID: archive.archiveID,
            revision: 1,
            writerDeviceID: DeviceIdentity.current
        )
        let url = exportURL(extension: "json")
        try LockedDeviceFileAccess.writeDataAtomically(
            try IntegrityCheckedStoreEnvelope.encode(envelope),
            to: url
        )
        return url
    }

    public func makeCSVExport() throws -> URL {
        var lines = [
            "date,listening_seconds,variable_speed_saved,trim_silence_saved,manual_skip_saved,automatic_skip_saved,episodes_started,episodes_completed,manual_skip_count,bytes_downloaded,episodes_downloaded,durable_outcomes"
        ]
        for key in allDayKeys().sorted() {
            let day = combinedDay(key)
            lines.append([
                key,
                String(format: "%.3f", day.wallClockSeconds),
                String(format: "%.3f", day.timeSavedVariableSpeed),
                String(format: "%.3f", day.timeSavedTrimSilence),
                String(format: "%.3f", day.timeSavedManualSkip),
                String(format: "%.3f", day.timeSavedAutoSkip),
                "\(day.episodesStarted)", "\(day.episodesCompleted)",
                "\(day.manualSkipForwardCount)", "\(day.bytesDownloaded)",
                "\(day.episodesDownloaded)", "\(day.episodeOutcomes.count)"
            ].joined(separator: ","))
        }
        let url = exportURL(extension: "csv")
        try LockedDeviceFileAccess.writeDataAtomically(Data(lines.joined(separator: "\n").utf8), to: url)
        return url
    }

    public func importJSONArchive(from url: URL) throws {
        let archive: ListeningStatsArchive
        do {
            let envelope = try IntegrityCheckedStoreEnvelope<ListeningStatsArchive>.decode(Data(contentsOf: url))
            archive = try envelope.validated(expectedSchemaVersion: ListeningStatsArchive.schemaVersion)
        } catch {
            throw ArchiveError.invalidArchive
        }
        guard archive.schemaVersion == ListeningStatsArchive.schemaVersion,
              !archive.archiveID.isEmpty,
              archive.exportedAt.timeIntervalSinceReferenceDate.isFinite,
              archive.startedAt.timeIntervalSinceReferenceDate.isFinite,
              archive.legacyBaseline.map(ListeningStatsData.isValid) ?? true,
              archive.days.allSatisfy({ $0.key == $0.value.dayKey && $0.value.isSemanticallyValid })
        else { throw ArchiveError.invalidArchive }
        guard !data.importedArchiveIDs.contains(archive.archiveID) else {
            throw ArchiveError.alreadyImported
        }
        guard Set(archive.days.keys).isDisjoint(with: Set(allDayKeys())) else {
            throw ArchiveError.overlapsExistingDays
        }
        data.inheritedDays.merge(archive.days) { existing, _ in existing }
        data.showTitles.merge(archive.showTitles) { existing, _ in existing }
        data.lineageDeviceIDs.formUnion(archive.coveredDeviceIDs)
        data.retiredGenerationIDs.formUnion(archive.coveredGenerationIDs)
        data.importedArchiveIDs.insert(archive.archiveID)
        if data.legacyBaseline == nil { data.legacyBaseline = archive.legacyBaseline }
        if data.legacyBaselineEndedAt == nil {
            data.legacyBaselineEndedAt = archive.legacyBaselineEndedAt
        }
        data.startedAt = min(data.startedAt, archive.startedAt)
        storageRevision &+= 1
        recordRecovery("Imported a verified Stats archive")
        try syncDatabase?.registerOwnedStatsDeviceIDs(data.lineageDeviceIDs.union([DeviceIdentity.current]))
        try syncDatabase?.registerRetiredStatsGenerations(data.retiredGenerationIDs)
        save()
        reloadRemoteStats()
    }

    private func exportURL(extension fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "Autohop-Stats-\(formatter.string(from: Date())).\(fileExtension)"
        )
    }

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

    /// Period summaries are recomputed inside `StatsView.body`, so they can be
    /// evaluated many times per SwiftUI redraw. Each walks every day bucket (and,
    /// for `.lifetime`, merges all remote partitions), which scales with lifetime
    /// history. Memoize by period and invalidate whenever `revision` changes
    /// (bumped on every stats mutation and remote-partition reload), so a redraw
    /// storm with unchanged data is served from cache.
    public func summary(for period: StatsPeriod) -> ListeningStatsSummary {
        let todayKey = dayKey(for: Date())
        if summaryCacheRevision != revision || summaryCacheDayKey != todayKey {
            summaryCache.removeAll(keepingCapacity: true)
            summaryCacheRevision = revision
            summaryCacheDayKey = todayKey
        }
        if let cached = summaryCache[period] { return cached }
        let result = computeSummary(for: period)
        summaryCache[period] = result
        return result
    }

    private func computeSummary(for period: StatsPeriod) -> ListeningStatsSummary {
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
        case .previousWeek:
            let thisWeek = startOfCurrentWeek()
            let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
            buckets = days(from: lastWeek, upTo: thisWeek)
        case .previousMonth:
            let thisMonth = startOfCurrentMonth()
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
            buckets = days(from: lastMonth, upTo: thisMonth)
        case .previousYear:
            let thisYear = startOfCurrentYear()
            let lastYear = calendar.date(byAdding: .year, value: -1, to: thisYear) ?? thisYear
            buckets = days(from: lastYear, upTo: thisYear)
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
            result.bytesDownloaded += day.bytesDownloaded
            result.episodesDownloaded += day.episodesDownloaded
            for (show, seconds) in day.perShowSeconds {
                result.perShowSeconds[show, default: 0] += seconds
            }
            for (show, seconds) in day.perShowTimeSaved {
                result.perShowTimeSaved[show, default: 0] += seconds
            }
            for (show, count) in day.perShowEpisodesStarted {
                result.perShowEpisodesStarted[show, default: 0] += count
            }
            for (show, count) in day.perShowEpisodesCompleted {
                result.perShowEpisodesCompleted[show, default: 0] += count
            }
            for (identity, outcome) in day.episodeOutcomes {
                if let existing = result.episodeOutcomes[identity] {
                    if existing.completionKind == .finishedNaturally,
                       outcome.completionKind == .finishedNaturally {
                        result.episodesCompleted = max(0, result.episodesCompleted - 1)
                        result.perShowEpisodesCompleted[outcome.showID, default: 0] = max(
                            0,
                            result.perShowEpisodesCompleted[outcome.showID, default: 0] - 1
                        )
                    }
                    result.episodeOutcomes[identity] = DayStats.preferredOutcome(existing, outcome)
                } else {
                    result.episodeOutcomes[identity] = outcome
                }
            }
            for hour in 0..<24 {
                result.hourSeconds[hour] += day.hourSeconds[hour]
            }
        }
        // Legacy totals have an interval but no daily attribution. Include the
        // block whenever the selected range wholly contains that interval. This
        // makes Year equal Lifetime when all listening occurred in that year,
        // while refusing to guess how a baseline spanning a boundary splits.
        if let baseline = legacyBaselineIncluded(in: period) {
            result.legacyUnbucketedListeningSeconds = baseline.totalListeningSeconds
            result.wallClockSeconds += baseline.totalListeningSeconds
            result.timeSavedVariableSpeed += baseline.timeSavedVariableSpeed
            result.timeSavedTrimSilence += baseline.timeSavedTrimSilence
            result.timeSavedManualSkip += baseline.timeSavedManualSkip
            result.timeSavedAutoSkip += baseline.timeSavedAutoSkip
        } else if legacyBaselinePartiallyOverlaps(period) {
            result.excludesPartiallyOverlappingLegacyBaseline = true
        }
        result.coverageNotices = coverageNotices(for: period)
        return result
    }

    private func legacyBaselineIncluded(in period: StatsPeriod) -> PlaybackStats? {
        guard let baseline = data.legacyBaseline else { return nil }
        if period == .lifetime { return baseline }
        guard let bounds = periodBounds(period) else { return baseline }

        let inferredCutover = data.days.keys.compactMap(dayDate(from:)).min() ?? Date()
        let endedAt = data.legacyBaselineEndedAt ?? inferredCutover
        guard baseline.startedAt >= bounds.start, endedAt <= bounds.end else { return nil }
        return baseline
    }

    private func legacyBaselinePartiallyOverlaps(_ period: StatsPeriod) -> Bool {
        guard period != .lifetime,
              let baseline = data.legacyBaseline,
              let bounds = periodBounds(period) else { return false }
        let inferredCutover = data.days.keys.compactMap(dayDate(from:)).min() ?? Date()
        let endedAt = data.legacyBaselineEndedAt ?? inferredCutover
        let overlaps = baseline.startedAt < bounds.end && endedAt > bounds.start
        let whollyContained = baseline.startedAt >= bounds.start && endedAt <= bounds.end
        return overlaps && !whollyContained
    }

    private func coverageNotices(for period: StatsPeriod) -> [StatsCoverageNotice] {
        let earliestBucket = allDayKeys().compactMap(dayDate(from:)).min()
        let knownHistoryStart = min(data.startedAt, earliestBucket ?? data.startedAt)
        let bounds = periodBounds(period) ?? (start: knownHistoryStart, end: Date.distantFuture)
        let boundaries: [(StatsCoverageNotice.Metric, DateComponents)] = [
            (.perShowTimeSaved, DateComponents(year: 2026, month: 6, day: 15)),
            (.downloads, DateComponents(year: 2026, month: 6, day: 18)),
            (.perShowOutcomes, DateComponents(year: 2026, month: 8, day: 20)),
            (.durableOutcomes, DateComponents(year: 2026, month: 9, day: 4))
        ]
        return boundaries.compactMap { metric, components in
            let effectiveStart = max(bounds.start, knownHistoryStart)
            guard let boundary = calendar.date(from: components),
                  effectiveStart < boundary,
                  bounds.end > knownHistoryStart else { return nil }
            return StatsCoverageNotice(metric: metric, trackedSince: boundary)
        }
    }

    private func periodBounds(_ period: StatsPeriod) -> (start: Date, end: Date)? {
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        switch period {
        case .last(let count):
            return (
                calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today) ?? today,
                tomorrow
            )
        case .currentWeek:
            return (startOfCurrentWeek(), tomorrow)
        case .currentMonth:
            return (startOfCurrentMonth(), tomorrow)
        case .currentYear:
            return (startOfCurrentYear(), tomorrow)
        case .previousWeek:
            let end = startOfCurrentWeek()
            return (calendar.date(byAdding: .day, value: -7, to: end) ?? end, end)
        case .previousMonth:
            let end = startOfCurrentMonth()
            return (calendar.date(byAdding: .month, value: -1, to: end) ?? end, end)
        case .previousYear:
            let end = startOfCurrentYear()
            return (calendar.date(byAdding: .year, value: -1, to: end) ?? end, end)
        case .lifetime:
            return nil
        }
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
        case .previousWeek:
            // "Last week" compares against the week before it.
            let thisWeek = startOfCurrentWeek()
            guard let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek),
                  let weekBefore = calendar.date(byAdding: .day, value: -14, to: thisWeek) else { return nil }
            accumulate(&totals, from: weekBefore, upTo: lastWeek)
        case .previousMonth:
            let thisMonth = startOfCurrentMonth()
            guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth),
                  let monthBefore = calendar.date(byAdding: .month, value: -2, to: thisMonth) else { return nil }
            accumulate(&totals, from: monthBefore, upTo: lastMonth)
        case .previousYear:
            let thisYear = startOfCurrentYear()
            guard let lastYear = calendar.date(byAdding: .year, value: -1, to: thisYear),
                  let yearBefore = calendar.date(byAdding: .year, value: -2, to: thisYear) else { return nil }
            accumulate(&totals, from: yearBefore, upTo: lastYear)
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
        guard persistenceState.allowsPersistence else {
            AppLogger.shared.error(
                "stats.saveBlocked",
                "Refused to overwrite listening stats after an unsuccessful load",
                metadata: ["state": String(describing: persistenceState)],
                alwaysPersist: true
            )
            return
        }
        // A full save is a real persistence checkpoint (pause / background / shutdown) — make sure
        // any coalesced stats-day writes reach the sync database too.
        flushPendingStatsDays(reason: "save")
        bumpPlaybackRevisionIfNeeded(now: Date(), force: true)
        guard let url = fileURL else { return }
        do {
            if persistenceState != .recoveredFromBackup {
                try preserveLastKnownGoodPrimary(at: url)
            }
            let envelope = try IntegrityCheckedStoreEnvelope.make(
                payload: data,
                schemaVersion: Self.storageSchemaVersion,
                generationID: storageGenerationID,
                revision: storageRevision,
                writerDeviceID: DeviceIdentity.current
            )
            let encoded = try IntegrityCheckedStoreEnvelope.encode(envelope)
            try LockedDeviceFileAccess.writeDataAtomically(encoded, to: url)
            lastSavedAt = Date()
            persistenceState = .loaded
        } catch {
            AppLogger.shared.error("stats.saveFailed", "Could not save listening stats", metadata: [
                "error": String(describing: error)
            ], alwaysPersist: true)
        }
    }

    // MARK: - Private

    private func mutateToday(
        persistImmediately: Bool = true,
        _ change: (inout DayStats) -> Void
    ) {
        var day = bucket(for: Date())
        change(&day)
        data.days[day.dayKey] = day
        storageRevision &+= 1
        data.dayRevisions[day.dayKey] = storageRevision
        recordDayPending(day, allowImmediateFlush: persistImmediately)
        bumpRevision()
        if persistImmediately {
            saveThrottled()
        }
    }

    private func bucket(for date: Date) -> DayStats {
        let key = dayKey(for: date)
        return data.days[key] ?? DayStats(dayKey: key)
    }

    private func canonicalShowKey(
        subscriptionID: UUID,
        feedURL: URL?,
        showTitle: String?
    ) -> String {
        let oldKey = subscriptionID.uuidString
        let key: String
        if let feedURL {
            key = StatsShowIdentity.key(for: feedURL)
            data.canonicalShowIDs[oldKey] = key
        } else {
            key = data.canonicalShowIDs[oldKey] ?? oldKey
        }
        if let showTitle, !showTitle.isEmpty { data.showTitles[key] = showTitle }
        return key
    }

    private struct ListeningSegment {
        var date: Date
        var hour: Int
        var seconds: TimeInterval
    }

    /// Splits a rendered interval at every local hour boundary. Day attribution
    /// and the listening clock therefore remain correct across midnight, DST,
    /// and callbacks that span more than one wall-clock bucket.
    private func listeningSegments(seconds: TimeInterval, endedAt: Date) -> [ListeningSegment] {
        let start = endedAt.addingTimeInterval(-seconds)
        var cursor = start
        var result: [ListeningSegment] = []
        while cursor < endedAt {
            let hourInterval = calendar.dateInterval(of: .hour, for: cursor)
            let boundary = min(hourInterval?.end ?? endedAt, endedAt)
            let duration = boundary.timeIntervalSince(cursor)
            guard duration > 0 else { break }
            result.append(ListeningSegment(
                date: cursor,
                hour: min(max(calendar.component(.hour, from: cursor), 0), 23),
                seconds: duration
            ))
            cursor = boundary
        }
        return result.isEmpty
            ? [ListeningSegment(
                date: endedAt,
                hour: min(max(calendar.component(.hour, from: endedAt), 0), 23),
                seconds: seconds
            )]
            : result
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

    /// Day buckets in the half-open range [start, end), oldest first. Used by the
    /// previous-period summaries (a concluded week/month/year).
    private func days(from start: Date, upTo end: Date) -> [DayStats] {
        var result: [DayStats] = []
        var cursor = calendar.startOfDay(for: start)
        let stop = calendar.startOfDay(for: end)
        while cursor < stop {
            result.append(combinedDay(dayKey(for: cursor)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
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

    /// Coalesces only the continuous playback path. Discrete events continue to
    /// use bumpRevision() immediately so taps/downloads/completions remain live.
    private func bumpPlaybackRevisionIfNeeded(now: Date, force: Bool = false) {
        guard playbackRevisionPending,
              force || lastPlaybackRevisionAt.map({ now.timeIntervalSince($0) >= playbackRevisionInterval }) ?? true
        else {
            return
        }
        playbackRevisionPending = false
        lastPlaybackRevisionAt = now
        bumpRevision()
    }

    private func saveThrottled() {
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 30 { return }
        save()
    }

    private struct LoadedSnapshot {
        let payload: ListeningStatsData
        let generationID: String
        let revision: UInt64
        let writerDeviceID: String?
        let updatedAt: Date?
    }

    private func load() {
        guard let url = fileURL else {
            persistenceState = .absent
            return
        }
        guard protectedDataAvailable() else {
            persistenceState = .temporarilyUnavailable
            installProtectedDataRetry()
            AppLogger.shared.error(
                "stats.loadUnavailable",
                "Listening stats are unavailable until protected data can be read",
                alwaysPersist: true
            )
            return
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            if restoreFromBackup(for: url) { return }
            if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
                quarantinePrimary(at: backupURL)
                persistenceState = .corruptOrIncompatible
                AppLogger.shared.error(
                    "stats.backupRejected",
                    "The primary stats file is absent and its backup failed validation; writes are blocked",
                    alwaysPersist: true
                )
                return
            }
            persistenceState = .absent
            return
        }

        do {
            let encoded = try Data(contentsOf: url)
            let loaded = try decodeSnapshot(encoded)
            applyLoadedSnapshot(loaded, state: .loaded)
            if migrateLegacyDeviceOwnership(from: loaded.writerDeviceID) {
                save()
            }
        } catch {
            if !protectedDataAvailable() {
                persistenceState = .temporarilyUnavailable
                installProtectedDataRetry()
                AppLogger.shared.error(
                    "stats.loadUnavailable",
                    "Listening stats became unavailable while loading",
                    metadata: ["error": String(describing: error)],
                    alwaysPersist: true
                )
                return
            }
            quarantinePrimary(at: url)
            if restoreFromBackup(for: url) { return }
            persistenceState = .corruptOrIncompatible
            AppLogger.shared.error(
                "stats.loadRejected",
                "Listening stats failed validation; writes are blocked and the original is preserved",
                metadata: ["error": String(describing: error)],
                alwaysPersist: true
            )
        }
    }

    private func decodeSnapshot(_ encoded: Data) throws -> LoadedSnapshot {
        do {
            let envelope = try IntegrityCheckedStoreEnvelope<ListeningStatsData>.decode(encoded)
            let payload = try envelope.validated(expectedSchemaVersion: Self.storageSchemaVersion)
            guard payload.isSemanticallyValid else {
                throw IntegrityCheckedStoreEnvelope<ListeningStatsData>.ValidationError.invalidMetadata
            }
            return LoadedSnapshot(
                payload: payload,
                generationID: envelope.generationID,
                revision: envelope.revision,
                writerDeviceID: envelope.writerDeviceID,
                updatedAt: envelope.updatedAt
            )
        } catch {
            if let legacy = try? JSONDecoder().decode(ListeningStatsData.self, from: encoded),
               legacy.isSemanticallyValid {
                return LoadedSnapshot(
                    payload: legacy,
                    generationID: UUID().uuidString,
                    revision: 0,
                    writerDeviceID: DeviceIdentity.legacyIdentifier,
                    updatedAt: nil
                )
            }
            throw error
        }
    }

    private func applyLoadedSnapshot(_ loaded: LoadedSnapshot, state: DurableStoreLoadState) {
        data = loaded.payload
        storageGenerationID = loaded.generationID
        storageRevision = loaded.revision
        lastSavedAt = loaded.updatedAt
        persistenceState = state
    }

    private var backupURL: URL? {
        fileURL?.deletingPathExtension().appendingPathExtension("backup.json")
    }

    private func restoreFromBackup(for primaryURL: URL) -> Bool {
        guard let backupURL,
              FileManager.default.fileExists(atPath: backupURL.path),
              let encoded = try? Data(contentsOf: backupURL),
              let loaded = try? decodeSnapshot(encoded) else { return false }
        applyLoadedSnapshot(loaded, state: .recoveredFromBackup)
        _ = migrateLegacyDeviceOwnership(from: loaded.writerDeviceID)
        recordRecovery("Recovered from last-known-good backup")
        AppLogger.shared.error(
            "stats.backupRecovered",
            "Recovered listening stats from the last-known-good backup",
            metadata: ["primary": primaryURL.lastPathComponent],
            alwaysPersist: true
        )
        save()
        return true
    }

    private func preserveLastKnownGoodPrimary(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // A read failure is not equivalent to an absent file. Abort the save so
        // a protection/permissions race cannot overwrite the only good copy.
        let existing = try Data(contentsOf: url)
        guard (try? decodeSnapshot(existing)) != nil else {
            quarantinePrimary(at: url, data: existing)
            return
        }
        guard let backupURL else { return }
        try LockedDeviceFileAccess.writeDataAtomically(existing, to: backupURL)
    }

    private func quarantinePrimary(at url: URL, data: Data? = nil) {
        guard let encoded = data ?? (try? Data(contentsOf: url)) else { return }
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
        )
        do {
            try LockedDeviceFileAccess.writeDataAtomically(encoded, to: quarantineURL)
            AppLogger.shared.error(
                "stats.corruptPreserved",
                "Preserved an invalid listening stats file for recovery",
                metadata: ["file": quarantineURL.lastPathComponent],
                alwaysPersist: true
            )
        } catch {
            AppLogger.shared.error(
                "stats.corruptPreserveFailed",
                "Could not preserve an invalid listening stats file",
                metadata: ["error": String(describing: error)],
                alwaysPersist: true
            )
        }
    }

    private func installProtectedDataRetry() {
        #if canImport(UIKit)
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryProtectedDataLoad() }
        }
        #endif
    }

    private func installSignificantTimeObservers() {
        let names: [Notification.Name] = [
            .NSSystemTimeZoneDidChange,
            .NSCalendarDayChanged
        ]
        #if canImport(UIKit)
        let allNames = names + [UIApplication.significantTimeChangeNotification]
        #else
        let allNames = names
        #endif
        significantTimeObservers = allNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.significantTimeDidChange() }
            }
        }
    }

    /// Invalidates every date-relative query after midnight, a time-zone change,
    /// or another system-significant clock adjustment. Recording itself reads
    /// the autoupdating calendar on every interval.
    func significantTimeDidChange() {
        summaryCache.removeAll(keepingCapacity: true)
        summaryCacheDayKey = ""
        bumpRevision()
    }

    /// Internal test seam; production invokes it from the protected-data
    /// notification installed after an unavailable launch-time read.
    func retryProtectedDataLoad() {
        guard persistenceState == .temporarilyUnavailable,
              protectedDataAvailable() else { return }
        let deferred = data
        let deferredRevision = storageRevision
        load()
        guard persistenceState.allowsPersistence, deferredRevision > 0 else { return }
        mergeDeferredActivity(deferred)
        storageRevision = max(storageRevision, deferredRevision) &+ 1
        for day in deferred.days.values {
            recordDayPending(day, allowImmediateFlush: false)
        }
        save()
    }

    private func mergeDeferredActivity(_ deferred: ListeningStatsData) {
        for (key, day) in deferred.days {
            if let persisted = data.days[key] {
                data.days[key] = persisted.merged(with: day)
            } else {
                data.days[key] = day
            }
        }
        for (key, day) in deferred.inheritedDays where data.inheritedDays[key] == nil {
            data.inheritedDays[key] = day
        }
        data.lineageDeviceIDs.formUnion(deferred.lineageDeviceIDs)
        data.retiredGenerationIDs.formUnion(deferred.retiredGenerationIDs)
        data.importedArchiveIDs.formUnion(deferred.importedArchiveIDs)
        data.canonicalShowIDs.merge(deferred.canonicalShowIDs) { _, deferredID in deferredID }
        if let recoveryAt = deferred.lastRecoveryAt,
           data.lastRecoveryAt.map({ recoveryAt > $0 }) ?? true {
            data.lastRecoveryAt = recoveryAt
            data.lastRecoveryMessage = deferred.lastRecoveryMessage
        }
        for (key, revision) in deferred.dayRevisions {
            data.dayRevisions[key] = max(data.dayRevisions[key] ?? 0, revision)
        }
        data.showTitles.merge(deferred.showTitles) { _, deferredTitle in deferredTitle }
        if data.legacyBaseline == nil { data.legacyBaseline = deferred.legacyBaseline }
        if data.legacyBaselineEndedAt == nil {
            data.legacyBaselineEndedAt = deferred.legacyBaselineEndedAt
        }
        data.startedAt = min(data.startedAt, deferred.startedAt)
    }

    /// One-time import of the legacy lifetime totals, so "time saved" doesn't reset
    /// to zero for existing users. The legacy file is left in place untouched.
    private func importLegacyBaselineIfNeeded() {
        guard persistenceState == .absent,
              data.legacyBaseline == nil, data.days.isEmpty,
              let legacyURL = legacyFileURL,
              FileManager.default.fileExists(atPath: legacyURL.path),
              let encoded = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(PlaybackStats.self, from: encoded)
        else { return }
        data.legacyBaseline = legacy
        data.legacyBaselineEndedAt = Date()
        data.startedAt = legacy.startedAt
        storageRevision &+= 1
        save()
        AppLogger.shared.info("stats.legacyImport", "Imported legacy playback stats as lifetime baseline", metadata: [
            "totalListeningSeconds": "\(Int(legacy.totalListeningSeconds))"
        ], alwaysPersist: true)
    }

    private func metadata(for day: DayStats) throws -> StatsPartitionMetadata {
        try StatsPartitionMetadata.make(
            day: day,
            generationID: storageGenerationID,
            revision: data.dayRevisions[day.dayKey] ?? storageRevision,
            writerDeviceID: DeviceIdentity.current
        )
    }

    /// First launch of the identity-v2 build retires the backup-restorable
    /// UserDefaults identity. Historical buckets become a local read-only base;
    /// only post-cutover deltas are authored under the new Keychain identity.
    /// This is what makes two live devices restored from one backup additive
    /// without uploading the same historical snapshot twice.
    private func migrateLegacyDeviceOwnership(from writerDeviceID: String?) -> Bool {
        let current = DeviceIdentity.current
        guard let writerDeviceID,
              !writerDeviceID.isEmpty,
              writerDeviceID != current,
              !data.lineageDeviceIDs.contains(writerDeviceID)
        else { return false }
        for (key, day) in data.days {
            if let inherited = data.inheritedDays[key] {
                data.inheritedDays[key] = inherited.merged(with: day)
            } else {
                data.inheritedDays[key] = day
            }
        }
        data.days.removeAll()
        data.dayRevisions.removeAll()
        data.lineageDeviceIDs.insert(writerDeviceID)
        data.retiredGenerationIDs.insert(storageGenerationID)
        storageGenerationID = UUID().uuidString
        storageRevision = 1
        recordRecovery("Migrated to backup-safe installation identity")
        AppLogger.shared.info(
            "stats.identityMigrated",
            "Retired a backup-restorable stats identity without re-uploading inherited totals",
            metadata: ["legacyDeviceID": writerDeviceID, "newDeviceID": current],
            alwaysPersist: true
        )
        return true
    }

    /// Startup reconciliation. JSON wins unless SQLite proves it has a newer
    /// revision from the same generation. Missing local JSON may be rebuilt from
    /// the durable projection; every local day is then hash-compared/backfilled,
    /// making failed projection writes survive process termination.
    private func reconcileWithSyncDatabase() {
        guard let syncDatabase else { return }
        do {
            try syncDatabase.registerOwnedStatsDeviceIDs(
                data.lineageDeviceIDs.union([DeviceIdentity.current])
            )
            try syncDatabase.registerRetiredStatsGenerations(data.retiredGenerationIDs)
            // Pre-cutover rows contain the inherited full snapshots. Retire
            // them before the new identity's queue scan can upload those totals
            // a second time.
            try syncDatabase.retireStatsProjections(
                dayKeys: Set(data.inheritedDays.keys).subtracting(data.days.keys)
            )
            let projections = try syncDatabase.allStatsDayProjections()
            var recovered = false

            if (persistenceState == .absent || persistenceState == .corruptOrIncompatible),
               data.days.isEmpty, !projections.isEmpty {
                // A missing JSON envelope also means its ownership metadata is
                // missing. Only projections explicitly authored by the active
                // ThisDeviceOnly identity may resume as writable local state.
                // Pre-v10 rows (blank metadata), restored-backup rows, and an
                // older generation are historical base data: retaining them as
                // writable would upload the same totals under a new identity.
                let currentDeviceID = DeviceIdentity.current
                let preferredGeneration = projections
                    .filter {
                        $0.metadata.writerDeviceID == currentDeviceID
                            && !$0.metadata.generationID.isEmpty
                            && $0.metadata.generationID != "legacy"
                    }
                    .max(by: { $0.metadata.revision < $1.metadata.revision })?
                    .metadata.generationID
                if let preferredGeneration { storageGenerationID = preferredGeneration }
                for projection in projections {
                    let metadata = projection.metadata
                    if metadata.writerDeviceID == currentDeviceID,
                       metadata.generationID == preferredGeneration {
                        data.days[projection.day.dayKey] = projection.day
                        data.dayRevisions[projection.day.dayKey] = metadata.revision
                    } else {
                        let key = projection.day.dayKey
                        if let inherited = data.inheritedDays[key] {
                            data.inheritedDays[key] = inherited.merged(with: projection.day)
                        } else {
                            data.inheritedDays[key] = projection.day
                        }
                        if !metadata.writerDeviceID.isEmpty,
                           metadata.writerDeviceID != currentDeviceID {
                            data.lineageDeviceIDs.insert(metadata.writerDeviceID)
                        }
                        if !metadata.generationID.isEmpty,
                           metadata.generationID != "legacy" {
                            data.retiredGenerationIDs.insert(metadata.generationID)
                        }
                    }
                    storageRevision = max(storageRevision, projection.metadata.revision)
                }
                try syncDatabase.registerOwnedStatsDeviceIDs(data.lineageDeviceIDs)
                try syncDatabase.registerRetiredStatsGenerations(data.retiredGenerationIDs)
                try syncDatabase.retireStatsProjections(
                    dayKeys: Set(data.inheritedDays.keys).subtracting(data.days.keys)
                )
                persistenceState = .loaded
                recovered = true
                recordRecovery("Recovered local days from SQLite")
            } else {
                for projection in projections where projection.metadata.generationID == storageGenerationID {
                    let key = projection.day.dayKey
                    let localRevision = data.dayRevisions[key] ?? 0
                    if data.days[key] == nil || projection.metadata.revision > localRevision {
                        data.days[key] = projection.day
                        data.dayRevisions[key] = projection.metadata.revision
                        storageRevision = max(storageRevision, projection.metadata.revision)
                        recovered = true
                    }
                }
            }

            var failures = Set<String>()
            let projectionByKey = Dictionary(
                uniqueKeysWithValues: projections.map { ($0.day.dayKey, $0) }
            )
            for localDay in data.days.values {
                do {
                    let day = syncReadyDay(localDay)
                    let localMetadata = try metadata(for: day)
                    if let projected = projectionByKey[day.dayKey],
                       projected.metadata.generationID == localMetadata.generationID,
                       projected.metadata.revision == localMetadata.revision,
                       projected.metadata.payloadHash == localMetadata.payloadHash {
                        continue
                    }
                    try syncDatabase.recordStatsDay(day, metadata: localMetadata)
                } catch {
                    failures.insert(localDay.dayKey)
                }
            }
            pendingStatsDayKeys.formUnion(failures)
            if recovered {
                recordRecovery("Recovered local days from SQLite")
                storageRevision &+= 1
                save()
                AppLogger.shared.info(
                    "stats.reconciled",
                    "Recovered divergent listening stats from the durable projection",
                    metadata: ["dayCount": "\(data.days.count)"],
                    alwaysPersist: true
                )
            }
            remoteByDayKey = (try? syncDatabase.remoteStatsByDayKey()) ?? [:]
            bumpRevision()
        } catch {
            recordRecovery("Reconciliation failed")
            AppLogger.shared.error(
                "stats.reconcileFailed",
                "Could not reconcile listening stats with SQLite",
                metadata: ["error": String(describing: error)],
                alwaysPersist: true
            )
            remoteByDayKey = (try? syncDatabase.remoteStatsByDayKey()) ?? [:]
            bumpRevision()
        }
    }

    private func recordRecovery(_ message: String) {
        data.lastRecoveryAt = Date()
        data.lastRecoveryMessage = message
    }

    private func syncReadyDay(_ day: DayStats) -> DayStats {
        var result = day
        let showKeys = Set(day.perShowSeconds.keys)
            .union(day.perShowTimeSaved.keys)
            .union(day.perShowEpisodesStarted.keys)
            .union(day.perShowEpisodesCompleted.keys)
            .union(day.episodeOutcomes.values.map(\.showID))
        result.showTitles = showKeys.reduce(into: [String: String]()) { map, showKey in
            if let title = data.showTitles[showKey] { map[showKey] = title }
        }
        return result
    }
}
