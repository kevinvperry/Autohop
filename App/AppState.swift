import AVFoundation
import Combine
import Foundation
import Network
import UIKit

// ============================================================================
// AI CONTEXT — App/AppState.swift
//
// PURPOSE: Central @MainActor coordinator and single source of truth for the
// whole app. Every view observes this object; every service (feeds, downloads,
// playback, queue, stats, history, notifications) is owned and orchestrated here.
//
// RESPONSIBILITIES:
//  - Player state: currentPlayerEpisode / currentPlayerTime / isPlaying;
//    starting playback (startPlayback), auto-advance (handleEpisodeFinished →
//    playNextEpisode), seek, chapter navigation, per-podcast audio settings
//    (speed / vocal boost / trim silence) pushed live into PlaybackEngine.
//  - Queue: downloadedQueue = QueueService priority order + manual overrides.
//    queueOverrideEpisodeIDs = "Play Next" pins (front of queue, in order);
//    queueDemotedEpisodeIDs = "Play Last" pins (end of queue). Pins persist in
//    Application Support/Autohop/queue-pins.json and clear on play/archive.
//  - Downloads: download-first model. maxConcurrentDownloads = 3 with a FIFO
//    pendingDownloadQueue; NWPathMonitor enforces the WiFi/cellular toggles;
//    reconcileOrphanedDownloads() repairs DB-vs-filesystem mismatches at launch.
//  - Feed refresh: refreshSubscription merges new episodes (auto-downloading
//    them), refreshDueSubscriptions implements Release Radar due-date polling,
//    refreshSubscriptionsForBackground serves BGAppRefreshTask (max 8 feeds,
//    waits on an in-flight cycle instead of completing early). Per-feed failure
//    backoff lives in feedFailureBackoffUntil.
//  - Auto archive: runAutoArchiveIfNeeded gates a full pass to every 30 min
//    (autoArchiveInterval) unless forced; runAutoArchive applies the three
//    per-podcast rules (after-played delay, inactive timeout, episode limit).
//    The inactive/limit passes skip a subscription's pre-existing back-catalogue
//    (episodes published on/before Subscription.subscribedAt) so subscribing to a
//    show never archives its whole backlog on day one.
//  - Persistence side: playback positions saved (throttled ~10 s) to
//    playback-position.json keyed by episode GUID/URL so re-fetched episodes
//    resume correctly; listening history + stats recorded on playback ticks.
//  - OPML import/export with progress reporting.
//
// KEY COLLABORATORS: PlaybackEngine (audio), DownloadManager (URLSession),
// FeedService/RSSParser (network), SubscriptionStore (SQLite-backed model
// store), QueueService (pure queue ordering), ListeningHistoryStore &
// ListeningStatsStore (JSON persistence, defined at bottom of this file and
// in Persistence/), NotificationService, SleepTimerService,
// SleepScheduleService (recurring nightly "still listening?" timer).
//
// INVARIANTS / GOTCHAS:
//  - Queue only ever contains DOWNLOADED, unplayed episodes (download-first).
//  - upNextEpisode refreshes are debounced via scheduleUpNextRefresh; mutate
//    suppressUpNextRefresh around bulk operations to avoid churn.
//  - Listening history requires ≥ 60 s listened before an entry is shown.
//  - AppState.shared is set once in init (used by AppDelegate/background tasks).
//  - All methods assume MainActor; long work hops to detached tasks/services.
// ============================================================================

@MainActor
final class AppState: ObservableObject {
    let feedService: FeedServicing
    let downloadManager: DownloadManaging
    var playbackEngine: PlaybackControlling
    let chapterService: ChapterServicing
    let queueService: QueueServicing
    let settingsStore: SettingsStoring
    let subscriptionStore: SubscriptionStore
    let listeningHistoryStore = ListeningHistoryStore()
    let listeningStatsStore = ListeningStatsStore()

    /// Opt-in cross-device sync engine (CloudKit). Started only while
    /// AppSettings.iCloudSyncEnabled is true.
    private let cloudSyncEngine: CloudSyncEngine
    static let cloudKitContainerID = "iCloud.com.kevinperry.autohop"
    let downloadActivityStore = DownloadActivityStore()

    // Player state
    @Published var currentPlayerEpisode: Episode? {
        didSet { scheduleUpNextRefresh(reason: "player.currentChanged") }
    }
    @Published var currentPlayerTime: TimeInterval = 0
    @Published var isPlaying: Bool = false
    @Published private(set) var upNextEpisode: Episode?
    @Published private var queueOverrideEpisodeIDs: [UUID] = []
    @Published private var queueDemotedEpisodeIDs: [UUID] = []

    // Per-episode download progress (0.0 – 1.0)
    @Published var downloadProgress: [UUID: Double] = [:]
    // Cached list of episodes currently on device — updated at state transitions only, not on progress ticks.
    @Published private(set) var downloadedActivities: [DownloadActivity] = []
    // Cached listening history groups — updated only when entries change, not on every playback tick.
    @Published private(set) var listeningHistoryGroups: [(String, [ListeningHistoryEntry])] = []
    @Published private(set) var completedEpisodeCount: Int = 0

    // Sleep timer
    let sleepTimerService = SleepTimerService()

    // Sleep Schedule (recurring nightly sleep timer with "still listening?" prompts)
    let sleepScheduleService = SleepScheduleService()
    // Playback position when the prompt fired — the asleep rewind target.
    private var sleepSchedulePromptAnchorTime: TimeInterval = 0

    // User-facing messages
    @Published var downloadMessage: String?
    @Published var playbackMessage: String?
    @Published private(set) var opmlImportProgress: (current: Int, total: Int)?

    // Download concurrency cap — at most 3 active downloads; extras wait in pendingDownloadQueue.
    private let maxConcurrentDownloads = 3
    private struct PendingDownload {
        let episode: Episode
        let subscriptionID: UUID
        let podcastTitle: String
        let showCompletionMessage: Bool
    }
    private var pendingDownloadQueue: [PendingDownload] = []
    private var activeDownloadCount = 0

    private(set) static var shared: AppState!

    private let logger = AppLogger.shared
    private let resourceMonitor = ResourceMonitor.shared
    private let autoArchiveInterval: TimeInterval = 30 * 60
    private var lastAutoArchiveSkipLogAt: Date?

    // Network path monitor — tracks current interface type for download enforcement.
    private let networkMonitor = NWPathMonitor()
    private var latestNetworkPath: NWPath?

    // Persisted position file
    private static let positionFileURL: URL? = {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/playback-position.json")
    }()

    // Persisted queue pin file
    private static let queuePinsFileURL: URL? = {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/queue-pins.json")
    }()

    private struct SavedQueuePins: Codable {
        var overrideIDs: [UUID]
        var demotedIDs: [UUID]
    }

    private struct SavedPosition: Codable {
        var episodeID: UUID
        var subscriptionID: UUID
        var episodeKey: String?
        var timeSeconds: TimeInterval
        var updatedAt: Date?
    }

    private typealias SavedPositions = [String: SavedPosition]

    // Throttle disk writes: save at most once every 10 s.
    private var positionSaveCounter = 0
    private var hasHandledLaunchPlayback = false
    private var activeRefreshCycle: Task<Bool, Never>?
    private var suppressUpNextRefresh = false
    private var upNextRefreshTask: Task<Void, Never>?
    private var feedFailureBackoffUntil: [UUID: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var historyTrackingEpisodeID: UUID?
    private var historyTrackingLastTime: TimeInterval?

    // MARK: - Computed queue

    var downloadedQueue: [Episode] {
        orderedQueueWithOverrides(
            queueService.downloadedQueue(from: subscriptionStore.subscriptions)
        )
    }

    var nextPlayableEpisode: Episode? {
        downloadedQueue.first
    }

    var currentVideoPlayer: AVPlayer? {
        playbackEngine.videoPlayer
    }

    // MARK: - Computed player helpers

    var currentChapter: Chapter? {
        guard let episode = currentPlayerEpisode else { return nil }
        return chapterService.chapter(atTime: currentPlayerTime, in: episode)
    }

    var currentEpisodeSupportsChapters: Bool {
        guard let episode = episodeForChapters else { return false }
        return !episode.chapters.isEmpty
    }

    var activeChapters: [Chapter] {
        guard let episode = currentPlayerEpisode,
              let sub = subscriptionStore.subscription(id: episode.subscriptionID)
        else { return [] }
        return chapterService.activeChapters(for: episode, filter: sub.chapterFilter)
    }

    var episodeForChapters: Episode? {
        let episode = currentPlayerEpisode ?? nextPlayableEpisode
        return episode?.chapters.isEmpty == false ? episode : nil
    }

    func isQueuePinnedNext(_ episode: Episode) -> Bool {
        queueOverrideEpisodeIDs.contains(episode.id)
    }

    func isQueuePinnedLast(_ episode: Episode) -> Bool {
        queueDemotedEpisodeIDs.contains(episode.id)
    }

    /// Returns the current playback position for an episode: live time if it's playing now,
    /// otherwise the last saved position. Returns 0 if no position has been recorded.
    func effectivePlaybackTime(for episode: Episode) -> TimeInterval {
        if currentPlayerEpisode?.id == episode.id {
            return currentPlayerTime
        }
        return savedPlaybackTime(for: episode)
    }

    private func resolvedUpNextEpisode() -> Episode? {
        let queue = downloadedQueue
        guard let current = currentPlayerEpisode else { return queue.first }
        return queue.first { $0.id != current.id }
    }

    private func orderedQueueWithOverrides(_ baseQueue: [Episode]) -> [Episode] {
        guard !queueOverrideEpisodeIDs.isEmpty || !queueDemotedEpisodeIDs.isEmpty else { return baseQueue }

        let availableIDs = Set(baseQueue.map(\.id))
        let validOverrideIDs = queueOverrideEpisodeIDs.filter { availableIDs.contains($0) }
        let validDemotedIDs = queueDemotedEpisodeIDs.filter { availableIDs.contains($0) }
        guard !validOverrideIDs.isEmpty || !validDemotedIDs.isEmpty else { return baseQueue }

        let specialIDs = Set(validOverrideIDs).union(Set(validDemotedIDs))
        let overrideEpisodes = validOverrideIDs.compactMap { id in baseQueue.first { $0.id == id } }
        let demotedEpisodes = validDemotedIDs.compactMap { id in baseQueue.first { $0.id == id } }

        var ordered = baseQueue.filter { !specialIDs.contains($0.id) }
        ordered.insert(contentsOf: overrideEpisodes, at: 0)
        ordered.append(contentsOf: demotedEpisodes)
        return ordered
    }

    private let defaultFeedEpisodeLimit = 50
    private let feedFailureBackoffInterval: TimeInterval = 30 * 60
    private let backgroundRefreshFeedLimit = 8

    // MARK: - Init

    init(
        feedService: FeedServicing,
        downloadManager: DownloadManaging,
        playbackEngine: PlaybackControlling,
        chapterService: ChapterServicing,
        queueService: QueueServicing,
        settingsStore: SettingsStoring,
        subscriptionStore: SubscriptionStore
    ) {
        self.feedService = feedService
        self.downloadManager = downloadManager
        self.playbackEngine = playbackEngine
        self.chapterService = chapterService
        self.queueService = queueService
        self.settingsStore = settingsStore
        self.subscriptionStore = subscriptionStore
        self.cloudSyncEngine = CloudSyncEngine(
            containerIdentifier: AppState.cloudKitContainerID,
            subscriptionStore: subscriptionStore,
            database: subscriptionStore.database
        )
        cloudSyncEngine.onSubscriptionNeedsMaterialization = { [weak self] state in
            await self?.materializeRemoteSubscription(state)
        }
        listeningHistoryStore.syncDatabase = subscriptionStore.database
        cloudSyncEngine.onRemoteHistoryEntry = { [weak self] entry in
            await MainActor.run { self?.listeningHistoryStore.applyRemote(entry) }
        }
        listeningStatsStore.syncDatabase = subscriptionStore.database
        cloudSyncEngine.onRemoteStatsChanged = { [weak self] in
            await MainActor.run { self?.listeningStatsStore.reloadRemoteStats() }
        }
        // Active-player-wins: tell the store which episode is loaded in the
        // player so a remote played/archived change can't interrupt it.
        subscriptionStore.nowPlayingGuidProvider = { [weak self] in
            self?.playbackEngine.currentEpisode?.guid
        }
        // New/activated subscriptions seed their playback settings from the
        // global default panel; browse feeds resolve it live (effectivePreference).
        subscriptionStore.defaultPlaybackPreferenceProvider = { [weak self] in
            self?.settingsStore.appSettings.defaultPlaybackPreference ?? .default
        }
        // When a remote played/archived state arrives for an episode this device
        // still has downloaded, drop the local media file (ASSESSMENT.md B1). The
        // store clears the download fields itself; this just deletes the file.
        subscriptionStore.onEpisodeFileShouldDelete = { [weak self] episode in
            Task { try? await self?.downloadManager.deleteLocalFile(for: episode) }
        }
        if settingsStore.appSettings.iCloudSyncEnabled {
            cloudSyncEngine.start()
        }

        subscriptionStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.scheduleUpNextRefresh(reason: "state.changed")
                    self.objectWillChange.send()
                    let badgeCount = self.settingsStore.appSettings.showQueueBadge ? self.downloadedQueue.count : 0
                    NotificationService.shared.updateBadge(count: badgeCount)
                }
            }
            .store(in: &cancellables)

        sleepTimerService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sleepScheduleService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if let observableSettingsStore = settingsStore as? SettingsStore {
            observableSettingsStore.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                    self?.syncDiagnosticLogging()
                    // didSet hasn't run yet on objectWillChange — sync after the value lands.
                    Task { @MainActor in
                        guard let self else { return }
                        self.syncSleepScheduleConfig()
                        self.cloudSyncEngine.syncEnabledChanged(self.settingsStore.appSettings.iCloudSyncEnabled)
                    }
                }
                .store(in: &cancellables)
        }

        syncSleepScheduleConfig()

        refreshUpNextEpisode()
        startNetworkMonitor()
        subscriptionStore.cleanupExpiredPreviewSubscriptions(
            subscriptionIDsWithHistory: Set(listeningHistoryStore.entries.map(\.subscriptionID))
        )
    }

    /// Creates a podcast that another device subscribed to, by fetching its feed,
    /// then applies the synced per-podcast settings on top. Invoked by the sync
    /// engine when a remote subscription record has no local match.
    private func materializeRemoteSubscription(_ state: SubscriptionSyncState) async {
        // Already present (by id or feed) — just apply settings.
        if subscriptionStore.subscription(id: state.subscriptionID) != nil
            || subscriptionStore.subscriptions.contains(where: { $0.feedURL == state.feedURL }) {
            subscriptionStore.applyRemoteSubscriptionState(state)
            return
        }

        do {
            let result = try await feedService.refresh(
                feedURL: state.feedURL,
                subscriptionID: state.subscriptionID,
                episodeLimit: defaultFeedEpisodeLimit
            )
            _ = try subscriptionStore.addSubscription(
                id: state.subscriptionID, feedURL: state.feedURL,
                title: result.subscriptionTitle, description: result.description,
                author: result.author, artworkURL: result.artworkURL,
                categories: result.categories, isExplicit: result.isExplicit,
                latestEpisode: result.latestEpisode, insertAtBottom: true
            )
            subscriptionStore.updateEpisodes(subscriptionID: state.subscriptionID, episodes: result.episodes)
            // Apply the synced settings (priority, playback, auto-archive, …) on top.
            subscriptionStore.applyRemoteSubscriptionState(state)
        } catch {
            logger.error("sync.materializeFailed", "Could not materialise synced subscription", metadata: [
                "url": state.feedURL.absoluteString
            ])
        }
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.latestNetworkPath = path }
        }
        networkMonitor.start(queue: DispatchQueue(label: "au.com.autohop.networkmonitor", qos: .utility))
    }

    private func isDownloadAllowed() -> Bool {
        let settings = settingsStore.appSettings
        guard let path = latestNetworkPath, path.status == .satisfied else { return true }
        if path.usesInterfaceType(.wifi) && !settings.downloadOverWifi { return false }
        if path.usesInterfaceType(.cellular) && !settings.downloadOverCellular { return false }
        return true
    }

    static func bootstrap() -> AppState {
        let chapterService = ChapterService()
        let queueService = QueueService()
        let playbackEngine = PlaybackEngine(chapterService: chapterService, queueService: queueService)
        let downloadManager = DownloadManager()
        let state = AppState(
            feedService: FeedService(chapterService: chapterService),
            downloadManager: downloadManager,
            playbackEngine: playbackEngine,
            chapterService: chapterService,
            queueService: queueService,
            settingsStore: SettingsStore(),
            subscriptionStore: SubscriptionStore()
        )

        // Episode completion
        playbackEngine.onEpisodeFinished = { [weak state] episode in
            Task { @MainActor in await state?.handleEpisodeFinished(episode) }
        }

        // Scrubber + Now Playing time sync (fires every 0.5 s)
        playbackEngine.onTimeUpdate = { [weak state] time in
            Task { @MainActor in
                guard let state else { return }
                state.currentPlayerTime = time
                state.sleepTimerService.tick()

                // Manual Sleep Timer overrides the Sleep Schedule for this session.
                if state.sleepTimerService.isActive {
                    state.sleepScheduleService.suspendForSession()
                }
                state.sleepScheduleService.tick(isPlaying: state.isPlaying)

                // Update lock-screen position (cheap — just updates two keys)
                if let ep = state.currentPlayerEpisode,
                   let sub = state.subscriptionStore.subscription(id: ep.subscriptionID) {
                    NowPlayingService.shared.updateTime(
                        currentTime: time,
                        isPlaying: state.isPlaying,
                        speed: state.effectiveSpeed(for: sub)
                    )
                }

                // Persist position every ~10 s (every 20th call at 0.5 s interval)
                state.positionSaveCounter += 1
                state.recordListeningProgress(at: time)
                if state.positionSaveCounter % 20 == 0 {
                    state.savePlaybackPosition()
                }

                // Accumulate playback stats every tick (0.5 s interval).
                // tickTime() fires whenever an episode is loaded, including while
                // paused — only credit listening time when audio is actually playing.
                if state.isPlaying,
                   let ep = state.currentPlayerEpisode,
                   let sub = state.subscriptionStore.subscription(id: ep.subscriptionID) {
                    state.listeningStatsStore.addListeningTime(
                        0.5,
                        speed: state.effectiveSpeed(for: sub),
                        subscriptionID: sub.id,
                        showTitle: sub.title
                    )
                }
            }
        }

        // Interruption (phone call, AirPods disconnect, etc.)
        playbackEngine.onPlaybackInterrupted = { [weak state] in
            Task { @MainActor in
                guard let state else { return }
                state.isPlaying = false
                if let ep = state.currentPlayerEpisode,
                   let sub = state.subscriptionStore.subscription(id: ep.subscriptionID) {
                    NowPlayingService.shared.updateTime(
                        currentTime: state.currentPlayerTime,
                        isPlaying: false,
                        speed: state.effectiveSpeed(for: sub)
                    )
                }
            }
        }
        playbackEngine.onPlaybackResumed = { [weak state] in
            Task { @MainActor in
                guard let state else { return }
                state.isPlaying = true
                if let ep = state.currentPlayerEpisode,
                   let sub = state.subscriptionStore.subscription(id: ep.subscriptionID) {
                    state.playbackEngine.updatePlaybackSpeed(state.effectiveSpeed(for: sub))
                    state.logger.info("player.resumedAfterInterruption", "Playback resumed after interruption", metadata: [
                        "episode": ep.title,
                        "speed": PlaybackPreference.speedLabel(state.effectiveSpeed(for: sub))
                    ])
                    NowPlayingService.shared.updateTime(
                        currentTime: state.currentPlayerTime,
                        isPlaying: true,
                        speed: state.effectiveSpeed(for: sub)
                    )
                }
            }
        }

        // Playback stats
        playbackEngine.onManualSkipForward = { [weak state] seconds in
            Task { @MainActor in
                state?.listeningStatsStore.addManualSkipForward(
                    seconds,
                    subscriptionID: state?.currentPlayerEpisode?.subscriptionID
                )
            }
        }
        playbackEngine.onAutoSkip = { [weak state] seconds in
            Task { @MainActor in
                state?.listeningStatsStore.addAutoSkip(
                    seconds,
                    subscriptionID: state?.currentPlayerEpisode?.subscriptionID
                )
            }
        }
        playbackEngine.onTrimSilenceSaved = { [weak state] seconds in
            Task { @MainActor in
                state?.listeningStatsStore.addTrimSilenceSaved(
                    seconds,
                    subscriptionID: state?.currentPlayerEpisode?.subscriptionID
                )
            }
        }

        // Background download completion (post app-relaunch path)
        downloadManager.onBackgroundDownloadCompleted = { [weak state] episodeID, subscriptionID, localFileURL in
            Task { @MainActor in
                guard let state else { return }
                state.subscriptionStore.markEpisodeDownloaded(
                    subscriptionID: subscriptionID,
                    episodeID: episodeID,
                    localFileURL: localFileURL
                )
                if let fileDuration = await state.localAudioDuration(from: localFileURL) {
                    state.subscriptionStore.updateEpisodeDuration(
                        subscriptionID: subscriptionID,
                        episodeID: episodeID,
                        durationSeconds: fileDuration
                    )
                }
                state.downloadProgress.removeValue(forKey: episodeID)
                if let sub = state.subscriptionStore.subscription(id: subscriptionID),
                   let ep = state.subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID) {
                    state.downloadActivityStore.complete(
                        episode: ep,
                        podcastTitle: sub.title,
                        localFileName: localFileURL.lastPathComponent
                    )
                    state.notifyNewEpisodeIfAllowed(ep, subscription: sub)
                }
                state.refreshDownloadedActivities()
            }
        }

        // Download progress
        downloadManager.onProgressUpdate = { [weak state] episodeID, fraction, writtenBytes, expectedBytes in
            Task { @MainActor in
                guard let state else { return }
                state.downloadProgress[episodeID] = fraction
                state.downloadActivityStore.progress(
                    episodeID: episodeID,
                    fraction: fraction,
                    writtenBytes: writtenBytes,
                    expectedBytes: expectedBytes
                )
            }
        }

        // Watchdog retry: when the downloader cancels a stalled task, wait 30 s then retry.
        // Resume data was saved by the watchdog so the retry picks up where it left off.
        downloadManager.onWatchdogCancelled = { [weak state] episodeID in
            Task { @MainActor in
                guard let state else { return }
                try? await Task.sleep(for: .seconds(30))
                await state.retryWatchdogCancelledDownload(episodeID: episodeID)
            }
        }

        // Sleep timer callbacks
        state.sleepTimerService.onPause = { [weak state] in
            Task { @MainActor in
                guard let state, state.isPlaying else { return }
                state.playbackEngine.pause()
                state.isPlaying = false
                if let ep = state.currentPlayerEpisode,
                   let sub = state.subscriptionStore.subscription(id: ep.subscriptionID) {
                    NowPlayingService.shared.updateTime(
                        currentTime: state.currentPlayerTime,
                        isPlaying: false,
                        speed: state.effectiveSpeed(for: sub)
                    )
                }
                state.logger.info("sleepTimer.fired", "Sleep timer paused playback")
            }
        }
        state.sleepTimerService.onFadeVolume = { [weak state] volume in
            state?.playbackEngine.setVolume(volume)
        }

        // Sleep Schedule callbacks. Playback keeps going through the prompt —
        // the chime plays over it; we only record the rewind anchor here.
        state.sleepScheduleService.onPrompt = { [weak state] in
            Task { @MainActor in
                guard let state else { return }
                state.sleepSchedulePromptAnchorTime = state.currentPlayerTime
                // Lock-screen prompt with a "Still Listening" action button so
                // the user can confirm without unlocking or opening the app.
                NotificationService.shared.postSleepSchedulePrompt()
                state.logger.info("sleepSchedule.prompt", "Sleep Schedule asking if still listening (playback continues)", metadata: [
                    "anchorTime": "\(Int(state.sleepSchedulePromptAnchorTime))"
                ])
            }
        }
        // Clear the lock-screen prompt whenever it tears down (confirmed,
        // timed out, suspended or reset).
        state.sleepScheduleService.onPromptDismissed = {
            NotificationService.shared.clearSleepSchedulePrompt()
        }
        // "Still Listening" tapped on the lock screen → confirm, same as any
        // transport command during the grace period.
        NotificationService.shared.setStillListeningHandler { [weak state] in
            Task { @MainActor in
                guard let state else { return }
                if state.sleepScheduleService.isPrompting {
                    state.sleepScheduleService.userResponded()
                    state.logger.info("sleepSchedule.stillListening", "User confirmed still listening via lock-screen notification")
                }
            }
        }
        state.sleepScheduleService.onAsleep = { [weak state] atEpisodeBoundary in
            Task { @MainActor in
                guard let state, state.isPlaying else { return }
                // Gentle fade over ~2.5 s, then pause and rewind to the point
                // where the chime started — the last position plausibly heard.
                for step in stride(from: 0.9, through: 0.0, by: -0.1) {
                    state.playbackEngine.setVolume(Float(step))
                    try? await Task.sleep(for: .milliseconds(250))
                }
                state.playbackEngine.pause()
                state.isPlaying = false
                state.playbackEngine.setVolume(1.0)

                // At an episode boundary the next episode auto-advanced during
                // the grace period — the anchor is its very start.
                let rewindTarget = atEpisodeBoundary ? 0 : state.sleepSchedulePromptAnchorTime
                state.seek(to: rewindTarget)
                state.savePlaybackPosition()
                state.listeningStatsStore.save()
                if let ep = state.currentPlayerEpisode,
                   let sub = state.subscriptionStore.subscription(id: ep.subscriptionID) {
                    NowPlayingService.shared.updateTime(
                        currentTime: rewindTarget,
                        isPlaying: false,
                        speed: state.effectiveSpeed(for: sub)
                    )
                }
                state.logger.info("sleepSchedule.asleep", "No response to prompt — faded out and rewound to prompt point", metadata: [
                    "atEpisodeBoundary": "\(atEpisodeBoundary)",
                    "rewindTarget": "\(Int(rewindTarget))"
                ])
            }
        }

        // Remote command centre (AirPods, lock screen, CarPlay)
        NowPlayingService.shared.configure(
            onPlayPause:    { Task { @MainActor in await state.togglePlayPause() } },
            onSeek:         { t in Task { @MainActor in state.seek(to: t) } },
            onSkipForward:  { s in Task { @MainActor in state.seek(to: state.currentPlayerTime + s) } },
            onSkipBackward: { s in Task { @MainActor in state.seek(to: max(0, state.currentPlayerTime - s)) } },
            onNextTrack: {
                Task { @MainActor in
                    guard let ep = state.currentPlayerEpisode else { return }
                    await state.handleEpisodeFinished(ep)
                }
            }
        )
        NowPlayingService.shared.updateSkipIntervals(
            forward: state.settingsStore.appSettings.skipForwardSeconds,
            backward: state.settingsStore.appSettings.skipBackSeconds
        )
        NowPlayingService.shared.refreshScrubbingCommand(
            enabled: state.settingsStore.appSettings.lockScreenScrubbingEnabled
        )

        // Notification permission is intentionally NOT requested here. The
        // launch path only sets up the delegate + categories (AppDelegate →
        // NotificationService.configure()); the system prompt is deferred to a
        // user-triggered opt-in (notification toggles, or enabling Sleep
        // Schedule). See NotificationService.requestPermission().
        if !state.settingsStore.appSettings.autoArchiveSettingsMigrated {
            state.subscriptionStore.migrateExistingSubscriptionsToAutoArchiveSettings()
            state.settingsStore.appSettings.autoArchiveSettingsMigrated = true
            state.logger.info("autoArchive.migration", "Existing subscriptions migrated to AutoArchiveSettings defaults")
        }
        if !state.settingsStore.appSettings.vocalBoostLevelMigrated {
            state.subscriptionStore.migrateExistingSubscriptionsToStrongVocalBoost()
            state.settingsStore.appSettings.vocalBoostLevelMigrated = true
            state.logger.info("vocalBoost.migration", "Existing subscriptions moved to Strong Vocal Boost")
        }
        if !state.settingsStore.appSettings.trimSilenceLowDefaultMigrated {
            state.subscriptionStore.migrateExistingSubscriptionsToTrimSilenceLow()
            state.settingsStore.appSettings.trimSilenceLowDefaultMigrated = true
            state.logger.info("trimSilence.migration", "Existing subscriptions set to Low Trim Silence")
        }
        if !state.settingsStore.appSettings.playbackSpeed160Migrated {
            state.subscriptionStore.migrateExistingSubscriptionsToPlaybackSpeed(1.6)
            state.settingsStore.appSettings.playbackSpeed160Migrated = true
            state.logger.info("speed.migration", "Existing subscriptions set to 1.6x playback speed")
        }
        state.syncDiagnosticLogging()
        state.logger.info("app.bootstrap", "App state bootstrapped")
        state.restorePlaybackPosition()
        state.loadQueuePins()
        state.startForegroundPolling()
        state.startResourceMonitoring()
        Task { @MainActor in
            await state.runAutoArchiveIfNeeded(reason: "app.startup")
        }
        Task { @MainActor in
            await state.reconcileOrphanedDownloads()
        }
        AppState.shared = state
        Task { @MainActor in
            let badgeCount = state.settingsStore.appSettings.showQueueBadge ? state.downloadedQueue.count : 0
            NotificationService.shared.updateBadge(count: badgeCount)
        }
        return state
    }

    // MARK: - Playback controls

    func togglePlayPause() async {
        resourceMonitor.logSnapshot(reason: "player.toggle", context: resourceContext())
        logger.info("player.toggle", "Play/pause pressed", metadata: [
            "isPlaying": "\(isPlaying)",
            "episode": currentPlayerEpisode?.title ?? "none"
        ])
        // Any transport command during the "still listening?" grace period is
        // a "yes" — confirm before the toggle proceeds. A pause press both
        // confirms and pauses; the re-armed countdown freezes until resume.
        if sleepScheduleService.isPrompting {
            sleepScheduleService.userResponded()
            logger.info("sleepSchedule.stillListening", "User confirmed still listening via play/pause")
        }
        if isPlaying {
            playbackEngine.pause()
            isPlaying = false
            listeningStatsStore.save()
            if let ep = currentPlayerEpisode,
               let sub = subscriptionStore.subscription(id: ep.subscriptionID) {
                NowPlayingService.shared.updateTime(
                    currentTime: currentPlayerTime, isPlaying: false,
                    speed: effectiveSpeed(for: sub)
                )
            }
        } else if let ep = currentPlayerEpisode {
            if playbackEngine.currentEpisode?.id == ep.id {
                playbackEngine.setVolume(1.0)
                playbackEngine.resume()
                isPlaying = true
                if sleepTimerService.checkAutoRestart() {
                    logger.info("sleepTimer.autoRestart", "Sleep timer auto-restarted on manual resume")
                }
                sleepScheduleService.playbackResumed()
            } else if ep.downloadState == .downloaded, ep.localFileURL != nil {
                _ = await startPlayback(episode: ep, resumeFrom: currentPlayerTime)
                return
            } else {
                currentPlayerEpisode = nil
                currentPlayerTime = 0
                await playNextEpisode()
                return
            }

            if let sub = subscriptionStore.subscription(id: ep.subscriptionID) {
                NowPlayingService.shared.updateTime(
                    currentTime: currentPlayerTime, isPlaying: true,
                    speed: effectiveSpeed(for: sub)
                )
            }
        } else {
            await playNextEpisode()
        }
    }

    func startPlaybackOnLaunchIfNeeded() async {
        guard !hasHandledLaunchPlayback else { return }
        hasHandledLaunchPlayback = true

        // If restorePlaybackPosition already loaded an episode, leave it paused.
        if currentPlayerEpisode != nil {
            logger.info("player.launch", "Restored episode loaded in paused state", metadata: [
                "episode": currentPlayerEpisode?.title ?? "none"
            ])
            return
        }

        // Load the first queued episode into the player in a paused state.
        guard let episode = nextPlayableEpisode else {
            logger.info("player.launch", "No episode available on launch")
            return
        }
        currentPlayerEpisode = episode
        currentPlayerTime = 0
        logger.info("player.launch", "Loaded episode in paused state on launch", metadata: [
            "episode": episode.title
        ])
    }

    func seek(to seconds: TimeInterval) {
        // Skip forward/back or scrubbing during the "still listening?" grace
        // period counts as a "yes".
        if sleepScheduleService.isPrompting {
            sleepScheduleService.userResponded()
            logger.info("sleepSchedule.stillListening", "User confirmed still listening via seek/skip")
        }
        let duration = currentPlayerEpisode?.durationSeconds
        let target = clampedPlaybackTime(seconds, duration: duration)
        logger.info("player.seek", "Seeking episode", metadata: [
            "episode": currentPlayerEpisode?.title ?? "none",
            "target": "\(Int(target))",
            "requested": "\(Int(seconds))"
        ])
        playbackEngine.seek(to: target)
        currentPlayerTime = target
        if let episode = currentPlayerEpisode,
           let subscription = subscriptionStore.subscription(id: episode.subscriptionID) {
            NowPlayingService.shared.updateTime(
                currentTime: target,
                isPlaying: isPlaying,
                speed: effectiveSpeed(for: subscription)
            )
        }
    }

    func navigateToPreviousChapter() {
        guard let episode = currentPlayerEpisode,
              let sub = subscriptionStore.subscription(id: episode.subscriptionID),
              let current = currentChapter
        else { return }
        let active = chapterService.activeChapters(for: episode, filter: sub.chapterFilter)
        guard let pos = active.firstIndex(where: { $0.position == current.position }), pos > 0 else { return }
        seek(to: active[pos - 1].startSeconds)
    }

    func navigateToNextChapter() {
        guard let episode = currentPlayerEpisode,
              let sub = subscriptionStore.subscription(id: episode.subscriptionID),
              let current = currentChapter
        else { return }
        let active = chapterService.activeChapters(for: episode, filter: sub.chapterFilter)
        guard let pos = active.firstIndex(where: { $0.position == current.position }),
              pos < active.count - 1 else { return }
        seek(to: active[pos + 1].startSeconds)
    }

    // MARK: - Download

    func downloadLatestEpisode(for subscription: Subscription) async {
        guard let episode = subscription.latestEpisode else {
            downloadMessage = "No latest episode available for \(subscription.title)."
            logger.warning("download.latest", "No latest episode available", metadata: [
                "podcast": subscription.title
            ])
            return
        }

        await downloadEpisode(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true
        )
    }

    func downloadEpisodeForQueue(_ episode: Episode) async {
        guard let subscription = subscriptionStore.subscription(id: episode.subscriptionID) else { return }
        await downloadEpisode(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true
        )
    }

    func deleteDownloadedEpisode(_ episode: Episode) async {
        logger.info("episode.deleteDownload", "Deleting downloaded episode", metadata: [
            "episode": episode.title
        ])
        if currentPlayerEpisode?.id == episode.id {
            playbackEngine.stop()
            currentPlayerEpisode = nil
            currentPlayerTime = 0
            isPlaying = false
            clearPlaybackPosition(for: episode)
            NowPlayingService.shared.clear()
        }

        do {
            try await downloadManager.deleteLocalFile(for: episode)
            subscriptionStore.markEpisodeNotDownloaded(subscriptionID: episode.subscriptionID, episodeID: episode.id)
        } catch {
            logger.warning("episode.deleteDownload", "Could not delete local file", metadata: [
                "episode": episode.title,
                "error": String(describing: error)
            ])
        }

        subscriptionStore.markEpisodeNotDownloaded(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        downloadMessage = "Removed \(episode.title) from the queue."
    }

    func pauseDownload(_ activity: DownloadActivity) {
        logger.info("download.pauseRequested", "Download pause requested", metadata: [
            "episode": activity.episodeTitle,
            "episodeID": activity.episodeID.uuidString
        ])
        downloadManager.pauseDownload(episodeID: activity.episodeID)
        downloadActivityStore.pause(episodeID: activity.episodeID)
        downloadMessage = "Paused \(activity.episodeTitle)."
    }

    func resumeDownload(_ activity: DownloadActivity) async {
        guard let episode = subscriptionStore.episode(
            subscriptionID: activity.subscriptionID,
            episodeID: activity.episodeID
        ), let subscription = subscriptionStore.subscription(id: activity.subscriptionID) else {
            logger.warning("download.resume", "Could not find episode to resume", metadata: [
                "episode": activity.episodeTitle,
                "episodeID": activity.episodeID.uuidString
            ])
            return
        }

        // Step 1: attempt resume (uses stored resume data if available, otherwise fresh start)
        logger.info("download.resumeAttempt", "Attempting download resume", metadata: [
            "episode": episode.title
        ])
        await downloadEpisode(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true
        )

        // Step 2: if the attempt ended in failure, clean up and restart from scratch
        let updatedEpisode = subscriptionStore.episode(
            subscriptionID: activity.subscriptionID,
            episodeID: activity.episodeID
        )
        guard updatedEpisode?.downloadState == .failed else { return }

        logger.warning("download.resumeFallback", "Resume failed — restarting download from scratch", metadata: [
            "episode": episode.title
        ])
        downloadMessage = "Restarting download from the beginning."

        downloadManager.cancelDownload(episodeID: episode.id)
        downloadManager.clearResumeData(episodeID: episode.id)
        try? await downloadManager.deleteLocalFile(for: episode)
        subscriptionStore.markEpisodeNotDownloaded(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )
        downloadActivityStore.remove(episodeID: episode.id)

        await downloadEpisode(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: true
        )
    }

    /// Called automatically after the download watchdog pauses a stalled task.
    /// Looks up the episode and retries the download; resume data is already stored so
    /// the transfer continues from where it left off rather than restarting from zero.
    func retryWatchdogCancelledDownload(episodeID: UUID) async {
        guard let activity = downloadActivityStore.activeActivities.first(where: { $0.episodeID == episodeID }),
              let episode = subscriptionStore.episode(subscriptionID: activity.subscriptionID, episodeID: episodeID),
              let subscription = subscriptionStore.subscription(id: activity.subscriptionID)
        else {
            logger.info("download.watchdogRetrySkipped", "Watchdog retry skipped — episode no longer active", metadata: [
                "episodeID": episodeID.uuidString
            ])
            return
        }
        logger.info("download.watchdogRetry", "Retrying watchdog-paused download", metadata: [
            "episode": episode.title,
            "podcast": subscription.title
        ])
        await downloadEpisode(
            episode,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: false
        )
    }

    func cancelDownload(_ activity: DownloadActivity) {
        logger.info("download.cancelRequested", "Download cancel requested", metadata: [
            "episode": activity.episodeTitle,
            "episodeID": activity.episodeID.uuidString
        ])
        downloadManager.cancelDownload(episodeID: activity.episodeID)
        downloadProgress.removeValue(forKey: activity.episodeID)
        if let episode = subscriptionStore.episode(subscriptionID: activity.subscriptionID, episodeID: activity.episodeID),
           let subscription = subscriptionStore.subscription(id: activity.subscriptionID) {
            downloadActivityStore.fail(episode: episode, podcastTitle: subscription.title, error: "Cancelled")
            subscriptionStore.markEpisodeDownloadFailed(subscriptionID: activity.subscriptionID, episodeID: activity.episodeID)
        }
        downloadMessage = "Cancelled \(activity.episodeTitle)."
    }

    /// Archives an episode from the Downloads page. Works for all statuses (downloading, paused,
    /// failed, completed): cancels any active URLSession task first, deletes any partial or full
    /// local file, then marks the episode as Archived — exactly as Archive does elsewhere in the app.
    func archiveDownload(_ activity: DownloadActivity) async {
        logger.info("download.archiveRequested", "Archive requested from Downloads page", metadata: [
            "episode": activity.episodeTitle,
            "episodeID": activity.episodeID.uuidString,
            "status": activity.status.rawValue
        ])
        // Cancel any live URLSession task and clear stale map entries.
        downloadManager.cancelDownload(episodeID: activity.episodeID)
        downloadProgress.removeValue(forKey: activity.episodeID)
        downloadActivityStore.remove(episodeID: activity.episodeID)

        if let episode = subscriptionStore.episode(subscriptionID: activity.subscriptionID, episodeID: activity.episodeID) {
            await archiveEpisode(episode)
        } else {
            // Episode not found in store — nothing further to archive; task cancellation above is sufficient.
            logger.warning("download.archiveRequested", "Episode not found in store — only URLSession task cancelled", metadata: [
                "episodeID": activity.episodeID.uuidString
            ])
            downloadMessage = "Archived \(activity.episodeTitle)."
        }
    }

    /// Clears `.downloading` state for any episode whose download task did not survive the last
    /// app run. Called once at startup after the URLSession task maps have been rebuilt.
    func reconcileOrphanedDownloads() async {
        let activeIDs = await downloadManager.activeDownloadEpisodeIDs()
        var orphanCount = 0

        // Reconcile subscriptionStore episodes.
        for subscription in subscriptionStore.subscriptions {
            for episode in subscription.episodes where episode.downloadState == .downloading {
                guard !activeIDs.contains(episode.id) else { continue }
                subscriptionStore.markEpisodeDownloadFailed(
                    subscriptionID: subscription.id,
                    episodeID: episode.id
                )
                downloadProgress.removeValue(forKey: episode.id)
                orphanCount += 1
                logger.warning("download.orphanRecovered", "Cleared orphaned downloading state on startup", metadata: [
                    "episode": episode.title,
                    "episodeID": episode.id.uuidString
                ])
            }
        }

        // Also reconcile downloadActivityStore — a persisted `.downloading` activity with no
        // live URLSession task blocks all future download attempts via the app-level duplicate
        // check. This is the primary cause of permanently-stuck downloads (zombie entries).
        for activity in downloadActivityStore.activeActivities where activity.status == .downloading {
            guard !activeIDs.contains(activity.episodeID) else { continue }
            if let episode = subscriptionStore.episode(
                subscriptionID: activity.subscriptionID,
                episodeID: activity.episodeID
            ),
               let subscription = subscriptionStore.subscription(id: activity.subscriptionID) {
                downloadActivityStore.fail(episode: episode, podcastTitle: subscription.title, error: "Interrupted")
            } else {
                downloadActivityStore.remove(episodeID: activity.episodeID)
            }
            orphanCount += 1
            logger.warning("download.orphanRecovered", "Cleared orphaned activity store entry on startup", metadata: [
                "episode": activity.episodeTitle,
                "episodeID": activity.episodeID.uuidString
            ])
        }

        if orphanCount > 0 {
            logger.info("download.reconcile", "Startup download reconciliation complete", metadata: [
                "orphanCount": "\(orphanCount)"
            ])
        }
        refreshDownloadedActivities()
        refreshListeningHistory()
    }

    func markEpisodePlayed(_ episode: Episode) async {
        logger.info("episode.markPlayed", "Marking episode as played", metadata: [
            "episode": episode.title
        ])
        if currentPlayerEpisode?.id == episode.id {
            playbackEngine.stop()
            currentPlayerEpisode = nil
            currentPlayerTime = 0
            isPlaying = false
            NowPlayingService.shared.clear()
        }

        let savedPos = savedPlaybackTime(for: episode)
        clearPlaybackPosition(for: episode)
        markListeningHistory(
            episode,
            status: .played,
            completionKind: .markedPlayed,
            positionSeconds: savedPos > 0 ? savedPos : nil
        )

        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning("episode.markPlayed", "Could not delete local file", metadata: [
                "episode": episode.title,
                "error": String(describing: error)
            ])
        }

        subscriptionStore.markEpisodePlayed(subscriptionID: episode.subscriptionID, episodeID: episode.id)
        downloadProgress.removeValue(forKey: episode.id)
        downloadMessage = "Marked \(episode.title) as played."
    }

    func archiveEpisode(_ episode: Episode, completionKind: CompletionKind = .manuallyArchived) async {
        logger.info("episode.archive", "Archiving episode", metadata: [
            "episode": episode.title
        ])
        if currentPlayerEpisode?.id == episode.id {
            playbackEngine.stop()
            currentPlayerEpisode = nil
            currentPlayerTime = 0
            isPlaying = false
            NowPlayingService.shared.clear()
        }

        let archivedPos = savedPlaybackTime(for: episode)
        clearPlaybackPosition(for: episode)
        markListeningHistory(
            episode,
            status: .archived,
            completionKind: completionKind,
            positionSeconds: archivedPos > 0 ? archivedPos : nil
        )

        downloadManager.cancelDownload(episodeID: episode.id)
        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning("episode.archive", "Could not delete local file", metadata: [
                "episode": episode.title,
                "error": String(describing: error)
            ])
        }

        subscriptionStore.markEpisodeArchived(subscriptionID: episode.subscriptionID, episodeID: episode.id)
        queueOverrideEpisodeIDs.removeAll { $0 == episode.id }
        queueDemotedEpisodeIDs.removeAll { $0 == episode.id }
        saveQueuePins()
        downloadProgress.removeValue(forKey: episode.id)
        downloadMessage = "Archived \(episode.title)."
        refreshDownloadedActivities()
    }

    func archiveEpisodeAndPlayNext(_ episode: Episode) async {
        let wasCurrentEpisode = currentPlayerEpisode?.id == episode.id
        logger.info("episode.archiveAndPlayNext", "Archiving and advancing queue", metadata: [
            "episode": episode.title,
            "wasCurrent": "\(wasCurrentEpisode)"
        ])

        await archiveEpisode(episode)

        if wasCurrentEpisode {
            await playNextEpisode(excluding: [episode.id])
        }
    }

    func unarchiveEpisode(_ episode: Episode) {
        subscriptionStore.markEpisodeUnarchived(subscriptionID: episode.subscriptionID, episodeID: episode.id)
        logger.info("episode.unarchive", "Unarchived episode", metadata: ["episode": episode.title])
    }

    private func downloadEpisode(
        _ episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String,
        showCompletionMessage: Bool
    ) async {
        resourceMonitor.logSnapshot(reason: "download.before", context: resourceContext([
            "episode": episode.title,
            "podcast": podcastTitle
        ]))
        guard isDownloadAllowed() else {
            logger.info("download.blocked", "Download blocked by network settings", metadata: [
                "episode": episode.title,
                "podcast": podcastTitle
            ])
            downloadMessage = "Downloads are disabled on the current network."
            return
        }

        if let activeActivity = downloadActivityStore.activeActivities.first(where: {
            $0.episodeID == episode.id || $0.mediaURL == episode.audioURL
        }), activeActivity.status == .downloading {
            logger.warning("download.duplicateBlocked", "Duplicate download request blocked by app state", metadata: [
                "episode": episode.title,
                "podcast": podcastTitle,
                "episodeID": episode.id.uuidString,
                "mediaURL": episode.audioURL.absoluteString
            ])
            downloadMessage = "\(episode.title) is already downloading."
            return
        }

        // Enforce concurrency cap — queue excess requests and drain after each slot frees up.
        if activeDownloadCount >= maxConcurrentDownloads {
            let alreadyQueued = pendingDownloadQueue.contains { $0.episode.id == episode.id }
            guard !alreadyQueued else { return }
            logger.info("download.queued", "Download deferred — concurrency cap reached", metadata: [
                "episode": episode.title,
                "podcast": podcastTitle,
                "activeCount": "\(activeDownloadCount)",
                "queueDepth": "\(pendingDownloadQueue.count + 1)"
            ])
            pendingDownloadQueue.append(PendingDownload(
                episode: episode,
                subscriptionID: subscriptionID,
                podcastTitle: podcastTitle,
                showCompletionMessage: showCompletionMessage
            ))
            return
        }
        activeDownloadCount += 1
        defer {
            activeDownloadCount -= 1
            drainDownloadQueue()
        }

        if let reusableEpisode = reusableDownloadedEpisode(for: episode) {
            logger.info("download.reuse", "Using existing downloaded file", metadata: [
                "episode": reusableEpisode.title,
                "podcast": podcastTitle
            ])
            if let localFileURL = reusableEpisode.localFileURL,
               let fileDuration = await localAudioDuration(from: localFileURL) {
                subscriptionStore.updateEpisodeDuration(
                    subscriptionID: subscriptionID,
                    episodeID: reusableEpisode.id,
                    durationSeconds: fileDuration
                )
            }
            downloadProgress.removeValue(forKey: reusableEpisode.id)
            if showCompletionMessage {
                downloadMessage = "\(reusableEpisode.title) is already downloaded."
            }
            resourceMonitor.logSnapshot(reason: "download.reuse", context: resourceContext([
                "episode": reusableEpisode.title,
                "podcast": podcastTitle
            ]))
            return
        }

        logger.info("download.start", "Starting episode download", metadata: [
            "episode": episode.title,
            "podcast": podcastTitle,
            "url": episode.audioURL.absoluteString,
            "mediaKind": episode.mediaKind.rawValue,
            "fileSizeBytes": episode.fileSizeBytes.map(String.init) ?? "unknown"
        ])
        downloadActivityStore.start(
            episode: episode,
            podcastTitle: podcastTitle,
            expectedBytes: episode.fileSizeBytes
        )
        subscriptionStore.markEpisodeDownloading(subscriptionID: subscriptionID, episodeID: episode.id)

        do {
            let localFileURL = try await downloadManager.download(episode, allowsCellular: settingsStore.appSettings.downloadOverCellular)
            let fileDuration = await localAudioDuration(from: localFileURL)
            subscriptionStore.markEpisodeDownloaded(
                subscriptionID: subscriptionID,
                episodeID: episode.id,
                localFileURL: localFileURL
            )
            if let fileDuration {
                subscriptionStore.updateEpisodeDuration(
                    subscriptionID: subscriptionID,
                    episodeID: episode.id,
                    durationSeconds: fileDuration
                )
            }
            downloadProgress.removeValue(forKey: episode.id)
            if showCompletionMessage {
                downloadMessage = "Downloaded \(episode.title)."
            }
            logger.info("download.complete", "Episode downloaded", metadata: [
                "episode": episode.title,
                "path": localFileURL.lastPathComponent,
                "duration": fileDuration.map { "\(Int($0))" } ?? "unknown",
                "mediaKind": episode.mediaKind.rawValue,
                "fileSizeBytes": episode.fileSizeBytes.map(String.init) ?? "unknown"
            ])
            downloadActivityStore.complete(
                episode: episode,
                podcastTitle: podcastTitle,
                localFileName: localFileURL.lastPathComponent
            )
            if let sub = subscriptionStore.subscription(id: subscriptionID) {
                notifyNewEpisodeIfAllowed(episode, subscription: sub)
            }
            refreshDownloadedActivities()
            resourceMonitor.logSnapshot(reason: "download.afterSuccess", context: resourceContext([
                "episode": episode.title,
                "podcast": podcastTitle
            ]))
        } catch {
            if let downloadError = error as? DownloadError, downloadError == .paused {
                downloadActivityStore.pause(episodeID: episode.id)
                downloadMessage = "Paused \(episode.title)."
                logger.info("download.paused", "Episode download paused", metadata: [
                    "episode": episode.title,
                    "podcast": podcastTitle,
                    "mediaKind": episode.mediaKind.rawValue
                ])
                return
            }
            if let downloadError = error as? DownloadError, downloadError == .cancelled {
                subscriptionStore.markEpisodeDownloadFailed(subscriptionID: subscriptionID, episodeID: episode.id)
                downloadProgress.removeValue(forKey: episode.id)
                downloadActivityStore.fail(
                    episode: episode,
                    podcastTitle: podcastTitle,
                    error: "Cancelled"
                )
                downloadMessage = "Cancelled \(episode.title)."
                logger.info("download.cancelled", "Episode download cancelled", metadata: [
                    "episode": episode.title,
                    "podcast": podcastTitle,
                    "mediaKind": episode.mediaKind.rawValue
                ])
                return
            }
            if let downloadError = error as? DownloadError, downloadError == .duplicateDownload {
                logger.warning("download.duplicateBlocked", "Duplicate download request rejected by downloader", metadata: [
                    "episode": episode.title,
                    "podcast": podcastTitle
                ])
                downloadMessage = "\(episode.title) is already downloading."
                return
            }
            subscriptionStore.markEpisodeDownloadFailed(subscriptionID: subscriptionID, episodeID: episode.id)
            downloadProgress.removeValue(forKey: episode.id)
            downloadMessage = "Download failed for \(episode.title)."
            downloadActivityStore.fail(
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
            resourceMonitor.logSnapshot(reason: "download.afterFailure", context: resourceContext([
                "episode": episode.title,
                "podcast": podcastTitle
            ]), force: true)
        }
    }

    func refreshDownloadedActivities() {
        let completedByEpisodeID = downloadActivityStore.completedActivities.reduce(
            into: [UUID: DownloadActivity]()
        ) { result, activity in
            if result[activity.episodeID] == nil { result[activity.episodeID] = activity }
        }
        downloadedActivities = subscriptionStore.subscriptions.flatMap { subscription in
            subscription.episodes.compactMap { episode -> DownloadActivity? in
                guard episode.downloadState == .downloaded, episode.localFileURL != nil else { return nil }
                if let existing = completedByEpisodeID[episode.id] { return existing }
                return DownloadActivity(
                    id: episode.id,
                    episodeID: episode.id,
                    subscriptionID: subscription.id,
                    episodeTitle: episode.title,
                    podcastTitle: subscription.title,
                    mediaURL: episode.audioURL,
                    artworkURL: subscription.artworkURL ?? episode.artworkURL,
                    mediaKind: episode.mediaKind,
                    expectedBytes: episode.fileSizeBytes,
                    writtenBytes: episode.fileSizeBytes ?? 0,
                    progress: 1,
                    status: .completed,
                    startedAt: episode.publishedAt ?? .distantPast,
                    updatedAt: episode.publishedAt ?? .distantPast,
                    completedAt: episode.publishedAt,
                    localFileName: episode.localFileName ?? episode.localFileURL?.lastPathComponent
                )
            }
        }
        .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    func refreshListeningHistory() {
        let calendar = Calendar.current
        let commenced = listeningHistoryStore.entries.filter { $0.listenedSeconds >= 60 || $0.lastPositionSeconds >= 60 }
        let grouped = Dictionary(grouping: commenced) { entry -> String in
            if calendar.isDateInToday(entry.lastListenedAt) { return "Today" }
            if calendar.isDateInYesterday(entry.lastListenedAt) { return "Yesterday" }
            return entry.lastListenedAt.formatted(date: .abbreviated, time: .omitted)
        }
        listeningHistoryGroups = grouped
            .map { ($0.key, $0.value.sorted { $0.lastListenedAt > $1.lastListenedAt }) }
            .sorted { lhs, rhs in
                (lhs.1.first?.lastListenedAt ?? .distantPast) > (rhs.1.first?.lastListenedAt ?? .distantPast)
            }
        completedEpisodeCount = commenced.filter { $0.status == .played || $0.status == .archived }.count
    }

    private func drainDownloadQueue() {
        guard !pendingDownloadQueue.isEmpty,
              activeDownloadCount < maxConcurrentDownloads else { return }
        let next = pendingDownloadQueue.removeFirst()
        logger.info("download.dequeued", "Starting deferred download", metadata: [
            "episode": next.episode.title,
            "podcast": next.podcastTitle,
            "remainingInQueue": "\(pendingDownloadQueue.count)"
        ])
        Task { @MainActor [weak self] in
            await self?.downloadEpisode(
                next.episode,
                subscriptionID: next.subscriptionID,
                podcastTitle: next.podcastTitle,
                showCompletionMessage: next.showCompletionMessage
            )
        }
    }

    // MARK: - Playback

    func playNextEpisode(excluding excludedEpisodeIDs: Set<UUID> = []) async {
        savePlaybackPosition()
        resourceMonitor.logSnapshot(reason: "queue.playNext", context: resourceContext())
        logger.info("queue.playNext", "Looking for next playable episode", metadata: [
            "queueCount": "\(downloadedQueue.count)",
            "excludedCount": "\(excludedEpisodeIDs.count)"
        ])

        // Prefer the restored episode (e.g. app relaunched mid-episode).
        if let restored = currentPlayerEpisode,
           restored.downloadState == .downloaded,
           restored.localFileURL != nil || restored.localFileName != nil,
           !excludedEpisodeIDs.contains(restored.id),
           await startPlayback(episode: restored, resumeFrom: currentPlayerTime) {
            return
        }

        for episode in downloadedQueue where !excludedEpisodeIDs.contains(episode.id) {
            if await startPlayback(episode: episode, resumeFrom: savedPlaybackTime(for: episode)) {
                return
            }
        }

        currentPlayerEpisode = nil
        currentPlayerTime = 0
        isPlaying = false
        NowPlayingService.shared.clear()
        playbackMessage = "No downloaded podcast episodes are ready."
        logger.warning("queue.empty", "No downloaded podcast episodes are ready")
    }

    /// Play a specific episode immediately, regardless of queue order.
    func playEpisode(_ episode: Episode) async {
        savePlaybackPosition()
        queueOverrideEpisodeIDs.removeAll { $0 == episode.id }
        queueDemotedEpisodeIDs.removeAll { $0 == episode.id }
        saveQueuePins()
        let resumeTime = savedPlaybackTime(for: episode)
        resourceMonitor.logSnapshot(reason: "player.playEpisode", context: resourceContext([
            "episode": episode.title
        ]))
        logger.info("player.playEpisode", "Playing selected episode", metadata: [
            "episode": episode.title,
            "resume": "\(Int(resumeTime))"
        ])
        _ = await startPlayback(episode: episode, resumeFrom: resumeTime)
    }

    func playEpisodeNext(_ episode: Episode) {
        guard currentPlayerEpisode?.id != episode.id else { return }
        queueDemotedEpisodeIDs.removeAll { $0 == episode.id }
        queueOverrideEpisodeIDs.removeAll { $0 == episode.id }
        queueOverrideEpisodeIDs.insert(episode.id, at: 0)
        saveQueuePins()
        refreshUpNextEpisode(reason: "queue.playNextOverride")
        logger.info("queue.playNextOverride", "Episode moved to play next", metadata: [
            "episode": episode.title,
            "current": currentPlayerEpisode?.title ?? "none"
        ])
    }

    func unpinEpisode(_ episode: Episode) {
        let wasOverride = queueOverrideEpisodeIDs.contains(episode.id)
        let wasDemoted = queueDemotedEpisodeIDs.contains(episode.id)
        guard wasOverride || wasDemoted else { return }
        queueOverrideEpisodeIDs.removeAll { $0 == episode.id }
        queueDemotedEpisodeIDs.removeAll { $0 == episode.id }
        saveQueuePins()
        refreshUpNextEpisode(reason: "queue.unpin")
        logger.info("queue.unpin", "Episode unpinned", metadata: [
            "episode": episode.title,
            "wasOverride": "\(wasOverride)"
        ])
    }

    func playEpisodeLast(_ episode: Episode) {
        guard currentPlayerEpisode?.id != episode.id else { return }
        queueOverrideEpisodeIDs.removeAll { $0 == episode.id }
        queueDemotedEpisodeIDs.removeAll { $0 == episode.id }
        queueDemotedEpisodeIDs.append(episode.id)
        saveQueuePins()
        refreshUpNextEpisode(reason: "queue.playLastDemotion")
        logger.info("queue.playLastDemotion", "Episode moved to play last", metadata: [
            "episode": episode.title,
            "current": currentPlayerEpisode?.title ?? "none"
        ])
    }

    func skipToEpisode(_ episode: Episode) async {
        savePlaybackPosition()
        logger.info("queue.skipToEpisode", "Skipping to episode", metadata: [
            "episode": episode.title
        ])
        playbackEngine.stop()
        isPlaying = false
        currentPlayerTime = 0
        let resumeTime = savedPlaybackTime(for: episode)
        _ = await startPlayback(episode: episode, resumeFrom: resumeTime)
    }

    func updatePlaybackSpeed(for subscriptionID: UUID, speed: Double) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        logger.info("player.speed", "Playback speed changed", metadata: [
            "podcast": subscription.title,
            "speed": PlaybackPreference.speedLabel(speed)
        ])
        var preference = subscription.playbackPreference
        preference.speed = speed
        subscriptionStore.updatePlaybackPreference(subscriptionID: subscriptionID, preference: preference)

        if currentPlayerEpisode?.subscriptionID == subscriptionID, !sharedListeningActive {
            playbackEngine.updatePlaybackSpeed(speed)
            NowPlayingService.shared.updateTime(
                currentTime: currentPlayerTime,
                isPlaying: isPlaying,
                speed: speed
            )
        }
    }

    func updateVocalBoost(for subscriptionID: UUID, level: VocalBoostLevel) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        logger.info("player.vocalBoost", "Vocal Boost changed", metadata: [
            "podcast": subscription.title,
            "level": level.title,
            "targetLUFS": level == .strong ? "-14" : "none"
        ])
        var preference = subscription.playbackPreference
        preference.vocalBoostLevel = level
        subscriptionStore.updatePlaybackPreference(subscriptionID: subscriptionID, preference: preference)

        if currentPlayerEpisode?.subscriptionID == subscriptionID {
            playbackEngine.updateVocalBoost(level)
        }
    }

    func updateLockScreenScrubbing(enabled: Bool) {
        settingsStore.appSettings.lockScreenScrubbingEnabled = enabled
        NowPlayingService.shared.refreshScrubbingCommand(enabled: enabled)
    }

    func updateTrimSilence(for subscriptionID: UUID, amount: TrimSilenceAmount) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        logger.info("player.trimSilence", "Trim Silence changed", metadata: [
            "podcast": subscription.title,
            "amount": amount.title
        ])
        var preference = subscription.playbackPreference
        preference.trimSilence = amount
        subscriptionStore.updatePlaybackPreference(subscriptionID: subscriptionID, preference: preference)

        if currentPlayerEpisode?.subscriptionID == subscriptionID, !sharedListeningActive {
            playbackEngine.updateTrimSilence(amount)
        }
    }

    // MARK: - Default Playback Preference (global, for new + non-subscribed feeds)

    // These edit AppSettings.defaultPlaybackPreference only. They never touch an
    // existing subscription's own playbackPreference — that snapshot was taken
    // when the feed was subscribed to. When the episode currently playing belongs
    // to a non-subscribed (browse) feed, the change is applied live, since browse
    // playback resolves through effectivePreference(for:).

    private func mutateDefaultPlaybackPreference(_ mutate: (inout PlaybackPreference) -> Void) {
        var preference = settingsStore.appSettings.defaultPlaybackPreference
        mutate(&preference)
        settingsStore.appSettings.defaultPlaybackPreference = preference
        if let episode = currentPlayerEpisode,
           let subscription = subscriptionStore.subscription(id: episode.subscriptionID),
           subscription.browseDate != nil {
            applyEffectivePreferenceToCurrentEpisode()
            if !sharedListeningActive {
                playbackEngine.updateVocalBoost(effectivePreference(for: subscription).vocalBoostLevel)
            }
        }
    }

    func updateDefaultPlaybackSpeed(_ speed: Double) {
        logger.info("settings.defaultSpeed", "Default playback speed changed", metadata: [
            "speed": PlaybackPreference.speedLabel(speed)
        ])
        mutateDefaultPlaybackPreference { $0.speed = speed }
    }

    func updateDefaultVocalBoost(_ level: VocalBoostLevel) {
        logger.info("settings.defaultVocalBoost", "Default Vocal Boost changed", metadata: ["level": level.title])
        mutateDefaultPlaybackPreference { $0.vocalBoostLevel = level }
    }

    func updateDefaultTrimSilence(_ amount: TrimSilenceAmount) {
        logger.info("settings.defaultTrimSilence", "Default Trim Silence changed", metadata: ["amount": amount.title])
        mutateDefaultPlaybackPreference { $0.trimSilence = amount }
    }

    func updateDefaultStartSkip(_ seconds: TimeInterval) {
        mutateDefaultPlaybackPreference { $0.startSkipSeconds = seconds }
    }

    func updateDefaultEndSkip(_ seconds: TimeInterval) {
        mutateDefaultPlaybackPreference { $0.endSkipSeconds = seconds }
    }

    // MARK: - Shared Listening (global temporary override)

    // While active, every podcast plays at sharedListeningSpeed (1.0–1.3x) with
    // Trim Silence off — per-subscription settings are untouched and resume the
    // moment the mode is switched off. Persisted in AppSettings so the mode
    // survives relaunch until explicitly deactivated.

    var sharedListeningActive: Bool { settingsStore.appSettings.sharedListeningActive }
    var sharedListeningSpeed: Double { settingsStore.appSettings.sharedListeningSpeed }

    static let sharedListeningSpeedOptions: [Double] = [1.0, 1.1, 1.2, 1.3]

    func setSharedListening(active: Bool) {
        var settings = settingsStore.appSettings
        settings.sharedListeningActive = active
        if active {
            // Each activation starts back at 1x regardless of last session's pick.
            settings.sharedListeningSpeed = 1.0
        }
        settingsStore.appSettings = settings
        logger.info("player.sharedListening", active ? "Shared Listening activated" : "Shared Listening deactivated")
        applyEffectivePreferenceToCurrentEpisode()
    }

    func updateSharedListeningSpeed(_ speed: Double) {
        guard sharedListeningActive else { return }
        settingsStore.appSettings.sharedListeningSpeed = speed
        logger.info("player.sharedListening", "Shared Listening speed changed", metadata: [
            "speed": PlaybackPreference.speedLabel(speed)
        ])
        applyEffectivePreferenceToCurrentEpisode()
    }

    /// The subscription's preference with the Shared Listening override applied.
    /// All playback paths must read speed/trim through this, never directly.
    func effectivePreference(for subscription: Subscription) -> PlaybackPreference {
        // Non-subscribed (browse-only) feeds always follow the live global
        // default — they never carry user-customised settings of their own.
        var preference = subscription.browseDate != nil
            ? settingsStore.appSettings.defaultPlaybackPreference
            : subscription.playbackPreference
        if settingsStore.appSettings.sharedListeningActive {
            preference.speed = settingsStore.appSettings.sharedListeningSpeed
            preference.trimSilence = .off
        }
        return preference
    }

    func effectiveSpeed(for subscription: Subscription) -> Double {
        effectivePreference(for: subscription).speed
    }

    private func applyEffectivePreferenceToCurrentEpisode() {
        guard let episode = currentPlayerEpisode,
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        else { return }
        let preference = effectivePreference(for: subscription)
        playbackEngine.updatePlaybackSpeed(preference.speed)
        playbackEngine.updateTrimSilence(preference.trimSilence)
        NowPlayingService.shared.updateTime(
            currentTime: currentPlayerTime,
            isPlaying: isPlaying,
            speed: preference.speed
        )
    }

    private func startPlayback(episode: Episode, resumeFrom: TimeInterval) async -> Bool {
        guard let subscription = subscriptionStore.subscription(id: episode.subscriptionID) else { return false }
        resourceMonitor.logSnapshot(reason: "player.start.before", context: resourceContext([
            "episode": episode.title,
            "podcast": subscription.title
        ]))
        logger.info("player.start", "Preparing playback", metadata: [
            "episode": episode.title,
            "podcast": subscription.title,
            "resume": "\(Int(resumeFrom))"
        ])
        var playableEpisode = subscriptionStore.episode(
            subscriptionID: subscription.id,
            episodeID: episode.id
        ) ?? episode

        if let repairedURL = resolvedLocalMediaURL(for: playableEpisode) {
            playableEpisode.localFileURL = repairedURL
        }

        if let localFileURL = playableEpisode.localFileURL,
           let fileDuration = await localAudioDuration(from: localFileURL) {
            playableEpisode.durationSeconds = fileDuration
            subscriptionStore.updateEpisodeDuration(
                subscriptionID: subscription.id,
                episodeID: playableEpisode.id,
                durationSeconds: fileDuration
            )
        }
        let safeResumeTime = normalizedResumeTime(resumeFrom, duration: playableEpisode.durationSeconds)

        guard let localFileURL = resolvedLocalMediaURL(for: playableEpisode) else {
            playbackMessage = "Downloading \(playableEpisode.title) before playback."
            logger.warning("player.missingFile", "Local audio file missing before playback", metadata: [
                "episode": playableEpisode.title,
                "episodeID": playableEpisode.id.uuidString,
                "storedPath": playableEpisode.localFileURL?.path ?? "none",
                "expectedPath": expectedLocalMediaPath(for: playableEpisode) ?? "unknown"
            ])
            await downloadEpisode(
                playableEpisode,
                subscriptionID: subscription.id,
                podcastTitle: subscription.title,
                showCompletionMessage: true
            )
            guard let refreshedEpisode = subscriptionStore.episode(subscriptionID: subscription.id, episodeID: playableEpisode.id),
                  localAudioFileExists(for: refreshedEpisode)
            else {
                isPlaying = false
                playbackMessage = "Could not download \(playableEpisode.title)."
                logger.error("player.downloadBeforePlaybackFailed", "Could not download missing episode before playback", metadata: [
                    "episode": playableEpisode.title
                ])
                return false
            }
            return await startPlayback(episode: refreshedEpisode, resumeFrom: 0)
        }
        playableEpisode.localFileURL = localFileURL

        if playableEpisode.chapters.isEmpty, let chaptersURL = playableEpisode.externalChaptersURL {
            if let fetched = await fetchExternalChapters(url: chaptersURL, episodeID: playableEpisode.id) {
                playableEpisode.chapters = fetched
                subscriptionStore.updateEpisodeChapters(
                    subscriptionID: subscription.id,
                    episodeID: playableEpisode.id,
                    chapters: fetched
                )
            }
        }

        do {
            // Reset volume to full before starting — clears any residual sleep-timer fade.
            playbackEngine.setVolume(1.0)

            let preference = effectivePreference(for: subscription)
            try await playbackEngine.play(
                playableEpisode,
                preference: preference,
                filter: subscription.chapterFilter
            )

            // Restore mid-episode position (overrides start-skip when > 0).
            if safeResumeTime > preference.startSkipSeconds {
                playbackEngine.seek(to: safeResumeTime)
                currentPlayerTime = safeResumeTime
            } else {
                // No resume — playback begins at the start-skip offset, so report that rather than 0
                // (otherwise Now Playing and history tracking briefly show 0 until the first tick).
                currentPlayerTime = preference.startSkipSeconds
            }

            subscriptionStore.markEpisodePlaying(subscriptionID: subscription.id, episodeID: playableEpisode.id)
            // Fresh start only — resuming a partially played episode is not a new "start".
            if safeResumeTime <= preference.startSkipSeconds {
                listeningStatsStore.recordEpisodeStarted(subscriptionID: subscription.id, showTitle: subscription.title)
            }
            currentPlayerEpisode = playableEpisode
            isPlaying = true
            positionSaveCounter = 0
            historyTrackingEpisodeID = playableEpisode.id
            historyTrackingLastTime = currentPlayerTime
            playbackMessage = nil

            // Auto-restart the sleep timer if it fired recently and the user has resumed.
            if sleepTimerService.checkAutoRestart() {
                logger.info("sleepTimer.autoRestart", "Sleep timer auto-restarted on playback resume")
            }

            // New playback session: clear any Sleep Schedule suspension and
            // arm a fresh cycle if we're inside the nightly window.
            sleepScheduleService.playbackStarted()

            logger.info("player.started", "Playback started", metadata: [
                "episode": playableEpisode.title,
                "podcast": subscription.title,
                "duration": playableEpisode.durationSeconds.map { "\(Int($0))" } ?? "unknown",
                "speed": PlaybackPreference.speedLabel(effectiveSpeed(for: subscription)),
                "vocalBoost": preference.vocalBoostLevel.title,
                "sharedListening": "\(sharedListeningActive)"
            ])

            NowPlayingService.shared.update(
                episode: playableEpisode,
                podcastTitle: subscription.title,
                currentTime: safeResumeTime,
                duration: playableEpisode.durationSeconds,
                speed: effectiveSpeed(for: subscription),
                isPlaying: true,
                artworkURL: playableEpisode.artworkURL ?? subscription.artworkURL
            )
            resourceMonitor.logSnapshot(reason: "player.start.afterSuccess", context: resourceContext([
                "episode": playableEpisode.title,
                "podcast": subscription.title
            ]))
            return true
        } catch {
            isPlaying = false
            playbackMessage = "Could not play \(playableEpisode.title)."
            logger.error("player.failed", "Playback failed", metadata: [
                "episode": playableEpisode.title,
                "error": String(describing: error)
            ])
            resourceMonitor.logSnapshot(reason: "player.start.afterFailure", context: resourceContext([
                "episode": playableEpisode.title,
                "podcast": subscription.title
            ]), force: true)
            return false
        }
    }

    func handleEpisodeFinished(_ episode: Episode) async {
        logger.info("player.finished", "Episode finished playback", metadata: [
            "episode": episode.title
        ])

        // Check sleep timer before advancing. `episodeFinished()` decrements the counter;
        // returns true on the last episode — in which case we stop rather than advance.
        let sleepTimerFired = sleepTimerService.episodeFinished()

        // Sleep Schedule end-of-episode mode: begin the prompt at the boundary
        // (skipped when the manual timer just fired). Playback still advances
        // to the next episode — the chime plays over it, and if there's no
        // response the asleep handler rewinds that episode to its start.
        let sleepSchedulePrompting = !sleepTimerFired && sleepScheduleService.episodeFinished()

        // Episode reached EOF: use its full duration as the position.
        let finishedPos = episode.durationSeconds
        listeningStatsStore.recordEpisodeCompleted(subscriptionID: episode.subscriptionID)
        clearPlaybackPosition(for: episode)
        markListeningHistory(
            episode,
            status: .played,
            completionKind: .finishedNaturally,
            positionSeconds: finishedPos
        )

        do {
            try await downloadManager.deleteLocalFile(for: episode)
        } catch {
            logger.warning("player.finished", "Could not delete local file after playback", metadata: [
                "episode": episode.title,
                "error": String(describing: error)
            ])
        }
        subscriptionStore.markEpisodePlayed(subscriptionID: episode.subscriptionID, episodeID: episode.id)

        isPlaying = false
        currentPlayerTime = 0

        if sleepTimerFired {
            logger.info("sleepTimer.episodeEnd", "Sleep timer stopped playback after episode finished", metadata: [
                "episode": episode.title
            ])
            NowPlayingService.shared.clear()
            return
        }

        if sleepSchedulePrompting {
            logger.info("sleepSchedule.episodeEnd", "Sleep Schedule prompting at episode boundary, advancing under the chime", metadata: [
                "episode": episode.title
            ])
        }

        try? await Task.sleep(for: .seconds(0.4))
        await playNextEpisode(excluding: [episode.id])
    }

    // MARK: - Feed refresh

    func refreshSubscription(_ subscription: Subscription, episodeLimit: Int? = 50, refreshUpNextAfterMerge: Bool = true) async {
        resourceMonitor.logSnapshot(reason: "feed.refresh.before", context: resourceContext([
            "podcast": subscription.title
        ]))
        logger.info("feed.refresh", "Refreshing podcast feed", metadata: [
            "podcast": subscription.title,
            "url": subscription.feedURL.absoluteString
        ])
        do {
            let outcome = try await feedService.refreshIfModified(
                feedURL: subscription.feedURL,
                subscriptionID: subscription.id,
                episodeLimit: episodeLimit,
                validators: FeedValidators(
                    etag: subscription.refreshStats.etag,
                    lastModified: subscription.refreshStats.lastModified
                )
            )
            feedFailureBackoffUntil.removeValue(forKey: subscription.id)

            guard case .updated(let result, let newValidators) = outcome else {
                var stats = subscription.refreshStats
                stats.recordFetch(foundNewEpisode: false)
                subscriptionStore.updateRefreshStats(subscriptionID: subscription.id, stats: stats)
                logger.info("feed.notModified", "Feed unchanged (304)", metadata: [
                    "podcast": subscription.title
                ])
                return
            }

            let oldLatestGUID = subscription.latestEpisode?.guid
            var stats = subscription.refreshStats
            stats.etag = newValidators.etag
            stats.lastModified = newValidators.lastModified
            stats.recordFetch(
                foundNewEpisode: result.latestEpisode.guid != oldLatestGUID,
                publishedAt: result.latestEpisode.publishedAt
            )
            subscriptionStore.updateRefreshStats(subscriptionID: subscription.id, stats: stats)
            let oldLatestWasDownloaded = subscription.latestEpisode?.downloadState == .downloaded

            if let old = subscription.latestEpisode,
               old.localFileURL != nil,
               result.latestEpisode.guid != old.guid,
               currentPlayerEpisode?.id != old.id {
                logger.info("feed.cleanupOldLatest", "Deleting old latest episode after new feed item", metadata: [
                    "episode": old.title,
                    "podcast": subscription.title
                ])
                try? await downloadManager.deleteLocalFile(for: old)
                subscriptionStore.markEpisodeNotDownloaded(subscriptionID: old.subscriptionID, episodeID: old.id)
            }

            logger.info("feed.refreshMerge", "Merging refreshed feed episodes", metadata: [
                "podcast": subscription.title,
                "oldLatest": oldLatestGUID ?? "none",
                "newLatest": result.latestEpisode.guid,
                "episodeCount": "\(result.episodes.count)"
            ])
            subscriptionStore.updateEpisodes(
                subscriptionID: subscription.id,
                episodes: result.episodes
            )
            subscriptionStore.updateDescription(subscriptionID: subscription.id, description: result.description)
            subscriptionStore.updateCategories(subscriptionID: subscription.id, categories: result.categories)
            subscriptionStore.updateIsExplicit(subscriptionID: subscription.id, isExplicit: result.isExplicit)
            if refreshUpNextAfterMerge {
                scheduleUpNextRefresh(reason: "feed.refresh.\(subscription.title)")
            }
            guard let latestPlayedState = subscriptionStore.subscription(id: subscription.id)?.latestEpisode?.playedState,
                  latestPlayedState != .played,
                  latestPlayedState != .archived
            else {
                logger.info("feed.refresh", "Latest episode is already played or archived", metadata: [
                    "podcast": subscription.title
                ])
                return
            }
            guard result.latestEpisode.guid != oldLatestGUID || oldLatestWasDownloaded == false else {
                logger.info("feed.refresh", "No new download needed", metadata: [
                    "podcast": subscription.title
                ])
                return
            }
            await enforceEpisodeLimitBeforeDownload(subscriptionID: subscription.id)
            await downloadEpisode(
                subscriptionStore.subscription(id: subscription.id)?.latestEpisode ?? result.latestEpisode,
                subscriptionID: subscription.id,
                podcastTitle: result.subscriptionTitle,
                showCompletionMessage: false
            )
            if refreshUpNextAfterMerge {
                scheduleUpNextRefresh(reason: "feed.download.\(result.subscriptionTitle)")
            }
            logger.info("feed.refresh", "Feed refresh completed", metadata: [
                "podcast": result.subscriptionTitle,
                "episodeCount": "\(result.episodes.count)"
            ])
            resourceMonitor.logSnapshot(reason: "feed.refresh.afterSuccess", context: resourceContext([
                "podcast": result.subscriptionTitle,
                "episodeCount": "\(result.episodes.count)"
            ]))
        } catch {
            if isCancellationError(error) {
                logger.info("feed.refreshCancelled", "Feed refresh cancelled", metadata: [
                    "podcast": subscription.title
                ])
                return
            }
            // Requests stranded by app suspension surface as timeouts or dropped
            // connections once the app wakes. Those say nothing about the feed's
            // health — retry on the normal schedule instead of backing off.
            if isTransientTransportError(error), UIApplication.shared.applicationState != .active {
                logger.info("feed.refreshDeferred", "Feed refresh dropped while app inactive — no backoff applied", metadata: [
                    "podcast": subscription.title,
                    "error": String(describing: error)
                ])
                return
            }
            let backoffUntil = Date().addingTimeInterval(feedFailureBackoffInterval)
            feedFailureBackoffUntil[subscription.id] = backoffUntil
            logger.error("feed.refreshFailed", "Feed refresh failed", metadata: [
                "podcast": subscription.title,
                "error": String(describing: error),
                "backoffUntil": backoffUntil.formatted(date: .omitted, time: .standard)
            ])
            resourceMonitor.logSnapshot(reason: "feed.refresh.afterFailure", context: resourceContext([
                "podcast": subscription.title
            ]), force: true)
        }
    }

    /// Manual refresh (pull-to-refresh): every feed, ignoring due dates.
    func refreshAllSubscriptions(includeBackoffFeeds: Bool = false) async {
        await refreshSubscriptions(
            reason: "manual",
            maxSubscriptions: nil,
            includeBackoffFeeds: includeBackoffFeeds,
            onlyDueFeeds: false
        )
    }

    /// Timed foreground tick: only feeds whose adaptive schedule says they're due.
    @discardableResult
    func refreshDueSubscriptions() async -> Bool {
        await refreshSubscriptions(
            reason: "timed-due",
            maxSubscriptions: nil,
            includeBackoffFeeds: false,
            onlyDueFeeds: true
        )
    }

    @discardableResult
    func refreshSubscriptionsForBackground() async -> Bool {
        await refreshSubscriptions(
            reason: "background",
            maxSubscriptions: backgroundRefreshFeedLimit,
            includeBackoffFeeds: false,
            onlyDueFeeds: true,
            joinActiveCycle: true
        )
    }

    @discardableResult
    private func refreshSubscriptions(
        reason: String,
        maxSubscriptions: Int?,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool,
        joinActiveCycle: Bool = false
    ) async -> Bool {
        if let active = activeRefreshCycle {
            guard joinActiveCycle else {
                logger.info("feed.refreshAll.skip", "Refresh-all skipped because another cycle is already running", metadata: [
                    "count": "\(subscriptionStore.subscriptions.count)",
                    "reason": reason
                ])
                return false
            }
            // A cycle is already in flight (e.g. the foreground tick fired on the
            // same wake as a background task). Ride it to completion instead of
            // skipping, so the BGTask stays alive until the work is actually done —
            // completing early lets iOS suspend the app mid-request.
            logger.info("feed.refreshAll.join", "Joining refresh cycle already in flight", metadata: [
                "reason": reason
            ])
            return await active.value
        }

        let cycle = Task { @MainActor in
            await self.performRefreshCycle(
                reason: reason,
                maxSubscriptions: maxSubscriptions,
                includeBackoffFeeds: includeBackoffFeeds,
                onlyDueFeeds: onlyDueFeeds
            )
        }
        activeRefreshCycle = cycle
        defer { activeRefreshCycle = nil }
        return await cycle.value
    }

    private func performRefreshCycle(
        reason: String,
        maxSubscriptions: Int?,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool
    ) async -> Bool {
        suppressUpNextRefresh = true
        defer { suppressUpNextRefresh = false }

        resourceMonitor.logSnapshot(reason: "feed.refreshAll.before", context: resourceContext(), force: true)
        logger.info("feed.refreshAll", "Refreshing all podcast feeds", metadata: [
            "count": "\(subscriptionStore.subscriptions.count)",
            "reason": reason,
            "maxSubscriptions": maxSubscriptions.map(String.init) ?? "all"
        ])
        let skippedSubscriptions = subscriptionStore.subscriptions.filter(\.excludeFromAutoFeedRefresh)
        let activeSubscriptions = subscriptionStore.subscriptions.filter { !$0.excludeFromAutoFeedRefresh }
        let now = Date()
        let backoffSubscriptions = activeSubscriptions.filter { subscription in
            guard let until = feedFailureBackoffUntil[subscription.id] else { return false }
            return until > now
        }
        let eligibleSubscriptions = includeBackoffFeeds
            ? activeSubscriptions
            : activeSubscriptions.filter { subscription in
                guard let until = feedFailureBackoffUntil[subscription.id] else { return true }
                return until <= now
            }
        let subscriptions = onlyDueFeeds
            ? subscriptionsForRefreshCycle(eligibleSubscriptions, maxSubscriptions: maxSubscriptions)
            : eligibleSubscriptions
        if onlyDueFeeds, subscriptions.isEmpty {
            return false
        }
        if !skippedSubscriptions.isEmpty {
            logger.info("feed.refreshAll.skippedInactive", "Skipped subscriptions excluded from auto feed refresh", metadata: [
                "count": "\(skippedSubscriptions.count)",
                "podcasts": skippedSubscriptions.map(\.title).joined(separator: ", ")
            ])
        }
        if !includeBackoffFeeds, !backoffSubscriptions.isEmpty {
            logger.info("feed.refreshAll.skippedBackoff", "Skipped subscriptions temporarily paused after failed refreshes", metadata: [
                "count": "\(backoffSubscriptions.count)",
                "podcasts": backoffSubscriptions.map(\.title).joined(separator: ", ")
            ])
        }
        for (index, subscription) in subscriptions.enumerated() {
            logger.info("feed.refreshAll.itemStart", "Refreshing subscription in timed cycle", metadata: [
                "index": "\(index + 1)",
                "total": "\(subscriptions.count)",
                "podcast": subscription.title,
                "url": subscription.feedURL.absoluteString,
                "reason": reason
            ])
            await refreshSubscription(
                subscription,
                episodeLimit: defaultFeedEpisodeLimit,
                refreshUpNextAfterMerge: false
            )
            logger.info("feed.refreshAll.itemFinished", "Finished subscription in timed cycle", metadata: [
                "index": "\(index + 1)",
                "total": "\(subscriptions.count)",
                "podcast": subscription.title,
                "reason": reason
            ])
        }
        let soonestDue = subscriptionStore.subscriptions
            .filter { !$0.excludeFromAutoFeedRefresh }
            .map { nextRefreshDue(for: $0) }
            .min()
        BackgroundTaskCoordinator.scheduleAppRefresh(earliestBeginDate: soonestDue)
        refreshUpNextEpisode(reason: "feed.refreshAll.finished")
        await runAutoArchiveIfNeeded(reason: "feed.refreshAll")
        logger.info("feed.refreshAll", "Finished refreshing all podcast feeds", metadata: [
            "attempted": "\(subscriptions.count)",
            "eligible": "\(eligibleSubscriptions.count)",
            "skippedBackoff": "\(backoffSubscriptions.count)",
            "skippedInactive": "\(skippedSubscriptions.count)",
            "reason": reason
        ])
        resourceMonitor.logSnapshot(reason: "feed.refreshAll.after", context: resourceContext(), force: true)
        return true
    }

    /// The next moment a subscription deserves a fetch, derived from its episode
    /// publish cadence (anchored to `publishedAt`, so fixed release schedules phase-lock).
    func nextRefreshDue(for subscription: Subscription) -> Date {
        // Single-item feeds (hourly news bulletins) carry too few dates to derive a
        // cadence from the feed alone — fold in the persisted publish-date history.
        let publishDates = Set(subscription.episodes.compactMap(\.publishedAt))
            .union(subscription.refreshStats.recentPublishDates)
        return FeedRefreshScheduling.nextDueAt(
            latestPublishedAt: subscription.latestEpisode?.publishedAt,
            publishDates: Array(publishDates),
            stats: subscription.refreshStats,
            minRecheckInterval: Double(settingsStore.appSettings.podcastPollMinutes) * 60
        )
    }

    /// Due-date priority queue: overdue feeds first; feeds not yet due are skipped entirely.
    /// `maxSubscriptions` remains only as a safety bound for the background window.
    private func subscriptionsForRefreshCycle(
        _ subscriptions: [Subscription],
        maxSubscriptions: Int?
    ) -> [Subscription] {
        let now = Date()
        let due = subscriptions
            .map { (subscription: $0, dueAt: nextRefreshDue(for: $0)) }
            .filter { $0.dueAt <= now }
            .sorted { $0.dueAt < $1.dueAt }
            .map(\.subscription)
        guard let maxSubscriptions, maxSubscriptions > 0 else { return due }
        return Array(due.prefix(maxSubscriptions))
    }

    /// Archives the oldest excess episodes so the newest can always download —
    /// the limit is a gate at the door, not a cleanup afterwards. Never touches
    /// the currently-playing episode.
    private func enforceEpisodeLimitBeforeDownload(subscriptionID: UUID) async {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        let limit = subscription.autoArchiveSettings.episodeLimit.rawValue
        guard limit > 0 else { return }

        // Pre-subscription backlog stays browsable — only count episodes published
        // after subscribing toward the keep-N limit (mirrors runAutoArchive).
        let backlogCutoff = subscription.subscribedAt
        let active = subscription.episodes
            .filter { episode in
                guard episode.playedState != .archived else { return false }
                if let backlogCutoff, let published = episode.publishedAt, published <= backlogCutoff {
                    return false
                }
                return true
            }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        guard active.count > limit else { return }

        for episode in active.dropFirst(limit) where episode.id != currentPlayerEpisode?.id {
            logger.info("autoArchive.inlineLimit", "Archiving excess episode before new download", metadata: [
                "podcast": subscription.title,
                "episode": episode.title,
                "limit": "\(limit)"
            ])
            await archiveEpisode(episode, completionKind: .autoArchived)
        }
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
        let lastRun = settingsStore.appSettings.lastAutoArchiveRunAt
        if !force,
           let lastRun,
           Date().timeIntervalSince(lastRun) < autoArchiveInterval {
            // Triggers arrive with every refresh cycle (~30 s apart) — log the skip
            // at most once a few minutes so the gate stays visible without spam.
            let now = Date()
            if lastAutoArchiveSkipLogAt.map({ now.timeIntervalSince($0) >= 5 * 60 }) ?? true {
                lastAutoArchiveSkipLogAt = now
                logger.info("autoArchive.skip", "Auto archive skipped", metadata: [
                    "reason": reason,
                    "lastRun": lastRun.formatted(date: .numeric, time: .standard),
                    "nextRun": lastRun.addingTimeInterval(autoArchiveInterval).formatted(date: .numeric, time: .standard)
                ])
            }
            return
        }

        settingsStore.appSettings.lastAutoArchiveRunAt = Date()
        await runAutoArchive(reason: reason)
    }

    private func runAutoArchive(reason: String) async {
        logger.info("autoArchive.start", "Auto archive started", metadata: ["reason": reason])
        resourceMonitor.logSnapshot(reason: "autoArchive.before", context: resourceContext(), force: true)

        var archivedCount = 0
        let now = Date()
        let playingID = currentPlayerEpisode?.id

        // Collect all non-archived episodes grouped by subscription.
        let allSubscriptions = subscriptionStore.subscriptions
        var archivedIDs = Set<UUID>()   // track within this run to avoid double-archiving

        for subscription in allSubscriptions {
            let settings = subscription.autoArchiveSettings
            let allEpisodes = subscription.episodes.filter { $0.playedState != .archived }

            // Episodes that already existed when the user subscribed are the
            // pre-existing back-catalogue — leave them browsable (unplayed) rather
            // than archiving the whole feed the moment you subscribe. Only episodes
            // published after subscribing flow through the inactive/limit passes.
            let backlogCutoff = subscription.subscribedAt
            func isPreSubscriptionBacklog(_ episode: Episode) -> Bool {
                guard let backlogCutoff, let published = episode.publishedAt else { return false }
                return published <= backlogCutoff
            }

            // ── Pass 1: After Played ──────────────────────────────────────────
            if let interval = settings.afterPlayed.interval {
                for episode in allEpisodes {
                    guard episode.playedState == .played,
                          episode.id != playingID,
                          !archivedIDs.contains(episode.id)
                    else { continue }

                    let playedAt = episode.lastPlayedAt ?? now  // if no timestamp, archive immediately
                    if now.timeIntervalSince(playedAt) >= interval {
                        await archiveEpisode(episode, completionKind: .autoArchived)
                        archivedIDs.insert(episode.id)
                        archivedCount += 1
                        logger.info("autoArchive.played", "Archived played episode", metadata: [
                            "podcast": subscription.title, "episode": episode.title
                        ])
                    }
                }
            }

            // ── Pass 2: After Inactive ────────────────────────────────────────
            if let interval = settings.afterInactive.interval {
                for episode in allEpisodes {
                    guard episode.playedState == .unplayed,
                          episode.id != playingID,
                          !archivedIDs.contains(episode.id),
                          !isPreSubscriptionBacklog(episode)
                    else { continue }

                    // An episode is inactive if nothing has touched it recently.
                    // "Last activity" = the most recent of: publish date, download date, play date.
                    let publishAge = episode.publishedAt.map { now.timeIntervalSince($0) } ?? interval
                    let playAge   = episode.lastPlayedAt.map { now.timeIntervalSince($0) }
                    let lastActivityAge = [publishAge, playAge].compactMap { $0 }.min() ?? publishAge

                    if lastActivityAge >= interval {
                        await archiveEpisode(episode, completionKind: .autoArchived)
                        archivedIDs.insert(episode.id)
                        archivedCount += 1
                        logger.info("autoArchive.inactive", "Archived inactive episode", metadata: [
                            "podcast": subscription.title, "episode": episode.title
                        ])
                    }
                }
            }

            // ── Pass 3: Episode Limit ─────────────────────────────────────────
            let limit = settings.episodeLimit.rawValue
            if limit > 0 {
                // Sort all non-archived episodes newest-first; keep the top N, archive the rest.
                let candidates = subscription.episodes
                    .filter { $0.playedState != .archived && !archivedIDs.contains($0.id) && $0.downloadState != .downloading && !isPreSubscriptionBacklog($0) }
                    .sorted {
                        ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
                    }
                for (index, episode) in candidates.enumerated() {
                    guard index >= limit,
                          episode.id != playingID
                    else { continue }
                    await archiveEpisode(episode, completionKind: .autoArchived)
                    archivedIDs.insert(episode.id)
                    archivedCount += 1
                    logger.info("autoArchive.limit", "Archived episode over limit", metadata: [
                        "podcast": subscription.title, "episode": episode.title, "limit": "\(limit)"
                    ])
                }
            }
        }

        refreshUpNextEpisode(reason: "autoArchive.finished")
        logger.info("autoArchive.finished", "Auto archive finished", metadata: [
            "reason": reason,
            "archivedCount": "\(archivedCount)"
        ])
        resourceMonitor.logSnapshot(reason: "autoArchive.after", context: resourceContext([
            "archivedCount": "\(archivedCount)"
        ]), force: true)
    }

    // MARK: - OPML

    struct OPMLImportSummary { var imported: Int; var failed: Int }

    func importOPML(from fileURL: URL) async -> OPMLImportSummary {
        let canAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if canAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let existingURLs = Set(subscriptionStore.subscriptions.map(\.feedURL))
        let newURLs: [URL]
        do {
            newURLs = try await OPMLService().importSubscriptions(
                from: fileURL, existingFeedURLs: existingURLs
            )
        } catch {
            downloadMessage = "Could not read the OPML file."
            logger.error("opml.importFailed", "Could not read OPML file", metadata: [
                "file": fileURL.lastPathComponent,
                "error": String(describing: error)
            ])
            return OPMLImportSummary(imported: 0, failed: 0)
        }

        guard !newURLs.isEmpty else {
            downloadMessage = "No new podcasts found in the OPML file."
            logger.info("opml.import", "No new podcasts found", metadata: [
                "file": fileURL.lastPathComponent
            ])
            return OPMLImportSummary(imported: 0, failed: 0)
        }

        var imported = 0; var failed = 0
        let total = newURLs.count
        for (index, url) in newURLs.enumerated() {
            opmlImportProgress = (current: index + 1, total: total)
            let subscriptionID = UUID()
            do {
                let result = try await feedService.refresh(
                    feedURL: url,
                    subscriptionID: subscriptionID,
                    episodeLimit: defaultFeedEpisodeLimit
                )
                _ = try subscriptionStore.addSubscription(
                    id: subscriptionID, feedURL: url,
                    title: result.subscriptionTitle, description: result.description,
                    author: result.author,
                    artworkURL: result.artworkURL,
                    categories: result.categories,
                    isExplicit: result.isExplicit,
                    latestEpisode: result.latestEpisode,
                    insertAtBottom: true
                )
                subscriptionStore.updateEpisodes(subscriptionID: subscriptionID, episodes: result.episodes)
                logger.info("opml.importPodcast", "Imported podcast", metadata: [
                    "podcast": result.subscriptionTitle,
                    "url": url.absoluteString
                ])
                imported += 1
            } catch {
                logger.error("opml.importPodcastFailed", "Could not import podcast", metadata: [
                    "url": url.absoluteString,
                    "error": String(describing: error)
                ])
                failed += 1
            }
        }

        opmlImportProgress = nil
        downloadMessage = imported > 0
            ? "Imported \(imported) podcast\(imported == 1 ? "" : "s")."
            : "No podcasts could be imported (\(failed) failed)."
        logger.info("opml.importComplete", "OPML import complete", metadata: [
            "imported": "\(imported)",
            "failed": "\(failed)"
        ])
        return OPMLImportSummary(imported: imported, failed: failed)
    }

    func exportOPML() -> Data? {
        try? OPMLService().exportSubscriptions(subscriptionStore.subscriptions)
    }

    // MARK: - Playback position persistence

    private func savePlaybackPosition() {
        guard let episode = currentPlayerEpisode,
              currentPlayerTime > 0,
              let url = Self.positionFileURL
        else { return }
        guard normalizedResumeTime(currentPlayerTime, duration: episode.durationSeconds) > 0 else {
            clearPlaybackPosition(for: episode)
            return
        }

        let episodeKey = playbackPositionKey(for: episode)
        let position = SavedPosition(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            episodeKey: episodeKey,
            timeSeconds: currentPlayerTime,
            updatedAt: Date()
        )
        var positions = loadSavedPositions()
        positions[episodeKey] = position
        positions.removeValue(forKey: episode.id.uuidString)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(positions) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func persistCurrentPlaybackPosition() {
        savePlaybackPosition()
        listeningHistoryStore.save()
    }

    private func saveQueuePins() {
        guard let url = Self.queuePinsFileURL else { return }
        let pins = SavedQueuePins(overrideIDs: queueOverrideEpisodeIDs, demotedIDs: queueDemotedEpisodeIDs)
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private func loadQueuePins() {
        guard let url = Self.queuePinsFileURL,
              let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode(SavedQueuePins.self, from: data)
        else { return }
        queueOverrideEpisodeIDs = pins.overrideIDs
        queueDemotedEpisodeIDs = pins.demotedIDs
        logger.info("queue.pinsLoaded", "Queue pins restored", metadata: [
            "overrideCount": "\(pins.overrideIDs.count)",
            "demotedCount": "\(pins.demotedIDs.count)"
        ])
    }

    private func restorePlaybackPosition() {
        let positions = loadSavedPositions()
        guard let restored = downloadedQueue
            .compactMap({ episode -> (Episode, SavedPosition)? in
                let saved = positions[playbackPositionKey(for: episode)]
                    ?? positions[episode.id.uuidString]
                guard let saved else { return nil }
                return (episode, saved)
            })
            .max(by: { lhs, rhs in
                switch (lhs.1.updatedAt, rhs.1.updatedAt) {
                case let (left?, right?):
                    return left < right
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case (nil, nil):
                    return lhs.1.timeSeconds < rhs.1.timeSeconds
                }
            })
        else { return }
        let episode = restored.0
        let saved = restored.1

        // Only restore if the episode is still downloaded.
        guard let sub = subscriptionStore.subscription(id: episode.subscriptionID),
              let storedEpisode = subscriptionStore.episode(subscriptionID: sub.id, episodeID: episode.id),
              episode.downloadState == .downloaded,
              resolvedLocalMediaURL(for: episode) != nil
        else {
            clearPlaybackPosition(for: episode)
            return
        }

        // Pre-populate player state — user tapping play will resume from this time.
        let resumeTime = normalizedResumeTime(saved.timeSeconds, duration: episode.durationSeconds)
        guard resumeTime > 0 else {
            clearPlaybackPosition(for: episode)
            return
        }
        currentPlayerEpisode = storedEpisode
        currentPlayerTime = resumeTime
        logger.info("player.restorePosition", "Restored playback position", metadata: [
            "episode": episode.title,
            "resume": "\(Int(resumeTime))"
        ])
    }

    private func savedPlaybackTime(for episode: Episode) -> TimeInterval {
        let positions = loadSavedPositions()
        guard let position = positions[playbackPositionKey(for: episode)] ?? positions[episode.id.uuidString],
              position.subscriptionID == episode.subscriptionID
        else { return 0 }
        return normalizedResumeTime(position.timeSeconds, duration: episode.durationSeconds)
    }

    private func loadSavedPositions() -> SavedPositions {
        guard let url = Self.positionFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return [:] }

        if let positions = try? JSONDecoder().decode(SavedPositions.self, from: data) {
            return positions
        }

        if let legacyPositions = try? JSONDecoder().decode([UUID: SavedPosition].self, from: data) {
            return Dictionary(uniqueKeysWithValues: legacyPositions.map { ($0.key.uuidString, $0.value) })
        }

        if let legacyPosition = try? JSONDecoder().decode(SavedPosition.self, from: data) {
            return [legacyPosition.episodeID.uuidString: legacyPosition]
        }

        return [:]
    }

    private func clearPlaybackPosition(for episodeID: UUID) {
        guard let url = Self.positionFileURL else { return }
        var positions = loadSavedPositions()
        positions.removeValue(forKey: episodeID.uuidString)
        if positions.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(positions) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func clearPlaybackPosition(for episode: Episode) {
        guard let url = Self.positionFileURL else { return }
        var positions = loadSavedPositions()
        positions.removeValue(forKey: playbackPositionKey(for: episode))
        positions.removeValue(forKey: episode.id.uuidString)
        if positions.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(positions) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func clearPlaybackPosition() {
        guard let url = Self.positionFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func normalizedResumeTime(_ seconds: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard let duration, duration.isFinite, duration > 0 else { return seconds }
        let clamped = clampedPlaybackTime(seconds, duration: duration)
        return clamped >= max(0, duration - 2) ? 0 : clamped
    }

    private func playbackPositionKey(for episode: Episode) -> String {
        let subscriptionPrefix = episode.subscriptionID.uuidString
        let trimmedGUID = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGUID.isEmpty {
            return "\(subscriptionPrefix)|guid:\(trimmedGUID)"
        }
        if let publishedAt = episode.publishedAt {
            return "\(subscriptionPrefix)|title-date:\(episode.title.lowercased())|\(Int(publishedAt.timeIntervalSince1970))"
        }
        return "\(subscriptionPrefix)|title-url:\(episode.title.lowercased())|\(episode.audioURL.absoluteString)"
    }

    private func recordListeningProgress(at time: TimeInterval) {
        guard isPlaying,
              let episode = currentPlayerEpisode,
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        else {
            historyTrackingEpisodeID = nil
            historyTrackingLastTime = nil
            return
        }

        guard historyTrackingEpisodeID == episode.id, let lastTime = historyTrackingLastTime else {
            historyTrackingEpisodeID = episode.id
            historyTrackingLastTime = time
            return
        }

        historyTrackingLastTime = time
        let delta = time - lastTime
        guard delta > 0, delta <= 3 else { return }

        listeningHistoryStore.recordProgress(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSeconds: delta,
            positionSeconds: time,
            durationSeconds: episode.durationSeconds
        )
    }

    private func markListeningHistory(
        _ episode: Episode,
        status: ListeningHistoryStatus,
        completionKind: CompletionKind,
        positionSeconds: TimeInterval? = nil
    ) {
        let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        listeningHistoryStore.mark(
            episode: episode,
            podcastTitle: subscription?.title ?? episode.author ?? "Podcast",
            artworkURL: episode.artworkURL ?? subscription?.artworkURL,
            status: status,
            completionKind: completionKind,
            positionSeconds: positionSeconds
        )
        refreshListeningHistory()
    }

    private func reusableDownloadedEpisode(for episode: Episode) -> Episode? {
        let storedEpisode = subscriptionStore.episode(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id
        )

        if var storedEpisode,
           storedEpisode.downloadState == .downloaded,
           let localFileURL = resolvedLocalMediaURL(for: storedEpisode) {
            storedEpisode.localFileURL = localFileURL
            return storedEpisode
        }

        var candidateEpisode = episode
        if candidateEpisode.downloadState == .downloaded,
           let localFileURL = resolvedLocalMediaURL(for: candidateEpisode) {
            candidateEpisode.localFileURL = localFileURL
            return candidateEpisode
        }

        return nil
    }

    private func scheduleUpNextRefresh(reason: String = "state.changed") {
        guard !suppressUpNextRefresh else { return }
        upNextRefreshTask?.cancel()
        upNextRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refreshUpNextEpisode(reason: reason)
        }
    }

    private func refreshUpNextEpisode(reason: String = "state.changed") {
        let latest = resolvedUpNextEpisode()
        let didChange = latest?.id != upNextEpisode?.id
        guard didChange || reason != "state.changed" else { return }
        logger.info("queue.upNextRefresh", "Resolved Up Next episode", metadata: [
            "reason": reason,
            "current": currentPlayerEpisode?.title ?? "none",
            "previous": upNextEpisode?.title ?? "none",
            "resolved": latest?.title ?? "none",
            "queueCount": "\(downloadedQueue.count)",
            "changed": "\(didChange)"
        ])
        upNextEpisode = latest
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func isTransientTransportError(_ error: Error) -> Bool {
        if case FeedServiceError.timedOut = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && (nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost)
    }

    private func clampedPlaybackTime(_ seconds: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = max(0, seconds.isFinite ? seconds : 0)
        guard let duration, duration.isFinite, duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }

    private func localAudioFileExists(for episode: Episode) -> Bool {
        resolvedLocalMediaURL(for: episode) != nil
    }

    private func resolvedLocalMediaURL(for episode: Episode) -> URL? {
        if let fileName = episode.localFileName,
           let url = try? downloadManager.localFileURL(fileName: fileName),
           FileManager.default.fileExists(atPath: url.path) {
            if episode.localFileURL?.path != url.path {
                subscriptionStore.markEpisodeDownloaded(
                    subscriptionID: episode.subscriptionID,
                    episodeID: episode.id,
                    localFileURL: url
                )
            }
            return url
        }

        if let url = episode.localFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            if episode.localFileName == nil {
                subscriptionStore.markEpisodeDownloaded(
                    subscriptionID: episode.subscriptionID,
                    episodeID: episode.id,
                    localFileURL: url
                )
            }
            return url
        }

        guard let expectedURL = try? downloadManager.expectedLocalFileURL(for: episode) else {
            return nil
        }

        if FileManager.default.fileExists(atPath: expectedURL.path) {
            if episode.localFileURL?.path != expectedURL.path {
                logger.info("download.localFilePathRepaired", "Repaired stale local media path", metadata: [
                    "episode": episode.title,
                    "episodeID": episode.id.uuidString,
                    "storedPath": episode.localFileURL?.path ?? "none",
                    "repairedPath": expectedURL.path
                ])
                subscriptionStore.markEpisodeDownloaded(
                    subscriptionID: episode.subscriptionID,
                    episodeID: episode.id,
                    localFileURL: expectedURL
                )
            }
            return expectedURL
        }

        return nil
    }

    private func expectedLocalMediaPath(for episode: Episode) -> String? {
        try? downloadManager.expectedLocalFileURL(for: episode).path
    }

    private func localAudioDuration(from url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration > 0
        else { return nil }
        return duration
    }

    private func fetchExternalChapters(url: URL, episodeID: UUID) async -> [Chapter]? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              HTTPResponseValidation.isAcceptable(response) else { return nil }
        struct JSONChapters: Decodable {
            struct JSONChapter: Decodable {
                var startTime: TimeInterval
                var title: String?
                var img: URL?
            }
            var chapters: [JSONChapter]
        }
        guard let parsed = try? JSONDecoder().decode(JSONChapters.self, from: data),
              !parsed.chapters.isEmpty
        else { return nil }
        return parsed.chapters.enumerated().map { index, c in
            Chapter(
                episodeID: episodeID,
                position: index + 1,
                title: c.title ?? "Chapter \(index + 1)",
                startSeconds: c.startTime,
                artworkURL: c.img,
                source: .podcastChaptersJSON
            )
        }
    }

    // MARK: - Foreground polling

    /// Foreground scheduler: ticks every 30 seconds and refreshes only the feeds
    /// whose adaptive due date has arrived. Conditional requests (304s) make each
    /// check nearly free, so an hourly news feed is picked up within a minute or
    /// two of publish while a weekly show is fetched roughly once a day.
    func startForegroundPolling() {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let now = Date()
                let anyDue = self.subscriptionStore.subscriptions.contains { subscription in
                    !subscription.excludeFromAutoFeedRefresh
                        && self.nextRefreshDue(for: subscription) <= now
                }
                if anyDue {
                    await self.refreshDueSubscriptions()
                }
            }
        }
    }

    private func startResourceMonitoring() {
        resourceMonitor.startPeriodicSampling { [weak self] in
            guard let self else { return [:] }
            return self.resourceContext()
        }
    }

    func syncDiagnosticLogging() {
        AppLogger.shared.isEnabled = settingsStore.appSettings.diagnosticLoggingEnabled
    }

    /// Pushes the AppSettings.sleepSchedule* values into SleepScheduleService.
    func syncSleepScheduleConfig() {
        let settings = settingsStore.appSettings
        sleepScheduleService.updateConfig(
            SleepScheduleService.Config(
                enabled: settings.sleepScheduleEnabled,
                startMinutes: settings.sleepScheduleStartMinutes,
                endMinutes: settings.sleepScheduleEndMinutes,
                durationMinutes: settings.sleepScheduleDurationMinutes
            ),
            isPlaying: isPlaying
        )
    }

    func updateIdleTimer(playerVisible: Bool) {
        let shouldStayAwake = playerVisible
            && isPlaying
            && settingsStore.appSettings.keepScreenAwakeDuringPlayback

        guard UIApplication.shared.isIdleTimerDisabled != shouldStayAwake else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        logger.info("screenAwake.updated", "Idle timer updated", metadata: [
            "playerVisible": "\(playerVisible)",
            "isPlaying": "\(isPlaying)",
            "settingEnabled": "\(settingsStore.appSettings.keepScreenAwakeDuringPlayback)",
            "idleTimerDisabled": "\(shouldStayAwake)"
        ])
    }

    private func notifyNewEpisodeIfAllowed(_ episode: Episode, subscription: Subscription) {
        guard settingsStore.appSettings.notifyNewEpisodes, subscription.notificationsEnabled else {
            logger.info("notification.skipped", "New episode notification skipped", metadata: [
                "podcast": subscription.title,
                "episode": episode.title,
                "globalEnabled": "\(settingsStore.appSettings.notifyNewEpisodes)",
                "subscriptionEnabled": "\(subscription.notificationsEnabled)"
            ])
            return
        }

        let episodeTitle = episode.title
        let podcastName = subscription.title
        let artworkURL = subscription.artworkURL
        Task {
            await NotificationService.shared.notifyNewEpisode(
                episodeTitle: episodeTitle,
                podcastName: podcastName,
                artworkURL: artworkURL
            )
        }
        logger.info("notification.sent", "New episode notification sent", metadata: [
            "podcast": subscription.title,
            "episode": episode.title
        ])
    }

    private func resourceContext(_ extra: [String: String] = [:]) -> [String: String] {
        var context = [
            "isPlaying": "\(isPlaying)",
            "currentEpisode": currentPlayerEpisode?.title ?? "none",
            "currentTime": "\(Int(currentPlayerTime))",
            "queueCount": "\(downloadedQueue.count)",
            "subscriptionCount": "\(subscriptionStore.subscriptions.count)",
            "activeDownloads": "\(downloadProgress.count)",
            "upNext": upNextEpisode?.title ?? "none"
        ]
        extra.forEach { context[$0.key] = $0.value }
        return context
    }
}


// AI CONTEXT — ListeningHistoryStore: persists per-episode listening log to
// Application Support/Autohop/listening-history.json (max 500 entries, oldest
// dropped). Entries are keyed by episode GUID/URL (historyKey) so the same
// episode re-fetched from a feed merges into one entry. recordProgress() is
// called from AppState playback ticks; mark() sets played/archived status with
// a CompletionKind used later by ShowEngagementAnalyzer ("drifting" stats).
// UI filters out entries with < 60 s listened — that rule lives in the views,
// not here. Value types live in Models/ListeningHistory.swift.
@MainActor
final class ListeningHistoryStore: ObservableObject {
    @Published private(set) var entries: [ListeningHistoryEntry] = []

    private var lastSavedAt: Date?
    private let maxEntries = 500
    /// Record store for cross-device history sync; set by AppState. nil = no sync.
    var syncDatabase: AutohopDatabase?

    private static let fileURL: URL? = {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/listening-history.json")
    }()

    init() {
        load()
    }

    var totalListeningSeconds: TimeInterval {
        entries.reduce(0) { $0 + $1.listenedSeconds }
    }

    func recordProgress(
        episode: Episode,
        podcastTitle: String,
        artworkURL: URL?,
        listenedSeconds: TimeInterval,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?
    ) {
        let key = historyKey(for: episode)
        let now = Date()

        if let index = entries.firstIndex(where: { $0.id == key }) {
            entries[index].episodeID = episode.id
            entries[index].episodeTitle = episode.title
            entries[index].podcastTitle = podcastTitle
            entries[index].artworkURL = artworkURL
            entries[index].publishedAt = episode.publishedAt
            entries[index].durationSeconds = durationSeconds ?? episode.durationSeconds
            entries[index].listenedSeconds += listenedSeconds
            entries[index].lastPositionSeconds = positionSeconds
            entries[index].lastListenedAt = now
            if entries[index].status == .listened {
                entries[index].status = .listened
            }
        } else {
            entries.append(ListeningHistoryEntry(
                id: key,
                subscriptionID: episode.subscriptionID,
                episodeID: episode.id,
                episodeTitle: episode.title,
                podcastTitle: podcastTitle,
                artworkURL: artworkURL,
                publishedAt: episode.publishedAt,
                durationSeconds: durationSeconds ?? episode.durationSeconds,
                listenedSeconds: listenedSeconds,
                lastPositionSeconds: positionSeconds,
                lastListenedAt: now,
                status: .listened
            ))
        }

        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        recordPending(id: key)
        saveThrottled()
    }

    func mark(
        episode: Episode,
        podcastTitle: String,
        artworkURL: URL?,
        status: ListeningHistoryStatus,
        completionKind: CompletionKind? = nil,
        positionSeconds: TimeInterval? = nil
    ) {
        let key = historyKey(for: episode)
        let now = Date()
        let epDuration = episode.durationSeconds
        let pct: Double? = {
            guard let pos = positionSeconds, let dur = epDuration, dur > 0 else { return nil }
            return min(pos / dur, 1.0)
        }()

        if let index = entries.firstIndex(where: { $0.id == key }) {
            entries[index].status = status
            entries[index].podcastTitle = podcastTitle
            entries[index].artworkURL = artworkURL
            entries[index].lastListenedAt = now
            entries[index].completionKind = completionKind
            if let pos = positionSeconds {
                entries[index].listenedDurationSeconds = pos
                entries[index].lastPositionSeconds = pos
            }
            if let dur = epDuration {
                entries[index].episodeDurationSeconds = dur
            }
            entries[index].completionPercent = pct
        } else {
            let pos = positionSeconds ?? 0
            entries.append(ListeningHistoryEntry(
                id: key,
                subscriptionID: episode.subscriptionID,
                episodeID: episode.id,
                episodeTitle: episode.title,
                podcastTitle: podcastTitle,
                artworkURL: artworkURL,
                publishedAt: episode.publishedAt,
                durationSeconds: epDuration,
                listenedSeconds: 0,
                lastPositionSeconds: pos,
                lastListenedAt: now,
                status: status,
                completionKind: completionKind,
                completionPercent: pct,
                listenedDurationSeconds: positionSeconds,
                episodeDurationSeconds: epDuration
            ))
        }
        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        recordPending(id: key)
        save()
    }

    /// Records a changed entry as pending for cross-device sync.
    private func recordPending(id: String) {
        guard let syncDatabase, let entry = entries.first(where: { $0.id == id }) else { return }
        try? syncDatabase.recordHistoryEntry(entry)
    }

    /// Merges a remote history entry with record-level last-write-wins
    /// (the entry with the newer `lastListenedAt` wins the whole record).
    @MainActor
    func applyRemote(_ remote: ListeningHistoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == remote.id }) {
            guard remote.lastListenedAt > entries[index].lastListenedAt else { return } // local newer — keep, stays pending
            entries[index] = remote
        } else {
            entries.append(remote)
        }
        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        try? syncDatabase?.saveSyncedHistoryEntry(remote) // clean — don't re-push
        save()
    }

    func save() {
        guard let url = Self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic])
            lastSavedAt = Date()
        } catch {
            AppLogger.shared.warning("history.saveFailed", "Could not save listening history", metadata: [
                "error": String(describing: error)
            ])
        }
    }

    private func saveThrottled() {
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 10 {
            return
        }
        save()
    }

    private func load() {
        guard let url = Self.fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loadedEntries = try? JSONDecoder().decode([ListeningHistoryEntry].self, from: data)
        else { return }
        entries = loadedEntries.sorted { $0.lastListenedAt > $1.lastListenedAt }
    }

    private func historyKey(for episode: Episode) -> String {
        let subscriptionPrefix = episode.subscriptionID.uuidString
        let trimmedGUID = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGUID.isEmpty {
            return "\(subscriptionPrefix)|guid:\(trimmedGUID)"
        }
        if let publishedAt = episode.publishedAt {
            return "\(subscriptionPrefix)|title-date:\(episode.title.lowercased())|\(Int(publishedAt.timeIntervalSince1970))"
        }
        return "\(subscriptionPrefix)|title-url:\(episode.title.lowercased())|\(episode.audioURL.absoluteString)"
    }
}

