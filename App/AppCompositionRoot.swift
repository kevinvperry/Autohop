import Foundation

// AI CONTEXT — App/AppCompositionRoot.swift
//
// PURPOSE:
// Stage 1 composition factory for the iOS application graph. It is the only
// production location that constructs the concrete feed, download, playback,
// chapter, queue, settings, and subscription services required by AppState.
// `AppState.bootstrap()` retains process-wide singleton resolution and asks this
// root for a fully constructed graph before invoking AppState's explicit start.
//
// OWNERSHIP:
// This value owns no runtime state, callback, Task, persistence rule, or policy.
// AppState remains the compatibility façade and still installs every existing
// compatibility callback graph. Stages 3–11 moved history/Stats, queue,
// onboarding, routing, download runtime, refresh/Radar state, automatic intents,
// Auto Archive, import, sync/Relay, and playback session ownership into explicit
// coordinators. Stage 12 will transfer lifecycle/bootstrap wiring.
//
// TESTABILITY:
// `Dependencies` and the explicit initializer form the Stage 0 application
// harness seam. Tests can supply protocol-backed fakes without invoking concrete
// production construction. `makeAppState()` never starts long-lived work.
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

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    init(
        feedService: FeedServicing,
        downloadManager: DownloadManaging,
        playbackEngine: PlaybackControlling,
        chapterService: ChapterServicing,
        queueService: QueueServicing,
        settingsStore: SettingsStoring,
        subscriptionStore: SubscriptionStore
    ) {
        self.init(dependencies: Dependencies(
            feedService: feedService,
            downloadManager: downloadManager,
            playbackEngine: playbackEngine,
            chapterService: chapterService,
            queueService: queueService,
            settingsStore: settingsStore,
            subscriptionStore: subscriptionStore
        ))
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
            subscriptionStore: SubscriptionStore()
        )
    }

    func makeAppState() -> AppState {
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
        return AppState(
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
            routingCoordinator: AppRoutingCoordinator()
        )
    }
}
