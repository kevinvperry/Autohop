import Foundation

// AI CONTEXT — Feeds/FeedService.swift
// Network layer for fetching + parsing one RSS feed. Two entry points:
//  - refresh(): unconditional GET, full parse (manual pull-to-refresh). Sends no
//    validators, so a 304 can't legitimately occur; if a misbehaving server
//    returns one anyway it surfaces as FeedServiceError.unexpectedNotModified
//    (B7) rather than the old misleading .missingAudioEnclosure.
//  - refreshIfModified(): HTTP conditional GET using stored ETag/Last-Modified
//    (FeedValidators, persisted in Subscription.refreshStats) — the Release
//    Radar fast path; a 304 returns .notModified with zero parse cost.
// Converts ParsedFeed → FeedRefreshResult with Episode values; AppState then
// merges via SubscriptionStore. 25 s request timeout. Episode limit param
// caps parse work (50 for normal refresh, nil for full history load). Each
// synchronous parse/conversion runs inside an autorelease pool so Foundation/XML
// temporaries are reclaimed between feeds during large manual refresh cycles.
protocol FeedServicing {
    func refresh(feedURL: URL, subscriptionID: UUID, episodeLimit: Int?) async throws -> FeedRefreshResult
    func refreshIfModified(
        feedURL: URL,
        subscriptionID: UUID,
        episodeLimit: Int?,
        validators: FeedValidators?
    ) async throws -> FeedRefreshOutcome
}

/// HTTP cache validators carried between fetches of the same feed.
struct FeedValidators: Sendable, Equatable {
    var etag: String?
    var lastModified: String?
}

enum FeedRefreshOutcome {
    /// Server returned 304 — feed unchanged, nothing was downloaded or parsed.
    case notModified
    case updated(FeedRefreshResult, FeedValidators)
}

struct FeedRefreshResult {
    var subscriptionTitle: String
    var description: String?
    var author: String?
    var artworkURL: URL?
    var categories: [String]
    var isExplicit: Bool?
    var latestEpisode: Episode
    var episodes: [Episode]
}

final class FeedService: FeedServicing {
    private let chapterService: ChapterServicing
    private let parser: RSSParser
    private let session: URLSession
    private let requestTimeoutSeconds: TimeInterval

    init(
        chapterService: ChapterServicing,
        parser: RSSParser = RSSParser(),
        session: URLSession? = nil,
        requestTimeoutSeconds: TimeInterval = 25
    ) {
        self.chapterService = chapterService
        self.parser = parser
        self.requestTimeoutSeconds = requestTimeoutSeconds
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = requestTimeoutSeconds
            configuration.timeoutIntervalForResource = requestTimeoutSeconds + 5
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func refresh(feedURL: URL, subscriptionID: UUID, episodeLimit: Int? = 50) async throws -> FeedRefreshResult {
        switch try await refreshIfModified(
            feedURL: feedURL,
            subscriptionID: subscriptionID,
            episodeLimit: episodeLimit,
            validators: nil
        ) {
        case .notModified:
            // Can't happen without validators, but a misbehaving server could
            // send 304 anyway — surface it distinctly rather than as a misleading
            // missing-enclosure error.
            throw FeedServiceError.unexpectedNotModified
        case .updated(let result, _):
            return result
        }
    }

    func refreshIfModified(
        feedURL: URL,
        subscriptionID: UUID,
        episodeLimit: Int? = 50,
        validators: FeedValidators?
    ) async throws -> FeedRefreshOutcome {
        var request = URLRequest(url: feedURL)
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await withTimeout(seconds: requestTimeoutSeconds) {
            try await self.session.data(for: request)
        }

        var newValidators = FeedValidators()
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304 {
                return .notModified
            }
            // Reject error responses (404/500/captive-portal HTML, etc.) instead of parsing the
            // body as a feed. 304 is handled above; everything else must be a success status.
            try HTTPResponseValidation.validate(http)
            newValidators.etag = http.value(forHTTPHeaderField: "ETag")
            newValidators.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        }

        let result = try parseResult(data: data, subscriptionID: subscriptionID, episodeLimit: episodeLimit)
        return .updated(result, newValidators)
    }

    private func parseResult(data: Data, subscriptionID: UUID, episodeLimit: Int?) throws -> FeedRefreshResult {
        try autoreleasepool {
            let parsedFeed = try parser.parse(data: data, maxEpisodes: episodeLimit)

            let playableEpisodes = parsedFeed.episodes.compactMap { parsedEpisode -> Episode? in
                guard let audioURL = parsedEpisode.audioURL else { return nil }
                return Self.episode(from: parsedEpisode, subscriptionID: subscriptionID, audioURL: audioURL, feedArtworkURL: parsedFeed.artworkURL)
            }

            guard let latestEpisode = playableEpisodes.first else {
                throw FeedServiceError.missingAudioEnclosure
            }

            return FeedRefreshResult(
                subscriptionTitle: parsedFeed.title,
                description: parsedFeed.description,
                author: parsedFeed.author,
                artworkURL: parsedFeed.artworkURL,
                categories: parsedFeed.categories,
                isExplicit: parsedFeed.isExplicit,
                latestEpisode: latestEpisode,
                episodes: playableEpisodes
            )
        }
    }

    private static func episode(
        from parsedEpisode: ParsedEpisode,
        subscriptionID: UUID,
        audioURL: URL,
        feedArtworkURL: URL?
    ) -> Episode {
        let episodeID = UUID()
        let chapters = parsedEpisode.chapters.map { p in
            Chapter(
                id: UUID(),
                episodeID: episodeID,
                position: p.position,
                title: p.title,
                startSeconds: p.startSeconds,
                durationSeconds: p.durationSeconds,
                source: p.source
            )
        }

        var episode = Episode(
            id: episodeID,
            subscriptionID: subscriptionID,
            guid: parsedEpisode.guid,
            title: parsedEpisode.title,
            audioURL: audioURL,
            mediaKind: parsedEpisode.mediaKind,
            chapters: chapters
        )
        episode.description = parsedEpisode.description
        episode.subtitle = parsedEpisode.subtitle
        episode.author = parsedEpisode.author
        episode.publishedAt = parsedEpisode.publishedAt
        episode.durationSeconds = parsedEpisode.durationSeconds
        episode.artworkURL = parsedEpisode.artworkURL ?? feedArtworkURL
        episode.fileSizeBytes = parsedEpisode.fileSizeBytes
        episode.isExplicit = parsedEpisode.isExplicit
        episode.externalChaptersURL = parsedEpisode.externalChaptersURL
        episode.episodeLink = parsedEpisode.episodeLink
        return episode
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw FeedServiceError.timedOut
            }

            guard let result = try await group.next() else {
                throw FeedServiceError.timedOut
            }
            group.cancelAll()
            return result
        }
    }
}

enum FeedServiceError: Error {
    case invalidFeed
    case missingAudioEnclosure
    case timedOut
    /// A server returned 304 Not Modified even though `refresh()` sent no
    /// validators (so it can't legitimately happen) — surfaced distinctly rather
    /// than as a misleading `missingAudioEnclosure`.
    case unexpectedNotModified
}
