import Combine
import CloudKit
import Foundation
import Observation
import AutohopCore

// AI CONTEXT — TV/App/TVAppModel.swift
// tvOS-only composition facade being decomposed according to
// Docs/TVAPP_MODEL_DECOMPOSITION_PROPOSAL.md. iPhone runtime code must not
// depend on this type. Focused child models/coordinators own page projections,
// recovery, sync and playback routing as the phased migration progresses.

@MainActor
@Observable
final class TVAppModel {
    enum RootState {
        case loading
        case ready
        case empty
    }

    let bootstrapCoordinator = TVBootstrapCoordinator()
    let libraryModel = TVLibraryModel()
    let queueModel = TVQueueModel()
    let continueListeningModel = TVContinueListeningModel()
    let historyModel = TVHistoryModel()

    var rootState: RootState = .loading {
        didSet {
            switch rootState {
            case .loading: bootstrapCoordinator.state = .loading(message: statusText)
            case .ready: bootstrapCoordinator.state = .ready
            case .empty: bootstrapCoordinator.state = .empty
            }
        }
    }
    var statusText = "Loading your library…" {
        didSet {
            if case .loading = rootState {
                bootstrapCoordinator.state = .loading(message: statusText)
            }
        }
    }
    let syncCoordinator = TVSyncCoordinator()
    var syncStatus: TVSyncStatus {
        get { syncCoordinator.status }
        set { syncCoordinator.status = newValue }
    }
    /// Observation-tracked mirror of the store's real (non-browse) library,
    /// priority order. TV views read THIS, never the store directly.
    // `AutohopCore.Subscription` qualified — Combine also declares a
    // `Subscription` protocol, and both are visible here (this file imports
    // Combine for AnyCancellable/debounce), which is otherwise ambiguous.
    var librarySubscriptions: [AutohopCore.Subscription] {
        get { libraryModel.subscriptions }
        set { libraryModel.subscriptions = newValue }
    }
    var libraryTiles: [TVPodcastTileModel] {
        get { libraryModel.tiles }
        set { libraryModel.tiles = newValue }
    }
    var episodeRowsBySubscription: [UUID: [TVEpisodeRowModel]] {
        get { libraryModel.episodeRowsBySubscription }
        set { libraryModel.episodeRowsBySubscription = newValue }
    }
    var loadingEpisodeSubscriptions: Set<UUID> {
        get { libraryModel.loadingEpisodeSubscriptions }
        set { libraryModel.loadingEpisodeSubscriptions = newValue }
    }
    /// The phone owns the queue snapshot and may not publish its replacement
    /// immediately. Keep an archived row hidden locally in the meantime.
    var locallyArchivedEpisodeKeys: Set<String> {
        get { queueModel.locallyArchivedEpisodeKeys }
        set { queueModel.locallyArchivedEpisodeKeys = newValue }
    }

    let subscriptionStore: SubscriptionStore
    /// Phase 3 (§8): the tvOS playback composition. Its upNextProvider/
    /// subscriptionProvider closures are wired below, AFTER subscriptionStore
    /// exists, avoiding an init-order back-reference to `self`.
    let playbackModel: TVPlaybackModel
    /// TV listening stats (2026-07-11, Kevin's request): TV consumption must
    /// contribute to the iPhone's Stats page. DayStats sync is ADDITIVE per
    /// (deviceID, dayKey) partition and summed on read (SYNC_DESIGN.md 5b), so
    /// all the TV has to do is record its own listening into a
    /// ListeningStatsStore wired to the sync database — the engine pushes the
    /// partitions and the phone folds them in with zero phone-side changes.
    /// Local JSON lives in Caches (same purge posture as the TV database: the
    /// synced CloudKit records are the durable copy). TV has no Stats UI, so
    /// onRemoteStatsChanged stays unwired here.
    let listeningStatsStore: ListeningStatsStore
    let materializationCoordinator: TVMaterializationCoordinator
    let queueEnrichmentCoordinator = TVLegacyQueueEnrichmentCoordinator()
    var survivalKitStore: SurvivalKitStore { materializationCoordinator.survivalKitStore }
    let projectionStore: TVProjectionStore?
    var cloudSyncEngine: CloudSyncEngine? {
        get { syncCoordinator.engine }
        set { syncCoordinator.engine = newValue }
    }
    var cancellables = Set<AnyCancellable>()
    var didBootstrap: Bool {
        get { bootstrapCoordinator.didBootstrap }
        set { bootstrapCoordinator.didBootstrap = newValue }
    }
    var queueEnrichmentTasks: [UUID: Task<Void, Never>] {
        get { queueEnrichmentCoordinator.tasks }
        set { queueEnrichmentCoordinator.tasks = newValue }
    }
    var pendingQueueEnrichmentIDs: [UUID] {
        get { queueEnrichmentCoordinator.pendingSubscriptionIDs }
        set { queueEnrichmentCoordinator.pendingSubscriptionIDs = newValue }
    }
    var failedQueueEnrichmentIDs: Set<UUID> {
        get { queueEnrichmentCoordinator.failedSubscriptionIDs }
        set { queueEnrichmentCoordinator.failedSubscriptionIDs = newValue }
    }
    var queueEnrichmentAttempts: [UUID: Int] {
        get { queueEnrichmentCoordinator.attempts }
        set { queueEnrichmentCoordinator.attempts = newValue }
    }
    /// Durable identity lives in SubscriptionSurvivalKit; these tasks are only
    /// the in-process retry schedulers. A relaunch reconstructs them from the
    /// kit, so a transient RSS/CDN failure cannot permanently erase a show.
    var materializationRetryTasks: [UUID: Task<Void, Never>] {
        get { materializationCoordinator.retryTasks }
        set { materializationCoordinator.retryTasks = newValue }
    }
    var materializationAttempts: [UUID: Int] {
        get { materializationCoordinator.attempts }
        set { materializationCoordinator.attempts = newValue }
    }
    var legacyQueueEpisodes: [String: Episode] {
        get { queueModel.legacyEpisodes }
        set { queueModel.legacyEpisodes = newValue }
    }
    var legacyQueuePodcastTitles: [String: String] {
        get { queueModel.legacyPodcastTitles }
        set { queueModel.legacyPodcastTitles = newValue }
    }
    var episodeFeedLoader: EpisodeFeedLoader { materializationCoordinator.feedLoader }
    var pendingLibraryRefresh: Task<Void, Never>?
    var lastLibraryRefreshAt = Date.distantPast
    var lastLibraryRefreshDuration: TimeInterval = 0
    @ObservationIgnored
    lazy var episodeDetailRepository = TVEpisodeDetailRepository(
        store: subscriptionStore,
        projectionStore: projectionStore,
        feedLoader: episodeFeedLoader
    )
    let durableMaterializationMigrationKey = "com.autohop.tv.durableMaterializationPrime.v1"

    @ObservationIgnored
    lazy var playbackCoordinator: TVPlaybackCoordinator = {
        let coordinator = TVPlaybackCoordinator(
            playbackModel: playbackModel,
            subscriptionStore: subscriptionStore
        )
        coordinator.onArchiveSuppression = { [weak self] key in
            self?.locallyArchivedEpisodeKeys.insert(key)
        }
        coordinator.onHistoryInvalidated = { [weak self] in
            self?.continueListeningModel.invalidate()
            self?.historyModel.invalidate()
        }
        coordinator.onProjectionRefreshRequested = { [weak self] in
            self?.refreshLibrary()
        }
        coordinator.onSyncFlushRequested = { [weak self] reason in
            self?.cloudSyncEngine?.flushAndSendDeferredPushes(reason: reason)
        }
        return coordinator
    }()

    /// TVAppDelegate has no other path to the running model (tvOS has no
    /// AppState.sharedOrBootstrap()-style composition root) — mirrors that
    /// pattern with a weak static instead. Safe: @State in AutohopTVApp keeps
    /// the one TVAppModel alive for the app's lifetime; weak just avoids a
    /// retain cycle through the delegate, which never itself needs to own it.
    static weak var shared: TVAppModel?

    convenience init() {
        self.init(dependencies: .production())
    }

    init(dependencies: TVAppDependencies) {
        // TV DIAGNOSTICS (2026-07-11, round 8): logging is ALWAYS ON for the
        // TV target (AppLogger.isEnabled defaults false and nothing on TV
        // ever set it — every tv.* log line was being silently dropped). The
        // file is capped/rotated at ~5 MB, and DEBUG builds mirror each line
        // to the Xcode console, so an Xcode-launched device run streams the
        // log live. TVHangWatchdog reports main-thread hangs ≥ 350 ms
        // (tv.mainThreadHang / tv.mainThreadHangRecovered); correlate with
        // the tv.perf.* stage timings scattered through this file.
        AppLogger.shared.setEnabled(true)
        #if DEBUG
        AppLogger.shared.setConsoleMirroringEnabled(true)
        #endif
        TVHangWatchdog.shared.start()
        let info = Bundle.main.infoDictionary ?? [:]
        AppLogger.shared.info("tv.lifecycle", "TV app launched", metadata: [
            "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "gitCommit": info["GitCommitSHA"] as? String ?? "unknown",
            "gitWorkingTreeDirty": info["GitWorkingTreeDirty"] as? String ?? "unknown",
            "sourceFingerprint": info["SourceFingerprint"] as? String ?? "unknown",
            "buildTimestampUTC": info["BuildTimestampUTC"] as? String ?? "unknown",
            "container": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "unknown",
            "session": UUID().uuidString
        ], alwaysPersist: true)

        subscriptionStore = dependencies.subscriptionStore
        projectionStore = dependencies.projectionStore
        listeningStatsStore = dependencies.listeningStatsStore
        playbackModel = dependencies.playbackModel
        materializationCoordinator = TVMaterializationCoordinator(
            survivalKitStore: dependencies.survivalKitStore,
            feedLoader: dependencies.episodeFeedLoader
        )

        playbackModel.upNextProvider = { [weak self] in self?.upNextEpisodes ?? [] }
        playbackModel.subscriptionProvider = { [weak self] id in self?.subscription(id: id) }
        // Force-push a just-written position immediately (pause / player exit),
        // so a TV-side pause reaches the phone in seconds instead of waiting out
        // the engine's ~60 s slow-lane debounce.
        playbackModel.onPlaybackCheckpoint = { [weak self] in
            self?.syncCoordinator.flush(reason: "tv.playbackCheckpoint")
        }

        if let cached = try? projectionStore?.loadLibrary(), !cached.isEmpty {
            libraryTiles = cached.map {
                TVPodcastTileModel(id: $0.id, title: $0.title, author: $0.author, artworkURL: $0.artworkURL, feedURL: $0.feedURL, priorityRank: $0.priorityRank, isMaterializing: false)
            }
            rootState = .ready
            syncStatus = .cached(Date(), generation: 0)
        }

        Self.shared = self

    }

}


/// The Home hero's model (2026-07-11 rework — see computeContinueListening):
/// the synced history entry is the authoritative, always-renderable truth;
/// `episode` is the locally-materialized catalog episode when available (nil =
/// render from the entry's denormalized fields, not yet playable).
struct TVContinueListening: Equatable {
    let entry: ListeningHistoryEntry
    let episode: Episode?
}

/// Immutable, bounded History-page projection. The synced entry remains the
/// display authority while `episode` is the optional playable materialisation.
struct TVHistoryItem: Identifiable, Equatable {
    let entry: ListeningHistoryEntry
    let episode: Episode?
    var id: String { entry.id }
}
