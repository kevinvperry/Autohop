import Foundation

// AI CONTEXT — App/AppCompositionRoot.swift
//
// PURPOSE:
// Stage 1 composition factory for the iOS application graph. It is the only
// production location that constructs the concrete feed, download, playback,
// chapter, queue, settings, subscription, and read-only widget projection
// services required by AppState.
// `AppState.bootstrap()` retains process-wide singleton resolution and asks this
// root for a fully constructed graph before invoking AppState's explicit start.
//
// OWNERSHIP:
// This value owns no runtime state, callback, Task, persistence rule, or policy.
// AppState remains the singleton/high-level compatibility façade. Domain
// callbacks, startup sequencing, runtime policy, and mutable state are owned by
// named coordinators/workflows; AppState only connects the typed graph.
// WidgetSnapshotCoordinator is constructed here and retained by AppState solely
// for graph lifetime. Its narrow subscriptions and App Group writes remain its
// own responsibility.
//
// TESTABILITY:
// `Dependencies` and the explicit initializer form the Stage 0 application
// harness seam. Tests can supply protocol-backed fakes without invoking concrete
// production construction. Test roots omit widget publication by default so
// they never require production App Group entitlements. `production()` enables
// it explicitly.
//
// CONCURRENCY / INVARIANTS:
// MainActor-only because AppState and several concrete services are MainActor
// types. Construct the complete graph synchronously, publish the singleton, then
// call `start()` exactly once. Never resolve AppState.shared from this factory,
// and never let a coordinator use this type as a service locator.
@MainActor
struct AppCompositionRoot {
    struct Dependencies {
        let feedService: FeedServicing
        let downloadManager: DownloadManaging
        let playbackEngine: PlaybackControlling
        let chapterService: ChapterServicing
        let queueService: QueueServicing
        let settingsStore: SettingsStoring
        let subscriptionStore: SubscriptionStore
    }

    let dependencies: Dependencies
    private let installWidgetCoordinator: Bool

    init(
        dependencies: Dependencies,
        installWidgetCoordinator: Bool = false
    ) {
        self.dependencies = dependencies
        self.installWidgetCoordinator = installWidgetCoordinator
    }

    init(
        feedService: FeedServicing,
        downloadManager: DownloadManaging,
        playbackEngine: PlaybackControlling,
        chapterService: ChapterServicing,
        queueService: QueueServicing,
        settingsStore: SettingsStoring,
        subscriptionStore: SubscriptionStore,
        installWidgetCoordinator: Bool = false
    ) {
        self.init(
            dependencies: Dependencies(
                feedService: feedService,
                downloadManager: downloadManager,
                playbackEngine: playbackEngine,
                chapterService: chapterService,
                queueService: queueService,
                settingsStore: settingsStore,
                subscriptionStore: subscriptionStore
            ),
            installWidgetCoordinator: installWidgetCoordinator
        )
    }

    static func production() -> AppCompositionRoot {
        let chapterService = ChapterService()
        let queueService = QueueService()
        let playbackEngine = PlaybackEngine(
            chapterService: chapterService,
            queueService: queueService
        )
        return AppCompositionRoot(
            feedService: FeedService(chapterService: chapterService),
            downloadManager: DownloadManager(),
            playbackEngine: playbackEngine,
            chapterService: chapterService,
            queueService: queueService,
            settingsStore: SettingsStore(),
            subscriptionStore: SubscriptionStore(),
            installWidgetCoordinator: true
        )
    }

    func makeAppState() -> AppState {
        let playbackPositionStore = PlaybackPositionStore()
        let historyStatsCoordinator = HistoryStatsCoordinator(
            historyStore: ListeningHistoryStore(),
            statsStore: ListeningStatsStore(),
            subscriptionStore: dependencies.subscriptionStore
        )
        let queueCoordinator = QueueCoordinator(
            subscriptionStore: dependencies.subscriptionStore,
            queueService: dependencies.queueService,
            currentEpisode: { nil },
            showBadge: { dependencies.settingsStore.appSettings.showQueueBadge }
        )
        let onboardingCoordinator = OnboardingCoordinator(
            subscriptionStore: dependencies.subscriptionStore,
            settingsStore: dependencies.settingsStore
        )
        let appState = AppState(
            feedService: dependencies.feedService,
            downloadManager: dependencies.downloadManager,
            playbackEngine: dependencies.playbackEngine,
            chapterService: dependencies.chapterService,
            queueService: dependencies.queueService,
            settingsStore: dependencies.settingsStore,
            subscriptionStore: dependencies.subscriptionStore,
            historyStatsCoordinator: historyStatsCoordinator,
            queueCoordinator: queueCoordinator,
            onboardingCoordinator: onboardingCoordinator,
            routingCoordinator: AppRoutingCoordinator(),
            playbackPositionStore: playbackPositionStore
        )
        if installWidgetCoordinator {
            appState.installWidgetSnapshotCoordinator(
                WidgetSnapshotCoordinator(
                    queueCoordinator: queueCoordinator,
                    playbackCoordinator: appState.playbackCoordinator,
                    subscriptionStore: dependencies.subscriptionStore,
                    playbackPositionStore: playbackPositionStore
                )
            )
        }
        return appState
    }
}
