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
// PERF (2026-07-02): currentPlayerTime is a proxy onto the dedicated PlaybackClock
// observable (PERF-1 targeted fix — the 2 Hz tick no longer invalidates every
// AppState observer; only PlayerView's scrubber + MiniPlayerBar observe the clock).
// releaseRadarProfile(for:) is memoized per subscription (PERF-2 — fingerprint-
// validated cache + off-main cold-launch warm-up via warmReleaseRadarProfileCache),
// so the 30 s due-feed poll no longer rebuilds every profile on the main thread.
// RESPONSIBILITIES:
//  - Player state: currentPlayerEpisode / currentPlayerTime / isPlaying;
//    starting playback (startPlayback), auto-advance (handleEpisodeFinished →
//    playNextEpisode), seek, chapter navigation, per-podcast audio settings
//    (speed / vocal boost / trim silence) pushed live into PlaybackEngine.
//    CarPlay is deliberately just another UI surface over these same methods:
//    helpers such as episodeIsCurrent(_:), archiveCurrentEpisodeAndPlayNext(),
//    cyclePlaybackSpeedForCurrentEpisode(), and setPlaybackSpeedForCurrentEpisode(_:)
//    exist to keep CarPlay action routing thin while preserving one shared
//    playback/queue/settings model. CarPlay-only cold launches use
//    resumePlaybackForCarPlayLaunchIfNeeded() to resume the restored episode
//    after the coordinator has installed its first Loading template; normal
//    iPhone launch still restores into a paused state.
//    External `podcast:chapters` are fetched AFTER play() begins (P7):
//    fetchExternalChaptersInBackground runs off the start path (bounded 10 s
//    ephemeral session) so a slow endpoint never delays the first audio frame,
//    then applies chapters live to the store, currentPlayerEpisode, and the
//    engine (PlaybackControlling.updateChapters) iff that episode still plays.
//  - Queue: downloadedQueue = QueueService priority order + manual overrides,
//    MEMOIZED in cachedDownloadedQueue (P3) and invalidated synchronously in the
//    subscriptionStore.objectWillChange sink + the pin didSets.
//    queueOverrideEpisodeIDs = "Play Next" pins (front of queue, in order);
//    queueDemotedEpisodeIDs = "Play Last" pins (end of queue). Pins persist in
//    Application Support/Autohop/queue-pins.json and clear on play/archive.
//    Queue pins and playback-position.json are marked available-after-first-unlock
//    so CarPlay can render queue/progress and archive/play-next while locked.
//  - Downloads: download-first model. maxConcurrentDownloads = 3 with a FIFO
//    pendingDownloadQueue; NWPathMonitor enforces the WiFi/cellular toggles via
//    isDownloadAllowed(). Before the monitor reports its first path (the launch
//    window), gating falls back to the WiFi toggle (BG1) so a "WiFi downloads off"
//    user can't slip a download through; cellular is additionally hard-gated at the
//    transport layer by URLRequest.allowsCellularAccess in DownloadManager.
//    reconcileOrphanedDownloads() repairs DB-vs-filesystem mismatches at launch.
//  - Feed refresh: refreshSubscription fetches feeds conditionally, records
//    per-episode release observations, merges new episodes, and applies per-feed
//    failure backoff in feedFailureBackoffUntil. Auto-downloads discovered by a
//    refresh are deliberately scheduled after the feed merge instead of awaited
//    by the refresh cycle, so slow/stalled audio transfers cannot block manual
//    refresh, due-feed polling, or BGAppRefresh completion. Refresh also updates
//    mutable feed metadata on the Subscription (author + artworkURL) so changed
//    podcast art is picked up by the shared artwork cache after the next
//    successful refresh instead of being frozen at subscribe time.
//    A changed latest episode is treated as a Release Radar "found new release"
//    signal even when the episode had already been seen in history, so manual
//    refreshes that discover out-of-window releases teach the schedule instead
//    of only fixing the immediate feed state.
//    IMPORTANT: keep user-initiated download/play-now paths awaitable, but do
//    not put `await downloadEpisode` back inside the feed-refresh success path.
//    Use scheduleAutoDownloadAfterRefresh/runAutoDownloadAfterRefresh so the
//    scheduled media transfer re-validates subscription state, browse previews,
//    current DownloadFilterSettings eligibility, scheduled-episode staleness,
//    and played/archived status before entering the bounded download queue.
//    Filters look back through the merged feed and choose the newest eligible
//    episode; skipped episodes are also excluded from Release Radar observation
//    learning and schedule prediction. Manual download/play paths bypass filters.
//    Rolling one-item feeds also cancel stale downloads for the replaced latest
//    item immediately, so the new bulletin/show is not blocked by a dead transfer
//    until startup reconciliation.
//    refreshDueSubscriptions and refreshSubscriptionsForBackground implement
//    Release Radar due-feed polling. They ask Models/Subscription.swift for a
//    learned schedule profile, FeedRefreshPrediction, and FeedRefreshPriority;
//    only due feeds are considered, then limited foreground/background slots go
//    to the highest-scoring feeds. Background refresh has 8 total slots and
//    reserves 6 of them for Release Radar pre-window/active/missed-release
//    candidates so daily one-episode shows are checked when iOS grants only a
//    short wake. Capped-out feeds are checkpointed in deferredRefreshBacklog and
//    receive a bounded fairness boost on later cycles so long wakes are drained
//    over multiple runs instead of hammering every overdue feed at once. Manual
//    refresh still ignores due dates and refreshes every eligible feed.
//  - Refresh diagnostics: every all-feed cycle carries a stable refreshCycleID,
//    trigger (manualButton / foregroundTimer / BGAppRefreshTask / BGProcessingTask),
//    and executionContext (manual / foregroundVisible / backgroundRefreshTask /
//    backgroundAudioAlive / backgroundProcessingTask). This deliberately avoids inferring background vs
//    foreground from sceneActive alone: a BG task can join an already-running
//    foreground poll, and background audio can keep the process alive while the
//    UI scene is inactive. Timed/background cycles also log a feed.refreshAll.plan
//    summary plus per-feed score/profile/prediction metadata on
//    feed.refreshAll.itemStart when the diagnostic log is enabled, including the
//    learned release window and observed spread when available. Refresh logs
//    include subscriptionID + a stable feedHash alongside the title so renamed
//    feeds remain traceable. ResourceMonitor's main-thread watchdog also calls
//    resourceContext() only after a suspected hang, adding playback, refresh,
//    queue, scene, download state, and the most recent playback-tick timing to
//    ui.mainThreadHang/recovered logs. playback.tickSlow logs only ticks above
//    the threshold; playback.tickSummary emits a compact rolling summary. These
//    logs are the intended tuning surface for the learned refresh system and
//    main-thread playback pressure.
//  - Auto archive: runAutoArchiveIfNeeded gates a full pass to every 30 min
//    (autoArchiveInterval) unless forced; runAutoArchive applies the three
//    per-podcast rules (after-played delay, inactive timeout, episode limit).
//    The inactive/limit passes skip a subscription's pre-existing back-catalogue
//    (episodes published on/before Subscription.subscribedAt) so subscribing to a
//    show never archives its whole backlog on day one.
//    INACTIVE EPISODES (Pass 2): only episodes with a non-nil Episode.downloadedAt
//    are eligible — episodes that have never been downloaded are fully exempt.
//    The inactivity clock runs from downloadedAt (when the file landed on device)
//    and resets if lastPlayedAt is more recent. publishedAt is NOT used as the
//    clock; an old episode downloaded today gets a fresh inactivity window.
//    EPISODE LIMIT (Pass 3): candidates are episodes in .queued or .downloaded
//    state only — .failed and .notDownloaded states do not consume a slot.
//    This prevents a failed download from causing a working downloaded episode
//    to be archived behind it.
//  - Persistence side: playback positions held in an authoritative in-memory
//    cache (savedPositionsCache, P2) loaded once and mutated through the
//    writeSavedPositions(_:) write-through helper — reads (savedPlaybackTime,
//    restorePlaybackPosition) never re-read/re-decode the file; writes stay
//    immediate (savePlaybackPosition throttled ~10 s) to playback-position.json,
//    keyed by subscription-scoped episode GUID/URL so re-fetched episodes resume
//    correctly without colliding across feeds.
//    Listening history + stats recorded on playback ticks (recordProgress only
//    accrues time; played/archived status transitions go through mark()).
//  - OPML import/export with progress reporting.
//  - First-run onboarding state + helpers (ONBOARDING_PLAN.md): realSubscriptionCount
//    (filters browseDate==nil), isFirstRunNoSubscriptions, checkFirstSubscriptionMilestone
//    (posts .autohopFirstSubscription on the first deliberate single subscribe; silent
//    on bulk import/starter-pack), subscribeToFeedURLs (starter packs), the coach-mark
//    TipCenter (activeTip / requestTip / dismissActiveTip — one-at-a-time, ≤3/session,
//    UserDefaults seen-flags), and onboardingToast. Bootstrap reconciles existing users
//    (real subs ⇒ mark onboarded). NOTE: tip animation is applied by CoachMarkOverlay's
//    .animation(value:) — AppState has no `import SwiftUI`, so never call withAnimation here.
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
//  - AppState.shared is created through bootstrap/sharedOrBootstrap (used by
//    AppDelegate/background tasks and CarPlay-only cold launches). bootstrap() is
//    single-instance: it early-returns an existing `shared` and publishes the new
//    instance the moment it's created, so racing/re-entrant callers (CarPlay cold
//    launch + phone WindowGroup) can never build two AppStates.
//  - All methods assume MainActor; long work hops to detached tasks/services.
// ============================================================================

/// Cached Release Radar profile + the fingerprint that validates it (PERF-2 memo —
/// see AppState.releaseRadarProfile). File-scope (not nested in AppState) on purpose:
/// nested types inherit the class's @MainActor isolation, and the cold-launch
/// warm-up constructs these OFF the main actor in a detached task.
private struct ReleaseRadarProfileCacheEntry {
    var observationCount: Int
    var newestObservationKey: String?
    var filterSettings: DownloadFilterSettings
    var generatedAt: Date
    var profile: FeedScheduleProfile
}

/// Dedicated 2 Hz playback-time publisher (PERF-1 targeted fix). The scrubber tick
/// used to be `@Published` directly on AppState, so every 0.5 s write invalidated
/// EVERY view observing AppState (24 files) for the whole duration of playback.
/// Only the surfaces that genuinely render the ticking time (PlayerView scrubber,
/// MiniPlayerBar progress/remaining) observe this object; everything else observes
/// AppState and no longer wakes on the tick. AppState.currentPlayerTime remains the
/// canonical accessor — it proxies to this clock, so all existing read/write sites
/// behave unchanged. Injected into the environment at the app root alongside
/// AppState (AutohopApp).
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: TimeInterval = 0
}

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
    /// AppSettings.iCloudSyncEnabled is true. History/stats pushes are coalesced
    /// on a ~60 s slow lane inside the engine; flushDeferredSyncPushes(reason:)
    /// is the lifecycle checkpoint that pushes them immediately (pause,
    /// sleep-timer/schedule pause, scene background/resign-active).
    private let cloudSyncEngine: CloudSyncEngine
    static let cloudKitContainerID = "iCloud.com.kevinperry.autohop"
    let downloadActivityStore = DownloadActivityStore()

    // Player state
    @Published var currentPlayerEpisode: Episode? {
        didSet { scheduleUpNextRefresh(reason: "player.currentChanged") }
    }
    /// 2 Hz scrubber time lives on its own observable (PERF-1) so the tick no longer
    /// invalidates every AppState observer; this proxy keeps all existing call sites
    /// working. Views that render the ticking time observe `playbackClock` instead.
    let playbackClock = PlaybackClock()
    var currentPlayerTime: TimeInterval {
        get { playbackClock.time }
        set { playbackClock.time = newValue }
    }
    @Published var isPlaying: Bool = false
    @Published private(set) var upNextEpisode: Episode?
    @Published private var queueOverrideEpisodeIDs: [UUID] = [] {
        didSet { invalidateDownloadedQueueCache() }
    }
    @Published private var queueDemotedEpisodeIDs: [UUID] = [] {
        didSet { invalidateDownloadedQueueCache() }
    }

    // Per-episode download progress (0.0 – 1.0)
    @Published var downloadProgress: [UUID: Double] = [:]
    // Onboarding coach mark currently on screen (nil = none). See OnboardingTip.
    @Published var activeTip: OnboardingTip?
    // Transient onboarding confirmation toast (e.g. after an import). Auto-cleared
    // by the RootView toast overlay.
    @Published var onboardingToast: String?
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

    /// Authoritative in-memory copy of the saved playback positions (P2). Loaded
    /// from disk once on first access and kept the source of truth thereafter, so
    /// repeated reads (e.g. `savedPlaybackTime` called in a loop over the queue
    /// during `playNextEpisode`/`restorePlaybackPosition`) never re-read+re-decode
    /// the whole positions file. Mutators update this and write through to disk.
    /// `nil` = not yet loaded. AppState is `@MainActor` and the sole owner of the
    /// positions file, so this never goes stale behind our back.
    private var savedPositionsCache: SavedPositions?

    // Throttle disk writes: save at most once every 10 s.
    private var positionSaveCounter = 0
    private var hasHandledLaunchPlayback = false
    private var activeRefreshCycle: Task<Bool, Never>?
    private var activeRefreshCycleDiagnostics: RefreshCycleDiagnostics?
    private var deferredRefreshBacklog: [UUID: DeferredRefreshBacklogEntry] = [:]
    private var suppressUpNextRefresh = false
    private var upNextRefreshTask: Task<Void, Never>?
    private var lastPlaybackTickDiagnostics: PlaybackTickDiagnostics?
    private var playbackTickSummary = PlaybackTickSummary()
    private var feedFailureBackoffUntil: [UUID: Date] = [:]
    private var supersededDownloadCancellationIDs = Set<UUID>()
    private var cancellables = Set<AnyCancellable>()
    private var historyTrackingEpisodeID: UUID?
    private var historyTrackingLastTime: TimeInterval?

    // MARK: - Computed queue

    /// Memoized result of `downloadedQueue` (P3). The underlying filter+sort over
    /// every subscription is O(n log n) and the property is read many times per UI
    /// update (badge, resourceContext, up-next refresh, …). Invalidated whenever
    /// the subscriptions change (subscriptionStore.objectWillChange) or a queue pin
    /// mutates (the @Published pin didSets). nil = needs recompute.
    private var cachedDownloadedQueue: [Episode]?

    var downloadedQueue: [Episode] {
        if let cachedDownloadedQueue { return cachedDownloadedQueue }
        let computed = orderedQueueWithOverrides(
            queueService.downloadedQueue(from: subscriptionStore.subscriptions)
        )
        cachedDownloadedQueue = computed
        return computed
    }

    private func invalidateDownloadedQueueCache() {
        cachedDownloadedQueue = nil
    }

    var nextPlayableEpisode: Episode? {
        downloadedQueue.first
    }

    // MARK: - Onboarding / first-run

    /// Count of real (non-browse) subscriptions. Browse/preview subs created by
    /// opening a Podcast Detail page (browseDate != nil) are invisible and must
    /// not count as "the user has subscribed". See ONBOARDING_PLAN.md.
    var realSubscriptionCount: Int {
        subscriptionStore.subscriptions.filter { $0.browseDate == nil }.count
    }

    /// True for a brand-new user who hasn't passed Welcome and has no real
    /// subscriptions — the signal RootView uses to route into the first-run flow.
    var isFirstRunNoSubscriptions: Bool {
        !settingsStore.appSettings.hasCompletedWelcome && realSubscriptionCount == 0
    }

    /// Fires the first-subscription milestone exactly once. A single deliberate
    /// subscribe (count == 1) posts `.autohopFirstSubscription` for the "You're
    /// all set" moment; a bulk OPML import (count > 1) flips the flag silently.
    private func checkFirstSubscriptionMilestone() {
        guard !settingsStore.appSettings.hasSubscribedFirstShow else { return }
        let realSubs = subscriptionStore.subscriptions.filter { $0.browseDate == nil }
        guard !realSubs.isEmpty else { return }
        settingsStore.appSettings.hasSubscribedFirstShow = true
        if realSubs.count == 1 {
            NotificationCenter.default.post(name: .autohopFirstSubscription, object: realSubs[0].id)
        }
    }

    // MARK: - Onboarding tips (coach marks)

    private var tipsShownThisSession = 0
    private let maxTipsPerSession = 3

    /// Surfaces a coach mark the first time a view asks for it. Enforces the
    /// policy: one visible at a time, never re-shown once seen, and at most
    /// `maxTipsPerSession` per launch (the rest surface in later sessions).
    /// Safe to call from `onAppear` repeatedly — unmet conditions are no-ops.
    func requestTip(_ tip: OnboardingTip) {
        guard activeTip == nil else { return }
        guard !tip.isSeen else { return }
        guard tipsShownThisSession < maxTipsPerSession else { return }
        // Animation is applied by CoachMarkOverlay (.animation(value:)); AppState
        // stays free of SwiftUI so it doesn't need `withAnimation` here.
        activeTip = tip
    }

    /// Dismisses the active tip via "Got it" — marks it seen so it never returns.
    func dismissActiveTip() {
        guard let tip = activeTip else { return }
        tip.markSeen()
        tipsShownThisSession += 1
        activeTip = nil
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
    private let backgroundReleaseRadarReservedSlots = 6
    private let backgroundReleaseRadarProtectedStates: Set<FeedRefreshWindowState> = [
        .preWindow,
        .activeWindow,
        .missedRelease
    ]
    private let foregroundRefreshFeedLimit = 12
    private let foregroundRefreshCapBypassStates: Set<FeedRefreshWindowState> = [.activeWindow, .preWindow]
    private let refreshDeferralScoreBoostPerCycle = 12.0
    private let refreshDeferralAgeBoostPerHour = 2.0
    private let refreshDeferralMaxScoreBoost = 40.0
    private let playbackTickSlowThresholdMs = 120.0
    private let playbackTickSummarySampleInterval = 120

    private enum FeedRefreshTrigger: String, Sendable {
        case manualButton
        case foregroundTimer
        case backgroundRefreshTask = "BGAppRefreshTask"
        case backgroundProcessingTask = "BGProcessingTask"
    }

    private enum FeedRefreshExecutionContext: String, Sendable {
        case manual
        case foregroundVisible
        case backgroundRefreshTask
        case backgroundAudioAlive
        case backgroundProcessingTask
    }

    private struct RefreshCycleDiagnostics: Sendable {
        var cycleID: String
        var reason: String
        var trigger: FeedRefreshTrigger
        var executionContext: FeedRefreshExecutionContext
        var startSceneActive: Bool
        var backgroundTaskIdentifier: String?

        func metadata(currentSceneActive: Bool) -> [String: String] {
            [
                "refreshCycleID": cycleID,
                "refreshReason": reason,
                "trigger": trigger.rawValue,
                "executionContext": executionContext.rawValue,
                "startSceneActive": "\(startSceneActive)",
                "currentSceneActive": "\(currentSceneActive)",
                "backgroundTaskIdentifier": backgroundTaskIdentifier ?? "none"
            ]
        }
    }

    private struct PlaybackTickStageTiming {
        var name: String
        var durationMs: Double
    }

    private struct PlaybackTickDiagnostics {
        var occurredAt: Date
        var episode: String
        var podcast: String
        var currentTime: Int
        var totalMs: Double
        var dominantStage: String
        var dominantStageMs: Double
        var stages: [PlaybackTickStageTiming]
        var positionSaved: Bool
        var statsCredited: Bool

        var stageSummary: String {
            stages
                .map { "\($0.name)=\(Int($0.durationMs.rounded()))" }
                .joined(separator: ",")
        }

        func metadata() -> [String: String] {
            [
                "episode": episode,
                "podcast": podcast,
                "currentTime": "\(currentTime)",
                "totalMs": String(format: "%.1f", totalMs),
                "dominantStage": dominantStage,
                "dominantStageMs": String(format: "%.1f", dominantStageMs),
                "stageMs": stageSummary,
                "positionSaved": "\(positionSaved)",
                "statsCredited": "\(statsCredited)"
            ]
        }
    }

    private struct PlaybackTickSummary {
        var samples = 0
        var slowSamples = 0
        var totalMs = 0.0
        var maxMs = 0.0
        var maxStage = "none"

        mutating func record(_ diagnostics: PlaybackTickDiagnostics, slowThresholdMs: Double) {
            samples += 1
            totalMs += diagnostics.totalMs
            if diagnostics.totalMs >= slowThresholdMs {
                slowSamples += 1
            }
            if diagnostics.totalMs > maxMs {
                maxMs = diagnostics.totalMs
                maxStage = diagnostics.dominantStage
            }
        }

        mutating func reset() {
            samples = 0
            slowSamples = 0
            totalMs = 0
            maxMs = 0
            maxStage = "none"
        }

        func metadata() -> [String: String] {
            [
                "samples": "\(samples)",
                "slowSamples": "\(slowSamples)",
                "averageMs": samples > 0 ? String(format: "%.1f", totalMs / Double(samples)) : "0.0",
                "maxMs": String(format: "%.1f", maxMs),
                "maxStage": maxStage
            ]
        }
    }

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
        subscriptionStore.nowPlayingEpisodeSyncKeyProvider = { [weak self] in
            guard let episode = self?.playbackEngine.currentEpisode else { return nil }
            return EpisodeSyncState.syncKey(subscriptionID: episode.subscriptionID, guid: episode.guid)
        }
        // New/activated subscriptions seed their playback settings from the
        // global default panel; browse feeds resolve it live (effectivePreference).
        subscriptionStore.defaultPlaybackPreferenceProvider = { [weak self] in
            self?.settingsStore.appSettings.defaultPlaybackPreference ?? .default
        }
        subscriptionStore.defaultAutoArchiveSettingsProvider = { [weak self] in
            self?.settingsStore.appSettings.defaultAutoArchiveSettings ?? .default
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
                // Drop the memoized queue synchronously (P3): SubscriptionStore
                // publishes visible saves after mutating in memory, so the next
                // read recomputes from the updated subscriptions.
                self?.invalidateDownloadedQueueCache()
                Task { @MainActor in
                    guard let self else { return }
                    self.scheduleUpNextRefresh(reason: "state.changed")
                    self.checkFirstSubscriptionMilestone()
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
                    // didSet hasn't run yet on objectWillChange — sync after the value
                    // lands. syncDiagnosticLogging() reads appSettings too, so it must
                    // be deferred as well or it acts on the previous value (enabling
                    // diagnostics wouldn't take effect until the next settings change).
                    Task { @MainActor in
                        guard let self else { return }
                        self.syncDiagnosticLogging()
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
        // Network path not yet known (NWPathMonitor hasn't reported its first update
        // at launch, or there is no connectivity). Honour the Wi-Fi toggle here: a
        // user who has turned OFF Wi-Fi downloads must not have one slip through this
        // pre-monitor window. Default users (Wi-Fi downloads on) are unaffected, and
        // cellular is independently enforced at the transport layer via
        // URLRequest.allowsCellularAccess (DownloadManager.startDownloadTask), so
        // gating on just the Wi-Fi toggle is sufficient here (BG1).
        guard let path = latestNetworkPath, path.status == .satisfied else {
            return settings.downloadOverWifi
        }
        if path.usesInterfaceType(.wifi) && !settings.downloadOverWifi { return false }
        if path.usesInterfaceType(.cellular) && !settings.downloadOverCellular { return false }
        return true
    }

    static func bootstrap() -> AppState {
        // Re-entrancy / single-instance guard. bootstrap() runs on the @MainActor and is
        // synchronous, so two *concurrent* callers can't interleave — but a caller reached
        // from within bootstrap's own setup (or any future `await` added before the shared
        // assignment) could otherwise build a SECOND AppState. Returning the existing
        // instance here, and publishing `shared` the instant it exists (below), guarantees
        // one instance no matter how many sharedOrBootstrap() callers race (e.g. a CarPlay
        // cold-launch scene and the phone WindowGroup both bootstrapping at startup).
        if let shared { return shared }

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
        // Publish immediately, before the remaining setup, so any re-entrant
        // sharedOrBootstrap() during bootstrap resolves to THIS instance.
        AppState.shared = state

        // Episode completion
        playbackEngine.onEpisodeFinished = { [weak state] episode in
            Task { @MainActor in await state?.handleEpisodeFinished(episode) }
        }

        // Scrubber + Now Playing time sync (fires every 0.5 s)
        playbackEngine.onTimeUpdate = { [weak state] time in
            Task { @MainActor in
                guard let state else { return }
                let tickStartedAt = CFAbsoluteTimeGetCurrent()
                var stageTimings: [PlaybackTickStageTiming] = []
                var positionSaved = false
                var statsCredited = false
                var tickEpisode: Episode?
                var tickSubscription: Subscription?

                func measure(_ name: String, _ work: () -> Void) {
                    let startedAt = CFAbsoluteTimeGetCurrent()
                    work()
                    let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    stageTimings.append(PlaybackTickStageTiming(name: name, durationMs: durationMs))
                }

                measure("timeState") {
                    state.currentPlayerTime = time
                    tickEpisode = state.currentPlayerEpisode
                    if let ep = tickEpisode {
                        tickSubscription = state.subscriptionStore.subscription(id: ep.subscriptionID)
                    }
                }

                measure("sleepTimers") {
                    state.sleepTimerService.tick()

                    // Manual Sleep Timer overrides the Sleep Schedule for this session.
                    if state.sleepTimerService.isActive {
                        state.sleepScheduleService.suspendForSession()
                    }
                    state.sleepScheduleService.tick(isPlaying: state.isPlaying)
                }

                measure("nowPlaying") {
                    // Update lock-screen position (cheap — just updates two keys)
                    if let sub = tickSubscription {
                        NowPlayingService.shared.updateTime(
                            currentTime: time,
                            isPlaying: state.isPlaying,
                            speed: state.effectiveSpeed(for: sub)
                        )
                    }
                }

                measure("historyProgress") {
                    state.recordListeningProgress(at: time)
                }

                measure("positionSave") {
                    // Persist position every ~10 s (every 20th call at 0.5 s interval)
                    state.positionSaveCounter += 1
                    if state.positionSaveCounter % 20 == 0 {
                        state.savePlaybackPosition()
                        positionSaved = true
                    }
                }

                measure("stats") {
                    // Accumulate playback stats every tick (0.5 s interval).
                    // tickTime() fires whenever an episode is loaded, including while
                    // paused — only credit listening time when audio is actually playing.
                    if state.isPlaying,
                       tickEpisode != nil,
                       let sub = tickSubscription {
                        state.listeningStatsStore.addListeningTime(
                            0.5,
                            speed: state.effectiveSpeed(for: sub),
                            subscriptionID: sub.id,
                            showTitle: sub.title
                        )
                        statsCredited = true
                    }
                }

                state.recordPlaybackTickDiagnostics(
                    startedAt: tickStartedAt,
                    playbackTime: time,
                    episode: tickEpisode,
                    subscription: tickSubscription,
                    stages: stageTimings,
                    positionSaved: positionSaved,
                    statsCredited: statsCredited
                )
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
                // Background downloads are the bulk of auto-downloads — record
                // their actual on-disk size against today's download-data stat too.
                let downloadedBytes = ((try? FileManager.default.attributesOfItem(atPath: localFileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                state.listeningStatsStore.recordDownload(bytes: downloadedBytes)
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
                // Coalesce UI publishes: DownloadManager already throttles to ~1/s per
                // task, but with several concurrent downloads each tick still fired an
                // AppState-wide @Published invalidation (downloadProgress) PLUS an
                // activity-store publish — several whole-tree re-evals per second,
                // which showed as scroll jank on the Downloads page. Progress bars
                // don't need sub-1% fidelity, so skip publishes until the fraction has
                // moved ≥1% (completion always publishes).
                let lastFraction = state.downloadProgress[episodeID] ?? -1
                guard fraction >= 1.0 || abs(fraction - lastFraction) >= 0.01 else { return }
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
                // Pause checkpoint: flush throttled stats to disk + sync DB, then
                // push any coalesced history/stats sync rows (the scene usually
                // resigned long before a sleep-timer fire, so this is the only
                // checkpoint that catches the tail of the session).
                state.listeningStatsStore.save()
                state.flushDeferredSyncPushes(reason: "sleepTimer.pause")
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
                state.flushDeferredSyncPushes(reason: "sleepSchedule.asleep")
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
            },
            onPlaybackRateChange: { rate in
                Task { @MainActor in
                    state.setPlaybackSpeedForCurrentEpisode(Double(rate))
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
        // Onboarding reconciliation (ONBOARDING_PLAN.md): an existing user who
        // already has real (non-browse) subscriptions has effectively completed
        // onboarding — never show them the first-run experience. Idempotent and
        // only ever flips false→true, so a user who later unsubscribes from
        // everything still won't see Welcome again. A brand-new install has zero
        // subscriptions at bootstrap, so its flags correctly stay false.
        if state.realSubscriptionCount > 0 && !state.settingsStore.appSettings.hasCompletedWelcome {
            state.settingsStore.appSettings.hasCompletedWelcome = true
            state.settingsStore.appSettings.hasSubscribedFirstShow = true
            state.settingsStore.appSettings.hasPlayedFirstEpisode = true
            state.logger.info("onboarding.reconcile", "Existing user with subscriptions marked onboarded")
        }
        state.syncDiagnosticLogging()
        state.logger.info("app.bootstrap", "App state bootstrapped")
        state.restorePlaybackPosition()
        state.loadQueuePins()
        state.startForegroundPolling()
        state.startResourceMonitoring()
        // Warm the Release Radar profile cache off-main so the poller's first tick
        // (30 s after launch) doesn't build every profile on the main thread.
        state.warmReleaseRadarProfileCache()
        Task { @MainActor in
            await state.runAutoArchiveIfNeeded(reason: "app.startup")
        }
        Task { @MainActor in
            await state.reconcileOrphanedDownloads()
        }
        // `AppState.shared` was already published right after creation (above) so a
        // re-entrant bootstrap can't create a second instance.
        Task { @MainActor in
            let badgeCount = state.settingsStore.appSettings.showQueueBadge ? state.downloadedQueue.count : 0
            NotificationService.shared.updateBadge(count: badgeCount)
        }
        return state
    }

    static func sharedOrBootstrap() -> AppState {
        if let shared {
            return shared
        }
        return bootstrap()
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
            flushDeferredSyncPushes(reason: "playback.pause")
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

    func resumePlaybackForCarPlayLaunchIfNeeded() async {
        guard !hasHandledLaunchPlayback else { return }
        hasHandledLaunchPlayback = true

        if playbackEngine.isPlaying {
            isPlaying = true
            if let episode = currentPlayerEpisode,
               let subscription = subscriptionStore.subscription(id: episode.subscriptionID) {
                playbackEngine.updatePlaybackSpeed(effectiveSpeed(for: subscription))
                NowPlayingService.shared.updateTime(
                    currentTime: currentPlayerTime,
                    isPlaying: true,
                    speed: effectiveSpeed(for: subscription)
                )
            }
            logger.info("player.carplayLaunch", "Playback already active on CarPlay launch", metadata: [
                "episode": currentPlayerEpisode?.title ?? "none"
            ])
            return
        }

        if let episode = currentPlayerEpisode {
            logger.info("player.carplayLaunch", "Resuming restored episode from CarPlay launch", metadata: [
                "episode": episode.title,
                "resume": "\(Int(currentPlayerTime))"
            ])
            if await startPlayback(episode: episode, resumeFrom: currentPlayerTime) {
                return
            }
        }

        logger.info("player.carplayLaunch", "No restored episode available for CarPlay launch")
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

    func archiveCurrentEpisodeAndPlayNext() async {
        guard let episode = currentPlayerEpisode else { return }
        await archiveEpisodeAndPlayNext(episode)
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
            // Record actual on-disk size against today's download-data stat. Falls
            // back to the feed-declared size if the file can't be stat'd.
            let downloadedBytes = ((try? FileManager.default.attributesOfItem(atPath: localFileURL.path))?[.size] as? NSNumber)?.int64Value
                ?? episode.fileSizeBytes ?? 0
            listeningStatsStore.recordDownload(bytes: downloadedBytes)
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
                if supersededDownloadCancellationIDs.remove(episode.id) != nil {
                    downloadProgress.removeValue(forKey: episode.id)
                    downloadActivityStore.remove(episodeID: episode.id)
                    logger.info("download.pausedSuperseded", "Superseded rolling-feed download pause ignored cleanly", metadata: [
                        "episode": episode.title,
                        "podcast": podcastTitle,
                        "mediaKind": episode.mediaKind.rawValue
                    ])
                    return
                }
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
                if supersededDownloadCancellationIDs.remove(episode.id) != nil {
                    downloadProgress.removeValue(forKey: episode.id)
                    downloadActivityStore.remove(episodeID: episode.id)
                    logger.info("download.cancelledSuperseded", "Superseded rolling-feed download cancelled cleanly", metadata: [
                        "episode": episode.title,
                        "podcast": podcastTitle,
                        "mediaKind": episode.mediaKind.rawValue
                    ])
                    return
                }
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

    func cyclePlaybackSpeedForCurrentEpisode() {
        guard !sharedListeningActive,
              let episode = currentPlayerEpisode,
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID),
              !PlaybackPreference.speedOptions.isEmpty
        else { return }

        let currentSpeed = subscription.playbackPreference.speed
        let currentIndex = PlaybackPreference.speedOptions.firstIndex { abs($0 - currentSpeed) < 0.01 }
            ?? PlaybackPreference.speedOptions.startIndex
        let nextIndex = PlaybackPreference.speedOptions.index(after: currentIndex)
        let nextSpeed = nextIndex == PlaybackPreference.speedOptions.endIndex
            ? PlaybackPreference.speedOptions[PlaybackPreference.speedOptions.startIndex]
            : PlaybackPreference.speedOptions[nextIndex]
        updatePlaybackSpeed(for: subscription.id, speed: nextSpeed)
    }

    func setPlaybackSpeedForCurrentEpisode(_ speed: Double) {
        guard !sharedListeningActive,
              let episode = currentPlayerEpisode,
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID),
              !PlaybackPreference.speedOptions.isEmpty
        else { return }

        let normalizedSpeed = PlaybackPreference.speedOptions.min { lhs, rhs in
            abs(lhs - speed) < abs(rhs - speed)
        } ?? speed
        updatePlaybackSpeed(for: subscription.id, speed: normalizedSpeed)
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
            // First-run: the user has now actually played something. Clears the
            // re-entry routing rule that opens new users on Subscriptions until
            // they've listened (ONBOARDING_PLAN.md Phase 2/4b).
            if !settingsStore.appSettings.hasPlayedFirstEpisode {
                settingsStore.appSettings.hasPlayedFirstEpisode = true
            }
            positionSaveCounter = 0
            historyTrackingEpisodeID = playableEpisode.id
            historyTrackingLastTime = currentPlayerTime
            playbackMessage = nil

            // Chapters from an external `podcast:chapters` feed are fetched AFTER
            // playback has started (P7) so a slow/hung endpoint never delays the
            // first audio frame; they are applied live to the store, the now-
            // playing episode, and the engine (chapter-skip) once they arrive.
            if playableEpisode.chapters.isEmpty, let chaptersURL = playableEpisode.externalChaptersURL {
                fetchExternalChaptersInBackground(
                    url: chaptersURL,
                    episodeID: playableEpisode.id,
                    subscriptionID: subscription.id,
                    filter: subscription.chapterFilter
                )
            }

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
        resourceMonitor.logSnapshot(
            reason: "feed.refresh.before",
            context: resourceContext(refreshFeedMetadata(for: subscription, includeURL: false))
        )
        logger.info("feed.refresh", "Refreshing podcast feed", metadata: refreshFeedMetadata(for: subscription))
        let previouslyKnownEpisodeKeys = Set(subscription.episodes.map(RefreshStats.releaseObservationKey(for:)))
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
                logger.info(
                    "feed.notModified",
                    "Feed unchanged (304)",
                    metadata: refreshFeedMetadata(for: subscription, includeURL: false)
                )
                return
            }

            let oldLatestGUID = subscription.latestEpisode?.guid
            var stats = subscription.refreshStats
            stats.etag = newValidators.etag
            stats.lastModified = newValidators.lastModified
            let currentFilterSettings = subscriptionStore.subscription(id: subscription.id)?.downloadFilterSettings
                ?? subscription.downloadFilterSettings
            let newlyObservedEpisodes = stats.recordEpisodeObservations(
                result.episodes,
                previouslyKnownEpisodeKeys: previouslyKnownEpisodeKeys,
                downloadFilterSettings: currentFilterSettings
            )
            let newEligibleEpisode = result.episodes.first { episode in
                !previouslyKnownEpisodeKeys.contains(RefreshStats.releaseObservationKey(for: episode))
                    && currentFilterSettings.evaluation(for: episode).isIncluded
            }
            let latestChanged = oldLatestGUID != result.latestEpisode.guid
            let latestChangedEligible = latestChanged && currentFilterSettings.evaluation(for: result.latestEpisode).isIncluded
            let releaseSignalPublishedAt = newEligibleEpisode?.publishedAt
                ?? (latestChangedEligible ? result.latestEpisode.publishedAt : nil)
            stats.recordFetch(
                foundNewEpisode: newEligibleEpisode != nil || latestChangedEligible,
                publishedAt: releaseSignalPublishedAt
            )
            subscriptionStore.updateRefreshStats(subscriptionID: subscription.id, stats: stats)
            let oldLatestWasDownloaded = subscription.latestEpisode?.downloadState == .downloaded

            if let old = subscription.latestEpisode,
               latestChanged,
               currentPlayerEpisode?.id != old.id {
                if old.localFileURL != nil {
                    logger.info("feed.cleanupOldLatest", "Deleting old latest episode after new feed item", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                        "episode": old.title,
                    ]))
                    try? await downloadManager.deleteLocalFile(for: old)
                    subscriptionStore.markEpisodeNotDownloaded(subscriptionID: old.subscriptionID, episodeID: old.id)
                }
                await cleanupSupersededRollingLatestDownloadIfNeeded(
                    oldLatest: old,
                    newLatest: result.latestEpisode,
                    feedEpisodeCount: result.episodes.count,
                    subscription: subscription
                )
            }

            logger.info("feed.refreshMerge", "Merging refreshed feed episodes", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                "oldLatest": oldLatestGUID ?? "none",
                "newLatest": result.latestEpisode.guid,
                "episodeCount": "\(result.episodes.count)",
                "newlyObservedEpisodes": "\(newlyObservedEpisodes)",
                "latestChanged": "\(latestChanged)",
                "releaseSignal": "\(newEligibleEpisode != nil || latestChangedEligible)"
            ]))
            subscriptionStore.updateEpisodes(
                subscriptionID: subscription.id,
                episodes: result.episodes
            )
            if let artworkURL = result.artworkURL {
                subscriptionStore.updateArtworkURL(subscriptionID: subscription.id, artworkURL: artworkURL)
            }
            subscriptionStore.updateAuthor(subscriptionID: subscription.id, author: result.author)
            subscriptionStore.updateDescription(subscriptionID: subscription.id, description: result.description)
            subscriptionStore.updateCategories(subscriptionID: subscription.id, categories: result.categories)
            subscriptionStore.updateIsExplicit(subscriptionID: subscription.id, isExplicit: result.isExplicit)
            // Browse-only previews (opened from the Discover page) are NOT real
            // subscriptions and must never auto-download or enter the queue. The
            // Podcast Detail page calls refreshSubscription on a returning browse
            // preview purely to refresh the displayed episode list — so stop here,
            // after the display merge, before the download pipeline. Without this a
            // preview's latest episode gets downloaded and appended to the queue on
            // open (the reported "Play Last on load" bug).
            if subscriptionStore.subscription(id: subscription.id)?.browseDate != nil {
                logger.info(
                    "feed.refresh",
                    "Skipping auto-download for browse preview",
                    metadata: refreshFeedMetadata(for: subscription, includeURL: false)
                )
                return
            }
            if refreshUpNextAfterMerge {
                scheduleUpNextRefresh(reason: "feed.refresh.\(subscription.title)")
            }
            let updatedSubscription = subscriptionStore.subscription(id: subscription.id)
            guard let autoDownloadEpisode = updatedSubscription.flatMap({ newestAutoDownloadCandidate(in: $0) }) else {
                logger.info(
                    "feed.refresh",
                    "No eligible episode found for auto-download",
                    metadata: refreshFeedMetadata(for: subscription, includeURL: false)
                )
                return
            }
            guard result.latestEpisode.guid != oldLatestGUID || oldLatestWasDownloaded == false else {
                logger.info(
                    "feed.refresh",
                    "No new download needed",
                    metadata: refreshFeedMetadata(for: subscription, includeURL: false)
                )
                return
            }
            scheduleAutoDownloadAfterRefresh(
                episode: autoDownloadEpisode,
                subscriptionID: subscription.id,
                podcastTitle: result.subscriptionTitle,
                refreshUpNextAfterMerge: refreshUpNextAfterMerge
            )
            logger.info("feed.refresh", "Feed refresh completed", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                "podcast": result.subscriptionTitle,
                "episodeCount": "\(result.episodes.count)",
                "autoDownload": "scheduled"
            ]))
            resourceMonitor.logSnapshot(reason: "feed.refresh.afterSuccess", context: resourceContext([
                "podcast": result.subscriptionTitle,
                "subscriptionID": subscription.id.uuidString,
                "feedHash": refreshFeedHash(for: subscription.feedURL),
                "episodeCount": "\(result.episodes.count)"
            ]))
        } catch {
            if isCancellationError(error) {
                logger.info(
                    "feed.refreshCancelled",
                    "Feed refresh cancelled",
                    metadata: refreshFeedMetadata(for: subscription, includeURL: false)
                )
                return
            }
            // Requests stranded by app suspension surface as timeouts or dropped
            // connections once the app wakes. Those say nothing about the feed's
            // health — retry on the normal schedule instead of backing off.
            if isTransientTransportError(error), UIApplication.shared.applicationState != .active {
                logger.info("feed.refreshDeferred", "Feed refresh dropped while app inactive — no backoff applied", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                    "error": String(describing: error)
                ]))
                return
            }
            let backoffUntil = Date().addingTimeInterval(feedFailureBackoffInterval)
            feedFailureBackoffUntil[subscription.id] = backoffUntil
            logger.error("feed.refreshFailed", "Feed refresh failed", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                "error": String(describing: error),
                "backoffUntil": backoffUntil.formatted(date: .omitted, time: .standard)
            ]))
            resourceMonitor.logSnapshot(
                reason: "feed.refresh.afterFailure",
                context: resourceContext(refreshFeedMetadata(for: subscription, includeURL: false)),
                force: true
            )
        }
    }

    private func cleanupSupersededRollingLatestDownloadIfNeeded(
        oldLatest: Episode,
        newLatest: Episode,
        feedEpisodeCount: Int,
        subscription: Subscription
    ) async {
        guard feedEpisodeCount == 1 else { return }
        guard oldLatest.guid != newLatest.guid else { return }

        let hadPendingQueueEntry = pendingDownloadQueue.contains { $0.episode.id == oldLatest.id }
        let hadTrackedDownload = downloadActivityStore.activeActivities.contains { $0.episodeID == oldLatest.id }
        let hadProgress = downloadProgress[oldLatest.id] != nil
        let shouldCancel = oldLatest.downloadState == .queued
            || oldLatest.downloadState == .downloading
            || hadPendingQueueEntry
            || hadTrackedDownload
            || hadProgress
        guard shouldCancel else { return }

        supersededDownloadCancellationIDs.insert(oldLatest.id)
        downloadManager.cancelDownload(episodeID: oldLatest.id)
        pendingDownloadQueue.removeAll { $0.episode.id == oldLatest.id }
        downloadProgress.removeValue(forKey: oldLatest.id)
        downloadActivityStore.remove(episodeID: oldLatest.id)
        subscriptionStore.markEpisodeNotDownloaded(
            subscriptionID: oldLatest.subscriptionID,
            episodeID: oldLatest.id
        )
        refreshDownloadedActivities()

        logger.info("feed.cleanupSupersededLatest", "Cancelled superseded one-item feed download", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
            "oldEpisode": oldLatest.title,
            "oldEpisodeID": oldLatest.id.uuidString,
            "oldDownloadState": oldLatest.downloadState.rawValue,
            "newEpisode": newLatest.title,
            "newEpisodeID": newLatest.id.uuidString,
            "feedEpisodeCount": "\(feedEpisodeCount)",
            "hadPendingQueueEntry": "\(hadPendingQueueEntry)",
            "hadTrackedDownload": "\(hadTrackedDownload)",
            "hadProgress": "\(hadProgress)"
        ]))
    }

    private func scheduleAutoDownloadAfterRefresh(
        episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String,
        refreshUpNextAfterMerge: Bool
    ) {
        logger.info("feed.autoDownloadScheduled", "Auto-download scheduled after feed refresh", metadata: [
            "podcast": podcastTitle,
            "episode": episode.title,
            "episodeID": episode.id.uuidString
        ])
        Task { @MainActor [weak self] in
            await self?.runAutoDownloadAfterRefresh(
                episode: episode,
                subscriptionID: subscriptionID,
                podcastTitle: podcastTitle,
                refreshUpNextAfterMerge: refreshUpNextAfterMerge
            )
        }
    }

    private func runAutoDownloadAfterRefresh(
        episode: Episode,
        subscriptionID: UUID,
        podcastTitle: String,
        refreshUpNextAfterMerge: Bool
    ) async {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            logger.info("feed.autoDownloadSkipped", "Auto-download skipped because subscription no longer exists", metadata: [
                "podcast": podcastTitle,
                "episode": episode.title,
                "episodeID": episode.id.uuidString
            ])
            return
        }
        guard subscription.browseDate == nil else {
            logger.info("feed.autoDownloadSkipped", "Auto-download skipped for browse preview", metadata: [
                "podcast": podcastTitle,
                "episode": episode.title,
                "episodeID": episode.id.uuidString
            ])
            return
        }
        guard let candidateEpisode = newestAutoDownloadCandidate(in: subscription),
              candidateEpisode.guid == episode.guid
        else {
            logger.info("feed.autoDownloadSkipped", "Auto-download skipped because the scheduled episode is no longer eligible", metadata: [
                "podcast": subscription.title,
                "scheduledEpisode": episode.title,
                "scheduledEpisodeID": episode.id.uuidString
            ])
            return
        }

        logger.info("feed.autoDownloadStart", "Starting auto-download after feed refresh", metadata: [
            "podcast": subscription.title,
            "episode": candidateEpisode.title,
            "episodeID": candidateEpisode.id.uuidString
        ])
        await enforceEpisodeLimitBeforeDownload(subscriptionID: subscriptionID)
        let targetEpisode = subscriptionStore.subscription(id: subscriptionID)
            .flatMap { newestAutoDownloadCandidate(in: $0) } ?? candidateEpisode
        await downloadEpisode(
            targetEpisode,
            subscriptionID: subscriptionID,
            podcastTitle: podcastTitle,
            showCompletionMessage: false
        )
        if refreshUpNextAfterMerge {
            scheduleUpNextRefresh(reason: "feed.download.\(podcastTitle)")
        }
    }

    private func newestAutoDownloadCandidate(in subscription: Subscription) -> Episode? {
        subscription.episodes
            .filter { episode in
                episode.playedState != .played
                    && episode.playedState != .archived
                    && episode.downloadState != .downloaded
                    && episode.downloadState != .queued
                    && episode.downloadState != .downloading
                    && subscription.downloadFilterSettings.evaluation(for: episode).isIncluded
            }
            .sorted {
                ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }
            .first
    }

    private func newestReleaseRadarEligibleEpisode(in subscription: Subscription) -> Episode? {
        subscription.episodes
            .filter { subscription.downloadFilterSettings.evaluation(for: $0).isIncluded }
            .sorted {
                ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }
            .first
    }

    /// Manual refresh (pull-to-refresh): every feed, ignoring due dates.
    func refreshAllSubscriptions(includeBackoffFeeds: Bool = false) async {
        await refreshSubscriptions(
            reason: "manual",
            trigger: .manualButton,
            executionContext: .manual,
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
            trigger: .foregroundTimer,
            executionContext: isAppForeground ? .foregroundVisible : .backgroundAudioAlive,
            maxSubscriptions: foregroundRefreshFeedLimit,
            capBypassStates: foregroundRefreshCapBypassStates,
            includeBackoffFeeds: false,
            onlyDueFeeds: true
        )
    }

    @discardableResult
    func refreshSubscriptionsForBackground(
        taskIdentifier: String = BackgroundTaskCoordinator.feedRefreshIdentifier
    ) async -> Bool {
        logger.info("background.refreshRequested", "Background app refresh requested feed refresh cycle", metadata: [
            "identifier": taskIdentifier,
            "sceneActive": "\(isSceneActive)",
            "trigger": FeedRefreshTrigger.backgroundRefreshTask.rawValue,
            "executionContext": FeedRefreshExecutionContext.backgroundRefreshTask.rawValue
        ])
        return await refreshSubscriptions(
            reason: "background",
            trigger: .backgroundRefreshTask,
            executionContext: .backgroundRefreshTask,
            maxSubscriptions: backgroundRefreshFeedLimit,
            protectedStates: backgroundReleaseRadarProtectedStates,
            minimumProtectedSelections: backgroundReleaseRadarReservedSlots,
            includeBackoffFeeds: false,
            onlyDueFeeds: true,
            joinActiveCycle: true,
            backgroundTaskIdentifier: taskIdentifier
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
        logger.info("background.processingRequested", "Background processing requested feed catch-up", metadata: [
            "identifier": taskIdentifier,
            "sceneActive": "\(isSceneActive)",
            "trigger": FeedRefreshTrigger.backgroundProcessingTask.rawValue,
            "executionContext": FeedRefreshExecutionContext.backgroundProcessingTask.rawValue
        ])
        return await refreshSubscriptions(
            reason: "processing",
            trigger: .backgroundProcessingTask,
            executionContext: .backgroundProcessingTask,
            maxSubscriptions: nil,
            includeBackoffFeeds: true,
            onlyDueFeeds: true,
            joinActiveCycle: true,
            backgroundTaskIdentifier: taskIdentifier
        )
    }

    /// Called from a BGTask expiration handler. Cancels the active refresh cycle
    /// ONLY when no live foreground/audio context is driving it. If the app is
    /// genuinely foreground (`isAppForeground`) or audio is playing, that context
    /// will finish the cycle, so an expiring BGTask that merely *joined* it must
    /// detach rather than abort shared work. Uses the real UIApplication state, not
    /// the cached `isSceneActive`. Otherwise falls through to cancel + checkpoint.
    func cancelRefreshCycleIfBackgroundOnly(reason: String) {
        if isAppForeground || isPlaying {
            logger.info("feed.refreshAll.expirationDetached", "BGTask expired but a live foreground/audio context owns the refresh cycle — detaching, not cancelling", metadata: [
                "reason": reason,
                "appForeground": "\(isAppForeground)",
                "isPlaying": "\(isPlaying)",
                "activeRefreshCycleID": activeRefreshCycleDiagnostics?.cycleID ?? "none",
                "activeTrigger": activeRefreshCycleDiagnostics?.trigger.rawValue ?? "none",
                "activeExecutionContext": activeRefreshCycleDiagnostics?.executionContext.rawValue ?? "none"
            ])
            return
        }
        cancelActiveRefreshCycle(reason: reason)
    }

    func cancelActiveRefreshCycle(reason: String) {
        guard let activeRefreshCycle else {
            logger.info("feed.refreshAll.cancelRequestIgnored", "No refresh cycle was active", metadata: [
                "reason": reason
            ])
            return
        }
        logger.warning("feed.refreshAll.cancelRequested", "Refresh cycle cancellation requested", metadata: [
            "reason": reason,
            "backlogCount": "\(deferredRefreshBacklog.count)",
            "sceneActive": "\(isSceneActive)",
            "activeRefreshCycleID": activeRefreshCycleDiagnostics?.cycleID ?? "unknown",
            "activeReason": activeRefreshCycleDiagnostics?.reason ?? "unknown",
            "activeTrigger": activeRefreshCycleDiagnostics?.trigger.rawValue ?? "unknown",
            "activeExecutionContext": activeRefreshCycleDiagnostics?.executionContext.rawValue ?? "unknown"
        ])
        activeRefreshCycle.cancel()
    }

    @discardableResult
    private func refreshSubscriptions(
        reason: String,
        trigger: FeedRefreshTrigger,
        executionContext: FeedRefreshExecutionContext,
        maxSubscriptions: Int?,
        capBypassStates: Set<FeedRefreshWindowState> = [],
        protectedStates: Set<FeedRefreshWindowState> = [],
        minimumProtectedSelections: Int = 0,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool,
        joinActiveCycle: Bool = false,
        backgroundTaskIdentifier: String? = nil
    ) async -> Bool {
        if let active = activeRefreshCycle {
            guard joinActiveCycle else {
                logger.info("feed.refreshAll.skip", "Refresh-all skipped because another cycle is already running", metadata: [
                    "count": "\(subscriptionStore.subscriptions.count)",
                    "reason": reason,
                    "trigger": trigger.rawValue,
                    "executionContext": executionContext.rawValue,
                    "sceneActive": "\(isSceneActive)",
                    "activeRefreshCycleID": activeRefreshCycleDiagnostics?.cycleID ?? "unknown",
                    "activeReason": activeRefreshCycleDiagnostics?.reason ?? "unknown",
                    "activeTrigger": activeRefreshCycleDiagnostics?.trigger.rawValue ?? "unknown",
                    "activeExecutionContext": activeRefreshCycleDiagnostics?.executionContext.rawValue ?? "unknown"
                ])
                return false
            }
            // A cycle is already in flight (e.g. the foreground tick fired on the
            // same wake as a background task). Ride it to completion instead of
            // skipping, so the BGTask stays alive until the work is actually done —
            // completing early lets iOS suspend the app mid-request.
            logger.info("feed.refreshAll.join", "Joining refresh cycle already in flight", metadata: [
                "reason": reason,
                "trigger": trigger.rawValue,
                "executionContext": executionContext.rawValue,
                "sceneActive": "\(isSceneActive)",
                "backgroundTaskIdentifier": backgroundTaskIdentifier ?? "none",
                "joinedRefreshCycleID": activeRefreshCycleDiagnostics?.cycleID ?? "unknown",
                "joinedReason": activeRefreshCycleDiagnostics?.reason ?? "unknown",
                "joinedTrigger": activeRefreshCycleDiagnostics?.trigger.rawValue ?? "unknown",
                "joinedExecutionContext": activeRefreshCycleDiagnostics?.executionContext.rawValue ?? "unknown"
            ])
            return await active.value
        }

        let diagnostics = RefreshCycleDiagnostics(
            cycleID: UUID().uuidString,
            reason: reason,
            trigger: trigger,
            executionContext: executionContext,
            startSceneActive: isSceneActive,
            backgroundTaskIdentifier: backgroundTaskIdentifier
        )

        let cycle = Task { @MainActor in
            await self.performRefreshCycle(
                diagnostics: diagnostics,
                maxSubscriptions: maxSubscriptions,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                includeBackoffFeeds: includeBackoffFeeds,
                onlyDueFeeds: onlyDueFeeds
            )
        }
        activeRefreshCycle = cycle
        activeRefreshCycleDiagnostics = diagnostics
        defer {
            activeRefreshCycle = nil
            activeRefreshCycleDiagnostics = nil
        }
        return await cycle.value
    }

    private func performRefreshCycle(
        diagnostics: RefreshCycleDiagnostics,
        maxSubscriptions: Int?,
        capBypassStates: Set<FeedRefreshWindowState>,
        protectedStates: Set<FeedRefreshWindowState>,
        minimumProtectedSelections: Int,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool
    ) async -> Bool {
        suppressUpNextRefresh = true
        defer { suppressUpNextRefresh = false }

        let refreshContext = diagnostics.metadata(currentSceneActive: isSceneActive)
        resourceMonitor.logSnapshot(
            reason: "feed.refreshAll.before",
            context: resourceContext(refreshContext),
            force: true
        )
        logger.info("feed.refreshAll", "Refreshing all podcast feeds", metadata: [
            "count": "\(subscriptionStore.subscriptions.count)",
            "reason": diagnostics.reason,
            "maxSubscriptions": maxSubscriptions.map(String.init) ?? "all"
        ].merging(refreshContext) { _, new in new })
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
        let dueCandidates = onlyDueFeeds
            ? refreshCandidatesForCycle(eligibleSubscriptions, now: now)
            : []
        let budgetSelection = FeedRefreshBudgeting.select(
            candidates: dueCandidates,
            policy: FeedRefreshBudgetPolicy(
                maxSelections: maxSubscriptions,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections
            ),
            state: { $0.prediction.state }
        )
        let selectedCandidates = budgetSelection.selected
        let deferredCandidates = budgetSelection.deferred
        let subscriptions = onlyDueFeeds
            ? selectedCandidates.map(\.subscription)
            : eligibleSubscriptions
        if onlyDueFeeds {
            reconcileDeferredRefreshBacklog(
                dueCandidates: dueCandidates,
                selectedCandidates: selectedCandidates,
                deferredCandidates: deferredCandidates,
                now: now,
                diagnostics: diagnostics
            )
            logRefreshCycleDecisionSummary(
                candidates: dueCandidates,
                selectedCandidates: selectedCandidates,
                deferredCandidates: deferredCandidates,
                selectedCount: selectedCandidates.count,
                eligibleCount: eligibleSubscriptions.count,
                skippedBackoffCount: backoffSubscriptions.count,
                skippedInactiveCount: skippedSubscriptions.count,
                maxSubscriptions: maxSubscriptions,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                diagnostics: diagnostics
            )
        }
        if onlyDueFeeds, selectedCandidates.isEmpty {
            scheduleBackgroundRefreshForNextDueFeed()
            logger.info("feed.refreshAll.noDue", "No due subscriptions selected for refresh cycle", metadata: [
                "eligible": "\(eligibleSubscriptions.count)",
                "due": "\(dueCandidates.count)",
                "skippedBackoff": "\(backoffSubscriptions.count)",
                "skippedInactive": "\(skippedSubscriptions.count)"
            ].merging(refreshContext) { _, new in new })
            return false
        }
        let selectedCandidatesByID = Dictionary(uniqueKeysWithValues: selectedCandidates.map { ($0.subscription.id, $0) })
        if !skippedSubscriptions.isEmpty {
            logger.info("feed.refreshAll.skippedInactive", "Skipped subscriptions excluded from auto feed refresh", metadata: [
                "count": "\(skippedSubscriptions.count)",
                "podcasts": skippedSubscriptions.map(\.title).joined(separator: ", ")
            ].merging(refreshContext) { _, new in new })
        }
        if !includeBackoffFeeds, !backoffSubscriptions.isEmpty {
            logger.info("feed.refreshAll.skippedBackoff", "Skipped subscriptions temporarily paused after failed refreshes", metadata: [
                "count": "\(backoffSubscriptions.count)",
                "podcasts": backoffSubscriptions.map(\.title).joined(separator: ", ")
            ].merging(refreshContext) { _, new in new })
        }
        var completedSubscriptionIDs = Set<UUID>()
        var wasCancelled = false
        for (index, subscription) in subscriptions.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            var itemStartMetadata = refreshFeedMetadata(for: subscription, extra: [
                "index": "\(index + 1)",
                "total": "\(subscriptions.count)",
                "reason": diagnostics.reason
            ].merging(refreshContext) { _, new in new })
            if let candidate = selectedCandidatesByID[subscription.id] {
                itemStartMetadata.merge(refreshDecisionMetadata(for: candidate)) { _, new in new }
            }
            logger.info("feed.refreshAll.itemStart", "Refreshing subscription in timed cycle", metadata: itemStartMetadata)
            await refreshSubscription(
                subscription,
                episodeLimit: defaultFeedEpisodeLimit,
                refreshUpNextAfterMerge: false
            )
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            completedSubscriptionIDs.insert(subscription.id)
            logger.info("feed.refreshAll.itemFinished", "Finished subscription in timed cycle", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                "index": "\(index + 1)",
                "total": "\(subscriptions.count)",
                "reason": diagnostics.reason
            ].merging(refreshContext) { _, new in new }))
        }
        if wasCancelled {
            let unfinishedCandidates = selectedCandidates.filter { candidate in
                !completedSubscriptionIDs.contains(candidate.subscription.id)
            }
            restoreUnfinishedRefreshBacklog(
                candidates: unfinishedCandidates,
                now: Date(),
                diagnostics: diagnostics
            )
            scheduleBackgroundRefreshForNextDueFeed()
            logger.warning("feed.refreshAll.cancelled", "Refresh cycle stopped before all selected feeds completed", metadata: [
                "attempted": "\(completedSubscriptionIDs.count)",
                "unfinished": "\(unfinishedCandidates.count)",
                "deferredBacklog": "\(deferredRefreshBacklog.count)",
                "reason": diagnostics.reason
            ].merging(refreshContext) { _, new in new })
            resourceMonitor.logSnapshot(
                reason: "feed.refreshAll.cancelled",
                context: resourceContext(refreshContext),
                force: true
            )
            return !completedSubscriptionIDs.isEmpty
        }
        scheduleBackgroundRefreshForNextDueFeed()
        refreshUpNextEpisode(reason: "feed.refreshAll.finished")
        await runAutoArchiveIfNeeded(reason: "feed.refreshAll")
        logger.info("feed.refreshAll", "Finished refreshing all podcast feeds", metadata: [
            "attempted": "\(subscriptions.count)",
            "eligible": "\(eligibleSubscriptions.count)",
            "skippedBackoff": "\(backoffSubscriptions.count)",
            "skippedInactive": "\(skippedSubscriptions.count)",
            "reason": diagnostics.reason
        ].merging(refreshContext) { _, new in new })
        resourceMonitor.logSnapshot(
            reason: "feed.refreshAll.after",
            context: resourceContext(refreshContext),
            force: true
        )
        return true
    }

    /// The next moment a subscription deserves a fetch, preferring learned release
    /// windows and falling back to the legacy cadence model while a feed is still
    /// learning or has unusable date data.
    func nextRefreshDue(for subscription: Subscription) -> Date {
        refreshPrediction(for: subscription).nextDueAt
    }

    /// Snapshot for the Feed Refresh Schedule diagnostics page
    /// (Views/FeedRefreshScheduleView): the learned schedule profile + next-window
    /// prediction for one subscription — the same FeedScheduleProfile /
    /// FeedRefreshPrediction the refresh scheduler itself uses.
    func releaseRadarSchedule(for subscription: Subscription, now: Date = Date()) -> (profile: FeedScheduleProfile, prediction: FeedRefreshPrediction) {
        let profile = releaseRadarProfile(for: subscription)
        return (profile, refreshPrediction(for: subscription, profile: profile, now: now))
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
        logger.info("feed.rebuildPrediction", "Rebuilding Release Radar prediction from feed history", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
            "episodeLimit": "\(episodeLimit)"
        ]))
        do {
            let result = try await feedService.refresh(
                feedURL: subscription.feedURL,
                subscriptionID: subscription.id,
                episodeLimit: episodeLimit
            )
            let currentSubscription = subscriptionStore.subscription(id: subscription.id) ?? subscription
            let filterSettings = currentSubscription.downloadFilterSettings
            let eligibleForLearning = result.episodes.filter { filterSettings.evaluation(for: $0).isIncluded }
            let historicalKeys = Set(result.episodes.map(RefreshStats.releaseObservationKey(for:)))
            var stats = currentSubscription.refreshStats
            let newlyRecorded = stats.recordEpisodeObservations(
                result.episodes,
                previouslyKnownEpisodeKeys: historicalKeys,
                downloadFilterSettings: filterSettings
            )
            subscriptionStore.updateRefreshStats(subscriptionID: subscription.id, stats: stats)
            // Report the classification the rebuilt history produced so the result can
            // be confirmed on-device (e.g. a weekly show should now read kind=weekly
            // with a learned window rather than falling through to random).
            let profile = stats.scheduleProfile(downloadFilterSettings: filterSettings)
            let windowText: String
            if let window = profile.releaseWindow {
                windowText = String(format: "%02d:%02d-%02d:%02d",
                                    window.startMinuteOfDay / 60, window.startMinuteOfDay % 60,
                                    window.endMinuteOfDay / 60, window.endMinuteOfDay % 60)
            } else {
                windowText = "none"
            }
            logger.info("feed.rebuildPrediction", "Rebuilt Release Radar prediction", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                "fetched": "\(result.episodes.count)",
                "eligibleForLearning": "\(eligibleForLearning.count)",
                "newlyRecorded": "\(newlyRecorded)",
                "totalObservations": "\(stats.releaseObservations(includedBy: filterSettings).count)",
                "kind": String(describing: profile.kind),
                "confidence": String(format: "%.2f", profile.confidence),
                "reliableDates": "\(profile.reliableDateCount)",
                "window": windowText
            ]))
            return eligibleForLearning.count
        } catch {
            if isCancellationError(error) { return nil }
            logger.error("feed.rebuildPredictionFailed", "Could not rebuild Release Radar prediction", metadata: refreshFeedMetadata(for: subscription, includeURL: false, extra: [
                "error": String(describing: error)
            ]))
            return nil
        }
    }

    private func refreshPrediction(for subscription: Subscription, now: Date = Date()) -> FeedRefreshPrediction {
        refreshPrediction(
            for: subscription,
            profile: releaseRadarProfile(for: subscription),
            now: now
        )
    }

    /// Memoized Release Radar profile per subscription (PERF-2). The profiler runs the
    /// full v2 detector pipeline (sort/cluster over up to 200 observations); the
    /// foreground poller calls this for EVERY subscription every 30 s just to count due
    /// feeds, which showed up in diagnostics as ~300 ms main-thread hangs right after
    /// launch. The profile is a pure function of (releaseObservations,
    /// downloadFilterSettings) — both change only on feed refresh / filter edits — so a
    /// fingerprint-validated cache is self-invalidating with no hooks needed at
    /// mutation sites. A 15-min TTL bounds drift from the profiler's time-dependent
    /// recency windows (they move over days, not minutes).
    private var releaseRadarProfileCache: [UUID: ReleaseRadarProfileCacheEntry] = [:]
    private static let releaseRadarProfileCacheTTL: TimeInterval = 15 * 60

    /// Cold-launch cache warm-up: computes every active subscription's profile OFF the
    /// main actor (the profiler is a pure function over value-type snapshots) so the
    /// first 30 s poller tick after launch hits a warm cache instead of building ~all
    /// profiles synchronously on the main thread (the post-launch hang burst in the
    /// 2026-07-02 diagnostic log). Entries are fingerprint-validated on read, so a feed
    /// refresh landing mid-warm-up just causes that one profile to recompute.
    func warmReleaseRadarProfileCache() {
        let snapshot = subscriptionStore.subscriptions.filter {
            !$0.excludeFromAutoFeedRefresh && $0.browseDate == nil
        }
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            var warmed: [UUID: ReleaseRadarProfileCacheEntry] = [:]
            for sub in snapshot {
                let observations = sub.refreshStats.releaseObservations
                warmed[sub.id] = ReleaseRadarProfileCacheEntry(
                    observationCount: observations.count,
                    newestObservationKey: observations.last?.episodeKey,
                    filterSettings: sub.downloadFilterSettings,
                    generatedAt: now,
                    profile: sub.refreshStats.scheduleProfile(downloadFilterSettings: sub.downloadFilterSettings)
                )
            }
            let entries = warmed
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Don't clobber entries the main actor computed while we were warming.
                self.releaseRadarProfileCache.merge(entries) { existing, _ in existing }
                self.logger.info("radar.profileCacheWarmed", "Release Radar profile cache warmed off-main", metadata: [
                    "profiles": "\(entries.count)"
                ])
            }
        }
    }

    private func releaseRadarProfile(for subscription: Subscription) -> FeedScheduleProfile {
        let observations = subscription.refreshStats.releaseObservations
        let settings = subscription.downloadFilterSettings
        let now = Date()
        if let entry = releaseRadarProfileCache[subscription.id],
           entry.observationCount == observations.count,
           entry.newestObservationKey == observations.last?.episodeKey,
           entry.filterSettings == settings,
           now.timeIntervalSince(entry.generatedAt) < Self.releaseRadarProfileCacheTTL {
            return entry.profile
        }
        let profile = subscription.refreshStats.scheduleProfile(downloadFilterSettings: settings)
        releaseRadarProfileCache[subscription.id] = ReleaseRadarProfileCacheEntry(
            observationCount: observations.count,
            newestObservationKey: observations.last?.episodeKey,
            filterSettings: settings,
            generatedAt: now,
            profile: profile
        )
        return profile
    }

    private func refreshPrediction(
        for subscription: Subscription,
        profile: FeedScheduleProfile,
        now: Date
    ) -> FeedRefreshPrediction {
        // Single-item feeds (hourly news bulletins) carry too few dates to derive a
        // cadence from the feed alone — fold in the persisted publish-date history.
        let filterSettings = subscription.downloadFilterSettings
        let eligibleEpisodeDates = subscription.episodes
            .filter { filterSettings.evaluation(for: $0).isIncluded }
            .compactMap(\.publishedAt)
        let learnedEligibleDates = subscription.refreshStats
            .releaseObservations(includedBy: filterSettings)
            .compactMap(\.publishedAt)
        let fallbackDates = filterSettings.hasActiveFilters
            ? learnedEligibleDates
            : subscription.refreshStats.recentPublishDates
        let publishDates = Set(eligibleEpisodeDates).union(fallbackDates)
        return FeedRefreshScheduling.prediction(
            profile: profile,
            latestPublishedAt: newestReleaseRadarEligibleEpisode(in: subscription)?.publishedAt,
            publishDates: Array(publishDates),
            stats: subscription.refreshStats,
            minRecheckInterval: Double(settingsStore.appSettings.podcastPollMinutes) * 60,
            now: now
        )
    }

    private struct RefreshCycleCandidate {
        var subscription: Subscription
        var profile: FeedScheduleProfile
        var prediction: FeedRefreshPrediction
        var priority: FeedRefreshPriority
        var deferredCount: Int = 0
        var deferredSince: Date?
        var deferredScoreBoost: Double = 0
    }

    private struct DeferredRefreshBacklogEntry {
        var subscriptionID: UUID
        var title: String
        var feedURL: URL
        var firstDeferredAt: Date
        var lastDeferredAt: Date
        var lastDueAt: Date
        var deferralCount: Int
        var state: FeedRefreshWindowState
        var score: Double
    }

    /// Priority queue for feeds already due. Learned active windows and missed
    /// releases win the limited background slots before ordinary overdue feeds.
    private func refreshCandidatesForCycle(
        _ subscriptions: [Subscription],
        now: Date
    ) -> [RefreshCycleCandidate] {
        subscriptions
            .compactMap { subscription -> RefreshCycleCandidate? in
                let profile = releaseRadarProfile(for: subscription)
                let prediction = refreshPrediction(for: subscription, profile: profile, now: now)
                guard prediction.nextDueAt <= now else { return nil }
                let priority = FeedRefreshPrioritizer.priority(
                    prediction: prediction,
                    profile: profile,
                    priorityRank: subscription.priorityRank,
                    lastFetchedAt: subscription.refreshStats.lastFetchedAt,
                    now: now
                )
                var candidate = RefreshCycleCandidate(
                    subscription: subscription,
                    profile: profile,
                    prediction: prediction,
                    priority: priority
                )
                applyDeferredRefreshBoost(to: &candidate, now: now)
                return candidate
            }
            .sorted { lhs, rhs in
                if lhs.priority.score != rhs.priority.score {
                    return lhs.priority.score > rhs.priority.score
                }
                if lhs.deferredSince != rhs.deferredSince {
                    return (lhs.deferredSince ?? .distantFuture) < (rhs.deferredSince ?? .distantFuture)
                }
                if lhs.prediction.nextDueAt != rhs.prediction.nextDueAt {
                    return lhs.prediction.nextDueAt < rhs.prediction.nextDueAt
                }
                if lhs.subscription.priorityRank != rhs.subscription.priorityRank {
                    return lhs.subscription.priorityRank < rhs.subscription.priorityRank
                }
                return lhs.subscription.title.localizedCaseInsensitiveCompare(rhs.subscription.title) == .orderedAscending
            }
    }

    private func logRefreshCycleDecisionSummary(
        candidates: [RefreshCycleCandidate],
        selectedCandidates: [RefreshCycleCandidate],
        deferredCandidates: [RefreshCycleCandidate],
        selectedCount: Int,
        eligibleCount: Int,
        skippedBackoffCount: Int,
        skippedInactiveCount: Int,
        maxSubscriptions: Int?,
        capBypassStates: Set<FeedRefreshWindowState>,
        protectedStates: Set<FeedRefreshWindowState>,
        minimumProtectedSelections: Int,
        diagnostics: RefreshCycleDiagnostics
    ) {
        let protectedSelectedCount = selectedCandidates.filter { protectedStates.contains($0.prediction.state) }.count
        logger.info("feed.refreshAll.plan", "Planned due-feed refresh cycle", metadata: [
            "reason": diagnostics.reason,
            "eligible": "\(eligibleCount)",
            "due": "\(candidates.count)",
            "selected": "\(selectedCount)",
            "cappedOut": "\(max(0, candidates.count - selectedCount))",
            "maxSubscriptions": maxSubscriptions.map(String.init) ?? "all",
            "capBypassStates": refreshStateList(capBypassStates),
            "protectedStates": refreshStateList(protectedStates),
            "protectedMinimum": "\(minimumProtectedSelections)",
            "protectedSelected": "\(protectedSelectedCount)",
            "skippedBackoff": "\(skippedBackoffCount)",
            "skippedInactive": "\(skippedInactiveCount)",
            "deferredBacklog": "\(deferredRefreshBacklog.count)",
            "stateCounts": refreshStateCounts(for: candidates),
            "topCandidates": refreshTopCandidateSummary(for: candidates),
            "selectedCandidates": refreshTopCandidateSummary(for: selectedCandidates),
            "deferredCandidates": refreshTopCandidateSummary(for: deferredCandidates)
        ].merging(diagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new })
    }

    private func refreshDecisionMetadata(for candidate: RefreshCycleCandidate) -> [String: String] {
        var metadata = [
            "refreshScore": String(format: "%.1f", candidate.priority.score),
            "refreshFactors": candidate.priority.reason,
            "profileKind": candidate.profile.kind.rawValue,
            "profileConfidence": String(format: "%.2f", candidate.profile.confidence),
            "profileObservations": "\(candidate.profile.observationCount)",
            "profileReliableDates": "\(candidate.profile.reliableDateCount)",
            "predictionState": candidate.prediction.state.rawValue,
            "predictionReason": candidate.prediction.reason,
            "nextDueAt": refreshLogDate(candidate.prediction.nextDueAt),
            "expectedWindowStart": refreshLogDate(candidate.prediction.expectedWindowStart),
            "expectedWindowEnd": refreshLogDate(candidate.prediction.expectedWindowEnd),
            "recheckIntervalSeconds": candidate.prediction.recheckInterval.map { "\(Int($0.rounded()))" } ?? "none"
        ]
        if let window = candidate.profile.releaseWindow {
            metadata["releaseWindow"] = String(format: "%02d:%02d-%02d:%02d",
                                               window.startMinuteOfDay / 60, window.startMinuteOfDay % 60,
                                               window.endMinuteOfDay / 60, window.endMinuteOfDay % 60)
            if let observedSpread = window.observedSpreadMinutes {
                metadata["releaseWindowObservedSpreadMinutes"] = "\(observedSpread)"
            }
        }
        if candidate.deferredCount > 0 {
            metadata["deferredRefreshCount"] = "\(candidate.deferredCount)"
            metadata["deferredRefreshSince"] = refreshLogDate(candidate.deferredSince)
            metadata["deferredRefreshBoost"] = String(format: "%.1f", candidate.deferredScoreBoost)
        }
        return metadata
    }

    private func refreshStateCounts(for candidates: [RefreshCycleCandidate]) -> String {
        let counts = candidates.reduce(into: [FeedRefreshWindowState: Int]()) { counts, candidate in
            counts[candidate.prediction.state, default: 0] += 1
        }
        return FeedRefreshWindowState.allCases
            .compactMap { state -> String? in
                guard let count = counts[state], count > 0 else { return nil }
                return "\(state.rawValue)=\(count)"
            }
            .joined(separator: ",")
    }

    private func refreshStateList(_ states: Set<FeedRefreshWindowState>) -> String {
        let values = FeedRefreshWindowState.allCases
            .filter(states.contains)
            .map(\.rawValue)
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    private func refreshTopCandidateSummary(for candidates: [RefreshCycleCandidate]) -> String {
        candidates.prefix(5)
            .map { candidate in
                let score = String(format: "%.1f", candidate.priority.score)
                let hash = refreshFeedHash(for: candidate.subscription.feedURL)
                let deferred = candidate.deferredCount > 0 ? "|deferred:\(candidate.deferredCount)" : ""
                return "\(score)|\(candidate.prediction.state.rawValue)|\(candidate.profile.kind.rawValue)|id:\(candidate.subscription.id.uuidString)|hash:\(hash)\(deferred)|\(candidate.subscription.title)"
            }
            .joined(separator: "; ")
    }

    private func refreshLogDate(_ date: Date?) -> String {
        guard let date else { return "none" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func refreshFeedMetadata(
        for subscription: Subscription,
        includeURL: Bool = true,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata = [
            "podcast": subscription.title,
            "subscriptionID": subscription.id.uuidString,
            "feedHash": refreshFeedHash(for: subscription.feedURL)
        ]
        if includeURL {
            metadata["url"] = subscription.feedURL.absoluteString
        }
        metadata.merge(extra) { _, new in new }
        return metadata
    }

    private func refreshFeedHash(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func scheduleBackgroundRefreshForNextDueFeed() {
        let activeSubscriptions = subscriptionStore.subscriptions.filter { !$0.excludeFromAutoFeedRefresh }
        let nextDue = activeSubscriptions
            .map { subscription in
                (subscription: subscription, dueAt: nextRefreshDue(for: subscription))
            }
            .min { lhs, rhs in
                if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
                return lhs.subscription.title.localizedCaseInsensitiveCompare(rhs.subscription.title) == .orderedAscending
            }
        if let nextDue {
            let secondsUntilDue = max(0, Int(nextDue.dueAt.timeIntervalSinceNow.rounded()))
            logger.info("background.nextDue", "Selected next feed due date for background refresh scheduling", metadata: refreshFeedMetadata(
                for: nextDue.subscription,
                includeURL: false,
                extra: [
                    "nextDueAt": refreshLogDate(nextDue.dueAt),
                    "secondsUntilDue": "\(secondsUntilDue)",
                    "activeSubscriptions": "\(activeSubscriptions.count)",
                    "skippedInactive": "\(subscriptionStore.subscriptions.count - activeSubscriptions.count)"
                ]
            ))
        } else {
            logger.info("background.nextDue", "No active subscription available for background refresh scheduling", metadata: [
                "activeSubscriptions": "0",
                "skippedInactive": "\(subscriptionStore.subscriptions.count)"
            ])
        }
        let soonestDue = nextDue?.dueAt
        BackgroundTaskCoordinator.scheduleAppRefresh(earliestBeginDate: soonestDue)
    }

    private func applyDeferredRefreshBoost(to candidate: inout RefreshCycleCandidate, now: Date) {
        guard let entry = deferredRefreshBacklog[candidate.subscription.id] else { return }
        let ageHours = max(0, now.timeIntervalSince(entry.firstDeferredAt) / 3600)
        let boost = min(
            refreshDeferralMaxScoreBoost,
            Double(entry.deferralCount) * refreshDeferralScoreBoostPerCycle
                + ageHours * refreshDeferralAgeBoostPerHour
        )
        let roundedBoost = (boost * 10).rounded() / 10
        guard roundedBoost > 0 else { return }
        candidate.deferredCount = entry.deferralCount
        candidate.deferredSince = entry.firstDeferredAt
        candidate.deferredScoreBoost = roundedBoost
        candidate.priority.score = ((candidate.priority.score + roundedBoost) * 10).rounded() / 10
        candidate.priority.factors.append("deferred \(entry.deferralCount)x")
        candidate.priority.reason = candidate.priority.factors.joined(separator: ", ")
    }

    private func reconcileDeferredRefreshBacklog(
        dueCandidates: [RefreshCycleCandidate],
        selectedCandidates: [RefreshCycleCandidate],
        deferredCandidates: [RefreshCycleCandidate],
        now: Date,
        diagnostics: RefreshCycleDiagnostics
    ) {
        let previousBacklogCount = deferredRefreshBacklog.count
        let dueIDs = Set(dueCandidates.map(\.subscription.id))
        deferredRefreshBacklog = deferredRefreshBacklog.filter { dueIDs.contains($0.key) }

        for candidate in selectedCandidates {
            deferredRefreshBacklog.removeValue(forKey: candidate.subscription.id)
        }
        for candidate in deferredCandidates {
            recordDeferredRefreshCandidate(candidate, now: now)
        }

        if !deferredCandidates.isEmpty || deferredRefreshBacklog.count != previousBacklogCount {
            logger.info("feed.refreshAll.backlog", "Checkpointed deferred due-feed backlog", metadata: [
                "reason": diagnostics.reason,
                "selected": "\(selectedCandidates.count)",
                "deferred": "\(deferredCandidates.count)",
                "backlogCount": "\(deferredRefreshBacklog.count)",
                "deferredCandidates": refreshTopCandidateSummary(for: deferredCandidates)
            ].merging(diagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new })
        }
    }

    private func restoreUnfinishedRefreshBacklog(
        candidates: [RefreshCycleCandidate],
        now: Date,
        diagnostics: RefreshCycleDiagnostics
    ) {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            recordDeferredRefreshCandidate(candidate, now: now)
        }
        logger.warning("feed.refreshAll.checkpoint", "Checkpointed unfinished selected feeds", metadata: [
            "reason": diagnostics.reason,
            "unfinished": "\(candidates.count)",
            "backlogCount": "\(deferredRefreshBacklog.count)",
            "unfinishedCandidates": refreshTopCandidateSummary(for: candidates)
        ].merging(diagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new })
    }

    private func recordDeferredRefreshCandidate(_ candidate: RefreshCycleCandidate, now: Date) {
        let subscription = candidate.subscription
        if var entry = deferredRefreshBacklog[subscription.id] {
            entry.title = subscription.title
            entry.feedURL = subscription.feedURL
            entry.lastDeferredAt = now
            entry.lastDueAt = candidate.prediction.nextDueAt
            entry.deferralCount += 1
            entry.state = candidate.prediction.state
            entry.score = candidate.priority.score
            deferredRefreshBacklog[subscription.id] = entry
        } else {
            deferredRefreshBacklog[subscription.id] = DeferredRefreshBacklogEntry(
                subscriptionID: subscription.id,
                title: subscription.title,
                feedURL: subscription.feedURL,
                firstDeferredAt: now,
                lastDeferredAt: now,
                lastDueAt: candidate.prediction.nextDueAt,
                deferralCount: 1,
                state: candidate.prediction.state,
                score: candidate.priority.score
            )
        }
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

                    // Only downloaded episodes are eligible — an episode that has
                    // never been downloaded has never been "touched" and should not
                    // be archived by this rule.
                    guard let downloadedAt = episode.downloadedAt else { continue }

                    // "Last activity" = the most recent of: download date, play date.
                    // The clock starts when the file lands on device, and resets any
                    // time the user starts playing the episode.
                    let downloadAge = now.timeIntervalSince(downloadedAt)
                    let playAge     = episode.lastPlayedAt.map { now.timeIntervalSince($0) }
                    let lastActivityAge = [downloadAge, playAge].compactMap { $0 }.min() ?? downloadAge

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
                    .filter { $0.playedState != .archived && !archivedIDs.contains($0.id) && ($0.downloadState == .queued || $0.downloadState == .downloaded) && !isPreSubscriptionBacklog($0) }
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

    /// Subscribes to a list of feed URLs in one go (used by starter packs —
    /// ONBOARDING_PLAN.md Phase 7). Mirrors the OPML import per-URL refresh+add
    /// loop, skipping any feed already subscribed. Returns the number newly
    /// subscribed. Because several real subscriptions can appear at once, the
    /// first-subscription milestone resolves silently (no "You're all set" card),
    /// exactly like a bulk OPML import.
    @discardableResult
    func subscribeToFeedURLs(_ urls: [URL]) async -> Int {
        let existing = Set(subscriptionStore.subscriptions.map(\.feedURL))
        var imported = 0
        for url in urls where !existing.contains(url) {
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
                imported += 1
            } catch {
                logger.error("starterPack.subscribeFailed", "Could not subscribe to feed", metadata: [
                    "url": url.absoluteString,
                    "error": String(describing: error)
                ])
            }
        }
        return imported
    }

    // MARK: - Playback position persistence

    private func recordPlaybackTickDiagnostics(
        startedAt: CFAbsoluteTime,
        playbackTime: TimeInterval,
        episode: Episode?,
        subscription: Subscription?,
        stages: [PlaybackTickStageTiming],
        positionSaved: Bool,
        statsCredited: Bool
    ) {
        let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        let dominant = stages.max { lhs, rhs in lhs.durationMs < rhs.durationMs }
        let diagnostics = PlaybackTickDiagnostics(
            occurredAt: Date(),
            episode: episode?.title ?? "none",
            podcast: subscription?.title ?? "none",
            currentTime: Int(playbackTime),
            totalMs: totalMs,
            dominantStage: dominant?.name ?? "none",
            dominantStageMs: dominant?.durationMs ?? 0,
            stages: stages,
            positionSaved: positionSaved,
            statsCredited: statsCredited
        )
        lastPlaybackTickDiagnostics = diagnostics
        playbackTickSummary.record(diagnostics, slowThresholdMs: playbackTickSlowThresholdMs)

        if totalMs >= playbackTickSlowThresholdMs {
            logger.warning("playback.tickSlow", "Playback tick was slow on the main actor", metadata: diagnostics.metadata())
        }

        if playbackTickSummary.samples >= playbackTickSummarySampleInterval {
            var metadata = playbackTickSummary.metadata()
            metadata.merge([
                "episode": diagnostics.episode,
                "podcast": diagnostics.podcast,
                "currentTime": "\(diagnostics.currentTime)",
                "thresholdMs": String(format: "%.1f", playbackTickSlowThresholdMs)
            ]) { _, new in new }
            logger.info("playback.tickSummary", "Playback tick timing summary", metadata: metadata)
            playbackTickSummary.reset()
        }
    }

    private func savePlaybackPosition() {
        guard let episode = currentPlayerEpisode,
              currentPlayerTime > 0,
              Self.positionFileURL != nil
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
        var positions = savedPositions()
        positions[episodeKey] = position
        positions.removeValue(forKey: episode.id.uuidString)
        writeSavedPositions(positions)
    }

    func persistCurrentPlaybackPosition() {
        savePlaybackPosition()
        listeningHistoryStore.save()
    }

    /// Lifecycle checkpoint for sync: pushes any slow-lane (history/stats)
    /// CloudKit changes the engine is holding on its ~60 s coalescing debounce.
    /// Call AFTER `listeningStatsStore.save()` (or `flushPendingStatsDays`) so
    /// the day buckets are in the sync database before the engine scans for
    /// pending rows. Wired to pause, sleep-timer/schedule pause, and scene
    /// backgrounding/resign-active (AutohopApp).
    func flushDeferredSyncPushes(reason: String) {
        cloudSyncEngine.flushDeferredPushes(reason: reason)
    }

    private func saveQueuePins() {
        guard let url = Self.queuePinsFileURL else { return }
        let pins = SavedQueuePins(overrideIDs: queueOverrideEpisodeIDs, demotedIDs: queueDemotedEpisodeIDs)
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? LockedDeviceFileAccess.writeDataAtomically(data, to: url)
    }

    private func loadQueuePins() {
        guard let url = Self.queuePinsFileURL,
              let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode(SavedQueuePins.self, from: data)
        else { return }
        LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: url)
        queueOverrideEpisodeIDs = pins.overrideIDs
        queueDemotedEpisodeIDs = pins.demotedIDs
        logger.info("queue.pinsLoaded", "Queue pins restored", metadata: [
            "overrideCount": "\(pins.overrideIDs.count)",
            "demotedCount": "\(pins.demotedIDs.count)"
        ])
    }

    private func restorePlaybackPosition() {
        let positions = savedPositions()
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
        let positions = savedPositions()
        guard let position = positions[playbackPositionKey(for: episode)] ?? positions[episode.id.uuidString],
              position.subscriptionID == episode.subscriptionID
        else { return 0 }
        return normalizedResumeTime(position.timeSeconds, duration: episode.durationSeconds)
    }

    /// Returns the saved positions, loading from disk once and caching the result.
    private func savedPositions() -> SavedPositions {
        if let cached = savedPositionsCache { return cached }
        let loaded = loadSavedPositionsFromDisk()
        savedPositionsCache = loaded
        return loaded
    }

    private func loadSavedPositionsFromDisk() -> SavedPositions {
        guard let url = Self.positionFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return [:] }

        LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: url)
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

    /// Updates the in-memory cache and writes it through to disk atomically;
    /// removes the file when empty. Single source of truth for position writes.
    private func writeSavedPositions(_ positions: SavedPositions) {
        savedPositionsCache = positions
        guard let url = Self.positionFileURL else { return }
        if positions.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(positions) else { return }
        try? LockedDeviceFileAccess.writeDataAtomically(data, to: url)
    }

    private func clearPlaybackPosition(for episodeID: UUID) {
        var positions = savedPositions()
        positions.removeValue(forKey: episodeID.uuidString)
        writeSavedPositions(positions)
    }

    private func clearPlaybackPosition(for episode: Episode) {
        var positions = savedPositions()
        positions.removeValue(forKey: playbackPositionKey(for: episode))
        positions.removeValue(forKey: episode.id.uuidString)
        writeSavedPositions(positions)
    }

    private func clearPlaybackPosition() {
        writeSavedPositions([:])
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

    /// Fetches external chapters off the playback-start path and applies them live
    /// when (and only if) the same episode is still the one playing. (P7)
    private func fetchExternalChaptersInBackground(url: URL, episodeID: UUID, subscriptionID: UUID, filter: ChapterFilter) {
        Task { [weak self] in
            guard let self,
                  let fetched = await self.fetchExternalChapters(url: url, episodeID: episodeID),
                  self.currentPlayerEpisode?.id == episodeID
            else { return }

            self.subscriptionStore.updateEpisodeChapters(
                subscriptionID: subscriptionID,
                episodeID: episodeID,
                chapters: fetched
            )
            self.currentPlayerEpisode?.chapters = fetched
            self.playbackEngine.updateChapters(fetched, filter: filter, for: episodeID)
        }
    }

    /// Bounded chapter fetch: an ephemeral session with a short request timeout so
    /// a slow/hung `podcast:chapters` endpoint can't linger on the default 60 s.
    private static let chapterFetchSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private func fetchExternalChapters(url: URL, episodeID: UUID) async -> [Chapter]? {
        guard let (data, response) = try? await Self.chapterFetchSession.data(from: url),
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

    /// Cached SwiftUI scenePhase belief (foreground == .active), kept for the
    /// `sceneActive=` diagnostic field. It can be **stale-true on a background
    /// relaunch**: iOS launches the app for a BGTask with no `.active` scenePhase
    /// event, so this default `true` is never reset. **Behavioural decisions must
    /// use `isAppForeground`** (the real UIApplication state) instead — relying on
    /// this caused a spurious "foreground" poll during a background BGTask wake that
    /// a later BGTask expiration then cancelled (see BACKGROUND_REFRESH_RESEARCH.md).
    var isSceneActive: Bool = true

    /// The true foreground state, read live from UIApplication rather than the cached
    /// `isSceneActive` (which can be stale on a background relaunch). Gates the
    /// due-feed poller and decides whether a BGTask expiration cancels the shared
    /// refresh cycle.
    var isAppForeground: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Called by the scenePhase observer so foreground polling can pause/resume
    /// in step with the app being foregrounded.
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
    }

    /// Due-feed poller: ticks every 30 seconds and refreshes only the feeds whose
    /// adaptive due date has arrived. Conditional requests (304s) make each check
    /// nearly free, so an hourly news feed is picked up within a minute or two of
    /// publish while a weekly show is fetched roughly once a day.
    ///
    /// The loop Task is never cancelled, so it keeps ticking whenever the process is
    /// alive — in the foreground AND while background audio playback keeps the app
    /// running. It therefore guards on `isSceneActive || isPlaying`: active
    /// listening is a fully-reliable, unthrottled refresh window for a podcast app
    /// (unlike best-effort BGAppRefreshTask), so new episodes are caught and queued
    /// for download while the user listens with the screen off. When the process is
    /// truly idle (no audio) iOS suspends it and this loop pauses until the next
    /// foreground/audio wake; BGAppRefreshTask covers that not-listening case (see
    /// BACKGROUND_REFRESH_RESEARCH.md). The work label flips to `backgroundAudioAlive`
    /// when the scene is inactive but audio is playing.
    func startForegroundPolling() {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                // Run when visible, or when background audio playback is keeping the
                // process alive (active listening). Skip only when truly idle.
                guard self.isAppForeground || self.isPlaying else { continue }
                let now = Date()
                let dueCount = self.subscriptionStore.subscriptions.filter { subscription in
                    !subscription.excludeFromAutoFeedRefresh
                        && self.nextRefreshDue(for: subscription) <= now
                }.count
                if dueCount > 0 {
                    let executionContext: FeedRefreshExecutionContext = self.isAppForeground ? .foregroundVisible : .backgroundAudioAlive
                    self.logger.info("feed.pollDue", "Due-feed poll found due subscriptions", metadata: [
                        "due": "\(dueCount)",
                        "appForeground": "\(self.isAppForeground)",
                        "sceneActive": "\(self.isSceneActive)",
                        "isPlaying": "\(self.isPlaying)",
                        "trigger": FeedRefreshTrigger.foregroundTimer.rawValue,
                        "executionContext": executionContext.rawValue
                    ])
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
            // Video playback (GPU decode + display on) is a major battery/heat source;
            // flag it so a warm-phone snapshot is attributable. Audio-path DSP (trim
            // silence / vocal boost) is already recorded at playback.start.
            "playingVideo": "\(currentPlayerEpisode?.mediaKind == .video)",
            "sceneActive": "\(isSceneActive)",
            "refreshActive": "\(activeRefreshCycle != nil)",
            "currentEpisode": currentPlayerEpisode?.title ?? "none",
            "currentTime": "\(Int(currentPlayerTime))",
            "queueCount": "\(downloadedQueue.count)",
            "subscriptionCount": "\(subscriptionStore.subscriptions.count)",
            "activeDownloads": "\(downloadProgress.count)",
            "activeDownloadSlots": "\(activeDownloadCount)",
            "pendingDownloads": "\(pendingDownloadQueue.count)",
            "upNext": upNextEpisode?.title ?? "none"
        ]
        if let activeRefreshCycleDiagnostics {
            context.merge(activeRefreshCycleDiagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new }
        }
        if let lastPlaybackTickDiagnostics {
            let ageMs = Date().timeIntervalSince(lastPlaybackTickDiagnostics.occurredAt) * 1000
            context.merge([
                "lastPlaybackTickAgeMs": String(format: "%.0f", ageMs),
                "lastPlaybackTickTotalMs": String(format: "%.1f", lastPlaybackTickDiagnostics.totalMs),
                "lastPlaybackTickDominantStage": lastPlaybackTickDiagnostics.dominantStage,
                "lastPlaybackTickDominantStageMs": String(format: "%.1f", lastPlaybackTickDiagnostics.dominantStageMs),
                "lastPlaybackTickPositionSaved": "\(lastPlaybackTickDiagnostics.positionSaved)",
                "lastPlaybackTickStatsCredited": "\(lastPlaybackTickDiagnostics.statsCredited)"
            ]) { _, new in new }
        }
        extra.forEach { context[$0.key] = $0.value }
        return context
    }
}


// AI CONTEXT — ListeningHistoryStore: persists per-episode listening log to
// Application Support/Autohop/listening-history.json (max 500 entries, oldest
// dropped). Entries are keyed by subscription-scoped episode GUID/URL
// (historyKey) so the same episode re-fetched from a feed merges into one entry
// without colliding across feeds. recordProgress() is called from AppState
// playback ticks; mark() sets played/archived status with a CompletionKind used
// later by ShowEngagementAnalyzer ("drifting" stats).
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
            // Status is intentionally left unchanged here: recordProgress only
            // accrues listening time; played/archived transitions go through mark().
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
        do {
            try syncDatabase.recordHistoryEntry(entry)
        } catch {
            // A swallowed failure here means the entry saved locally but the
            // outgoing CloudKit row was never queued — log so a "history didn't
            // sync" report leaves a trace (alwaysPersist survives the Diagnostics
            // toggle being off).
            AppLogger.shared.error("sync.historyMarkerFailed", "Failed to record pending history entry for sync", metadata: [
                "entryID": id,
                "error": String(describing: error)
            ], alwaysPersist: true)
        }
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
