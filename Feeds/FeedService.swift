import Foundation

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
            // send 304 anyway — surface it as an empty-feed failure.
            throw FeedServiceError.missingAudioEnclosure
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
            newValidators.etag = http.value(forHTTPHeaderField: "ETag")
            newValidators.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        }

        let result = try parseResult(data: data, subscriptionID: subscriptionID, episodeLimit: episodeLimit)
        return .updated(result, newValidators)
    }

    private func parseResult(data: Data, subscriptionID: UUID, episodeLimit: Int?) throws -> FeedRefreshResult {
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
}
