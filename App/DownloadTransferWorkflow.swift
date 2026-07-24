import Foundation

// AI CONTEXT — App/DownloadTransferWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Exclusive implementation of one episode media-transfer transaction and the
// bounded three-slot FIFO that feeds it. It owns network-policy gating,
// duplicate suppression, queue admission/draining, existing-file reuse,
// DownloadManager invocation, store/activity/progress settlement, watchdog and
// failure-backoff cleanup, error classification, Stats bytes, notifications,
// Play Instant eligibility delivery, and resource diagnostics.
//
// CONCURRENCY:
// MainActor serializes queue/slot state. A queued item starts in an unstructured
// MainActor task only after a slot is released; the queue and active count remain
// stored exclusively in DownloadCoordinator. DownloadManager owns URLSession
// transfer lifetime and background continuation.
//
// INVARIANTS:
// - At most `DownloadCoordinator.maxConcurrentDownloads` transactions execute.
// - One episode appears at most once in the pending queue.
// - Existing verified local media is reused without network transfer.
// - Superseded rolling-feed cancellation never becomes a user-visible failure.
// - Genuine failures retain durable automatic intent and receive exponential
//   per-GUID backoff through DownloadCoordinator.
// - PlaybackMediaWorkflow supplies canonical local-media resolution/duration.
// - File-size inspection runs off-main and downloaded-state/duration mutations
//   publish as one observer transaction. Slow-settlement diagnostics expose
//   store, stats, and effects sub-stages for actionable overnight-log evidence.
// - BackgroundWakeMonitor counts a transfer only when DownloadManager submission
//   begins; queued/blocked/reused requests are not misreported as network starts.

@MainActor
final class DownloadTransferWorkflow {
    private let coordinator: DownloadCoordinator
    private let downloadManager: any DownloadManaging
    private let subscriptionStore: SubscriptionStore
    private let settingsStore: any SettingsStoring
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let logger: AppLogger
    private let mediaWorkflow: PlaybackMediaWorkflow
    private let notificationWorkflow: NewEpisodeNotificationWorkflow
    private let runtimeWorkflow: AppRuntimeWorkflow
    private weak var playInstantWorkflow: PlayInstantWorkflow?

    init(
        coordinator: DownloadCoordinator,
        downloadManager: any DownloadManaging,
        subscriptionStore: SubscriptionStore,
        settingsStore: any SettingsStoring,
        historyStatsCoordinator: HistoryStatsCoordinator,
        logger: AppLogger,
        mediaWorkflow: PlaybackMediaWorkflow,
        notificationWorkflow: NewEpisodeNotificationWorkflow,
        runtimeWorkflow: AppRuntimeWorkflow
    ) {
        self.coordinator = coordinator
        self.downloadManager = downloadManager
        self.subscriptionStore = subscriptionStore
        self.settingsStore = settingsStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.logger = logger
        self.mediaWorkflow = mediaWorkflow
        self.notificationWorkflow = notificationWorkflow
        self.runtimeWorkflow = runtimeWorkflow
    }

    /// Installed after graph construction to break the intentional
    /// transfer → Play Instant → playback-start → transfer cycle.
    func observePlayInstant(_ workflow: PlayInstantWorkflow) {
        playInstantWorkflow = workflow
    }

    func download(
        _ episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String,
        showCompletionMessage: Bool,
        isAutomatic: Bool = false
    ) async {
        runtimeWorkflow.logResourceSnapshot(reason: "download.before", extra: [
            "episode": episode.title,
            "podcast": podcastTitle
        ], force: false)
        guard coordinator.isAllowed(settings: settingsStore.appSettings) else {
            logger.info("download.blocked", "Download blocked by network settings", metadata: [
                "episode": episode.title,
                "podcast": podcastTitle
            ])
            coordinator.message = "Downloads are disabled on the current network."
            return
        }
        if isAutomatic,
           let circuit = coordinator.automaticDownloadBlock(
            for: episode.audioURL
           ) {
            logger.info(
                "download.circuitBreakerSkipped",
                "Automatic download deferred by failure circuit breaker",
                metadata: [
                    "episode": episode.title,
                    "episodeID": episode.id.uuidString,
                    "podcast": podcastTitle,
                    "scope": circuit,
                    "mediaHost": episode.audioURL.host ?? "unknown"
                ]
            )
            subscriptionStore.markEpisodeDownloadFailed(
                subscriptionID: subscriptionID,
                episodeID: episode.id
            )
            coordinator.activityStore.fail(
                episode: episode,
                podcastTitle: podcastTitle,
                error: "Download host is cooling down after repeated stalls."
            )
            return
        }

        if let activeActivity = coordinator.activityStore.activeActivities.first(
            where: {
                $0.episodeID == episode.id || $0.mediaURL == episode.audioURL
            }
        ), activeActivity.status == .downloading {
            logger.warning(
                "download.duplicateBlocked",
                "Duplicate download request blocked by app state",
                metadata: [
                    "episode": episode.title,
                    "podcast": podcastTitle,
                    "episodeID": episode.id.uuidString,
                    "mediaURL": episode.audioURL.absoluteString
                ]
            )
            coordinator.message = "\(episode.title) is already downloading."
            return
        }

        if coordinator.activeCount >= coordinator.maxConcurrentDownloads {
            guard !coordinator.pendingQueue.contains(
                where: { $0.episode.id == episode.id }
            ) else {
                return
            }
            logger.info(
                "download.queued",
                "Download deferred — concurrency cap reached",
                metadata: [
                    "episode": episode.title,
                    "podcast": podcastTitle,
                    "activeCount": "\(coordinator.activeCount)",
                    "queueDepth": "\(coordinator.pendingQueue.count + 1)"
                ]
            )
            coordinator.pendingQueue.append(
                DownloadCoordinator.PendingDownload(
                    episode: episode,
                    subscriptionID: subscriptionID,
                    podcastTitle: podcastTitle,
                    showCompletionMessage: showCompletionMessage,
                    isAutomatic: isAutomatic
                )
            )
            return
        }

        coordinator.activeCount += 1
        defer {
            coordinator.activeCount -= 1
            drainQueue()
        }

        if let reusableEpisode = reusableDownloadedEpisode(for: episode) {
            logger.info("download.reuse", "Using existing downloaded file", metadata: [
                "episode": reusableEpisode.title,
                "podcast": podcastTitle
            ])
            if let localFileURL = reusableEpisode.localFileURL,
               let duration = await mediaWorkflow.localDuration(
                from: localFileURL
               ) {
                subscriptionStore.updateEpisodeDuration(
                    subscriptionID: subscriptionID,
                    episodeID: reusableEpisode.id,
                    durationSeconds: duration
                )
            }
            coordinator.progressModel.progress.removeValue(
                forKey: reusableEpisode.id
            )
            if showCompletionMessage {
                coordinator.message = "\(reusableEpisode.title) is already downloaded."
            }
            runtimeWorkflow.logResourceSnapshot(reason: "download.reuse", extra: [
                "episode": reusableEpisode.title,
                "podcast": podcastTitle
            ], force: false)
            return
        }

        let transferStartedAt = runtimeWorkflow.now
        let detectionAtStart = coordinator.detectionMetadata(
            episodeID: episode.id,
            now: transferStartedAt,
            sceneActivationSequence: runtimeWorkflow.sceneActivationSequence
        )
        logger.info("download.start", "Starting episode download", metadata: [
            "episode": episode.title,
            "episodeID": episode.id.uuidString,
            "podcast": podcastTitle,
            "mediaHost": episode.audioURL.host ?? "unknown",
            "mediaKind": episode.mediaKind.rawValue,
            "fileSizeBytes": episode.fileSizeBytes.map(String.init) ?? "unknown",
            "automatic": "\(isAutomatic)",
            "sceneActive": "\(runtimeWorkflow.isSceneActive)",
            "applicationForeground": "\(runtimeWorkflow.isAppForeground)",
            "batteryState": ResourceMonitor.shared.externalPowerStateLabel,
            "publishedAt": episode.publishedAt?.ISO8601Format() ?? "unknown"
        ].merging(detectionAtStart) { _, new in new })
        coordinator.activityStore.start(
            episode: episode,
            podcastTitle: podcastTitle,
            expectedBytes: episode.fileSizeBytes
        )
        subscriptionStore.markEpisodeDownloading(
            subscriptionID: subscriptionID,
            episodeID: episode.id
        )
        BackgroundWakeMonitor.shared.recordDownloadSubmitted()

        do {
            let localFileURL = try await downloadManager.download(
                episode,
                allowsCellular: settingsStore.appSettings.downloadOverCellular
            )
            let duration = await mediaWorkflow.localDuration(
                from: localFileURL
            )
            let downloadedBytes = await localFileByteCount(
                at: localFileURL,
                fallback: episode.fileSizeBytes ?? 0
            )
            let settlementMemory = ResourceMonitor.shared
                .memoryFootprintSample()
            let settlementStartedAt = CFAbsoluteTimeGetCurrent()
            let storeStartedAt = CFAbsoluteTimeGetCurrent()
            subscriptionStore.beginChangeNotificationCoalescing()
            subscriptionStore.markEpisodeDownloaded(
                subscriptionID: subscriptionID,
                episodeID: episode.id,
                localFileURL: localFileURL
            )
            coordinator.clearWatchdogRetryState(for: episode.id)
            coordinator.failureBackoff.removeValue(forKey: episode.guid)
            coordinator.recordDownloadSuccess(
                episodeID: episode.id,
                mediaURL: episode.audioURL
            )
            if let duration {
                subscriptionStore.updateEpisodeDuration(
                    subscriptionID: subscriptionID,
                    episodeID: episode.id,
                    durationSeconds: duration
                )
            }
            subscriptionStore.endChangeNotificationCoalescing()
            let storeMs =
                (CFAbsoluteTimeGetCurrent() - storeStartedAt) * 1_000
            coordinator.progressModel.progress.removeValue(forKey: episode.id)

            let statsStartedAt = CFAbsoluteTimeGetCurrent()
            historyStatsCoordinator.recordDownload(bytes: downloadedBytes)
            let statsMs =
                (CFAbsoluteTimeGetCurrent() - statsStartedAt) * 1_000
            let effectsStartedAt = CFAbsoluteTimeGetCurrent()
            if showCompletionMessage {
                coordinator.message = "Downloaded \(episode.title)."
            }
            let completedAt = runtimeWorkflow.now
            let detectionAtCompletion = coordinator.detectionMetadata(
                episodeID: episode.id,
                now: completedAt,
                sceneActivationSequence:
                    runtimeWorkflow.sceneActivationSequence
            )
            logger.info("download.complete", "Episode downloaded", metadata: [
                "episode": episode.title,
                "episodeID": episode.id.uuidString,
                "path": localFileURL.lastPathComponent,
                "duration": duration.map { "\(Int($0))" } ?? "unknown",
                "mediaKind": episode.mediaKind.rawValue,
                "fileSizeBytes": episode.fileSizeBytes.map(String.init) ?? "unknown",
                "automatic": "\(isAutomatic)",
                "sceneActive": "\(runtimeWorkflow.isSceneActive)",
                "applicationForeground": "\(runtimeWorkflow.isAppForeground)",
                "batteryState": ResourceMonitor.shared.externalPowerStateLabel,
                "transferElapsedSeconds": String(
                    format: "%.1f",
                    runtimeWorkflow.now.timeIntervalSince(transferStartedAt)
                )
            ].merging(detectionAtCompletion) { _, new in new })
            coordinator.clearEpisodeDetection(episodeID: episode.id)
            coordinator.activityStore.complete(
                episode: episode,
                podcastTitle: podcastTitle,
                localFileName: localFileURL.lastPathComponent
            )
            BackgroundWakeMonitor.shared.recordDownloadCompleted()
            if let subscription = subscriptionStore.subscription(id: subscriptionID) {
                notificationWorkflow.notifyIfAllowed(
                    episode: episode,
                    subscription: subscription
                )
            }
            if isAutomatic {
                playInstantWorkflow?.enqueueIfEligible(
                    episodeID: episode.id,
                    subscriptionID: subscriptionID
                )
            }
            coordinator.rebuildDownloadedActivities(
                from: subscriptionStore.subscriptions
            )
            let effectsMs =
                (CFAbsoluteTimeGetCurrent() - effectsStartedAt) * 1_000
            let settlementMs =
                (CFAbsoluteTimeGetCurrent() - settlementStartedAt) * 1_000
            if settlementMs >= 100 {
                logger.warning(
                    "ui.mainActorOperationSlow",
                    "Download completion settlement occupied the main actor",
                    metadata: [
                        "operation": "download.settlement",
                        "durationMs": String(
                            format: "%.1f",
                            settlementMs
                        ),
                        "episode": episode.title,
                        "podcast": podcastTitle,
                        "storeMs": String(format: "%.1f", storeMs),
                        "statsMs": String(format: "%.1f", statsMs),
                        "effectsMs": String(format: "%.1f", effectsMs),
                        "subscriptionCount":
                            "\(subscriptionStore.subscriptions.count)"
                    ]
                )
            }
            _ = ResourceMonitor.shared.logMemoryStageDelta(
                stage: "download.settlement",
                from: settlementMemory,
                context: [
                    "episode": episode.title,
                    "podcast": podcastTitle,
                    "durationMs": String(format: "%.1f", settlementMs)
                ]
            )
            runtimeWorkflow.logResourceSnapshot(reason: "download.afterSuccess", extra: [
                "episode": episode.title,
                "podcast": podcastTitle
            ], force: false)
        } catch {
            handleFailure(
                error,
                episode: episode,
                subscriptionID: subscriptionID,
                podcastTitle: podcastTitle
            )
        }
    }

    private func localFileByteCount(
        at url: URL,
        fallback: Int64
    ) async -> Int64 {
        await Task.detached(priority: .utility) {
            (
                (try? FileManager.default.attributesOfItem(
                    atPath: url.path
                ))?[.size] as? NSNumber
            )?.int64Value ?? fallback
        }.value
    }

    private func drainQueue() {
        guard !coordinator.pendingQueue.isEmpty,
              coordinator.activeCount < coordinator.maxConcurrentDownloads else {
            return
        }
        let next = coordinator.pendingQueue.removeFirst()
        logger.info("download.dequeued", "Starting deferred download", metadata: [
            "episode": next.episode.title,
            "podcast": next.podcastTitle,
            "remainingInQueue": "\(coordinator.pendingQueue.count)"
        ])
        Task { @MainActor [weak self] in
            await self?.download(
                next.episode,
                subscriptionID: next.subscriptionID,
                podcastTitle: next.podcastTitle,
                showCompletionMessage: next.showCompletionMessage,
                isAutomatic: next.isAutomatic
            )
        }
    }

    private func reusableDownloadedEpisode(for episode: Episode) -> Episode? {
        let storedEpisode = subscriptionStore.episode(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        if var storedEpisode,
           storedEpisode.downloadState == .downloaded,
           let localFileURL = mediaWorkflow.resolveLocalURL(
            for: storedEpisode
           ) {
            storedEpisode.localFileURL = localFileURL
            return storedEpisode
        }

        var candidate = episode
        if candidate.downloadState == .downloaded,
           let localFileURL = mediaWorkflow.resolveLocalURL(for: candidate) {
            candidate.localFileURL = localFileURL
            return candidate
        }
        return nil
    }

    private func handleFailure(
        _ error: Error,
        episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String
    ) {
        if let downloadError = error as? DownloadError,
           downloadError == .paused {
            if coordinator.supersededCancellationIDs.remove(episode.id) != nil {
                retireSupersededActivity(
                    episode: episode,
                    podcastTitle: podcastTitle,
                    event: "download.pausedSuperseded",
                    message: "Superseded rolling-feed download pause ignored cleanly"
                )
                return
            }
            coordinator.activityStore.pause(episodeID: episode.id)
            coordinator.message = "Paused \(episode.title)."
            logger.info("download.paused", "Episode download paused", metadata: [
                "episode": episode.title,
                "podcast": podcastTitle,
                "mediaKind": episode.mediaKind.rawValue
            ])
            return
        }

        if let downloadError = error as? DownloadError,
           downloadError == .cancelled {
            if coordinator.supersededCancellationIDs.remove(episode.id) != nil {
                retireSupersededActivity(
                    episode: episode,
                    podcastTitle: podcastTitle,
                    event: "download.cancelledSuperseded",
                    message: "Superseded rolling-feed download cancelled cleanly"
                )
                return
            }
            subscriptionStore.markEpisodeDownloadFailed(
                subscriptionID: subscriptionID,
                episodeID: episode.id
            )
            coordinator.progressModel.progress.removeValue(forKey: episode.id)
            coordinator.activityStore.fail(
                episode: episode,
                podcastTitle: podcastTitle,
                error: "Cancelled"
            )
            coordinator.message = "Cancelled \(episode.title)."
            logger.info("download.cancelled", "Episode download cancelled", metadata: [
                "episode": episode.title,
                "podcast": podcastTitle,
                "mediaKind": episode.mediaKind.rawValue
            ])
            return
        }

        if let downloadError = error as? DownloadError,
           downloadError == .duplicateDownload {
            logger.warning(
                "download.duplicateBlocked",
                "Duplicate download request rejected by downloader",
                metadata: [
                    "episode": episode.title,
                    "podcast": podcastTitle
                ]
            )
            coordinator.message = "\(episode.title) is already downloading."
            return
        }

        subscriptionStore.markEpisodeDownloadFailed(
            subscriptionID: subscriptionID,
            episodeID: episode.id
        )
        coordinator.recordFailure(
            guid: episode.guid,
            title: episode.title,
            logger: logger
        )
        coordinator.progressModel.progress.removeValue(forKey: episode.id)
        coordinator.message = "Download failed for \(episode.title)."
        coordinator.activityStore.fail(
            episode: episode,
            podcastTitle: podcastTitle,
            error: String(describing: error)
        )
        logger.error("download.failed", "Episode download failed", metadata: [
            "episode": episode.title,
            "podcast": podcastTitle,
            "error": String(describing: error),
            "mediaKind": episode.mediaKind.rawValue,
            "fileSizeBytes": episode.fileSizeBytes.map(String.init) ?? "unknown"
        ])
        runtimeWorkflow.logResourceSnapshot(reason: "download.afterFailure", extra: [
            "episode": episode.title,
            "podcast": podcastTitle
        ], force: true)
    }

    private func retireSupersededActivity(
        episode: Episode,
        podcastTitle: String,
        event: String,
        message: String
    ) {
        coordinator.progressModel.progress.removeValue(forKey: episode.id)
        coordinator.activityStore.remove(episodeID: episode.id)
        logger.info(event, message, metadata: [
            "episode": episode.title,
            "podcast": podcastTitle,
            "mediaKind": episode.mediaKind.rawValue
        ])
    }
}
