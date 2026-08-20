import Combine
import CloudKit
import Foundation
import AutohopCore

// AI CONTEXT — Library projection, detail loading, and store invalidation workflow. Extracted from TVAppModel without changing
// product policy; this extension is tvOS-only and coordinated through focused
// observable state owners defined in TVAppFeatureModels.swift.

extension TVAppModel {
    /// Stage-timing probe (TV diagnostics, 2026-07-11): runs `body` and logs a
    /// `tv.perf` line when it took ≥ `thresholdMs` on the main actor. Cheap
    /// enough to leave on permanently; the threshold keeps the log signal-only.
    /// Cross-reference with tv.mainThreadHang timestamps to see WHICH stage
    /// was blocking during a stutter.
    @discardableResult
    func timed<T>(_ stage: String, thresholdMs: Double = 40, _ body: () -> T) -> T {
        let beganActive = isSceneActive
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = body()
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        if !beganActive || !isSceneActive || elapsedMs >= 30_000 {
            AppLogger.shared.info("tv.perf.inactiveGapExcluded", "Excluded inactive or suspension gap from performance timing", metadata: [
                "stage": stage,
                "elapsedBucket": elapsedMs >= 300_000 ? "5m+" : elapsedMs >= 30_000 ? "30s+" : "sceneInactive"
            ])
        } else if elapsedMs >= thresholdMs {
            AppLogger.shared.info("tv.perf", "Main-actor stage was slow", metadata: [
                "stage": stage,
                "ms": String(format: "%.0f", elapsedMs)
            ], alwaysPersist: true)
        }
        return result
    }

    func saveSurvivalKit() {
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

    func observeStoreForKitWrites() {
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
    func scheduleLibraryRefresh() {
        guard isSceneActive else {
            hasDeferredInactiveLibraryRefresh = true
            deferredInactiveLibraryRefreshRequestCount += 1
            return
        }
        guard pendingLibraryRefresh == nil else {
            coalescedLibraryRefreshRequestCount += 1
            return
        }
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
            guard self.isSceneActive else {
                self.hasDeferredInactiveLibraryRefresh = true
                self.deferredInactiveLibraryRefreshRequestCount += 1
                return
            }
            self.refreshLibrary()
        }
    }

    /// Drains at most one projection rebuild after an inactive period. The
    /// counters make high-volume CloudKit bursts measurable without logging
    /// every suppressed callback.
    func resumeDeferredLibraryRefreshIfNeeded() {
        guard isSceneActive, hasDeferredInactiveLibraryRefresh else { return }
        hasDeferredInactiveLibraryRefresh = false
        AppLogger.shared.info("tv.libraryRefresh.resumed", "Resumed one coalesced library refresh after scene activation", metadata: [
            "inactiveRequests": "\(deferredInactiveLibraryRefreshRequestCount)",
            "coalescedRequests": "\(coalescedLibraryRefreshRequestCount)"
        ], alwaysPersist: true)
        deferredInactiveLibraryRefreshRequestCount = 0
        coalescedLibraryRefreshRequestCount = 0
        scheduleLibraryRefresh()
    }

    func refreshLibrary() {
        lastLibraryRefreshAt = Date()
        let startedAt = CFAbsoluteTimeGetCurrent()
        timed("refreshLibrary") { refreshLibraryBody() }
        let duration = CFAbsoluteTimeGetCurrent() - startedAt
        if isSceneActive, duration < 30 { lastLibraryRefreshDuration = duration }
    }

    func refreshLibraryBody() {
        // EQUALITY GUARDS (2026-07-11 nav-stall fix, part 3): @Observable
        // fires on every SET regardless of value equality, and this method is
        // called from several periodic paths (store observer, cloud prime, the
        // foreground freshness poll) — unconditional reassignment re-rendered
        // the whole Home/Queue tree even when nothing changed, disturbing the
        // tvOS focus engine mid-navigation. A no-change refresh is now a
        // genuine no-op: nothing is written, so nothing re-renders.
        let baseProjection = TVLibraryProjector.project(
            subscriptions: subscriptionStore.subscriptions,
            pendingEntries: []
        )
        let realIDs = Set(baseProjection.subscriptions.map(\.id))
        let pendingEntries = (survivalKitStore.load()?.entries ?? [])
            .filter { !realIDs.contains($0.subscriptionID) }
        let projection = TVLibraryProjector.project(
            subscriptions: subscriptionStore.subscriptions,
            pendingEntries: pendingEntries
        )
        let newLibrary = projection.subscriptions
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
        let newTiles = projection.tiles
        if newTiles != libraryTiles { libraryTiles = newTiles }

        // PERF FIX (2026-07-10, found investigating a reported memory/CPU bug):
        // subscriptionsByID + upNextItems/upNextEpisodes/
        // continueListening were all previously COMPUTED properties, recomputed
        // from scratch on every access — including subscription(id:)'s O(n)
        // linear scan and continueListening's DB query + full flatMap/filter/max
        // over every episode across every show. TVHomeView reads
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
        let historyChanged = historyNeedsReload || historyModel.needsReload
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

        // AI CONTEXT — Launch readiness is published LAST. Cached/show tiles
        // alone are not a usable Home screen: queue, history and Continue
        // Listening must all be projected before TVRootView leaves the branded
        // launch experience. This prevents a one-frame false empty state.
        let newRootState: RootState = newTiles.isEmpty ? .empty : .ready
        if newRootState != rootState { rootState = newRootState }
        scheduleTopShelfPublication(reason: "libraryRefresh")
    }

    func scheduleTopShelfPublication(reason: String) {
        topShelfPublisher.schedule(candidate: topShelfCandidate(), reason: reason)
    }

    // AI CONTEXT — This is the single presentation projection used by both
    // coalesced foreground updates and the immediate background checkpoint.
    func topShelfCandidate() -> TVTopShelfSnapshotCandidate? {
        let currentEpisodeKey = playbackModel.currentEpisode.map(PlaybackPositionStore.key(for:))
        // AI CONTEXT — Top Shelf gets live playback explicitly, unlike Home's
        // idle-only Continue projection. Reserve it ahead of the ten-item cap
        // and remove the matching queue row so a lower-ranked playing episode
        // cannot disappear and a top-ranked one cannot be duplicated.
        let projectedQueueRows = queueRows.filter { $0.id != currentEpisodeKey }
        let nowPlaying = playbackModel.currentEpisode.map {
            TVTopShelfNowPlaying(
                episode: $0,
                podcastTitle: playbackModel.currentSubscriptionTitle,
                positionSeconds: playbackModel.currentTime
            )
        }
        return rootState == .ready
            ? TVTopShelfSnapshotBuilder.build(
                nowPlaying: nowPlaying,
                continueListening: continueListening,
                queueRows: projectedQueueRows
            )
            : nil
    }

    func recomputeDerivedState(recomputeQueue: Bool, recomputeHistory: Bool) {
        if recomputeQueue {
            subscriptionsByID = Dictionary(uniqueKeysWithValues: librarySubscriptions.map { ($0.id, $0) })
            // AI CONTEXT — History checkpoints must never rebuild Up Next.
            // Log 25 showed 199 queue projections for only five meaningful
            // queue generations because history invalidation shared this path.
            let authoritativeUpNextItems = computeUpNextItems().map { item in
                let recovered = legacyQueueEpisodes[item.episodeKey] ?? recoveredLocalEpisode(for: item)
                guard item.episode == nil, let recovered else { return item }
                return QueueModel.ResolvedQueueItem(
                    episodeKey: item.episodeKey,
                    title: recovered.title,
                    podcastTitle: item.podcastTitle ?? legacyQueuePodcastTitles[item.episodeKey],
                    subscriptionID: item.subscriptionID,
                    episode: recovered,
                    pinState: item.pinState,
                    publishedAt: item.publishedAt
                )
            }.filter { item in
                guard let episode = item.episode else {
                    return !locallyArchivedEpisodeKeys.contains(item.episodeKey)
                }
                return !locallyArchivedEpisodeKeys.contains(PlaybackPositionStore.key(for: episode))
            }
            // A TV Play Next command is locally visible before CloudKit is
            // contacted. Do not let an older phone snapshot undo that action
            // while its command is travelling to the phone. Once the phone's
            // authoritative snapshot has the same first key, confirmation is
            // complete and the temporary overlay can be removed.
            if let pendingKey = queueModel.pendingPlayNextEpisodeKey,
               authoritativeUpNextItems.first?.episodeKey == pendingKey,
               authoritativeUpNextItems.first?.pinState == .playNext {
                queueModel.pendingPlayNextEpisodeKey = nil
                AppLogger.shared.info("tv.playNextConfirmed", "Phone-authored queue confirmed Apple TV Play Next pin", metadata: [
                    "episodeKey": pendingKey,
                    "generation": lastRenderedQueueSnapshot.map { "\($0.generation)" } ?? "unknown"
                ], alwaysPersist: true)
            }
            let confirmedUnpins = queueModel.pendingUnpinEpisodeKeys.filter { key in
                authoritativeUpNextItems.first(where: { $0.episodeKey == key })?.pinState == nil
            }
            if !confirmedUnpins.isEmpty {
                queueModel.pendingUnpinEpisodeKeys.subtract(confirmedUnpins)
                AppLogger.shared.info("tv.unpinConfirmed", "Phone-authored queue confirmed Apple TV Unpin", metadata: [
                    "count": "\(confirmedUnpins.count)",
                    "generation": lastRenderedQueueSnapshot.map { "\($0.generation)" } ?? "unknown"
                ], alwaysPersist: true)
            }
            var newUpNextItems = TVQueueProjector.pinToFront(
                authoritativeUpNextItems,
                episodeKey: queueModel.pendingPlayNextEpisodeKey
            )
            if let discoverItem = queueModel.pendingDiscoverPlayNextItem,
               !newUpNextItems.contains(where: { $0.episodeKey == discoverItem.episodeKey }) {
                newUpNextItems.insert(discoverItem, at: 0)
            }
            for key in queueModel.pendingUnpinEpisodeKeys {
                newUpNextItems = TVQueueProjector.unpin(
                    newUpNextItems,
                    episodeKey: key,
                    subscriptionsByID: subscriptionsByID
                )
            }
            if newUpNextItems != upNextItems {
                upNextItems = newUpNextItems
                upNextEpisodes = newUpNextItems.compactMap(\.episode)
                queueRows = projectQueueRows(from: newUpNextItems)
            }
        }
        guard recomputeHistory else { return }
        if historyModel.needsReload {
            historyModel.needsReload = false
            let newHistory = computeRecentHistory()
            if newHistory != historyModel.items { historyModel.items = newHistory }
        }
        if playbackModel.currentEpisode == nil {
            let newContinueListening = computeContinueListening()
            if newContinueListening != continueListening { continueListening = newContinueListening }
        } else {
            historyNeedsReload = true
            if continueListening != nil { continueListening = nil }
        }
        // A history-only CloudKit delta can change remaining-time metadata
        // without changing queue identity or order. Refresh the immutable rows
        // here so tvOS mirrors the iOS Up Next label immediately.
        let refreshedQueueRows = projectQueueRows(from: upNextItems)
        if refreshedQueueRows != queueRows { queueRows = refreshedQueueRows }
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
        if let cached = episodeDetailRepository.cachedRows(subscriptionID: subscriptionID) {
            episodeRowsBySubscription[subscriptionID] = cached
        }
        do {
            episodeRowsBySubscription[subscriptionID] = try await episodeDetailRepository.refreshRows(
                subscriptionID: subscriptionID,
                feedURL: tile.feedURL
            )
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
    }}
