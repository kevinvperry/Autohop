import Foundation

// AI CONTEXT — Compact, purgeable tvOS read projections. These deliberately
// exclude subscription settings, download state and sync authorship. tvOS can
// render its first frame from this cache while CloudKit refreshes authoritative
// state. The cache is an optimisation and may be deleted at any time.

public struct TVLibraryProjectionEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let author: String?
    public let artworkURL: URL?
    public let feedURL: URL
    public let priorityRank: Int

    public init(id: UUID, title: String, author: String?, artworkURL: URL?, feedURL: URL, priorityRank: Int) {
        self.id = id
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.feedURL = feedURL
        self.priorityRank = priorityRank
    }
}

public struct TVEpisodeProjection: Codable, Sendable, Equatable {
    public let subscriptionID: UUID
    public let updatedAt: Date
    public let episodes: [Episode]

    public init(subscriptionID: UUID, updatedAt: Date = Date(), episodes: [Episode]) {
        self.subscriptionID = subscriptionID
        self.updatedAt = updatedAt
        self.episodes = Array(episodes.prefix(25))
    }
}
