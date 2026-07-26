import Foundation

// AI CONTEXT — Feeds/ReleaseRadarCyclePlanner.swift
//
// PURPOSE:
// Pure, immutable Release Radar candidate planning extracted verbatim from
// AppState during decomposition Stage 2. AppState snapshots mutable subscription,
// profile-cache, and deferred-backlog inputs; this planner calculates profiles,
// predictions, priority scores, fairness boosts, and deterministic ordering
// off-main. AppState remains the refresh-cycle owner until the later
// FeedRefreshCoordinator stage.
//
// CONCURRENCY:
// DTOs are Sendable values. `candidates` performs no actor-isolated work and may
// run in a detached utility task. Callers must never pass live mutable store
// collections that can change concurrently.
//
// PERSISTENCE / EVENTS:
// None. This file neither mutates subscriptions nor records backlog/profile
// state. The MainActor caller reconciles returned candidates and executes effects.
//
// INVARIANTS:
// - Download filters constrain episode dates and learned release observations.
// - Only feeds due at `now` are returned.
// - Deferred fairness boost remains bounded and deterministic.
// - Final ordering remains score, deferral age, due date, priority rank, title.
// - Do not add network, logging, store, queue, or download side effects here.
struct ReleaseRadarProfileCacheEntry {
    var observationCount: Int
    var newestObservationKey: String?
    var filterSettings: DownloadFilterSettings
    var generatedAt: Date
    var profile: FeedScheduleProfile
}

struct RefreshCycleCandidate: Sendable {
    var subscription: Subscription
    var profile: FeedScheduleProfile
    var prediction: FeedRefreshPrediction
    var priority: FeedRefreshPriority
    var deferredCount: Int = 0
    var deferredSince: Date?
    var deferredScoreBoost: Double = 0
    /// True when the candidate is selected because its last successful check
    /// exceeded the context's hard freshness ceiling, irrespective of prediction.
    var freshnessOverride = false
    /// Effective per-feed ceiling after bulletin/freshness classification.
    var freshnessCeilingSeconds: TimeInterval? = nil
}

struct RefreshPlanningDeferredSnapshot: Sendable {
    var firstDeferredAt: Date
    var deferralCount: Int
}

enum ReleaseRadarCyclePlanner {
    static func candidates(
        subscriptions: [Subscription],
        cachedProfiles: [UUID: FeedScheduleProfile],
        deferred: [UUID: RefreshPlanningDeferredSnapshot],
        minimumRecheckInterval: TimeInterval,
        maximumSuccessfulCheckAge: TimeInterval? = nil,
        now: Date
    ) -> [RefreshCycleCandidate] {
        subscriptions.compactMap { subscription in
            let filter = subscription.downloadFilterSettings
            let profile = cachedProfiles[subscription.id]
                ?? subscription.refreshStats.scheduleProfile(downloadFilterSettings: filter)
            let episodeDates = subscription.episodes
                .filter { filter.evaluation(for: $0).isIncluded }
                .compactMap(\.publishedAt)
            let learnedDates = subscription.refreshStats
                .releaseObservations(includedBy: filter)
                .compactMap(\.publishedAt)
            let fallbackDates = filter.hasActiveFilters
                ? learnedDates
                : subscription.refreshStats.recentPublishDates
            let eligibleEpisodes = subscription.episodes.filter { filter.evaluation(for: $0).isIncluded }
            let latestPublishedAt = eligibleEpisodes.compactMap(\.publishedAt).max()
            let prediction = FeedRefreshScheduling.prediction(
                profile: profile,
                latestPublishedAt: latestPublishedAt,
                publishDates: Array(Set(episodeDates).union(fallbackDates)),
                stats: subscription.refreshStats,
                minRecheckInterval: minimumRecheckInterval,
                now: now
            )
            let successfulCheckAge = subscription.refreshStats.lastFetchedAt
                .map { max(0, now.timeIntervalSince($0)) }
                ?? .greatestFiniteMagnitude
            let effectiveMaximumCheckAge = maximumSuccessfulCheckAge.map {
                FeedFreshnessPolicy.maximumSuccessfulCheckAge(
                    subscriptionTitle: subscription.title,
                    profileKind: profile.kind,
                    defaultAge: $0
                )
            }
            let freshnessOverride = effectiveMaximumCheckAge.map {
                successfulCheckAge >= $0
            } ?? false
            guard prediction.nextDueAt <= now || freshnessOverride else {
                return nil
            }
            // Surveillance/fallback feeds with no reliable release window must
            // not re-enter every four-minute audio batch merely because their
            // calculated due date remains in the past. A successful fetch
            // advances lastFetchedAt, which supplies this durable floor.
            let slowSurveillanceStates: Set<FeedRefreshWindowState> = [
                .fallback, .randomSurveillance, .unreliableDates
            ]
            if slowSurveillanceStates.contains(prediction.state),
               let lastFetchedAt = subscription.refreshStats.lastFetchedAt,
               now.timeIntervalSince(lastFetchedAt) < 30 * 60 {
                return nil
            }
            var priority = FeedRefreshPrioritizer.priority(
                prediction: prediction,
                profile: profile,
                priorityRank: subscription.priorityRank,
                lastFetchedAt: subscription.refreshStats.lastFetchedAt,
                now: now
            )
            var candidate = RefreshCycleCandidate(
                subscription: subscription,
                profile: profile,
                prediction: prediction,
                priority: priority
            )
            candidate.freshnessOverride = freshnessOverride
            candidate.freshnessCeilingSeconds = effectiveMaximumCheckAge
            if freshnessOverride {
                priority.score += 1_000 + min(
                    500,
                    successfulCheckAge / 60
                )
                priority.factors.append("hard freshness ceiling")
                priority.reason = priority.factors.joined(separator: ", ")
                candidate.priority = priority
            }
            if let deferred = deferred[subscription.id] {
                let ageHours = max(0, now.timeIntervalSince(deferred.firstDeferredAt) / 3600)
                let boost = min(40, Double(deferred.deferralCount) * 12 + ageHours * 2)
                let rounded = (boost * 10).rounded() / 10
                if rounded > 0 {
                    candidate.deferredCount = deferred.deferralCount
                    candidate.deferredSince = deferred.firstDeferredAt
                    candidate.deferredScoreBoost = rounded
                    priority.score = ((priority.score + rounded) * 10).rounded() / 10
                    priority.factors.append("deferred \(deferred.deferralCount)x")
                    priority.reason = priority.factors.joined(separator: ", ")
                    candidate.priority = priority
                }
            }
            return candidate
        }.sorted { lhs, rhs in
            if lhs.priority.score != rhs.priority.score {
                return lhs.priority.score > rhs.priority.score
            }
            if lhs.deferredSince != rhs.deferredSince {
                return (lhs.deferredSince ?? .distantFuture) < (rhs.deferredSince ?? .distantFuture)
            }
            if lhs.prediction.nextDueAt != rhs.prediction.nextDueAt {
                return lhs.prediction.nextDueAt < rhs.prediction.nextDueAt
            }
            if lhs.subscription.priorityRank != rhs.subscription.priorityRank {
                return lhs.subscription.priorityRank < rhs.subscription.priorityRank
            }
            return lhs.subscription.title.localizedCaseInsensitiveCompare(rhs.subscription.title) == .orderedAscending
        }
    }
}
