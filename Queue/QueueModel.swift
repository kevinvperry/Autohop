import Foundation

// AI CONTEXT — Queue/QueueModel.swift
// Phase 0 of Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md (§4.2 move 2): the pure,
// platform-neutral Priority Stack composition — base ordering (QueueService)
// plus the Play Next / Play Last pin overrides that previously lived only in
// AppState.orderedQueueWithOverrides(). AppState now delegates here (its
// memoization + pin persistence + invalidation signals stay in AppState);
// tvOS/watch compose their queues from this same logic so ordering can never
// drift between surfaces. PIN SEMANTICS (must match the historical AppState
// behavior exactly): pins referencing episodes not in the base queue are
// ignored; Play Next pins move to the FRONT in pin order; Play Last pins
// append to the END in pin order; everything else keeps base order. Headless
// tests: Tests/QueueModelTests.swift.

/// The user's manual queue overrides: Play Next pins (front, in order) and
/// Play Last pins (end, in order). Persisted by the app layer (queue-pins.json
/// on iOS); this type is just the value shape the ordering logic consumes.
public struct QueuePins: Codable, Equatable {
    public var playNextIDs: [UUID]
    public var playLastIDs: [UUID]

    public init(playNextIDs: [UUID] = [], playLastIDs: [UUID] = []) {
        self.playNextIDs = playNextIDs
        self.playLastIDs = playLastIDs
    }

    public var isEmpty: Bool { playNextIDs.isEmpty && playLastIDs.isEmpty }
}

public enum QueueModel {
    /// Full Priority Stack: QueueService base ordering with pins applied.
    /// DOWNLOAD-GATED — for the iPhone's download-first player. Do not use
    /// this for a streaming platform (see `streamableQueue` below).
    public static func downloadedQueue(
        from subscriptions: [Subscription],
        pins: QueuePins,
        queueService: QueueServicing = QueueService()
    ) -> [Episode] {
        applyPins(queueService.downloadedQueue(from: subscriptions), pins: pins)
    }

    /// The Priority Stack for a STREAMING platform (tvOS Phase 2, later watch):
    /// ascending priorityRank across shows, ONE episode per show — the oldest
    /// still-unplayed one (matches QueueService's within-podcast ordering rule
    /// and, in effect, what an iPhone user normally sees: only one episode per
    /// show is ever downloaded/queued at a time). WITHOUT the "downloaded with
    /// a local file" gate, since a streaming engine plays every episode from
    /// its enclosure URL.
    /// FIX (found via real-device tvOS testing, 2026-07-04): this used to
    /// return EVERY unplayed episode per show, not just one. iPhone's queue
    /// never visibly "groups" because the download gate normally limits each
    /// show to a single queued episode; without that gate, a show with a full
    /// back-catalog (e.g. 50 parsed episodes, all unplayed on a fresh
    /// subscribe) dumped its entire backlog consecutively before the next
    /// show ever appeared. Interleaving one-per-show across priority order is
    /// what actually reads as "Up Next," not a per-show binge list — browsing
    /// a show's full backlog is Library's job.
    /// No pin overrides yet: Play Next/Play Last pins are local, per-device,
    /// un-synced state on iPhone today (queue-pins.json), so a TV/watch
    /// install has no pin data of its own to apply — this is the honest
    /// current behavior, not an oversight. If pins are ever synced, layer
    /// `applyPins` on top here the same way `downloadedQueue` does.
    public static func streamableQueue(from subscriptions: [Subscription]) -> [Episode] {
        subscriptions
            .sorted { $0.priorityRank < $1.priorityRank }
            .compactMap { subscription -> Episode? in
                let episodes = subscription.episodes.isEmpty
                    ? subscription.latestEpisode.map { [$0] } ?? []
                    : subscription.episodes
                guard let next = episodes
                    .filter({ $0.playedState != .played && $0.playedState != .archived })
                    .min(by: { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) })
                else { return nil }
                var queuedEpisode = next
                queuedEpisode.subscriptionID = subscription.id
                return queuedEpisode
            }
    }

    /// Resolves a synced QueueSnapshot (the iPhone's authored Up Next order —
    /// see Models/QueueSnapshot.swift) against a reader's local catalog.
    /// Snapshot ORDER is authoritative; entries that don't resolve to a local
    /// episode are skipped (that show's catalog may still be fetching), and
    /// episodes the READER already knows are played/archived are filtered as
    /// stale protection (a snapshot authored before a local/newer-synced
    /// completion must not resurrect a finished episode). This is what makes
    /// "3 queued episodes of one show on the phone" mirror exactly on TV.
    public static func resolvedQueue(
        from snapshot: QueueSnapshot,
        subscriptions: [Subscription]
    ) -> [Episode] {
        // Key every local episode once (subscriptions × episodes can be a few
        // thousand; the snapshot is small — index the big side).
        var episodesByKey: [String: Episode] = [:]
        for subscription in subscriptions {
            let episodes = subscription.episodes.isEmpty
                ? subscription.latestEpisode.map { [$0] } ?? []
                : subscription.episodes
            for var episode in episodes {
                episode.subscriptionID = subscription.id
                episodesByKey[PlaybackPositionStore.key(for: episode)] = episode
            }
        }
        return snapshot.entries.compactMap { entry in
            guard let episode = episodesByKey[entry.episodeKey],
                  episode.playedState != .played,
                  episode.playedState != .archived
            else { return nil }
            return episode
        }
    }

    /// Applies Play Next / Play Last pins to an already-ordered base queue.
    /// Exact port of AppState.orderedQueueWithOverrides() — see header for the
    /// pin semantics contract.
    public static func applyPins(_ baseQueue: [Episode], pins: QueuePins) -> [Episode] {
        guard !pins.isEmpty else { return baseQueue }

        let availableIDs = Set(baseQueue.map(\.id))
        let validOverrideIDs = pins.playNextIDs.filter { availableIDs.contains($0) }
        let validDemotedIDs = pins.playLastIDs.filter { availableIDs.contains($0) }
        guard !validOverrideIDs.isEmpty || !validDemotedIDs.isEmpty else { return baseQueue }

        let specialIDs = Set(validOverrideIDs).union(Set(validDemotedIDs))
        let overrideEpisodes = validOverrideIDs.compactMap { id in baseQueue.first { $0.id == id } }
        let demotedEpisodes = validDemotedIDs.compactMap { id in baseQueue.first { $0.id == id } }

        var ordered = baseQueue.filter { !specialIDs.contains($0.id) }
        ordered.insert(contentsOf: overrideEpisodes, at: 0)
        ordered.append(contentsOf: demotedEpisodes)
        return ordered
    }
}
