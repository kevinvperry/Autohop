import Foundation
import AutohopCore

// AI CONTEXT — Phase 4 immutable TV render projections. Views consume these
// stable, compact values instead of traversing Subscription graphs or reading
// persistence during Siri Remote focus updates. Episode is retained only as an
// action payload; playbackPositionSeconds is projected once from synced history.
// TVHomeQueueProjector is the single presentation-only exclusion boundary for
// hero episodes: it never mutates the phone-authored queue snapshot.

struct TVQueueRowModel: Identifiable, Equatable {
    let id: String
    let subscriptionID: UUID
    let position: Int
    let title: String
    let podcastTitle: String
    let artworkURL: URL?
    let durationSeconds: TimeInterval?
    let playbackPositionSeconds: TimeInterval?
    let mediaKind: EpisodeMediaKind
    let episode: Episode?
    let pinState: QueuePinState?

    var isPlayable: Bool { episode != nil }
    var isPinned: Bool { pinState != nil }

    /// Mirrors iOS Up Next: show remaining time only for a genuinely partial
    /// episode; otherwise the view falls back to total runtime.
    var remainingSeconds: TimeInterval? {
        guard let position = playbackPositionSeconds,
              position.isFinite, position > 0,
              let duration = durationSeconds,
              duration.isFinite, duration > position
        else { return nil }
        return duration - position
    }
}

enum TVHomeQueueProjector {
    static func rows(
        queueRows: [TVQueueRowModel],
        currentEpisode: Episode?,
        continueListening: TVContinueListening?
    ) -> [TVQueueRowModel] {
        let featuredKeys: Set<String>
        if let currentEpisode {
            featuredKeys = [PlaybackPositionStore.key(for: currentEpisode)]
        } else if let continuation = continueListening {
            var keys = Set([continuation.entry.id])
            if let episode = continuation.episode {
                keys.insert(PlaybackPositionStore.key(for: episode))
            }
            featuredKeys = keys
        } else {
            featuredKeys = []
        }

        return queueRows.filter { row in
            guard !featuredKeys.contains(row.id) else { return false }
            if let currentEpisode, let episode = row.episode,
               episode.id == currentEpisode.id {
                return false
            }
            return true
        }
    }
}

struct TVPodcastTileModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String?
    let artworkURL: URL?
    let feedURL: URL
    let priorityRank: Int
    /// True when iCloud supplied the subscription identity but tvOS has not
    /// yet completed its RSS materialisation. The Library keeps this durable
    /// placeholder visible instead of silently dropping the podcast.
    let isMaterializing: Bool
}

struct TVEpisodeRowModel: Identifiable, Equatable {
    let episode: Episode
    var id: UUID { episode.id }
}

enum TVSyncStatus: Equatable {
    case upToDate(Date, generation: Int64)
    case updating
    case cached(Date, generation: Int64)
    case unavailable
    case failed(Date?)

    var label: String {
        switch self {
        case .upToDate: return "Up to date"
        case .updating: return "Updating from iCloud…"
        case .cached(let date, _): return "Cached · updated \(date.formatted(.relative(presentation: .named)))"
        case .unavailable: return "iCloud unavailable"
        case .failed: return "Update failed — try again"
        }
    }
}
