import Foundation

// AI CONTEXT — App/AppStartupWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Ordered application-start transaction extracted from AppState during Stage 14.
// It connects typed domain collaborators exactly once, starts service owners in
// the characterized order, applies idempotent settings/subscription migrations,
// restores durable playback/queue state, warms Release Radar, and schedules
// startup maintenance through AppLifecycleCoordinator.
//
// ORDERING INVARIANTS:
// 1. Connect every domain callback/provider before a service can emit events.
// 2. Start sync/Relay/queue/network/runtime owners before restoration work.
// 3. Preserve existing migration order and one-way migration flags.
// 4. Restore playback before loading queue pins and warming Radar profiles.
// 5. Retain all asynchronous maintenance in AppLifecycleCoordinator.
// 6. Reconcile interrupted downloads before draining durable auto-download
//    intents, so stale `.downloading` rows cannot suppress recovery.
// 7. When startup occurs inside an OS BGTask wake, publish bootstrap duration to
//    BackgroundWakeMonitor so per-wake summaries expose cold-launch budget cost.
//
// PROHIBITED RESPONSIBILITIES:
// This workflow owns no mutable playback, download, queue, refresh, archive,
// sync, onboarding, or routing state. It never retains a Task and never reaches
// back into AppState. AppState remains the singleton/high-level command façade.

@MainActor
final class AppStartupWorkflow {
    private let lifecycle: AppLifecycleCoordinator
    private let settingsStore: any SettingsStoring
    private let settingsCoordinator: SettingsViewModel
    private let subscriptionStore: SubscriptionStore
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let queueCoordinator: QueueCoordinator
    private let onboardingCoordinator: OnboardingCoordinator
    private let routingCoordinator: AppRoutingCoordinator
    private let downloadCoordinator: DownloadCoordinator
    private let downloadManager: any DownloadManaging
    private let downloadActionsWorkflow: DownloadActionsWorkflow
    private let autoDownloadIntentWorkflow: AutoDownloadIntentWorkflow
    private let autoDownloadIntentStore: AutoDownloadIntentStore
    private let autoArchiveCoordinator: AutoArchiveCoordinator
    private let syncCoordinator: SyncCoordinator
    private let relayCoordinator: RelayCoordinator
    private let playbackCoordinator: PlaybackCoordinator
    private let playbackPreferenceWorkflow: PlaybackPreferenceWorkflow
    private let playbackSeekWorkflow: PlaybackSeekWorkflow
    private let playbackCheckpointWorkflow: PlaybackCheckpointWorkflow
    private let playbackMediaWorkflow: PlaybackMediaWorkflow
    private let episodeCompletionWorkflow: EpisodeCompletionWorkflow
    private let playbackTransportWorkflow: PlaybackTransportWorkflow
    private let playInstantWorkflow: PlayInstantWorkflow
    private let newEpisodeNotificationWorkflow:
        NewEpisodeNotificationWorkflow
    private let feedRefreshCycleWorkflow: FeedRefreshCycleWorkflow
    private let releaseRadarWorkflow: ReleaseRadarWorkflow
    private let appRuntimeWorkflow: AppRuntimeWorkflow
    private let logger: AppLogger

    private var graphConnected = false

    init(
        lifecycle: AppLifecycleCoordinator,
        settingsStore: any SettingsStoring,
        settingsCoordinator: SettingsViewModel,
        subscriptionStore: SubscriptionStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        queueCoordinator: QueueCoordinator,
        onboardingCoordinator: OnboardingCoordinator,
        routingCoordinator: AppRoutingCoordinator,
        downloadCoordinator: DownloadCoordinator,
        downloadManager: any DownloadManaging,
        downloadActionsWorkflow: DownloadActionsWorkflow,
        autoDownloadIntentWorkflow: AutoDownloadIntentWorkflow,
        autoDownloadIntentStore: AutoDownloadIntentStore,
        autoArchiveCoordinator: AutoArchiveCoordinator,
        syncCoordinator: SyncCoordinator,
        relayCoordinator: RelayCoordinator,
        playbackCoordinator: PlaybackCoordinator,
        playbackPreferenceWorkflow: PlaybackPreferenceWorkflow,
        playbackSeekWorkflow: PlaybackSeekWorkflow,
        playbackCheckpointWorkflow: PlaybackCheckpointWorkflow,
        playbackMediaWorkflow: PlaybackMediaWorkflow,
        episodeCompletionWorkflow: EpisodeCompletionWorkflow,
        playbackTransportWorkflow: PlaybackTransportWorkflow,
        playInstantWorkflow: PlayInstantWorkflow,
        newEpisodeNotificationWorkflow: NewEpisodeNotificationWorkflow,
        feedRefreshCycleWorkflow: FeedRefreshCycleWorkflow,
        releaseRadarWorkflow: ReleaseRadarWorkflow,
        appRuntimeWorkflow: AppRuntimeWorkflow,
        logger: AppLogger
    ) {
        self.lifecycle = lifecycle
        self.settingsStore = settingsStore
        self.settingsCoordinator = settingsCoordinator
        self.subscriptionStore = subscriptionStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.queueCoordinator = queueCoordinator
        self.onboardingCoordinator = onboardingCoordinator
        self.routingCoordinator = routingCoordinator
        self.downloadCoordinator = downloadCoordinator
        self.downloadManager = downloadManager
        self.downloadActionsWorkflow = downloadActionsWorkflow
        self.autoDownloadIntentWorkflow = autoDownloadIntentWorkflow
        self.autoDownloadIntentStore = autoDownloadIntentStore
        self.autoArchiveCoordinator = autoArchiveCoordinator
        self.syncCoordinator = syncCoordinator
        self.relayCoordinator = relayCoordinator
        self.playbackCoordinator = playbackCoordinator
        self.playbackPreferenceWorkflow = playbackPreferenceWorkflow
        self.playbackSeekWorkflow = playbackSeekWorkflow
        self.playbackCheckpointWorkflow = playbackCheckpointWorkflow
        self.playbackMediaWorkflow = playbackMediaWorkflow
        self.episodeCompletionWorkflow = episodeCompletionWorkflow
        self.playbackTransportWorkflow = playbackTransportWorkflow
        self.playInstantWorkflow = playInstantWorkflow
        self.newEpisodeNotificationWorkflow =
            newEpisodeNotificationWorkflow
        self.feedRefreshCycleWorkflow = feedRefreshCycleWorkflow
        self.releaseRadarWorkflow = releaseRadarWorkflow
        self.appRuntimeWorkflow = appRuntimeWorkflow
        self.logger = logger
    }

    func start(
        bootstrapStartedAt: CFAbsoluteTime,
        constructionFinishedAt: CFAbsoluteTime
    ) {
        connectGraphIfNeeded()

        syncCoordinator.startIfEnabled(
            settingsStore.appSettings.iCloudSyncEnabled
        )
        relayCoordinator.start()
        queueCoordinator.start()
        downloadCoordinator.startNetworkMonitoring()
        subscriptionStore.cleanupExpiredPreviewSubscriptions(
            subscriptionIDsWithHistory: Set(
                historyStatsCoordinator.historyStore.entries.map(
                    \.subscriptionID
                )
            )
        )
        installPlatformCallbacks()
        applyMigrations()
        onboardingCoordinator.reconcileExistingUser()

        logger.info("app.bootstrap", "App state bootstrapped")
        playbackMediaWorkflow.restoreNewestCandidate(
            in: queueCoordinator.episodes
        )
        queueCoordinator.loadPins()
        releaseRadarWorkflow.warmProfileCache()

        lifecycle.runMaintenance { [weak autoArchiveCoordinator] in
            await autoArchiveCoordinator?.runIfNeeded(
                reason: "app.startup"
            )
        }
        lifecycle.runMaintenance {
            [weak downloadActionsWorkflow, weak autoDownloadIntentWorkflow] in
            await downloadActionsWorkflow?.reconcileOrphanedDownloads()
            await autoDownloadIntentWorkflow?.drain(reason: "launch")
        }

        let finishedAt = CFAbsoluteTimeGetCurrent()
        let totalMilliseconds =
            (finishedAt - bootstrapStartedAt) * 1_000
        let constructionMilliseconds =
            (constructionFinishedAt - bootstrapStartedAt) * 1_000
        BackgroundWakeMonitor.shared.recordBootstrap(
            totalMilliseconds: totalMilliseconds,
            constructionMilliseconds: constructionMilliseconds
        )
        logger.info(
            "app.bootstrapTiming",
            "Measured synchronous cold-bootstrap stages",
            metadata: [
                "totalMs": String(
                    format: "%.1f",
                    totalMilliseconds
                ),
                "constructionMs": String(
                    format: "%.1f",
                    constructionMilliseconds
                ),
                "wiringAndRestoreMs": String(
                    format: "%.1f",
                    (finishedAt - constructionFinishedAt) * 1000
                ),
                "subscriptionCount":
                    "\(subscriptionStore.subscriptions.count)",
                "historyCount":
                    "\(historyStatsCoordinator.historyStore.entries.count)"
            ]
        )
    }

    private func connectGraphIfNeeded() {
        guard !graphConnected else { return }
        graphConnected = true

        historyStatsCoordinator.attachSyncDatabase(
            subscriptionStore.database
        )
        settingsCoordinator.installSubscriptionDefaults(
            on: subscriptionStore
        )
        downloadCoordinator.installRemoteFileDeletionCallback(
            on: subscriptionStore,
            downloadManager: downloadManager
        )
        onboardingCoordinator.installRoutingOutput(to: routingCoordinator)
        routingCoordinator.startLegacyNotificationAdapter()
        appRuntimeWorkflow.installRefreshDue {
            [weak feedRefreshCycleWorkflow] in
            await feedRefreshCycleWorkflow?.refreshDue() ?? false
        }
        appRuntimeWorkflow.start()
    }

    private func installPlatformCallbacks() {
        playbackCoordinator.installStatisticsCallbacks(
            historyStatsCoordinator: historyStatsCoordinator
        )
        playbackCoordinator.installSessionCallbacks(
            subscriptionStore: subscriptionStore,
            preferenceWorkflow: playbackPreferenceWorkflow,
            logger: logger
        )
        playbackCoordinator.installSleepCallbacks(
            subscriptionStore: subscriptionStore,
            preferenceWorkflow: playbackPreferenceWorkflow,
            seekWorkflow: playbackSeekWorkflow,
            checkpointWorkflow: playbackCheckpointWorkflow,
            logger: logger
        )
        playbackCoordinator.installTimeUpdateCallback(
            subscriptionStore: subscriptionStore,
            preferenceWorkflow: playbackPreferenceWorkflow,
            historyStatsCoordinator: historyStatsCoordinator,
            mediaWorkflow: playbackMediaWorkflow,
            logger: logger
        )
        playbackCoordinator.installCompletionCallback(
            completionWorkflow: episodeCompletionWorkflow
        )
        playbackCoordinator.installRemoteCommandCallbacks(
            settings: settingsStore.appSettings,
            transportWorkflow: playbackTransportWorkflow,
            seekWorkflow: playbackSeekWorkflow,
            completionWorkflow: episodeCompletionWorkflow,
            playInstantWorkflow: playInstantWorkflow,
            preferenceWorkflow: playbackPreferenceWorkflow
        )
        downloadCoordinator.installProgressCallback(on: downloadManager)
        downloadCoordinator.installWatchdogCallback(
            on: downloadManager,
            subscriptionStore: subscriptionStore,
            autoDownloadIntentStore: autoDownloadIntentStore,
            logger: logger,
            actions: downloadActionsWorkflow
        )
        downloadCoordinator.installBackgroundCompletionCallback(
            on: downloadManager,
            subscriptionStore: subscriptionStore,
            autoDownloadIntentStore: autoDownloadIntentStore,
            historyStatsCoordinator: historyStatsCoordinator,
            notificationWorkflow: newEpisodeNotificationWorkflow,
            playInstantWorkflow: playInstantWorkflow,
            autoDownloadIntentWorkflow: autoDownloadIntentWorkflow
        )
    }

    private func applyMigrations() {
        if !settingsStore.appSettings.autoArchiveSettingsMigrated {
            subscriptionStore.migrateExistingSubscriptionsToAutoArchiveSettings()
            settingsStore.appSettings.autoArchiveSettingsMigrated = true
            logger.info(
                "autoArchive.migration",
                "Existing subscriptions migrated to AutoArchiveSettings defaults"
            )
        }
        if !settingsStore.appSettings.vocalBoostLevelMigrated {
            subscriptionStore.migrateExistingSubscriptionsToStrongVocalBoost()
            settingsStore.appSettings.vocalBoostLevelMigrated = true
            logger.info(
                "vocalBoost.migration",
                "Existing subscriptions moved to Strong Vocal Boost"
            )
        }
        if !settingsStore.appSettings.trimSilenceLowDefaultMigrated {
            subscriptionStore.migrateExistingSubscriptionsToTrimSilenceLow()
            settingsStore.appSettings.trimSilenceLowDefaultMigrated = true
            logger.info(
                "trimSilence.migration",
                "Existing subscriptions set to Low Trim Silence"
            )
        }
        if !settingsStore.appSettings.playbackSpeed160Migrated {
            subscriptionStore.migrateExistingSubscriptionsToPlaybackSpeed(1.6)
            settingsStore.appSettings.playbackSpeed160Migrated = true
            logger.info(
                "speed.migration",
                "Existing subscriptions set to 1.6x playback speed"
            )
        }
    }
}
