import Foundation

// AI CONTEXT — App/AutoDownloadIntentWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Durable automatic-download orchestration that begins after a feed merge. It
// persists intent before asynchronous work, revalidates current subscription,
// browse status, filters, candidate recency, played/archive state, and failure
// backoff, applies the episode-limit precondition, invokes the shared transfer
// workflow, refreshes Up Next, and settles intents only at durable terminal
// states.
//
// DURABILITY / CONCURRENCY:
// - Intent is written before the post-refresh Task starts.
// - AutoDownloadWorkflow serializes launch/foreground/background drains.
// - Queued/downloading/temporarily blocked/failed work retains intent.
// - Downloaded, played, archived, removed, browse, filter-excluded, or
//   superseded work removes intent.
// - The newest currently eligible episode is re-read after episode-limit
//   enforcement so archive side effects cannot leave a stale target.
//
// This workflow never performs the network transfer itself and never chooses
// feed-refresh timing.

@MainActor
final class AutoDownloadIntentWorkflow {
    private let state: AutoDownloadWorkflow
    private let subscriptionStore: SubscriptionStore
    private let downloadCoordinator: DownloadCoordinator
    private let autoArchiveCoordinator: AutoArchiveCoordinator
    private let queueCoordinator: QueueCoordinator
    private let logger: AppLogger
    private let transferWorkflow: DownloadTransferWorkflow

    init(
        state: AutoDownloadWorkflow,
        subscriptionStore: SubscriptionStore,
        downloadCoordinator: DownloadCoordinator,
        autoArchiveCoordinator: AutoArchiveCoordinator,
        queueCoordinator: QueueCoordinator,
        logger: AppLogger,
        transferWorkflow: DownloadTransferWorkflow
    ) {
        self.state = state
        self.subscriptionStore = subscriptionStore
        self.downloadCoordinator = downloadCoordinator
        self.autoArchiveCoordinator = autoArchiveCoordinator
        self.queueCoordinator = queueCoordinator
        self.logger = logger
        self.transferWorkflow = transferWorkflow
    }

    func newestCandidate(in subscription: Subscription) -> Episode? {
        subscription.episodes
            .filter { episode in
                episode.playedState != .played
                    && episode.playedState != .archived
                    && episode.downloadState != .downloaded
                    && episode.downloadState != .queued
                    && episode.downloadState != .downloading
                    && subscription.downloadFilterSettings
                        .evaluation(for: episode)
                        .isIncluded
            }
            .sorted {
                ($0.publishedAt ?? .distantPast)
                    > ($1.publishedAt ?? .distantPast)
            }
            .first
    }

    func schedule(
        episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String,
        refreshUpNextAfterMerge: Bool,
        detectionContext: String,
        sceneActive: Bool,
        batteryState: String,
        detectedAt: Date,
        sceneActivationSequence: Int
    ) {
        if let failure = state.intentStore.activeFailure(
            episodeID: episode.id,
            mediaURL: episode.audioURL
        ) {
            logger.info(
                "download.exhaustionCooldownSkipped",
                "Unchanged exhausted enclosure remains in its durable cooldown",
                metadata: [
                    "podcast": podcastTitle,
                    "episodeID": episode.id.uuidString,
                    "exhaustions": "\(failure.consecutiveExhaustions)",
                    "retryAfterSeconds": String(
                        format: "%.0f",
                        failure.retryAfter.timeIntervalSinceNow
                    )
                ]
            )
            return
        }
        state.intentStore.record(
            episodeID: episode.id,
            subscriptionID: subscriptionID,
            podcastTitle: podcastTitle,
            mediaURL: episode.audioURL
        )
        downloadCoordinator.recordEpisodeDetection(
            episodeID: episode.id,
            detectedAt: detectedAt,
            context: detectionContext,
            sceneActivationSequence: sceneActivationSequence
        )
        logger.info(
            "feed.autoDownloadScheduled",
            "Auto-download scheduled after feed refresh",
            metadata: [
                "podcast": podcastTitle,
                "episode": episode.title,
                "episodeID": episode.id.uuidString,
                "intentPersisted": "true",
                "publishedAt":
                    episode.publishedAt?.ISO8601Format() ?? "unknown",
                "publicationAgeSeconds": episode.publishedAt.map {
                    String(
                        format: "%.1f",
                        max(0, detectedAt.timeIntervalSince($0))
                    )
                } ?? "unknown",
                "detectionContext": detectionContext,
                "sceneActive": "\(sceneActive)",
                "batteryState": batteryState
            ]
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(
                episode: episode,
                subscriptionID: subscriptionID,
                podcastTitle: podcastTitle,
                refreshUpNextAfterMerge: refreshUpNextAfterMerge
            )
            self.resolveIfSettled(
                episodeID: episode.id,
                subscriptionID: subscriptionID
            )
        }
    }

    func resolveIfSettled(episodeID: UUID, subscriptionID: UUID) {
        guard state.intentStore.contains(episodeID: episodeID) else { return }
        func settle(_ reason: String) {
            state.intentStore.remove(episodeID: episodeID)
            logger.info(
                "download.intentResolved",
                "Auto-download intent settled",
                metadata: [
                    "episodeID": episodeID.uuidString,
                    "reason": reason
                ]
            )
        }

        guard let subscription = subscriptionStore.subscription(
            id: subscriptionID
        ),
              subscription.browseDate == nil else {
            settle("subscriptionGone")
            return
        }
        guard let episode = subscriptionStore.episode(
            subscriptionID: subscriptionID,
            episodeID: episodeID
        ) else {
            settle("episodeGone")
            return
        }
        if episode.downloadState == .downloaded {
            settle("downloaded")
            return
        }
        if episode.playedState == .played || episode.playedState == .archived {
            settle("playedOrArchived")
            return
        }
        if episode.downloadState == .downloading
            || episode.downloadState == .queued {
            return
        }
        if !subscription.downloadFilterSettings.evaluation(for: episode).isIncluded {
            settle("filterExcluded")
            return
        }
        if newestCandidate(in: subscription)?.guid != episode.guid {
            settle("supersededByNewer")
        }
    }

    func drain(reason: String) async {
        guard !state.isDraining else { return }
        let pending = state.intentStore.intents
        guard !pending.isEmpty else { return }
        await state.withExclusiveDrain { [weak self] in
            guard let self else { return }
            self.logger.info(
                "download.intentDrain",
                "Draining persisted auto-download intents",
                metadata: [
                    "reason": reason,
                    "count": "\(pending.count)"
                ]
            )
            for intent in pending {
                self.resolveIfSettled(
                    episodeID: intent.episodeID,
                    subscriptionID: intent.subscriptionID
                )
                guard self.state.intentStore.contains(
                    episodeID: intent.episodeID
                ),
                      let episode = self.subscriptionStore.episode(
                        subscriptionID: intent.subscriptionID,
                        episodeID: intent.episodeID
                      ) else {
                    continue
                }
                if episode.downloadState == .downloading
                    || episode.downloadState == .queued {
                    continue
                }
                if let failure = self.state.intentStore.activeFailure(
                    episodeID: episode.id,
                    mediaURL: episode.audioURL
                ) {
                    self.logger.info(
                        "download.exhaustionCooldownSkipped",
                        "Persisted auto-download remains in terminal-failure cooldown",
                        metadata: [
                            "episodeID": episode.id.uuidString,
                            "exhaustions": "\(failure.consecutiveExhaustions)",
                            "retryAfterSeconds": String(
                                format: "%.0f",
                                failure.retryAfter.timeIntervalSinceNow
                            )
                        ]
                    )
                    continue
                }
                await self.run(
                    episode: episode,
                    subscriptionID: intent.subscriptionID,
                    podcastTitle: intent.podcastTitle,
                    refreshUpNextAfterMerge: true
                )
                self.resolveIfSettled(
                    episodeID: intent.episodeID,
                    subscriptionID: intent.subscriptionID
                )
            }
        }
    }

    private func run(
        episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String,
        refreshUpNextAfterMerge: Bool
    ) async {
        guard let subscription = subscriptionStore.subscription(
            id: subscriptionID
        ) else {
            logSkip(
                "Auto-download skipped because subscription no longer exists",
                podcastTitle: podcastTitle,
                episode: episode
            )
            return
        }
        guard subscription.browseDate == nil else {
            logSkip(
                "Auto-download skipped for browse preview",
                podcastTitle: podcastTitle,
                episode: episode
            )
            return
        }
        guard let candidate = newestCandidate(in: subscription),
              candidate.guid == episode.guid else {
            logger.info(
                "feed.autoDownloadSkipped",
                "Auto-download skipped because the scheduled episode is no longer eligible",
                metadata: [
                    "podcast": subscription.title,
                    "scheduledEpisode": episode.title,
                    "scheduledEpisodeID": episode.id.uuidString
                ]
            )
            return
        }
        if let failure = state.intentStore.activeFailure(
            episodeID: candidate.id,
            mediaURL: candidate.audioURL
        ) {
            logger.info(
                "download.exhaustionCooldownSkipped",
                "Auto-download suppressed until the durable exhaustion cooldown ends",
                metadata: [
                    "podcast": subscription.title,
                    "episodeID": candidate.id.uuidString,
                    "exhaustions": "\(failure.consecutiveExhaustions)",
                    "retryAfterSeconds": String(
                        format: "%.0f",
                        failure.retryAfter.timeIntervalSinceNow
                    )
                ]
            )
            return
        }

        if let backoff = downloadCoordinator.failureBackoff[candidate.guid],
           Date() < backoff.retryAfter {
            logger.info(
                "download.backoffSkipped",
                "Auto-download skipped — backing off after repeated failures",
                metadata: [
                    "podcast": subscription.title,
                    "episode": candidate.title,
                    "failures": "\(backoff.failures)",
                    "retryAfterSecs": String(
                        format: "%.0f",
                        backoff.retryAfter.timeIntervalSinceNow
                    )
                ]
            )
            return
        }

        logger.info(
            "feed.autoDownloadStart",
            "Starting auto-download after feed refresh",
            metadata: [
                "podcast": subscription.title,
                "episode": candidate.title,
                "episodeID": candidate.id.uuidString
            ]
        )
        await autoArchiveCoordinator.enforceEpisodeLimitBeforeDownload(
            subscriptionID: subscriptionID,
            incomingEpisodeID: candidate.id
        )
        let target = subscriptionStore.subscription(id: subscriptionID)
            .flatMap { newestCandidate(in: $0) } ?? candidate
        await transferWorkflow.download(
            target,
            subscriptionID: subscriptionID,
            podcastTitle: podcastTitle,
            showCompletionMessage: false,
            isAutomatic: true
        )
        if refreshUpNextAfterMerge {
            queueCoordinator.scheduleRecompute(
                reason: "feed.download.\(podcastTitle)"
            )
        }
    }

    private func logSkip(
        _ message: String,
        podcastTitle: String,
        episode: Episode
    ) {
        logger.info("feed.autoDownloadSkipped", message, metadata: [
            "podcast": podcastTitle,
            "episode": episode.title,
            "episodeID": episode.id.uuidString
        ])
    }
}
