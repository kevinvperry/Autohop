import Foundation

// AI CONTEXT — Feeds/ParsedFeed.swift
// Intermediate value types produced by RSSParser — feed-shaped data BEFORE it
// becomes a Subscription/Episode (no UUIDs, no local state). SubscriptionStore
// and FeedService convert these into model types; PodcastDetailView renders them
// directly for not-yet-subscribed (browse-preview) podcasts.
// Also hosts the shared HTTPResponseValidation gate (see bottom of file) — placed
// here because this file is compiled by BOTH the SwiftPM AutohopCore target and
// the Xcode app target, so it needs no XcodeGen regeneration.
public struct ParsedFeed: Equatable {
    public var title: String
    public var description: String?
    public var author: String?
    public var artworkURL: URL?
    public var categories: [String]
    public var isExplicit: Bool?
    public var latestEpisode: ParsedEpisode?
    public var episodes: [ParsedEpisode]

    public init(title: String, description: String? = nil, author: String?, artworkURL: URL?, categories: [String] = [], isExplicit: Bool? = nil, latestEpisode: ParsedEpisode?, episodes: [ParsedEpisode]? = nil) {
        self.title = title
        self.description = description
        self.author = author
        self.artworkURL = artworkURL
        self.categories = categories
        self.isExplicit = isExplicit
        self.latestEpisode = latestEpisode
        self.episodes = episodes ?? latestEpisode.map { [$0] } ?? []
    }
}

public struct ParsedEpisode: Equatable {
    public var guid: String
    public var title: String
    public var description: String?
    public var subtitle: String?
    public var author: String?
    public var publishedAt: Date?
    public var durationSeconds: TimeInterval?
    public var audioURL: URL?
    /// Canonical episode web page (RSS `<item><link>`), for sharing.
    public var episodeLink: URL?
    public var mediaKind: EpisodeMediaKind
    public var artworkURL: URL?
    public var fileSizeBytes: Int64?
    public var isExplicit: Bool?
    public var chapters: [ParsedChapter]
    public var externalChaptersURL: URL?

    public init(
        guid: String,
        title: String,
        description: String?,
        subtitle: String?,
        author: String?,
        publishedAt: Date?,
        durationSeconds: TimeInterval?,
        audioURL: URL?,
        episodeLink: URL? = nil,
        mediaKind: EpisodeMediaKind = .audio,
        artworkURL: URL?,
        fileSizeBytes: Int64?,
        isExplicit: Bool?,
        chapters: [ParsedChapter],
        externalChaptersURL: URL?
    ) {
        self.guid = guid
        self.title = title
        self.description = description
        self.subtitle = subtitle
        self.author = author
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.audioURL = audioURL
        self.episodeLink = episodeLink
        self.mediaKind = mediaKind
        self.artworkURL = artworkURL
        self.fileSizeBytes = fileSizeBytes
        self.isExplicit = isExplicit
        self.chapters = chapters
        self.externalChaptersURL = externalChaptersURL
    }
}

public struct ParsedChapter: Equatable {
    public var position: Int
    public var title: String
    public var startSeconds: TimeInterval
    public var durationSeconds: TimeInterval?
    public var source: ChapterSource

    public init(position: Int, title: String, startSeconds: TimeInterval, durationSeconds: TimeInterval?, source: ChapterSource) {
        self.position = position
        self.title = title
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.source = source
    }
}

// MARK: - Shared HTTP response gate
// Lives here (an existing file compiled by BOTH the SwiftPM AutohopCore target and the Xcode app
// target) rather than in its own file, so it needs no XcodeGen regeneration to be picked up. Used
// by the network clients (feed refresh, iTunes search/charts/lookup, preview feed, external
// chapters, notification artwork) which previously parsed/attached any body regardless of status.

public enum HTTPResponseError: Error, Equatable {
    /// A non-success HTTP status was returned (e.g. 404, 500).
    case unacceptableStatus(Int)
}

public enum HTTPResponseValidation {
    /// Throws `HTTPResponseError.unacceptableStatus` when `response` is a non-success HTTP
    /// response. `304 Not Modified` is accepted so conditional-GET callers can handle it
    /// themselves. A non-HTTP response (no `HTTPURLResponse`) passes — there is nothing to check.
    public static func validate(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 304 { return }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPResponseError.unacceptableStatus(http.statusCode)
        }
    }

    /// Convenience for `try?`-style call sites: returns `true` when the response is acceptable.
    public static func isAcceptable(_ response: URLResponse?) -> Bool {
        (try? validate(response)) != nil
    }
}
