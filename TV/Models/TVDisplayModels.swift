import Foundation
import AutohopCore

// AI CONTEXT — Phase 4 immutable TV render projections. Views consume these
// stable, compact values instead of traversing Subscription graphs during Siri
// Remote focus updates. Episode is retained only as an action payload.

struct TVQueueRowModel: Identifiable, Equatable {
    let id: String
    let subscriptionID: UUID
    let position: Int
    let title: String
    let podcastTitle: String
    let artworkURL: URL?
    let durationSeconds: TimeInterval?
    let mediaKind: EpisodeMediaKind
    let episode: Episode?
    let pinState: QueuePinState?

    var isPlayable: Bool { episode != nil }
    var isPinned: Bool { pinState != nil }
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
