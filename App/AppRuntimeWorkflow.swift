import Combine
import Foundation
import UIKit

// AI CONTEXT — App/AppRuntimeWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Process-runtime policy owner for iOS scene changes and long-lived app
// operation. It owns cached scene state, foreground/background-audio due-feed
// polling, independent Auto Archive polling, settings operational reactions,
// Sleep Schedule configuration, keep-screen-awake policy, background playback
// diagnostics/resource release, and shared resource-diagnostic context.
//
// TASK / LIFECYCLE MODEL:
// AppLifecycleCoordinator remains the exclusive retained-Task registry.
// AppRuntimeWorkflow supplies operations to its poller, maintenance, and delayed
// diagnostic slots. Foreground transitions cancel delayed background probes;
// stop removes settings subscriptions before LifecycleCoordinator cancels all
// retained tasks.
//
// INVARIANTS:
// - Injected live UIApplication state, not cached scene state, controls
//   foreground work. Tests may substitute application state, background time,
//   idle-timer state, and wall-clock time without touching UIKit globals.
// - Background polling runs only while audio is active and remains bounded by
//   FeedRefreshCycleWorkflow's four-minute/resource-pressure policy.
// - Auto Archive gets its own poll opportunity and is not coupled to a feed
//   cycle selecting or completing work.
// - Paused engine resources are released only when both application and engine
//   playback state agree that audio is inactive.
// - Settings reactions are operational; they never forward objectWillChange.

/// AI CONTEXT — Injectable process-environment boundary for AppRuntimeWorkflow.
/// Production uses `live()`. Tests should provide deterministic closures rather
/// than swizzling UIApplication or relying on the simulator's current state.
@MainActor
struct AppRuntimeEnvironment {
    let applicationState: () -> UIApplication.State
    let backgroundTimeRemaining: () -> TimeInterval
    let isIdleTimerDisabled: () -> Bool
    let setIdleTimerDisabled: (Bool) -> Void
    let now: () -> Date

    static func live() -> AppRuntimeEnvironment {
        AppRuntimeEnvironment(
            applicationState: { UIApplication.shared.applicationState },
            backgroundTimeRemaining: {
                UIApplication.shared.backgroundTimeRemaining
            },
            isIdleTimerDisabled: {
                UIApplication.shared.isIdleTimerDisabled
            },
            setIdleTimerDisabled: {
                UIApplication.shared.isIdleTimerDisabled = $0
            },
            now: Date.init
        )
    }
}

@MainActor
final class AppRuntimeWorkflow {
    typealias RefreshDue = @MainActor () async -> Bool

    private let lifecycle: AppLifecycleCoordinator
    private let playback: PlaybackCoordinator
    private let settingsStore: any SettingsStoring
    private let settingsCoordinator: SettingsViewModel
    private let syncCoordinator: SyncCoordinator
    private let subscriptionStore: SubscriptionStore
    private let checkpointWorkflow: PlaybackCheckpointWorkflow
    private let feedRefreshCoordinator: FeedRefreshCoordinator
    private let releaseRadar: ReleaseRadarWorkflow
    private let autoArchiveCoordinator: AutoArchiveCoordinator
    private let queueCoordinator: QueueCoordinator
    private let downloadCoordinator: DownloadCoordinator
    private let logger: AppLogger
    private let resourceMonitor: ResourceMonitor
    private let environment: AppRuntimeEnvironment
    private let backgroundAudioMinimumInterval: TimeInterval

    private var refreshDue: RefreshDue = { false }
    private var settingsCancellables = Set<AnyCancellable>()
    private var hasStarted = false

    private(set) var isSceneActive = true
    private(set) var sceneActivationSequence = 0

    init(
        lifecycle: AppLifecycleCoordinator,
        playback: PlaybackCoordinator,
        settingsStore: any SettingsStoring,
        settingsCoordinator: SettingsViewModel,
        syncCoordinator: SyncCoordinator,
        subscriptionStore: SubscriptionStore,
        checkpointWorkflow: PlaybackCheckpointWorkflow,
        feedRefreshCoordinator: FeedRefreshCoordinator,
        releaseRadar: ReleaseRadarWorkflow,
        autoArchiveCoordinator: AutoArchiveCoordinator,
        queueCoordinator: QueueCoordinator,
        downloadCoordinator: DownloadCoordinator,
        logger: AppLogger,
        resourceMonitor: ResourceMonitor,
        environment: AppRuntimeEnvironment,
        backgroundAudioMinimumInterval: TimeInterval = 4 * 60
    ) {
        self.lifecycle = lifecycle
        self.playback = playback
        self.settingsStore = settingsStore
        self.settingsCoordinator = settingsCoordinator
        self.syncCoordinator = syncCoordinator
        self.subscriptionStore = subscriptionStore
        self.checkpointWorkflow = checkpointWorkflow
        self.feedRefreshCoordinator = feedRefreshCoordinator
        self.releaseRadar = releaseRadar
        self.autoArchiveCoordinator = autoArchiveCoordinator
        self.queueCoordinator = queueCoordinator
        self.downloadCoordinator = downloadCoordinator
        self.logger = logger
        self.resourceMonitor = resourceMonitor
        self.environment = environment
        self.backgroundAudioMinimumInterval = backgroundAudioMinimumInterval
    }

    var isAppForeground: Bool {
        environment.applicationState() == .active
    }

    var now: Date {
        environment.now()
    }

    func installRefreshDue(_ action: @escaping RefreshDue) {
        refreshDue = action
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        installSettingsReactions()
        syncDiagnosticLogging()
        syncSleepScheduleConfig()
        lifecycle.startPoller { [weak self] in
            await self?.performPollTick()
        }
        resourceMonitor.startPeriodicSampling { [weak self] in
            self?.resourceContext() ?? [:]
        }
    }

    func stop() {
        settingsCancellables.removeAll()
        lifecycle.cancelDelayedDiagnostics()
        hasStarted = false
    }

    func setSceneActive(_ active: Bool) {
        if active && !isSceneActive {
            sceneActivationSequence &+= 1
        }
        isSceneActive = active
        if active {
            lifecycle.cancelDelayedDiagnostics()
        }
    }

    func handleScenePhaseChange(
        phaseName: String,
        isActive: Bool,
        isBackground: Bool
    ) {
        let previousSceneActive = isSceneActive
        setSceneActive(isActive)
        downloadCoordinator.reevaluateWatchdog(
            reason: "scene.\(phaseName)"
        )

        var metadata = resourceContext([
            "phase": phaseName,
            "previousSceneActive": "\(previousSceneActive)",
            "applicationState":
                applicationStateLabel(environment.applicationState())
        ])
        if !isActive {
            metadata["backgroundTimeRemainingSecs"] =
                backgroundTimeRemainingLabel()
        }
        logger.info(
            "scene.phase",
            "Scene phase changed",
            metadata: metadata
        )
        resourceMonitor.logSnapshot(
            reason: "scene.\(phaseName)",
            context: metadata,
            force: isBackground || !isActive
        )

        guard isBackground else { return }
        lifecycle.runMaintenance {
            await ArtworkImageCache.shared.trimMemory(
                reason: "scene.background"
            )
        }
        scheduleBackgroundPlaybackDiagnostics(reason: "scene.background")
        let released = releasePausedPlaybackResourcesForBackground(
            reason: "scene.background"
        )
        metadata["releasedPausedPlayerResources"] = "\(released)"
        logger.info(
            "scene.background",
            "Scene entered background",
            metadata: metadata
        )
    }

    @discardableResult
    func releasePausedPlaybackResourcesForBackground(reason: String) -> Bool {
        guard playback.currentEpisode != nil
                || playback.engine.currentEpisode != nil else {
            return false
        }

        var metadata = resourceContext([
            "reason": reason,
            "engineEpisode":
                playback.engine.currentEpisode?.title ?? "none",
            "engineIsPlaying": "\(playback.engine.isPlaying)"
        ])
        guard !playback.isPlaying, !playback.engine.isPlaying else {
            logger.info(
                "player.backgroundReleaseSkipped",
                "Playback is active; keeping playback resources",
                metadata: metadata
            )
            return false
        }
        guard let engine = playback.engine as? PlaybackEngine else {
            logger.info(
                "player.backgroundReleaseSkipped",
                "Playback engine does not support background resource release",
                metadata: metadata
            )
            return false
        }
        guard let releasedPosition =
                engine.releasePausedPlayerResourcesForBackground(
                    reason: reason
                ) else {
            logger.info(
                "player.backgroundReleaseSkipped",
                "No paused playback resources to release",
                metadata: metadata
            )
            return false
        }

        playback.clock.time = releasedPosition
        checkpointWorkflow.persistLocal()
        metadata["releasedPositionSecs"] = String(
            format: "%.1f",
            releasedPosition
        )
        logger.info(
            "player.backgroundRelease",
            "Released paused playback resources for background",
            metadata: metadata
        )
        resourceMonitor.logSnapshot(
            reason: "player.backgroundRelease",
            context: metadata,
            force: true
        )
        return true
    }

    func logActivePlaybackDiagnostics(
        reason: String,
        extra: [String: String] = [:]
    ) {
        guard playback.currentEpisode != nil
                || playback.engine.currentEpisode != nil else {
            return
        }

        var metadata = resourceContext(extra)
        let remaining = environment.backgroundTimeRemaining()
        metadata["backgroundTimeRemainingSecs"] =
            backgroundTimeRemainingLabel()
        metadata.merge(
            playbackEngineDiagnosticMetadata(reason: reason)
        ) { _, new in new }
        logger.info(
            "playback.backgroundHealth",
            "Active playback background health",
            metadata: metadata
        )
        if playback.isPlaying,
           remaining.isFinite,
           remaining < 60 {
            logger.warning(
                "audio.backgroundAssertionLow",
                "Playing but iOS granted only limited background time — audio keep-alive not held",
                metadata: metadata,
                alwaysPersist: true
            )
        }
    }

    func logResourceSnapshot(
        reason: String,
        extra: [String: String] = [:],
        force: Bool = true
    ) {
        resourceMonitor.logSnapshot(
            reason: reason,
            context: resourceContext(extra),
            force: force
        )
    }

    func logResourceWarningSnapshot(
        event: String,
        message: String,
        reason: String,
        extra: [String: String] = [:]
    ) {
        resourceMonitor.logWarningSnapshot(
            event: event,
            message: message,
            reason: reason,
            context: resourceContext(extra)
        )
    }

    func syncDiagnosticLogging() {
        let enabled = settingsStore.appSettings.diagnosticLoggingEnabled
        AppLogger.shared.isEnabled = enabled
        AppLogger.shared.isVerboseEnabled = enabled
            && settingsStore.appSettings.verboseDiagnosticLoggingEnabled
        resourceMonitor.setDiagnosticSessionEnabled(enabled)
    }

    func syncSleepScheduleConfig() {
        let settings = settingsStore.appSettings
        playback.sleepScheduleService.updateConfig(
            SleepScheduleService.Config(
                enabled: settings.sleepScheduleEnabled,
                startMinutes: settings.sleepScheduleStartMinutes,
                endMinutes: settings.sleepScheduleEndMinutes,
                durationMinutes: settings.sleepScheduleDurationMinutes
            ),
            isPlaying: playback.isPlaying
        )
    }

    func updateIdleTimer(playerVisible: Bool) {
        let shouldStayAwake = playerVisible
            && playback.isPlaying
            && settingsStore.appSettings.keepScreenAwakeDuringPlayback
        guard environment.isIdleTimerDisabled() != shouldStayAwake else {
            return
        }
        environment.setIdleTimerDisabled(shouldStayAwake)
        logger.info(
            "screenAwake.updated",
            "Idle timer updated",
            metadata: [
                "playerVisible": "\(playerVisible)",
                "isPlaying": "\(playback.isPlaying)",
                "settingEnabled":
                    "\(settingsStore.appSettings.keepScreenAwakeDuringPlayback)",
                "idleTimerDisabled": "\(shouldStayAwake)"
            ]
        )
    }

    func resourceContext(
        _ extra: [String: String] = [:]
    ) -> [String: String] {
        var context = [
            "isPlaying": "\(playback.isPlaying)",
            "playingVideo":
                "\(playback.currentEpisode?.mediaKind == .video)",
            "sceneActive": "\(isSceneActive)",
            "refreshActive":
                "\(feedRefreshCoordinator.activeCycle != nil)",
            "currentEpisode": playback.currentEpisode?.title ?? "none",
            "currentTime": "\(Int(playback.clock.time))",
            "queueCount": "\(queueCoordinator.episodes.count)",
            "subscriptionCount":
                "\(subscriptionStore.subscriptions.count)",
            "activeDownloads":
                "\(downloadCoordinator.progressModel.progress.count)",
            "activeDownloadSlots": "\(downloadCoordinator.activeCount)",
            "pendingDownloads":
                "\(downloadCoordinator.pendingQueue.count)",
            "upNext": queueCoordinator.upNextEpisode?.title ?? "none"
        ]
        if let diagnostics =
            feedRefreshCoordinator.activeCycleDiagnostics {
            context.merge(
                diagnostics.metadata(currentSceneActive: isSceneActive)
            ) { _, new in new }
        }
        context.merge(playback.lastTickResourceMetadata) { _, new in new }
        if environment.applicationState() != .active {
            context["backgroundTimeRemainingSecs"] =
                backgroundTimeRemainingLabel()
            if playback.currentEpisode != nil
                || playback.engine.currentEpisode != nil {
                context.merge(
                    playbackEngineDiagnosticMetadata(
                        reason: "resourceContext"
                    )
                ) { existing, _ in existing }
            }
        }
        extra.forEach { context[$0.key] = $0.value }
        return context
    }

    private func installSettingsReactions() {
        settingsCoordinator.$appSettings
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.lifecycle.runMaintenance { [weak self] in
                    guard let self else { return }
                    self.syncDiagnosticLogging()
                    self.syncSleepScheduleConfig()
                    self.syncCoordinator.syncEnabledChanged(
                        self.settingsStore.appSettings.iCloudSyncEnabled
                    )
                }
            }
            .store(in: &settingsCancellables)
    }

    private func performPollTick() async {
        guard isAppForeground || playback.isPlaying else { return }
        await autoArchiveCoordinator.runIfNeeded(reason: "poll.tick")

        let now = environment.now()
        let dueCount = subscriptionStore.subscriptions.filter {
            !$0.excludeFromAutoFeedRefresh
                && releaseRadar.nextRefreshDue(for: $0) <= now
        }.count
        guard dueCount > 0 else { return }

        let executionContext: FeedRefreshExecutionContext =
            isAppForeground ? .foregroundVisible : .backgroundAudioAlive
        if executionContext == .backgroundAudioAlive,
           let last = feedRefreshCoordinator.lastBackgroundAudioRefreshAt,
           now.timeIntervalSince(last) < backgroundAudioMinimumInterval {
            return
        }
        logger.info(
            "feed.pollDue",
            "Due-feed poll found due subscriptions",
            metadata: [
                "due": "\(dueCount)",
                "appForeground": "\(isAppForeground)",
                "sceneActive": "\(isSceneActive)",
                "isPlaying": "\(playback.isPlaying)",
                "trigger": FeedRefreshTrigger.foregroundTimer.rawValue,
                "executionContext": executionContext.rawValue
            ]
        )
        _ = await refreshDue()
    }

    private func scheduleBackgroundPlaybackDiagnostics(reason: String) {
        logActivePlaybackDiagnostics(
            reason: "\(reason).entry",
            extra: ["backgroundElapsedSecs": "0"]
        )
        lifecycle.replaceDelayedDiagnostics(delays: [5, 20]) {
            [weak self] delay in
            guard let self,
                  !self.isAppForeground,
                  self.playback.currentEpisode != nil
                    || self.playback.engine.currentEpisode != nil else {
                return
            }
            let seconds = Int(delay)
            self.logActivePlaybackDiagnostics(
                reason: "\(reason).+\(seconds)s",
                extra: ["backgroundElapsedSecs": "\(seconds)"]
            )
        }
    }

    private func applicationStateLabel(
        _ state: UIApplication.State
    ) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func backgroundTimeRemainingLabel() -> String {
        let remaining = environment.backgroundTimeRemaining()
        guard remaining.isFinite else { return "unknown" }
        if remaining > 1_000_000 { return "unlimited" }
        return String(format: "%.1f", remaining)
    }

    private func playbackEngineDiagnosticMetadata(
        reason: String
    ) -> [String: String] {
        if let engine = playback.engine as? PlaybackEngine {
            return engine.playbackDiagnosticMetadata(reason: reason)
        }
        return [
            "playbackDiagnosticReason": reason,
            "playbackBackend": "unknown",
            "playbackEngineIsPlaying": "\(playback.engine.isPlaying)",
            "engineEpisode":
                playback.engine.currentEpisode?.title ?? "none",
            "playbackLikelyProducingAudio": "unknown"
        ]
    }
}
