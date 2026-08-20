import Foundation
import AutohopCore

// AI CONTEXT — Pure conversion from resolved queue items into immutable tvOS
// rows. Phone-authored ordering is preserved exactly. Synced resume positions
// are injected as one bulk-read map so views remain persistence-free. Local
// archive suppression releases only when a newer phone snapshot contains it.
struct TVQueueProjector {
    static func archiveSuppressionsToRelease(
        authoredAtByEpisodeKey: [String: Date],
        authoritativeEpisodeKeys: Set<String>,
        snapshotUpdatedAt: Date
    ) -> Set<String> {
        Set(authoredAtByEpisodeKey.compactMap { key, authoredAt in
            snapshotUpdatedAt > authoredAt && authoritativeEpisodeKeys.contains(key) ? key : nil
        })
    }

    static func pinToFront(
        _ items: [QueueModel.ResolvedQueueItem],
        episodeKey: String?
    ) -> [QueueModel.ResolvedQueueItem] {
        guard let episodeKey,
              let index = items.firstIndex(where: { $0.episodeKey == episodeKey }),
              index > 0
        else { return items }
        var reordered = items
        var pinned = reordered.remove(at: index)
        pinned.pinState = .playNext
        reordered.insert(pinned, at: 0)
        return reordered
    }

    /// Removes the temporary/authoritative pin and restores the row to the
    /// same natural Priority Stack slot used by iPhone: remaining Play Next
    /// pins, normal rows by subscription priority then publication date, and
    /// Play Last pins. Stable source indexes resolve equal values.
    static func unpin(
        _ items: [QueueModel.ResolvedQueueItem],
        episodeKey: String,
        subscriptionsByID: [UUID: AutohopCore.Subscription]
    ) -> [QueueModel.ResolvedQueueItem] {
        guard let targetIndex = items.firstIndex(where: { $0.episodeKey == episodeKey }) else {
            return items
        }
        var normalized = items
        normalized[targetIndex].pinState = nil
        return normalized.enumerated().sorted { lhs, rhs in
            let leftTier = tier(lhs.element.pinState)
            let rightTier = tier(rhs.element.pinState)
            if leftTier != rightTier { return leftTier < rightTier }
            guard leftTier == 1 else { return lhs.offset < rhs.offset }
            let leftRank = subscriptionsByID[lhs.element.subscriptionID]?.priorityRank ?? .max
            let rightRank = subscriptionsByID[rhs.element.subscriptionID]?.priorityRank ?? .max
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDate = lhs.element.publishedAt ?? .distantPast
            let rightDate = rhs.element.publishedAt ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func tier(_ pinState: QueuePinState?) -> Int {
        switch pinState {
        case .playNext: return 0
        case nil: return 1
        case .playLast: return 2
        }
    }

    static func rows(
        from items: [QueueModel.ResolvedQueueItem],
        subscriptionsByID: [UUID: AutohopCore.Subscription],
        playbackPositionsByEpisodeKey: [String: TimeInterval] = [:]
    ) -> [TVQueueRowModel] {
        items.enumerated().map { index, item in
            TVQueueRowModel(
                id: item.episodeKey,
                subscriptionID: item.subscriptionID,
                position: index + 1,
                title: item.title,
                podcastTitle: item.podcastTitle
                    ?? item.episode.flatMap { subscriptionsByID[$0.subscriptionID]?.title }
                    ?? subscriptionsByID[item.subscriptionID]?.title
                    ?? "Podcast",
                artworkURL: item.episode?.artworkURL
                    ?? subscriptionsByID[item.subscriptionID]?.artworkURL,
                durationSeconds: item.episode?.durationSeconds,
                playbackPositionSeconds: playbackPositionsByEpisodeKey[item.episodeKey],
                mediaKind: item.episode?.mediaKind ?? .audio,
                episode: item.episode,
                pinState: item.pinState
            )
        }
    }
}
