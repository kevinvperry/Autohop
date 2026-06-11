import Foundation

// AI CONTEXT — Feeds/EpisodeFeedLoader.swift
// Fetches a ParsedFeed directly from a URL without requiring a Subscription.
// Used by PodcastPreviewView so that "Load Older Episodes" never forces
// subscription creation. Ephemeral URLSession, 20 s timeout; limit nil = full
// episode history.

actor EpisodeFeedLoader {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Fetches and parses the feed at `url`.  Pass `limit: nil` to load all episodes.
    func fetch(feedURL: URL, limit: Int? = 50) async throws -> ParsedFeed {
        let (data, _) = try await session.data(from: feedURL)
        return try RSSParser().parse(data: data, maxEpisodes: limit)
    }
}
