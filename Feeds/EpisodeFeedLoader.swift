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
    private struct Validator: Sendable { let etag: String?; let lastModified: String?; let data: Data }
    private var validators: [URL: Validator] = [:]
    private var validatorRecency: [URL] = []

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        PodcastUserAgent.configure(config)
        session = URLSession(configuration: config)
    }

    /// Fetches and parses the feed at `url`.  Pass `limit: nil` to load all episodes.
    public func fetch(feedURL: URL, limit: Int? = 50) async throws -> ParsedFeed {
        var request = URLRequest(url: feedURL)
        PodcastUserAgent.identify(&request)
        if let validator = validators[feedURL] {
            if let etag = validator.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = validator.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (receivedData, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 304,
           let cached = validators[feedURL]?.data {
            return try RSSParser().parse(data: cached, maxEpisodes: limit)
        }
        try HTTPResponseValidation.validate(response)
        let data = receivedData
        if let http = response as? HTTPURLResponse {
            validators[feedURL] = Validator(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                data: data
            )
            validatorRecency.removeAll { $0 == feedURL }
            validatorRecency.insert(feedURL, at: 0)
            for expired in validatorRecency.dropFirst(12) { validators[expired] = nil }
            validatorRecency = Array(validatorRecency.prefix(12))
        }
        return try RSSParser().parse(data: data, maxEpisodes: limit)
    }
}
