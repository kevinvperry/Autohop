import Foundation
import AutohopCore

// AI CONTEXT — Pure, bounded conversion from the tvOS Home presentation into
// the privacy-minimal Top Shelf schema. A live Currently Playing item owns the
// first slot regardless of queue rank, falling back to Continue Listening only
// while idle. Queue order is preserved and identities are deduplicated. This
// pure boundary never reads persistence or performs artwork/network work.

struct TVTopShelfNowPlaying: Equatable {
    let episode: Episode
    let podcastTitle: String
    let positionSeconds: TimeInterval
}

struct TVTopShelfSnapshotCandidate: Equatable {
    struct Item: Equatable {
        let stableID: String
        let subscriptionID: UUID
        let episodeKey: String
        let episodeTitle: String
        let podcastTitle: String
        let artworkURL: URL?
        let playbackProgress: Double?
        let expiresAt: Date?
    }

    struct Section: Equatable {
        let kind: TVTopShelfSectionKind
        let title: String
        let items: [Item]
    }

    let sections: [Section]
}

enum TVTopShelfSnapshotBuilder {
    static func build(
        nowPlaying: TVTopShelfNowPlaying? = nil,
        continueListening: TVContinueListening?,
        queueRows: [TVQueueRowModel],
        now: Date = Date()
    ) -> TVTopShelfSnapshotCandidate? {
        var sections: [TVTopShelfSnapshotCandidate.Section] = []
        var featuredKey: String?

        if let nowPlaying,
           let item = nowPlayingItem(nowPlaying) {
            featuredKey = item.episodeKey
            sections.append(.init(
                kind: .currentlyPlaying,
                title: nowPlaying.episode.mediaKind == .video ? "Currently Watching" : "Currently Playing",
                items: [item]
            ))
        } else if let continuation = continueListening,
           let episode = continuation.episode,
           let item = continueItem(continuation, episode: episode, now: now) {
            featuredKey = item.episodeKey
            sections.append(.init(
                kind: .continueListening,
                title: episode.mediaKind == .video ? "Continue Watching" : "Continue Listening",
                items: [item]
            ))
        }

        let remainingCapacity = TVTopShelfSnapshot.maximumItems
            - sections.reduce(0) { $0 + $1.items.count }
        let queueItems = queueRows.lazy
            .filter { $0.isPlayable && $0.id != featuredKey }
            .prefix(max(0, remainingCapacity))
            .map { row in
                TVTopShelfSnapshotCandidate.Item(
                    stableID: stableID(subscriptionID: row.subscriptionID, episodeKey: row.id),
                    subscriptionID: row.subscriptionID,
                    episodeKey: row.id,
                    episodeTitle: sanitized(row.title, fallback: "Episode", maximum: 500),
                    podcastTitle: sanitized(row.podcastTitle, fallback: "Podcast", maximum: 300),
                    artworkURL: row.artworkURL,
                    playbackProgress: progress(
                        position: row.playbackPositionSeconds,
                        duration: row.durationSeconds
                    ),
                    expiresAt: nil
                )
            }
        if !queueItems.isEmpty {
            sections.append(.init(kind: .upNext, title: "Up Next", items: Array(queueItems)))
        }
        return sections.isEmpty ? nil : .init(sections: sections)
    }

    private static func nowPlayingItem(
        _ nowPlaying: TVTopShelfNowPlaying
    ) -> TVTopShelfSnapshotCandidate.Item? {
        let episode = nowPlaying.episode
        let key = PlaybackPositionStore.key(for: episode)
        return .init(
            stableID: stableID(subscriptionID: episode.subscriptionID, episodeKey: key),
            subscriptionID: episode.subscriptionID,
            episodeKey: key,
            episodeTitle: sanitized(episode.title, fallback: "Episode", maximum: 500),
            podcastTitle: sanitized(nowPlaying.podcastTitle, fallback: "Podcast", maximum: 300),
            artworkURL: episode.artworkURL,
            playbackProgress: progress(position: nowPlaying.positionSeconds, duration: episode.durationSeconds),
            expiresAt: nil
        )
    }

    private static func continueItem(
        _ continuation: TVContinueListening,
        episode: Episode,
        now: Date
    ) -> TVTopShelfSnapshotCandidate.Item? {
        let entry = continuation.entry
        let duration = entry.durationSeconds ?? entry.episodeDurationSeconds ?? episode.durationSeconds
        guard entry.status == .listened,
              entry.lastPositionSeconds >= 60,
              let duration, duration.isFinite, duration > 0,
              duration - entry.lastPositionSeconds > 60
        else { return nil }
        let key = PlaybackPositionStore.key(for: episode)
        return .init(
            stableID: stableID(subscriptionID: episode.subscriptionID, episodeKey: key),
            subscriptionID: episode.subscriptionID,
            episodeKey: key,
            episodeTitle: sanitized(entry.episodeTitle, fallback: episode.title, maximum: 500),
            podcastTitle: sanitized(entry.podcastTitle, fallback: "Podcast", maximum: 300),
            artworkURL: episode.artworkURL ?? entry.artworkURL,
            playbackProgress: min(max(entry.lastPositionSeconds / duration, 0), 1),
            expiresAt: now.addingTimeInterval(TVTopShelfSnapshot.freshnessInterval)
        )
    }

    static func stableID(subscriptionID: UUID, episodeKey: String) -> String {
        let value = subscriptionID.uuidString + "|" + episodeKey
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func progress(position: TimeInterval?, duration: TimeInterval?) -> Double? {
        guard let position, position.isFinite, position > 0,
              let duration, duration.isFinite, duration > 0
        else { return nil }
        return min(max(position / duration, 0), 1)
    }

    private static func sanitized(_ value: String, fallback: String, maximum: Int) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? fallback : clean).prefix(maximum))
    }
}
