import Foundation

// AI CONTEXT — Models/Chapter.swift
// Value type for one episode chapter. `position` is the 0-based slot index —
// the key ChapterFilter uses to disable chapters across all future episodes
// of a podcast. `source` records where the chapter came from (embedded ID3/
// MP4 metadata vs. external PodcastIndex JSON). Skipping logic lives in
// ChapterService + PlaybackEngine, not here.
public struct Chapter: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var episodeID: UUID?
    public var position: Int
    public var title: String
    public var startSeconds: TimeInterval
    public var durationSeconds: TimeInterval?
    public var artworkURL: URL?
    public var source: ChapterSource

    public init(
        id: UUID = UUID(),
        episodeID: UUID? = nil,
        position: Int,
        title: String,
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval? = nil,
        artworkURL: URL? = nil,
        source: ChapterSource
    ) {
        self.id = id
        self.episodeID = episodeID
        self.position = position
        self.title = title
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
        self.source = source
    }
}

public enum ChapterSource: String, Codable, Sendable {
    case pscChapters
    case podcastChaptersJSON
    case appleEmbedded
    case plainTextFallback
}

public struct ChapterFilter: Equatable, Codable, Sendable {
    public var skippedPositions: Set<Int>

    public init(skippedPositions: Set<Int> = []) {
        self.skippedPositions = skippedPositions
    }

    public func allows(position: Int) -> Bool {
        !skippedPositions.contains(position)
    }
}
