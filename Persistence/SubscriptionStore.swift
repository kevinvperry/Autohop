import Foundation

// AI CONTEXT — Persistence/SubscriptionStore.swift
// The single persistent store for ALL subscription + episode data. JSON file
// at Application Support/Autohop/subscriptions.json; saves are coalesced on a
// utility queue so a 70-feed refresh cycle produces one disk write, written
// atomically. @MainActor: all mutation happens on the main actor and views
// observe `subscriptions` through AppState's subscriptionStore.objectWillChange
// bridge. The array is not @Published on purpose: save() is the single publisher,
// which lets refresh-stat-only writes persist quietly without waking UI/sync.
// RESPONSIBILITIES beyond CRUD: episode merge on feed refresh (match by guid,
// preserving local fields like downloadState/playedState/localFileURL/
// wasCompleted — the merge also reconstructs wasCompleted from
// playedEpisodeKeys when a finished episode was archived between refreshes),
// feed metadata maintenance (updateAuthor / updateArtworkURL are used by
// AppState.refreshSubscription so show art and author changes from RSS refreshes
// reach every cached-artwork call site),
// Release Radar history seeding for newly added subscriptions
// (seedReleaseObservations records initial ParsedFeed episodes into
// RefreshStats.releaseObservations so the learned scheduler starts with the
// feed's current RSS publish-date evidence),
// priorityRank normalization (contiguous 1..n after any insert/move/delete),
// browse-subscription lifecycle (creation on preview, 30-day expiry purge,
// activation on subscribe), and ParsedFeed → Episode conversion.
// Remote episode sync applies by subscription-scoped sync key and protects the
// currently loaded player episode (active-player-wins); refresh-stat-only writes
// deliberately persist without publishing so they do not wake views or sync.
// GOTCHA: accessors generally distinguish active subscriptions
// (browseDate == nil) from browse ones; queue/refresh/UI must not see browse
// subscriptions except in the search sheet's Recently Viewed list.
@MainActor
public final class SubscriptionStore: ObservableObject {
    public private(set) var subscriptions: [Subscription] = []
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
    /// Snapshot of what last reached disk, keyed by id, so save() writes only
    /// the rows that actually changed.
    private var persistedSnapshot: [UUID: Subscription] = [:]
    /// Returns the subscription-scoped sync key of the episode loaded in the
    /// player on this device, so a remote played/archived change can't interrupt
    /// it (active-player-wins).
    /// Set by AppState; nil when nothing is loaded.
    public var nowPlayingEpisodeSyncKeyProvider: (() -> String?)?

    /// Supplies the global default PlaybackPreference (from AppSettings). Used to
    /// seed a subscription's own playbackPreference at the moment it becomes a
    /// real subscription. Set by AppState; falls back to `.default` when nil.
    /// Browse-only (preview) subscriptions resolve their preference live through
    /// AppState.effectivePreference(for:), so seeding only matters once a feed is
    /// actually subscribed to — after which the snapshot is independent.
    public var defaultPlaybackPreferenceProvider: (() -> PlaybackPreference)?

    /// Supplies the global default AutoArchiveSettings (from AppSettings). Applied
    /// to each new subscription at subscribe time. Set by AppState; falls back to
    /// `.default` when nil. Never applied to existing subscriptions.
    public var defaultAutoArchiveSettingsProvider: (() -> AutoArchiveSettings)?

    /// Requests deletion of an episode's downloaded media file. Set by AppState to
    /// call DownloadManager.deleteLocalFile(for:) — the store can't reach the
    /// DownloadManager directly. Invoked when a remote played/archived state merges
    /// in (applyRemoteEpisodeState) and this device still holds the download, so a
    /// cross-device archive doesn't leave an orphaned file (ASSESSMENT.md B1). The
    /// episode handed in still has its localFileURL/localFileName populated so the
    /// file can be located before those fields are cleared.
    public var onEpisodeFileShouldDelete: ((Episode) -> Void)?

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
    }

    /// Test seam: a store backed entirely by an in-memory database (no disk).
    public static func inMemory() -> SubscriptionStore {
        SubscriptionStore(inMemoryDatabase: try? AutohopDatabase())
    }

    private init(inMemoryDatabase: AutohopDatabase?) {
        self.legacyFileURL = nil
        self.database = inMemoryDatabase
        load()
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

    /// Used by OPML import to add a subscription whose metadata came from a live feed fetch.
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
        insertAtBottom: Bool = false
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
        normalizePriorityOrder()
        save()
        return subscription
    }

    // MARK: - Remove / reorder

    public func remove(subscriptionID: UUID) {
        subscriptions.removeAll { $0.id == subscriptionID }
        reindexPriority()
        save()
    }

    public func reorder(from source: IndexSet, to destination: Int) {
        // Array.move(fromOffsets:toOffset:) is a SwiftUI extension not available in the
        // package's macOS build target, so we implement the same semantics manually.
        let sorted = source.sorted()
        let moving = sorted.map { subscriptions[$0] }
        for index in sorted.reversed() { subscriptions.remove(at: index) }
        let offset = sorted.filter { $0 < destination }.count
        let insertAt = max(0, min(destination - offset, subscriptions.count))
        subscriptions.insert(contentsOf: moving, at: insertAt)
        enforceInactiveSubscriptionsAtBottom()
        reindexPriority()
        save()
    }

    public func updateDescription(subscriptionID: UUID, description: String?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].description = description
        save()
    }

    public func updateAuthor(subscriptionID: UUID, author: String?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].author = author
        save()
    }

    public func updateArtworkURL(subscriptionID: UUID, artworkURL: URL) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
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
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].categories = categories
        save()
    }

    public func updateIsExplicit(subscriptionID: UUID, isExplicit: Bool?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
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
        guard let currentIndex = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        var subscription = subscriptions.remove(at: currentIndex)
        let clampedRank = max(1, min(priorityRank, subscriptions.count + 1))
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

    /// Activates an inactive subscription and moves it to the top of the Priority Stack.
    /// Clears `browseDate` — the subscription is now a full active subscription.
    public func activateAndMoveToTop(subscriptionID: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].excludeFromAutoFeedRefresh
        else { return }
        var subscription = subscriptions.remove(at: index)
        subscription.excludeFromAutoFeedRefresh = false
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
            subscriptions.append(subscription)
        } else {
            let firstInactiveIndex = subscriptions.firstIndex { $0.excludeFromAutoFeedRefresh } ?? subscriptions.endIndex
            subscriptions.insert(subscription, at: firstInactiveIndex)
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

    private func reindexPriority() {
        for index in subscriptions.indices {
            subscriptions[index].priorityRank = index + 1
        }
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
        }
    }

    public func markEpisodeDownloaded(subscriptionID: UUID, episodeID: UUID, localFileURL: URL) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .downloaded
            $0.localFileURL = localFileURL
            $0.localFileName = localFileURL.lastPathComponent
            $0.playedState = .unplayed
            $0.wasCompleted = false
        }
    }

    public func updateEpisodeDuration(subscriptionID: UUID, episodeID: UUID, durationSeconds: TimeInterval) {
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
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) { $0.playedState = .playing }
    }

    public func markEpisodePlayed(subscriptionID: UUID) {
        updateLatestEpisode(subscriptionID: subscriptionID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .played
            $0.wasCompleted = true
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
        }
        rememberPlayedEpisode(subscriptionID: subscriptionID, episodeID: episodeID)
    }

    public func markEpisodeArchived(subscriptionID: UUID, episodeID: UUID) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .archived
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
            // the feed brings it in, apply that synced state.
            if existingByGUID[newEpisode.guid] == nil,
               let projection = try? database?.episodeSyncState(subscriptionID: subscriptionID, guid: newEpisode.guid) {
                merged.playedState = projection.playedState
                merged.wasCompleted = projection.wasCompleted
                merged.lastPlayedAt = projection.lastPlayedAt
                if projection.playedState == .archived || projection.playedState == .played {
                    merged.downloadState = .notDownloaded
                    merged.localFileURL = nil
                    merged.localFileName = nil
                }
            }
            return merged
        }
        subscriptions[index].episodes = mergedEpisodes
        subscriptions[index].latestEpisode = mergedEpisodes.first
        save()
    }

    public func updatePlaybackPreference(subscriptionID: UUID, preference: PlaybackPreference) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].playbackPreference = preference
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
        // onEpisodeFileShouldDelete (set by AppState) since the store can't reach
        // DownloadManager directly — mirroring nowPlayingEpisodeSyncKeyProvider.
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
        sub.priorityRank = merged.priorityRank
        sub.notificationsEnabled = merged.notificationsEnabled
        sub.excludeFromAutoFeedRefresh = merged.excludeFromAutoFeedRefresh
        sub.playbackPreference = merged.playbackPreference
        sub.autoArchiveSettings = merged.autoArchiveSettings
        sub.chapterFilter = merged.chapterFilter
        subscriptions[existingIndex] = sub
        normalizePriorityOrder()
        save()
        return .applied
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
            normalizePriorityOrder()
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

    private func save(notifyObservers: Bool = true) {
        if notifyObservers {
            objectWillChange.send()
        }
        guard let database else { return }
        // Coalesce saves issued while a write is in flight: rerun once it lands
        // so the final state always reaches disk (dropping them loses data).
        if pendingSave {
            saveCoalesced = true
            return
        }
        pendingSave = true
        // Snapshot on main actor, diff + write on the background queue. GRDB's
        // DatabaseQueue is thread-safe, so calling it off-main is fine.
        let snapshot = subscriptions
        let previous = persistedSnapshot
        Self.saveQueue.async { [weak self, weak database] in
            let didPersist: Bool
            do {
                try database?.persist(current: snapshot, previous: previous)
                didPersist = true
            } catch {
                didPersist = false
                AppLogger.shared.error("subscriptions.persistFailed", "Failed to persist subscriptions snapshot", metadata: [
                    "error": String(describing: error)
                ])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Only advance the persisted snapshot when the write actually reached disk.
                // Otherwise later saves would diff against a snapshot that was never written and
                // silently drop the failed mutation. Leaving it unchanged means the next edit's
                // diff still includes those changes and retries them.
                if didPersist {
                    self.persistedSnapshot = self.snapshotByID(snapshot)
                }
                self.pendingSave = false
                if self.saveCoalesced {
                    self.saveCoalesced = false
                    self.save(notifyObservers: false)
                }
            }
        }
    }

    /// Waits until every queued write has reached disk. Lets tests (and shutdown
    /// paths) reload from the store without racing the background save queue.
    public func flushPendingSaves() async {
        while pendingSave || saveCoalesced {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
