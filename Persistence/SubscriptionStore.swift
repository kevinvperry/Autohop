import Combine
import Foundation

// AI CONTEXT — Persistence/SubscriptionStore.swift
// The single persistent store for ALL subscription + episode data. The current
// app store is Application Support/Autohop/autohop.sqlite; legacy JSON at
// subscriptions.json is imported once. The SQLite directory/store is marked
// available-after-first-unlock so CarPlay can read downloadedQueue and persist
// archive/play-next changes while locked. Saves are coalesced on a utility queue
// so a 70-feed refresh cycle produces one disk write. @MainActor: all mutation
// happens on the main actor and views observe `subscriptions` through AppState's
// subscriptionStore.objectWillChange bridge. The array is not @Published on
// purpose: save() is the single publisher, which lets refresh-stat-only writes
// persist quietly without waking UI/sync. begin/endChangeNotificationCoalescing
// lets CloudSyncEngine apply a fetched-changes burst with ONE objectWillChange at
// the end instead of one per record (post-launch sync bursts were a main-thread
// hang source); disk persistence is unaffected.
// DECOMPOSITION STAGES 4–5: queueDidChange fingerprints only fields capable of
// changing the downloaded Priority Stack; membershipDidChange fingerprints
// subscription identity/browse status. QueueCoordinator and
// OnboardingCoordinator observe these narrow streams instead of using broad
// objectWillChange for domain work. Keep signatures free of display-only fields.
// WIDGET STAGE 2: presentationDidChange is a third narrow stream for
// display-only projections whose queue identity is unchanged (title, artwork,
// duration, media/explicit metadata). WidgetSnapshotCoordinator observes it so
// the extension never subscribes to raw objectWillChange. Its signature is
// limited to playable downloaded episode presentation, not settings/stats.
// RESPONSIBILITIES beyond CRUD: episode merge on feed refresh (match by guid,
// preserving local fields like downloadState/playedState/localFileURL/
// wasCompleted/downloadedAt — the merge also reconstructs wasCompleted from
// playedEpisodeKeys when a finished episode was archived between refreshes),
// feed metadata maintenance (updateAuthor / updateArtworkURL are used by
// AppState.refreshSubscription so show art and author changes from RSS refreshes
// reach every cached-artwork call site),
// Release Radar history seeding for newly added subscriptions
// (seedReleaseObservations records initial ParsedFeed episodes into
// RefreshStats.releaseObservations so the learned scheduler starts with the
// feed's current RSS publish-date evidence),
// priorityRank normalization (contiguous 1..n after any insert/move/delete).
// Reorder sessions are ID-based: the SwiftUI draft contains ONLY active real
// subscriptions, Inactive rows are fixed at the bottom, browse previews never
// enter the drag index space, and one validated commit authors one atomic
// SubscriptionOrder generation. Remote order changes are deferred while the
// user is dragging. Persistence retries failed terminal writes with bounded
// backoff, while lifecycle/Done callers can force `flushPendingSaves()`.
// browse-subscription lifecycle (creation on preview, 30-day expiry purge,
// activation on subscribe), and ParsedFeed → Episode conversion.
// Remote episode sync applies by subscription-scoped sync key and protects the
// currently loaded player episode (active-player-wins); refresh-stat-only writes
// deliberately persist without publishing so they do not wake views or sync.
// Remote subscription recovery can restore per-podcast settings from legacy
// unprefixed CloudKit SubscriptionState records left by the namespace migration;
// it never creates/removes subscriptions and always marks the repaired state for
// a full namespaced re-upload. Inactive podcasts (`excludeFromAutoFeedRefresh`)
// remain real subscriptions: they move to the bottom, keep a hidden return rank,
// and later restore that rank instead of using the browse-preview activation path.
// DownloadFilterSettings is persisted on the local Subscription payload and
// updated via updateDownloadFilterSettings; it is intentionally not projected
// into SubscriptionSyncState for v1, so filters are backup/local-only.
// GOTCHA: accessors generally distinguish real subscriptions (browseDate == nil)
// from browse ones; queue/UI may still include Inactive real subscriptions, but
// automatic/feed-all refresh must skip `excludeFromAutoFeedRefresh`.
// FEED MERGE PERFORMANCE: refresh metadata setters and updateEpisodes are
// equality-guarded. FeedRefreshItemWorkflow wraps the related calls in one
// change-notification transaction, so a conditional 200 response whose content
// is semantically unchanged performs comparison work but authors no persistence,
// narrow-domain invalidation, broad objectWillChange, queue projection, or sync
// work. Do not remove these guards: unchanged feeds are the dominant refresh case.
// DOWNLOAD TIMESTAMPS: markEpisodeDownloaded sets Episode.downloadedAt to now
// if not already set (preserves the original date on re-download). This is the
// clock used by Auto Archive "After Inactive" — do not clear downloadedAt when
// a file is deleted or an episode is re-queued; it records first arrival only.
@MainActor
public final class SubscriptionStore: ObservableObject {
    public private(set) var subscriptions: [Subscription] = []
    /// Stage 4 narrow invalidation stream. QueueCoordinator observes this
    /// instead of broad objectWillChange, so metadata/settings-only saves cannot
    /// trigger queue recomputation or QueueSnapshot publication.
    public let queueDidChange = PassthroughSubject<Void, Never>()
    /// Stage 5 narrow membership stream. OnboardingCoordinator observes only
    /// real/browse subscription membership changes, never episode merges.
    public let membershipDidChange = PassthroughSubject<Void, Never>()
    /// Narrow display invalidation for downloaded episode projections. This is
    /// intentionally distinct from queue identity/order and broad UI changes.
    public let presentationDidChange = PassthroughSubject<Void, Never>()
    private var lastQueueAffectingSignature: [String] = []
    private var lastMembershipSignature: [String] = []
    private var lastPresentationSignature: [String] = []
    /// Record store. Exposed within the module so CloudSyncEngine can read
    /// pending sync-state and cached CKRecord system fields.
    let database: AutohopDatabase?
    /// Legacy JSON file — used only for the one-time import into GRDB, then
    /// renamed to `*.migrated`. nil once migrated or when no legacy file exists.
    private let legacyFileURL: URL?
    private static let saveQueue = DispatchQueue(label: "com.autohop.subscriptionStore.save", qos: .utility)
    // Coalesces rapid save() calls (e.g. during a 70-feed refresh cycle) into one disk write.
    private var pendingSave = false
    private var saveCoalesced = false
    private var coalescedSaveAuthorsSubscriptionOrder = false
    private var lastFailedSaveAuthorsSubscriptionOrder = true
    private var persistenceRetryTask: Task<Void, Never>?
    private var persistenceRetryAttempt = 0
    private let maximumPersistenceRetryAttempts = 4
    public private(set) var lastPersistenceErrorDescription: String?
    /// Snapshot of what last reached disk, keyed by id, so save() writes only
    /// the rows that actually changed.
    private var persistedSnapshot: [UUID: Subscription] = [:]
    /// Returns the subscription-scoped sync key of the episode loaded in the
    /// player on this device, so a remote played/archived change can't interrupt
    /// it (active-player-wins).
    /// Installed by SyncCoordinator; nil when nothing is loaded.
    public var nowPlayingEpisodeSyncKeyProvider: (() -> String?)?

    /// Supplies the global default PlaybackPreference (from AppSettings). Used to
    /// seed a subscription's own playbackPreference at the moment it becomes a
    /// real subscription. Installed by SettingsViewModel; falls back to
    /// `.default` when nil.
    /// Browse-only (preview) subscriptions resolve their preference live through
    /// PlaybackPreferenceWorkflow.effectivePreference(for:), so seeding only matters once a feed is
    /// actually subscribed to — after which the snapshot is independent.
    public var defaultPlaybackPreferenceProvider: (() -> PlaybackPreference)?

    /// Supplies the global default AutoArchiveSettings (from AppSettings). Applied
    /// to each new subscription at subscribe time. Installed by
    /// SettingsViewModel; falls back to `.default` when nil. Never applied to
    /// existing subscriptions.
    public var defaultAutoArchiveSettingsProvider: (() -> AutoArchiveSettings)?

    /// Requests deletion of an episode's downloaded media file. Installed by
    /// DownloadCoordinator to call DownloadManager.deleteLocalFile(for:) — the store can't reach the
    /// DownloadManager directly. Invoked when a remote played/archived state merges
    /// in (applyRemoteEpisodeState) and this device still holds the download, so a
    /// cross-device archive doesn't leave an orphaned file (ASSESSMENT.md B1). The
    /// episode handed in still has its localFileURL/localFileName populated so the
    /// file can be located before those fields are cleared.
    public var onEpisodeFileShouldDelete: ((Episode) -> Void)?

    // MARK: Priority reorder session

    private var priorityReorderSessionInitialIDs: [UUID]?
    private var deferredRemoteSubscriptionOrder: SubscriptionOrderState?
    private var deferredLegacyPriorityRanks = false

    private var seededDefaultPlaybackPreference: PlaybackPreference {
        defaultPlaybackPreferenceProvider?() ?? .default
    }

    private var seededDefaultAutoArchiveSettings: AutoArchiveSettings {
        defaultAutoArchiveSettingsProvider?() ?? .default
    }

    /// - Parameter fileURL: legacy JSON location (defaults to the historical
    ///   subscriptions.json path). Kept as a parameter so existing callers are
    ///   unchanged; it now seeds the one-time GRDB import.
    /// - Parameter databasePath: SQLite file location. Defaults to the app's
    ///   Application Support directory.
    public init(fileURL: URL? = nil, databasePath: String? = nil) {
        self.legacyFileURL = fileURL ?? Self.defaultLegacyFileURL()
        // When an explicit fileURL is given (tests/CLI), keep the SQLite file
        // beside it so each location stays isolated and a reload finds the same
        // database. The app uses the default paths.
        let resolvedPath = databasePath
            ?? fileURL.map { Self.databasePath(besideLegacyFile: $0) }
            ?? Self.defaultDatabasePath()
        self.database = try? AutohopDatabase(path: resolvedPath)
        load()
        seedDomainChangeSignatures()
    }

    /// DEFERRED-LOAD variant (2026-07-11, tvOS launch-freeze fix): opens the
    /// database but does NOT decode the library — the caller must await
    /// `completeDeferredLoad()` before reading `subscriptions`. Added because
    /// the synchronous `load()` decode of a large library (113 shows × 50
    /// episode payloads) blocks the main actor for seconds, which on the TV
    /// froze the launch splash into a static image and stalled remote
    /// navigation right after launch. iOS keeps using the synchronous init
    /// above (its launch sequencing depends on the store being ready
    /// immediately after construction).
    public init(deferredLoadDatabasePath: String?) {
        self.legacyFileURL = nil
        self.database = try? AutohopDatabase(path: deferredLoadDatabasePath ?? Self.defaultDatabasePath())
    }

    /// Finishes a deferred-load init: the row fetch + payload decode (the
    /// expensive part) runs OFF the main actor — AutohopDatabase is
    /// thread-safe by design (CloudSyncEngine already reads it off-main) —
    /// and only the cheap array assignment/sort happens back here. Safe to
    /// call once, before anything reads `subscriptions`.
    public func completeDeferredLoad() async {
        guard let database else { return }
        // The legacy-JSON import path only applies to iOS (TV never had a
        // subscriptions.json); with a nil legacyFileURL decodeLegacyFileIfPresent
        // is a no-op, so plain load() semantics reduce to the DB branch below.
        let loaded = await Task.detached(priority: .userInitiated) { [database] in
            guard let rows = try? database.loadSubscriptions() else { return nil as [Subscription]? }
            // The projection-heal pass also reads/decodes sync rows — keep it
            // off-main with the load (2026-07-11, TV launch-hang follow-up).
            try? database.reseedUndecodableSyncState(for: rows)
            return rows
        }.value
        guard let loaded else {
            subscriptions = []
            persistedSnapshot = [:]
            return
        }
        subscriptions = loaded.sorted { $0.priorityRank < $1.priorityRank }
        // Non-destructive resort — same reasoning as load()'s note.
        resortByCurrentPriorityRank()
        persistedSnapshot = snapshotByID(subscriptions)
        seedDomainChangeSignatures()
    }

    /// Test seam: a store backed entirely by an in-memory database (no disk).
    public static func inMemory() -> SubscriptionStore {
        SubscriptionStore(inMemoryDatabase: try? AutohopDatabase())
    }

    private init(inMemoryDatabase: AutohopDatabase?) {
        self.legacyFileURL = nil
        self.database = inMemoryDatabase
        load()
        seedDomainChangeSignatures()
    }

    // MARK: - Add

    public func add(parsedFeed: ParsedFeed, feedURL: URL) throws -> Subscription {
        guard !subscriptions.contains(where: { $0.feedURL == feedURL }) else {
            throw SubscriptionStoreError.duplicateFeed
        }

        let subscriptionID = UUID()

        var subscription = Subscription(
            id: subscriptionID,
            feedURL: feedURL,
            title: parsedFeed.title,
            author: parsedFeed.author,
            artworkURL: parsedFeed.artworkURL,
            priorityRank: 0,
            categories: parsedFeed.categories,
            isExplicit: parsedFeed.isExplicit
        )
        subscription.description = parsedFeed.description
        subscription.subscribedAt = Date()
        subscription.playbackPreference = seededDefaultPlaybackPreference
        subscription.autoArchiveSettings = seededDefaultAutoArchiveSettings

        let episodes = parsedFeed.episodes.compactMap {
            episode(from: $0, subscriptionID: subscriptionID, feedArtworkURL: parsedFeed.artworkURL)
        }

        if !episodes.isEmpty {
            subscription.latestEpisode = episodes.first
            subscription.episodes = episodes
            seedReleaseObservations(for: &subscription, episodes: episodes)
        }

        subscriptions.insert(subscription, at: 0)
        normalizePriorityOrder()
        save()
        return subscription
    }

    /// Recreates a subscription with a FIXED identity from a fresh feed fetch —
    /// the tvOS purge-resilient bootstrap (proposal T2/§6) and the TV remote-
    /// materialization path. Preserving `subscriptionID` is what lets synced
    /// CloudKit records (EpisodeState/SubscriptionState, keyed by that UUID)
    /// apply to the rebuilt rows; `add(parsedFeed:)` above deliberately mints a
    /// NEW id and must not be used for rebuilds. Appends at the bottom; pass
    /// `priorityRank` (e.g. from the survival kit) to restore ordering — ranks
    /// are re-normalized after all rebuilds by the caller sorting its inserts.
    /// No-op (returns the existing value) when the id is already present.
    @discardableResult
    public func materialize(
        parsedFeed: ParsedFeed,
        feedURL: URL,
        subscriptionID: UUID,
        priorityRank: Int? = nil
    ) -> Subscription {
        if let existing = subscriptions.first(where: { $0.id == subscriptionID }) {
            return existing
        }

        // Placeholder uses max+1 (not count+1): guarantees it sorts AFTER every
        // existing rank, however large, so a brand-new arrival never lands
        // ahead of an already-correct synced rank before its OWN true rank is
        // applied moments later by the caller's follow-up
        // applyRemoteSubscriptionState call. See resortByCurrentPriorityRank's
        // header for the full bug this — and the non-destructive resort below
        // — fixes.
        let placeholderRank = priorityRank ?? ((subscriptions.map(\.priorityRank).max() ?? 0) + 1)
        var subscription = Subscription(
            id: subscriptionID,
            feedURL: feedURL,
            title: parsedFeed.title,
            author: parsedFeed.author,
            artworkURL: parsedFeed.artworkURL,
            priorityRank: placeholderRank,
            categories: parsedFeed.categories,
            isExplicit: parsedFeed.isExplicit
        )
        subscription.description = parsedFeed.description
        subscription.subscribedAt = Date()
        subscription.playbackPreference = seededDefaultPlaybackPreference
        subscription.autoArchiveSettings = seededDefaultAutoArchiveSettings

        // DATA-INTEGRITY FIX (2026-07-05, found via tvOS real-device testing):
        // when a remote subscription is materialised (TV/rebuild path), the
        // engine has already adopted a CLEAN remote sync projection carrying the
        // user's real settings (playback speed, auto-archive, chapter/download
        // filters, notifications). If we seed DEFAULTS here, the subsequent
        // save() → recordSubscriptionSyncState re-applies those defaults over the
        // clean projection, marking each field dirty at `now`; field-level LWW
        // then lets those fresh-default timestamps BEAT the phone's older real
        // values and pushes them back — silently clobbering the phone's settings
        // ("loading older info in the TV app damages newer info on the phone").
        // Adopting the projection's settings up front means the projection stays
        // clean → nothing is pushed → the phone is preserved, and the TV shows
        // the correct settings immediately instead of defaults. We adopt EVERY
        // synced field (not just the user-tuned settings) so recordSubscriptionSyncState's
        // apply() sees no change at all and leaves hasPendingChanges false —
        // otherwise the placeholder priorityRank / feed-derived title would
        // re-dirty the projection and push those over the phone's synced values.
        if let projection = try? database?.subscriptionSyncState(id: subscriptionID) {
            subscription.title = projection.title
            subscription.priorityRank = projection.priorityRank
            subscription.notificationsEnabled = projection.notificationsEnabled
            subscription.excludeFromAutoFeedRefresh = projection.excludeFromAutoFeedRefresh
            subscription.autoFeedRefreshReturnPriorityRank = projection.autoFeedRefreshReturnPriorityRank
            subscription.playbackPreference = projection.playbackPreference
            subscription.autoArchiveSettings = projection.autoArchiveSettings
            subscription.chapterFilter = projection.chapterFilter
            subscription.downloadFilterSettings = projection.downloadFilterSettings
        } else {
            // SECOND DATA-INTEGRITY FIX, SAME BUG CLASS (2026-07-11, found via
            // real cross-device damage on Kevin's iPhone): the adopt branch
            // above only protects materialisations that happen AFTER the synced
            // projection landed locally. The survival-kit PURGE REBUILD runs
            // against a freshly-purged (EMPTY) database — no projections exist
            // yet — so this fell through, seeded defaults, and the follow-up
            // save() → recordSubscriptionSyncState's "first sighting seeds a
            // fully-dirty projection" rule (right for a genuine local
            // subscribe, wrong here) pushed ALL 113 subscriptions' DEFAULT
            // settings with fresh stamps that beat the phone's older real
            // values under field-LWW — resetting settings across Kevin's phone.
            // Fix: pre-seed the projection CLEAN (markClean = every field "no
            // local opinion"), so recordSubscriptionSyncState's apply() sees no
            // change, nothing pushes, and the real settings win when the
            // CloudKit record arrives moments later. A materialized-by-identity
            // subscription NEVER originates settings; only add(parsedFeed:)
            // (a genuine new local subscribe) should seed dirty.
            var seed = SubscriptionSyncState(subscription: subscription, subscribed: true)
            seed.markClean()
            try? database?.saveSubscriptionSyncState(seed)
        }

        let episodes = parsedFeed.episodes.compactMap {
            episode(from: $0, subscriptionID: subscriptionID, feedArtworkURL: parsedFeed.artworkURL)
        }.map { episode in
            selfHealedEpisode(episode, subscriptionID: subscriptionID)
        }
        if !episodes.isEmpty {
            subscription.latestEpisode = episodes.first
            subscription.episodes = episodes
            seedReleaseObservations(for: &subscription, episodes: episodes)
        }

        subscriptions.append(subscription)
        applyStoredSubscriptionOrderIfAvailable()
        save(authorSubscriptionOrder: false)
        return subscription
    }

    /// REPAIR (2026-07-11, companion to the clean-seed fix in `materialize`
    /// above): de-dirties every pending subscription projection WITHOUT pushing
    /// it. For the tvOS one-shot launch repair: a TV database that was rebuilt
    /// from the survival kit BEFORE that fix shipped still holds fully-dirty
    /// DEFAULT-settings projections, which the engine would re-push (and
    /// re-clobber the phone) on its next activation. The TV NEVER authors
    /// subscription settings (it has no per-podcast settings UI), so clearing
    /// ALL pending subscription-projection dirt there is safe; the only
    /// TV-authored subscription event is subscribe-on-TV, and losing a pending
    /// push of one of those (worst case) means that show simply doesn't roam —
    /// vastly better than clobbering settings account-wide. Returns the number
    /// of projections cleaned, for logging. NOT for iOS: the phone legitimately
    /// authors settings and its pending dirt must survive.
    @discardableResult
    public func markAllPendingSubscriptionProjectionsClean() -> Int {
        guard let database, let pending = try? database.pendingSubscriptionSyncStates(), !pending.isEmpty else { return 0 }
        for state in pending {
            var cleaned = state
            cleaned.markClean()
            try? database.saveSubscriptionSyncState(cleaned)
        }
        return pending.count
    }

    /// Self-heal: an `EpisodeSyncState` CloudKit record can arrive and cache
    /// itself as a "stashed" projection (`applyRemoteEpisodeState`'s no-
    /// local-episode-yet branch) BEFORE the episode it describes exists
    /// locally — normal on a freshly-materializing device, since CloudKit
    /// doesn't guarantee episode records arrive after their parent
    /// subscription. Shared by `updateEpisodes` (iPhone feed refresh) and
    /// `materialize` (tvOS/rebuild path). BUG FIXED HERE (found via tvOS
    /// real-device testing, 2026-07-04): `materialize` used to build fresh
    /// Episode objects with NO such check, so played/archived state that had
    /// already synced down was silently never applied — every back-catalog
    /// episode looked freshly unplayed, which is what caused Up Next to be
    /// full of episodes already finished on iPhone.
    private func selfHealedEpisode(_ episode: Episode, subscriptionID: UUID) -> Episode {
        guard let projection = try? database?.episodeSyncState(subscriptionID: subscriptionID, guid: episode.guid) else {
            return episode
        }
        var healed = episode
        healed.playedState = projection.playedState
        healed.wasCompleted = projection.wasCompleted
        healed.lastPlayedAt = projection.lastPlayedAt
        if projection.playedState == .archived || projection.playedState == .played {
            healed.downloadState = .notDownloaded
            healed.localFileURL = nil
            healed.localFileName = nil
        }
        return healed
    }

    /// Used by OPML import to add a subscription whose metadata came from a live feed fetch.
    /// - Parameter reindexRanks: pass FALSE from remote-sync materialization
    ///   (`SyncCoordinator.materializeRemoteSubscription` on iPhone) so the insert does
    ///   a non-destructive resort instead of compacting every subscription's
    ///   rank to its array position. The compaction is correct for LOCAL adds
    ///   (subscribe, OPML import — the array IS the whole truth there), but
    ///   during a multi-subscription remote sync it collides compacted values
    ///   (1..n) with later-arriving ABSOLUTE synced ranks, producing ties and
    ///   arrival-order corruption — the same bug class fixed for the tvOS
    ///   `materialize` path (see resortByCurrentPriorityRank's header).
    public func addSubscription(
        id: UUID,
        feedURL: URL,
        title: String,
        description: String? = nil,
        author: String?,
        artworkURL: URL?,
        categories: [String] = [],
        isExplicit: Bool? = nil,
        latestEpisode: Episode,
        insertAtBottom: Bool = false,
        reindexRanks: Bool = true
    ) throws -> Subscription {
        guard !subscriptions.contains(where: { $0.feedURL == feedURL }) else {
            throw SubscriptionStoreError.duplicateFeed
        }

        let priorityRank = insertAtBottom ? (subscriptions.map(\.priorityRank).max() ?? 0) + 1 : 0
        var subscription = Subscription(
            id: id,
            feedURL: feedURL,
            title: title,
            author: author,
            artworkURL: artworkURL,
            priorityRank: priorityRank,
            categories: categories,
            isExplicit: isExplicit
        )
        subscription.description = description
        subscription.subscribedAt = Date()
        subscription.playbackPreference = seededDefaultPlaybackPreference
        subscription.autoArchiveSettings = seededDefaultAutoArchiveSettings
        subscription.latestEpisode = latestEpisode
        subscription.episodes = [latestEpisode]
        seedReleaseObservations(for: &subscription, episodes: [latestEpisode])
        if insertAtBottom {
            subscriptions.append(subscription)
        } else {
            subscriptions.insert(subscription, at: 0)
        }
        if reindexRanks {
            normalizePriorityOrder()
        } else {
            applyStoredSubscriptionOrderIfAvailable()
        }
        save(authorSubscriptionOrder: reindexRanks)
        return subscription
    }

    // MARK: - Remove / reorder

    public func remove(subscriptionID: UUID) {
        subscriptions.removeAll { $0.id == subscriptionID }
        reindexPriority()
        save()
    }

    /// Starts a stable UI reorder session and returns the only IDs eligible for
    /// dragging: active, real subscriptions. The view owns this draft until Done,
    /// so repeated SwiftUI moves never depend on delayed AppState publication.
    @discardableResult
    public func beginPriorityReorderSession() -> [UUID] {
        let ids = activeRealSubscriptions.map(\.id)
        priorityReorderSessionInitialIDs = ids
        deferredRemoteSubscriptionOrder = nil
        deferredLegacyPriorityRanks = false
        AppLogger.shared.info("subscriptions.reorderBegan", "Priority reorder session began", metadata: [
            "activeCount": "\(ids.count)",
            "inactiveCount": "\(inactiveRealSubscriptions.count)",
            "hiddenBrowseCount": "\(browseSubscriptions.count)"
        ])
        return ids
    }

    /// Commits one validated whole-list transaction. Returns false when the draft
    /// is malformed/stale; no best-effort index guessing is permitted.
    @discardableResult
    public func commitPriorityReorderSession(
        orderedActiveSubscriptionIDs: [UUID],
        reason: String
    ) -> Bool {
        let currentActive = activeRealSubscriptions
        let currentIDs = currentActive.map(\.id)
        let inputSet = Set(orderedActiveSubscriptionIDs)
        let isValid = inputSet.count == orderedActiveSubscriptionIDs.count
            && inputSet == Set(currentIDs)

        guard isValid else {
            AppLogger.shared.error("subscriptions.reorderRejected", "Rejected stale or invalid priority reorder draft", metadata: [
                "reason": reason,
                "draftCount": "\(orderedActiveSubscriptionIDs.count)",
                "currentCount": "\(currentIDs.count)",
                "duplicateDraftIDs": "\(inputSet.count != orderedActiveSubscriptionIDs.count)"
            ], alwaysPersist: true)
            priorityReorderSessionInitialIDs = nil
            applyDeferredPriorityOrderIfNeeded()
            return false
        }

        let initialIDs = priorityReorderSessionInitialIDs ?? currentIDs
        let userChangedOrder = orderedActiveSubscriptionIDs != initialIDs
        priorityReorderSessionInitialIDs = nil

        if userChangedOrder {
            deferredRemoteSubscriptionOrder = nil
            deferredLegacyPriorityRanks = false
            applyActivePriorityOrder(
                orderedActiveSubscriptionIDs,
                authorSubscriptionOrder: true,
                event: "subscriptions.reorderCommitted",
                reason: reason
            )
        } else {
            applyDeferredPriorityOrderIfNeeded()
        }
        return true
    }

    /// Receives the authoritative whole-list CloudKit order. During a local drag
    /// session it is buffered so the List cannot move underneath the user's hand.
    public func applyRemoteSubscriptionOrder(_ order: SubscriptionOrderState) {
        if priorityReorderSessionInitialIDs != nil {
            if deferredRemoteSubscriptionOrder.map({ $0.updatedAt < order.updatedAt }) ?? true {
                deferredRemoteSubscriptionOrder = order
            }
            AppLogger.shared.info("subscriptions.remoteOrderDeferred", "Deferred remote priority order during local reorder", metadata: [
                "generationID": order.generationID.uuidString,
                "orderedCount": "\(order.orderedSubscriptionIDs.count)"
            ])
            return
        }
        applySubscriptionOrder(
            order,
            authorSubscriptionOrder: false,
            event: "subscriptions.remoteOrderApplied"
        )
    }

    public func updateDescription(subscriptionID: UUID, description: String?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].description != description else { return }
        subscriptions[index].description = description
        save()
    }

    public func updateAuthor(subscriptionID: UUID, author: String?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].author != author else { return }
        subscriptions[index].author = author
        save()
    }

    public func updateArtworkURL(subscriptionID: UUID, artworkURL: URL) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].artworkURL != artworkURL else { return }
        subscriptions[index].artworkURL = artworkURL
        save()
    }

    public func updateRefreshStats(subscriptionID: UUID, stats: RefreshStats) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].refreshStats = stats
        // Refresh stats are scheduler bookkeeping, often written after cheap 304s.
        // Persist them without invalidating views or waking the sync engine's
        // objectWillChange observer on every feed check.
        save(notifyObservers: false)
    }

    public func updateCategories(subscriptionID: UUID, categories: [String]) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].categories != categories else { return }
        subscriptions[index].categories = categories
        save()
    }

    public func updateIsExplicit(subscriptionID: UUID, isExplicit: Bool?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].isExplicit != isExplicit else { return }
        subscriptions[index].isExplicit = isExplicit
        save()
    }

    public func updateTitle(subscriptionID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = subscriptions.firstIndex(where: { $0.id == subscriptionID })
        else { return }

        subscriptions[index].title = trimmed
        save()
    }

    public func updatePriorityRank(subscriptionID: UUID, priorityRank: Int) {
        guard let currentIndex = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[currentIndex].browseDate == nil,
              !subscriptions[currentIndex].excludeFromAutoFeedRefresh
        else { return }
        let activeCount = activeRealSubscriptions.count
        var subscription = subscriptions.remove(at: currentIndex)
        // The visible priority range contains active real subscriptions only.
        // Inactive and browse rows must not inflate the numeric editor's index.
        let clampedRank = max(1, min(priorityRank, activeCount))
        subscription.priorityRank = clampedRank
        subscriptions.insert(subscription, at: clampedRank - 1)
        enforceInactiveSubscriptionsAtBottom()
        reindexPriority()
        save()
    }

    public func updateNotificationsEnabled(subscriptionID: UUID, enabled: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].notificationsEnabled = enabled
        save()
    }

    public func updateAutoArchiveSettings(subscriptionID: UUID, settings: AutoArchiveSettings) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].autoArchiveSettings = settings
        save()
    }

    /// Creates an inactive, browse-only subscription from a search preview.
    /// Sets `browseDate` to now so it appears in the 30-day search history
    /// and can be swept by `cleanupExpiredPreviewSubscriptions()`.
    @discardableResult
    public func addPreviewSubscription(parsedFeed: ParsedFeed, feedURL: URL) throws -> Subscription {
        // If a subscription already exists (active or inactive), don't create a duplicate.
        guard !subscriptions.contains(where: { $0.feedURL == feedURL }) else {
            throw SubscriptionStoreError.duplicateFeed
        }
        var subscription = try add(parsedFeed: parsedFeed, feedURL: feedURL)
        // Move to bottom and mark inactive + browsed.
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return subscription }
        subscriptions[index].excludeFromAutoFeedRefresh = true
        subscriptions[index].browseDate = Date()
        subscription = subscriptions[index]
        enforceInactiveSubscriptionsAtBottom()
        reindexPriority()
        save()
        return subscription
    }

    /// Removes browse-only subscriptions whose `browseDate` is older than 30 days,
    /// provided no episode has been played or downloaded and the show has no
    /// listening history (i.e. truly unacted-on). `subscriptionIDsWithHistory`
    /// is the set of subscription IDs that have at least one listening-history
    /// entry — those are spared so their history stays navigable.
    public func cleanupExpiredPreviewSubscriptions(subscriptionIDsWithHistory: Set<UUID> = []) {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let toRemove = subscriptions.filter { sub in
            guard let date = sub.browseDate, date < cutoff else { return false }
            guard !subscriptionIDsWithHistory.contains(sub.id) else { return false }
            let hasPlayedEpisode = sub.episodes.contains { $0.playedState != .unplayed }
            let hasDownloadedEpisode = sub.episodes.contains { $0.downloadState == .downloaded }
            return !hasPlayedEpisode && !hasDownloadedEpisode
        }
        guard !toRemove.isEmpty else { return }
        let removeIDs = Set(toRemove.map(\.id))
        subscriptions.removeAll { removeIDs.contains($0.id) }
        reindexPriority()
        save()
    }

    /// Resets the 30-day browse clock to now.
    /// Call this whenever the user re-opens a browse-only preview page.
    public func refreshBrowseDate(subscriptionID: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].browseDate != nil
        else { return }
        subscriptions[index].browseDate = Date()
        save()
    }

    /// Activates a browse-only preview and moves it to the top of the Priority Stack.
    /// Real Inactive subscriptions use `updateExcludeFromAutoFeedRefresh` instead
    /// so their per-podcast settings and remembered rank are preserved.
    public func activateAndMoveToTop(subscriptionID: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].browseDate != nil
        else { return }
        var subscription = subscriptions.remove(at: index)
        subscription.excludeFromAutoFeedRefresh = false
        subscription.autoFeedRefreshReturnPriorityRank = nil
        subscription.browseDate = nil
        // Browse preview becoming a real subscription — start the backlog clock now
        // so the existing catalogue isn't archived out from under the new subscriber.
        if subscription.subscribedAt == nil {
            subscription.subscribedAt = Date()
        }
        // Snapshot the current global default now that this is a real subscription.
        // While it was browse-only its preference was resolved live; from here it
        // owns an independent copy that later default changes won't touch.
        subscription.playbackPreference = seededDefaultPlaybackPreference
        subscriptions.insert(subscription, at: 0)
        reindexPriority()
        save()
    }

    public func updateExcludeFromAutoFeedRefresh(subscriptionID: UUID, excluded: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        guard subscriptions[index].excludeFromAutoFeedRefresh != excluded else { return }

        var subscription = subscriptions.remove(at: index)
        subscription.excludeFromAutoFeedRefresh = excluded

        if excluded {
            if subscription.browseDate == nil {
                subscription.autoFeedRefreshReturnPriorityRank = subscription.priorityRank
            }
            subscriptions.append(subscription)
        } else {
            let firstInactiveIndex = subscriptions.firstIndex { $0.excludeFromAutoFeedRefresh } ?? subscriptions.endIndex
            let returnIndex = subscription.autoFeedRefreshReturnPriorityRank
                .map { max(0, min($0 - 1, firstInactiveIndex)) }
                ?? firstInactiveIndex
            subscription.autoFeedRefreshReturnPriorityRank = nil
            subscriptions.insert(subscription, at: returnIndex)
        }

        reindexPriority()
        save()
    }

    /// Migrates all subscriptions to the new AutoArchiveSettings defaults.
    /// `Subscription.init(from:)` simply defaults a missing `autoArchiveSettings`
    /// to `.default` (there is no legacy `autoArchivePolicy` key mapping); this
    /// migration force-sets every subscription to `.default` and re-saves.
    public func migrateExistingSubscriptionsToAutoArchiveSettings() {
        for index in subscriptions.indices {
            // Ensure every subscription ends up with the new default values regardless
            // of what the legacy field decoded to.
            subscriptions[index].autoArchiveSettings = .default
        }
        save()
    }

    public func migrateExistingSubscriptionsToStrongVocalBoost() {
        var changed = false
        for index in subscriptions.indices where subscriptions[index].playbackPreference.vocalBoostLevel != .strong {
            subscriptions[index].playbackPreference.vocalBoostLevel = .strong
            changed = true
        }

        if changed {
            save()
        }
    }

    public func migrateExistingSubscriptionsToPlaybackSpeed(_ speed: Double) {
        var changed = false
        for index in subscriptions.indices {
            subscriptions[index].playbackPreference.speed = speed
            changed = true
        }
        if changed { save() }
    }

    public func migrateExistingSubscriptionsToTrimSilenceLow() {
        var changed = false
        for index in subscriptions.indices where subscriptions[index].playbackPreference.trimSilence == .off {
            subscriptions[index].playbackPreference.trimSilence = .low
            changed = true
        }

        if changed {
            save()
        }
    }

    private var activeRealSubscriptions: [Subscription] {
        subscriptions.filter { $0.browseDate == nil && !$0.excludeFromAutoFeedRefresh }
    }

    private var inactiveRealSubscriptions: [Subscription] {
        subscriptions.filter { $0.browseDate == nil && $0.excludeFromAutoFeedRefresh }
    }

    private var browseSubscriptions: [Subscription] {
        subscriptions.filter { $0.browseDate != nil }
    }

    /// Rebuilds storage by stable identity. Hidden browse previews are always
    /// outside the real-subscription ordering domain.
    private func rebuiltSubscriptions(realOrderIDs: [UUID]) -> [Subscription] {
        let real = subscriptions.filter { $0.browseDate == nil }
        let realByID = Dictionary(real.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var orderedReal = realOrderIDs.compactMap { id -> Subscription? in
            guard seen.insert(id).inserted else { return nil }
            return realByID[id]
        }
        orderedReal.append(contentsOf: real.filter { seen.insert($0.id).inserted })

        // Inactive is a state boundary, not a user-sortable priority tier.
        let active = orderedReal.filter { !$0.excludeFromAutoFeedRefresh }
        let inactive = orderedReal.filter(\.excludeFromAutoFeedRefresh)
        var rebuilt = active + inactive + browseSubscriptions
        for index in rebuilt.indices {
            rebuilt[index].priorityRank = index + 1
        }
        return rebuilt
    }

    private func applyActivePriorityOrder(
        _ orderedActiveIDs: [UUID],
        authorSubscriptionOrder: Bool,
        event: String,
        reason: String
    ) {
        let realOrder = orderedActiveIDs + inactiveRealSubscriptions.map(\.id)
        let rebuilt = rebuiltSubscriptions(realOrderIDs: realOrder)
        guard rebuilt != subscriptions else { return }
        publishChange()
        subscriptions = rebuilt
        save(notifyObservers: false, authorSubscriptionOrder: authorSubscriptionOrder)
        AppLogger.shared.info(event, "Applied stable ID-based priority order", metadata: [
            "reason": reason,
            "activeCount": "\(orderedActiveIDs.count)",
            "generationSource": authorSubscriptionOrder ? "local" : "remote",
            "orderedIDs": orderedActiveIDs.map(\.uuidString).joined(separator: ",")
        ])
    }

    private func applySubscriptionOrder(
        _ order: SubscriptionOrderState,
        authorSubscriptionOrder: Bool,
        event: String
    ) {
        let rebuilt = rebuiltSubscriptions(realOrderIDs: order.orderedSubscriptionIDs)
        guard rebuilt != subscriptions else { return }
        publishChange()
        subscriptions = rebuilt
        save(notifyObservers: false, authorSubscriptionOrder: authorSubscriptionOrder)
        AppLogger.shared.info(event, "Applied atomic subscription order", metadata: [
            "generationID": order.generationID.uuidString,
            "sourceDeviceID": order.sourceDeviceID,
            "remoteCount": "\(order.orderedSubscriptionIDs.count)",
            "localRealCount": "\(subscriptions.filter { $0.browseDate == nil }.count)"
        ])
    }

    private func applyDeferredPriorityOrderIfNeeded() {
        if let deferredRemoteSubscriptionOrder {
            self.deferredRemoteSubscriptionOrder = nil
            deferredLegacyPriorityRanks = false
            applySubscriptionOrder(
                deferredRemoteSubscriptionOrder,
                authorSubscriptionOrder: false,
                event: "subscriptions.deferredRemoteOrderApplied"
            )
            return
        }
        if deferredLegacyPriorityRanks {
            deferredLegacyPriorityRanks = false
            applyPriorityRanksFromStoredProjections()
        }
    }

    private func applyPriorityRanksFromStoredProjections() {
        guard let database else { return }
        // Once this client has an atomic order, independently delivered legacy
        // rank fields are compatibility data only and must not supersede it.
        if let atomicOrder = try? database.subscriptionOrder() {
            applySubscriptionOrder(
                atomicOrder,
                authorSubscriptionOrder: false,
                event: "subscriptions.storedAtomicOrderReapplied"
            )
            return
        }
        var updated = subscriptions
        var changed = false
        for index in updated.indices where updated[index].browseDate == nil {
            guard let projection = try? database.subscriptionSyncState(id: updated[index].id),
                  updated[index].priorityRank != projection.priorityRank
            else { continue }
            updated[index].priorityRank = projection.priorityRank
            changed = true
        }
        guard changed else { return }
        updated.sort { $0.priorityRank < $1.priorityRank }
        let realOrderIDs = updated.filter { $0.browseDate == nil }.map(\.id)
        let realByID = Dictionary(updated.filter { $0.browseDate == nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var orderedReal = realOrderIDs.compactMap { realByID[$0] }
        orderedReal = orderedReal.filter { !$0.excludeFromAutoFeedRefresh }
            + orderedReal.filter(\.excludeFromAutoFeedRefresh)
        var rebuilt = orderedReal + updated.filter { $0.browseDate != nil }
        for index in rebuilt.indices {
            rebuilt[index].priorityRank = index + 1
        }
        publishChange()
        subscriptions = rebuilt
        save(notifyObservers: false, authorSubscriptionOrder: false)
    }

    /// Reuses a stored atomic order after a remote subscription materializes.
    /// This prevents CloudKit's arbitrary record-delivery order from becoming
    /// a new locally-authored list while the library is still filling in.
    private func applyStoredSubscriptionOrderIfAvailable() {
        if let database,
           let order = try? database.subscriptionOrder() {
            subscriptions = rebuiltSubscriptions(realOrderIDs: order.orderedSubscriptionIDs)
        } else {
            resortByCurrentPriorityRank()
        }
    }

    private func reindexPriority() {
        for index in subscriptions.indices {
            subscriptions[index].priorityRank = index + 1
        }
    }

    /// Re-sorts by the CURRENT priorityRank values WITHOUT renumbering them —
    /// unlike `normalizePriorityOrder()`, which compacts ranks to sequential
    /// array-position integers. Use this for remote-sync-driven updates
    /// (materialize / applyRemoteSubscriptionState / legacy recovery), where
    /// the incoming priorityRank is a raw, meaningful value synced from
    /// another device (SYNC_DESIGN.md's field-level LWW).
    ///
    /// BUG THIS FIXES (found via tvOS testing, 2026-07-04): a fresh device
    /// receiving several subscriptions from CloudKit gets them in arbitrary
    /// delivery order, not priority order. `normalizePriorityOrder()`
    /// unconditionally overwrites EVERY subscription's rank with its current
    /// array position — so the very next subscription to materialize (with
    /// its own correct-but-not-yet-applied synced rank) triggers a reindex
    /// that permanently clobbers the rank just set for the PREVIOUS one,
    /// before all the true values are even known. The end result is
    /// "whatever order things happened to arrive in," not the user's actual
    /// Priority Stack order — which is exactly what looked like "random
    /// order" on a freshly-synced Apple TV.
    /// A non-destructive sort preserves each subscription's true rank
    /// (possibly leaving numeric gaps, e.g. 1, 3, 12) until a genuine LOCAL
    /// edit (drag-reorder, subscribe, unsubscribe) next calls
    /// `normalizePriorityOrder()` and compacts them — cosmetic only (the
    /// Priority Stack rank BADGE on iPhone reads the raw value), and it
    /// self-heals on the next local edit. Order is what matters everywhere
    /// else (Library, Up Next, iPhone's own queue), and order is correct
    /// immediately with this approach.
    private func resortByCurrentPriorityRank() {
        subscriptions.sort { $0.priorityRank < $1.priorityRank }
        enforceInactiveSubscriptionsAtBottom()
    }

    private func normalizePriorityOrder() {
        subscriptions.sort { $0.priorityRank < $1.priorityRank }
        enforceInactiveSubscriptionsAtBottom()
        reindexPriority()
    }

    private func enforceInactiveSubscriptionsAtBottom() {
        let active = subscriptions.filter { !$0.excludeFromAutoFeedRefresh }
        let inactive = subscriptions.filter { $0.excludeFromAutoFeedRefresh }
        subscriptions = active + inactive
    }

    // MARK: - Episode state

    public func markEpisodeDownloading(subscriptionID: UUID) {
        updateLatestEpisode(subscriptionID: subscriptionID) { $0.downloadState = .downloading }
    }

    public func markEpisodeDownloading(subscriptionID: UUID, episodeID: UUID) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) { $0.downloadState = .downloading }
    }

    public func markEpisodeDownloaded(subscriptionID: UUID, localFileURL: URL) {
        updateLatestEpisode(subscriptionID: subscriptionID) {
            $0.downloadState = .downloaded
            $0.localFileURL = localFileURL
            $0.localFileName = localFileURL.lastPathComponent
            if $0.downloadedAt == nil { $0.downloadedAt = Date() }
        }
    }

    public func markEpisodeDownloaded(
        subscriptionID: UUID,
        episodeID: UUID,
        localFileURL: URL,
        protectFromEpisodeLimit: Bool = false
    ) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .downloaded
            $0.localFileURL = localFileURL
            $0.localFileName = localFileURL.lastPathComponent
            $0.playedState = .unplayed
            $0.wasCompleted = false
            if $0.downloadedAt == nil { $0.downloadedAt = Date() }
            // Automatic retries/repairs must not erase an earlier explicit
            // user decision. Protection ends only when the file is disposed.
            if protectFromEpisodeLimit {
                $0.isManualDownloadProtected = true
            }
        }
    }

    public func updateEpisodeDuration(subscriptionID: UUID, episodeID: UUID, durationSeconds: TimeInterval) {
        guard durationSeconds.isFinite, durationSeconds >= 0 else { return }
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.durationSeconds = durationSeconds
        }
    }

    public func updateEpisodeChapters(subscriptionID: UUID, episodeID: UUID, chapters: [Chapter]) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.chapters = chapters
        }
    }

    public func markEpisodeDownloadFailed(subscriptionID: UUID) {
        updateLatestEpisode(subscriptionID: subscriptionID) { $0.downloadState = .failed }
    }

    public func markEpisodeDownloadFailed(subscriptionID: UUID, episodeID: UUID) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) { $0.downloadState = .failed }
    }

    public func markEpisodePlaying(subscriptionID: UUID) {
        updateLatestEpisode(subscriptionID: subscriptionID) { $0.playedState = .playing }
    }

    public func markEpisodePlaying(subscriptionID: UUID, episodeID: UUID) {
        let now = Date()
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.playedState = .playing
            // FIX (2026-07-04): historically only markEpisodePlayed stamped
            // this, so multiple `.playing` episodes had nil lastPlayedAt and
            // any recency comparison between them (e.g. picking the most
            // recently started one across devices) was arbitrary. Starting
            // playback IS "last played at" — and it's also what the
            // auto-archive inactivity clock wants (it resets on recent play).
            // Syncs via EpisodeSyncState.lastPlayedAt.
            $0.lastPlayedAt = now
        }
    }

    public func markEpisodePlayed(subscriptionID: UUID) {
        updateLatestEpisode(subscriptionID: subscriptionID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .played
            $0.wasCompleted = true
            $0.isManualDownloadProtected = false
        }
    }

    public func markEpisodePlayed(subscriptionID: UUID, episodeID: UUID) {
        let now = Date()
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .played
            $0.lastPlayedAt = now
            $0.wasCompleted = true
            $0.isManualDownloadProtected = false
        }
        rememberPlayedEpisode(subscriptionID: subscriptionID, episodeID: episodeID)
    }

    // MARK: - Listening history write-back (tvOS Phase 3, §8 item 3)
    //
    // Playback position roams via the ListeningHistoryEntry sync record, whole-
    // entry record-level LWW by `lastListenedAt` (SYNC_DESIGN.md) — NOT via
    // EpisodeSyncState. Historically only the iOS app-target ListeningHistoryStore
    // could write it. These two methods expose the same write path from
    // AutohopCore so a streaming platform (TV, later watch) can participate in
    // phone⇄device resume round-trips without a local history store of its own.
    // Both use `PlaybackPositionStore.key(for:)` as the entry id — verified
    // byte-for-byte identical to ListeningHistoryStore's private `historyKey(for:)`
    // (same subscription-scoped guid/title-date/title-url fallback chain), so
    // entries from either device collide on the SAME id and merge correctly
    // instead of duplicating. Read-modify-write against any existing entry (not
    // a bare overwrite) so a TV session's `listenedSeconds` ACCUMULATES onto
    // whatever the phone already recorded, rather than shrinking the lifetime
    // total on the next record-level-LWW resolution.

    /// Periodic/position write during TV playback — the tvOS analog of
    /// ListeningHistoryStore.recordProgress(). `listenedSecondsDelta` is
    /// ADDED to the existing entry's total (0 for a brand-new entry).
    public func recordListeningProgress(
        episode: Episode,
        podcastTitle: String,
        artworkURL: URL?,
        listenedSecondsDelta: TimeInterval,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        historyEntryID: String? = nil
    ) {
        guard let database else { return }
        let key = historyEntryID ?? PlaybackPositionStore.key(for: episode)
        let now = Date()
        var entry = (try? database.historyEntry(id: key)) ?? ListeningHistoryEntry(
            id: key,
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id,
            episodeTitle: episode.title,
            podcastTitle: podcastTitle,
            artworkURL: artworkURL,
            streamURL: episode.audioURL,
            mediaKind: episode.mediaKind,
            publishedAt: episode.publishedAt,
            durationSeconds: durationSeconds ?? episode.durationSeconds,
            listenedSeconds: 0,
            lastPositionSeconds: 0,
            lastListenedAt: now,
            status: .listened
        )
        entry.episodeID = episode.id
        entry.episodeTitle = episode.title
        entry.podcastTitle = podcastTitle
        entry.artworkURL = artworkURL
        entry.streamURL = episode.audioURL
        entry.mediaKind = episode.mediaKind
        entry.publishedAt = episode.publishedAt
        entry.durationSeconds = durationSeconds ?? episode.durationSeconds
        entry.listenedSeconds += max(0, listenedSecondsDelta)
        entry.lastPositionSeconds = positionSeconds
        entry.lastListenedAt = now
        // Status is intentionally left unchanged here — played/archived
        // transitions go through markListeningHistoryFinished below.
        try? database.recordHistoryEntry(entry)
    }

    /// Records the whole-entry status transition at natural finish — the tvOS
    /// analog of ListeningHistoryStore.mark(status:completionKind:). Called
    /// once when a streamed episode plays to the end.
    public func markListeningHistoryFinished(
        episode: Episode,
        podcastTitle: String,
        artworkURL: URL?,
        finishedPositionSeconds: TimeInterval,
        historyEntryID: String? = nil
    ) {
        guard let database else { return }
        let key = historyEntryID ?? PlaybackPositionStore.key(for: episode)
        let now = Date()
        var entry = (try? database.historyEntry(id: key)) ?? ListeningHistoryEntry(
            id: key,
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id,
            episodeTitle: episode.title,
            podcastTitle: podcastTitle,
            artworkURL: artworkURL,
            streamURL: episode.audioURL,
            mediaKind: episode.mediaKind,
            publishedAt: episode.publishedAt,
            durationSeconds: episode.durationSeconds,
            listenedSeconds: 0,
            lastPositionSeconds: 0,
            lastListenedAt: now,
            status: .listened
        )
        entry.status = .played
        entry.streamURL = episode.audioURL
        entry.mediaKind = episode.mediaKind
        entry.completionKind = .finishedNaturally
        entry.lastPositionSeconds = finishedPositionSeconds
        entry.listenedDurationSeconds = finishedPositionSeconds
        entry.episodeDurationSeconds = episode.durationSeconds
        entry.lastListenedAt = now
        try? database.recordHistoryEntry(entry)
    }

    /// Cross-device resume position for an episode (tvOS Phase 3+ read side —
    /// the counterpart of recordListeningProgress above). Reads the synced
    /// ListeningHistoryEntry (position roams inside it, SYNC_DESIGN.md) and
    /// normalizes: near-end / non-positive → nil ("start from the beginning"),
    /// same rule as the iPhone's PlaybackPositionStore. Only `.listened`
    /// entries resume — a `.played`/`.archived` entry means the episode was
    /// finished, and resuming into the last 2 seconds of it would be wrong.
    public func savedListeningPosition(for episode: Episode) -> TimeInterval? {
        guard let database,
              let entry = try? database.historyEntry(id: PlaybackPositionStore.key(for: episode)),
              entry.status == .listened
        else { return nil }
        let normalized = PlaybackPositionStore.normalizedResumeTime(
            entry.lastPositionSeconds,
            duration: episode.durationSeconds ?? entry.durationSeconds
        )
        return normalized > 0 ? normalized : nil
    }

    /// The most recently listened-to, still-in-progress history entry across
    /// ALL shows — the cross-device "Continue Listening" signal (tvOS Home
    /// hero). History entries carry `lastListenedAt` from whichever device
    /// last played, so this correctly surfaces e.g. the video podcast being
    /// watched on iPhone right now, unlike the old `playedState == .playing`
    /// heuristic (playedState has no reliable recency: `markEpisodePlaying`
    /// historically never stamped `lastPlayedAt`, so multiple `.playing`
    /// episodes compared as nil and the pick was effectively arbitrary).
    /// Requires a meaningful position (> 0 after normalization) so a barely-
    /// touched episode doesn't squat on the hero card.
    public func mostRecentInProgressListeningEntry() -> ListeningHistoryEntry? {
        guard let database else { return nil }
        func qualifies(_ entry: ListeningHistoryEntry) -> Bool {
            guard entry.status == .listened else { return false }
            return PlaybackPositionStore.normalizedResumeTime(
                entry.lastPositionSeconds,
                duration: entry.durationSeconds
            ) > 0
        }
        // FAST PATH (2026-07-11, TV round-8b): the winner is by definition the
        // newest qualifying entry, so scan a newest-first LIMITed slice instead
        // of decoding the whole table (1,783 rows) — the rows are ordered by
        // the same lastListenedAt the recency comparison uses, so the first
        // qualifying hit IS the answer. The full-scan fallback only runs in
        // the degenerate case where none of the newest 50 qualify (e.g. a long
        // run of completed-episode entries with no usable position).
        if let recent = try? database.historyEntriesNewestFirst(limit: 50) {
            if let winner = recent.first(where: qualifies(_:)) { return winner }
            // Fewer rows than the limit = that WAS the whole table; done.
            if recent.count < 50 { return nil }
        }
        guard let entries = try? database.allHistoryEntries() else { return nil }
        return entries
            .filter(qualifies(_:))
            .max { $0.lastListenedAt < $1.lastListenedAt }
    }

    // MARK: - Synced queue snapshot (2026-07-04 — the Up Next queue roams)

    /// Records THIS device's authored Up Next queue for sync. Called by the
    /// iPhone (the queue's source of truth) whenever its queue recomputes;
    /// dedupes on entry-list equality so routine recomputes with no actual
    /// change never dirty the record or trigger a push.
    public func updateLocalQueueSnapshot(entries: [QueueSnapshotEntry]) {
        guard let database else { return }
        if let existing = try? database.queueSnapshot(), existing.entries == entries {
            return
        }
        let epoch = QueueProjectionAuthority.currentEpoch
        let existing = try? database.queueSnapshot()
        let nextGeneration: Int64 = {
            guard let existing, existing.authorityEpoch == epoch else { return 1 }
            return existing.generation == Int64.max ? Int64.max : existing.generation + 1
        }()
        let snapshot = QueueSnapshot(
            entries: entries,
            updatedAt: Date(),
            sourceDeviceID: DeviceIdentity.current,
            generation: nextGeneration,
            authorityEpoch: epoch
        )
        do {
            try database.recordLocalQueueSnapshot(snapshot)
        } catch {
            AppLogger.shared.error("sync.queueSnapshotWriteFailed", "Could not record queue snapshot for sync", metadata: [
                "entries": "\(entries.count)",
                "error": String(describing: error)
            ], alwaysPersist: true)
        }
    }

    /// The latest known queue snapshot (local-authored or synced), for
    /// read-only surfaces (tvOS/watch) to render via QueueModel.resolvedQueue.
    public func syncedQueueSnapshot() -> QueueSnapshot? {
        guard let database else { return nil }
        return try? database.queueSnapshot()
    }

    public func markEpisodeArchived(subscriptionID: UUID, episodeID: UUID) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .archived
            $0.isManualDownloadProtected = false
        }
        rememberArchivedEpisode(subscriptionID: subscriptionID, episodeID: episodeID)
    }

    public func markEpisodeUnarchived(subscriptionID: UUID, episodeID: UUID) {
        guard let subIndex = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let episode = subscriptions[subIndex].episodes.first(where: { $0.id == episodeID })
        else { return }
        let keys = playedEpisodeKeys(for: episode)
        subscriptions[subIndex].archivedEpisodeKeys.subtract(keys)
        subscriptions[subIndex].playedEpisodeKeys.subtract(keys)
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.playedState = .unplayed
            $0.wasCompleted = false
            $0.isManualDownloadProtected = false
        }
    }

    public func markEpisodeNotDownloaded(subscriptionID: UUID, episodeID: UUID) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .unplayed
            $0.wasCompleted = false
        }
    }

    public func updateLatestEpisode(subscriptionID: UUID, episode: Episode) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].latestEpisode = episode
        if subscriptions[index].episodes.isEmpty {
            subscriptions[index].episodes = [episode]
        } else if let episodeIndex = subscriptions[index].episodes.firstIndex(where: { $0.guid == episode.guid }) {
            subscriptions[index].episodes[episodeIndex] = episode
        } else {
            subscriptions[index].episodes.insert(episode, at: 0)
        }
        save()
    }

    /// Convenience refresh entry point: converts a freshly-fetched `ParsedFeed`
    /// into episodes (same conversion as `materialize`/`add`) and merges them
    /// via `updateEpisodes`, preserving local + synced state by guid. Used by
    /// the tvOS feed refresh so "Latest" and episode lists track the phone
    /// (the TV otherwise only fetches a feed once, at materialize time).
    public func updateEpisodes(subscriptionID: UUID, from parsedFeed: ParsedFeed) {
        guard subscriptions.contains(where: { $0.id == subscriptionID }) else { return }
        let episodes = parsedFeed.episodes.compactMap {
            episode(from: $0, subscriptionID: subscriptionID, feedArtworkURL: parsedFeed.artworkURL)
        }
        guard !episodes.isEmpty else { return }
        updateEpisodes(subscriptionID: subscriptionID, episodes: episodes)
    }

    public func updateEpisodes(subscriptionID: UUID, episodes newEpisodes: [Episode]) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        // guid is the episode identity key (parser falls back guid -> title ->
        // random UUID, so it's always present). Build the lookup with
        // uniquingKeysWith — `uniqueKeysWithValues` would CRASH if stored episodes
        // ever contained a duplicate guid.
        let existingByGUID = Dictionary(
            subscriptions[index].episodes.map { ($0.guid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Dedupe the incoming feed by guid (keep first / newest occurrence). A feed
        // that repeats a guid would otherwise map two episodes to the SAME existing
        // id below, producing duplicate Identifiable ids — which crashes SwiftUI's
        // ForEach in PodcastDetailView the moment a row is tapped.
        var seenGUIDs = Set<String>()
        let dedupedNewEpisodes = newEpisodes.filter { seenGUIDs.insert($0.guid).inserted }
        let mergedEpisodes = dedupedNewEpisodes.map { newEpisode -> Episode in
            var merged = newEpisode
            if let existing = existingByGUID[newEpisode.guid] {
                merged.id = existing.id
                merged.downloadState = existing.downloadState
                merged.localFileURL = existing.localFileURL
                merged.localFileName = existing.localFileName ?? existing.localFileURL?.lastPathComponent
                merged.playedState = existing.playedState
                merged.wasCompleted = existing.wasCompleted
                // Feed fields are authoritative for RSS metadata, but these
                // timestamps are device-local lifecycle state. Preserve them
                // whenever identity matches so a routine HTTP 200 refresh
                // cannot erase the Auto Archive inactivity clock or playback
                // recency while retaining the corresponding local file/state.
                merged.downloadedAt = existing.downloadedAt
                merged.isManualDownloadProtected =
                    existing.isManualDownloadProtected
                merged.lastPlayedAt = existing.lastPlayedAt
                merged.isExplicit = newEpisode.isExplicit ?? existing.isExplicit
                if existing.localFileURL != nil, let duration = existing.durationSeconds {
                    merged.durationSeconds = duration
                }
            }
            if merged.downloadState != .downloaded {
                let keys = playedEpisodeKeys(for: merged)
                if keys.contains(where: { subscriptions[index].archivedEpisodeKeys.contains($0) }) {
                    merged.downloadState = .notDownloaded
                    merged.localFileURL = nil
                    merged.localFileName = nil
                    merged.playedState = .archived
                    // Episode keys in both sets = finished, then archived.
                    if keys.contains(where: { subscriptions[index].playedEpisodeKeys.contains($0) }) {
                        merged.wasCompleted = true
                    }
                } else if keys.contains(where: { subscriptions[index].playedEpisodeKeys.contains($0) }) {
                    merged.downloadState = .notDownloaded
                    merged.localFileURL = nil
                    merged.localFileName = nil
                    merged.playedState = .played
                    merged.wasCompleted = true
                }
            }

            // Self-heal: a remote episode-state may have arrived before this
            // episode existed locally (stashed as a sync projection). Now that
            // the feed brings it in, apply that synced state. Shared with
            // materialize()'s selfHealedEpisode — keep them in sync.
            if existingByGUID[newEpisode.guid] == nil {
                merged = selfHealedEpisode(merged, subscriptionID: subscriptionID)
            }
            return merged
        }
        guard subscriptions[index].episodes != mergedEpisodes
                || subscriptions[index].latestEpisode != mergedEpisodes.first
        else { return }
        subscriptions[index].episodes = mergedEpisodes
        subscriptions[index].latestEpisode = mergedEpisodes.first
        save()
    }

    public func updatePlaybackPreference(subscriptionID: UUID, preference: PlaybackPreference) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].playbackPreference = preference
        save()
    }

    public func updateDownloadFilterSettings(subscriptionID: UUID, settings: DownloadFilterSettings) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].downloadFilterSettings = settings
        save()
    }

    public func subscription(id: UUID) -> Subscription? {
        subscriptions.first { $0.id == id }
    }

    public func episode(subscriptionID: UUID, episodeID: UUID) -> Episode? {
        guard let subscription = subscription(id: subscriptionID) else { return nil }
        return subscription.episodes.first { $0.id == episodeID }
            ?? (subscription.latestEpisode?.id == episodeID ? subscription.latestEpisode : nil)
    }

    public func toggleChapter(subscriptionID: UUID, position: Int) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        if subscriptions[index].chapterFilter.skippedPositions.contains(position) {
            subscriptions[index].chapterFilter.skippedPositions.remove(position)
        } else {
            subscriptions[index].chapterFilter.skippedPositions.insert(position)
        }
        save()
    }

    /// Replaces the complete position filter with one persistence/UI publication.
    /// PlaybackChapterWorkflow owns propagation into an active playback engine.
    public func updateChapterFilter(subscriptionID: UUID, filter: ChapterFilter) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].chapterFilter != filter else { return }
        subscriptions[index].chapterFilter = filter
        save()
    }

    // MARK: - Cross-device sync (remote → local)

    /// Applies a remote episode-state record into the local store with
    /// field-level last-write-wins (see `EpisodeSyncState.merged`). The merged
    /// projection is persisted and, when the episode exists locally, its
    /// played/completed/lastPlayed fields are updated without creating new dirty
    /// stamps. Returns true if a local domain episode was updated.
    @discardableResult
    public func applyRemoteEpisodeState(_ remote: EpisodeSyncState) -> Bool {
        guard let database else { return false }

        let localProjection = try? database.episodeSyncState(syncKey: remote.syncKey)
        let location = locateEpisode(subscriptionID: remote.subscriptionID, guid: remote.guid)

        let baseline: EpisodeSyncState
        if let localProjection {
            baseline = localProjection
        } else if let location {
            var seeded = EpisodeSyncState(
                episode: subscriptions[location.sub].episodes[location.ep],
                subscriptionID: subscriptions[location.sub].id
            )
            seeded.markClean() // no local opinion yet → remote wins
            baseline = seeded
        } else {
            // No projection and no local episode: adopt the remote values as
            // clean authoritative state so they aren't lost before the feed
            // brings the episode in (full self-heal is a later step).
            var adopted = remote
            adopted.markClean()
            try? database.saveEpisodeSyncState(adopted)
            return false
        }

        var merged = baseline.merged(withRemote: remote)

        // Active-player-wins: if this episode is loaded in the player on THIS
        // device, don't let a remote played/archived state interrupt it — keep
        // the local playedState and re-stamp it so it pushes back as authoritative.
        if let location, remote.syncKey == nowPlayingEpisodeSyncKeyProvider?() {
            let localPlayed = subscriptions[location.sub].episodes[location.ep].playedState
            if merged.playedState != localPlayed {
                merged.$playedState = Synced(wrappedValue: localPlayed, modifiedAt: Date())
            }
        }

        try? database.saveEpisodeSyncState(merged)

        guard let location else { return false }

        var episode = subscriptions[location.sub].episodes[location.ep]
        episode.playedState = merged.playedState
        episode.wasCompleted = merged.wasCompleted
        episode.lastPlayedAt = merged.lastPlayedAt

        // A remote played/archived merge means the episode finished on another
        // device; discard this device's local download to match the local
        // markEpisodePlayed/markEpisodeArchived paths and the self-heal branch in
        // updateEpisodes(). Without this, a cross-device archive leaves an orphaned
        // media file (storage leak) and a "downloaded + archived" episode
        // (ASSESSMENT.md B1). The actual file delete is surfaced through
        // onEpisodeFileShouldDelete (installed by DownloadCoordinator) since the
        // store can't reach DownloadManager directly — mirroring the active
        // player identity provider.
        if merged.playedState == .played || merged.playedState == .archived {
            let hadLocalDownload = episode.downloadState == .downloaded
                || episode.localFileURL != nil
                || episode.localFileName != nil
            if hadLocalDownload {
                // Hand off the still-populated episode so the callback can locate
                // the file before we null the fields below.
                onEpisodeFileShouldDelete?(episode)
            }
            episode.downloadState = .notDownloaded
            episode.localFileURL = nil
            episode.localFileName = nil
            episode.isManualDownloadProtected = false
        }

        subscriptions[location.sub].episodes[location.ep] = episode
        if subscriptions[location.sub].latestEpisode?.id == episode.id {
            subscriptions[location.sub].latestEpisode = episode
        }
        save()
        return true
    }

    /// Outcome of applying a remote subscription record.
    public enum RemoteSubscriptionOutcome {
        /// Handled locally (settings applied, unsubscribe processed, or no-op).
        case applied
        /// The podcast isn't present on this device and needs to be created by
        /// fetching its feed — the caller (AppState, which has FeedService)
        /// materialises it, then re-applies this state.
        case needsMaterialization(SubscriptionSyncState)
    }

    /// Applies a remote subscription-settings record with field-level LWW.
    /// Updates an existing subscription's settings, processes an unsubscribe, or
    /// reports that a new subscribed podcast must be materialised from its feed.
    @discardableResult
    public func applyRemoteSubscriptionState(_ remote: SubscriptionSyncState) -> RemoteSubscriptionOutcome {
        guard let database else { return .applied }

        let localProjection = try? database.subscriptionSyncState(id: remote.subscriptionID)
        let existingIndex = subscriptions.firstIndex { $0.id == remote.subscriptionID }

        let baseline: SubscriptionSyncState
        if let localProjection {
            baseline = localProjection
        } else if let existingIndex {
            var seeded = SubscriptionSyncState(subscription: subscriptions[existingIndex], subscribed: true)
            seeded.markClean()
            baseline = seeded
        } else {
            // Unknown podcast.
            if remote.subscribed {
                var adopted = remote
                adopted.markClean()
                try? database.saveSubscriptionSyncState(adopted)
                return .needsMaterialization(remote)
            }
            return .applied // unsubscribe for something we never had
        }

        let merged = baseline.merged(withRemote: remote)
        try? database.saveSubscriptionSyncState(merged)

        // Remote unsubscribe wins → remove locally.
        if !merged.subscribed {
            if let existingIndex {
                remove(subscriptionID: subscriptions[existingIndex].id)
            }
            return .applied
        }

        guard let existingIndex else { return .applied }

        var sub = subscriptions[existingIndex]
        sub.title = merged.title
        if priorityReorderSessionInitialIDs == nil {
            sub.priorityRank = merged.priorityRank
        } else if sub.priorityRank != merged.priorityRank {
            // Keep the visible/local draft stable; the merged projection already
            // retains this remote rank and will be applied if the user exits
            // without committing a local change.
            deferredLegacyPriorityRanks = true
        }
        sub.notificationsEnabled = merged.notificationsEnabled
        sub.excludeFromAutoFeedRefresh = merged.excludeFromAutoFeedRefresh
        sub.autoFeedRefreshReturnPriorityRank = merged.autoFeedRefreshReturnPriorityRank
        sub.playbackPreference = merged.playbackPreference
        sub.autoArchiveSettings = merged.autoArchiveSettings
        sub.chapterFilter = merged.chapterFilter
        sub.downloadFilterSettings = merged.downloadFilterSettings
        subscriptions[existingIndex] = sub
        if priorityReorderSessionInitialIDs == nil {
            // Legacy per-subscription rank compatibility. Atomic
            // SubscriptionOrder is authoritative when present, but old clients
            // still send this field.
            applyStoredSubscriptionOrderIfAvailable()
        }
        save(authorSubscriptionOrder: false)
        return .applied
    }

    /// Restores settings from a legacy unprefixed CloudKit SubscriptionState
    /// record left behind by the namespace repair. This never creates or removes
    /// a subscription; it only repairs settings for a podcast that still exists
    /// locally, then marks the merged state fully dirty so the namespaced
    /// `subscription:<id>` record is re-uploaded as a complete snapshot.
    @discardableResult
    public func recoverSettingsFromLegacySubscriptionState(_ legacy: SubscriptionSyncState) -> Bool {
        guard let database,
              let existingIndex = subscriptions.firstIndex(where: { $0.id == legacy.subscriptionID })
        else { return false }

        let baseline: SubscriptionSyncState
        if let localProjection = try? database.subscriptionSyncState(id: legacy.subscriptionID) {
            baseline = localProjection
        } else {
            var seeded = SubscriptionSyncState(subscription: subscriptions[existingIndex], subscribed: true)
            seeded.markClean()
            baseline = seeded
        }

        var legacySettings = legacy
        // Recovery must not resurrect a removed subscription or process a stale
        // unsubscribe; membership stays local. Only per-podcast settings are
        // restored from the legacy record.
        legacySettings.$subscribed = baseline.$subscribed

        let merged = baseline.merged(withRemote: legacySettings)
        var upload = merged
        upload.markAllDirty()
        try? database.saveSubscriptionSyncState(upload)

        var sub = subscriptions[existingIndex]
        sub.title = merged.title
        sub.priorityRank = merged.priorityRank
        sub.notificationsEnabled = merged.notificationsEnabled
        sub.excludeFromAutoFeedRefresh = merged.excludeFromAutoFeedRefresh
        sub.autoFeedRefreshReturnPriorityRank = merged.autoFeedRefreshReturnPriorityRank
        sub.playbackPreference = merged.playbackPreference
        sub.autoArchiveSettings = merged.autoArchiveSettings
        sub.chapterFilter = merged.chapterFilter
        // Legacy records predate filter sync, so this is normally the local
        // value carried through the merge (nil remote stamp = no opinion).
        sub.downloadFilterSettings = merged.downloadFilterSettings
        subscriptions[existingIndex] = sub
        applyStoredSubscriptionOrderIfAvailable()
        save(authorSubscriptionOrder: false)
        return true
    }

    private func locateEpisode(subscriptionID: UUID, guid: String) -> (sub: Int, ep: Int)? {
        guard let s = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return nil }
        guard let e = subscriptions[s].episodes.firstIndex(where: { $0.guid == guid }) else { return nil }
        return (s, e)
    }

    private func updateLatestEpisode(subscriptionID: UUID, update: (inout Episode) -> Void) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              var episode = subscriptions[index].latestEpisode
        else { return }
        update(&episode)
        subscriptions[index].latestEpisode = episode
        if let episodeIndex = subscriptions[index].episodes.firstIndex(where: { $0.id == episode.id }) {
            subscriptions[index].episodes[episodeIndex] = episode
        } else if subscriptions[index].episodes.isEmpty {
            subscriptions[index].episodes = [episode]
        }
        save()
    }

    private func updateEpisode(subscriptionID: UUID, episodeID: UUID, update: (inout Episode) -> Void) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }

        if let episodeIndex = subscriptions[index].episodes.firstIndex(where: { $0.id == episodeID }) {
            update(&subscriptions[index].episodes[episodeIndex])
            if subscriptions[index].latestEpisode?.id == episodeID {
                subscriptions[index].latestEpisode = subscriptions[index].episodes[episodeIndex]
            }
        } else if var episode = subscriptions[index].latestEpisode, episode.id == episodeID {
            update(&episode)
            subscriptions[index].latestEpisode = episode
            subscriptions[index].episodes = [episode]
        } else {
            return
        }
        save()
    }

    private func rememberPlayedEpisode(subscriptionID: UUID, episodeID: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let episode = subscriptions[index].episodes.first(where: { $0.id == episodeID })
                ?? (subscriptions[index].latestEpisode?.id == episodeID ? subscriptions[index].latestEpisode : nil)
        else { return }

        subscriptions[index].playedEpisodeKeys.formUnion(playedEpisodeKeys(for: episode))
        save()
    }

    private func rememberArchivedEpisode(subscriptionID: UUID, episodeID: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let episode = subscriptions[index].episodes.first(where: { $0.id == episodeID })
                ?? (subscriptions[index].latestEpisode?.id == episodeID ? subscriptions[index].latestEpisode : nil)
        else { return }

        subscriptions[index].archivedEpisodeKeys.formUnion(playedEpisodeKeys(for: episode))
        save()
    }

    private func playedEpisodeKeys(for episode: Episode) -> Set<String> {
        var keys: Set<String> = ["guid:\(episode.guid)"]
        if let publishedAt = episode.publishedAt {
            keys.insert("title-date:\(episode.title.lowercased())|\(Int(publishedAt.timeIntervalSince1970))")
        }
        return keys
    }

    private func seedReleaseObservations(for subscription: inout Subscription, episodes: [Episode]) {
        var stats = subscription.refreshStats
        stats.recordEpisodeObservations(
            episodes,
            previouslyKnownEpisodeKeys: [],
            at: Date()
        )
        subscription.refreshStats = stats
    }

    private func episode(from parsedEpisode: ParsedEpisode, subscriptionID: UUID, feedArtworkURL: URL?) -> Episode? {
        guard let audioURL = parsedEpisode.audioURL else { return nil }
        let episodeID = UUID()
        let chapters = parsedEpisode.chapters.map { p in
            Chapter(
                id: UUID(),
                episodeID: episodeID,
                position: p.position,
                title: p.title,
                startSeconds: p.startSeconds,
                durationSeconds: p.durationSeconds,
                source: p.source
            )
        }
        var episode = Episode(
            id: episodeID,
            subscriptionID: subscriptionID,
            guid: parsedEpisode.guid,
            title: parsedEpisode.title,
            audioURL: audioURL,
            mediaKind: parsedEpisode.mediaKind,
            chapters: chapters
        )
        episode.description = parsedEpisode.description
        episode.subtitle = parsedEpisode.subtitle
        episode.author = parsedEpisode.author
        episode.publishedAt = parsedEpisode.publishedAt
        episode.durationSeconds = parsedEpisode.durationSeconds
        episode.artworkURL = parsedEpisode.artworkURL ?? feedArtworkURL
        episode.fileSizeBytes = parsedEpisode.fileSizeBytes
        episode.isExplicit = parsedEpisode.isExplicit
        episode.episodeLink = parsedEpisode.episodeLink
        return episode
    }

    // MARK: - Persistence

    private func load() {
        guard let database else { return }

        // One-time migration: if the GRDB store is empty but a legacy
        // subscriptions.json exists, import it, then rename the file so the
        // import never runs again (kept, not deleted, so it's recoverable).
        if database.isEmpty, let imported = decodeLegacyFileIfPresent() {
            subscriptions = imported.sorted { $0.priorityRank < $1.priorityRank }
            normalizePriorityOrder()
            do {
                try database.replaceAll(with: subscriptions)
                persistedSnapshot = snapshotByID(subscriptions)
                // Import decoded AND reached disk — only now retire the legacy file so the
                // migration never re-runs. If we renamed earlier and the write had failed,
                // the source would be gone with the data unsaved.
                retireLegacyFile()
            } catch {
                // Persist failed — keep the legacy file so the migration retries next launch.
                AppLogger.shared.error("subscriptions.legacyImportPersistFailed", "Legacy import decoded but failed to persist; keeping source file", metadata: [
                    "error": String(describing: error)
                ])
                persistedSnapshot = [:]
            }
            return
        }

        do {
            subscriptions = try database.loadSubscriptions()
                .sorted { $0.priorityRank < $1.priorityRank }
            // Non-destructive resort (2026-07-04 audit, same bug class as the
            // materialization rank fix): compacting ranks at LOAD destroyed
            // absolute synced values — if the app relaunched mid-initial-sync,
            // later-arriving remote ranks tied against the freshly compacted
            // 1..n and order corrupted. Gaps are cosmetic and the next LOCAL
            // edit recompacts via normalizePriorityOrder as before.
            resortByCurrentPriorityRank()
            persistedSnapshot = snapshotByID(subscriptions)
            // Heal any sync-state rows left by an older projection shape so they
            // re-seed and push on this launch, not only when next edited.
            try? database.reseedUndecodableSyncState(for: subscriptions)
        } catch {
            subscriptions = []
            persistedSnapshot = [:]
        }
    }

    /// Decodes the legacy JSON file (reusing the same decoder so Subscription's
    /// legacy-key migration still runs). Returns nil when there is no legacy file
    /// or it cannot be decoded — in which case the source file is left untouched so
    /// the caller can retry the migration on a future launch. The file is only
    /// retired (via `retireLegacyFile()`) once the import has reached the database.
    private func decodeLegacyFileIfPresent() -> [Subscription]? {
        guard let legacyFileURL,
              FileManager.default.fileExists(atPath: legacyFileURL.path)
        else { return nil }

        do {
            let data = try Data(contentsOf: legacyFileURL)
            return try JSONDecoder().decode([Subscription].self, from: data)
        } catch {
            AppLogger.shared.error("subscriptions.legacyDecodeFailed", "Legacy subscriptions file present but could not be decoded; keeping it for retry", metadata: [
                "error": String(describing: error)
            ])
            return nil
        }
    }

    /// Renames the legacy file to `*.migrated` so the one-time import never re-runs.
    /// Called only after a successful decode + persist; the file is kept (not deleted)
    /// so the migration remains recoverable.
    private func retireLegacyFile() {
        guard let legacyFileURL,
              FileManager.default.fileExists(atPath: legacyFileURL.path)
        else { return }
        let migratedURL = legacyFileURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: migratedURL) // clear any prior leftover
        try? FileManager.default.moveItem(at: legacyFileURL, to: migratedURL)
    }

    private func snapshotByID(_ subs: [Subscription]) -> [UUID: Subscription] {
        Dictionary(subs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Change-notification coalescing (launch-jank fix)

    /// While true, `save(notifyObservers: true)` defers its `objectWillChange` into a
    /// single pending flag instead of firing per mutation. Used by CloudSyncEngine's
    /// fetched-changes apply loop: a post-launch sync burst (e.g. 18 remote records)
    /// otherwise fires 18 whole-app invalidations back-to-back on the main thread.
    /// Disk persistence is unaffected — only the UI/sync notification is coalesced.
    private var changeNotificationCoalescingDepth = 0
    private var coalescedChangeNotificationPending = false
    private var coalescedNarrowDomainNotificationPending = false

    /// Begin deferring observer notifications. Must be paired with
    /// `endChangeNotificationCoalescing()` on the main actor.
    public func beginChangeNotificationCoalescing() {
        changeNotificationCoalescingDepth += 1
    }

    /// Stop deferring and fire ONE `objectWillChange` if any save was suppressed.
    public func endChangeNotificationCoalescing() {
        guard changeNotificationCoalescingDepth > 0 else { return }
        changeNotificationCoalescingDepth -= 1
        guard changeNotificationCoalescingDepth == 0 else { return }
        if coalescedNarrowDomainNotificationPending {
            coalescedNarrowDomainNotificationPending = false
            publishNarrowDomainChangesIfNeeded()
        }
        if coalescedChangeNotificationPending {
            coalescedChangeNotificationPending = false
            objectWillChange.send()
        }
    }

    private func publishChange() {
        if changeNotificationCoalescingDepth > 0 {
            coalescedChangeNotificationPending = true
        } else {
            objectWillChange.send()
        }
    }

    private func save(
        notifyObservers: Bool = true,
        authorSubscriptionOrder: Bool = true
    ) {
        if notifyObservers {
            publishNarrowDomainChangesIfNeeded()
            publishChange()
        }
        guard let database else { return }
        persistenceRetryTask?.cancel()
        persistenceRetryTask = nil
        // Coalesce saves issued while a write is in flight: rerun once it lands
        // so the final state always reaches disk (dropping them loses data).
        if pendingSave {
            saveCoalesced = true
            coalescedSaveAuthorsSubscriptionOrder =
                coalescedSaveAuthorsSubscriptionOrder || authorSubscriptionOrder
            return
        }
        pendingSave = true
        // Snapshot on main actor, diff + write on the background queue. GRDB's
        // DatabaseQueue is thread-safe, so calling it off-main is fine.
        let snapshot = subscriptions
        let previous = persistedSnapshot
        let authorsOrder = authorSubscriptionOrder
        Self.saveQueue.async { [weak self, weak database] in
            let didPersist: Bool
            var persistenceError: String?
            do {
                try database?.persist(
                    current: snapshot,
                    previous: previous,
                    authorSubscriptionOrder: authorsOrder
                )
                didPersist = true
            } catch {
                didPersist = false
                persistenceError = String(describing: error)
                AppLogger.shared.error("subscriptions.persistFailed", "Failed to persist subscriptions snapshot", metadata: [
                    "error": String(describing: error)
                ], alwaysPersist: true)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Only advance the persisted snapshot when the write actually reached disk.
                // Otherwise later saves would diff against a snapshot that was never written and
                // silently drop the failed mutation. Leaving it unchanged means the next edit's
                // diff still includes those changes and retries them.
                if didPersist {
                    self.persistedSnapshot = self.snapshotByID(snapshot)
                    self.persistenceRetryAttempt = 0
                    self.lastPersistenceErrorDescription = nil
                } else {
                    self.lastPersistenceErrorDescription = persistenceError
                    self.lastFailedSaveAuthorsSubscriptionOrder = authorsOrder
                }
                self.pendingSave = false
                if self.saveCoalesced {
                    let coalescedAuthorsOrder = self.coalescedSaveAuthorsSubscriptionOrder
                    self.saveCoalesced = false
                    self.coalescedSaveAuthorsSubscriptionOrder = false
                    self.save(
                        notifyObservers: false,
                        authorSubscriptionOrder: coalescedAuthorsOrder
                    )
                } else if !didPersist {
                    self.schedulePersistenceRetry()
                }
            }
        }
    }

    /// Computes only the fields capable of changing downloaded queue identity or
    /// ordering. This deliberately excludes titles, artwork, descriptions,
    /// playback preferences, refresh stats, and other broad store mutations.
    private func queueAffectingSignature() -> [String] {
        subscriptions
            .sorted { $0.priorityRank < $1.priorityRank }
            .flatMap { subscription in
                let episodes = subscription.episodes.isEmpty
                    ? subscription.latestEpisode.map { [$0] } ?? []
                    : subscription.episodes
                return episodes
                    .filter {
                        $0.downloadState == .downloaded
                            && ($0.localFileURL != nil || $0.localFileName != nil)
                            && $0.playedState != .played
                            && $0.playedState != .archived
                    }
                    .map { episode in
                    [
                        subscription.id.uuidString,
                        "\(subscription.priorityRank)",
                        episode.id.uuidString,
                        episode.title,
                        episode.downloadState.rawValue,
                        episode.localFileURL?.path ?? "",
                        episode.localFileName ?? "",
                        episode.playedState.rawValue,
                        "\(episode.publishedAt?.timeIntervalSince1970 ?? 0)"
                    ].joined(separator: "|")
                    }
            }
    }

    private func membershipSignature() -> [String] {
        subscriptions
            .map { "\($0.id.uuidString)|\($0.browseDate == nil ? "real" : "browse")" }
            .sorted()
    }

    private func presentationSignature() -> [String] {
        subscriptions
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .flatMap { subscription in
                let episodes = subscription.episodes.isEmpty
                    ? subscription.latestEpisode.map { [$0] } ?? []
                    : subscription.episodes
                return episodes
                    .filter {
                        $0.downloadState == .downloaded
                            && ($0.localFileURL != nil || $0.localFileName != nil)
                            && $0.playedState != .played
                            && $0.playedState != .archived
                    }
                    .map { episode in
                        [
                            subscription.id.uuidString,
                            subscription.title,
                            subscription.artworkURL?.absoluteString ?? "",
                            PlaybackPositionStore.key(for: episode),
                            episode.title,
                            "\(episode.durationSeconds ?? 0)",
                            episode.artworkURL?.absoluteString ?? "",
                            episode.mediaKind.rawValue,
                            episode.isExplicit.map { String($0) } ?? "unknown"
                        ].joined(separator: "|")
                    }
            }
    }

    private func seedDomainChangeSignatures() {
        lastQueueAffectingSignature = queueAffectingSignature()
        lastMembershipSignature = membershipSignature()
        lastPresentationSignature = presentationSignature()
    }

    private func publishNarrowDomainChangesIfNeeded() {
        if changeNotificationCoalescingDepth > 0 {
            coalescedNarrowDomainNotificationPending = true
            return
        }
        let queueSignature = queueAffectingSignature()
        if queueSignature != lastQueueAffectingSignature {
            lastQueueAffectingSignature = queueSignature
            queueDidChange.send()
        }
        let membership = membershipSignature()
        if membership != lastMembershipSignature {
            lastMembershipSignature = membership
            membershipDidChange.send()
        }
        let presentation = presentationSignature()
        if presentation != lastPresentationSignature {
            lastPresentationSignature = presentation
            presentationDidChange.send()
        }
    }

    private func schedulePersistenceRetry() {
        guard persistenceRetryAttempt < maximumPersistenceRetryAttempts else {
            AppLogger.shared.error("subscriptions.persistRetryExhausted", "Subscription persistence retries exhausted", metadata: [
                "attempts": "\(persistenceRetryAttempt)",
                "error": lastPersistenceErrorDescription ?? "unknown"
            ], alwaysPersist: true)
            return
        }
        persistenceRetryAttempt += 1
        let attempt = persistenceRetryAttempt
        let delay = min(4.0, 0.25 * pow(2.0, Double(attempt - 1)))
        AppLogger.shared.warning("subscriptions.persistRetryScheduled", "Scheduled subscription persistence retry", metadata: [
            "attempt": "\(attempt)",
            "delaySeconds": String(format: "%.2f", delay)
        ])
        persistenceRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.persistenceRetryTask = nil
            self.save(
                notifyObservers: false,
                authorSubscriptionOrder: self.lastFailedSaveAuthorsSubscriptionOrder
            )
        }
    }

    /// Waits until every queued write has reached disk. Lets tests (and shutdown
    /// paths) reload from the store without racing the background save queue.
    @discardableResult
    public func flushPendingSaves() async -> Bool {
        if persistenceRetryTask != nil {
            persistenceRetryTask?.cancel()
            persistenceRetryTask = nil
            save(
                notifyObservers: false,
                authorSubscriptionOrder: lastFailedSaveAuthorsSubscriptionOrder
            )
        }
        while pendingSave || saveCoalesced || persistenceRetryTask != nil {
            // A cancelled lifecycle task must not spin forever: Task.sleep
            // throws immediately after cancellation while the store's own
            // retry may still be pending. The retry remains scheduled and a
            // later lifecycle/Done flush can verify durability.
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return lastPersistenceErrorDescription == nil
    }

    private static func defaultLegacyFileURL() -> URL? {
        appSupportURL()?.appendingPathComponent("Autohop/subscriptions.json")
    }

    /// SQLite path sitting beside an explicit legacy file, e.g.
    /// `…/subscriptions.json` → `…/subscriptions.sqlite`.
    private static func databasePath(besideLegacyFile fileURL: URL) -> String {
        fileURL.deletingPathExtension().appendingPathExtension("sqlite").path
    }

    private static func defaultDatabasePath() -> String {
        // Falls back to a temporary path if Application Support is unavailable,
        // so the store always has a working database.
        guard let url = appSupportURL()?.appendingPathComponent("Autohop/autohop.sqlite") else {
            return NSTemporaryDirectory() + "autohop.sqlite"
        }
        try? LockedDeviceFileAccess.createDirectory(url.deletingLastPathComponent())
        return url.path
    }

    private static func appSupportURL() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}

enum SubscriptionStoreError: LocalizedError {
    case duplicateFeed

    var errorDescription: String? {
        "That podcast is already in your subscriptions."
    }
}
