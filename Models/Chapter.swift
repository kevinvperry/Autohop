import Foundation

public struct Chapter: Identifiable, Equatable, Codable {
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

public enum ChapterSource: String, Codable {
    case pscChapters
    case podcastChaptersJSON
    case appleEmbedded
    case plainTextFallback
}

public struct ChapterFilter: Equatable, Codable {
    public var skippedPositions: Set<Int>

    public init(skippedPositions: Set<Int> = []) {
        self.skippedPositions = skippedPositions
    }

    public func allows(position: Int) -> Bool {
        !skippedPositions.contains(position)
    }
}
