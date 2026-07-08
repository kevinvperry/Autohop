import SwiftUI
import Combine
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
// PHASE 2 (§7): upNextEpisodes / latestEpisodes / continueListeningEpisode are
// derived from that mirror on each access — cheap at real-library scale
// (dozens of subscriptions), unlike the iPhone's cachedDownloadedQueue
// memoization concern at hundreds. Revisit if a TV library ever grows large
// enough to matter. subscription(for:)/subscription(id:) resolve live rather
// than caching a stale snapshot per episode/id.

@main
struct AutohopTVApp: App {
    @State private var model = TVAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVRootView(model: model)
                .preferredColorScheme(.dark)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
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
    /// Observation-tracked mirror of the store's real (non-browse) library,
    /// priority order. TV views read THIS, never the store directly.
    // `AutohopCore.Subscription` qualified — Combine also declares a
    // `Subscription` protocol, and both are visible here (this file imports
    // Combine for AnyCancellable/debounce), which is otherwise ambiguous.
    private(set) var librarySubscriptions: [AutohopCore.Subscription] = []

    let subscriptionStore: SubscriptionStore
    /// Phase 3 (§8): the tvOS playback composition. Its upNextProvider/
    /// subscriptionProvider closures are wired below, AFTER subscriptionStore
    /// exists, avoiding an init-order back-reference to `self`.
    let playbackModel: TVPlaybackModel
    private let survivalKitStore = SurvivalKitStore()
    private var cloudSyncEngine: CloudSyncEngine?
    private var cancellables = Set<AnyCancellable>()
    private var didBootstrap = false

    init() {
        // T2: the database is a rebuildable cache — it belongs in Caches so the
        // system may purge it; durable truth is the survival kit + CloudKit.
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let databaseDirectory = cachesDirectory?.appendingPathComponent("Autohop", isDirectory: true)
        if let databaseDirectory {
            try? FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        }
        let store = SubscriptionStore(
            fileURL: nil,
            databasePath: databaseDirectory?.appendingPathComponent("autohop-tv.sqlite").path
        )
        subscriptionStore = store
        playbackModel = TVPlaybackModel(subscriptionStore: store)

        playbackModel.upNextProvider = { [weak self] in self?.upNextEpisodes ?? [] }
        playbackModel.subscriptionProvider = { [weak self] id in self?.subscription(id: id) }
        // Force-push a just-written position immediately (pause / player exit),
        // so a TV-side pause reaches the phone in seconds instead of waiting out
        // the engine's ~60 s slow-lane debounce.
        playbackModel.onPlaybackCheckpoint = { [weak self] in
            self?.cloudSyncEngine?.flushDeferredPushes(reason: "tv.playbackCheckpoint")
        }
    }

    /// Called when the TV app backgrounds/resigns active: persist the current
    /// position and force-push it, mirroring the iPhone's scene-background flush.
    func handleBackgrounded() {
        playbackModel.checkpoint()
    }

    /// Starts playback of an episode, resolving its owning subscription for
    /// playback preference/chapter filter/history metadata. No-op if the
    /// subscription can no longer be resolved (e.g. unsubscribed elsewhere).
    func beginPlayback(_ episode: Episode) {
        guard let subscription = subscription(for: episode) else { return }
        Task { await playbackModel.play(episode: episode, subscription: subscription) }
    }

    /// Subscribes to a podcast found via TV Search (§9 item 1). Fetches the
    /// full feed, adds it as a new subscription (mints a fresh id — this is
    /// not a rebuild), and refreshes immediately for snappy UI feedback.
    /// T7: this always writes to the local store + survival kit regardless of
    /// whether iCloud sync is working, so subscribing on TV never depends on
    /// or blocks behind sync — CloudSyncEngine picks the change up if/when it
    /// can, and the survival kit alone is enough to survive a purge.
    func subscribe(to result: PodcastSearchResult) async throws {
        let feed = try await EpisodeFeedLoader().fetch(feedURL: result.feedURL)
        _ = try subscriptionStore.add(parsedFeed: feed, feedURL: result.feedURL)
        refreshLibrary()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        if let kit = survivalKitStore.load() {
            await rebuildMissingSubscriptions(from: kit)
        }
        startCloudSync()
        observeStoreForKitWrites()

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
        guard rootState != .ready else { return }

        // BUG FIXED HERE (found via Kevin's real Apple TV, 2026-07-04): the
        // refreshLibrary() call above already flips rootState to `.empty`
        // when there's nothing yet — so the OLD code's follow-up 6 s wait
        // (with a statusText update) was invisible: the screen had ALREADY
        // switched to the static "No Library Yet" view before the wait even
        // started. A first-ever CloudKit sync legitimately does a full
        // historical fetch of the whole private zone (no prior change
        // token) and can take MINUTES — Kevin's cold start took ~4 min, and
        // that speed is Apple's infrastructure, not something we control.
        // So: explicitly stay in `.loading` (spinner + rotating reassuring
        // text) for a long grace window instead. `observeStoreForKitWrites`'s
        // debounced sink calls refreshLibrary() independently the instant
        // CloudKit actually delivers something, flipping rootState to
        // `.ready` — the wait loop below just checks for that and exits
        // early; it isn't what makes sync succeed, only what's on screen
        // while waiting.
        rootState = .loading
        await waitForFirstSyncWithAnimatedStatus()
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

    /// Up to ~5 minutes (one full pass of the 42 messages), rotating status
    /// text every 7 s, exiting immediately once `observeStoreForKitWrites`'s
    /// debounced sink resolves `rootState` to `.ready` on its own.
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
            await materializeFeed(
                url: entry.feedURL,
                subscriptionID: entry.subscriptionID,
                priorityRank: entry.priorityRank
            )
        }
    }

    /// Fetch + parse a feed and recreate its subscription with a PRESERVED id.
    /// Failures are logged and skipped — sync retries materialization later,
    /// and the kit entry remains for the next launch.
    private func materializeFeed(url: URL, subscriptionID: UUID, priorityRank: Int?) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = try RSSParser().parse(data: data, maxEpisodes: 50)
            subscriptionStore.materialize(
                parsedFeed: parsed,
                feedURL: url,
                subscriptionID: subscriptionID,
                priorityRank: priorityRank
            )
        } catch {
            AppLogger.shared.warning("tv.materializeFailed", "Could not fetch a feed during TV bootstrap", metadata: [
                "url": url.absoluteString,
                "error": String(describing: error)
            ])
        }
    }

    // MARK: - Sync

    private func startCloudSync() {
        let engine = CloudSyncEngine(
            containerIdentifier: "iCloud.com.kevinperry.autohop",
            subscriptionStore: subscriptionStore
        )
        engine.onSubscriptionNeedsMaterialization = { [weak self] state in
            await self?.materializeRemoteSubscription(state)
        }
        // Notify-only (persistence happens in the engine): re-render Up Next
        // the moment a newer phone-authored queue snapshot lands.
        engine.onRemoteQueueSnapshotChanged = { [weak self] in
            await self?.refreshLibrary()
        }
        // Notify-only: re-render Home when a listening-history entry lands, so
        // Continue Watching populates the moment the paused-on-iPhone episode's
        // resume position syncs (it's read from the DB, not Observation-tracked).
        engine.onRemoteHistoryChanged = { [weak self] in
            await self?.refreshLibrary()
        }
        cloudSyncEngine = engine
        engine.start()
    }

    private func materializeRemoteSubscription(_ state: SubscriptionSyncState) async {
        await materializeFeed(url: state.feedURL, subscriptionID: state.subscriptionID, priorityRank: nil)
        subscriptionStore.applyRemoteSubscriptionState(state)
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
            await engine.fetchAllSubscriptionsNow(reason: reason)
            _ = await engine.fetchQueueSnapshotNow(reason: reason)
            // Pull listening history too, so Continue Watching (the paused-on-
            // iPhone episode) appears fast instead of waiting on the slow lane.
            await engine.fetchAllHistoryNow(reason: reason)
            refreshLibrary()
            // Then bring each feed's episodes up to date (see refreshFeeds).
            await refreshFeeds(reason: reason)
            return
        }
    }

    /// Re-fetches each subscription's feed and merges the latest episodes, so
    /// "Latest" and the episode lists match the phone. The TV otherwise only
    /// fetches a feed at materialize time and never refreshes, leaving those
    /// surfaces frozen at first-sighting. Sequential + best-effort: a failed
    /// feed is skipped (the next launch/foreground retries), and the merge
    /// preserves local + synced played/download state by guid. Runs in the
    /// background after the cloud prime so it never blocks launch.
    func refreshFeeds(reason: String) async {
        let feeds = subscriptionStore.subscriptions
            .filter { $0.browseDate == nil }
            .map { ($0.id, $0.feedURL) }
        for (subscriptionID, feedURL) in feeds {
            guard let parsed = try? await EpisodeFeedLoader().fetch(feedURL: feedURL) else { continue }
            subscriptionStore.updateEpisodes(subscriptionID: subscriptionID, from: parsed)
        }
        refreshLibrary()
    }

    // MARK: - Library state + kit write-back

    private func observeStoreForKitWrites() {
        subscriptionStore.objectWillChange
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.survivalKitStore.save(SubscriptionSurvivalKit.capture(
                    from: self.subscriptionStore.subscriptions,
                    iCloudSyncEnabled: true
                ))
                self.refreshLibrary()
            }
            .store(in: &cancellables)
    }

    private func refreshLibrary() {
        librarySubscriptions = subscriptionStore.subscriptions
            .filter { $0.browseDate == nil }
            .sorted { $0.priorityRank < $1.priorityRank }
        rootState = librarySubscriptions.isEmpty ? .empty : .ready

        // Pre-buffer the Continue Listening episode (the one most likely to be
        // played next) so resuming it starts near-instantly. Idempotent per
        // URL — a matching in-flight preload is left untouched. Skipped while
        // something is already playing.
        if playbackModel.currentEpisode == nil, let resume = continueListening?.episode {
            playbackModel.preload(episode: resume)
        }
    }

    // MARK: - Home/Queue/Library derived state (Phase 2, §7)

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
    var upNextItems: [QueueModel.ResolvedQueueItem] {
        if let snapshot = subscriptionStore.syncedQueueSnapshot(), !snapshot.entries.isEmpty {
            return QueueModel.resolvedQueueItems(from: snapshot, subscriptions: librarySubscriptions)
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

    /// Playable Up Next episodes (resolved only) — for auto-advance on finish.
    /// Placeholder (not-yet-materialized) items are excluded since they can't
    /// be played until their catalog lands.
    var upNextEpisodes: [Episode] { upNextItems.compactMap(\.episode) }

    /// Newest episode per subscription, newest-published first. Uses `newestEpisode`
    /// (derived from the episode list) rather than the denormalised `latestEpisode`,
    /// which can drift behind and surface a stale episode — matches the iOS fix.
    var latestEpisodes: [Episode] {
        librarySubscriptions
            .compactMap(\.newestEpisode)
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Continue Listening, driven by SYNCED LISTENING HISTORY (fix 2026-07-04;
    /// previously used the `playedState == .playing` heuristic, which had no
    /// reliable recency — see SubscriptionStore.mostRecentInProgressListeningEntry's
    /// header — and therefore surfaced the wrong episode when several shows
    /// were mid-progress across devices). The history entry carries the true
    /// most-recently-listened episode from ANY device plus its resume
    /// position (used for the hero card's progress bar). Falls back to the
    /// old playedState heuristic only when no usable history entry resolves
    /// to a local episode (e.g. history hasn't synced yet on a fresh install).
    /// REACTIVITY NOTE: history rows are read straight from the sync database
    /// (not Observation-tracked), so this refreshes when the tracked
    /// `librarySubscriptions` mirror next changes — which any sync activity,
    /// playback start, or tab re-render triggers — rather than the instant a
    /// lone history record lands. Acceptable staleness (seconds-to-a-refresh),
    /// noted so nobody "fixes" the fallback ordering chasing it.
    var continueListening: (episode: Episode, positionSeconds: TimeInterval)? {
        if let entry = subscriptionStore.mostRecentInProgressListeningEntry(),
           let episode = episodeMatching(historyEntry: entry) {
            return (episode, entry.lastPositionSeconds)
        }
        // Fallback: synced playedState (recency via lastPlayedAt — stamped on
        // play start since the 2026-07-04 markEpisodePlaying fix).
        if let playing = librarySubscriptions
            .flatMap(\.episodes)
            .filter({ $0.playedState == .playing })
            .max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }) {
            return (playing, 0)
        }
        return nil
    }

    /// Resolves a history entry to its local episode. Primary match: the
    /// stable subscription-scoped key (identical derivation on both devices —
    /// PlaybackPositionStore.key == the entry id). Fallback: episodeID, for
    /// entries written by a device sharing our local UUIDs.
    private func episodeMatching(historyEntry entry: ListeningHistoryEntry) -> Episode? {
        guard let subscription = subscription(id: entry.subscriptionID) else { return nil }
        return subscription.episodes.first { PlaybackPositionStore.key(for: $0) == entry.id }
            ?? subscription.episodes.first { $0.id == entry.episodeID }
    }

    /// Resolves an episode's owning subscription (for podcast title display).
    /// `AutohopCore.Subscription` qualified — see this file's top note on the
    /// Combine `Subscription` protocol collision.
    func subscription(for episode: Episode) -> AutohopCore.Subscription? {
        subscription(id: episode.subscriptionID)
    }

    /// Resolves a subscription by id from the live library mirror (never a
    /// stale snapshot — used by pushed detail pages).
    func subscription(id: UUID) -> AutohopCore.Subscription? {
        librarySubscriptions.first { $0.id == id }
    }
}

// MARK: - Root state machine UI (Phase 1 placeholder)

struct TVRootView: View {
    let model: TVAppModel

    var body: some View {
        switch model.rootState {
        case .loading:
            VStack(spacing: 20) {
                ProgressView()
                Text(model.statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
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
