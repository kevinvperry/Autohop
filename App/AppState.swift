import AVFoundation
import CloudKit
import Combine
import Foundation
import Network
import UIKit

// ============================================================================
// AI CONTEXT — App/AppState.swift
//
// PURPOSE: Central @MainActor coordinator and single source of truth for the
// whole app during the compatibility phase. Every view still observes this
// façade, while AppCompositionRoot now owns concrete production construction
// and explicit startup. Domain ownership moves out only in later approved stages.
//
// PERF (2026-07-02): currentPlayerTime is a proxy onto the dedicated PlaybackClock
// observable (PERF-1 targeted fix — the 2 Hz tick no longer invalidates every
// AppState observer; only PlayerView's scrubber + MiniPlayerBar observe the clock).
// releaseRadarProfile(for:) is memoized per subscription (PERF-2 — fingerprint-
// validated cache + off-main cold-launch warm-up via warmReleaseRadarProfileCache),
// so the 30 s due-feed poll no longer rebuilds every profile on the main thread.
// Download progress lives on the dedicated DownloadProgressModel observable
// (2026-07-04, same pattern as PlaybackClock): AppState.downloadProgress is a
// proxy; only progress-rendering surfaces observe the model, so ≥1% progress
// steps no longer invalidate every AppState observer during active downloads.
// RESPONSIBILITIES:
//  - Play Instant: a per-podcast, automatic-download-only FIFO interruption
//    pipeline. It warns over current playback, snapshots the interrupted episode
//    at switch time, plays eligible arrivals outside normal Up Next order, then
//    restores the snapshot after natural completion or Mark Played. Manual
//    pause, archive, episode selection, or Next cancels restoration. Persisted
//    automatic-download intent preserves provenance across URLSession relaunch.
//  - Player state: currentPlayerEpisode / currentPlayerTime / isPlaying;
//    starting playback (startPlayback), auto-advance (handleEpisodeFinished →
//    playNextEpisode), seek, chapter navigation, per-podcast audio settings
//    (speed / mono fold-down / vocal boost / trim silence) pushed live into PlaybackEngine.
//    Playback DECISIONS (effective preference, resume-vs-start-skip, speed
//    cycle/normalize, chapter prev/next targets) live in AutohopCore's
//    PlaybackSessionPolicy (tvOS Phase 0 item 4) — AppState delegates the
//    decisions and executes the effects. Keep new decisions in the policy.
//    CarPlay is deliberately just another UI surface over these same methods:
//    helpers such as episodeIsCurrent(_:), archiveCurrentEpisodeAndPlayNext(),
    //    cyclePlaybackSpeedForCurrentEpisode(), setPlaybackSpeedForCurrentEpisode(_:),
    //    and downloadEpisodeForCarPlayAction(_:) exist to keep CarPlay action routing
    //    thin while preserving one shared playback/download/queue/settings model.
    //    CarPlay-only cold launches use
//    resumePlaybackForCarPlayLaunchIfNeeded() to resume the restored episode
//    after the coordinator has installed its first Loading template; normal
//    iPhone launch still restores into a paused state.
//    External `podcast:chapters` are fetched AFTER play() begins (P7):
//    fetchExternalChaptersInBackground runs off the start path (bounded 10 s
//    ephemeral session) so a slow endpoint never delays the first audio frame,
//    then applies chapters live to the store, currentPlayerEpisode, and the
//    engine (PlaybackControlling.updateChapters) iff that episode still plays.
//  - Queue: downloadedQueue = QueueService priority order + manual overrides
//    (pin application now lives in AutohopCore's QueueModel.applyPins — tvOS
//    Phase 0 — with AppState delegating via orderedQueueWithOverrides),
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
//    scheduleAutoDownloadAfterRefresh persists a durable intent
//    (AutoDownloadIntentStore) BEFORE spawning the download Task, and
//    drainAutoDownloadIntents retries at launch/foreground/BG-task end — so a
//    BG-wake suspension after the feed cycle can never silently lose a
//    discovered episode (deep-scan AH-2026-06-28-01). Keep intents settled only
//    via resolveAutoDownloadIntentIfSettled. A permanently-broken enclosure (server
//    5xx/404 every attempt) is NOT retried on every drain: recordDownloadFailure sets
//    an exponential per-guid cooldown (downloadFailureBackoff) that runAutoDownloadAfterRefresh
//    honours (download.backoffSkipped); a success clears it. The intent stays until the
//    cooldown lapses, so recovery still happens — just not as per-drain churn.
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
//    Planning uses immutable snapshots and runs at utility priority off MainActor:
//    profile fallback calculation, prediction, scoring, deferred boosts, and sort
//    must never stall playback/UI. MainActor only filters mutable eligibility,
//    applies the budget, reconciles backlog state, and starts network refreshes.
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
//  - Autohop Relay protocol v2 (2026-07-12): AppState owns registration,
//    membership reconciliation, retry pressure, and wake dispatch. The broad
//    SubscriptionStore publisher is filtered through a canonical feed-URL set,
//    so episode merges never generate membership traffic. Registration/recovery
//    sends one idempotent full set; real subscribe/unsubscribe changes send
//    add/remove deltas against the persisted server-acknowledged set. Debounce
//    Tasks release their stored reference BEFORE URLSession begins, preventing a
//    later mutation from canceling an in-flight request. Feed sync and sync-nudge
//    use persisted exponential circuit breakers. A v2 `feed-updated` push maps
//    opaque IDs to local subscriptions and refreshes only those feeds; a legacy
//    ID-less push is capped to eight due feeds and respects failure backoff.
//    Unknown IDs trigger mapping reconciliation, never a full-library sweep.
//  - Auto archive: runAutoArchiveIfNeeded gates a full pass to every 25 min
//    (autoArchiveInterval) unless forced; runAutoArchive applies the three
//    per-podcast rules (after-played delay, inactive timeout, episode limit).
//    DRIVEN BY the 30-second foreground poller (startForegroundPolling,
//    reason: "poll.tick") so it runs on its own cadence whenever the app is
//    alive (foreground OR background-audio) — NOT only at cold launch and at a
//    completed feed-refresh cycle's tail, which left it barely running for
//    long-lived processes (fixed 2026-07-11). Also runs at app.startup and at
//    the end of a completed performRefreshCycle, plus the two manual buttons.
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
//  - Persistence side: playback positions live in
//    Persistence/PlaybackPositionStore.swift (AppState-split first carve, in
//    AutohopCore + headless-tested): write-through in-memory cache (P2),
//    subscription-scoped GUID/URL keys, resume normalization, legacy decode.
//    AppState keeps same-named thin wrappers (savePlaybackPosition /
//    savedPlaybackTime / clearPlaybackPosition) and the ~10 s tick throttle.
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
// STAGE 1–2 ARCHITECTURE (2026-07-18): AppCompositionRoot constructs the
// complete protocol-backed production graph. AppState init is side-effect-light;
// idempotent start() installs this compatibility callback graph before starting
// services, migrations, restoration, pollers, or launch tasks. Physically
// independent observables/policies/stores now live in their domain folders:
// PlaybackClock, PlaybackCueService, DownloadProgressModel,
// ReleaseRadarCyclePlanner, and ListeningHistoryStore. This is physical
// separation only; AppState remains the runtime owner until later stages.
//
// KEY COLLABORATORS: PlaybackEngine (audio), DownloadManager (URLSession),
// FeedService/RSSParser (network), SubscriptionStore (SQLite-backed model
// store), QueueService (pure queue ordering), ListeningHistoryStore &
// ListeningStatsStore (persistence, both in Persistence/), NotificationService,
// SleepTimerService,
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

// AI CONTEXT — Explicit AppState startup lifecycle introduced by decomposition
// Stage 1. Construction stores a complete dependency graph but does not start
// CloudKit, NWPathMonitor, service callbacks, pollers, resource monitoring,
// migrations, restoration, or launch maintenance. Production bootstrap publishes
// the constructed singleton first, then `start()` advances synchronously through
// starting → started. Re-entrant/repeated starts are ignored. `stopped` is
// reserved for Stage 12's deterministic process/test teardown; no restart from
// stopped is permitted during Stages 0–2.
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
    var playbackEngine: PlaybackControlling
    let chapterService: ChapterServicing
    let queueService: QueueServicing
    let settingsStore: SettingsStoring
    let subscriptionStore: SubscriptionStore
    let listeningHistoryStore = ListeningHistoryStore()
    let listeningStatsStore = ListeningStatsStore()
    let autoArchiveActivityStore = AutoArchiveActivityStore()
    /// Durable auto-download intents (AH-2026-06-28-01): recorded before the
    /// fire-and-forget download Task so a BG-wake suspension can't lose a
    /// discovered episode; drained at launch/foreground/BG-task end.
    let autoDownloadIntentStore = AutoDownloadIntentStore()

    /// Opt-in cross-device sync engine (CloudKit). Started only while
    /// AppSettings.iCloudSyncEnabled is true. History/stats pushes are coalesced
    /// on a ~60 s slow lane inside the engine; flushDeferredSyncPushes(reason:)
    /// is the lifecycle checkpoint that pushes them immediately (pause,
    /// sleep-timer/schedule pause, scene background/resign-active).
    private let cloudSyncEngine: CloudSyncEngine
    static let cloudKitContainerID = "iCloud.com.kevinperry.autohop"
    let downloadActivityStore = DownloadActivityStore()

    /// Autohop Pro entitlement (StoreKit 2) + the relay client it gates. See
    /// Docs/RELAY_TIER1_IMPLEMENTATION.md §4. autohopProStore owns purchase/
    /// entitlement state only; AppState owns WHEN to call the relay (register on
    /// entitlement gain, unregister on loss, feed-sync on subscription changes,
    /// dispatch wake-pushes) — wired in init() and relayTokenReceived(_:) below.
    let autohopProStore = AutohopProStore(enabled: ReleaseFeatures.autohopPro)
    private let relayClient = RelayClient.shared
    private var relayAPNsToken: String?
    private var relayRegistrationInFlight = false
    private var relayFeedSyncDebounceTask: Task<Void, Never>?
    private var relayFeedSyncInFlight = false
    private var relayFeedSyncNeedsReconcile = false
    private var relayForceFullFeedSync = false
    private var relayObservedFeedURLs = Set<String>()
    private static let relayAcknowledgedFeedsKey = "com.autohop.relay.acknowledgedFeeds.v2"
    private static let relayFeedFailureCountKey = "com.autohop.relay.feedSyncFailureCount.v2"
    private static let relayFeedNextAttemptKey = "com.autohop.relay.feedSyncNextAttempt.v2"
    /// CKContainer.fetchUserRecordID(), cached — the anonymous per-USER (not
    /// per-device) id the relay's Glossary calls `sync_group_id`, used to fan
    /// sync-nudge between a user's own devices (§6.4). Resolved lazily and
    /// cached in-memory only (re-fetches each cold launch — cheap, no local
    /// account-status caching needed since CloudKit already caches internally).
    private var relaySyncGroupID: String?
    private var relaySyncNudgeDebounceTask: Task<Void, Never>?
    private var relaySyncNudgeInFlight = false
    private var relaySyncNudgeDirty = false
    private static let relayNudgeFailureCountKey = "com.autohop.relay.nudgeFailureCount.v2"
    private static let relayNudgeNextAttemptKey = "com.autohop.relay.nudgeNextAttempt.v2"
    private static let relayNudgeLastSuccessKey = "com.autohop.relay.nudgeLastSuccess.v2"
    private static let relayNudgeMinimumInterval: TimeInterval = 5 * 60

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

    /// Per-episode download progress (0.0 – 1.0) lives on its own observable so
    /// progress ticks don't invalidate every AppState observer; this proxy keeps
    /// all existing call sites working. Views that RENDER progress must observe
    /// `downloadProgressModel` instead (reading this proxy in body renders stale).
    let downloadProgressModel = DownloadProgressModel()
    var downloadProgress: [UUID: Double] {
        get { downloadProgressModel.progress }
        set { downloadProgressModel.progress = newValue }
    }
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
        let isAutomatic: Bool
    }
    private var pendingDownloadQueue: [PendingDownload] = []
    private var activeDownloadCount = 0

    // MARK: Play Instant

    private struct PlayInstantCandidate: Equatable {
        let episodeID: UUID
        let subscriptionID: UUID
    }
    private struct PlayInstantInterruptedSession {
        let episodeID: UUID
        let subscriptionID: UUID
        var position: TimeInterval
    }
    private var playInstantQueue: [PlayInstantCandidate] = []
    private var playInstantInterruptedSession: PlayInstantInterruptedSession?
    private var activePlayInstantEpisodeID: UUID?
    private var playInstantTransitionTask: Task<Void, Never>?
    private var playInstantWarningPlayer: AVAudioPlayer?

    private(set) static var shared: AppState!
    private(set) var startupState: AppStartupState = .constructed
    private var callbacksInstalled = false

    private let logger = AppLogger.shared
    private let resourceMonitor = ResourceMonitor.shared
    private let autoArchiveInterval: TimeInterval = 25 * 60
    private var lastAutoArchiveSkipLogAt: Date?
    private var backgroundPlaybackDiagnosticsGeneration = 0

    // Network path monitor — tracks current interface type for download enforcement.
    private let networkMonitor = NWPathMonitor()
    private var latestNetworkPath: NWPath?

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

    /// Playback-position persistence (file + cache + key/normalization rules),
    /// extracted to Persistence/PlaybackPositionStore.swift (AppState-split
    /// first carve). AppState keeps same-named thin wrappers below; the 10 s
    /// tick write-throttle (positionSaveCounter) stays here.
    private let playbackPositionStore = PlaybackPositionStore()

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
        // 2026-07-04: the Up Next queue's COMPOSITION now roams (Kevin's
        // decision — the queue is the product's centre). The iPhone is the
        // authoring device: publish its ordered episode identities whenever
        // the queue actually changes. The store dedupes on entry equality, so
        // recomputes with no real change never dirty the sync record; the
        // recompute-on-cache-miss cadence (store change / pin change) is
        // exactly the set of moments the queue can differ.
        subscriptionStore.updateLocalQueueSnapshot(entries: computed.map { episode in
            QueueSnapshotEntry(
                episodeKey: PlaybackPositionStore.key(for: episode),
                subscriptionID: episode.subscriptionID,
                episodeTitle: episode.title
            )
        })
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

    /// Pin application moved to QueueModel.applyPins (AutohopCore, Phase 0 of
    /// the tvOS proposal) so every surface shares one Priority Stack
    /// composition; this wrapper feeds it the persisted pin lists.
    private func orderedQueueWithOverrides(_ baseQueue: [Episode]) -> [Episode] {
        QueueModel.applyPins(baseQueue, pins: QueuePins(
            playNextIDs: queueOverrideEpisodeIDs,
            playLastIDs: queueDemotedEpisodeIDs
        ))
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
    private var lastBackgroundAudioRefreshAt: Date?
    private let foregroundRefreshCapBypassStates: Set<FeedRefreshWindowState> = [.activeWindow, .preWindow]
    private let backgroundAudioCapBypassStates: Set<FeedRefreshWindowState> = [.preWindow, .activeWindow, .missedRelease]
    /// Automatic base cadence. State-specific scheduling expands this to five
    /// minutes in pre-window and 5–10 minutes after a missed release; random and
    /// unreliable feeds retain their 15–60 minute adaptive surveillance.
    private let automaticReleaseRadarBaseInterval: TimeInterval = 3 * 60
    private let playbackTickSlowThresholdMs = 120.0
    private let playbackTickSummarySampleInterval = 120

    private enum FeedRefreshTrigger: String, Sendable {
        case manualButton
        case foregroundTimer
        case backgroundRefreshTask = "BGAppRefreshTask"
        case backgroundProcessingTask = "BGProcessingTask"
        // Autohop Pro silent push (RELAY_TIER1_IMPLEMENTATION.md §4.4) — tagged
        // separately from the BGTask triggers so a log review can finally answer
        // "did the relay actually cause this refresh, or would the on-device
        // poller have found it anyway" — the question the whole feature exists
        // to answer, previously unanswerable from diagnostics.
        case relayPush = "AutohopRelay"
    }

    private enum FeedRefreshExecutionContext: String, Sendable {
        case manual
        case foregroundVisible
        case backgroundRefreshTask
        case backgroundAudioAlive
        case backgroundProcessingTask
        case relayPush
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
        // Seed the observed membership before subscribing to the store's broad
        // change publisher. Episode merges will still invalidate UI state, but
        // only an actual feed-membership difference will reach the relay.
        self.relayObservedFeedURLs = ReleaseFeatures.relayService
            ? Self.relayFeedURLs(in: subscriptionStore.subscriptions)
            : []
    }

    /// Installs the existing compatibility callback graph exactly once.
    ///
    /// AI CONTEXT — Stage 1 intentionally moves ownership of no callback. This
    /// method is still AppState code; its sole purpose is to keep synchronous
    /// dependency construction separate from runtime activation. Production
    /// `start()` calls it before CloudKit, the network monitor, restoration,
    /// migrations, pollers, and launch tasks, preserving the former bootstrap
    /// ordering. Later stages transfer each callback to its domain coordinator.
    private func installRuntimeCallbacksIfNeeded() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

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
        // Relay sync-nudge send-side (§6.4) — see AppState's "Autohop Relay" MARK
        // section for scheduleRelaySyncNudge()'s debounce/gating.
        cloudSyncEngine.onLocalChangesPushed = { [weak self] in
            guard ReleaseFeatures.relayService else { return }
            await MainActor.run { self?.scheduleRelaySyncNudge() }
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
                    if ReleaseFeatures.relayService {
                        self.scheduleRelayFeedSyncIfMembershipChanged()
                    }
                }
            }
            .store(in: &cancellables)

        // Autohop Pro gate (§4.1): register with the relay the moment BOTH an
        // active entitlement and an APNs token are available; unregister the
        // instant entitlement lapses so a lapsed subscriber's feeds/token stop
        // being crawled/pushed. relayTokenReceived(_:) drives the other half of
        // this (token arriving after entitlement is already active).
        if ReleaseFeatures.relayService {
            autohopProStore.$isPro
                .removeDuplicates()
                .sink { [weak self] isPro in
                    Task { @MainActor in
                        guard let self else { return }
                        if isPro {
                            await self.registerWithRelayIfPossible()
                        } else if self.relayClient.isRegistered {
                            _ = try? await self.relayClient.unregister()
                            self.clearRelayFeedProtocolState()
                        }
                    }
                }
                .store(in: &cancellables)
        }

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
    }

    /// Creates a podcast that another device subscribed to, by fetching its feed,
    /// then applies the synced per-podcast settings on top. Invoked by the sync
    /// engine when a remote subscription record has no local match.
    /// RANK-CORRUPTION FIX (2026-07-04): passes `reindexRanks: false` to
    /// `addSubscription` below — remote materialization must NOT compact
    /// every subscription's rank to its array position, or later-arriving
    /// absolute synced ranks collide with the compacted 1..n values and the
    /// library ends up in arrival order (the same bug class fixed for TV's
    /// `materialize` path; see `SubscriptionStore.addSubscription`'s
    /// `reindexRanks` doc). Local paths (subscribe, OPML import) keep the
    /// default reindexing, which is correct for them.
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
                latestEpisode: result.latestEpisode, insertAtBottom: true,
                reindexRanks: false
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

    /// Explicit, idempotent runtime start. All Stage 0–2 callbacks remain owned
    /// by AppState; later stages transfer them one domain at a time.
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

        let state = self
        // Install the complete pre-existing callback graph before any service can
        // emit runtime events. This preserves the former init → bootstrap order.
        installRuntimeCallbacksIfNeeded()

        // These effects previously ran during/after bootstrap. Keeping them at
        // the beginning of explicit start makes construction side-effect-light
        // while preserving their order relative to the callback graph.
        if settingsStore.appSettings.iCloudSyncEnabled {
            cloudSyncEngine.start()
        }
        refreshUpNextEpisode()
        startNetworkMonitor()
        subscriptionStore.cleanupExpiredPreviewSubscriptions(
            subscriptionIDsWithHistory: Set(listeningHistoryStore.entries.map(\.subscriptionID))
        )

        // Episode completion
        state.playbackEngine.onEpisodeFinished = { [weak state] episode in
            Task { @MainActor in await state?.handleEpisodeFinished(episode) }
        }

        // Scrubber + Now Playing time sync (fires every 0.5 s)
        state.playbackEngine.onTimeUpdate = { [weak state] time in
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
        state.playbackEngine.onPlaybackInterrupted = { [weak state] in
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
        // "Audio hijack" fix (2026-07-12): a removed output device (AirPods)
        // returning fires this after the engine has re-claimed the audio
        // session (PlaybackEngine.scheduleNowPlayingReassertAfterRouteRestore)
        // — re-push the FULL Now Playing card so an AirPods stem-press lands
        // on Autohop instead of falling through to Apple Music.
        if let routeAwarePlaybackEngine = state.playbackEngine as? PlaybackEngine {
            routeAwarePlaybackEngine.onRouteRestored = { [weak state] in
                Task { @MainActor in
                    state?.reassertNowPlayingCard(reason: "routeRestored")
                }
            }
        }
        state.playbackEngine.onPlaybackResumed = { [weak state] in
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
        state.playbackEngine.onManualSkipForward = { [weak state] seconds in
            Task { @MainActor in
                state?.listeningStatsStore.addManualSkipForward(
                    seconds,
                    subscriptionID: state?.currentPlayerEpisode?.subscriptionID
                )
            }
        }
        state.playbackEngine.onAutoSkip = { [weak state] seconds in
            Task { @MainActor in
                state?.listeningStatsStore.addAutoSkip(
                    seconds,
                    subscriptionID: state?.currentPlayerEpisode?.subscriptionID
                )
            }
        }
        state.playbackEngine.onTrimSilenceSaved = { [weak state] seconds in
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
                // AI CONTEXT — A persisted intent is the authoritative proof that
                // this background completion originated from automatic feed policy.
                // Capture it before the downloaded state settles/removes the intent;
                // manual background downloads must never trigger Play Instant.
                let wasAutomatic = state.autoDownloadIntentStore.contains(episodeID: episodeID)
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
                    if wasAutomatic {
                        state.enqueuePlayInstantIfEligible(episodeID: episodeID, subscriptionID: subscriptionID)
                    }
                }
                state.resolveAutoDownloadIntentIfSettled(episodeID: episodeID, subscriptionID: subscriptionID)
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

        // Watchdog retry: bounded exponential delay prevents a broken CDN or resume
        // blob from occupying a slot in an endless ten-minute cancel/recreate loop.
        downloadManager.onWatchdogCancelled = { [weak state] episodeID in
            Task { @MainActor in
                guard let state else { return }
                let attempt = (state.downloadWatchdogRetryCounts[episodeID] ?? 0) + 1
                state.downloadWatchdogRetryCounts[episodeID] = attempt
                guard attempt <= 3 else {
                    // Retire both any surviving URLSession task and orphaned
                    // watchdog clocks before publishing the terminal failure.
                    // cancelDownload is deliberately idempotent/no-task safe.
                    state.downloadManager.cancelDownload(episodeID: episodeID)
                    state.downloadManager.clearResumeData(episodeID: episodeID)
                    if let activity = state.downloadActivityStore.activeActivities.first(where: { $0.episodeID == episodeID }),
                       let episode = state.subscriptionStore.episode(subscriptionID: activity.subscriptionID, episodeID: episodeID),
                       let subscription = state.subscriptionStore.subscription(id: activity.subscriptionID) {
                        state.subscriptionStore.markEpisodeDownloadFailed(
                            subscriptionID: activity.subscriptionID,
                            episodeID: episodeID
                        )
                        state.downloadActivityStore.fail(
                            episode: episode,
                            podcastTitle: subscription.title,
                            error: "Download stalled repeatedly. Tap to retry."
                        )
                    }
                    state.logger.warning("download.watchdogRetryExhausted", "Automatic retries stopped after repeated confirmed stalls", metadata: [
                        "episodeID": episodeID.uuidString,
                        "attempts": "\(attempt - 1)"
                    ])
                    return
                }
                let delay = TimeInterval(30 * (1 << (attempt - 1)))
                state.logger.info("download.watchdogRetryScheduled", "Scheduled bounded watchdog retry", metadata: [
                    "episodeID": episodeID.uuidString,
                    "attempt": "\(attempt)",
                    "delaySeconds": "\(Int(delay))"
                ])
                try? await Task.sleep(for: .seconds(delay))
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
                state.persistCurrentPlaybackPosition()
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
                state.listeningHistoryStore.save()
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
            onSkipForward:  { s in Task { @MainActor in state.skipForward(seconds: s) } },
            onSkipBackward: { s in Task { @MainActor in state.seek(to: max(0, state.currentPlayerTime - s)) } },
            onNextTrack: {
                Task { @MainActor in
                    guard let ep = state.currentPlayerEpisode else { return }
                    // AI CONTEXT — Remote/CarPlay Next is a deliberate switch,
                    // not natural EOF, so it cancels Play Instant's return point.
                    if state.activePlayInstantEpisodeID != nil || state.playInstantTransitionTask != nil {
                        state.cancelPlayInstantSession(reason: "manualNextTrack")
                    }
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
            // After orphan repair (interrupted transfers → .failed), retry any
            // auto-downloads whose BG-wake intent never started or died mid-flight.
            await state.drainAutoDownloadIntents(reason: "launch")
        }
        // `AppState.shared` was already published right after creation (above) so a
        // re-entrant bootstrap can't create a second instance.
        Task { @MainActor in
            let badgeCount = state.settingsStore.appSettings.showQueueBadge ? state.downloadedQueue.count : 0
            NotificationService.shared.updateBadge(count: badgeCount)
        }
        let bootstrapFinishedAt = CFAbsoluteTimeGetCurrent()
        state.logger.info("app.bootstrapTiming", "Measured synchronous cold-bootstrap stages", metadata: [
            "totalMs": String(format: "%.1f", (bootstrapFinishedAt - bootstrapStartedAt) * 1000),
            "constructionMs": String(format: "%.1f", (constructionFinishedAt - bootstrapStartedAt) * 1000),
            "wiringAndRestoreMs": String(format: "%.1f", (bootstrapFinishedAt - constructionFinishedAt) * 1000),
            "subscriptionCount": "\(state.subscriptionStore.subscriptions.count)",
            "historyCount": "\(state.listeningHistoryStore.entries.count)"
        ])
        startupState = .started
    }

    private func beginStartupTransition() -> Bool {
        guard startupState == .constructed else {
            logger.info("app.startSkipped", "AppState start ignored because runtime is already starting or started", metadata: [
                "startupState": startupState.rawValue
            ])
            return false
        }
        startupState = .starting
        return true
    }

#if DEBUG
    /// Stage 0 harness seam: exercises the exact production startup-state guard
    /// without installing OS callbacks or launching long-lived work.
    @discardableResult
    func _runCharacterizationStart(_ work: () -> Void) -> Bool {
        guard beginStartupTransition() else { return false }
        work()
        startupState = .started
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
        guard let episode = currentPlayerEpisode,
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        else { return }
        NowPlayingService.shared.update(
            episode: episode,
            podcastTitle: subscription.title,
            currentTime: currentPlayerTime,
            duration: episode.durationSeconds,
            speed: effectiveSpeed(for: subscription),
            isPlaying: isPlaying,
            artworkURL: episode.artworkURL ?? subscription.artworkURL
        )
        logger.info("nowPlaying.reasserted", "Now Playing card re-pushed", metadata: [
            "reason": reason,
            "episode": episode.title,
            "isPlaying": "\(isPlaying)"
        ])
    }

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
            if activePlayInstantEpisodeID != nil || playInstantTransitionTask != nil {
                cancelPlayInstantSession(reason: "pausedDuringPlayInstant")
            }
            playbackEngine.pause()
            isPlaying = false
            listeningStatsStore.save()
            // Capture the freshest position + history row (mirrors the
            // scene-background path) so the flush pushes the exact pause point,
            // not the last periodic progress tick.
            persistCurrentPlaybackPosition()
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

    /// Manual skip-forward: credits the skipped seconds to the "Skipping" time-saved stat,
    /// then seeks. Both the Player skip button and the lock-screen / AirPods skip command
    /// route through here — previously they called `seek(to:)` directly, so the manual-skip
    /// stat (onManualSkipForward → addManualSkipForward) never ran and the Stats "Skipping"
    /// row was permanently 0s. `seek(to:)` keeps its own side effects (sleep-schedule
    /// "still listening", logging, position persistence).
    func skipForward(seconds: TimeInterval) {
        let duration = currentPlayerEpisode?.durationSeconds
        let actualSkipped = PlaybackSeekBoundaryPolicy.actualForwardSkip(
            from: currentPlayerTime,
            seconds: seconds,
            duration: duration
        )
        if actualSkipped > 0 {
            listeningStatsStore.addManualSkipForward(
                actualSkipped,
                subscriptionID: currentPlayerEpisode?.subscriptionID
            )
        }
        seek(to: currentPlayerTime + seconds)
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
        if PlaybackSeekBoundaryPolicy.reachesCompletion(requestedTime: seconds, duration: duration),
           let episode = currentPlayerEpisode {
            // Stop synchronously before scheduling completion so neither backend
            // can emit a competing EOF callback or restart an engine loop at zero.
            playbackEngine.stop()
            currentPlayerTime = duration ?? target
            isPlaying = false
            logger.info("player.seekCompleted", "Seek reached episode end; completing instead of restarting at EOF", metadata: [
                "episode": episode.title,
                "requested": String(format: "%.2f", seconds),
                "duration": duration.map { String(format: "%.2f", $0) } ?? "unknown"
            ])
            Task { @MainActor [weak self] in
                await self?.handleEpisodeFinished(episode)
            }
            return
        }
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

    /// Single mutation gateway for every chapter UI. Persist first, then push the
    /// resulting filter into the active engine. Disabling the current chapter is
    /// allowed and causes an immediate deterministic skip.
    func toggleChapter(subscriptionID: UUID, position: Int) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        var filter = subscription.chapterFilter
        if filter.skippedPositions.contains(position) {
            filter.skippedPositions.remove(position)
        } else {
            filter.skippedPositions.insert(position)
        }
        applyChapterFilter(filter, subscriptionID: subscriptionID)
    }

    func applyChapterFilter(_ filter: ChapterFilter, subscriptionID: UUID) {
        subscriptionStore.updateChapterFilter(subscriptionID: subscriptionID, filter: filter)
        guard let episode = currentPlayerEpisode, episode.subscriptionID == subscriptionID else { return }
        playbackEngine.updateChapterFilter(filter, for: episode.id)
    }

    var previousChapterNavigationTarget: TimeInterval? {
        guard let episode = currentPlayerEpisode,
              let sub = subscriptionStore.subscription(id: episode.subscriptionID) else { return nil }
        return PlaybackSessionPolicy.previousChapterStart(
            at: currentPlayerTime,
            currentChapter: currentChapter,
            in: chapterService.activeChapters(for: episode, filter: sub.chapterFilter)
        )
    }

    var nextChapterNavigationTarget: TimeInterval? {
        guard let episode = currentPlayerEpisode,
              let sub = subscriptionStore.subscription(id: episode.subscriptionID) else { return nil }
        return PlaybackSessionPolicy.nextChapterStart(
            at: currentPlayerTime,
            in: chapterService.activeChapters(for: episode, filter: sub.chapterFilter)
        )
    }

    // Time-based target decisions stay functional when the current chapter has
    // just been removed from the active list by a live settings edit.
    func navigateToPreviousChapter() {
        guard let target = previousChapterNavigationTarget else { return }
        seek(to: target)
    }

    func navigateToNextChapter() {
        guard let target = nextChapterNavigationTarget else { return }
        seek(to: target)
    }

    // MARK: - Download

    func downloadLatestEpisode(for subscription: Subscription) async {
        // Use newestEpisode (episode list) not the denormalised latestEpisode, which can
        // lag — otherwise the Subscriptions row's Download button would fetch a stale episode.
        guard let episode = subscription.newestEpisode else {
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

    func downloadEpisodeForCarPlayAction(_ episode: Episode) async -> Episode? {
        guard let subscription = subscriptionStore.subscription(id: episode.subscriptionID) else { return nil }
        if let readyEpisode = carPlayPlayableDownloadedEpisode(subscriptionID: subscription.id, episodeID: episode.id) {
            return readyEpisode
        }

        let episodeToDownload = subscriptionStore.episode(subscriptionID: subscription.id, episodeID: episode.id) ?? episode
        await downloadEpisode(
            episodeToDownload,
            subscriptionID: subscription.id,
            podcastTitle: subscription.title,
            showCompletionMessage: false
        )
        return await waitForCarPlayDownloadedEpisode(subscriptionID: subscription.id, episodeID: episode.id)
    }

    private func waitForCarPlayDownloadedEpisode(subscriptionID: UUID, episodeID: UUID) async -> Episode? {
        for _ in 0..<3600 {
            if Task.isCancelled { return nil }
            if let readyEpisode = carPlayPlayableDownloadedEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
                return readyEpisode
            }
            guard carPlayDownloadIsActive(subscriptionID: subscriptionID, episodeID: episodeID) else {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func carPlayPlayableDownloadedEpisode(subscriptionID: UUID, episodeID: UUID) -> Episode? {
        guard let episode = subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID),
              episode.downloadState == .downloaded,
              episode.localFileURL != nil || episode.localFileName != nil
        else { return nil }
        return episode
    }

    private func carPlayDownloadIsActive(subscriptionID: UUID, episodeID: UUID) -> Bool {
        if pendingDownloadQueue.contains(where: { $0.subscriptionID == subscriptionID && $0.episode.id == episodeID }) {
            return true
        }
        if downloadProgress[episodeID] != nil {
            return true
        }
        if downloadActivityStore.activeActivities.contains(where: { activity in
            activity.subscriptionID == subscriptionID &&
            activity.episodeID == episodeID &&
            (activity.status == .downloading || activity.status == .paused)
        }) {
            return true
        }
        if let episode = subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID) {
            return episode.downloadState == .queued || episode.downloadState == .downloading
        }
        return false
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
        let completesPlayInstant = activePlayInstantEpisodeID == episode.id
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
        if completesPlayInstant {
            await finishPlayInstantAndAdvance(reason: "markedPlayed")
        }
    }

    func archiveEpisode(_ episode: Episode, completionKind: CompletionKind = .manuallyArchived) async {
        logger.info("episode.archive", "Archiving episode", metadata: [
            "episode": episode.title
        ])
        if currentPlayerEpisode?.id == episode.id {
            if activePlayInstantEpisodeID == episode.id || playInstantInterruptedSession != nil {
                cancelPlayInstantSession(reason: "archiveCurrentEpisode")
            }
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
        showCompletionMessage: Bool,
        isAutomatic: Bool = false
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
                showCompletionMessage: showCompletionMessage,
                isAutomatic: isAutomatic
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
            downloadWatchdogRetryCounts.removeValue(forKey: episode.id)
            downloadFailureBackoff.removeValue(forKey: episode.guid)
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
            if isAutomatic {
                enqueuePlayInstantIfEligible(episodeID: episode.id, subscriptionID: subscriptionID)
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
            recordDownloadFailure(guid: episode.guid, title: episode.title)
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
                showCompletionMessage: next.showCompletionMessage,
                isAutomatic: next.isAutomatic
            )
        }
    }

    // MARK: - Play Instant

    /// Accepts only the successful automatic-download boundary. Eligibility is
    /// re-read from the current subscription so disabling the toggle while a
    /// transfer is running prevents an interruption. A paused/idle player does
    /// not qualify and the arrival remains in normal Up Next order.
    private func enqueuePlayInstantIfEligible(episodeID: UUID, subscriptionID: UUID) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID),
              subscription.autoArchiveSettings.playInstantEnabled,
              let episode = subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID),
              subscription.downloadFilterSettings.evaluation(for: episode).isIncluded,
              episode.downloadState == .downloaded,
              currentPlayerEpisode?.id != episodeID,
              isPlaying || playbackEngine.isPlaying
        else { return }

        let candidate = PlayInstantCandidate(episodeID: episodeID, subscriptionID: subscriptionID)
        guard activePlayInstantEpisodeID != episodeID,
              !playInstantQueue.contains(candidate) else { return }
        playInstantQueue.append(candidate)
        logger.info("playInstant.queued", "Queued automatically downloaded episode for instant playback", metadata: [
            "episode": episode.title,
            "podcast": subscription.title,
            "queueDepth": "\(playInstantQueue.count)"
        ])
        beginPlayInstantTransitionIfNeeded()
    }

    private func beginPlayInstantTransitionIfNeeded() {
        guard activePlayInstantEpisodeID == nil,
              playInstantTransitionTask == nil,
              !playInstantQueue.isEmpty,
              let interruptedEpisode = currentPlayerEpisode,
              isPlaying || playbackEngine.isPlaying else { return }

        if playInstantInterruptedSession == nil {
            playInstantInterruptedSession = PlayInstantInterruptedSession(
                episodeID: interruptedEpisode.id,
                subscriptionID: interruptedEpisode.subscriptionID,
                position: currentPlayerTime
            )
        }
        let expectedCurrentID = interruptedEpisode.id
        playPlayInstantWarningTone()
        logger.info("playInstant.warning", "Warning before switching to Play Instant episode", metadata: [
            "interruptedEpisode": interruptedEpisode.title,
            "delaySeconds": "2"
        ])

        playInstantTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.playInstantTransitionTask = nil
            guard self.currentPlayerEpisode?.id == expectedCurrentID,
                  self.isPlaying || self.playbackEngine.isPlaying else {
                self.cancelPlayInstantSession(reason: "playbackChangedDuringWarning")
                return
            }
            self.playInstantInterruptedSession?.position = self.currentPlayerTime
            self.savePlaybackPosition()
            await self.startNextPlayInstantCandidate()
        }
    }

    private func startNextPlayInstantCandidate() async {
        while !playInstantQueue.isEmpty {
            let candidate = playInstantQueue.removeFirst()
            guard let subscription = subscriptionStore.subscription(id: candidate.subscriptionID),
                  subscription.autoArchiveSettings.playInstantEnabled,
                  let episode = subscriptionStore.episode(
                    subscriptionID: candidate.subscriptionID,
                    episodeID: candidate.episodeID
                  ),
                  episode.downloadState == .downloaded,
                  localAudioFileExists(for: episode)
            else { continue }

            activePlayInstantEpisodeID = episode.id
            logger.info("playInstant.started", "Starting Play Instant episode", metadata: [
                "episode": episode.title,
                "podcast": subscription.title,
                "remainingInstantQueue": "\(playInstantQueue.count)"
            ])
            if await startPlayback(episode: episode, resumeFrom: 0) { return }
            activePlayInstantEpisodeID = nil
        }
        await restoreInterruptedPlayInstantSession(reason: "noPlayableInstantCandidate")
    }

    private func finishPlayInstantAndAdvance(reason: String) async {
        activePlayInstantEpisodeID = nil
        if !playInstantQueue.isEmpty {
            playPlayInstantWarningTone()
            try? await Task.sleep(for: .seconds(2))
            await startNextPlayInstantCandidate()
            return
        }
        await restoreInterruptedPlayInstantSession(reason: reason)
    }

    private func restoreInterruptedPlayInstantSession(reason: String) async {
        guard let interrupted = playInstantInterruptedSession else {
            cancelPlayInstantSession(reason: "missingInterruptedSession")
            return
        }
        playInstantInterruptedSession = nil
        activePlayInstantEpisodeID = nil
        guard let episode = subscriptionStore.episode(
            subscriptionID: interrupted.subscriptionID,
            episodeID: interrupted.episodeID
        ), episode.downloadState == .downloaded, localAudioFileExists(for: episode) else {
            logger.warning("playInstant.restoreUnavailable", "Interrupted episode was no longer available to resume", metadata: [
                "episodeID": interrupted.episodeID.uuidString,
                "reason": reason
            ])
            await playNextEpisode()
            return
        }
        logger.info("playInstant.restoring", "Returning to episode interrupted by Play Instant", metadata: [
            "episode": episode.title,
            "positionSeconds": String(format: "%.1f", interrupted.position),
            "reason": reason
        ])
        _ = await startPlayback(episode: episode, resumeFrom: interrupted.position)
    }

    private func cancelPlayInstantSession(reason: String) {
        let hadSession = playInstantInterruptedSession != nil || activePlayInstantEpisodeID != nil || !playInstantQueue.isEmpty
        playInstantTransitionTask?.cancel()
        playInstantTransitionTask = nil
        playInstantWarningPlayer?.stop()
        playInstantWarningPlayer = nil
        playInstantQueue.removeAll()
        playInstantInterruptedSession = nil
        activePlayInstantEpisodeID = nil
        if hadSession {
            logger.info("playInstant.cancelled", "Cancelled Play Instant return session after deliberate user action", metadata: [
                "reason": reason
            ])
        }
    }

    /// Generates a quiet two-note PCM cue in memory; no bundled sound asset and
    /// no network/file dependency. AVAudioPlayer shares Autohop's active audio
    /// session, allowing the warning to sound gently over the interrupted show.
    private func playPlayInstantWarningTone() {
        guard let data = PlaybackCueService.makePlayInstantWarningWAV() else { return }
        playInstantWarningPlayer = try? AVAudioPlayer(data: data)
        playInstantWarningPlayer?.volume = 0.22
        playInstantWarningPlayer?.prepareToPlay()
        playInstantWarningPlayer?.play()
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
        if activePlayInstantEpisodeID != nil || playInstantTransitionTask != nil || playInstantInterruptedSession != nil {
            cancelPlayInstantSession(reason: "selectedDifferentEpisode")
        }
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
        if activePlayInstantEpisodeID != nil || playInstantTransitionTask != nil || playInstantInterruptedSession != nil {
            cancelPlayInstantSession(reason: "skippedToDifferentEpisode")
        }
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
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        else { return }

        // Cycle decision lives in PlaybackSessionPolicy (Phase 0 item 4).
        guard let nextSpeed = PlaybackSessionPolicy.cycledSpeed(
            after: subscription.playbackPreference.speed
        ) else { return }
        updatePlaybackSpeed(for: subscription.id, speed: nextSpeed)
    }

    func setPlaybackSpeedForCurrentEpisode(_ speed: Double) {
        guard !sharedListeningActive,
              let episode = currentPlayerEpisode,
              let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        else { return }

        // Nearest-option decision lives in PlaybackSessionPolicy (Phase 0 item 4).
        updatePlaybackSpeed(
            for: subscription.id,
            speed: PlaybackSessionPolicy.normalizedSpeed(closestTo: speed)
        )
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

    // AI CONTEXT — Per-subscription Volume Adjustment is stored inside the same
    // PlaybackPreference sync unit as speed/boost/mono. It is a gain stage in dB,
    // not a write to device volume; sleep fading remains independently controlled
    // through PlaybackControlling.setVolume().
    func updateVolumeAdjustment(for subscriptionID: UUID, adjustment: Int) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        let clamped = PlaybackPreference.clampedVolumeAdjustment(adjustment)
        var preference = subscription.playbackPreference
        guard preference.volumeAdjustment != clamped else { return }
        preference.volumeAdjustment = clamped
        subscriptionStore.updatePlaybackPreference(subscriptionID: subscriptionID, preference: preference)
        logger.info("player.volumeAdjustment", "Subscription volume adjustment changed", metadata: [
            "podcast": subscription.title,
            "adjustmentDB": "\(clamped)"
        ])
        if currentPlayerEpisode?.subscriptionID == subscriptionID {
            playbackEngine.updateVolumeAdjustment(clamped)
        }
    }

    // AI CONTEXT — Mono Audio is persisted inside PlaybackPreference so it uses
    // the existing per-podcast sync boundary. A live change rebuilds/restarts the
    // audio engine at the current file position; video remains on AVPlayer.
    func updateAudioChannelMode(for subscriptionID: UUID, mode: AudioChannelMode) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        var preference = subscription.playbackPreference
        guard preference.audioChannelMode != mode else { return }
        preference.audioChannelMode = mode
        subscriptionStore.updatePlaybackPreference(subscriptionID: subscriptionID, preference: preference)
        logger.info("player.audioChannelMode", "Audio channel mode changed", metadata: [
            "podcast": subscription.title,
            "mode": mode.title
        ])
        if currentPlayerEpisode?.subscriptionID == subscriptionID {
            playbackEngine.updateAudioChannelMode(mode)
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

    // AI CONTEXT — Episode-trim mutations enter through this single boundary.
    // Optional arguments let either shared UI row merge with the latest stored
    // preference instead of overwriting its sibling with a captured/stale
    // Subscription value. EpisodeTrimControlRow already debounces taps, so this
    // method performs exactly one store publication and one live-engine update.
    func updateEpisodeTrim(
        for subscriptionID: UUID,
        startSkipSeconds: TimeInterval? = nil,
        endSkipSeconds: TimeInterval? = nil
    ) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else { return }
        var preference = subscription.playbackPreference
        if let startSkipSeconds {
            preference.startSkipSeconds = normalizedEpisodeTrim(startSkipSeconds)
        }
        if let endSkipSeconds {
            preference.endSkipSeconds = normalizedEpisodeTrim(endSkipSeconds)
        }
        guard preference != subscription.playbackPreference else { return }

        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )
        logger.info("settings.episodeTrim", "Podcast episode trim changed", metadata: [
            "podcast": subscription.title,
            "startSeconds": "\(Int(preference.startSkipSeconds))",
            "endSeconds": "\(Int(preference.endSkipSeconds))"
        ])

        if currentPlayerEpisode?.subscriptionID == subscriptionID {
            playbackEngine.updateEpisodeTrim(
                startSkipSeconds: preference.startSkipSeconds,
                endSkipSeconds: preference.endSkipSeconds
            )
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

    func updateDefaultAudioChannelMode(_ mode: AudioChannelMode) {
        logger.info("settings.defaultAudioChannelMode", "Default audio channel mode changed", metadata: [
            "mode": mode.title
        ])
        mutateDefaultPlaybackPreference { $0.audioChannelMode = mode }
    }

    func updateDefaultTrimSilence(_ amount: TrimSilenceAmount) {
        logger.info("settings.defaultTrimSilence", "Default Trim Silence changed", metadata: ["amount": amount.title])
        mutateDefaultPlaybackPreference { $0.trimSilence = amount }
    }

    // AI CONTEXT — Combined default-trim mutation used by both shared rows. A
    // single assignment to @Published AppSettings means one atomic save, not a
    // write for every intermediate button tap.
    func updateDefaultEpisodeTrim(
        startSkipSeconds: TimeInterval? = nil,
        endSkipSeconds: TimeInterval? = nil
    ) {
        mutateDefaultPlaybackPreference { preference in
            if let startSkipSeconds {
                preference.startSkipSeconds = normalizedEpisodeTrim(startSkipSeconds)
            }
            if let endSkipSeconds {
                preference.endSkipSeconds = normalizedEpisodeTrim(endSkipSeconds)
            }
        }
    }

    private func normalizedEpisodeTrim(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(300, max(0, seconds))
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
        // Decision lives in PlaybackSessionPolicy (AutohopCore, Phase 0 item 4)
        // so every surface resolves browse-feed + Shared Listening overrides
        // identically; this wrapper feeds it the live settings.
        PlaybackSessionPolicy.effectivePreference(
            subscriptionPreference: subscription.playbackPreference,
            isBrowseFeed: subscription.browseDate != nil,
            defaultPreference: settingsStore.appSettings.defaultPlaybackPreference,
            sharedListeningSpeed: settingsStore.appSettings.sharedListeningActive
                ? settingsStore.appSettings.sharedListeningSpeed
                : nil
        )
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
        playbackEngine.updateAudioChannelMode(preference.audioChannelMode)
        playbackEngine.updateEpisodeTrim(
            startSkipSeconds: preference.startSkipSeconds,
            endSkipSeconds: preference.endSkipSeconds
        )
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

            // Resume-vs-start-skip decision lives in PlaybackSessionPolicy
            // (Phase 0 item 4): a mid-episode resume overrides start-skip and
            // seeks; otherwise report the start-skip offset (not 0) and credit
            // a fresh "episode started" to stats.
            let start = PlaybackSessionPolicy.startResolution(
                resumeTime: safeResumeTime,
                startSkipSeconds: preference.startSkipSeconds
            )
            if let seekTarget = start.seekTarget {
                playbackEngine.seek(to: seekTarget)
            }
            currentPlayerTime = start.reportedStartTime

            subscriptionStore.markEpisodePlaying(subscriptionID: subscription.id, episodeID: playableEpisode.id)
            if start.isFreshStart {
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

            // CROSS-DEVICE "NOW PLAYING" FRESHNESS (2026-07-11, Kevin's TV
            // round 7: the TV's Continue Listening hero was "a show behind").
            // Seed/stamp this episode's history entry NOW and force-push it —
            // previously the entry only went dirty at the first playback
            // progress tick and then sat out the engine's ~60 s slow-lane
            // debounce, so another device had no idea a new episode had
            // started for the first minute-plus. listenedSeconds: 0 accrues
            // nothing; the write's only job is the fresh lastListenedAt stamp
            // (which wins the hero's recency comparison everywhere) and the
            // starting position. max(…, 1) because the TV-side hero filter
            // requires a usable (> 0) resume position.
            listeningHistoryStore.recordProgress(
                episode: playableEpisode,
                podcastTitle: subscription.title,
                artworkURL: playableEpisode.artworkURL ?? subscription.artworkURL,
                listenedSeconds: 0,
                positionSeconds: max(start.reportedStartTime, 1),
                durationSeconds: playableEpisode.durationSeconds
            )
            flushDeferredSyncPushes(reason: "playback.start")

            // Chapters from an external `podcast:chapters` feed are fetched AFTER
            // playback has started (P7) so a slow/hung endpoint never delays the
            // first audio frame; they are applied live to the store, the now-
            // playing episode, and the engine (chapter-skip) once they arrive.
            if playableEpisode.chapters.isEmpty, let chaptersURL = playableEpisode.externalChaptersURL {
                fetchExternalChaptersInBackground(
                    url: chaptersURL,
                    episodeID: playableEpisode.id,
                    subscriptionID: subscription.id
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
                // reportedStartTime, not safeResumeTime: under a start-skip
                // with no resume the lock screen otherwise shows 0:00 until
                // the first tick while the app already shows the skip offset.
                currentTime: start.reportedStartTime,
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

        // A Play Instant return point is invalid once that interrupted episode
        // has itself completed (including a forward skip that crosses EOF).
        // Keeping it would resurrect the final skipped seconds after the Instant
        // episode ends.
        if playInstantInterruptedSession?.episodeID == episode.id {
            cancelPlayInstantSession(reason: "interruptedEpisodeCompleted")
            logger.info("playInstant.returnDiscarded", "Discarded return point because the interrupted episode completed", metadata: [
                "episode": episode.title
            ])
        }

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

        if activePlayInstantEpisodeID == episode.id {
            if sleepTimerFired {
                cancelPlayInstantSession(reason: "sleepTimerFired")
                NowPlayingService.shared.clear()
                return
            }
            await finishPlayInstantAndAdvance(reason: "finishedNaturally")
            return
        }

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
            // Keep Foundation/SQLite bridge temporaries scoped to one feed. The
            // value result remains available for downstream scheduling, while
            // transient merge objects can drain before the next feed begins.
            autoreleasepool {
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
            }
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
        // Persist the intent BEFORE spawning the download Task (AH-2026-06-28-01):
        // a BG wake can suspend/terminate the app right after the feed cycle
        // returns, losing the Task below before the URLSession transfer starts —
        // and a successfully-refreshed feed isn't due again until its next
        // release window, so the episode would otherwise sit undownloaded until
        // the next app open. The durable intent is drained at launch /
        // foreground / BG-task end (drainAutoDownloadIntents) and removed once
        // the episode settles (resolveAutoDownloadIntentIfSettled).
        autoDownloadIntentStore.record(
            episodeID: episode.id,
            subscriptionID: subscriptionID,
            podcastTitle: podcastTitle
        )
        logger.info("feed.autoDownloadScheduled", "Auto-download scheduled after feed refresh", metadata: [
            "podcast": podcastTitle,
            "episode": episode.title,
            "episodeID": episode.id.uuidString,
            "intentPersisted": "true"
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runAutoDownloadAfterRefresh(
                episode: episode,
                subscriptionID: subscriptionID,
                podcastTitle: podcastTitle,
                refreshUpNextAfterMerge: refreshUpNextAfterMerge
            )
            self.resolveAutoDownloadIntentIfSettled(episodeID: episode.id, subscriptionID: subscriptionID)
        }
    }

    /// Removes an episode's persisted auto-download intent once it has reached a
    /// SETTLED state: downloaded, played/archived, gone (episode or subscription
    /// removed / became a browse preview), excluded by Download Filters, or
    /// superseded as the newest auto-download candidate (policy downloads only
    /// the newest eligible episode). An episode that is merely queued/downloading
    /// or whose attempt was blocked/interrupted keeps its intent so the next
    /// drain retries.
    private func resolveAutoDownloadIntentIfSettled(episodeID: UUID, subscriptionID: UUID) {
        guard autoDownloadIntentStore.contains(episodeID: episodeID) else { return }
        func settle(_ reason: String) {
            autoDownloadIntentStore.remove(episodeID: episodeID)
            logger.info("download.intentResolved", "Auto-download intent settled", metadata: [
                "episodeID": episodeID.uuidString,
                "reason": reason
            ])
        }
        guard let subscription = subscriptionStore.subscription(id: subscriptionID),
              subscription.browseDate == nil else {
            settle("subscriptionGone")
            return
        }
        guard let episode = subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID) else {
            settle("episodeGone")
            return
        }
        if episode.downloadState == .downloaded { settle("downloaded"); return }
        if episode.playedState == .played || episode.playedState == .archived { settle("playedOrArchived"); return }
        // In flight — the intent stays until the transfer reaches a terminal state
        // (an interrupted transfer is repaired to .failed by
        // reconcileOrphanedDownloads, and the next drain retries it).
        if episode.downloadState == .downloading || episode.downloadState == .queued { return }
        if !subscription.downloadFilterSettings.evaluation(for: episode).isIncluded { settle("filterExcluded"); return }
        if newestAutoDownloadCandidate(in: subscription)?.guid != episode.guid { settle("supersededByNewer"); return }
        // Still wanted and not yet downloading — keep for the next drain.
    }

    private var isDrainingAutoDownloadIntents = false

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
    private var downloadFailureBackoff: [String: (failures: Int, retryAfter: Date)] = [:]
    /// Process-local ceiling for watchdog-triggered retries. Genuine user retries
    /// and future launches remain possible, but one bad transfer cannot loop forever.
    private var downloadWatchdogRetryCounts: [UUID: Int] = [:]

    /// Records a genuine download failure and schedules an exponential cooldown before the
    /// episode is eligible for another AUTO attempt: 2, 8, 32, then 120 min (capped).
    private func recordDownloadFailure(guid: String, title: String) {
        guard !guid.isEmpty else { return }
        let failures = (downloadFailureBackoff[guid]?.failures ?? 0) + 1
        let cooldownMinutes = min(2.0 * pow(4.0, Double(failures - 1)), 120.0)
        downloadFailureBackoff[guid] = (failures, Date().addingTimeInterval(cooldownMinutes * 60))
        logger.info("download.backoffScheduled", "Backing off repeated download failure", metadata: [
            "episode": title,
            "failures": "\(failures)",
            "retryAfterMinutes": String(format: "%.0f", cooldownMinutes)
        ])
    }

    func drainAutoDownloadIntents(reason: String) async {
        guard !isDrainingAutoDownloadIntents else { return }
        let pending = autoDownloadIntentStore.intents
        guard !pending.isEmpty else { return }
        isDrainingAutoDownloadIntents = true
        defer { isDrainingAutoDownloadIntents = false }

        logger.info("download.intentDrain", "Draining persisted auto-download intents", metadata: [
            "reason": reason,
            "count": "\(pending.count)"
        ])
        for intent in pending {
            resolveAutoDownloadIntentIfSettled(episodeID: intent.episodeID, subscriptionID: intent.subscriptionID)
            guard autoDownloadIntentStore.contains(episodeID: intent.episodeID),
                  let episode = subscriptionStore.episode(
                    subscriptionID: intent.subscriptionID,
                    episodeID: intent.episodeID
                  )
            else { continue }
            // In flight already — leave it to finish; the intent settles later.
            if episode.downloadState == .downloading || episode.downloadState == .queued { continue }
            await runAutoDownloadAfterRefresh(
                episode: episode,
                subscriptionID: intent.subscriptionID,
                podcastTitle: intent.podcastTitle,
                refreshUpNextAfterMerge: true
            )
            resolveAutoDownloadIntentIfSettled(episodeID: intent.episodeID, subscriptionID: intent.subscriptionID)
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

        if let backoff = downloadFailureBackoff[candidateEpisode.guid], Date() < backoff.retryAfter {
            logger.info("download.backoffSkipped", "Auto-download skipped — backing off after repeated failures", metadata: [
                "podcast": subscription.title,
                "episode": candidateEpisode.title,
                "failures": "\(backoff.failures)",
                "retryAfterSecs": String(format: "%.0f", backoff.retryAfter.timeIntervalSinceNow)
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
            showCompletionMessage: false,
            isAutomatic: true
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
        let foreground = isAppForeground
        let backgroundBudget = foreground ? nil : backgroundAudioRefreshBudget()
        if !foreground {
            let now = Date()
            if let lastBackgroundAudioRefreshAt,
               now.timeIntervalSince(lastBackgroundAudioRefreshAt) < backgroundAudioRefreshMinimumInterval {
                return false
            }
            lastBackgroundAudioRefreshAt = now
        }
        return await refreshSubscriptions(
            reason: "timed-due",
            trigger: .foregroundTimer,
            executionContext: foreground ? .foregroundVisible : .backgroundAudioAlive,
            maxSubscriptions: foreground ? foregroundRefreshFeedLimit : backgroundBudget?.routineLimit,
            maxTotalSelections: foreground ? nil : backgroundBudget?.hardLimit,
            capBypassStates: foreground ? foregroundRefreshCapBypassStates : backgroundAudioCapBypassStates,
            includeBackoffFeeds: false,
            onlyDueFeeds: true
        )
    }

    /// AI CONTEXT — Background audio is a valuable refresh opportunity, but its
    /// network/parser budget adapts to device pressure. The normal 7/10 routine/
    /// urgent limits are reduced—not disabled—on cellular/constrained paths, Low
    /// Power Mode, elevated thermal state, or while a >=100 MB transfer is active.
    private func backgroundAudioRefreshBudget() -> (routineLimit: Int, hardLimit: Int) {
        var routineLimit = backgroundAudioRefreshFeedLimit
        var hardLimit = backgroundAudioRefreshHardLimit

        func reduce(routine: Int, hard: Int) {
            routineLimit = min(routineLimit, routine)
            hardLimit = min(hardLimit, hard)
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled { reduce(routine: 4, hard: 6) }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: reduce(routine: 3, hard: 5)
        case .critical: reduce(routine: 2, hard: 3)
        case .nominal, .fair: break
        @unknown default: reduce(routine: 4, hard: 6)
        }
        if let path = latestNetworkPath,
           path.usesInterfaceType(.cellular) || path.isConstrained || path.isExpensive {
            reduce(routine: 4, hard: 6)
        }
        let largeDownloadActive = downloadActivityStore.activeActivities.contains { activity in
            activity.status == .downloading
                && max(activity.expectedBytes ?? 0, activity.writtenBytes) >= 100 * 1_024 * 1_024
        }
        if largeDownloadActive { reduce(routine: 4, hard: 6) }
        return (routineLimit, max(routineLimit, hardLimit))
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
        maxTotalSelections: Int? = nil,
        capBypassStates: Set<FeedRefreshWindowState> = [],
        protectedStates: Set<FeedRefreshWindowState> = [],
        minimumProtectedSelections: Int = 0,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool,
        joinActiveCycle: Bool = false,
        backgroundTaskIdentifier: String? = nil,
        targetSubscriptionIDs: Set<UUID>? = nil,
        refreshAfterJoiningActiveCycle: Bool = false
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
            let joinedResult = await active.value
            guard refreshAfterJoiningActiveCycle else { return joinedResult }
            // The joined cycle may have been a capped/due-only poll that did not
            // include the feed named by the relay. Let its owning caller clear
            // activeRefreshCycle, then run one targeted follow-up cycle.
            while activeRefreshCycle != nil { await Task.yield() }
            return await refreshSubscriptions(
                reason: reason,
                trigger: trigger,
                executionContext: executionContext,
                maxSubscriptions: maxSubscriptions,
                maxTotalSelections: maxTotalSelections,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                includeBackoffFeeds: includeBackoffFeeds,
                onlyDueFeeds: onlyDueFeeds,
                joinActiveCycle: false,
                backgroundTaskIdentifier: backgroundTaskIdentifier,
                targetSubscriptionIDs: targetSubscriptionIDs,
                refreshAfterJoiningActiveCycle: false
            )
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
                maxTotalSelections: maxTotalSelections,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                includeBackoffFeeds: includeBackoffFeeds,
                onlyDueFeeds: onlyDueFeeds,
                targetSubscriptionIDs: targetSubscriptionIDs
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
        maxTotalSelections: Int?,
        capBypassStates: Set<FeedRefreshWindowState>,
        protectedStates: Set<FeedRefreshWindowState>,
        minimumProtectedSelections: Int,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool,
        targetSubscriptionIDs: Set<UUID>?
    ) async -> Bool {
        suppressUpNextRefresh = true
        defer { suppressUpNextRefresh = false }

        let refreshContext = diagnostics.metadata(currentSceneActive: isSceneActive)
        resourceMonitor.logSnapshot(
            reason: "feed.refreshAll.before",
            context: resourceContext(refreshContext),
            force: true
        )
        let requestedSubscriptions = targetSubscriptionIDs.map { targetIDs in
            subscriptionStore.subscriptions.filter { targetIDs.contains($0.id) }
        } ?? subscriptionStore.subscriptions
        logger.info("feed.refreshAll", "Refreshing podcast feeds", metadata: [
            "count": "\(requestedSubscriptions.count)",
            "reason": diagnostics.reason,
            "maxSubscriptions": maxSubscriptions.map(String.init) ?? "all",
            "targeted": "\(targetSubscriptionIDs != nil)"
        ].merging(refreshContext) { _, new in new })
        let skippedSubscriptions = requestedSubscriptions.filter(\.excludeFromAutoFeedRefresh)
        let activeSubscriptions = requestedSubscriptions.filter { !$0.excludeFromAutoFeedRefresh }
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
            ? await refreshCandidatesForCycle(eligibleSubscriptions, now: now)
            : []
        let budgetSelection = FeedRefreshBudgeting.select(
            candidates: dueCandidates,
            policy: FeedRefreshBudgetPolicy(
                maxSelections: maxSubscriptions,
                maxTotalSelections: maxTotalSelections,
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
                maxTotalSelections: maxTotalSelections,
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
        // AI CONTEXT — Refreshes remain sequential for deterministic store merges,
        // but cycles are divided into 16-feed memory batches. Every boundary logs
        // physical footprint (the intervention metric), yields the main actor, and
        // gives manual all-library refreshes a short drain window for parser pools.
        let refreshMemoryBatchSize = 16
        let isLargeManualRefresh = diagnostics.executionContext == .manual && subscriptions.count > refreshMemoryBatchSize
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
            let completedCount = index + 1
            if completedCount % refreshMemoryBatchSize == 0, completedCount < subscriptions.count {
                resourceMonitor.logSnapshot(
                    reason: "feed.refreshAll.batchCheckpoint",
                    context: resourceContext(refreshContext.merging([
                        "completedFeeds": "\(completedCount)",
                        "totalFeeds": "\(subscriptions.count)",
                        "batchSize": "\(refreshMemoryBatchSize)",
                        "manualDrainPause": "\(isLargeManualRefresh)"
                    ]) { _, new in new }),
                    force: true
                )
                await Task.yield()
                if isLargeManualRefresh {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
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
            minRecheckInterval: automaticReleaseRadarBaseInterval,
            now: now
        )
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
    ) async -> [RefreshCycleCandidate] {
        let cachedProfiles = subscriptions.reduce(into: [UUID: FeedScheduleProfile]()) { result, subscription in
            let observations = subscription.refreshStats.releaseObservations
            if let entry = releaseRadarProfileCache[subscription.id],
               entry.observationCount == observations.count,
               entry.newestObservationKey == observations.last?.episodeKey,
               entry.filterSettings == subscription.downloadFilterSettings,
               now.timeIntervalSince(entry.generatedAt) < Self.releaseRadarProfileCacheTTL {
                result[subscription.id] = entry.profile
            }
        }
        let deferred = deferredRefreshBacklog.mapValues {
            RefreshPlanningDeferredSnapshot(firstDeferredAt: $0.firstDeferredAt, deferralCount: $0.deferralCount)
        }
        let interval = automaticReleaseRadarBaseInterval
        return await Task.detached(priority: .utility) {
            ReleaseRadarCyclePlanner.candidates(
                subscriptions: subscriptions,
                cachedProfiles: cachedProfiles,
                deferred: deferred,
                minimumRecheckInterval: interval,
                now: now
            )
        }.value
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
        maxTotalSelections: Int?,
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
            "maxTotalSelections": maxTotalSelections.map(String.init) ?? "unlimited",
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
        ].merging(deferredBacklogDiagnosticMetadata(now: Date())) { _, new in new }
         .merging(diagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new })
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
        let now = Date()
        let activeSubscriptions = subscriptionStore.subscriptions.filter { !$0.excludeFromAutoFeedRefresh }
        let nextDue = activeSubscriptions
            .map { subscription in
                let feedDueAt = nextRefreshDue(for: subscription)
                let backoffUntil = feedFailureBackoffUntil[subscription.id]
                let effectiveDueAt = BackgroundTaskCoordinator.effectiveFeedDueDate(
                    feedDueDate: feedDueAt,
                    backoffUntil: backoffUntil,
                    now: now
                )
                return (
                    subscription: subscription,
                    feedDueAt: feedDueAt,
                    backoffUntil: backoffUntil,
                    effectiveDueAt: effectiveDueAt
                )
            }
            .min { lhs, rhs in
                if lhs.effectiveDueAt != rhs.effectiveDueAt { return lhs.effectiveDueAt < rhs.effectiveDueAt }
                return lhs.subscription.title.localizedCaseInsensitiveCompare(rhs.subscription.title) == .orderedAscending
            }
        if let nextDue {
            let secondsUntilDue = max(0, Int(nextDue.effectiveDueAt.timeIntervalSince(now).rounded()))
            let activeBackoffCount = activeSubscriptions.reduce(into: 0) { count, subscription in
                if let until = feedFailureBackoffUntil[subscription.id], until > now { count += 1 }
            }
            logger.info("background.nextDue", "Selected next feed due date for background refresh scheduling", metadata: refreshFeedMetadata(
                for: nextDue.subscription,
                includeURL: false,
                extra: [
                    "feedDueAt": refreshLogDate(nextDue.feedDueAt),
                    "backoffUntil": refreshLogDate(nextDue.backoffUntil),
                    "nextDueAt": refreshLogDate(nextDue.effectiveDueAt),
                    "delayedByBackoff": "\(nextDue.effectiveDueAt > nextDue.feedDueAt)",
                    "secondsUntilDue": "\(secondsUntilDue)",
                    "activeSubscriptions": "\(activeSubscriptions.count)",
                    "activeBackoffSubscriptions": "\(activeBackoffCount)",
                    "skippedInactive": "\(subscriptionStore.subscriptions.count - activeSubscriptions.count)"
                ]
            ))
        } else {
            logger.info("background.nextDue", "No active subscription available for background refresh scheduling", metadata: [
                "activeSubscriptions": "0",
                "skippedInactive": "\(subscriptionStore.subscriptions.count)"
            ])
        }
        let soonestDue = nextDue?.effectiveDueAt
        BackgroundTaskCoordinator.scheduleAppRefresh(earliestBeginDate: soonestDue)
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
            ].merging(deferredBacklogDiagnosticMetadata(now: now)) { _, new in new }
             .merging(diagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new })
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
        ].merging(deferredBacklogDiagnosticMetadata(now: now)) { _, new in new }
         .merging(diagnostics.metadata(currentSceneActive: isSceneActive)) { _, new in new })
    }

    /// AI CONTEXT — Backlog diagnostics expose starvation directly. Age is based
    /// on the first time the currently-oldest feed was capped out, not its most
    /// recent deferral, so repeated cycles cannot make a long wait look new.
    private func deferredBacklogDiagnosticMetadata(now: Date) -> [String: String] {
        guard let oldest = deferredRefreshBacklog.values.min(by: { $0.firstDeferredAt < $1.firstDeferredAt }) else {
            return [
                "oldestDeferredAgeSeconds": "0",
                "oldestDeferredPodcast": "none",
                "oldestDeferredSubscriptionID": "none",
                "oldestDeferredCount": "0",
                "oldestDeferredState": "none"
            ]
        }
        return [
            "oldestDeferredAgeSeconds": "\(max(0, Int(now.timeIntervalSince(oldest.firstDeferredAt).rounded())))",
            "oldestDeferredSince": refreshLogDate(oldest.firstDeferredAt),
            "oldestDeferredPodcast": oldest.title,
            "oldestDeferredSubscriptionID": oldest.subscriptionID.uuidString,
            "oldestDeferredCount": "\(oldest.deferralCount)",
            "oldestDeferredState": oldest.state.rawValue
        ]
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
            autoArchiveActivityStore.record(AutoArchiveActivity(
                episodeID: episode.id,
                subscriptionID: subscription.id,
                episodeTitle: episode.title,
                podcastTitle: subscription.title,
                archivedAt: Date(),
                rule: .episodeLimit,
                configuredThreshold: "Keep \(limit)",
                measuredAgeSeconds: max(0, Date().timeIntervalSince(episode.publishedAt ?? episode.downloadedAt ?? Date()))
            ))
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

        // AI CONTEXT — Eligibility counters explain zero-result passes. They
        // count rule-specific candidates and the principal reason work remained
        // pending/protected, then emit one compact diagnostic at pass completion.
        var playedEvaluated = 0
        var playedWaiting = 0
        var inactiveEvaluated = 0
        var inactiveNeverDownloaded = 0
        var inactiveWaiting = 0
        var protectedCurrent = 0
        var limitCandidates = 0
        var limitBacklogProtected = 0
        var archivedPlayed = 0
        var archivedInactive = 0
        var archivedLimit = 0

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
                    guard episode.playedState == .played else { continue }
                    playedEvaluated += 1
                    guard episode.id != playingID,
                          !archivedIDs.contains(episode.id)
                    else {
                        if episode.id == playingID { protectedCurrent += 1 }
                        continue
                    }

                    let playedAt = episode.lastPlayedAt ?? now  // if no timestamp, archive immediately
                    let playedAge = now.timeIntervalSince(playedAt)
                    if playedAge >= interval {
                        await archiveEpisode(episode, completionKind: .autoArchived)
                        autoArchiveActivityStore.record(AutoArchiveActivity(
                            episodeID: episode.id,
                            subscriptionID: subscription.id,
                            episodeTitle: episode.title,
                            podcastTitle: subscription.title,
                            archivedAt: Date(),
                            rule: .afterPlaying,
                            configuredThreshold: settings.afterPlayed.title,
                            measuredAgeSeconds: playedAge
                        ))
                        archivedIDs.insert(episode.id)
                        archivedCount += 1
                        archivedPlayed += 1
                        logger.info("autoArchive.played", "Archived played episode", metadata: [
                            "podcast": subscription.title, "episode": episode.title
                        ])
                    } else { playedWaiting += 1 }
                }
            }

            // ── Pass 2: After Inactive ────────────────────────────────────────
            if let interval = settings.afterInactive.interval {
                for episode in allEpisodes {
                    guard episode.playedState == .unplayed else { continue }
                    inactiveEvaluated += 1
                    guard episode.id != playingID,
                          !archivedIDs.contains(episode.id)
                    else {
                        if episode.id == playingID { protectedCurrent += 1 }
                        continue
                    }

                    // Only downloaded episodes are eligible — an episode that has
                    // never been downloaded has never been "touched" and should not
                    // be archived by this rule. A non-nil downloadedAt is itself
                    // proof of user engagement, so it overrides the backlog
                    // exemption above (bug fix 2026-07-05: an old backlog episode
                    // the user explicitly downloaded was being permanently
                    // protected from the inactive-timeout rule by publish date).
                    guard let downloadedAt = episode.downloadedAt else {
                        inactiveNeverDownloaded += 1
                        continue
                    }

                    // "Last activity" = the most recent of: download date, play date.
                    // The clock starts when the file lands on device, and resets any
                    // time the user starts playing the episode.
                    let downloadAge = now.timeIntervalSince(downloadedAt)
                    let playAge     = episode.lastPlayedAt.map { now.timeIntervalSince($0) }
                    let lastActivityAge = [downloadAge, playAge].compactMap { $0 }.min() ?? downloadAge

                    if lastActivityAge >= interval {
                        await archiveEpisode(episode, completionKind: .autoArchived)
                        autoArchiveActivityStore.record(AutoArchiveActivity(
                            episodeID: episode.id,
                            subscriptionID: subscription.id,
                            episodeTitle: episode.title,
                            podcastTitle: subscription.title,
                            archivedAt: Date(),
                            rule: .inactiveEpisodes,
                            configuredThreshold: settings.afterInactive.title,
                            measuredAgeSeconds: lastActivityAge
                        ))
                        archivedIDs.insert(episode.id)
                        archivedCount += 1
                        archivedInactive += 1
                        logger.info("autoArchive.inactive", "Archived inactive episode", metadata: [
                            "podcast": subscription.title, "episode": episode.title
                        ])
                    } else { inactiveWaiting += 1 }
                }
            }

            // ── Pass 3: Episode Limit ─────────────────────────────────────────
            let limit = settings.episodeLimit.rawValue
            if limit > 0 {
                limitBacklogProtected += subscription.episodes.filter {
                    $0.playedState != .archived && isPreSubscriptionBacklog($0)
                }.count
                // Sort all non-archived episodes newest-first; keep the top N, archive the rest.
                let candidates = subscription.episodes
                    .filter { $0.playedState != .archived && !archivedIDs.contains($0.id) && ($0.downloadState == .queued || $0.downloadState == .downloaded) && !isPreSubscriptionBacklog($0) }
                    .sorted {
                        ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
                    }
                limitCandidates += candidates.count
                for (index, episode) in candidates.enumerated() {
                    guard index >= limit,
                          episode.id != playingID
                    else { continue }
                    await archiveEpisode(episode, completionKind: .autoArchived)
                    autoArchiveActivityStore.record(AutoArchiveActivity(
                        episodeID: episode.id,
                        subscriptionID: subscription.id,
                        episodeTitle: episode.title,
                        podcastTitle: subscription.title,
                        archivedAt: Date(),
                        rule: .episodeLimit,
                        configuredThreshold: "Keep \(limit)",
                        measuredAgeSeconds: max(0, now.timeIntervalSince(episode.publishedAt ?? episode.downloadedAt ?? now))
                    ))
                    archivedIDs.insert(episode.id)
                    archivedCount += 1
                    archivedLimit += 1
                    logger.info("autoArchive.limit", "Archived episode over limit", metadata: [
                        "podcast": subscription.title, "episode": episode.title, "limit": "\(limit)"
                    ])
                }
            }
        }

        refreshUpNextEpisode(reason: "autoArchive.finished")
        logger.info("autoArchive.eligibility", "Auto Archive eligibility summary", metadata: [
            "reason": reason,
            "subscriptions": "\(allSubscriptions.count)",
            "playedEvaluated": "\(playedEvaluated)",
            "playedWaiting": "\(playedWaiting)",
            "inactiveEvaluated": "\(inactiveEvaluated)",
            "inactiveNeverDownloaded": "\(inactiveNeverDownloaded)",
            "inactiveWaiting": "\(inactiveWaiting)",
            "protectedCurrent": "\(protectedCurrent)",
            "limitCandidates": "\(limitCandidates)",
            "limitBacklogProtected": "\(limitBacklogProtected)",
            "archivedPlayed": "\(archivedPlayed)",
            "archivedInactive": "\(archivedInactive)",
            "archivedLimit": "\(archivedLimit)"
        ])
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
        guard let episode = currentPlayerEpisode, currentPlayerTime > 0 else { return }
        // The store clears the position instead when the time normalizes to 0
        // (finished/near-end), matching the historical behavior.
        playbackPositionStore.save(episode: episode, timeSeconds: currentPlayerTime)
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

    // MARK: - Autohop Relay (Autohop Pro — RELAY_TIER1_IMPLEMENTATION.md §4)

    /// Forwarded from AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken.
    /// Called on every launch (registerForRemoteNotifications runs unconditionally),
    /// so this is frequently a no-op token refresh; registerWithRelayIfPossible
    /// only actually calls the relay when isPro is also true.
    func relayTokenReceived(_ token: String) {
        guard ReleaseFeatures.relayService else { return }
        relayAPNsToken = token
        Task { await registerWithRelayIfPossible() }
    }

    private func registerWithRelayIfPossible() async {
        guard ReleaseFeatures.relayService,
              autohopProStore.isPro,
              let token = relayAPNsToken,
              let jws = autohopProStore.latestTransactionJWS,
              !relayRegistrationInFlight
        else { return }
        relayRegistrationInFlight = true
        defer { relayRegistrationInFlight = false }
        let syncGroupID = await resolveRelaySyncGroupID()
        do {
            let (_, requestID) = try await relayClient.register(jws: jws, apnsToken: token, syncGroupId: syncGroupID)
            logger.info("relay.registered", "Registered device with Autohop Relay", metadata: [
                "requestID": requestID,
                "hasSyncGroupID": "\(syncGroupID != nil)"
            ])
            // Registration may create a device or rotate credentials on the
            // existing row. One idempotent full set confirms/rebuilds the local
            // acknowledged baseline; ordinary library changes use deltas.
            relayForceFullFeedSync = true
            await syncRelayFeedsIfRegistered()
        } catch {
            logger.warning("relay.registerFailed", "Autohop Relay registration failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none"
            ])
        }
    }

    /// AI CONTEXT — SubscriptionStore's publisher represents every episode and
    /// metadata save, not just subscribe/unsubscribe. Compare the canonical feed
    /// set synchronously after each save and schedule network work only when that
    /// set actually changes.
    private func scheduleRelayFeedSyncIfMembershipChanged() {
        guard ReleaseFeatures.relayService else { return }
        let current = Self.relayFeedURLs(in: subscriptionStore.subscriptions)
        guard current != relayObservedFeedURLs else { return }
        relayObservedFeedURLs = current
        relayFeedSyncNeedsReconcile = true
        scheduleRelayFeedSync()
    }

    /// Debounces membership mutations. Crucially, this Task owns only the sleep:
    /// it clears its stored reference before starting URLSession work. A later
    /// store change can cancel a pending debounce but cannot cancel an in-flight
    /// request (the cause of the diagnostic log's repeated NSURLErrorCancelled).
    private func scheduleRelayFeedSync(after delay: TimeInterval = 2) {
        guard ReleaseFeatures.relayService else { return }
        relayFeedSyncDebounceTask?.cancel()
        relayFeedSyncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.relayFeedSyncDebounceTask = nil
            await self.syncRelayFeedsIfRegistered()
        }
    }

    /// Reconciles desired membership against the last server-acknowledged set.
    /// Fresh registration/recovery sends `set`; normal membership edits send only
    /// `add`/`remove`. Failures open a persisted exponential circuit breaker so
    /// relaunches and store churn cannot immediately recreate a request storm.
    private func syncRelayFeedsIfRegistered() async {
        guard ReleaseFeatures.relayService,
              autohopProStore.isPro,
              relayClient.isRegistered else { return }
        if relayFeedSyncInFlight {
            relayFeedSyncNeedsReconcile = true
            return
        }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let nextAttempt = defaults.double(forKey: Self.relayFeedNextAttemptKey)
        if nextAttempt > now {
            relayFeedSyncNeedsReconcile = true
            scheduleRelayFeedSync(after: nextAttempt - now)
            return
        }

        relayFeedSyncInFlight = true
        relayFeedSyncNeedsReconcile = false
        defer {
            relayFeedSyncInFlight = false
            if relayFeedSyncNeedsReconcile { scheduleRelayFeedSync() }
        }

        let desired = Self.relayFeedURLs(in: subscriptionStore.subscriptions)
        let hasBaseline = defaults.object(forKey: Self.relayAcknowledgedFeedsKey) != nil
        let acknowledged = Set(defaults.stringArray(forKey: Self.relayAcknowledgedFeedsKey) ?? [])
        let additions = desired.subtracting(acknowledged)
        let removals = acknowledged.subtracting(desired)
        // The Worker deliberately caps a single delta at 100 entries. A large
        // OPML import/removal remains one bounded, idempotent full-set request
        // instead of failing repeatedly against that pressure limit.
        let forceFull = relayForceFullFeedSync || !hasBaseline
            || additions.count > 100 || removals.count > 100
        if !forceFull, additions.isEmpty, removals.isEmpty { return }

        do {
            let result: (response: RelayFeedsResponse, requestID: String)
            if forceFull {
                result = try await relayClient.setFeeds(Self.urls(from: desired))
            } else {
                result = try await relayClient.updateFeeds(
                    add: Self.urls(from: additions),
                    remove: Self.urls(from: removals)
                )
            }

            let serverURLs: Set<String>
            if let descriptors = result.response.feeds {
                RelayFeedMappingStore.replace(with: descriptors)
                serverURLs = Set(descriptors.map(\.url))
            } else {
                // Backward-compatible rollout path for a v1 Worker response.
                // Membership can still advance, but targeted pushes remain
                // unavailable until a v2 response supplies opaque mappings.
                serverURLs = desired
            }
            defaults.set(Array(serverURLs).sorted(), forKey: Self.relayAcknowledgedFeedsKey)
            defaults.set(0, forKey: Self.relayFeedFailureCountKey)
            defaults.removeObject(forKey: Self.relayFeedNextAttemptKey)
            relayForceFullFeedSync = result.response.count != desired.count
            logger.info("relay.feedSyncSucceeded", "Autohop Relay feed sync succeeded", metadata: [
                "mode": forceFull ? "set" : "delta",
                "desiredCount": "\(desired.count)",
                "addedCount": "\(additions.count)",
                "removedCount": "\(removals.count)",
                "acknowledgedCount": "\(result.response.count)",
                "changedCount": "\(result.response.changed ?? -1)",
                "requestID": result.requestID
            ])
            let latestDesired = Self.relayFeedURLs(in: subscriptionStore.subscriptions)
            if latestDesired != desired || relayForceFullFeedSync {
                relayFeedSyncNeedsReconcile = true
            }
        } catch {
            let failureCount = defaults.integer(forKey: Self.relayFeedFailureCountKey) + 1
            defaults.set(failureCount, forKey: Self.relayFeedFailureCountKey)
            let policyDelay = RelayRetryPolicy.delay(failureCount: failureCount)
            let delay = max(policyDelay, (error as? RelayError)?.retryAfter ?? 0)
            defaults.set(now + delay, forKey: Self.relayFeedNextAttemptKey)
            relayFeedSyncNeedsReconcile = true
            logger.warning("relay.feedSyncFailed", "Autohop Relay feed sync failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none",
                "failureCount": "\(failureCount)",
                "retryAfterSeconds": "\(Int(delay))"
            ])
        }
    }

    private static func relayFeedURLs(in subscriptions: [Subscription]) -> Set<String> {
        Set(subscriptions.lazy
            .filter { $0.browseDate == nil }
            .compactMap { RelayFeedURLCanonicalizer.string(for: $0.feedURL) })
    }

    private static func urls(from strings: Set<String>) -> [URL] {
        strings.sorted().compactMap(URL.init(string:))
    }

    private func clearRelayFeedProtocolState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.relayAcknowledgedFeedsKey)
        defaults.removeObject(forKey: Self.relayFeedFailureCountKey)
        defaults.removeObject(forKey: Self.relayFeedNextAttemptKey)
        RelayFeedMappingStore.clear()
        relayForceFullFeedSync = false
        relayFeedSyncNeedsReconcile = false
        relayFeedSyncDebounceTask?.cancel()
        relayFeedSyncDebounceTask = nil
    }

    /// Resolves the anonymous per-user CloudKit record ID used as the relay's
    /// `sync_group_id` (§1 Glossary — identical across this user's devices,
    /// unlike DeviceIdentity.current which is per-DEVICE and would never match
    /// between an iPhone and its paired TV). Cached in-memory for the process
    /// lifetime; nil (register proceeds without a sync group — feed-updated
    /// push still works, only sync-nudge fan-out is unavailable) if iCloud
    /// isn't available, matching this app's existing graceful-degradation
    /// posture around CloudSyncEngine itself.
    /// CKContainer has NO async-throws overload of fetchUserRecordID — only the
    /// completion-handler form (confirmed by an actual build failure, not
    /// assumed) — so this bridges it via withCheckedContinuation.
    private func resolveRelaySyncGroupID() async -> String? {
        if let relaySyncGroupID { return relaySyncGroupID }
        let container = CKContainer(identifier: AppState.cloudKitContainerID)
        let recordID: CKRecord.ID? = await withCheckedContinuation { continuation in
            container.fetchUserRecordID { recordID, _ in
                continuation.resume(returning: recordID)
            }
        }
        guard let recordID else { return nil }
        relaySyncGroupID = recordID.recordName
        return recordID.recordName
    }

    /// Coalesces CloudKit writes behind both a short quiet period and a persisted
    /// five-minute minimum interval. The dirty bit preserves a trailing nudge;
    /// unlike the former implementation, canceling a future sleep can never
    /// cancel the URLSession request that is already running.
    private func scheduleRelaySyncNudge() {
        guard ReleaseFeatures.relayService else { return }
        relaySyncNudgeDirty = true
        relaySyncNudgeDebounceTask?.cancel()
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let earliest = max(
            now + 5,
            defaults.double(forKey: Self.relayNudgeNextAttemptKey),
            defaults.double(forKey: Self.relayNudgeLastSuccessKey) + Self.relayNudgeMinimumInterval
        )
        relaySyncNudgeDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, earliest - Date().timeIntervalSince1970)))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.relaySyncNudgeDebounceTask = nil
            await self.sendRelaySyncNudge()
        }
    }

    /// No-op for non-Pro, not-yet-registered, or already-in-flight devices. The
    /// Worker itself is a further, coarser safety net regardless of how often
    /// this fires: it fans out to OTHER devices, not this one, and PUSH_QUEUE's
    /// per-device coalescing (§6.3, COALESCE_WINDOW=15m) caps how often any
    /// single target device is actually woken — this guard only protects the
    /// relay's REQUEST volume from this device, not push volume to the TV.
    private func sendRelaySyncNudge() async {
        guard ReleaseFeatures.relayService,
              autohopProStore.isPro,
              relayClient.isRegistered,
              relaySyncNudgeDirty else { return }
        if relaySyncNudgeInFlight { return }
        relaySyncNudgeInFlight = true
        relaySyncNudgeDirty = false
        defer {
            relaySyncNudgeInFlight = false
            if relaySyncNudgeDirty { scheduleRelaySyncNudge() }
        }
        let defaults = UserDefaults.standard
        do {
            let requestID = try await relayClient.syncNudge()
            defaults.set(Date().timeIntervalSince1970, forKey: Self.relayNudgeLastSuccessKey)
            defaults.set(0, forKey: Self.relayNudgeFailureCountKey)
            defaults.removeObject(forKey: Self.relayNudgeNextAttemptKey)
            logger.info("relay.syncNudgeSent", "Autohop Relay sync-nudge sent", metadata: [
                "requestID": requestID
            ])
        } catch {
            let failureCount = defaults.integer(forKey: Self.relayNudgeFailureCountKey) + 1
            defaults.set(failureCount, forKey: Self.relayNudgeFailureCountKey)
            let delay = max(
                RelayRetryPolicy.delay(failureCount: failureCount, base: 60, maximum: 30 * 60),
                (error as? RelayError)?.retryAfter ?? 0
            )
            defaults.set(Date().timeIntervalSince1970 + delay, forKey: Self.relayNudgeNextAttemptKey)
            relaySyncNudgeDirty = true
            logger.warning("relay.syncNudgeFailed", "Autohop Relay sync-nudge failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none",
                "failureCount": "\(failureCount)",
                "retryAfterSeconds": "\(Int(delay))"
            ])
        }
    }

    /// §4.5 heartbeat send-side. Called from AppDelegate.applicationDidBecomeActive
    /// (the documented trigger — "on foreground, ≤1/day"). Persisted via
    /// UserDefaults (NOT an in-memory Task/timestamp like the debounces above) —
    /// a relaunch must NOT reset the ≤1/day budget, or a user who force-quits and
    /// reopens the app often would heartbeat every launch instead of daily.
    private static let lastHeartbeatKey = "com.autohop.relay.lastHeartbeatAt"
    private static let heartbeatInterval: TimeInterval = 24 * 3600

    func sendRelayHeartbeatIfDue() async {
        guard ReleaseFeatures.relayService,
              autohopProStore.isPro,
              relayClient.isRegistered else { return }
        let lastSent = UserDefaults.standard.double(forKey: Self.lastHeartbeatKey)
        let elapsed = Date().timeIntervalSince1970 - lastSent
        guard elapsed >= Self.heartbeatInterval else { return }
        do {
            let (entitlement, requestID) = try await relayClient.heartbeat(
                apnsToken: relayAPNsToken,
                syncGroupId: await resolveRelaySyncGroupID()
            )
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastHeartbeatKey)
            logger.info("relay.heartbeatSent", "Autohop Relay heartbeat sent", metadata: [
                "requestID": requestID,
                "entitlementStatus": entitlement.status
            ])
            // A heartbeat that comes back non-active/grace means the server no
            // longer considers this device entitled (e.g. a webhook the app
            // never saw) — refresh local StoreKit state so isPro catches up
            // rather than staying stuck showing "Active" indefinitely.
            if entitlement.status != "active" && entitlement.status != "grace" {
                await autohopProStore.refreshEntitlement()
            }
        } catch {
            // Deliberately does NOT update lastHeartbeatKey on failure — retries
            // next foreground instead of waiting a full day after a transient error.
            logger.warning("relay.heartbeatFailed", "Autohop Relay heartbeat failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none"
            ])
        }
    }

    /// Dispatches a relay silent push (§4.4) by its `type` payload key. Must
    /// return quickly — called from AppDelegate's fetchCompletionHandler path,
    /// the same no-stall contract as the BGTask handlers. Returns whether real
    /// work was kicked off (maps to .newData vs .noData for iOS's wake-budget).
    @discardableResult
    func handleRelayPush(type: String, feedIDs: [String] = []) async -> Bool {
        guard ReleaseFeatures.relayService else { return false }
        switch type {
        case "feed-updated":
            guard !feedIDs.isEmpty else {
                // Protocol-v1/legacy fallback: never repeat the old unbounded,
                // backoff-bypassing full-library sweep. Check only the same small
                // due-feed budget used by BGAppRefresh and honor feed backoff.
                return await refreshSubscriptions(
                    reason: "relay.legacy",
                    trigger: .relayPush,
                    executionContext: .relayPush,
                    maxSubscriptions: backgroundRefreshFeedLimit,
                    includeBackoffFeeds: false,
                    onlyDueFeeds: true,
                    joinActiveCycle: true
                )
            }

            let mapping = RelayFeedMappingStore.urlStrings(for: feedIDs)
            if !mapping.unknown.isEmpty {
                // Unknown IDs mean the local protocol cache missed a server
                // membership revision (upgrade/re-registration race). Repair the
                // mapping with a full set, but do not turn this push into a sweep.
                relayForceFullFeedSync = true
                relayFeedSyncNeedsReconcile = true
                scheduleRelayFeedSync(after: 0)
                logger.warning("relay.pushUnknownFeedIDs", "Relay push contained unknown feed identities", metadata: [
                    "unknownCount": "\(mapping.unknown.count)",
                    "receivedCount": "\(feedIDs.count)"
                ])
            }
            let targetIDs: Set<UUID> = Set(subscriptionStore.subscriptions.compactMap { subscription -> UUID? in
                guard let canonical = RelayFeedURLCanonicalizer.string(for: subscription.feedURL),
                      mapping.known.contains(canonical)
                else { return nil }
                return subscription.id
            })
            guard !targetIDs.isEmpty else {
                // The membership may have been removed locally before a queued
                // push arrived. Mapping repair above is sufficient; no feed fetch
                // is useful in this wake.
                return !mapping.unknown.isEmpty
            }
            return await refreshSubscriptions(
                reason: "relay.targeted",
                trigger: .relayPush,
                executionContext: .relayPush,
                maxSubscriptions: targetIDs.count,
                includeBackoffFeeds: true,
                onlyDueFeeds: false,
                joinActiveCycle: true,
                targetSubscriptionIDs: targetIDs,
                refreshAfterJoiningActiveCycle: true
            )
        case "sync-nudge":
            // Immediate CloudKit pull — same primitives TV's launch/foreground
            // prime uses (TV/App/AutohopTVApp.swift primeLibraryFromCloudSoon),
            // just without its retry loop (a background push has no time for
            // 15 s of activation retries; a not-yet-activated engine is a no-op).
            await cloudSyncEngine.fetchAllSubscriptionsNow(reason: "relay.syncNudge")
            await cloudSyncEngine.fetchAllHistoryNow(reason: "relay.syncNudge")
            return true
        default:
            return false
        }
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
        guard let restored = playbackPositionStore.bestRestoreCandidate(in: downloadedQueue) else { return }
        let episode = restored.episode
        let saved = restored.position

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

    // Thin delegations into PlaybackPositionStore (AppState-split first carve) —
    // same names as the historical private helpers so playback call sites are
    // unchanged. All key/normalization/cache/disk logic lives in the store.
    private func savedPlaybackTime(for episode: Episode) -> TimeInterval {
        playbackPositionStore.savedTime(for: episode)
    }

    private func clearPlaybackPosition(for episodeID: UUID) {
        playbackPositionStore.clear(episodeID: episodeID)
    }

    private func clearPlaybackPosition(for episode: Episode) {
        playbackPositionStore.clear(for: episode)
    }

    private func normalizedResumeTime(_ seconds: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        PlaybackPositionStore.normalizedResumeTime(seconds, duration: duration)
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
        PlaybackPositionStore.clampedTime(seconds, duration: duration)
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
    private func fetchExternalChaptersInBackground(url: URL, episodeID: UUID, subscriptionID: UUID) {
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
            // Read the filter AFTER the network await. Capturing it at request
            // launch let a late response overwrite settings changed meanwhile.
            let latestFilter = self.subscriptionStore.subscription(id: subscriptionID)?.chapterFilter ?? ChapterFilter()
            self.playbackEngine.updateChapters(fetched, filter: latestFilter, for: episodeID)
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

    func handleScenePhaseChange(phaseName: String, isActive: Bool, isBackground: Bool) {
        let previousSceneActive = isSceneActive
        isSceneActive = isActive
        if isActive {
            backgroundPlaybackDiagnosticsGeneration += 1
        }

        var metadata = resourceContext([
            "phase": phaseName,
            "previousSceneActive": "\(previousSceneActive)",
            "applicationState": applicationStateLabel(UIApplication.shared.applicationState)
        ])
        if !isActive {
            metadata["backgroundTimeRemainingSecs"] = backgroundTimeRemainingLabel()
        }
        logger.info("scene.phase", "Scene phase changed", metadata: metadata)
        resourceMonitor.logSnapshot(
            reason: "scene.\(phaseName)",
            context: metadata,
            force: isBackground || !isActive
        )

        guard isBackground else { return }
        Task { await ArtworkImageCache.shared.trimMemory(reason: "scene.background") }
        scheduleBackgroundPlaybackDiagnostics(reason: "scene.background")
        let released = releasePausedPlaybackResourcesForBackground(reason: "scene.background")
        metadata["releasedPausedPlayerResources"] = "\(released)"
        logger.info("scene.background", "Scene entered background", metadata: metadata)
    }

    @discardableResult
    func releasePausedPlaybackResourcesForBackground(reason: String) -> Bool {
        guard currentPlayerEpisode != nil || playbackEngine.currentEpisode != nil else { return false }

        var metadata = resourceContext([
            "reason": reason,
            "engineEpisode": playbackEngine.currentEpisode?.title ?? "none",
            "engineIsPlaying": "\(playbackEngine.isPlaying)"
        ])
        guard !isPlaying, !playbackEngine.isPlaying else {
            logger.info("player.backgroundReleaseSkipped", "Playback is active; keeping playback resources", metadata: metadata)
            return false
        }
        guard let engine = playbackEngine as? PlaybackEngine else {
            logger.info("player.backgroundReleaseSkipped", "Playback engine does not support background resource release", metadata: metadata)
            return false
        }
        guard let releasedPosition = engine.releasePausedPlayerResourcesForBackground(reason: reason) else {
            logger.info("player.backgroundReleaseSkipped", "No paused playback resources to release", metadata: metadata)
            return false
        }

        currentPlayerTime = releasedPosition
        persistCurrentPlaybackPosition()
        metadata["releasedPositionSecs"] = String(format: "%.1f", releasedPosition)
        logger.info("player.backgroundRelease", "Released paused playback resources for background", metadata: metadata)
        resourceMonitor.logSnapshot(reason: "player.backgroundRelease", context: metadata, force: true)
        return true
    }

    func logActivePlaybackDiagnostics(reason: String, extra: [String: String] = [:]) {
        guard currentPlayerEpisode != nil || playbackEngine.currentEpisode != nil else { return }

        var metadata = resourceContext(extra)
        let backgroundRemaining = UIApplication.shared.backgroundTimeRemaining
        metadata["backgroundTimeRemainingSecs"] = backgroundTimeRemainingLabel()
        metadata.merge(playbackEngineDiagnosticMetadata(reason: reason)) { _, new in new }
        logger.info("playback.backgroundHealth", "Active playback background health", metadata: metadata)

        // Keep-alive anomaly: the app believes it's playing, yet iOS granted only a short,
        // finite background allowance (tens of seconds) instead of the "unlimited" audio
        // assertion. This is the state that immediately precedes the unexpected ~6 s
        // background kill. Flag it loudly (WARN + alwaysPersist), with the full session/engine
        // snapshot already in `metadata`, so the next log shows WHY the assertion was lost —
        // e.g. a silent / read-finished engine (stale lastRenderedAgeMs, playbackLikely
        // ProducingAudio=false), another app taking audio (audioSessionOtherAudioPlaying=true),
        // a deactivated session, or a route change. `backgroundTimeRemaining` is DBL_MAX (huge)
        // while the assertion is held, so a value under a minute means it is NOT held.
        if isPlaying, backgroundRemaining.isFinite, backgroundRemaining < 60 {
            logger.warning(
                "audio.backgroundAssertionLow",
                "Playing but iOS granted only limited background time — audio keep-alive not held",
                metadata: metadata,
                alwaysPersist: true
            )
        }
    }

    private func scheduleBackgroundPlaybackDiagnostics(reason: String) {
        backgroundPlaybackDiagnosticsGeneration += 1
        let generation = backgroundPlaybackDiagnosticsGeneration
        logActivePlaybackDiagnostics(reason: "\(reason).entry", extra: [
            "backgroundElapsedSecs": "0"
        ])

        for delaySeconds in [5, 20] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard let self,
                      self.backgroundPlaybackDiagnosticsGeneration == generation,
                      !self.isAppForeground,
                      self.currentPlayerEpisode != nil || self.playbackEngine.currentEpisode != nil
                else { return }

                self.logActivePlaybackDiagnostics(reason: "\(reason).+\(delaySeconds)s", extra: [
                    "backgroundElapsedSecs": "\(delaySeconds)"
                ])
            }
        }
    }

    func logResourceSnapshot(reason: String, extra: [String: String] = [:], force: Bool = true) {
        resourceMonitor.logSnapshot(reason: reason, context: resourceContext(extra), force: force)
    }

    func logResourceWarningSnapshot(event: String, message: String, reason: String, extra: [String: String] = [:]) {
        resourceMonitor.logWarningSnapshot(
            event: event,
            message: message,
            reason: reason,
            context: resourceContext(extra)
        )
    }

    /// Due-feed poller: ticks every 30 seconds and refreshes only the feeds whose
    /// adaptive due date has arrived. Conditional requests (304s) make each check
    /// nearly free, so an hourly news feed is picked up within a minute or two of
    /// publish while a weekly show is fetched roughly once a day.
    ///
    /// The loop Task is never cancelled, so it keeps ticking whenever the process is
    /// alive — in the foreground AND while background audio playback keeps the app
    /// running. It therefore guards on `isSceneActive || isPlaying`: active
    /// listening is a reliable refresh window for a podcast app
    /// (unlike best-effort BGAppRefreshTask), so new episodes are caught and queued
    /// for download while the user listens with the screen off. When the process is
    /// truly idle (no audio) iOS suspends it and this loop pauses until the next
    /// foreground/audio wake; background-audio refreshes are limited to one cycle
    /// every four minutes: seven routine feeds, with urgent release-window work
    /// allowed to use up to ten total checks. Resource pressure lowers both limits.
    /// BGAppRefreshTask covers the not-listening case (see
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

                // Auto-archive on its OWN cadence, decoupled from feed refresh.
                // BUG FIX (2026-07-11, Kevin: "auto-archive is simply not running
                // regularly" — an 8-hour Inactive setting leaving episodes for
                // weeks). runAutoArchive was ONLY ever driven by (a) cold launch
                // and (b) the tail of a COMPLETED feed-refresh cycle
                // (performRefreshCycle, ~line 3500). Both are unreliable: a
                // podcast app's process stays alive for hours (background audio +
                // suspension) so cold launch is rare, and the refresh cycle skips
                // auto-archive entirely whenever nothing is due (early return at
                // the onlyDueFeeds/no-selection guard) or the cycle is cancelled
                // by the background time budget. So the inactive-timeout clock was
                // serviced only by chance. This tick services it every poll while
                // the app is alive; runAutoArchiveIfNeeded's built-in 25-minute
                // gate bounds the work regardless of how often this loop calls it.
                await self.runAutoArchiveIfNeeded(reason: "poll.tick")

                let now = Date()
                let dueCount = self.subscriptionStore.subscriptions.filter { subscription in
                    !subscription.excludeFromAutoFeedRefresh
                        && self.nextRefreshDue(for: subscription) <= now
                }.count
                if dueCount > 0 {
                    let executionContext: FeedRefreshExecutionContext = self.isAppForeground ? .foregroundVisible : .backgroundAudioAlive
                    if executionContext == .backgroundAudioAlive,
                       let lastRefresh = self.lastBackgroundAudioRefreshAt,
                       now.timeIntervalSince(lastRefresh) < self.backgroundAudioRefreshMinimumInterval {
                        continue
                    }
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

    private func applicationStateLabel(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func backgroundTimeRemainingLabel() -> String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining.isFinite else { return "unknown" }
        if remaining > 1_000_000 { return "unlimited" }
        return String(format: "%.1f", remaining)
    }

    private func playbackEngineDiagnosticMetadata(reason: String) -> [String: String] {
        if let engine = playbackEngine as? PlaybackEngine {
            return engine.playbackDiagnosticMetadata(reason: reason)
        }

        return [
            "playbackDiagnosticReason": reason,
            "playbackBackend": "unknown",
            "playbackEngineIsPlaying": "\(playbackEngine.isPlaying)",
            "engineEpisode": playbackEngine.currentEpisode?.title ?? "none",
            "playbackLikelyProducingAudio": "unknown"
        ]
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
        if UIApplication.shared.applicationState != .active {
            context["backgroundTimeRemainingSecs"] = backgroundTimeRemainingLabel()
            if currentPlayerEpisode != nil || playbackEngine.currentEpisode != nil {
                context.merge(playbackEngineDiagnosticMetadata(reason: "resourceContext")) { existing, _ in existing }
            }
        }
        extra.forEach { context[$0.key] = $0.value }
        return context
    }
}
