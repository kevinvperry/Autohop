import Foundation

// AI CONTEXT — App/ReleaseRadarWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Release Radar learning, prediction, due-date, profile-cache, off-main planning,
// diagnostic identity, and next-background-wake workflow. It is the only code
// that converts subscription release observations into FeedScheduleProfile,
// FeedRefreshPrediction, and scored RefreshCycleCandidate values.
//
// PERFORMANCE:
// Profiles are fingerprinted by observation count/newest key/filter settings and
// retained for FeedRefreshCoordinator.profileCacheTTL. Cold-start warming and
// all-feed candidate planning execute at utility priority away from MainActor.
//
// INVARIANTS:
// - Download Filters affect both learning and latest-release evidence.
// - One-item feeds combine visible dates with durable observation history.
// - Rebuild Prediction learns only; it does not merge episodes, alter normal
//   last-fetched cadence, download media, or archive anything.
// - Background scheduling honors feed failure backoff when selecting the
//   earliest effective due date.
// - Wall-clock time is injected so cache expiry, prediction, and background
//   scheduling tests do not depend on the process clock.

@MainActor
final class ReleaseRadarWorkflow {
    private let coordinator: FeedRefreshCoordinator
    private let feedService: any FeedServicing
    private let subscriptionStore: SubscriptionStore
    private let logger: AppLogger
    private let minimumRecheckInterval: TimeInterval
    private let now: () -> Date

    init(
        coordinator: FeedRefreshCoordinator,
        feedService: any FeedServicing,
        subscriptionStore: SubscriptionStore,
        logger: AppLogger,
        minimumRecheckInterval: TimeInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.feedService = feedService
        self.subscriptionStore = subscriptionStore
        self.logger = logger
        self.minimumRecheckInterval = minimumRecheckInterval
        self.now = now
    }

    func nextRefreshDue(for subscription: Subscription) -> Date {
        prediction(for: subscription).nextDueAt
    }

    func schedule(
        for subscription: Subscription,
        now: Date? = nil
    ) -> (profile: FeedScheduleProfile, prediction: FeedRefreshPrediction) {
        let effectiveNow = now ?? self.now()
        let profile = releaseProfile(for: subscription)
        return (
            profile,
            prediction(
                for: subscription,
                profile: profile,
                now: effectiveNow
            )
        )
    }

    @discardableResult
    func rebuildPrediction(
        for subscription: Subscription,
        episodeLimit: Int = 100
    ) async -> Int? {
        logger.info(
            "feed.rebuildPrediction",
            "Rebuilding Release Radar prediction from feed history",
            metadata: feedMetadata(
                for: subscription,
                includeURL: false,
                extra: ["episodeLimit": "\(episodeLimit)"]
            )
        )
        do {
            let result = try await feedService.refresh(
                feedURL: subscription.feedURL,
                subscriptionID: subscription.id,
                episodeLimit: episodeLimit
            )
            let current = subscriptionStore.subscription(id: subscription.id)
                ?? subscription
            let filters = current.downloadFilterSettings
            let eligible = result.episodes.filter {
                filters.evaluation(for: $0).isIncluded
            }
            let historicalKeys = Set(
                result.episodes.map(RefreshStats.releaseObservationKey(for:))
            )
            var stats = current.refreshStats
            let newlyRecorded = stats.recordEpisodeObservations(
                result.episodes,
                previouslyKnownEpisodeKeys: historicalKeys,
                downloadFilterSettings: filters
            )
            subscriptionStore.updateRefreshStats(
                subscriptionID: subscription.id,
                stats: stats
            )
            let profile = stats.scheduleProfile(downloadFilterSettings: filters)
            let windowText: String
            if let window = profile.releaseWindow {
                windowText = String(
                    format: "%02d:%02d-%02d:%02d",
                    window.startMinuteOfDay / 60,
                    window.startMinuteOfDay % 60,
                    window.endMinuteOfDay / 60,
                    window.endMinuteOfDay % 60
                )
            } else {
                windowText = "none"
            }
            logger.info(
                "feed.rebuildPrediction",
                "Rebuilt Release Radar prediction",
                metadata: feedMetadata(
                    for: subscription,
                    includeURL: false,
                    extra: [
                        "fetched": "\(result.episodes.count)",
                        "eligibleForLearning": "\(eligible.count)",
                        "newlyRecorded": "\(newlyRecorded)",
                        "totalObservations":
                            "\(stats.releaseObservations(includedBy: filters).count)",
                        "kind": String(describing: profile.kind),
                        "confidence": String(
                            format: "%.2f",
                            profile.confidence
                        ),
                        "reliableDates": "\(profile.reliableDateCount)",
                        "window": windowText
                    ]
                )
            )
            return eligible.count
        } catch {
            if Self.isCancellationError(error) { return nil }
            logger.error(
                "feed.rebuildPredictionFailed",
                "Could not rebuild Release Radar prediction",
                metadata: feedMetadata(
                    for: subscription,
                    includeURL: false,
                    extra: ["error": String(describing: error)]
                )
            )
            return nil
        }
    }

    func prediction(
        for subscription: Subscription,
        now: Date? = nil
    ) -> FeedRefreshPrediction {
        prediction(
            for: subscription,
            profile: releaseProfile(for: subscription),
            now: now ?? self.now()
        )
    }

    func warmProfileCache() {
        let snapshot = subscriptionStore.subscriptions.filter {
            !$0.excludeFromAutoFeedRefresh && $0.browseDate == nil
        }
        guard !snapshot.isEmpty else { return }
        let generatedAt = now()
        Task.detached(priority: .utility) { [weak self] in
            var warmed: [UUID: ReleaseRadarProfileCacheEntry] = [:]
            for subscription in snapshot {
                let observations =
                    subscription.refreshStats.releaseObservations
                warmed[subscription.id] = ReleaseRadarProfileCacheEntry(
                    observationCount: observations.count,
                    newestObservationKey: observations.last?.episodeKey,
                    filterSettings: subscription.downloadFilterSettings,
                    generatedAt: generatedAt,
                    profile: subscription.refreshStats.scheduleProfile(
                        downloadFilterSettings:
                            subscription.downloadFilterSettings
                    )
                )
            }
            let entries = warmed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.coordinator.mergeWarmedProfiles(entries)
                self.logger.info(
                    "radar.profileCacheWarmed",
                    "Release Radar profile cache warmed off-main",
                    metadata: ["profiles": "\(entries.count)"]
                )
            }
        }
    }

    func candidates(
        from subscriptions: [Subscription],
        now: Date
    ) async -> [RefreshCycleCandidate] {
        let cachedProfiles = subscriptions.reduce(
            into: [UUID: FeedScheduleProfile]()
        ) { result, subscription in
            let observations = subscription.refreshStats.releaseObservations
            if let entry = coordinator.profileCache[subscription.id],
               entry.observationCount == observations.count,
               entry.newestObservationKey == observations.last?.episodeKey,
               entry.filterSettings == subscription.downloadFilterSettings,
               now.timeIntervalSince(entry.generatedAt)
                    < FeedRefreshCoordinator.profileCacheTTL {
                result[subscription.id] = entry.profile
            }
        }
        let deferred = coordinator.deferredBacklog.mapValues {
            RefreshPlanningDeferredSnapshot(
                firstDeferredAt: $0.firstDeferredAt,
                deferralCount: $0.deferralCount
            )
        }
        let interval = minimumRecheckInterval
        return await Task.detached(priority: .utility) {
            ReleaseRadarCyclePlanner.candidates(
                subscriptions: subscriptions,
                cachedProfiles: cachedProfiles,
                deferred: deferred,
                minimumRecheckInterval: interval,
                now: now
            )
        }.value
    }

    func scheduleNextBackgroundRefresh() {
        let now = now()
        let active = subscriptionStore.subscriptions.filter {
            !$0.excludeFromAutoFeedRefresh
        }
        let nextDue = active
            .map { subscription in
                let feedDueAt = nextRefreshDue(for: subscription)
                let backoffUntil =
                    coordinator.failureBackoffUntil[subscription.id]
                let effectiveDueAt =
                    BackgroundTaskCoordinator.effectiveFeedDueDate(
                        feedDueDate: feedDueAt,
                        backoffUntil: backoffUntil,
                        now: now
                    )
                return (
                    subscription: subscription,
                    feedDueAt: feedDueAt,
                    backoffUntil: backoffUntil,
                    effectiveDueAt: effectiveDueAt
                )
            }
            .min { lhs, rhs in
                if lhs.effectiveDueAt != rhs.effectiveDueAt {
                    return lhs.effectiveDueAt < rhs.effectiveDueAt
                }
                return lhs.subscription.title.localizedCaseInsensitiveCompare(
                    rhs.subscription.title
                ) == .orderedAscending
            }
        if let nextDue {
            let secondsUntilDue = max(
                0,
                Int(nextDue.effectiveDueAt.timeIntervalSince(now).rounded())
            )
            let activeBackoffCount = active.reduce(into: 0) {
                count,
                subscription in
                if let until = coordinator.failureBackoffUntil[subscription.id],
                   until > now {
                    count += 1
                }
            }
            logger.info(
                "background.nextDue",
                "Selected next feed due date for background refresh scheduling",
                metadata: feedMetadata(
                    for: nextDue.subscription,
                    includeURL: false,
                    extra: [
                        "feedDueAt": logDate(nextDue.feedDueAt),
                        "backoffUntil": logDate(nextDue.backoffUntil),
                        "nextDueAt": logDate(nextDue.effectiveDueAt),
                        "delayedByBackoff":
                            "\(nextDue.effectiveDueAt > nextDue.feedDueAt)",
                        "secondsUntilDue": "\(secondsUntilDue)",
                        "activeSubscriptions": "\(active.count)",
                        "activeBackoffSubscriptions":
                            "\(activeBackoffCount)",
                        "skippedInactive":
                            "\(subscriptionStore.subscriptions.count - active.count)"
                    ]
                )
            )
        } else {
            logger.info(
                "background.nextDue",
                "No active subscription available for background refresh scheduling",
                metadata: [
                    "activeSubscriptions": "0",
                    "skippedInactive":
                        "\(subscriptionStore.subscriptions.count)"
                ]
            )
        }
        BackgroundTaskCoordinator.scheduleAppRefreshIfNeeded(
            earliestBeginDate: nextDue?.effectiveDueAt
        )
    }

    func feedMetadata(
        for subscription: Subscription,
        includeURL: Bool = true,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata = [
            "podcast": subscription.title,
            "subscriptionID": subscription.id.uuidString,
            "feedHash": feedHash(for: subscription.feedURL)
        ]
        if includeURL {
            metadata["url"] = subscription.feedURL.absoluteString
        }
        metadata.merge(extra) { _, new in new }
        return metadata
    }

    func feedHash(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func logDate(_ date: Date?) -> String {
        guard let date else { return "none" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func releaseProfile(
        for subscription: Subscription
    ) -> FeedScheduleProfile {
        let observations = subscription.refreshStats.releaseObservations
        let filters = subscription.downloadFilterSettings
        let now = now()
        if let entry = coordinator.profileCache[subscription.id],
           entry.observationCount == observations.count,
           entry.newestObservationKey == observations.last?.episodeKey,
           entry.filterSettings == filters,
           now.timeIntervalSince(entry.generatedAt)
                < FeedRefreshCoordinator.profileCacheTTL {
            return entry.profile
        }
        let profile = subscription.refreshStats.scheduleProfile(
            downloadFilterSettings: filters
        )
        coordinator.profileCache[subscription.id] =
            ReleaseRadarProfileCacheEntry(
                observationCount: observations.count,
                newestObservationKey: observations.last?.episodeKey,
                filterSettings: filters,
                generatedAt: now,
                profile: profile
            )
        return profile
    }

    private func prediction(
        for subscription: Subscription,
        profile: FeedScheduleProfile,
        now: Date
    ) -> FeedRefreshPrediction {
        let filters = subscription.downloadFilterSettings
        let eligibleEpisodeDates = subscription.episodes
            .filter { filters.evaluation(for: $0).isIncluded }
            .compactMap(\.publishedAt)
        let learnedEligibleDates = subscription.refreshStats
            .releaseObservations(includedBy: filters)
            .compactMap(\.publishedAt)
        let fallbackDates = filters.hasActiveFilters
            ? learnedEligibleDates
            : subscription.refreshStats.recentPublishDates
        let publishDates = Set(eligibleEpisodeDates).union(fallbackDates)
        return FeedRefreshScheduling.prediction(
            profile: profile,
            latestPublishedAt: newestEligibleEpisode(in: subscription)?
                .publishedAt,
            publishDates: Array(publishDates),
            stats: subscription.refreshStats,
            minRecheckInterval: minimumRecheckInterval,
            now: now
        )
    }

    private func newestEligibleEpisode(
        in subscription: Subscription
    ) -> Episode? {
        subscription.episodes
            .filter {
                subscription.downloadFilterSettings
                    .evaluation(for: $0)
                    .isIncluded
            }
            .sorted {
                ($0.publishedAt ?? .distantPast)
                    > ($1.publishedAt ?? .distantPast)
            }
            .first
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }
}
