import Foundation

// AI CONTEXT — App/AppState.swift (AUTHORITATIVE, Stage 14 final architecture)
//
// PURPOSE:
// MainActor process singleton, composition root, and high-level compatibility
// façade for SwiftUI, CarPlay, AppDelegate, BGTask, APNs, and file-open entry
// points. It constructs/retains the typed coordinator/workflow graph, connects
// cross-domain collaborators once, guards singleton startup, and delegates every
// user/platform command to its named owner.
//
// OWNERSHIP BOUNDARY:
// - AppState owns singleton identity and compatibility API shape only.
// - AppStartupWorkflow owns callback connection, migrations, restoration, and
//   ordered service startup.
// - AppLifecycleCoordinator owns every retained lifecycle/maintenance Task.
// - AppRuntimeWorkflow owns scene/application policy and resource diagnostics.
// - Domain coordinators/workflows exclusively own playback, queue, download,
//   refresh/Radar, Auto Archive, import, history/Stats, iCloud sync, onboarding,
//   routing, notifications, media, chapters, and Play Instant behavior.
//
// INVARIANTS:
// - No domain callback, Combine subscription, retained Task, persistence
//   transaction, or domain state-machine implementation belongs in this file.
// - SwiftUI observes narrow domain owners directly; AppState does not forward
//   objectWillChange.
// - Compatibility getters are side-effect free. High-level commands may
//   coordinate domains only by delegating to a named workflow.
// - `bootstrap()` publishes exactly one instance before `start()` can emit work;
//   repeated phone/CarPlay/background bootstrap requests resolve that instance.
// - Persistence formats, CloudKit schemas, queue rules, and release
//   behavior are owned elsewhere and must not be duplicated here.
//
// AI CONTEXT — AppState startup state exposed by AppLifecycleCoordinator.
// AppStartupWorkflow performs ordered runtime startup after AppState publishes
// the singleton. Re-entrant/repeated starts are ignored. `stopped` is the
// deterministic process/test teardown state; a stopped graph is not restarted.
enum AppStartupState: String, Equatable {
    case constructed
    case starting
    case started
    case stopped
}

@MainActor
final class AppState: ObservableObject {
    let feedService: FeedServicing
    let downloadManager: DownloadManaging
    let playbackCoordinator: PlaybackCoordinator
    var playbackEngine: PlaybackControlling {
        get { playbackCoordinator.engine }
        set { playbackCoordinator.engine = newValue }
    }
    let chapterService: ChapterServicing
    let queueService: QueueServicing
    let settingsStore: SettingsStoring
    let settingsCoordinator: SettingsViewModel
    let subscriptionStore: SubscriptionStore
    let historyStatsCoordinator: HistoryStatsCoordinator
    let queueCoordinator: QueueCoordinator
    let onboardingCoordinator: OnboardingCoordinator
    let routingCoordinator: AppRoutingCoordinator
    let downloadCoordinator: DownloadCoordinator
    private let feedRefreshCoordinator: FeedRefreshCoordinator
    private let autoDownloadWorkflow: AutoDownloadWorkflow
    let autoArchiveCoordinator: AutoArchiveCoordinator
    let subscriptionImportCoordinator: SubscriptionImportCoordinator
    private let syncCoordinator: SyncCoordinator
    private let lifecycleCoordinator: AppLifecycleCoordinator
    var listeningHistoryStore: ListeningHistoryStore { historyStatsCoordinator.historyStore }
    var listeningStatsStore: ListeningStatsStore { historyStatsCoordinator.statsStore }
    var autoArchiveActivityStore: AutoArchiveActivityStore {
        autoArchiveCoordinator.activityStore
    }
    /// Opt-in cross-device sync engine (CloudKit). Started only while
    /// AppSettings.iCloudSyncEnabled is true. History/stats pushes are coalesced
    /// on a ~60 s slow lane inside the engine; flushDeferredSyncPushes(reason:)
    /// is the lifecycle checkpoint that pushes them immediately (pause,
    /// sleep-timer/schedule pause, scene background/resign-active).
    var downloadActivityStore: DownloadActivityStore {
        downloadCoordinator.activityStore
    }

    // Player state
    var currentPlayerEpisode: Episode? {
        get { playbackCoordinator.currentEpisode }
        set { playbackCoordinator.currentEpisode = newValue }
    }
    /// 2 Hz scrubber time lives on its own observable (PERF-1) so the tick no longer
    /// invalidates every AppState observer; this proxy keeps all existing call sites
    /// working. Views that render the ticking time observe `playbackClock` instead.
    var playbackClock: PlaybackClock { playbackCoordinator.clock }
    var currentPlayerTime: TimeInterval {
        get { playbackClock.time }
        set { playbackClock.time = newValue }
    }
    var isPlaying: Bool {
        get { playbackCoordinator.isPlaying }
        set { playbackCoordinator.isPlaying = newValue }
    }
    /// Per-episode progress publishes through a narrow leaf observable.
    var downloadProgressModel: DownloadProgressModel {
        downloadCoordinator.progressModel
    }
    // Sleep timer
    var sleepTimerService: SleepTimerService { playbackCoordinator.sleepTimerService }

    // Sleep Schedule (recurring nightly sleep timer with "still listening?" prompts)
    var sleepScheduleService: SleepScheduleService { playbackCoordinator.sleepScheduleService }
    private(set) static var shared: AppState!
    var startupState: AppStartupState { lifecycleCoordinator.state }

    private let logger = AppLogger.shared

    /// PlaybackPositionStore owns the durable JSON/cache. PlaybackMediaWorkflow
    /// owns filesystem repair and application-level save/restore transactions.
    private let playbackPositionStore: PlaybackPositionStore
    /// AI CONTEXT — retained here only to bind its lifetime to the application
    /// graph. Construction belongs to AppCompositionRoot and the coordinator
    /// observes narrow domain publishers; AppState does not project widget data.
    private var widgetSnapshotCoordinator: WidgetSnapshotCoordinator?
    private lazy var playbackMediaWorkflow = PlaybackMediaWorkflow(
        playback: playbackCoordinator,
        subscriptionStore: subscriptionStore,
        downloadManager: downloadManager,
        positionStore: playbackPositionStore,
        logger: logger
    )
    private lazy var playbackCheckpointWorkflow = PlaybackCheckpointWorkflow(
        mediaWorkflow: playbackMediaWorkflow,
        historyStatsCoordinator: historyStatsCoordinator,
        syncCoordinator: syncCoordinator
    )
    private lazy var playbackPreferenceWorkflow = PlaybackPreferenceWorkflow(
        playback: playbackCoordinator,
        subscriptionStore: subscriptionStore,
        settingsStore: settingsStore,
        logger: logger
    )
    private lazy var newEpisodeNotificationWorkflow =
        NewEpisodeNotificationWorkflow(
            logger: logger
        )
    private lazy var episodeCompletionWorkflow = EpisodeCompletionWorkflow(
        playbackCoordinator: playbackCoordinator,
        historyStatsCoordinator: historyStatsCoordinator,
        subscriptionStore: subscriptionStore,
        downloadManager: downloadManager,
        playbackPositionStore: playbackPositionStore,
        logger: logger
    )
    private lazy var episodeDispositionWorkflow = EpisodeDispositionWorkflow(
        playback: playbackCoordinator,
        historyStatsCoordinator: historyStatsCoordinator,
        subscriptionStore: subscriptionStore,
        downloadManager: downloadManager,
        downloadCoordinator: downloadCoordinator,
        queueCoordinator: queueCoordinator,
        playbackPositionStore: playbackPositionStore,
        logger: logger
    )
    private lazy var downloadTransferWorkflow = DownloadTransferWorkflow(
        coordinator: downloadCoordinator,
        downloadManager: downloadManager,
        subscriptionStore: subscriptionStore,
        settingsStore: settingsStore,
        historyStatsCoordinator: historyStatsCoordinator,
        logger: logger,
        mediaWorkflow: playbackMediaWorkflow,
        notificationWorkflow: newEpisodeNotificationWorkflow,
        runtimeWorkflow: appRuntimeWorkflow
    )
    private lazy var downloadActionsWorkflow = DownloadActionsWorkflow(
        playback: playbackCoordinator,
        downloadCoordinator: downloadCoordinator,
        downloadManager: downloadManager,
        subscriptionStore: subscriptionStore,
        playbackPositionStore: playbackPositionStore,
        historyStatsCoordinator: historyStatsCoordinator,
        logger: logger,
        transferWorkflow: downloadTransferWorkflow,
        dispositionWorkflow: episodeDispositionWorkflow
    )
    private lazy var autoDownloadIntentWorkflow = AutoDownloadIntentWorkflow(
        state: autoDownloadWorkflow,
        subscriptionStore: subscriptionStore,
        downloadCoordinator: downloadCoordinator,
        autoArchiveCoordinator: autoArchiveCoordinator,
        queueCoordinator: queueCoordinator,
        logger: logger,
        transferWorkflow: downloadTransferWorkflow
    )
    private lazy var releaseRadarWorkflow = ReleaseRadarWorkflow(
        coordinator: feedRefreshCoordinator,
        feedService: feedService,
        subscriptionStore: subscriptionStore,
        logger: logger,
        minimumRecheckInterval: automaticReleaseRadarBaseInterval
    )
    private lazy var appRuntimeWorkflow = AppRuntimeWorkflow(
        lifecycle: lifecycleCoordinator,
        playback: playbackCoordinator,
        settingsStore: settingsStore,
        settingsCoordinator: settingsCoordinator,
        syncCoordinator: syncCoordinator,
        subscriptionStore: subscriptionStore,
        checkpointWorkflow: playbackCheckpointWorkflow,
        feedRefreshCoordinator: feedRefreshCoordinator,
        releaseRadar: releaseRadarWorkflow,
        autoArchiveCoordinator: autoArchiveCoordinator,
        queueCoordinator: queueCoordinator,
        downloadCoordinator: downloadCoordinator,
        logger: logger,
        resourceMonitor: .shared,
        environment: .live(),
        backgroundAudioMinimumInterval:
            backgroundAudioRefreshMinimumInterval
    )
    private lazy var feedRefreshItemWorkflow = FeedRefreshItemWorkflow(
        feedService: feedService,
        subscriptionStore: subscriptionStore,
        downloadManager: downloadManager,
        playback: playbackCoordinator,
        feedRefreshCoordinator: feedRefreshCoordinator,
        downloadActionsWorkflow: downloadActionsWorkflow,
        autoDownloadIntentWorkflow: autoDownloadIntentWorkflow,
        queueCoordinator: queueCoordinator,
        releaseRadarWorkflow: releaseRadarWorkflow,
        logger: logger,
        failureBackoffInterval: feedFailureBackoffInterval,
        runtimeWorkflow: appRuntimeWorkflow
    )
    private lazy var feedRefreshCycleWorkflow: FeedRefreshCycleWorkflow = {
        let runtimeWorkflow = appRuntimeWorkflow
        return FeedRefreshCycleWorkflow(
            coordinator: feedRefreshCoordinator,
            subscriptionStore: subscriptionStore,
            downloadCoordinator: downloadCoordinator,
            playback: playbackCoordinator,
            releaseRadar: releaseRadarWorkflow,
            itemWorkflow: feedRefreshItemWorkflow,
            queueCoordinator: queueCoordinator,
            autoArchiveCoordinator: autoArchiveCoordinator,
            logger: logger,
            policy: FeedRefreshCycleWorkflow.Policy(
                defaultEpisodeLimit: defaultFeedEpisodeLimit,
                backgroundRefreshLimit: backgroundRefreshFeedLimit,
                backgroundProtectedMinimum:
                    backgroundReleaseRadarReservedSlots,
                backgroundProtectedStates:
                    backgroundReleaseRadarProtectedStates,
                foregroundLimit: foregroundRefreshFeedLimit,
                backgroundAudioLimit: backgroundAudioRefreshFeedLimit,
                backgroundAudioHardLimit: backgroundAudioRefreshHardLimit,
                backgroundAudioMinimumInterval:
                    backgroundAudioRefreshMinimumInterval,
                foregroundCapBypassStates:
                    foregroundRefreshCapBypassStates,
                backgroundAudioCapBypassStates:
                    backgroundAudioCapBypassStates
            ),
            sceneActive: { [weak runtimeWorkflow] in
                runtimeWorkflow?.isSceneActive ?? false
            },
            appForeground: { [weak runtimeWorkflow] in
                runtimeWorkflow?.isAppForeground ?? false
            },
            runtimeWorkflow: runtimeWorkflow
        )
    }()
    private lazy var playInstantWorkflow = PlayInstantWorkflow(
        playback: playbackCoordinator,
        subscriptionStore: subscriptionStore,
        logger: logger,
        mediaWorkflow: playbackMediaWorkflow
    )
    private lazy var playbackSeekWorkflow = PlaybackSeekWorkflow(
        playback: playbackCoordinator,
        subscriptionStore: subscriptionStore,
        historyStatsCoordinator: historyStatsCoordinator,
        logger: logger,
        preferenceWorkflow: playbackPreferenceWorkflow,
        completionWorkflow: episodeCompletionWorkflow
    )
    private lazy var playbackChapterWorkflow = PlaybackChapterWorkflow(
        playback: playbackCoordinator,
        chapterService: chapterService,
        subscriptionStore: subscriptionStore,
        queueCoordinator: queueCoordinator,
        seekWorkflow: playbackSeekWorkflow
    )
    private lazy var playbackStartWorkflow = PlaybackStartWorkflow(
        playback: playbackCoordinator,
        subscriptionStore: subscriptionStore,
        settingsStore: settingsStore,
        historyStatsCoordinator: historyStatsCoordinator,
        logger: logger,
        mediaWorkflow: playbackMediaWorkflow,
        downloadWorkflow: downloadTransferWorkflow,
        preferenceWorkflow: playbackPreferenceWorkflow,
        syncCoordinator: syncCoordinator,
        chapterWorkflow: playbackChapterWorkflow,
        runtimeWorkflow: appRuntimeWorkflow
    )
    private lazy var playbackTransportWorkflow = PlaybackTransportWorkflow(
        playback: playbackCoordinator,
        subscriptionStore: subscriptionStore,
        queueCoordinator: queueCoordinator,
        playbackPositionStore: playbackPositionStore,
        checkpointWorkflow: playbackCheckpointWorkflow,
        logger: logger,
        preferenceWorkflow: playbackPreferenceWorkflow,
        startWorkflow: playbackStartWorkflow,
        playInstantWorkflow: playInstantWorkflow,
        runtimeWorkflow: appRuntimeWorkflow
    )
    private lazy var playbackLaunchWorkflow = PlaybackLaunchWorkflow(
        playback: playbackCoordinator,
        queueCoordinator: queueCoordinator,
        subscriptionStore: subscriptionStore,
        logger: logger,
        preferenceWorkflow: playbackPreferenceWorkflow,
        startWorkflow: playbackStartWorkflow
    )
    private lazy var appStartupWorkflow = AppStartupWorkflow(
        lifecycle: lifecycleCoordinator,
        settingsStore: settingsStore,
        settingsCoordinator: settingsCoordinator,
        subscriptionStore: subscriptionStore,
        historyStatsCoordinator: historyStatsCoordinator,
        queueCoordinator: queueCoordinator,
        onboardingCoordinator: onboardingCoordinator,
        routingCoordinator: routingCoordinator,
        downloadCoordinator: downloadCoordinator,
        downloadManager: downloadManager,
        downloadActionsWorkflow: downloadActionsWorkflow,
        autoDownloadIntentWorkflow: autoDownloadIntentWorkflow,
        autoDownloadIntentStore: autoDownloadWorkflow.intentStore,
        autoArchiveCoordinator: autoArchiveCoordinator,
        syncCoordinator: syncCoordinator,
        playbackCoordinator: playbackCoordinator,
        playbackPreferenceWorkflow: playbackPreferenceWorkflow,
        playbackSeekWorkflow: playbackSeekWorkflow,
        playbackCheckpointWorkflow: playbackCheckpointWorkflow,
        playbackMediaWorkflow: playbackMediaWorkflow,
        episodeCompletionWorkflow: episodeCompletionWorkflow,
        playbackTransportWorkflow: playbackTransportWorkflow,
        playInstantWorkflow: playInstantWorkflow,
        newEpisodeNotificationWorkflow:
            newEpisodeNotificationWorkflow,
        feedRefreshCycleWorkflow: feedRefreshCycleWorkflow,
        releaseRadarWorkflow: releaseRadarWorkflow,
        appRuntimeWorkflow: appRuntimeWorkflow,
        logger: logger
    )
    // MARK: - Computed queue

    var downloadedQueue: [Episode] {
        queueCoordinator.episodes
    }

    // MARK: - Computed player helpers

    func isQueuePinnedNext(_ episode: Episode) -> Bool {
        queueCoordinator.isPinnedNext(episode)
    }

    func isQueuePinnedLast(_ episode: Episode) -> Bool {
        queueCoordinator.isPinnedLast(episode)
    }

    func episodeIsCurrent(_ episode: Episode) -> Bool {
        currentPlayerEpisode?.id == episode.id
    }

    func podcastTitle(for episode: Episode) -> String? {
        subscriptionStore.subscription(id: episode.subscriptionID)?.title
    }

    /// Returns the current playback position for an episode: live time if it's playing now,
    /// otherwise the last saved position. Returns 0 if no position has been recorded.
    func effectivePlaybackTime(for episode: Episode) -> TimeInterval {
        if currentPlayerEpisode?.id == episode.id {
            return currentPlayerTime
        }
        return playbackMediaWorkflow.savedTime(for: episode)
    }

    private let defaultFeedEpisodeLimit = 50
    private let feedFailureBackoffInterval: TimeInterval = 30 * 60
    private let backgroundRefreshFeedLimit = 8
    private let backgroundReleaseRadarReservedSlots = 6
    private let backgroundReleaseRadarProtectedStates: Set<FeedRefreshWindowState> = [
        .preWindow,
        .activeWindow,
        .missedRelease
    ]
    private let foregroundRefreshFeedLimit = 12
    /// AI CONTEXT — background audio is a refresh opportunity, not permission for
    /// continuous foreground-rate polling. This cap and global gate bound network,
    /// parse, and radio cost during long screen-off listening sessions.
    private let backgroundAudioRefreshFeedLimit = 7
    private let backgroundAudioRefreshHardLimit = 10
    private let backgroundAudioRefreshMinimumInterval: TimeInterval = 4 * 60
    private let foregroundRefreshCapBypassStates: Set<FeedRefreshWindowState> = [.activeWindow, .preWindow]
    private let backgroundAudioCapBypassStates: Set<FeedRefreshWindowState> = [.preWindow, .activeWindow, .missedRelease]
    /// Automatic base cadence. State-specific scheduling expands this to five
    /// minutes in pre-window and 5–10 minutes after a missed release; random and
    /// unreliable feeds retain their 15–60 minute adaptive surveillance.
    private let automaticReleaseRadarBaseInterval: TimeInterval = 3 * 60
    // MARK: - Init

    /// AI CONTEXT — PlaybackPositionStore is explicit here even though AppState
    /// is @MainActor. Do not restore `= PlaybackPositionStore()` as a default
    /// argument: Swift evaluates default expressions in the caller's
    /// synchronous nonisolated context and rejects this main-actor initializer.
    /// AppCompositionRoot and the compatibility initializer construct it while
    /// already on the main actor.
    init(
        feedService: FeedServicing,
        downloadManager: DownloadManaging,
        playbackEngine: PlaybackControlling,
        chapterService: ChapterServicing,
        queueService: QueueServicing,
        settingsStore: SettingsStoring,
        subscriptionStore: SubscriptionStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        queueCoordinator: QueueCoordinator,
        onboardingCoordinator: OnboardingCoordinator,
        routingCoordinator: AppRoutingCoordinator,
        playbackPositionStore: PlaybackPositionStore
    ) {
        self.feedService = feedService
        self.downloadManager = downloadManager
        self.playbackCoordinator = PlaybackCoordinator(engine: playbackEngine)
        self.chapterService = chapterService
        self.queueService = queueService
        self.settingsStore = settingsStore
        self.settingsCoordinator = SettingsViewModel(settingsStore: settingsStore)
        self.subscriptionStore = subscriptionStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.queueCoordinator = queueCoordinator
        self.onboardingCoordinator = onboardingCoordinator
        self.routingCoordinator = routingCoordinator
        self.playbackPositionStore = playbackPositionStore
        self.downloadCoordinator = DownloadCoordinator()
        self.feedRefreshCoordinator = FeedRefreshCoordinator()
        self.autoDownloadWorkflow = AutoDownloadWorkflow()
        self.autoArchiveCoordinator = AutoArchiveCoordinator(
            subscriptionStore: subscriptionStore,
            settingsStore: settingsStore
        )
        self.subscriptionImportCoordinator = SubscriptionImportCoordinator(
            feedService: feedService,
            subscriptionStore: subscriptionStore,
            episodeLimit: defaultFeedEpisodeLimit
        )
        self.syncCoordinator = SyncCoordinator(
            feedService: feedService,
            subscriptionStore: subscriptionStore,
            historyStatsCoordinator: historyStatsCoordinator,
            queueCoordinator: queueCoordinator
        )
        self.lifecycleCoordinator = AppLifecycleCoordinator()
        queueCoordinator.observePlayback(playbackCoordinator)
        playbackCoordinator.observeChapters(playbackChapterWorkflow)
        syncCoordinator.observePlayback(playbackCoordinator)
        let instantWorkflow = playInstantWorkflow
        let startWorkflow = playbackStartWorkflow
        let transportWorkflow = playbackTransportWorkflow
        downloadTransferWorkflow.observePlayInstant(instantWorkflow)
        instantWorkflow.installPlaybackWorkflows(
            startWorkflow: startWorkflow,
            transportWorkflow: transportWorkflow
        )
        episodeCompletionWorkflow.installNavigation(
            playInstantWorkflow: instantWorkflow,
            transportWorkflow: transportWorkflow
        )
        episodeDispositionWorkflow.installNavigation(
            playInstantWorkflow: instantWorkflow,
            transportWorkflow: transportWorkflow
        )
        autoArchiveCoordinator.installRuntime(
            dispositionWorkflow: episodeDispositionWorkflow,
            playbackCoordinator: playbackCoordinator,
            queueCoordinator: queueCoordinator,
            runtimeWorkflow: appRuntimeWorkflow
        )
    }

    /// Composition-only lifetime hook. Widget projection remains independently
    /// owned and never becomes an AppState forwarding API.
    func installWidgetSnapshotCoordinator(
        _ coordinator: WidgetSnapshotCoordinator
    ) {
        guard widgetSnapshotCoordinator == nil else { return }
        widgetSnapshotCoordinator = coordinator
        coordinator.start()
    }

    /// Typed external-entry checkpoint used after an App Intent outcome. The
    /// coordinator still owns projection, dedupe, persistence, and reload.
    func requestWidgetSnapshotPublication(reason: String) {
        widgetSnapshotCoordinator?.schedulePublication(
            reason: reason,
            immediately: true
        )
    }

    /// AI CONTEXT — BGTask completion hook for nonessential widget projection.
    /// The finite OS task window is already closed in BackgroundWakeMonitor.
    /// Publish deferred reasons now only when foreground or active audio keeps
    /// the process executable; otherwise the next foreground/domain event
    /// coalesces them. This method does not affect feed/download/archive work.
    func backgroundTaskExecutionDidEnd() {
        widgetSnapshotCoordinator?.backgroundTaskExecutionDidEnd(
            allowImmediatePublication:
                appRuntimeWorkflow.isAppForeground
                    || playbackCoordinator.isPlaying
                    || playbackCoordinator.engine.isPlaying
        )
    }

    /// Compatibility initializer retained for existing tests and transitional
    /// call sites. Production construction is owned by AppCompositionRoot.
    convenience init(
        feedService: FeedServicing,
        downloadManager: DownloadManaging,
        playbackEngine: PlaybackControlling,
        chapterService: ChapterServicing,
        queueService: QueueServicing,
        settingsStore: SettingsStoring,
        subscriptionStore: SubscriptionStore
    ) {
        let playbackPositionStore = PlaybackPositionStore()
        let historyStatsCoordinator = HistoryStatsCoordinator(
            historyStore: ListeningHistoryStore(),
            statsStore: ListeningStatsStore(),
            subscriptionStore: subscriptionStore,
            playbackPositionStore: playbackPositionStore
        )
        let queueCoordinator = QueueCoordinator(
            subscriptionStore: subscriptionStore,
            queueService: queueService,
            currentEpisode: { nil },
            showBadge: { settingsStore.appSettings.showQueueBadge }
        )
        self.init(
            feedService: feedService,
            downloadManager: downloadManager,
            playbackEngine: playbackEngine,
            chapterService: chapterService,
            queueService: queueService,
            settingsStore: settingsStore,
            subscriptionStore: subscriptionStore,
            historyStatsCoordinator: historyStatsCoordinator,
            queueCoordinator: queueCoordinator,
            onboardingCoordinator: OnboardingCoordinator(
                subscriptionStore: subscriptionStore,
                settingsStore: settingsStore
            ),
            routingCoordinator: AppRoutingCoordinator(),
            playbackPositionStore: playbackPositionStore
        )
    }

    /// Resolves the process-wide AppState. Concrete production construction lives
    /// in AppCompositionRoot; the optional root/start flag are Stage 0 test seams
    /// used to verify singleton identity without launching OS-owned services.
    static func bootstrap(
        compositionRoot: AppCompositionRoot? = nil,
        startRuntime: Bool = true
    ) -> AppState {
        let bootstrapStartedAt = CFAbsoluteTimeGetCurrent()
        // Re-entrancy / single-instance guard. bootstrap() runs on the @MainActor and is
        // synchronous, so two *concurrent* callers can't interleave — but a caller reached
        // from within bootstrap's own setup (or any future `await` added before the shared
        // assignment) could otherwise build a SECOND AppState. Returning the existing
        // instance here, and publishing `shared` the instant it exists (below), guarantees
        // one instance no matter how many sharedOrBootstrap() callers race (e.g. a CarPlay
        // cold-launch scene and the phone WindowGroup both bootstrapping at startup).
        if let shared {
            if startRuntime { shared.start() }
            return shared
        }

        let state = (compositionRoot ?? AppCompositionRoot.production()).makeAppState()
        let constructionFinishedAt = CFAbsoluteTimeGetCurrent()
        // Publish immediately, before the remaining setup, so any re-entrant
        // sharedOrBootstrap() during bootstrap resolves to THIS instance.
        AppState.shared = state
        if startRuntime {
            state.start(
                bootstrapStartedAt: bootstrapStartedAt,
                constructionFinishedAt: constructionFinishedAt
            )
        }
        return state
    }

    /// Explicit, idempotent runtime start. AppStartupWorkflow owns ordered graph
    /// connection, service startup, migrations, restoration, and maintenance.
    func start() {
        let now = CFAbsoluteTimeGetCurrent()
        start(bootstrapStartedAt: now, constructionFinishedAt: now)
    }

    private func start(
        bootstrapStartedAt: CFAbsoluteTime,
        constructionFinishedAt: CFAbsoluteTime
    ) {
        guard beginStartupTransition() else {
            return
        }
        appStartupWorkflow.start(
            bootstrapStartedAt: bootstrapStartedAt,
            constructionFinishedAt: constructionFinishedAt
        )
        lifecycleCoordinator.finishStart()
    }

    private func beginStartupTransition() -> Bool {
        guard lifecycleCoordinator.beginStart() else {
            logger.info("app.startSkipped", "AppState start ignored because runtime is already starting or started", metadata: [
                "startupState": startupState.rawValue
            ])
            return false
        }
        return true
    }

    /// Stage 12 deterministic teardown seam. Cancels coordinator-owned pollers
    /// and maintenance work without deleting persisted state.
    func stop() {
        widgetSnapshotCoordinator?.stop()
        feedRefreshCycleWorkflow.cancel(reason: "app.stop")
        appRuntimeWorkflow.stop()
        lifecycleCoordinator.stop()
    }

#if DEBUG
    /// Stage 0 harness seam: exercises the exact production startup-state guard
    /// without installing OS callbacks or launching long-lived work.
    @discardableResult
    func _runCharacterizationStart(_ work: () -> Void) -> Bool {
        guard beginStartupTransition() else { return false }
        work()
        lifecycleCoordinator.finishStart()
        return true
    }

    /// Tests must restore the process singleton after identity characterization.
    static func _resetSharedForCharacterization() {
        shared = nil
    }
#endif

    static func sharedOrBootstrap() -> AppState {
        if let shared {
            return shared
        }
        return bootstrap()
    }

    // MARK: - Playback controls

    /// AI CONTEXT — "Audio hijack" fix (2026-07-12): re-pushes the FULL Now
    /// Playing card (not just the elapsed-time patch) for the loaded episode,
    /// re-claiming the system's now-playing slot. Called when a removed output
    /// device returns (PlaybackEngine.onRouteRestored — the AirPods-stem-press-
    /// resumed-Apple-Music report) and on scene foreground (AutohopApp), both
    /// moments where the slot claim can have gone stale while the episode is
    /// still loaded. Safe to call redundantly: it only rewrites metadata that
    /// is already true and never touches the audio session or playback state.
    func reassertNowPlayingCard(reason: String) {
        playbackPreferenceWorkflow.reassertNowPlayingCard(reason: reason)
    }

    func togglePlayPause() async {
        await playbackTransportWorkflow.togglePlayPause()
    }

    func startPlaybackOnLaunchIfNeeded() async {
        await playbackLaunchWorkflow.preparePhoneLaunch()
    }

    func resumePlaybackForCarPlayLaunchIfNeeded() async {
        await playbackLaunchWorkflow.resumeForCarPlayLaunch()
    }

    /// Manual skip-forward: credits the skipped seconds to the "Skipping" time-saved stat,
    /// then seeks. Both the Player skip button and the lock-screen / AirPods skip command
    /// route through here — previously they called `seek(to:)` directly, so the manual-skip
    /// stat (onManualSkipForward → addManualSkipForward) never ran and the Stats "Skipping"
    /// row was permanently 0s. `seek(to:)` keeps its own side effects (sleep-schedule
    /// "still listening", logging, position persistence).
    func skipForward(seconds: TimeInterval) {
        playbackSeekWorkflow.skipForward(seconds: seconds)
    }

    func seek(to seconds: TimeInterval) {
        playbackSeekWorkflow.seek(to: seconds)
    }

    /// Internal cross-device counterpart to seek(to:). It updates an open,
    /// paused player's in-memory playhead without treating iCloud as a user
    /// transport command.
    func applyRemotePlaybackPosition(_ seconds: TimeInterval) {
        playbackSeekWorkflow.applyRemotePosition(seconds)
    }

    /// Compatibility façade for chapter settings screens. Chapter ownership and
    /// the persist-then-apply transaction live in PlaybackChapterWorkflow.
    func toggleChapter(subscriptionID: UUID, position: Int) {
        playbackChapterWorkflow.toggleChapter(
            subscriptionID: subscriptionID,
            position: position
        )
    }

    func applyChapterFilter(_ filter: ChapterFilter, subscriptionID: UUID) {
        playbackChapterWorkflow.apply(
            filter,
            subscriptionID: subscriptionID
        )
    }

    func navigateToPreviousChapter() {
        playbackChapterWorkflow.navigateToPrevious()
    }

    func navigateToNextChapter() {
        playbackChapterWorkflow.navigateToNext()
    }

    // MARK: - Download

    func downloadLatestEpisode(for subscription: Subscription) async {
        await downloadActionsWorkflow.downloadLatestEpisode(for: subscription)
    }

    func downloadEpisodeForQueue(_ episode: Episode) async {
        await downloadActionsWorkflow.downloadEpisodeForQueue(episode)
    }

    func downloadEpisodeForCarPlayAction(_ episode: Episode) async -> Episode? {
        await downloadActionsWorkflow.downloadEpisodeForCarPlayAction(episode)
    }

    func deleteDownloadedEpisode(_ episode: Episode) async {
        await downloadActionsWorkflow.deleteDownloadedEpisode(episode)
    }

    func pauseDownload(_ activity: DownloadActivity) {
        downloadActionsWorkflow.pauseDownload(activity)
    }

    func resumeDownload(_ activity: DownloadActivity) async {
        await downloadActionsWorkflow.resumeDownload(activity)
    }

    func cancelDownload(_ activity: DownloadActivity) {
        downloadActionsWorkflow.cancelDownload(activity)
    }

    /// Archives an episode from the Downloads page. Works for all statuses (downloading, paused,
    /// failed, completed): cancels any active URLSession task first, deletes any partial or full
    /// local file, then marks the episode as Archived — exactly as Archive does elsewhere in the app.
    func archiveDownload(_ activity: DownloadActivity) async {
        await downloadActionsWorkflow.archiveDownload(activity)
    }

    func markEpisodePlayed(_ episode: Episode) async {
        await episodeDispositionWorkflow.markPlayed(episode)
    }

    func archiveEpisode(_ episode: Episode, completionKind: CompletionKind = .manuallyArchived) async {
        await episodeDispositionWorkflow.archive(
            episode,
            completionKind: completionKind
        )
    }

    func archiveEpisodeAndPlayNext(_ episode: Episode) async {
        await episodeDispositionWorkflow.archiveAndPlayNext(episode)
    }

    func archiveCurrentEpisodeAndPlayNext() async {
        await episodeDispositionWorkflow.archiveCurrentAndPlayNext()
    }

    func unarchiveEpisode(_ episode: Episode) {
        episodeDispositionWorkflow.unarchive(episode)
    }

    // MARK: - Playback

    func playNextEpisode(excluding excludedEpisodeIDs: Set<UUID> = []) async {
        await playbackTransportWorkflow.playNextEpisode(
            excluding: excludedEpisodeIDs
        )
    }

    /// Play a specific episode immediately, regardless of queue order.
    func playEpisode(_ episode: Episode) async {
        await playbackTransportWorkflow.playEpisode(episode)
    }

    func playEpisodeNext(_ episode: Episode) {
        queueCoordinator.playNext(episode)
    }

    func unpinEpisode(_ episode: Episode) {
        queueCoordinator.unpin(episode)
    }

    func playEpisodeLast(_ episode: Episode) {
        queueCoordinator.playLast(episode)
    }

    func skipToEpisode(_ episode: Episode) async {
        await playbackTransportWorkflow.skipToEpisode(episode)
    }

    func updatePlaybackSpeed(for subscriptionID: UUID, speed: Double) {
        playbackPreferenceWorkflow.updatePlaybackSpeed(
            for: subscriptionID,
            speed: speed
        )
    }

    func cyclePlaybackSpeedForCurrentEpisode() {
        playbackPreferenceWorkflow.cyclePlaybackSpeedForCurrentEpisode()
    }

    func setPlaybackSpeedForCurrentEpisode(_ speed: Double) {
        playbackPreferenceWorkflow.setPlaybackSpeedForCurrentEpisode(speed)
    }

    func updateVocalBoost(for subscriptionID: UUID, level: VocalBoostLevel) {
        playbackPreferenceWorkflow.updateVocalBoost(
            for: subscriptionID,
            level: level
        )
    }

    func updateVolumeAdjustment(for subscriptionID: UUID, adjustment: Int) {
        playbackPreferenceWorkflow.updateVolumeAdjustment(
            for: subscriptionID,
            adjustment: adjustment
        )
    }

    func updateAudioChannelMode(for subscriptionID: UUID, mode: AudioChannelMode) {
        playbackPreferenceWorkflow.updateAudioChannelMode(
            for: subscriptionID,
            mode: mode
        )
    }

    func updateLockScreenScrubbing(enabled: Bool) {
        playbackPreferenceWorkflow.updateLockScreenScrubbing(enabled: enabled)
    }

    func updateTrimSilence(for subscriptionID: UUID, amount: TrimSilenceAmount) {
        playbackPreferenceWorkflow.updateTrimSilence(
            for: subscriptionID,
            amount: amount
        )
    }

    func updateEpisodeTrim(
        for subscriptionID: UUID,
        startSkipSeconds: TimeInterval? = nil,
        endSkipSeconds: TimeInterval? = nil
    ) {
        playbackPreferenceWorkflow.updateEpisodeTrim(
            for: subscriptionID,
            startSkipSeconds: startSkipSeconds,
            endSkipSeconds: endSkipSeconds
        )
    }

    // MARK: - Default Playback Preference (global, for new + non-subscribed feeds)

    func updateDefaultPlaybackSpeed(_ speed: Double) {
        playbackPreferenceWorkflow.updateDefaultPlaybackSpeed(speed)
    }

    func updateDefaultVocalBoost(_ level: VocalBoostLevel) {
        playbackPreferenceWorkflow.updateDefaultVocalBoost(level)
    }

    func updateDefaultAudioChannelMode(_ mode: AudioChannelMode) {
        playbackPreferenceWorkflow.updateDefaultAudioChannelMode(mode)
    }

    func updateDefaultTrimSilence(_ amount: TrimSilenceAmount) {
        playbackPreferenceWorkflow.updateDefaultTrimSilence(amount)
    }

    func updateDefaultEpisodeTrim(
        startSkipSeconds: TimeInterval? = nil,
        endSkipSeconds: TimeInterval? = nil
    ) {
        playbackPreferenceWorkflow.updateDefaultEpisodeTrim(
            startSkipSeconds: startSkipSeconds,
            endSkipSeconds: endSkipSeconds
        )
    }

    // MARK: - Shared Listening (global temporary override)

    var sharedListeningActive: Bool {
        playbackPreferenceWorkflow.sharedListeningActive
    }
    var sharedListeningSpeed: Double {
        playbackPreferenceWorkflow.sharedListeningSpeed
    }

    static let sharedListeningSpeedOptions: [Double] = [1.0, 1.1, 1.2, 1.3]

    func setSharedListening(active: Bool) {
        playbackPreferenceWorkflow.setSharedListening(active: active)
    }

    func updateSharedListeningSpeed(_ speed: Double) {
        playbackPreferenceWorkflow.updateSharedListeningSpeed(speed)
    }

    func effectiveSpeed(for subscription: Subscription) -> Double {
        playbackPreferenceWorkflow.effectiveSpeed(for: subscription)
    }

    // MARK: - Feed refresh

    func refreshSubscription(_ subscription: Subscription, episodeLimit: Int? = 50, refreshUpNextAfterMerge: Bool = true) async {
        if let until = subscription.refreshStats.parseQuarantineUntil,
           until > appRuntimeWorkflow.now {
            logger.warning(
                "feed.parseMemoryQuarantineManualOverride",
                "User explicitly refreshed one feed despite its parse-memory quarantine",
                metadata: [
                    "podcast": subscription.title,
                    "subscriptionID": subscription.id.uuidString,
                    "quarantineUntil": until.ISO8601Format()
                ]
            )
        }
        await feedRefreshItemWorkflow.refresh(
            subscription,
            episodeLimit: episodeLimit,
            refreshUpNextAfterMerge: refreshUpNextAfterMerge
        )
    }

    /// Retries persisted auto-download intents (AH-2026-06-28-01). Idempotent:
    /// every intent is first settled against current state, in-flight transfers
    /// are left alone, and the actual attempt goes through
    /// runAutoDownloadAfterRefresh, whose guards re-validate eligibility.
    /// Called at launch (after reconcileOrphanedDownloads), on scene-foreground,
    /// and (unawaited) at the end of both BG task handlers.
    /// Per-episode auto-download failure backoff, keyed by the episode's stable `guid`
    /// (identity across feed refreshes). A permanently-broken enclosure — e.g. a server
    /// returning HTTP 500 on every attempt — would otherwise be retried on every intent
    /// drain (launch / foreground / BG-task end). Track consecutive failures + an
    /// exponential cooldown so it's skipped until the cooldown passes. In-memory: a fresh
    /// launch grants one more attempt (the server may have recovered) and a successful
    /// download clears the entry.
    func drainAutoDownloadIntents(reason: String) async {
        await autoDownloadIntentWorkflow.drain(reason: reason)
    }

    /// Re-evaluates absolute download deadlines at process execution boundaries.
    /// BGTask handlers call this before feed work so a transfer that exhausted its
    /// first-byte window while suspended does not wait for the periodic timer.
    func reevaluateDownloadWatchdog(reason: String) {
        downloadCoordinator.reevaluateWatchdog(reason: reason)
    }

    /// Manual refresh (pull-to-refresh): every feed, ignoring due dates.
    func refreshAllSubscriptions(includeBackoffFeeds: Bool = false) async {
        await feedRefreshCycleWorkflow.refreshAll(
            includeBackoffFeeds: includeBackoffFeeds
        )
    }

    @discardableResult
    func refreshSubscriptionsForBackground(
        taskIdentifier: String = BackgroundTaskCoordinator.feedRefreshIdentifier
    ) async -> Bool {
        await feedRefreshCycleWorkflow.refreshForBackground(
            taskIdentifier: taskIdentifier
        )
    }

    @discardableResult
    func refreshAdditionalSubscriptionsForBackground(
        taskIdentifier: String,
        cooperativeSecondsRemaining: TimeInterval
    ) async -> Bool {
        await feedRefreshCycleWorkflow.refreshAdditionalForBackground(
            taskIdentifier: taskIdentifier,
            cooperativeSecondsRemaining: cooperativeSecondsRemaining
        )
    }

    /// Longer catch-up run from a BGProcessingTask (charging + network, several
    /// minutes of runtime — far more than BGAppRefreshTask's ~30 s). Refreshes ALL
    /// due feeds with no cap and retries backed-off feeds, draining the deferred
    /// backlog, so a user who hasn't listened for a long stretch (e.g. overnight)
    /// wakes up to fully-refreshed feeds and downloaded episodes. Joins an in-flight
    /// cycle if one is already running. See BACKGROUND_REFRESH_RESEARCH.md (Tier 2).
    @discardableResult
    func refreshSubscriptionsForProcessing(
        taskIdentifier: String = BackgroundTaskCoordinator.feedProcessingIdentifier
    ) async -> Bool {
        await feedRefreshCycleWorkflow.refreshForProcessing(
            taskIdentifier: taskIdentifier
        )
    }

    /// Called from a BGTask expiration handler. Cancels the active refresh cycle
    /// ONLY when no live foreground/audio context is driving it. If the app is
    /// genuinely foreground (`isAppForeground`) or audio is playing, that context
    /// will finish the cycle, so an expiring BGTask that merely *joined* it must
    /// detach rather than abort shared work. Uses the real UIApplication state, not
    /// the cached `isSceneActive`. Otherwise falls through to cancel + checkpoint.
    func cancelRefreshCycleIfOwnedByBackgroundTask(
        taskIdentifier: String,
        reason: String
    ) {
        feedRefreshCycleWorkflow.cancelIfOwnedByBackgroundTask(
            taskIdentifier: taskIdentifier,
            reason: reason
        )
    }

    /// Snapshot for the Feed Refresh Schedule diagnostics page
    /// (Views/FeedRefreshScheduleView): the learned schedule profile + next-window
    /// prediction for one subscription — the same FeedScheduleProfile /
    /// FeedRefreshPrediction the refresh scheduler itself uses.
    func releaseRadarSchedule(
        for subscription: Subscription,
        now: Date? = nil
    ) -> (
        profile: FeedScheduleProfile,
        prediction: FeedRefreshPrediction
    ) {
        releaseRadarWorkflow.schedule(for: subscription, now: now)
    }

    /// Learning-only "Rebuild Prediction" (Feed Refresh Schedule page button): fetches
    /// up to `episodeLimit` recent episodes from the feed and records their publish
    /// dates into the Release Radar learner (`RefreshStats.releaseObservations`) to
    /// bootstrap a stronger schedule profile — WITHOUT merging the episodes into the
    /// library/queue, running auto-download/auto-archive, or disturbing the normal
    /// refresh cadence (lastFetchedAt is left untouched). All fetched episodes are
    /// marked already-known so they're recorded as *history*, not false real-time
    /// "new release" signals. Returns the episode count whose dates were recorded, or
    /// nil on failure.
    @discardableResult
    func rebuildReleasePrediction(for subscription: Subscription, episodeLimit: Int = 100) async -> Int? {
        await releaseRadarWorkflow.rebuildPrediction(
            for: subscription,
            episodeLimit: episodeLimit
        )
    }

    func loadFullEpisodeHistory(for subscription: Subscription) async {
        logger.info("feed.loadFullHistory", "Loading full episode history", metadata: [
            "podcast": subscription.title
        ])
        await refreshSubscription(
            subscription,
            episodeLimit: nil,
            refreshUpNextAfterMerge: true
        )
    }

    func runAutoArchiveIfNeeded(reason: String, force: Bool = false) async {
        await autoArchiveCoordinator.runIfNeeded(reason: reason, force: force)
    }

    // MARK: - OPML

    typealias OPMLImportSummary = SubscriptionImportSummary

    func importOPML(from fileURL: URL) async -> OPMLImportSummary {
        let summary = await subscriptionImportCoordinator.importOPML(from: fileURL)
        downloadCoordinator.message = subscriptionImportCoordinator.message
        return summary
    }

    // MARK: - Playback position persistence

    /// Scene-lifecycle two-phase checkpoint: make playback/history/Stats durable,
    /// then AutohopApp awaits SubscriptionStore's pending SQLite transaction
    /// before requesting the one final CloudKit scan.
    func preparePlaybackHistoryAndStatsCheckpoint() {
        playbackCheckpointWorkflow.prepareLocalCheckpoint()
    }

    /// Lifecycle checkpoint for sync: pushes any slow-lane (history/stats)
    /// CloudKit changes the engine is holding on its ~60 s coalescing debounce.
    /// HistoryStatsCoordinator calls this only after local history and Stats
    /// stores have flushed their pending sync rows. Other domains may also call
    /// it after their own durable checkpoint.
    func flushDeferredSyncPushes(reason: String) {
        syncCoordinator.flushDeferredPushes(reason: reason)
    }

    // MARK: - Runtime compatibility façade

    func handleScenePhaseChange(
        phaseName: String,
        isActive: Bool,
        isBackground: Bool
    ) {
        appRuntimeWorkflow.handleScenePhaseChange(
            phaseName: phaseName,
            isActive: isActive,
            isBackground: isBackground
        )
    }

    @discardableResult
    func releasePausedPlaybackResourcesForBackground(reason: String) -> Bool {
        appRuntimeWorkflow.releasePausedPlaybackResourcesForBackground(
            reason: reason
        )
    }

    func logActivePlaybackDiagnostics(
        reason: String,
        extra: [String: String] = [:]
    ) {
        appRuntimeWorkflow.logActivePlaybackDiagnostics(
            reason: reason,
            extra: extra
        )
    }

    func logResourceSnapshot(
        reason: String,
        extra: [String: String] = [:],
        force: Bool = true
    ) {
        appRuntimeWorkflow.logResourceSnapshot(
            reason: reason,
            extra: extra,
            force: force
        )
    }

    func logResourceWarningSnapshot(
        event: String,
        message: String,
        reason: String,
        extra: [String: String] = [:]
    ) {
        appRuntimeWorkflow.logResourceWarningSnapshot(
            event: event,
            message: message,
            reason: reason,
            extra: extra
        )
    }

    func updateIdleTimer(playerVisible: Bool) {
        appRuntimeWorkflow.updateIdleTimer(playerVisible: playerVisible)
    }

}
