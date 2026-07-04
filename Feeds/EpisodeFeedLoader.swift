import Foundation

// AI CONTEXT — Feeds/EpisodeFeedLoader.swift
// Fetches a ParsedFeed directly from a URL without requiring a Subscription.
// Used by PodcastPreviewView so that "Load Older Episodes" never forces
// subscription creation. Ephemeral URLSession, 20 s timeout; limit nil = full
// episode history. Since tvOS Phase 4 (2026-07-04), `public` + part of
// AutohopCore (Package.swift) — TV/Views/TVSearchView.swift uses it to fetch
// the full feed of a search result before subscribing.

// PUBLIC since tvOS Phase 4 (§9 item 1): the TV Search tab uses this to fetch
// the full feed of a chosen search result before subscribing.
public actor EpisodeFeedLoader {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Fetches and parses the feed at `url`.  Pass `limit: nil` to load all episodes.
    public func fetch(feedURL: URL, limit: Int? = 50) async throws -> ParsedFeed {
        let (data, response) = try await session.data(from: feedURL)
        try HTTPResponseValidation.validate(response)
        return try RSSParser().parse(data: data, maxEpisodes: limit)
    }
}
