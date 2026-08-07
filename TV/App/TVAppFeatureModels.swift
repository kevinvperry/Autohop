import Foundation
import Observation
import AutohopCore

// AI CONTEXT — Focused tvOS observable state owners extracted from TVAppModel.
// These types deliberately contain state, not network/persistence policy. Their
// coordinators/projectors publish compact results here so a Queue change does
// not invalidate Library or Continue Listening views.

@MainActor
@Observable
final class TVLibraryModel {
    var subscriptions: [AutohopCore.Subscription] = []
    var tiles: [TVPodcastTileModel] = []
    var episodeRowsBySubscription: [UUID: [TVEpisodeRowModel]] = [:]
    var loadingEpisodeSubscriptions: Set<UUID> = []
    var subscriptionsByID: [UUID: AutohopCore.Subscription] = [:]

    func subscription(id: UUID) -> AutohopCore.Subscription? {
        subscriptionsByID[id]
    }

    func episodeRows(subscriptionID: UUID) -> [TVEpisodeRowModel] {
        episodeRowsBySubscription[subscriptionID] ?? []
    }
}

@MainActor
@Observable
final class TVQueueModel {
    var items: [QueueModel.ResolvedQueueItem] = []
    var episodes: [Episode] = []
    var rows: [TVQueueRowModel] = []
    var lastRenderedSnapshot: QueueSnapshot?
    // Local presentation overlay for a TV-originated Play Next request. The
    // row moves immediately, before CloudKit I/O, and remains pinned while an
    // older phone snapshot is still in flight. It is cleared only when the
    // authoritative phone snapshot confirms the same first episode.
    var pendingPlayNextEpisodeKey: String?
    /// Unpin commands are also presented immediately and held across stale
    /// snapshots until the phone republishes the entry with no pin state.
    var pendingUnpinEpisodeKeys: Set<String> = []

    // Compatibility indexes remain queue-owned because they reconcile queue
    // identities against a changing local catalogue.
    internal var legacyEpisodes: [String: Episode] = [:]
    internal var legacyPodcastTitles: [String: String] = [:]
    internal var uniqueEpisodesByGUID: [String: Episode] = [:]
    internal var uniqueEpisodesByNormalizedTitle: [String: Episode] = [:]
    internal var locallyArchivedEpisodeKeys: Set<String> = []
}

@MainActor
@Observable
final class TVContinueListeningModel {
    var item: TVContinueListening?
    internal var needsReload = true
    internal var cachedEntry: ListeningHistoryEntry?

    func invalidate() {
        needsReload = true
    }
}

@MainActor
@Observable
final class TVHistoryModel {
    var items: [TVHistoryItem] = []
    internal var needsReload = true

    func invalidate() {
        needsReload = true
    }
}
