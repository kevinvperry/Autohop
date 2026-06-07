import Foundation

@MainActor
public final class SubscriptionStore: ObservableObject {
    @Published public private(set) var subscriptions: [Subscription] = []
    private let fileURL: URL?
    private static let saveQueue = DispatchQueue(label: "com.autohop.subscriptionStore.save", qos: .utility)
    // Coalesces rapid save() calls (e.g. during a 70-feed refresh cycle) into one disk write.
    private var pendingSave = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
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

        let episodes = parsedFeed.episodes.compactMap {
            episode(from: $0, subscriptionID: subscriptionID, feedArtworkURL: parsedFeed.artworkURL)
        }

        if !episodes.isEmpty {
            subscription.latestEpisode = episodes.first
            subscription.episodes = episodes
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
        subscription.latestEpisode = latestEpisode
        subscription.episodes = [latestEpisode]
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
    /// The decoder handles legacy `autoArchivePolicy` → `autoArchiveSettings` conversion on load,
    /// so this migration only needs to force-save to write the new key and drop the old one.
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
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) { $0.playedState = .unplayed }
    }

    public func markEpisodeNotDownloaded(subscriptionID: UUID, episodeID: UUID) {
        updateEpisode(subscriptionID: subscriptionID, episodeID: episodeID) {
            $0.downloadState = .notDownloaded
            $0.localFileURL = nil
            $0.localFileName = nil
            $0.playedState = .unplayed
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
        let existingByGUID = Dictionary(uniqueKeysWithValues: subscriptions[index].episodes.map { ($0.guid, $0) })
        let mergedEpisodes = newEpisodes.map { newEpisode -> Episode in
            var merged = newEpisode
            if let existing = existingByGUID[newEpisode.guid] {
                merged.id = existing.id
                merged.downloadState = existing.downloadState
                merged.localFileURL = existing.localFileURL
                merged.localFileName = existing.localFileName ?? existing.localFileURL?.lastPathComponent
                merged.playedState = existing.playedState
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
                } else if keys.contains(where: { subscriptions[index].playedEpisodeKeys.contains($0) }) {
                    merged.downloadState = .notDownloaded
                    merged.localFileURL = nil
                    merged.localFileName = nil
                    merged.playedState = .played
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
        return episode
    }

    // MARK: - Persistence

    private func load() {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            subscriptions = try JSONDecoder().decode([Subscription].self, from: data)
                .sorted { $0.priorityRank < $1.priorityRank }
            normalizePriorityOrder()
        } catch {
            subscriptions = []
        }
    }

    private func save() {
        objectWillChange.send()
        guard let fileURL, !pendingSave else { return }
        pendingSave = true
        // Snapshot on main actor, then encode + write on background queue.
        let snapshot = subscriptions
        Self.saveQueue.async { [weak self, fileURL] in
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                // In-memory state remains usable.
            }
            DispatchQueue.main.async { self?.pendingSave = false }
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/subscriptions.json")
    }
}

enum SubscriptionStoreError: LocalizedError {
    case duplicateFeed

    var errorDescription: String? {
        "That podcast is already in your subscriptions."
    }
}
