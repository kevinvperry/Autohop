import Foundation

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
    /// A show must have at least this many *genuine* drift signals (abandoned
    /// mid-listen or deliberately archived unplayed) to be flagged. Auto-archive
    /// churn still raises the score, but can never flag a show by itself: a
    /// high-volume feed the episode limit cycles through sits at a 100% auto
    /// rate forever, so no rate threshold separates limit churn from drift —
    /// only evidence the user actually engaged and pulled away does.
    public static let minGenuineBadEpisodes = 2
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

    /// The shows worth surfacing in "Shows You're Drifting From": enough resolved
    /// episodes, a high enough struggle score, and not muted by the user.
    public static func strugglingShows(
        entries: [ListeningHistoryEntry],
        since: Date,
        excluding muted: Set<UUID> = []
    ) -> [ShowEngagement] {
        Array(
            engagements(entries: entries, since: since)
                .filter {
                    !muted.contains($0.subscriptionID)
                        && $0.totalResolved >= minResolvedEpisodes
                        && $0.struggleScore >= minStruggleScore
                        && $0.abandoned + $0.archivedUnplayedDeliberate >= minGenuineBadEpisodes
                }
                .prefix(maxStrugglingShows)
        )
    }

    // MARK: Row label

    /// Blunt one-line summary for a struggling show, picked by dominant signal.
    public static func label(for engagement: ShowEngagement) -> String {
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
