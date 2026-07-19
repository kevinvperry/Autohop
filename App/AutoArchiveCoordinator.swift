//
//  AutoArchiveCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 8 AppState decomposition owner for automatic episode archival.
//  This coordinator is the single owner of the 25-minute execution gate, the
//  After Playing / Inactive Episodes / Episode Limit rules, active-playback and
//  pre-subscription-backlog protection, eligibility diagnostics, per-pass
//  deduplication, and AutoArchiveActivity persistence.
//
//  Archive effects, current-playback protection, queue recomputation, and
//  diagnostic context use weak typed collaborators installed after composition.
//  The coordinator never reaches back into AppState and never relabels
//  listening history itself.
//

import Combine
import Foundation

@MainActor
final class AutoArchiveCoordinator: ObservableObject {
    let activityStore: AutoArchiveActivityStore

    private let subscriptionStore: SubscriptionStore
    private let settingsStore: SettingsStoring
    private let logger: AppLogger
    private let resourceMonitor: ResourceMonitor
    private let interval: TimeInterval
    private let now: () -> Date
    private weak var dispositionWorkflow: EpisodeDispositionWorkflow?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private weak var queueCoordinator: QueueCoordinator?
    private weak var runtimeWorkflow: AppRuntimeWorkflow?
#if DEBUG
    // Characterization-only seam. Production composition uses installRuntime
    // with typed collaborators; tests can isolate rule evaluation without
    // constructing the complete playback/download graph.
    private var testArchiveEpisode:
        (@MainActor (Episode, CompletionKind) async -> Void)?
    private var testCurrentEpisodeID: (() -> UUID?)?
    private var testRefreshQueue: ((String) -> Void)?
    private var testResourceContext: (() -> [String: String])?
#endif
    private var lastSkipLogAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init(
        subscriptionStore: SubscriptionStore,
        settingsStore: SettingsStoring,
        activityStore: AutoArchiveActivityStore? = nil,
        interval: TimeInterval = 25 * 60,
        logger: AppLogger? = nil,
        resourceMonitor: ResourceMonitor? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.subscriptionStore = subscriptionStore
        self.settingsStore = settingsStore
        self.activityStore = activityStore ?? AutoArchiveActivityStore()
        self.interval = interval
        self.logger = logger ?? .shared
        self.resourceMonitor = resourceMonitor ?? .shared
        self.now = now
        self.activityStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func installRuntime(
        dispositionWorkflow: EpisodeDispositionWorkflow,
        playbackCoordinator: PlaybackCoordinator,
        queueCoordinator: QueueCoordinator,
        runtimeWorkflow: AppRuntimeWorkflow
    ) {
        self.dispositionWorkflow = dispositionWorkflow
        self.playbackCoordinator = playbackCoordinator
        self.queueCoordinator = queueCoordinator
        self.runtimeWorkflow = runtimeWorkflow
    }

#if DEBUG
    func installRuntimeAdapters(
        archive: @escaping @MainActor (Episode, CompletionKind) async -> Void,
        currentEpisodeID: @escaping () -> UUID?,
        refreshQueue: @escaping (String) -> Void,
        resourceContext: @escaping () -> [String: String]
    ) {
        testArchiveEpisode = archive
        testCurrentEpisodeID = currentEpisodeID
        testRefreshQueue = refreshQueue
        testResourceContext = resourceContext
    }
#endif

    func runIfNeeded(reason: String, force: Bool = false) async {
        let now = self.now()
        if !force,
           let lastRun = settingsStore.appSettings.lastAutoArchiveRunAt,
           now.timeIntervalSince(lastRun) < interval {
            if lastSkipLogAt.map({ now.timeIntervalSince($0) >= 5 * 60 }) ?? true {
                lastSkipLogAt = now
                logger.info("autoArchive.skip", "Auto archive skipped", metadata: [
                    "reason": reason,
                    "lastRun": lastRun.formatted(date: .numeric, time: .standard),
                    "nextRun": lastRun.addingTimeInterval(interval).formatted(date: .numeric, time: .standard)
                ])
            }
            return
        }

        settingsStore.appSettings.lastAutoArchiveRunAt = now
        await run(reason: reason, now: now)
    }

    func enforceEpisodeLimitBeforeDownload(subscriptionID: UUID) async {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        let limit = subscription.autoArchiveSettings.episodeLimit.rawValue
        guard limit > 0 else { return }

        let cutoff = subscription.subscribedAt
        let active = subscription.episodes
            .filter { episode in
                guard episode.playedState != .archived else { return false }
                if let cutoff, let published = episode.publishedAt, published <= cutoff {
                    return false
                }
                return true
            }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        guard active.count > limit else { return }

        for episode in active.dropFirst(limit)
        where episode.id != activeEpisodeID {
            logger.info("autoArchive.inlineLimit", "Archiving excess episode before new download", metadata: [
                "podcast": subscription.title,
                "episode": episode.title,
                "limit": "\(limit)"
            ])
            await archive(
                episode,
                subscription: subscription,
                rule: .episodeLimit,
                threshold: "Keep \(limit)",
                measuredAge: max(
                    0,
                    now().timeIntervalSince(
                        episode.publishedAt
                            ?? episode.downloadedAt
                            ?? now()
                    )
                )
            )
        }
    }

    private func run(reason: String, now: Date) async {
        guard hasArchiveExecutor else {
            logger.error("autoArchive.workflowMissing", "Auto Archive workflow was not installed")
            return
        }
        logger.info("autoArchive.start", "Auto archive started", metadata: ["reason": reason])
        resourceMonitor.logSnapshot(
            reason: "autoArchive.before",
            context: currentResourceContext,
            force: true
        )

        var archivedCount = 0
        let playingID = activeEpisodeID
        var playedEvaluated = 0
        var playedWaiting = 0
        var inactiveEvaluated = 0
        var inactiveNeverDownloaded = 0
        var inactiveWaiting = 0
        var protectedCurrent = 0
        var limitCandidates = 0
        var limitBacklogProtected = 0
        var archivedPlayed = 0
        var archivedInactive = 0
        var archivedLimit = 0
        var archivedIDs = Set<UUID>()
        let subscriptions = subscriptionStore.subscriptions

        for subscription in subscriptions {
            let settings = subscription.autoArchiveSettings
            let episodes = subscription.episodes.filter { $0.playedState != .archived }
            let cutoff = subscription.subscribedAt
            func isBacklog(_ episode: Episode) -> Bool {
                guard let cutoff, let published = episode.publishedAt else { return false }
                return published <= cutoff
            }

            if let interval = settings.afterPlayed.interval {
                for episode in episodes where episode.playedState == .played {
                    playedEvaluated += 1
                    guard episode.id != playingID, !archivedIDs.contains(episode.id) else {
                        if episode.id == playingID { protectedCurrent += 1 }
                        continue
                    }
                    let age = now.timeIntervalSince(episode.lastPlayedAt ?? now)
                    if age >= interval {
                        await archive(
                            episode,
                            subscription: subscription,
                            rule: .afterPlaying,
                            threshold: settings.afterPlayed.title,
                            measuredAge: age
                        )
                        archivedIDs.insert(episode.id)
                        archivedCount += 1
                        archivedPlayed += 1
                        logger.info("autoArchive.played", "Archived played episode", metadata: [
                            "podcast": subscription.title, "episode": episode.title
                        ])
                    } else {
                        playedWaiting += 1
                    }
                }
            }

            if let interval = settings.afterInactive.interval {
                for episode in episodes where episode.playedState == .unplayed {
                    inactiveEvaluated += 1
                    guard episode.id != playingID, !archivedIDs.contains(episode.id) else {
                        if episode.id == playingID { protectedCurrent += 1 }
                        continue
                    }
                    guard let downloadedAt = episode.downloadedAt else {
                        inactiveNeverDownloaded += 1
                        continue
                    }
                    let downloadAge = now.timeIntervalSince(downloadedAt)
                    let playAge = episode.lastPlayedAt.map { now.timeIntervalSince($0) }
                    let age = [downloadAge, playAge].compactMap { $0 }.min() ?? downloadAge
                    if age >= interval {
                        await archive(
                            episode,
                            subscription: subscription,
                            rule: .inactiveEpisodes,
                            threshold: settings.afterInactive.title,
                            measuredAge: age
                        )
                        archivedIDs.insert(episode.id)
                        archivedCount += 1
                        archivedInactive += 1
                        logger.info("autoArchive.inactive", "Archived inactive episode", metadata: [
                            "podcast": subscription.title, "episode": episode.title
                        ])
                    } else {
                        inactiveWaiting += 1
                    }
                }
            }

            let limit = settings.episodeLimit.rawValue
            if limit > 0 {
                limitBacklogProtected += subscription.episodes.filter {
                    $0.playedState != .archived && isBacklog($0)
                }.count
                let candidates = subscription.episodes
                    .filter {
                        $0.playedState != .archived
                            && !archivedIDs.contains($0.id)
                            && ($0.downloadState == .queued || $0.downloadState == .downloaded)
                            && !isBacklog($0)
                    }
                    .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                limitCandidates += candidates.count
                for (index, episode) in candidates.enumerated()
                where index >= limit && episode.id != playingID {
                    await archive(
                        episode,
                        subscription: subscription,
                        rule: .episodeLimit,
                        threshold: "Keep \(limit)",
                        measuredAge: max(0, now.timeIntervalSince(episode.publishedAt ?? episode.downloadedAt ?? now))
                    )
                    archivedIDs.insert(episode.id)
                    archivedCount += 1
                    archivedLimit += 1
                    logger.info("autoArchive.limit", "Archived episode over limit", metadata: [
                        "podcast": subscription.title, "episode": episode.title, "limit": "\(limit)"
                    ])
                }
            }
        }

        refreshQueue(reason: "autoArchive.finished")
        logger.info("autoArchive.eligibility", "Auto Archive eligibility summary", metadata: [
            "reason": reason,
            "subscriptions": "\(subscriptions.count)",
            "playedEvaluated": "\(playedEvaluated)",
            "playedWaiting": "\(playedWaiting)",
            "inactiveEvaluated": "\(inactiveEvaluated)",
            "inactiveNeverDownloaded": "\(inactiveNeverDownloaded)",
            "inactiveWaiting": "\(inactiveWaiting)",
            "protectedCurrent": "\(protectedCurrent)",
            "limitCandidates": "\(limitCandidates)",
            "limitBacklogProtected": "\(limitBacklogProtected)",
            "archivedPlayed": "\(archivedPlayed)",
            "archivedInactive": "\(archivedInactive)",
            "archivedLimit": "\(archivedLimit)"
        ])
        logger.info("autoArchive.finished", "Auto archive finished", metadata: [
            "reason": reason,
            "archivedCount": "\(archivedCount)"
        ])
        var context = currentResourceContext
        context["archivedCount"] = "\(archivedCount)"
        resourceMonitor.logSnapshot(reason: "autoArchive.after", context: context, force: true)
    }

    private func archive(
        _ episode: Episode,
        subscription: Subscription,
        rule: AutoArchiveActivityRule,
        threshold: String,
        measuredAge: TimeInterval
    ) async {
        await executeArchive(episode)
        activityStore.record(AutoArchiveActivity(
            episodeID: episode.id,
            subscriptionID: subscription.id,
            episodeTitle: episode.title,
            podcastTitle: subscription.title,
            archivedAt: now(),
            rule: rule,
            configuredThreshold: threshold,
            measuredAgeSeconds: measuredAge
        ))
    }

    private var activeEpisodeID: UUID? {
#if DEBUG
        if let testCurrentEpisodeID {
            return testCurrentEpisodeID()
        }
#endif
        return playbackCoordinator?.currentEpisode?.id
    }

    private var currentResourceContext: [String: String] {
#if DEBUG
        if let testResourceContext {
            return testResourceContext()
        }
#endif
        return runtimeWorkflow?.resourceContext() ?? [:]
    }

    private var hasArchiveExecutor: Bool {
        if dispositionWorkflow != nil {
            return true
        }
#if DEBUG
        return testArchiveEpisode != nil
#else
        return false
#endif
    }

    private func refreshQueue(reason: String) {
#if DEBUG
        if let testRefreshQueue {
            testRefreshQueue(reason)
            return
        }
#endif
        queueCoordinator?.recompute(reason: reason)
    }

    private func executeArchive(_ episode: Episode) async {
#if DEBUG
        if let testArchiveEpisode {
            await testArchiveEpisode(episode, .autoArchived)
            return
        }
#endif
        await dispositionWorkflow?.archive(
            episode,
            completionKind: .autoArchived
        )
    }
}
