import Foundation

// AI CONTEXT — Stats/ShowEngagementAnalyzer.swift
// Pure functions (no I/O, smoke-tested in StatsSmokeTests) powering the Stats
// page's "Shows You're Drifting From" section. Classifies each listening-
// history entry into completed / abandoned / archivedUnplayed(deliberate:),
// aggregates per show, then flags a show via either of two paths:
//   • DRIFT — struggleScore ≥ 0.4, ≥ 4 resolved episodes, AND ≥ 2 genuine
//     drift signals (abandoned mid-listen or deliberately archived unplayed).
//     The genuine-signal rule means auto-archive churn can't flag a show the
//     user is actively using (some completions + lots of limit cycling).
//   • NEGLECT (ghost subscription) — completed == 0 AND ≥ minNeglectedAutoArchives
//     auto-archived unplayed: new episodes keep arriving and aging out of the
//     episode limit while the user never finishes one. The discriminator from
//     healthy high-volume use is the completion COUNT, not the auto-archive rate
//     (both a happy news listener and a lapsed one sit near a 100% auto rate).
// Thresholds are the constants below; medianStopSeconds feeds the "you usually
// stop around the N-minute mark" insight line.

// MARK: - EpisodeOutcome

/// How one listening-history entry resolved, for engagement analysis.
public enum EpisodeOutcome: Equatable {
    /// Played to the end naturally, or got ≥ `completedPercent` of the way through.
    case completed
    /// Real listening happened (≥ `minListenedSeconds`) but the episode ended below `abandonedBelowPercent`.
    case abandoned(stopAtSeconds: TimeInterval)
    /// Archived or dismissed with essentially no listening. `deliberate` means the
    /// user did it by hand; auto-archive churn (episode limit pushing old episodes
    /// out) is a weaker drift signal and is weighted at half in the struggle score.
    case archivedUnplayed(deliberate: Bool)
}

// MARK: - ShowEngagement

/// Per-show episode outcomes over a period, with a struggle score for ranking
/// the "Shows You're Drifting From" list.
public struct ShowEngagement: Identifiable {
    public let subscriptionID: UUID
    public let title: String
    public var completed: Int = 0
    public var abandoned: Int = 0
    public var archivedUnplayedDeliberate: Int = 0
    public var archivedUnplayedAuto: Int = 0
    /// Median position (seconds) at which abandoned episodes were given up.
    public var medianStopSeconds: TimeInterval?

    public var id: UUID { subscriptionID }

    public var archivedUnplayed: Int { archivedUnplayedDeliberate + archivedUnplayedAuto }

    /// Episodes that resolved one way or another — the struggle-score denominator.
    public var totalResolved: Int { completed + abandoned + archivedUnplayed }

    /// 0.0–1.0: fraction of resolved episodes that went badly. Auto-archived
    /// episodes count at half weight — the episode limit removing old episodes
    /// is partly queue hygiene, not pure struggle.
    public var struggleScore: Double {
        guard totalResolved > 0 else { return 0 }
        let badness = Double(abandoned + archivedUnplayedDeliberate) + 0.5 * Double(archivedUnplayedAuto)
        return badness / Double(totalResolved)
    }

    /// A "ghost" subscription: the user has never finished an episode this period,
    /// yet the episode limit keeps auto-archiving unplayed ones — new episodes
    /// arrive and age out without ever being listened to. This is the neglect
    /// path into the drifting list, distinct from engaged-then-drifted shows.
    /// See `ShowEngagementAnalyzer.minNeglectedAutoArchives`.
    public var isNeglected: Bool {
        completed == 0 && archivedUnplayedAuto >= ShowEngagementAnalyzer.minNeglectedAutoArchives
    }

    public init(subscriptionID: UUID, title: String) {
        self.subscriptionID = subscriptionID
        self.title = title
    }
}

// MARK: - ShowEngagementAnalyzer

/// Pure analysis over `ListeningHistoryEntry` values. No storage, no UI — every
/// threshold lives here so tuning is a one-file change and the smoke tests pin
/// the behavior.
public enum ShowEngagementAnalyzer {

    // MARK: Thresholds

    /// Below this much listening an entry counts as "unplayed".
    public static let minListenedSeconds: TimeInterval = 60
    /// At or above this completion fraction an entry counts as completed.
    public static let completedPercent: Double = 0.9
    /// Entries that ended below this fraction (with real listening) count as abandoned.
    public static let abandonedBelowPercent: Double = 0.8
    /// A show needs at least this many resolved episodes before it can be flagged.
    public static let minResolvedEpisodes = 4
    /// Minimum struggle score for a show to appear in the drifting list.
    public static let minStruggleScore = 0.4
    /// To qualify via the DRIFT path a show must have at least this many *genuine*
    /// drift signals (abandoned mid-listen or deliberately archived unplayed).
    /// Auto-archive churn raises the score but can't satisfy this path on its own:
    /// a high-volume feed the episode limit cycles through sits at a 100% auto
    /// rate, so no rate threshold separates limit churn from drift — only evidence
    /// the user engaged and pulled away does. Shows the user never engages with at
    /// all are caught separately by the NEGLECT path (see `minNeglectedAutoArchives`).
    public static let minGenuineBadEpisodes = 2
    /// A show with zero completions and at least this many auto-archived unplayed
    /// episodes is a "ghost" subscription: new episodes keep arriving and aging
    /// out of the episode limit while the user never finishes one. This is the
    /// neglect path — separate from drift, which needs evidence the user engaged
    /// and pulled away. Completion count (not the auto-archive rate) separates a
    /// ghost sub from healthy high-volume use, where the user finishes some
    /// episodes and lets the rest cycle.
    public static let minNeglectedAutoArchives = 4
    /// Maximum shows surfaced in the drifting list.
    public static let maxStrugglingShows = 5
    /// Minimum abandoned episodes before the median stop point is considered meaningful.
    public static let minAbandonedForStopInsight = 3

    // MARK: Classification

    /// Maps one history entry to an outcome, or nil when the entry is still in
    /// progress or too ambiguous to judge (e.g. legacy entries missing both
    /// completion kind and duration).
    public static func classify(_ entry: ListeningHistoryEntry) -> EpisodeOutcome? {
        if entry.completionKind == .finishedNaturally { return .completed }

        let percent = completionFraction(entry)
        if let percent, percent >= completedPercent { return .completed }

        if entry.listenedSeconds < minListenedSeconds {
            switch entry.status {
            case .archived:
                return .archivedUnplayed(deliberate: entry.completionKind == .manuallyArchived)
            case .played:
                // Marked played without really listening — a deliberate dismissal.
                guard entry.completionKind == .markedPlayed else { return nil }
                return .archivedUnplayed(deliberate: true)
            case .listened:
                // Tapped in and backed out — sampling, not struggle.
                return nil
            }
        }

        // Real listening happened. Only resolved entries can be abandoned; an
        // episode still sitting mid-progress isn't a struggle yet.
        let ended = entry.status == .archived
            || entry.completionKind == .markedPlayed
            || entry.completionKind == .manuallyArchived
            || entry.completionKind == .autoArchived
        guard ended else { return nil }

        if let percent {
            guard percent < abandonedBelowPercent else { return nil }
            return .abandoned(stopAtSeconds: entry.lastPositionSeconds)
        }

        // No duration to judge by, but the user listened and then dismissed it.
        return .abandoned(stopAtSeconds: entry.lastPositionSeconds)
    }

    /// 0.0–1.0 completion fraction, preferring the recorded percent and falling
    /// back to position / duration for legacy entries.
    private static func completionFraction(_ entry: ListeningHistoryEntry) -> Double? {
        if let percent = entry.completionPercent { return percent }
        let duration = entry.episodeDurationSeconds ?? entry.durationSeconds
        guard let duration, duration > 0 else { return nil }
        return entry.lastPositionSeconds / duration
    }

    // MARK: Aggregation

    /// Per-show engagement for entries whose last activity is on/after `since`,
    /// sorted by struggle score descending.
    public static func engagements(entries: [ListeningHistoryEntry], since: Date) -> [ShowEngagement] {
        var byShow: [UUID: ShowEngagement] = [:]
        var stops: [UUID: [TimeInterval]] = [:]

        for entry in entries where entry.lastListenedAt >= since {
            guard let outcome = classify(entry) else { continue }
            var engagement = byShow[entry.subscriptionID]
                ?? ShowEngagement(subscriptionID: entry.subscriptionID, title: entry.podcastTitle)

            switch outcome {
            case .completed:
                engagement.completed += 1
            case .abandoned(let stopAt):
                engagement.abandoned += 1
                stops[entry.subscriptionID, default: []].append(stopAt)
            case .archivedUnplayed(let deliberate):
                if deliberate {
                    engagement.archivedUnplayedDeliberate += 1
                } else {
                    engagement.archivedUnplayedAuto += 1
                }
            }
            byShow[entry.subscriptionID] = engagement
        }

        for (show, values) in stops {
            byShow[show]?.medianStopSeconds = median(values)
        }

        return byShow.values.sorted {
            ($0.struggleScore, $0.totalResolved) > ($1.struggleScore, $1.totalResolved)
        }
    }

    /// The shows worth surfacing in "Shows You're Drifting From": either a ghost
    /// subscription (the neglect path) or genuine drift — enough resolved
    /// episodes, a high enough struggle score, and real drift signals. Muted
    /// shows are always excluded.
    public static func strugglingShows(
        entries: [ListeningHistoryEntry],
        since: Date,
        excluding muted: Set<UUID> = []
    ) -> [ShowEngagement] {
        Array(
            engagements(entries: entries, since: since)
                .filter {
                    guard !muted.contains($0.subscriptionID) else { return false }
                    // Neglect path: a ghost subscription qualifies on its own.
                    if $0.isNeglected { return true }
                    // Drift path: real engagement that trailed off.
                    return $0.totalResolved >= minResolvedEpisodes
                        && $0.struggleScore >= minStruggleScore
                        && $0.abandoned + $0.archivedUnplayedDeliberate >= minGenuineBadEpisodes
                }
                .prefix(maxStrugglingShows)
        )
    }

    // MARK: Row label

    /// Blunt one-line summary for a struggling show, picked by dominant signal.
    public static func label(for engagement: ShowEngagement) -> String {
        // Ghost subscription: episodes keep auto-archiving and the user has never
        // finished — or even abandoned mid-listen — a single one. Pure neglect.
        if engagement.isNeglected, engagement.abandoned == 0, engagement.archivedUnplayedDeliberate == 0 {
            return "Downloaded \(engagement.archivedUnplayedAuto), never played"
        }
        if engagement.archivedUnplayed >= engagement.abandoned, engagement.archivedUnplayed > 0 {
            return "Archived \(engagement.archivedUnplayed) of the last \(engagement.totalResolved) unplayed"
        }
        if engagement.abandoned >= minAbandonedForStopInsight,
           let median = engagement.medianStopSeconds, median >= 60 {
            return "You usually stop around the \(Int((median / 60).rounded()))-minute mark"
        }
        return "Finished \(engagement.completed) of the last \(engagement.totalResolved) episodes"
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
