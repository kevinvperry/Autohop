import Foundation

protocol FeedServicing {
    func refresh(feedURL: URL, subscriptionID: UUID, episodeLimit: Int?) async throws -> FeedRefreshResult
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
        let (data, _) = try await withTimeout(seconds: requestTimeoutSeconds) {
            try await self.session.data(from: feedURL)
        }
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
