import SwiftUI
import Combine
import CloudKit
import Observation
import AutohopCore

// AI CONTEXT — TV/App/AutohopTVApp.swift
// tvOS Phase 1 (Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md §6): app entry point,
// TVAppModel composition root, and the purge-resilient bootstrap (T2). This
// target consumes AutohopCore as a LIBRARY (import AutohopCore) — it must
// never compile iOS sources or reach for AppState; TVAppModel is deliberately
// the anti-AppState (@Observable, a few hundred lines max, composed from
// Phase 0 domain objects).
// BOOTSTRAP (T2): the GRDB store lives in Caches (purgeable!). Cold start:
// read the survival kit (durable UserDefaults: subscription IDs + feed URLs +
// ranks) → refetch each missing feed → SubscriptionStore.materialize with the
// PRESERVED subscriptionID (identity is what keeps synced records applicable)
// → start CloudSyncEngine (its own account check aborts gracefully without
// iCloud) → remote SubscriptionState records for unknown podcasts arrive via
// onSubscriptionNeedsMaterialization and build the library on first-ever
// launch. The kit is rewritten (debounced) on every store change.
// ROOT STATE: loading → ready | empty (PC RootView shape, minus auth).
// `ready` shows the Phase 2 Home/Queue/Library/Search TabView (TVMainTabView).
// FIRST-SYNC WAIT (fixed 2026-07-04, found on Kevin's real Apple TV): a
// device with no prior CloudKit change token does a full historical fetch of
// the whole private zone, which can legitimately take MINUTES (observed ~4
// on a fresh install) — Apple's fetch speed, not something this app
// controls. `bootstrap()` keeps `rootState == .loading` (animated spinner +
// rotating status text, see waitForFirstSyncWithAnimatedStatus) for a long
// grace window instead of flipping to the static `.empty` screen almost
// immediately, which is what silently happened before (refreshLibrary() was
// called BEFORE the old short wait even started, so the wait's own status
// text updates were never visible). `.empty` itself now also carries a
// small persistent spinner — it is never a dead end: the debounced
// `observeStoreForKitWrites` sink keeps refreshing in the background and
// will flip to `.ready` automatically whenever CloudKit actually delivers
// something, no matter which screen happens to be showing at the time.
// No Simulator debug bypass anymore (removed 2026-07-04 once real-hardware
// testing worked) — see git history if one is ever needed again.
// NOTE: librarySubscriptions is an Observation-tracked mirror of the store's
// library (SubscriptionStore is ObservableObject; its @Published changes are
// NOT tracked by @Observable views — always read the mirror in TV views).
// 2026-07-11 (Kevin's real-device round 5): Latest shelf REMOVED (latestEpisodes
// deleted — Up Next is the point of the TV Home); Continue Listening reworked to
// render from the synced history entry itself (see computeContinueListening);
// prime order flipped to queue/history-first; TV now records listening stats
// (listeningStatsStore) so TV consumption lands on the iPhone's Stats page;
// animated splash (TVLaunchLoadingView) replaces the bare loading spinner.
// PHASE 2 (§7): upNextItems/upNextEpisodes/continueListening and
// the subscription(id:) lookup were originally derived from librarySubscriptions
// on EVERY ACCESS (assumed cheap at "dozens of subscriptions" — the library grew
// to 113, matching the iPhone, invalidating that; PERF FIX 2026-07-10, found
// investigating a reported memory/CPU bug, see refreshLibrary()'s own note).
// They're now cached: recomputed ONCE per refreshLibrary() call (real data
// changes) via recomputeDerivedState(), read back as plain O(1) stored state —
// same pattern as the iPhone's cachedDownloadedQueue, this file just didn't need
// it until the library grew. The former per-foreground all-library RSS sweep
// has now been deleted; only bounded row/detail recovery may fetch feeds.

@main
struct AutohopTVApp: App {
    // LAZY MODEL (2026-07-11, Kevin's round 6: "no splash, just a blank page
    // for ~15 s"): TVAppModel's init synchronously loads the whole GRDB store
    // (113 subscriptions × episodes decoded on the main actor). As a `@State
    // = TVAppModel()` default it ran BEFORE SwiftUI could draw the first
    // frame, so the window sat on the bare background colour until the load
    // finished — the splash never had a chance to appear. Now the splash
    // renders first and the model is created one frame later in .task.
    // ROUND 7 (2026-07-11, "the start up animation does not have any
    // movement — just a static image"): creating the model later wasn't
    // enough — the synchronous decode then froze the main actor WHILE the
    // splash was up, and SwiftUI animations are main-thread driven, so the
    // splash showed but its bars never moved. The store now defers the
    // decode (SubscriptionStore deferred-load init) and bootstrap() runs it
    // off-main via completeDeferredLoad(), keeping the main actor free so
    // the splash actually animates.
    @State private var model: TVAppModel?
    @Environment(\.scenePhase) private var scenePhase
    // CKSyncEngine uses the app delegate's remote-notification registration
    // to receive private-iCloud change notifications while the app is installed.
    @UIApplicationDelegateAdaptor(TVAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    TVRootView(model: model)
                } else {
                    TVLaunchLoadingView(statusText: "Loading your library…")
                }
            }
            .preferredColorScheme(.dark)
            .task {
                guard model == nil else { return }
                // Give the splash one rendered frame before the heavy
                // synchronous store load begins.
                try? await Task.sleep(for: .milliseconds(50))
                let created = TVAppModel()
                model = created
                await created.bootstrap()
            }
            .onChange(of: scenePhase) { _, phase in
                guard let model else { return }
                model.isSceneActive = (phase == .active)
                // Returning to the foreground: re-prime the library + queue
                // snapshot directly so the Library and Up Next reflect any
                // phone-side changes (new subscriptions, reordered queue)
                // made while the TV app was backgrounded, without waiting
                // for the change stream to drain.
                if phase == .active {
                    Task { await model.primeLibraryFromCloudSoon(reason: "foreground") }
                } else {
                    // Leaving the foreground: persist + force-push the
                    // current position so it reaches the phone promptly.
                    model.handleBackgrounded()
                    TVArtworkLoader.shared.trimForMemoryPressure()
                }
            }
        }
    }
}

@MainActor
@Observable
final class TVAppModel {
    enum RootState {
        case loading
        case ready
        case empty
    }

    private(set) var rootState: RootState = .loading
    private(set) var statusText = "Loading your library…"
    private(set) var syncStatus: TVSyncStatus = .updating
    /// Observation-tracked mirror of the store's real (non-browse) library,
    /// priority order. TV views read THIS, never the store directly.
    // `AutohopCore.Subscription` qualified — Combine also declares a
    // `Subscription` protocol, and both are visible here (this file imports
    // Combine for AnyCancellable/debounce), which is otherwise ambiguous.
    private(set) var librarySubscriptions: [AutohopCore.Subscription] = []
    private(set) var libraryTiles: [TVPodcastTileModel] = []
    private(set) var episodeRowsBySubscription: [UUID: [TVEpisodeRowModel]] = [:]
    private(set) var loadingEpisodeSubscriptions: Set<UUID> = []
    /// The phone owns the queue snapshot and may not publish its replacement
    /// immediately. Keep an archived row hidden locally in the meantime.
    private var locallyArchivedEpisodeKeys: Set<String> = []

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
    private let survivalKitStore = SurvivalKitStore()
    private let projectionStore: TVProjectionStore?
    private var cloudSyncEngine: CloudSyncEngine?
    private var cancellables = Set<AnyCancellable>()
    private var didBootstrap = false
    private var queueEnrichmentTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingQueueEnrichmentIDs: [UUID] = []
    private var failedQueueEnrichmentIDs: Set<UUID> = []
    private var queueEnrichmentAttempts: [UUID: Int] = [:]
    /// Durable identity lives in SubscriptionSurvivalKit; these tasks are only
    /// the in-process retry schedulers. A relaunch reconstructs them from the
    /// kit, so a transient RSS/CDN failure cannot permanently erase a show.
    private var materializationRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var materializationAttempts: [UUID: Int] = [:]
    private var legacyQueueEpisodes: [String: Episode] = [:]
    private var legacyQueuePodcastTitles: [String: String] = [:]
    private let episodeFeedLoader = EpisodeFeedLoader()
    private let foregroundSyncCoordinator = TVForegroundSyncCoordinator()
    private var lastHistoryPrimeAt = Date.distantPast
    private var historyPrimeTask: Task<Int, Never>?
    private let durableMaterializationMigrationKey = "com.autohop.tv.durableMaterializationPrime.v1"

    /// TVAppDelegate has no other path to the running model (tvOS has no
    /// AppState.sharedOrBootstrap()-style composition root) — mirrors that
    /// pattern with a weak static instead. Safe: @State in AutohopTVApp keeps
    /// the one TVAppModel alive for the app's lifetime; weak just avoids a
    /// retain cycle through the delegate, which never itself needs to own it.
    private(set) static weak var shared: TVAppModel?

    init() {
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

        // T2: the database is a rebuildable cache — it belongs in Caches so the
        // system may purge it; durable truth is the survival kit + CloudKit.
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let databaseDirectory = cachesDirectory?.appendingPathComponent("Autohop", isDirectory: true)
        if let databaseDirectory {
            try? FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        }
        // Deferred load (2026-07-11 launch-freeze fix): opening the DB is
        // cheap; the 113-show payload decode is NOT, and doing it here froze
        // the splash into a static image (SwiftUI animations are main-thread
        // driven — a blocked main actor stops them dead). bootstrap() awaits
        // completeDeferredLoad(), which decodes off-main.
        let store = SubscriptionStore(
            deferredLoadDatabasePath: databaseDirectory?.appendingPathComponent("autohop-tv.sqlite").path
        )
        subscriptionStore = store
        projectionStore = databaseDirectory.flatMap {
            try? TVProjectionStore(path: $0.appendingPathComponent("autohop-tv-projections.sqlite").path)
        }
        let statsStore = ListeningStatsStore(
            fileURL: databaseDirectory?.appendingPathComponent("listening-stats.json"),
            legacyFileURL: nil
        )
        statsStore.attachSyncDatabase(from: store)
        listeningStatsStore = statsStore
        playbackModel = TVPlaybackModel(subscriptionStore: store, statsStore: statsStore)

        playbackModel.upNextProvider = { [weak self] in self?.upNextEpisodes ?? [] }
        playbackModel.subscriptionProvider = { [weak self] id in self?.subscription(id: id) }
        // Force-push a just-written position immediately (pause / player exit),
        // so a TV-side pause reaches the phone in seconds instead of waiting out
        // the engine's ~60 s slow-lane debounce.
        playbackModel.onPlaybackCheckpoint = { [weak self] in
            self?.cloudSyncEngine?.flushAndSendDeferredPushes(reason: "tv.playbackCheckpoint")
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

    /// Called when the TV app backgrounds/resigns active: persist the current
    /// position and force-push it, mirroring the iPhone's scene-background flush.
    func handleBackgrounded() {
        playbackModel.checkpoint()
    }

    /// Starts playback of an episode, resolving its owning subscription for
    /// playback preference/chapter filter/history metadata. No-op if the
    /// subscription can no longer be resolved (e.g. unsubscribed elsewhere).
    func beginPlayback(_ episode: Episode) async {
        let authoritativeHistory = cachedContinueEntry.flatMap {
            episodeResolver.historyEntry($0, belongsTo: episode) ? $0 : nil
        } ?? subscriptionStore.listeningHistoryEntry(matching: episode)
        let resolution = episodeResolver.playbackResolution(
            for: episode,
            candidateHistory: authoritativeHistory
        )
        await playbackModel.play(
            episode: resolution.episode,
            subscription: resolution.subscription,
            resumePositionOverride: resolution.historyEntry?.lastPositionSeconds,
            historyEntryID: resolution.historyEntry?.id,
            displayPodcastTitle: resolution.historyEntry?.podcastTitle,
            verifyVideoIfAmbiguous: resolution.needsAssetMediaProbe
        )
    }

    /// Archives from any tvOS episode surface. Archive is authored through the
    /// durable companion identity path so legacy queue/history projections are
    /// not dependent on matching a current local episode UUID. If this is the
    /// active episode, playback is stopped before the row is removed.
    func archiveEpisode(_ episode: Episode) {
        let isCurrent = playbackModel.isCurrentEpisode(episode)
        let canonicalEpisode = TVEpisodeResolver.canonicalized(episode)
        if isCurrent { playbackModel.stopAndClear() }
        locallyArchivedEpisodeKeys.insert(PlaybackPositionStore.key(for: episode))
        subscriptionStore.markListeningHistoryArchived(episode: episode)
        let authored = subscriptionStore.markCompanionEpisodeArchived(
            canonicalEpisode,
            preferredSubscriptionID: canonicalEpisode.subscriptionID
        )
        AppLogger.shared.info("tv.episodeArchived", "Episode archived from Apple TV", metadata: [
            "episodeID": episode.id.uuidString,
            "subscriptionID": episode.subscriptionID.uuidString,
            "sourceGUID": episode.guid,
            "canonicalGUID": canonicalEpisode.guid,
            "wasCurrent": "\(isCurrent)",
            "stateAuthored": "\(authored)"
        ], alwaysPersist: true)
        historyNeedsReload = true
        refreshLibrary()
        cloudSyncEngine?.flushAndSendDeferredPushes(reason: "tv.episodeArchived")
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Finish the deferred store load FIRST (off-main decode — see init's
        // note); everything below reads store.subscriptions.
        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        await subscriptionStore.completeDeferredLoad()
        AppLogger.shared.info("tv.perf", "Deferred store load finished", metadata: [
            "stage": "storeLoad",
            "ms": String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000),
            "subscriptions": "\(subscriptionStore.subscriptions.count)"
        ], alwaysPersist: true)

        if let kit = survivalKitStore.load() {
            await rebuildMissingSubscriptions(from: kit)
        }
        // ONE-SHOT REPAIR (2026-07-11) — MUST run before startCloudSync(): a TV
        // database rebuilt from the survival kit before the materialize
        // clean-seed fix holds fully-dirty DEFAULT-settings projections for
        // every subscription; engine activation queues dirty state, so starting
        // sync first would re-push the defaults and re-clobber the phone's real
        // settings (the exact damage Kevin reported). Safe on TV because the TV
        // never authors subscription settings — see the method's header.
        let repairFlag = "com.autohop.tv.cleanDefaultProjectionDirt.v1"
        if !UserDefaults.standard.bool(forKey: repairFlag) {
            let cleaned = subscriptionStore.markAllPendingSubscriptionProjectionsClean()
            UserDefaults.standard.set(true, forKey: repairFlag)
            if cleaned > 0 {
                AppLogger.shared.warning("sync.tvProjectionDirtRepaired", "Cleared pre-fix dirty subscription projections that would have pushed default settings", metadata: [
                    "count": "\(cleaned)"
                ], alwaysPersist: true)
            }
        }
        startCloudSync()
        observeStoreForKitWrites()
        startForegroundFreshnessPolling()

        // Prime the library DIRECTLY (targeted zone queries) rather than
        // waiting for CKSyncEngine's cold-start delta stream — Kevin's
        // real-device findings were a ~5-min "No Library Yet" blank AND the Up
        // Next queue cycling stale episodes for ~10 min. This fetches every
        // subscription record (kicking off feed materialisation immediately)
        // and the Up Next queue snapshot the moment the engine activates. Runs
        // in the background (retries until activation) so it never blocks the
        // launch path.
        Task { await primeLibraryFromCloudSoon(reason: "launch") }

        // Fast path: the survival-kit rebuild (or a database that already
        // survived from a previous launch) may already have real content —
        // don't make a returning device sit through the first-sync wait.
        refreshLibrary()
        // Never hold the focus UI behind a multi-minute carousel. A compact
        // cached projection renders immediately; a true first install gets a
        // short connection grace, then an actionable empty/offline state while
        // CloudKit continues progressively in the background.
        guard rootState != .ready else { return }
        rootState = .loading
        statusText = "Connecting to your iCloud library…"
        try? await Task.sleep(for: .seconds(8))
        refreshLibrary()
    }

    /// Shown IN ORDER (not shuffled) so the informative ones about what's
    /// actually happening come first, then Autohop feature highlights, with
    /// family-friendly dad jokes sprinkled throughout for relief. 42 messages
    /// at 7 s each ≈ 5 minutes before any repeat — longer than the ~4-minute
    /// first sync observed on real hardware, so a user should never see the
    /// same line twice. Tripled + feature-highlighted per Kevin's request
    /// (2026-07-04) after the previous 14 still felt thin on a real wait.
    private static let firstSyncWaitMessages = [
        // — What's actually happening (process, in rough order) —
        "Connecting to your iCloud library…",
        "Asking iCloud for your podcasts — the first sync fetches everything, so it takes a few minutes…",
        "Your subscriptions arrive first, then each show's episode list…",
        "Why don't podcasts ever get lost? They always follow the feed.",
        "Downloading your show list from iCloud — it only takes this long the first time…",
        "Played and archived episodes are matched up next, so your progress carries over…",
        "I asked iCloud to hurry up. It said it needed a moment to sync in.",
        "Episode artwork and details are filled in from each show's RSS feed…",
        "Your Priority Stack order comes across too — shows appear in YOUR order…",
        "What's a podcast's favourite exercise? The feed-lift.",
        "Listening positions sync as well, so you can resume right where you left off…",
        "Your Up Next queue syncs from your iPhone — same episodes, same order…",
        "Why did the episode go to school? To get a little more well-listened.",
        // — Feature highlights (the Autohop tour) —
        "Autohop's Priority Stack plays your favourite shows first, automatically…",
        "On iPhone, new episodes download themselves — Up Next is always ready to play…",
        "What do you call a queue that builds itself? Up Next. We checked — it's very modest about it.",
        "Release Radar learns each show's schedule and checks feeds right when new episodes drop…",
        "Trim Silence on iPhone skips the quiet gaps — hours saved without missing a word…",
        "Vocal Boost lifts voices above the background music, great for noisy rooms…",
        "Why did the silence get trimmed? It didn't have anything to say for itself.",
        "Sleep Schedule can ask 'still listening?' at night and rewind to where you dozed off…",
        "The Stats page tracks your listening streaks, top shows, and total time saved…",
        "Chapters are supported too — skip straight to the segment you want…",
        "What's a podcast host's favourite dinner? Anything with good seasoning… and a mid-roll.",
        "Download Filters can skip trailers and short episodes automatically…",
        "Autohop works in the car too — the full queue is on CarPlay…",
        "Shared Listening slows things down evenly so everyone in the room can follow along…",
        "Why don't podcast apps tell secrets? Too many listeners.",
        "Everything syncs through YOUR private iCloud — no accounts, no servers, no tracking…",
        "Episodes played here mark as played on your iPhone too — one library, everywhere…",
        // — Reassurance (the long-tail wait) —
        "Still syncing — larger libraries take a little longer, but it's all on the way…",
        "What did the Apple TV say to the iPhone? 'You're breaking up… but your podcasts aren't.'",
        "Nearly there — the first sync is always the slowest; launches after this are instant…",
        "Your queue, positions, and played history are all coming across…",
        "Why was the podcast app so calm? Everything was under subscription.",
        "Apple's iCloud sets the pace on a first sync — Autohop grabs everything the moment it lands…",
        "Once this finishes, this Apple TV stays in step with your iPhone automatically…",
        "How does a podcast say goodbye? 'Thanks for listening — see you next episode!'",
        "Hang tight — good things come to those who sync…",
        "Fetching the last few shows now…",
        "What's the loading screen's favourite song? 'The Waiting' — it's a deep cut.",
        "Almost done — your library is nearly all here…"
    ]

    /// Legacy compatibility helper. Bootstrap no longer calls this carousel;
    /// first launch gets an eight-second grace and then remains interactive.
    private func waitForFirstSyncWithAnimatedStatus() async {
        var messageIndex = 0
        for _ in 0..<Self.firstSyncWaitMessages.count {
            guard rootState == .loading else { return }
            statusText = Self.firstSyncWaitMessages[messageIndex % Self.firstSyncWaitMessages.count]
            messageIndex += 1
            try? await Task.sleep(for: .seconds(7))
        }
    }

    // MARK: - Purge recovery (T2)

    private func rebuildMissingSubscriptions(from kit: SubscriptionSurvivalKit) async {
        let missing = kit.entries
            .filter { subscriptionStore.subscription(id: $0.subscriptionID) == nil }
            .sorted { $0.priorityRank < $1.priorityRank }
        guard !missing.isEmpty else { return }
        statusText = "Rebuilding your library…"
        for entry in missing {
            let succeeded = await materializeFeed(
                url: entry.feedURL,
                subscriptionID: entry.subscriptionID,
                priorityRank: entry.priorityRank
            )
            if !succeeded { scheduleMaterializationRetry(entry) }
        }
    }

    /// Fetch + parse a feed and recreate its subscription with a PRESERVED id.
    /// Failures are retained in the survival kit and owned by the bounded retry
    /// worker below; an unchanged CloudKit record is not assumed to reappear.
    @discardableResult
    private func materializeFeed(url: URL, subscriptionID: UUID, priorityRank: Int?) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Parse OFF the main actor (2026-07-11 nav-stall fix): this runs
            // in a @MainActor context, so a bare parse() of each of 113 feeds
            // during a purge rebuild serially blocked the main thread — one
            // ingredient of the "focus feels stuck, then jumps" remote lag.
            let parsed = try await Task.detached(priority: .userInitiated) {
                try RSSParser().parse(data: data, maxEpisodes: 50)
            }.value
            subscriptionStore.materialize(
                parsedFeed: parsed,
                feedURL: url,
                subscriptionID: subscriptionID,
                priorityRank: priorityRank
            )
            materializationAttempts[subscriptionID] = nil
            materializationRetryTasks[subscriptionID]?.cancel()
            materializationRetryTasks[subscriptionID] = nil
            saveSurvivalKit()
            return true
        } catch {
            AppLogger.shared.warning("tv.materializeFailed", "Could not fetch a feed during TV bootstrap", metadata: [
                "url": url.absoluteString,
                "error": String(describing: error)
            ], alwaysPersist: true)
            return false
        }
    }

    /// Records a remote identity before touching the network. This is the
    /// missing durability edge in the former implementation: CloudKit may not
    /// resend an unchanged record after a one-off RSS failure.
    private func rememberMaterializationCandidate(_ entry: SurvivalKitEntry) {
        var kit = survivalKitStore.load() ?? SubscriptionSurvivalKit(entries: [], iCloudSyncEnabled: true)
        if let index = kit.entries.firstIndex(where: { $0.subscriptionID == entry.subscriptionID }) {
            kit.entries[index] = entry
        } else {
            kit.entries.append(entry)
        }
        kit.entries.sort { $0.priorityRank < $1.priorityRank }
        survivalKitStore.save(kit)
        refreshLibrary()
    }

    private func forgetMaterializationCandidate(id: UUID) {
        guard var kit = survivalKitStore.load() else { return }
        kit.entries.removeAll { $0.subscriptionID == id }
        survivalKitStore.save(kit)
        materializationAttempts[id] = nil
        materializationRetryTasks[id]?.cancel()
        materializationRetryTasks[id] = nil
        refreshLibrary()
    }

    /// Retries indefinitely with a capped delay while the app remains alive.
    /// The survival kit re-establishes the loop after relaunch. Only one worker
    /// may own a subscription ID, preventing retry storms on repeated sync
    /// callbacks or manual refreshes.
    private func scheduleMaterializationRetry(_ entry: SurvivalKitEntry, immediate: Bool = false) {
        rememberMaterializationCandidate(entry)
        guard subscriptionStore.subscription(id: entry.subscriptionID) == nil,
              materializationRetryTasks[entry.subscriptionID] == nil else { return }
        materializationRetryTasks[entry.subscriptionID] = Task { [weak self] in
            guard let self else { return }
            var runImmediately = immediate
            while !Task.isCancelled,
                  self.subscriptionStore.subscription(id: entry.subscriptionID) == nil {
                if self.subscriptionStore.syncedSubscriptionWantsMembership(id: entry.subscriptionID) == false {
                    self.forgetMaterializationCandidate(id: entry.subscriptionID)
                    break
                }
                let attempt = (self.materializationAttempts[entry.subscriptionID] ?? 0) + 1
                self.materializationAttempts[entry.subscriptionID] = attempt
                if !runImmediately {
                    let delays: [TimeInterval] = [5, 30, 120, 300, 900]
                    try? await Task.sleep(for: .seconds(delays[min(attempt - 1, delays.count - 1)]))
                }
                runImmediately = false
                guard !Task.isCancelled else { break }
                let succeeded = await self.materializeFeed(
                    url: entry.feedURL,
                    subscriptionID: entry.subscriptionID,
                    priorityRank: entry.priorityRank
                )
                if succeeded { break }
                AppLogger.shared.info("tv.materializeRetryScheduled", "Subscription materialisation remains pending", metadata: [
                    "subscriptionID": entry.subscriptionID.uuidString,
                    "attempt": "\(attempt)",
                    "feedHost": entry.feedURL.host ?? "unknown"
                ], alwaysPersist: true)
            }
            self.materializationRetryTasks[entry.subscriptionID] = nil
        }
    }

    private func retryPendingMaterializationsNow() {
        let realIDs = Set(subscriptionStore.subscriptions.filter { $0.browseDate == nil }.map(\.id))
        for entry in survivalKitStore.load()?.entries ?? [] where !realIDs.contains(entry.subscriptionID) {
            if subscriptionStore.syncedSubscriptionWantsMembership(id: entry.subscriptionID) == false {
                forgetMaterializationCandidate(id: entry.subscriptionID)
                continue
            }
            materializationRetryTasks[entry.subscriptionID]?.cancel()
            materializationRetryTasks[entry.subscriptionID] = nil
            scheduleMaterializationRetry(entry, immediate: true)
        }
    }

    // MARK: - Sync

    private func startCloudSync() {
        // pushesSubscriptionState: false — HARD one-way rule (2026-07-11,
        // Kevin's directive after the purge-rebuild default-settings damage):
        // the TV must have ZERO ability to alter subscription settings,
        // subscribed state, or priority ranking on the phone. The engine
        // structurally refuses to push SubscriptionState records in this mode
        // (dirty rows never queued; restored pending saves dropped; legacy
        // recovery skipped). Episode played-state, history, stats, and the
        // queue snapshot still push — those are the TV's legitimate outputs.
        // Consequence: subscribe-on-TV stays local to the TV.
        let engine = CloudSyncEngine(
            containerIdentifier: "iCloud.com.kevinperry.autohop",
            subscriptionStore: subscriptionStore,
            capabilities: .tvCompanion
        )
        engine.onSubscriptionNeedsMaterialization = { [weak self] state in
            await self?.materializeRemoteSubscription(state)
        }
        // Notify-only (persistence happens in the engine): re-render Up Next
        // the moment a newer phone-authored queue snapshot lands. The hop back
        // to the main actor is the await; refreshLibrary itself is synchronous.
        engine.onRemoteQueueSnapshotChanged = { [weak self] in
            await MainActor.run { self?.scheduleLibraryRefresh() }
        }
        // Notify-only: re-render Home when a listening-history entry lands, so
        // Continue Watching populates the moment the paused-on-iPhone episode's
        // resume position syncs (it's read from the DB, not Observation-tracked).
        // COALESCED + history-cache invalidation — see scheduleLibraryRefresh's
        // header and continueListeningCache below.
        engine.onRemoteHistoryChanged = { [weak self] in
            await MainActor.run {
                self?.historyNeedsReload = true
                self?.scheduleLibraryRefresh()
            }
        }
        cloudSyncEngine = engine
        engine.start()
    }

    private func materializeRemoteSubscription(_ state: SubscriptionSyncState) async {
        let entry = SurvivalKitEntry(
            subscriptionID: state.subscriptionID,
            feedURL: state.feedURL,
            priorityRank: state.priorityRank,
            title: state.title
        )
        rememberMaterializationCandidate(entry)
        let succeeded = await materializeFeed(
            url: state.feedURL,
            subscriptionID: state.subscriptionID,
            priorityRank: state.priorityRank
        )
        if succeeded {
            subscriptionStore.applyRemoteSubscriptionState(state)
        } else {
            scheduleMaterializationRetry(entry)
        }
        refreshLibrary()
    }

    /// Targeted library prime, retried until the engine has finished its async
    /// activation (account status check). Fetches all subscription records
    /// (kicking off materialisation) AND the Up Next queue snapshot directly,
    /// bypassing the cold-start delta stream. Call at launch and on foreground
    /// so the Library populates fast and Up Next mirrors the phone quickly.
    /// Idempotent — re-priming on foreground also picks up subscriptions added
    /// on the phone since the last launch.
    func primeLibraryFromCloudSoon(reason: String) async {
        // ~15 s of retries at 1 s intervals — enough for the account check +
        // activation; gives up quietly if sync never comes up (e.g. no iCloud).
        for _ in 0..<15 {
            guard let engine = cloudSyncEngine, engine.isActivated else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            // ORDER MATTERS (reordered 2026-07-11, Kevin's real-device round 5:
            // "old shows in Up Next for ~30 s" + a stale Resume card): the queue
            // snapshot and listening history are each ONE cheap targeted fetch,
            // while fetchAllSubscriptionsNow paginates all 113 subscription
            // records. Fetching the cheap, user-facing state FIRST and rendering
            // immediately means Up Next and Continue Listening are phone-correct
            // within a couple of seconds; the subscription sweep then fills in
            // catalogs behind it (each landing record re-renders via the store
            // observer).
            syncStatus = .updating
            retryPendingMaterializationsNow()
            let fetched = await engine.fetchQueueSnapshotNow(reason: reason)
            refreshLibrary()
            // Queue truth is independent of the much larger first-time Library
            // and history queries. Report Up Next current as soon as its
            // singleton lands instead of showing “Updating” for the entire
            // ten-minute cold-zone materialization.
            if let snapshot = subscriptionStore.syncedQueueSnapshot() {
                syncStatus = .upToDate(snapshot.updatedAt, generation: snapshot.generation)
            } else if !fetched {
                syncStatus = .unavailable
            }

            let shouldFetchHistory = Date().timeIntervalSince(lastHistoryPrimeAt) >= 15 * 60 || reason == "launch"
            // One full membership sweep repairs subscriptions that disappeared
            // before durable materialisation shipped and therefore are absent
            // from both the current database and old survival kit. Manual Check
            // for Updates is also an explicit request for this authoritative
            // sweep; ordinary foreground activation remains projection-only.
            let needsDurableMaterializationMigration = !UserDefaults.standard.bool(
                forKey: durableMaterializationMigrationKey
            )
            let shouldFetchSubscriptions = reason == "bootstrap"
                || reason == "tv.manualRetry"
                || librarySubscriptions.isEmpty
                || needsDurableMaterializationMigration
            let migrationKey = durableMaterializationMigrationKey
            let historyTask = shouldFetchHistory
                ? sharedRecentHistoryPrime(engine: engine, reason: reason)
                : nil
            let subscriptionTask = shouldFetchSubscriptions ? Task { [weak self] in
                _ = await engine.fetchAllSubscriptionsNow(reason: reason)
                if needsDurableMaterializationMigration {
                    UserDefaults.standard.set(true, forKey: migrationKey)
                }
                self?.refreshLibrary()
            } : nil
            // A foreground queue/history recovery must not re-download and
            // reapply the complete subscription zone. Bootstrap owns the full
            // library prime; later activations use compact projections only.
            if let subscriptionTask { await subscriptionTask.value }
            if let historyTask { _ = await historyTask.value }
            refreshLibrary()
            // Phase 2: projection-first TV does not sweep the entire RSS
            // library. Queue v2 is self-contained; targeted detail enrichment
            // may fetch one feed in a later phase, but sync never triggers an
            // all-subscription network/parse pass.
            return
        }
        syncStatus = subscriptionStore.syncedQueueSnapshot().map {
            .cached($0.updatedAt, generation: $0.generation)
        } ?? .unavailable
    }

    // MARK: - Library state + kit write-back

    /// Mirrors scenePhase — set by AutohopTVApp's onChange. Gates the
    /// freshness poll below so a backgrounded TV app isn't fetching.
    var isSceneActive = true

    /// CONTINUE-LISTENING FRESHNESS SAFETY NET. CloudKit changes are the primary
    /// path. While frontmost, the TV uses the bounded
    /// TVForegroundSyncPolicy fallback so a missed notification cannot leave
    /// Home/Up Next stale for the former five-to-ten-minute window. Equality
    /// guards keep a no-change poll render-free.
    private func startForegroundFreshnessPolling() {
        foregroundSyncCoordinator.start { [weak self] in
            await self?.performForegroundFreshnessPoll()
        }
    }

    private func performForegroundFreshnessPoll() async {
        guard isSceneActive, let engine = cloudSyncEngine, engine.isActivated else { return }
        let snapshot = subscriptionStore.syncedQueueSnapshot()
        let shouldFetchQueue = TVForegroundSyncPolicy.shouldFetch(
            snapshotUpdatedAt: snapshot?.updatedAt
        )
        let shouldFetchHistory = Date().timeIntervalSince(lastHistoryPrimeAt)
            >= TVForegroundSyncPolicy.maximumSnapshotAge
        guard shouldFetchQueue || shouldFetchHistory else { return }

        syncStatus = .updating
        if shouldFetchQueue {
            _ = await engine.fetchQueueSnapshotNow(reason: "tv.freshnessPoll")
        }
        if shouldFetchHistory {
            _ = await sharedRecentHistoryPrime(engine: engine, reason: "tv.freshnessPoll").value
            historyNeedsReload = true
        }
        refreshLibrary()
        if let snapshot = subscriptionStore.syncedQueueSnapshot() {
            syncStatus = .upToDate(snapshot.updatedAt, generation: snapshot.generation)
        }
    }

    /// One owner for launch/foreground history recovery. Scene activation can
    /// race bootstrap while the first CloudKit query is still in flight; the
    /// old code started a second ~3,000-record sweep because
    /// `lastHistoryPrimeAt` changed only after completion.
    private func sharedRecentHistoryPrime(
        engine: CloudSyncEngine,
        reason: String
    ) -> Task<Int, Never> {
        if let historyPrimeTask { return historyPrimeTask }
        let task = Task { [weak self] in
            let count = await engine.fetchRecentHistoryNow(reason: reason, limit: 100)
            await MainActor.run {
                self?.lastHistoryPrimeAt = Date()
                self?.historyPrimeTask = nil
            }
            return count
        }
        historyPrimeTask = task
        return task
    }

    /// Stage-timing probe (TV diagnostics, 2026-07-11): runs `body` and logs a
    /// `tv.perf` line when it took ≥ `thresholdMs` on the main actor. Cheap
    /// enough to leave on permanently; the threshold keeps the log signal-only.
    /// Cross-reference with tv.mainThreadHang timestamps to see WHICH stage
    /// was blocking during a stutter.
    @discardableResult
    private func timed<T>(_ stage: String, thresholdMs: Double = 40, _ body: () -> T) -> T {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = body()
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        if elapsedMs >= thresholdMs {
            AppLogger.shared.info("tv.perf", "Main-actor stage was slow", metadata: [
                "stage": stage,
                "ms": String(format: "%.0f", elapsedMs)
            ], alwaysPersist: true)
        }
        return result
    }

    private func saveSurvivalKit() {
        timed("kitCapture") {
            var captured = SubscriptionSurvivalKit.capture(
                from: subscriptionStore.subscriptions,
                iCloudSyncEnabled: true
            )
            // Preserve identities that are still awaiting RSS materialisation;
            // membershipDidChange for another show must not erase them.
            let capturedIDs = Set(captured.entries.map(\.subscriptionID))
            let pending = (survivalKitStore.load()?.entries ?? []).filter {
                !capturedIDs.contains($0.subscriptionID)
            }
            captured.entries.append(contentsOf: pending)
            captured.entries.sort { $0.priorityRank < $1.priorityRank }
            survivalKitStore.save(captured)
        }
    }

    private func observeStoreForKitWrites() {
        subscriptionStore.membershipDidChange
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.saveSurvivalKit()
                self.scheduleLibraryRefresh()
            }
            .store(in: &cancellables)

        Publishers.Merge(
            subscriptionStore.queueDidChange,
            subscriptionStore.presentationDidChange
        )
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleLibraryRefresh()
            }
            .store(in: &cancellables)
    }

    // REFRESH COALESCER (2026-07-11, round-8 watchdog finding): the round-8
    // log showed refreshLibrary running back-to-back at ~290 ms per pass for
    // MINUTES — the engine's notify callbacks fired once per applied record
    // (hundreds of history records per prime/poll), and each call did a full
    // derived-state recompute on the main actor. The engine now batches its
    // own notifies (fetchAllHistoryNow), and this coalescer is the TV-side
    // guarantee: notify-driven refreshes collapse to AT MOST one pass per
    // 500 ms window no matter how fast callbacks arrive. Direct callers with
    // sequencing needs (bootstrap/prime tails) still call refreshLibrary().
    private var pendingLibraryRefresh: Task<Void, Never>?
    private var lastLibraryRefreshAt = Date.distantPast
    private var lastLibraryRefreshDuration: TimeInterval = 0

    private func scheduleLibraryRefresh() {
        guard pendingLibraryRefresh == nil else { return }
        // DUTY-CYCLE BOUND (round-8b second log): a fixed 500 ms window still
        // let ~300 ms passes eat ~60% of the main thread while the cold sync
        // stream churned. Spacing is now ≥6× the LAST pass's own duration, so
        // however expensive a pass is, refreshes can never take more than
        // ~15% of main-thread time — the focus engine keeps the rest.
        let minimumSpacing = max(0.5, lastLibraryRefreshDuration * 6)
        let sinceLast = Date().timeIntervalSince(lastLibraryRefreshAt)
        let delay = max(minimumSpacing - sinceLast, 0.05)
        pendingLibraryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.pendingLibraryRefresh = nil
            self.refreshLibrary()
        }
    }

    private func refreshLibrary() {
        lastLibraryRefreshAt = Date()
        let startedAt = CFAbsoluteTimeGetCurrent()
        timed("refreshLibrary") { refreshLibraryBody() }
        lastLibraryRefreshDuration = CFAbsoluteTimeGetCurrent() - startedAt
    }

    private func refreshLibraryBody() {
        // EQUALITY GUARDS (2026-07-11 nav-stall fix, part 3): @Observable
        // fires on every SET regardless of value equality, and this method is
        // called from several periodic paths (store observer, cloud prime, the
        // foreground freshness poll) — unconditional reassignment re-rendered
        // the whole Home/Queue tree even when nothing changed, disturbing the
        // tvOS focus engine mid-navigation. A no-change refresh is now a
        // genuine no-op: nothing is written, so nothing re-renders.
        let newLibrary = subscriptionStore.subscriptions
            .filter { $0.browseDate == nil }
            .sorted { $0.priorityRank < $1.priorityRank }
        let libraryChanged = newLibrary != librarySubscriptions
        if libraryChanged {
            librarySubscriptions = newLibrary
            rebuildOrphanRecoveryIndexes()
            let compact = newLibrary.map {
                TVLibraryProjectionEntry(id: $0.id, title: $0.title, author: $0.author, artworkURL: $0.artworkURL, feedURL: $0.feedURL, priorityRank: $0.priorityRank)
            }
            Task.detached(priority: .utility) { [projectionStore] in
                try? projectionStore?.saveLibrary(compact)
            }
        }
        let realIDs = Set(newLibrary.map(\.id))
        let pendingEntries = (survivalKitStore.load()?.entries ?? []).filter { !realIDs.contains($0.subscriptionID) }
        let newTiles = (newLibrary.map {
            TVPodcastTileModel(id: $0.id, title: $0.title, author: $0.author, artworkURL: $0.artworkURL, feedURL: $0.feedURL, priorityRank: $0.priorityRank, isMaterializing: false)
        } + pendingEntries.map {
            TVPodcastTileModel(id: $0.subscriptionID, title: $0.title, author: nil, artworkURL: nil, feedURL: $0.feedURL, priorityRank: $0.priorityRank, isMaterializing: true)
        }).sorted { $0.priorityRank < $1.priorityRank }
        if newTiles != libraryTiles { libraryTiles = newTiles }
        let newRootState: RootState = newTiles.isEmpty ? .empty : .ready
        if newRootState != rootState { rootState = newRootState }

        // PERF FIX (2026-07-10, found investigating a reported memory/CPU bug):
        // subscriptionsByID + upNextItems/upNextEpisodes/
        // continueListening were all previously COMPUTED properties, recomputed
        // from scratch on every access — including subscription(id:)'s O(n)
        // linear scan and continueListening's DB query + full flatMap/filter/max
        // over every episode across every show. TVHomeView/TVQueueView read
        // several of these MULTIPLE TIMES per body evaluation, and tvOS's
        // focus-engine-driven navigation re-evaluates view bodies far more
        // often than actual data changes — at Kevin's real library size (113
        // shows, matching his iPhone; this file's own header previously assumed
        // "dozens" and flagged "revisit if a TV library ever grows large enough
        // to matter" — it has), that added up to real, repeated CPU/memory cost
        // during ordinary remote-navigation, not just at sync/launch time.
        // Fixed by computing all of this ONCE here — whenever the library
        // actually changes — and reading it back as plain O(1) stored state.
        let queueSnapshot = subscriptionStore.syncedQueueSnapshot()
        let queueChanged = queueSnapshot != lastRenderedQueueSnapshot
        let historyChanged = historyNeedsReload
        let projectionsChanged = libraryChanged || queueChanged || historyChanged
        if projectionsChanged {
            if queueChanged { lastRenderedQueueSnapshot = queueSnapshot }
            recomputeDerivedState(
                recomputeQueue: libraryChanged || queueChanged,
                recomputeHistory: libraryChanged || historyChanged
            )
        }
        // A synced history row can itself unlock an orphan compatibility feed
        // even when neither the library nor queue changed. This is the exact
        // old-phone case where Continue Listening arrives during playback.
        if projectionsChanged { retryLegacyRowsWhoseSourcesArrived() }

        // Pre-buffer the Continue Listening episode (the one most likely to be
        // played next) so resuming it starts near-instantly. Idempotent per
        // URL — a matching in-flight preload is left untouched. Skipped while
        // something is already playing.
        if playbackModel.currentEpisode == nil, let resume = continueListening?.episode {
            playbackModel.preload(episode: resume)
        }
    }

    private func recomputeDerivedState(recomputeQueue: Bool, recomputeHistory: Bool) {
        if recomputeQueue {
            subscriptionsByID = Dictionary(uniqueKeysWithValues: librarySubscriptions.map { ($0.id, $0) })
            // AI CONTEXT — History checkpoints must never rebuild Up Next.
            // Log 25 showed 199 queue projections for only five meaningful
            // queue generations because history invalidation shared this path.
            let newUpNextItems = computeUpNextItems().map { item in
                let recovered = legacyQueueEpisodes[item.episodeKey] ?? recoveredLocalEpisode(for: item)
                guard item.episode == nil, let recovered else { return item }
                return QueueModel.ResolvedQueueItem(
                    episodeKey: item.episodeKey,
                    title: recovered.title,
                    podcastTitle: item.podcastTitle ?? legacyQueuePodcastTitles[item.episodeKey],
                    subscriptionID: item.subscriptionID,
                    episode: recovered
                )
            }.filter { item in
                guard let episode = item.episode else {
                    return !locallyArchivedEpisodeKeys.contains(item.episodeKey)
                }
                return !locallyArchivedEpisodeKeys.contains(PlaybackPositionStore.key(for: episode))
            }
            if newUpNextItems != upNextItems {
                upNextItems = newUpNextItems
                upNextEpisodes = newUpNextItems.compactMap(\.episode)
                queueRows = newUpNextItems.enumerated().map { index, item in
                    TVQueueRowModel(
                        id: item.episodeKey,
                        position: index + 1,
                        title: item.title,
                        podcastTitle: item.podcastTitle
                            ?? item.episode.flatMap { subscriptionsByID[$0.subscriptionID]?.title }
                            ?? subscriptionsByID[item.subscriptionID]?.title
                            ?? "Podcast",
                        artworkURL: item.episode?.artworkURL ?? subscriptionsByID[item.subscriptionID]?.artworkURL,
                        durationSeconds: item.episode?.durationSeconds,
                        mediaKind: item.episode?.mediaKind ?? .audio,
                        episode: item.episode
                    )
                }
            }
        }
        guard recomputeHistory else { return }
        if playbackModel.currentEpisode == nil {
            let newContinueListening = computeContinueListening()
            if newContinueListening != continueListening { continueListening = newContinueListening }
        } else {
            historyNeedsReload = true
            if continueListening != nil { continueListening = nil }
        }
    }

    // MARK: - Home/Queue/Library derived state (Phase 2, §7)
    // Cached in refreshLibrary()/recomputeDerivedState() — see the PERF FIX note
    // there. Read-only from outside; Views access these as plain stored state.

    private(set) var upNextItems: [QueueModel.ResolvedQueueItem] = []
    private(set) var upNextEpisodes: [Episode] = []
    private(set) var queueRows: [TVQueueRowModel] = []
    private(set) var continueListening: TVContinueListening?
    /// O(1) id → subscription lookup, replacing the old `librarySubscriptions
    /// .first { $0.id == id }` linear scan that subscription(id:) used to run —
    /// on its own a modest cost, but TVQueueView/TVHomeView call it once PER ROW
    /// PER RENDER, which at 113 subscriptions was a real O(rows × shows) tax on
    /// every Up Next / Latest re-render.
    private var subscriptionsByID: [UUID: AutohopCore.Subscription] = [:]
    private var lastRenderedQueueSnapshot: QueueSnapshot?
    private var uniqueEpisodesByGUID: [String: Episode] = [:]
    private var uniqueEpisodesByNormalizedTitle: [String: Episode] = [:]

    /// Reconciles queue/history records authored before a subscription was
    /// removed and re-added. Their subscription-scoped keys legitimately no
    /// longer match, while the same RSS GUID/title exists under the replacement
    /// subscription UUID. Index only globally unique values so recovery can
    /// never guess between two shows or similarly named episodes.
    private func rebuildOrphanRecoveryIndexes() {
        var guidCandidates: [String: [Episode]] = [:]
        var titleCandidates: [String: [Episode]] = [:]
        for subscription in librarySubscriptions {
            let episodes = subscription.episodes.isEmpty
                ? subscription.latestEpisode.map { [$0] } ?? []
                : subscription.episodes
            for episode in episodes where episode.playedState != .archived {
                let guid = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
                if !guid.isEmpty { guidCandidates[guid, default: []].append(episode) }
                titleCandidates[normalizedEpisodeTitle(episode.title), default: []].append(episode)
            }
        }
        uniqueEpisodesByGUID = guidCandidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
        uniqueEpisodesByNormalizedTitle = titleCandidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private func recoveredLocalEpisode(for item: QueueModel.ResolvedQueueItem) -> Episode? {
        if let marker = item.episodeKey.range(of: "|guid:") {
            let guid = String(item.episodeKey[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let episode = uniqueEpisodesByGUID[guid] { return episode }
        }
        return uniqueEpisodesByNormalizedTitle[normalizedEpisodeTitle(item.title)]
    }

    private func normalizedEpisodeTitle(_ title: String) -> String {
        TVEpisodeResolver.normalized(title)
    }

    private func normalizedPodcastIdentity(_ title: String) -> String {
        // “Windows Weekly” and “Windows Weekly (Video)” are deliberately
        // distinct. Provider suffix stripping previously allowed the wrong
        // subscription to supply playback settings and media metadata.
        TVEpisodeResolver.normalized(title)
    }

    /// Old-phone/new-TV migration fallback. Fetch only the unresolved row's
    /// podcast, at most once concurrently per subscription; never sweep the
    /// library. Version 2 projections bypass this path entirely.
    func enrichQueueRowIfNeeded(_ row: TVQueueRowModel) {
        guard let item = upNextItems.first(where: { $0.episodeKey == row.id }),
              !row.isPlayable,
              queueEnrichmentTasks[item.subscriptionID] == nil,
              !pendingQueueEnrichmentIDs.contains(item.subscriptionID),
              !failedQueueEnrichmentIDs.contains(item.subscriptionID)
        else { return }
        pendingQueueEnrichmentIDs.append(item.subscriptionID)
        pumpQueueEnrichment()
    }

    private func pumpQueueEnrichment() {
        while queueEnrichmentTasks.count < 2, !pendingQueueEnrichmentIDs.isEmpty {
            let subscriptionID = pendingQueueEnrichmentIDs.removeFirst()
            let existing = subscriptionsByID[subscriptionID]
            let kitEntry = survivalKitStore.load()?.entries.first { $0.subscriptionID == subscriptionID }
            let recoveryItem = upNextItems.first {
                $0.subscriptionID == subscriptionID && $0.episode == nil
            }
            guard recoveryItem != nil,
                  let feedURL = existing?.feedURL ?? kitEntry?.feedURL else {
                // The queue singleton commonly arrives before the larger
                // Subscription zone on first install. Absence of a feed source
                // is therefore a waiting state, not a failed request. A later
                // membership projection calls retryLegacyRowsWhoseSourcesArrived.
                AppLogger.shared.info("tv.queueEnrichmentWaitingForSource", "Legacy queue row is waiting for its subscription projection", metadata: [
                    "subscriptionID": subscriptionID.uuidString
                ], alwaysPersist: true)
                continue
            }
            queueEnrichmentTasks[subscriptionID] = Task { [weak self] in
                guard let self else { return }
                defer { self.finishQueueEnrichment(subscriptionID: subscriptionID) }
                do {
                    let parsed = try await self.episodeFeedLoader.fetch(feedURL: feedURL, limit: 50)
                    try Task.checkCancellation()
                    let unresolvedKeys = Set(self.upNextItems.filter {
                        $0.subscriptionID == subscriptionID && $0.episode == nil
                    }.map(\.episodeKey))
                    let unresolvedTitles = Dictionary(uniqueKeysWithValues: self.upNextItems.filter {
                        $0.subscriptionID == subscriptionID && $0.episode == nil
                    }.map { (self.normalizedEpisodeTitle($0.title), $0) })
                    for parsedEpisode in parsed.episodes {
                        guard let projected = parsedEpisode.projectedEpisode(
                            subscriptionID: subscriptionID,
                            feedArtworkURL: parsed.artworkURL
                        ) else { continue }
                        let key = PlaybackPositionStore.key(for: projected)
                        if unresolvedKeys.contains(key) {
                            self.legacyQueueEpisodes[key] = projected
                            self.legacyQueuePodcastTitles[key] = parsed.title
                        } else if let orphanItem = unresolvedTitles[self.normalizedEpisodeTitle(parsedEpisode.title)] {
                            // Compatibility feeds are accepted only on an exact
                            // normalized title within the explicitly identified
                            // podcast. Preserve the authoritative queue key.
                            self.legacyQueueEpisodes[orphanItem.episodeKey] = projected
                            self.legacyQueuePodcastTitles[orphanItem.episodeKey] = parsed.title
                        }
                    }
                    // Queue enrichment and Library materialisation must converge
                    // on the same phone-authored subscription identity. The old
                    // path retained only a matched episode in memory, leaving
                    // the corresponding podcast absent from Library.
                    if self.subscriptionStore.subscription(id: subscriptionID) == nil {
                        _ = self.subscriptionStore.materialize(
                            parsedFeed: parsed, feedURL: feedURL,
                            subscriptionID: subscriptionID,
                            priorityRank: kitEntry?.priorityRank
                        )
                    } else {
                        self.subscriptionStore.updateEpisodes(subscriptionID: subscriptionID, from: parsed)
                    }
                    self.failedQueueEnrichmentIDs.remove(subscriptionID)
                    self.refreshLibrary()
                    AppLogger.shared.info("tv.queueEnrichmentCompleted", "Legacy queue podcast materialized", metadata: [
                        "subscriptionID": subscriptionID.uuidString,
                        "episodes": "\(parsed.episodes.count)"
                    ], alwaysPersist: true)
                } catch {
                    let attempt = (self.queueEnrichmentAttempts[subscriptionID] ?? 0) + 1
                    self.queueEnrichmentAttempts[subscriptionID] = attempt
                    AppLogger.shared.warning("tv.queueEnrichmentFailed", "Legacy queue podcast could not be materialized", metadata: [
                        "subscriptionID": subscriptionID.uuidString,
                        "url": feedURL.absoluteString,
                        "error": String(describing: error)
                    ], alwaysPersist: true)
                    if attempt < 3 {
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(attempt == 1 ? 2 : 6))
                            guard let self, !Task.isCancelled else { return }
                            self.pendingQueueEnrichmentIDs.append(subscriptionID)
                            self.pumpQueueEnrichment()
                        }
                    } else {
                        self.failedQueueEnrichmentIDs.insert(subscriptionID)
                    }
                }
            }
        }
    }

    private func finishQueueEnrichment(subscriptionID: UUID) {
        queueEnrichmentTasks[subscriptionID] = nil
        pumpQueueEnrichment()
    }

    func queueEnrichmentFailed(for row: TVQueueRowModel) -> Bool {
        guard let item = upNextItems.first(where: { $0.episodeKey == row.id }) else { return false }
        return failedQueueEnrichmentIDs.contains(item.subscriptionID)
    }

    var unresolvedQueueDiagnostics: [String] {
        queueRows.filter { !$0.isPlayable }.map { row in
            guard let item = upNextItems.first(where: { $0.episodeKey == row.id }) else {
                return "\(row.title): projection missing"
            }
            let source = subscriptionsByID[item.subscriptionID] != nil ? "source yes" : "source no"
            let title = uniqueEpisodesByNormalizedTitle[normalizedEpisodeTitle(item.title)] != nil ? "title yes" : "title no"
            let keyKind = item.episodeKey.contains("|guid:") ? "GUID" : "legacy key"
            return "\(row.title): \(keyKind), \(source), \(title)"
        }
    }

    var pendingMaterializationDiagnostics: [String] {
        let realIDs = Set(librarySubscriptions.map(\.id))
        return (survivalKitStore.load()?.entries ?? [])
            .filter { !realIDs.contains($0.subscriptionID) }
            .map { "\($0.title): awaiting RSS details from \($0.feedURL.host ?? "unknown")" }
    }

    private func retryLegacyRowsWhoseSourcesArrived() {
        let availableIDs = Set(subscriptionsByID.keys)
        failedQueueEnrichmentIDs.subtract(availableIDs)
        for item in upNextItems where item.episode == nil {
            let canResolve = availableIDs.contains(item.subscriptionID)
                || survivalKitStore.load()?.entries.contains(where: { $0.subscriptionID == item.subscriptionID }) == true
            guard canResolve else { continue }
            failedQueueEnrichmentIDs.remove(item.subscriptionID)
            queueEnrichmentAttempts[item.subscriptionID] = 0
            if queueEnrichmentTasks[item.subscriptionID] == nil,
               !pendingQueueEnrichmentIDs.contains(item.subscriptionID) {
                pendingQueueEnrichmentIDs.append(item.subscriptionID)
            }
        }
        pumpQueueEnrichment()
    }

    func episodeRows(subscriptionID: UUID) -> [TVEpisodeRowModel] {
        episodeRowsBySubscription[subscriptionID] ?? []
    }

    /// Phase 4 bounded detail loading. The view first receives at most 25
    /// cached episodes, then one targeted conditional-cache network request.
    /// Leaving the page cancels the request; no library-wide feed sweep exists.
    func loadEpisodeDetails(subscriptionID: UUID) async {
        guard let tile = libraryTiles.first(where: { $0.id == subscriptionID }),
              !loadingEpisodeSubscriptions.contains(subscriptionID) else { return }
        loadingEpisodeSubscriptions.insert(subscriptionID)
        defer { loadingEpisodeSubscriptions.remove(subscriptionID) }
        if let cached = try? projectionStore?.loadEpisodes(subscriptionID: subscriptionID) {
            episodeRowsBySubscription[subscriptionID] = cached.episodes.map(TVEpisodeRowModel.init)
        }
        do {
            let parsed = try await episodeFeedLoader.fetch(feedURL: tile.feedURL, limit: 25)
            try Task.checkCancellation()
            subscriptionStore.updateEpisodes(subscriptionID: subscriptionID, from: parsed)
            let episodes = Array((subscriptionStore.subscription(id: subscriptionID)?.episodes ?? []).prefix(25))
            episodeRowsBySubscription[subscriptionID] = episodes.map(TVEpisodeRowModel.init)
            let projection = TVEpisodeProjection(subscriptionID: subscriptionID, episodes: episodes)
            Task.detached(priority: .utility) { [projectionStore] in
                try? projectionStore?.saveEpisodes(projection)
            }
        } catch is CancellationError {
            // Expected when focus/navigation abandons the detail screen.
        } catch {
            AppLogger.shared.warning("tv.detailLoadFailed", "Targeted episode detail load failed", metadata: [
                "subscriptionID": subscriptionID.uuidString,
                "error": String(describing: error)
            ])
        }
    }

    /// Up Next display items (2026-07-05 churn fix): renders the SYNCED QUEUE
    /// SNAPSHOT — the iPhone's authored queue order, exactly (including multiple
    /// episodes from one show, mirroring Kevin's core goal). CRUCIALLY, when a
    /// snapshot exists we render STRICTLY from it — including placeholder rows
    /// for entries whose catalog hasn't materialized yet (`episode == nil`) —
    /// and never fall back to the locally-derived Priority Stack. That fallback
    /// was the source of the ~10-min "old episodes appearing and disappearing"
    /// churn on a cold sync: it showed locally-derived episodes (wrong/already
    /// finished on the phone) until every catalog trickled in. Rendering from
    /// the snapshot's own entries makes Up Next correct and STABLE the moment
    /// the snapshot lands; placeholder rows fill in artwork/duration + become
    /// playable as their subscription materializes. The Priority Stack fallback
    /// is used ONLY when there is genuinely no synced snapshot (fresh install
    /// with sync still cold, or sync disabled — T7's standalone mode).
    private func computeUpNextItems() -> [QueueModel.ResolvedQueueItem] {
        if let snapshot = subscriptionStore.syncedQueueSnapshot(), !snapshot.entries.isEmpty {
            Task.detached(priority: .utility) { [projectionStore] in
                try? projectionStore?.saveQueue(snapshot)
            }
            let items = QueueModel.resolvedQueueItems(from: snapshot, subscriptions: librarySubscriptions)
            AppLogger.shared.info("tv.queueProjection", "Queue projection rendered", metadata: [
                "schema": "\(snapshot.schemaVersion)",
                "generation": "\(snapshot.generation)",
                "epoch": snapshot.authorityEpoch,
                "entries": "\(snapshot.entries.count)",
                "unresolved": "\(items.filter { $0.episode == nil }.count)",
                "ageSeconds": "\(Int(Date().timeIntervalSince(snapshot.updatedAt)))"
            ], alwaysPersist: true)
            return items
        }
        if let cached = try? projectionStore?.loadQueue(), !cached.entries.isEmpty {
            return QueueModel.resolvedQueueItems(from: cached, subscriptions: librarySubscriptions)
        }
        return QueueModel.streamableQueue(from: librarySubscriptions).map { episode in
            QueueModel.ResolvedQueueItem(
                episodeKey: PlaybackPositionStore.key(for: episode),
                title: episode.title,
                subscriptionID: episode.subscriptionID,
                episode: episode
            )
        }
    }

    /// Continue Listening, driven by SYNCED LISTENING HISTORY — REWORKED
    /// 2026-07-11 (Kevin's real-device round 5: the hero showed a MONTH-OLD
    /// stale episode for ~30 s, then vanished, and NEVER showed the episode he
    /// was actually mid-way through on the phone). Two root causes, both fixed:
    /// 1. The old code required the history entry to resolve to a LOCAL episode
    ///    (episodeMatching) before showing anything. On a cold/behind TV the
    ///    phone's current episode often isn't materialized yet (or has aged out
    ///    of the 50-episode feed window), so the correct entry was silently
    ///    discarded. Now the hero renders from the ENTRY ITSELF — it carries
    ///    denormalized episodeTitle/podcastTitle/artworkURL/duration/position,
    ///    everything the card needs — same "render the synced truth, placeholder
    ///    until the catalog lands" pattern as the queue-snapshot churn fix
    ///    (SYNC_DESIGN.md). `episode` is nil until materialization; the card is
    ///    non-playable (no Resume affordance) exactly until then.
    /// 2. The `playedState == .playing` local-heuristic FALLBACK was what
    ///    surfaced the month-old episode (any stale .playing state, no real
    ///    recency) before history synced, then disappeared when sync marked it
    ///    played. Deleted outright: no history entry → no hero. Showing nothing
    ///    briefly is correct; showing the wrong episode is not.
    /// HISTORY-READ CACHE (2026-07-11, round-8 watchdog finding): the ~290 ms
    /// refreshLibrary passes were dominated by mostRecentInProgressListeningEntry,
    /// which decodes the ENTIRE synced history table on every call. The winning
    /// entry only changes when history actually changes, so it's cached and
    /// re-read only after a history invalidation (onRemoteHistoryChanged /
    /// store-change sink set `historyNeedsReload`). Episode resolution stays
    /// per-call — it's a cheap dictionary lookup and must re-run as catalogs
    /// materialize.
    private var historyNeedsReload = true
    private var cachedContinueEntry: ListeningHistoryEntry?

    private func computeContinueListening() -> TVContinueListening? {
        if historyNeedsReload {
            historyNeedsReload = false
            cachedContinueEntry = subscriptionStore.mostRecentInProgressListeningEntry()
        }
        guard let entry = cachedContinueEntry else { return nil }
        return TVContinueListening(entry: entry, episode: episodeResolver.resolveEpisode(from: entry))
    }

    /// One compatibility boundary for queue/history/catalog identity. Keeping
    /// its inputs explicit makes the extraction from TVAppModel incremental:
    /// this resolver can move behind a repository later without changing the
    /// already-tested matching rules.
    private var episodeResolver: TVEpisodeResolver {
        TVEpisodeResolver(context: .init(
            subscriptions: librarySubscriptions,
            subscriptionsByID: subscriptionsByID,
            queueItems: upNextItems,
            legacyQueueEpisodes: legacyQueueEpisodes,
            uniqueEpisodesByGUID: uniqueEpisodesByGUID,
            uniqueEpisodesByNormalizedTitle: uniqueEpisodesByNormalizedTitle
        ))
    }

    /// Resolves an episode's owning subscription (for podcast title display).
    /// `AutohopCore.Subscription` qualified — see this file's top note on the
    /// Combine `Subscription` protocol collision.
    func subscription(for episode: Episode) -> AutohopCore.Subscription? {
        subscription(id: episode.subscriptionID)
    }

    /// Resolves a subscription by id — O(1) via subscriptionsByID (see PERF FIX
    /// above), never a stale snapshot since it's rebuilt every refreshLibrary().
    func subscription(id: UUID) -> AutohopCore.Subscription? {
        subscriptionsByID[id]
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

// MARK: - Root state machine UI (Phase 1 placeholder)

struct TVRootView: View {
    let model: TVAppModel

    var body: some View {
        switch model.rootState {
        case .loading:
            // Animated Autohop splash (2026-07-11, Kevin's request) — TV port
            // of the iPhone's LaunchLoadingView, with the rotating first-sync
            // status text underneath (TV/Views/TVLaunchLoadingView.swift).
            TVLaunchLoadingView(statusText: model.statusText)
        case .empty:
            // Not a dead end: observeStoreForKitWrites's debounced sink keeps
            // watching in the background and flips to `.ready` automatically
            // the moment CloudKit delivers something, even while this screen
            // is showing — the small spinner reflects that it's still
            // listening, not stuck.
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("No library yet", systemImage: "square.stack")
                } description: {
                    Text("Subscribe to podcasts in Autohop on your iPhone and turn on iCloud Sync in Settings → Sync. Your library appears here automatically — this can take several minutes on a fresh install.")
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Still listening for iCloud updates…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .ready:
            TVMainTabView(model: model)
        }
    }
}
