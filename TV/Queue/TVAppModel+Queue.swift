import Combine
import CloudKit
import Foundation
import AutohopCore

// AI CONTEXT — Phone-authored Up Next projection and bounded legacy enrichment. Extracted from TVAppModel without changing
// product policy; this extension is tvOS-only and coordinated through focused
// observable state owners defined in TVAppFeatureModels.swift.

extension TVAppModel {
    // MARK: - Home queue and Library derived state
    // Cached in refreshLibrary()/recomputeDerivedState() — see the PERF FIX note
    // there. Read-only from outside; Views access these as plain stored state.

    var upNextItems: [QueueModel.ResolvedQueueItem] {
        get { queueModel.items }
        set { queueModel.items = newValue }
    }
    var upNextEpisodes: [Episode] {
        get { queueModel.episodes }
        set { queueModel.episodes = newValue }
    }
    var queueRows: [TVQueueRowModel] {
        get { queueModel.rows }
        set { queueModel.rows = newValue }
    }
    var continueListening: TVContinueListening? {
        get { continueListeningModel.item }
        set { continueListeningModel.item = newValue }
    }
    /// O(1) id → subscription lookup, replacing the old `librarySubscriptions
    /// .first { $0.id == id }` linear scan that subscription(id:) used to run —
    /// on its own a modest cost, but TVHomeView calls it once PER ROW
    /// PER RENDER, which at 113 subscriptions was a real O(rows × shows) tax on
    /// every Up Next / Latest re-render.
    var subscriptionsByID: [UUID: AutohopCore.Subscription] {
        get { libraryModel.subscriptionsByID }
        set { libraryModel.subscriptionsByID = newValue }
    }
    var lastRenderedQueueSnapshot: QueueSnapshot? {
        get { queueModel.lastRenderedSnapshot }
        set { queueModel.lastRenderedSnapshot = newValue }
    }
    var uniqueEpisodesByGUID: [String: Episode] {
        get { queueModel.uniqueEpisodesByGUID }
        set { queueModel.uniqueEpisodesByGUID = newValue }
    }
    var uniqueEpisodesByNormalizedTitle: [String: Episode] {
        get { queueModel.uniqueEpisodesByNormalizedTitle }
        set { queueModel.uniqueEpisodesByNormalizedTitle = newValue }
    }

    /// Reconciles queue/history records authored before a subscription was
    /// removed and re-added. Their subscription-scoped keys legitimately no
    /// longer match, while the same RSS GUID/title exists under the replacement
    /// subscription UUID. Index only globally unique values so recovery can
    /// never guess between two shows or similarly named episodes.
    func rebuildOrphanRecoveryIndexes() {
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

    func recoveredLocalEpisode(for item: QueueModel.ResolvedQueueItem) -> Episode? {
        if let marker = item.episodeKey.range(of: "|guid:") {
            let guid = String(item.episodeKey[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let episode = uniqueEpisodesByGUID[guid] { return episode }
        }
        return uniqueEpisodesByNormalizedTitle[normalizedEpisodeTitle(item.title)]
    }

    func normalizedEpisodeTitle(_ title: String) -> String {
        TVEpisodeResolver.normalized(title)
    }

    func normalizedPodcastIdentity(_ title: String) -> String {
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

    func pumpQueueEnrichment() {
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

    func finishQueueEnrichment(subscriptionID: UUID) {
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

    func retryLegacyRowsWhoseSourcesArrived() {
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

    func computeUpNextItems() -> [QueueModel.ResolvedQueueItem] {
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
}
