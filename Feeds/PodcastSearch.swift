import Foundation

// AI CONTEXT — Feeds/PodcastSearch.swift
// Storefront-aware iTunes Search API clients for the dedicated iOS Search page
// and browse-only tvOS Search. Shows and episodes deliberately use independent
// providers and requests: `entity=podcast` and `entity=podcastEpisode` have
// different schemas, ranking and failure boundaries. Every request supplies
// the two-letter Discover storefront; Apple's undocumented default is the US
// store and must never silently override the user's selected storefront.
// Results lacking a feedUrl are dropped because Autohop can only open or
// subscribe to public RSS podcasts. Search uses a 400 ms debounce. Since tvOS
// Phase 4 (2026-07-04),
// `PodcastSearchResult`/`PodcastSearchService` are `public` and part of
// AutohopCore (Package.swift) — verified Foundation-only, no UIKit — so
// TV/Views/TVSearchView.swift can consume them directly as a library import.
// Keep this file UIKit-free; the ViewModels below (iOS-only consumers) stay
// internal, they just happen to live in the same file.
// `ApplePodcastsReviewResolver` is the iOS-family bridge from Autohop's
// RSS-owned show identity to Apple's catalogue. It accepts a known Apple show
// ID when Search already supplied one; legacy/manual subscriptions are resolved
// by title and then require an exact normalized feed-URL match. Never open a
// fuzzy title-only match: sending a listener to the wrong show's review page is
// worse than withholding the action.

// MARK: - Model

// PUBLIC since tvOS Phase 4 (§9 item 1): the TV Search tab consumes this
// service directly (AutohopCore is a library import there, unlike iOS's
// direct-compile target — access levels matter). Read-only consumption
// doesn't need a public memberwise init (results are only ever returned by
// `search`, never constructed fresh outside this file).
public struct PodcastSearchResult: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let author: String
    public let feedURL: URL
    public let artworkURL: URL?
    public let episodeCount: Int
    public let genre: String

    public init(
        id: Int,
        title: String,
        author: String,
        feedURL: URL,
        artworkURL: URL?,
        episodeCount: Int,
        genre: String
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.episodeCount = episodeCount
        self.genre = genre
    }
}

public struct PodcastEpisodeSearchResult: Identifiable, Hashable, Sendable {
    public let id: Int
    public let podcastID: Int
    public let title: String
    public let podcastTitle: String
    public let publisher: String
    public let feedURL: URL
    public let artworkURL: URL?
    public let releaseDate: Date?
    public let duration: TimeInterval?
    public let genre: String
    public let episodeGUID: String?

    public init(
        id: Int,
        podcastID: Int,
        title: String,
        podcastTitle: String,
        publisher: String,
        feedURL: URL,
        artworkURL: URL?,
        releaseDate: Date?,
        duration: TimeInterval?,
        genre: String,
        episodeGUID: String? = nil
    ) {
        self.id = id
        self.podcastID = podcastID
        self.title = title
        self.podcastTitle = podcastTitle
        self.publisher = publisher
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.releaseDate = releaseDate
        self.duration = duration
        self.genre = genre
        self.episodeGUID = episodeGUID
    }

    /// Episode selection currently opens the parent show at its episode list.
    /// A later search phase can deep-link to an exact episode after feed GUID
    /// reconciliation is added; do not guess identity from an Apple track ID.
    public var parentPodcast: PodcastSearchResult {
        PodcastSearchResult(
            id: podcastID,
            title: podcastTitle,
            author: publisher,
            feedURL: feedURL,
            artworkURL: artworkURL,
            episodeCount: 0,
            genre: genre
        )
    }
}

enum PodcastEpisodeSearchRanking {
    /// Apple supplies a relevance-ordered candidate set. Autohop makes that
    /// ordering explicit and stable: strong phrase/title/show matches form
    /// accuracy tiers, publication date orders results only inside a tier, and
    /// Apple's original order breaks any remaining tie.
    static func ordered(
        _ results: [PodcastEpisodeSearchResult],
        query: String
    ) -> [PodcastEpisodeSearchResult] {
        results.enumerated().sorted { lhs, rhs in
            let lhsScore = accuracyScore(lhs.element, query: query)
            let rhsScore = accuracyScore(rhs.element, query: query)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsDate = lhs.element.releaseDate ?? .distantPast
            let rhsDate = rhs.element.releaseDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func accuracyScore(_ result: PodcastEpisodeSearchResult, query: String) -> Int {
        let phrase = normalized(query)
        guard !phrase.isEmpty else { return 0 }
        let title = normalized(result.title)
        let show = normalized(result.podcastTitle)
        let publisher = normalized(result.publisher)
        let tokens = phrase.split(separator: " ").map(String.init)

        var score = 0
        if title == phrase { score += 10_000 }
        else if title.hasPrefix(phrase) { score += 9_000 }
        else if title.contains(phrase) { score += 8_000 }

        if show == phrase { score += 7_500 }
        else if show.hasPrefix(phrase) { score += 7_000 }
        else if show.contains(phrase) { score += 6_500 }

        score += tokens.reduce(into: 0) { partial, token in
            if title.contains(token) { partial += 500 }
            if show.contains(token) { partial += 250 }
            if publisher.contains(token) { partial += 100 }
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum PodcastEpisodeReconciliation {
    /// Resolves an Apple catalog episode into the RSS-owned local model without
    /// equating Apple track IDs to RSS identity. GUID is authoritative when
    /// available; exact normalized title is the deliberately narrow fallback.
    static func matchingEpisode(
        result: PodcastEpisodeSearchResult,
        in subscription: Subscription
    ) -> Episode? {
        if let guid = result.episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !guid.isEmpty,
           let match = subscription.episodes.first(where: {
               $0.guid.trimmingCharacters(in: .whitespacesAndNewlines)
                   .localizedCaseInsensitiveCompare(guid) == .orderedSame
           }) {
            return match
        }

        let wantedTitle = PodcastCreatorGrouping.normalized(result.title)
        let titleMatches = subscription.episodes.filter {
            PodcastCreatorGrouping.normalized($0.title) == wantedTitle
        }
        guard !titleMatches.isEmpty else { return nil }
        guard let releaseDate = result.releaseDate else { return titleMatches.first }
        return titleMatches.min {
            abs(($0.publishedAt ?? .distantPast).timeIntervalSince(releaseDate)) <
            abs(($1.publishedAt ?? .distantPast).timeIntervalSince(releaseDate))
        }
    }
}

// MARK: - Local library search and conservative creator derivation

/// A locally known episode search hit. UUID identity is preserved so opening a
/// result always routes back to the owning on-device subscription; Apple track
/// identifiers are deliberately not guessed or reconciled here.
struct PodcastLibraryEpisodeSearchResult: Identifiable, Hashable, Sendable {
    let id: UUID
    let subscriptionID: UUID
    let title: String
    let podcastTitle: String
    let artworkURL: URL?
    let releaseDate: Date?
    let duration: TimeInterval?
}

struct PodcastLibrarySearchResults: Sendable {
    let shows: [Subscription]
    let episodes: [PodcastLibraryEpisodeSearchResult]
}

/// Publisher/creator groups are derived only from an exact, cleaned author
/// metadata value. This is intentionally not a people extractor: episode
/// descriptions, titles and inferred guests must not create identity claims.
struct PodcastCreatorGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let shows: [PodcastSearchResult]
}

enum PodcastCreatorGrouping {
    static func groups(from shows: [PodcastSearchResult], query: String) -> [PodcastCreatorGroup] {
        let grouped = Dictionary(grouping: shows.compactMap { show -> (String, String, PodcastSearchResult)? in
            guard let author = acceptedAuthor(show.author) else { return nil }
            return (normalized(author), author, show)
        }, by: { $0.0 })

        let phrase = normalized(query)
        return grouped.compactMap { key, values in
            guard let first = values.first else { return nil }
            let deduplicated = Dictionary(grouping: values.map(\.2), by: \.feedURL)
                .compactMap { $0.value.first }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return PodcastCreatorGroup(id: key, name: first.1, shows: deduplicated)
        }.sorted { lhs, rhs in
            let lhsMatch = normalized(lhs.name).contains(phrase)
            let rhsMatch = normalized(rhs.name).contains(phrase)
            if lhsMatch != rhsMatch { return lhsMatch }
            if lhs.shows.count != rhs.shows.count { return lhs.shows.count > rhs.shows.count }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func acceptedAuthor(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(value.count),
              !value.contains("@"),
              !value.localizedCaseInsensitiveContains("http://"),
              !value.localizedCaseInsensitiveContains("https://") else { return nil }
        let rejected: Set<String> = ["unknown", "n/a", "na", "various", "various artists"]
        guard !rejected.contains(normalized(value)) else { return nil }
        return value
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum PodcastLibrarySearch {
    static func search(_ subscriptions: [Subscription], query: String) -> PodcastLibrarySearchResults {
        let phrase = PodcastCreatorGrouping.normalized(query)
        guard !phrase.isEmpty else { return PodcastLibrarySearchResults(shows: [], episodes: []) }
        let tokens = phrase.split(separator: " ").map(String.init)
        let library = subscriptions.filter { $0.browseDate == nil }

        let shows = library.compactMap { subscription -> (Subscription, Int)? in
            let title = PodcastCreatorGrouping.normalized(subscription.title)
            let author = PodcastCreatorGrouping.normalized(subscription.author ?? "")
            let description = PodcastCreatorGrouping.normalized(subscription.description ?? "")
            let categories = PodcastCreatorGrouping.normalized(subscription.categories.joined(separator: " "))
            let score = matchScore(
                phrase: phrase,
                tokens: tokens,
                primary: title,
                secondary: [author, categories, description]
            )
            return score > 0 ? (subscription, score) : nil
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }.prefix(25).map(\.0)

        let episodes = library.flatMap { subscription in
            subscription.episodes.compactMap { episode -> (PodcastLibraryEpisodeSearchResult, Int)? in
                let title = PodcastCreatorGrouping.normalized(episode.title)
                let secondary = [
                    episode.subtitle,
                    episode.author,
                    episode.description,
                    subscription.title,
                    subscription.author,
                ].map { PodcastCreatorGrouping.normalized($0 ?? "") }
                let score = matchScore(phrase: phrase, tokens: tokens, primary: title, secondary: secondary)
                guard score > 0 else { return nil }
                return (
                    PodcastLibraryEpisodeSearchResult(
                        id: episode.id,
                        subscriptionID: subscription.id,
                        title: episode.title,
                        podcastTitle: subscription.title,
                        artworkURL: episode.artworkURL ?? subscription.artworkURL,
                        releaseDate: episode.publishedAt,
                        duration: episode.durationSeconds
                    ),
                    score
                )
            }
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let lhsDate = lhs.0.releaseDate ?? .distantPast
            let rhsDate = rhs.0.releaseDate ?? .distantPast
            return lhsDate > rhsDate
        }.prefix(50).map(\.0)

        return PodcastLibrarySearchResults(shows: shows, episodes: episodes)
    }

    static func creatorGroups(from subscriptions: [Subscription], query: String) -> [PodcastCreatorGroup] {
        let shows = subscriptions.filter { $0.browseDate == nil }.map { subscription in
            PodcastSearchResult(
                id: subscription.feedURL.absoluteString.hashValue,
                title: subscription.title,
                author: subscription.author ?? "",
                feedURL: subscription.feedURL,
                artworkURL: subscription.artworkURL,
                episodeCount: subscription.episodes.count,
                genre: subscription.categories.first ?? ""
            )
        }
        let phrase = PodcastCreatorGrouping.normalized(query)
        return PodcastCreatorGrouping.groups(from: shows, query: query).filter { group in
            PodcastCreatorGrouping.normalized(group.name).contains(phrase) ||
            group.shows.contains { PodcastCreatorGrouping.normalized($0.title).contains(phrase) }
        }
    }

    private static func matchScore(
        phrase: String,
        tokens: [String],
        primary: String,
        secondary: [String]
    ) -> Int {
        var score = 0
        if primary == phrase { score += 10_000 }
        else if primary.hasPrefix(phrase) { score += 9_000 }
        else if primary.contains(phrase) { score += 8_000 }
        for value in secondary {
            if value == phrase { score += 6_000 }
            else if value.hasPrefix(phrase) { score += 5_000 }
            else if value.contains(phrase) { score += 4_000 }
        }
        score += tokens.reduce(into: 0) { partial, token in
            if primary.contains(token) { partial += 300 }
            partial += secondary.filter { $0.contains(token) }.count * 100
        }
        return score
    }
}

// MARK: - Service

public enum PodcastSearchStorefront {
    /// Normalises a Discover/device storefront into the ISO alpha-2 value the
    /// iTunes Search API requires. Invalid persisted values fall back to the
    /// current device region, then AU for Autohop's primary market.
    public static func normalized(_ candidate: String?) -> String {
        let supplied = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if supplied.count == 2, supplied.allSatisfy(\.isLetter) { return supplied }
        let device = Locale.current.region?.identifier.lowercased() ?? ""
        if device.count == 2, device.allSatisfy(\.isLetter) { return device }
        return "au"
    }
}

private func podcastSearchSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.waitsForConnectivity = false
    PodcastUserAgent.configure(config)
    return URLSession(configuration: config)
}

enum PodcastSearchRequest {
    static func url(query: String, countryCode: String, entity: String, limit: Int) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "country", value: PodcastSearchStorefront.normalized(countryCode)),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        return components.url!
    }
}

public actor PodcastShowSearchProvider {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? podcastSearchSession()
    }

    public func search(query: String, countryCode: String, limit: Int = 25) async throws -> [PodcastSearchResult] {
        let url = PodcastSearchRequest.url(query: query, countryCode: countryCode, entity: "podcast", limit: limit)
        let (data, httpResponse) = try await session.data(from: url)
        try HTTPResponseValidation.validate(httpResponse)
        let response = try JSONDecoder().decode(iTunesShowSearchResponse.self, from: data)
        let results: [PodcastSearchResult] = response.results.compactMap { raw -> PodcastSearchResult? in
            guard let feedString = raw.feedUrl, let feedURL = URL(string: feedString) else { return nil }
            return PodcastSearchResult(
                id: raw.trackId,
                title: raw.trackName,
                author: raw.artistName,
                feedURL: feedURL,
                artworkURL: raw.artworkUrl600.flatMap(URL.init),
                episodeCount: raw.trackCount ?? 0,
                genre: raw.primaryGenreName ?? ""
            )
        }
        return results
    }
}

public actor PodcastEpisodeSearchProvider {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? podcastSearchSession()
    }

    public func search(query: String, countryCode: String, limit: Int = 25) async throws -> [PodcastEpisodeSearchResult] {
        let url = PodcastSearchRequest.url(query: query, countryCode: countryCode, entity: "podcastEpisode", limit: limit)
        let (data, httpResponse) = try await session.data(from: url)
        try HTTPResponseValidation.validate(httpResponse)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(iTunesEpisodeSearchResponse.self, from: data)
        let results: [PodcastEpisodeSearchResult] = response.results.compactMap { raw -> PodcastEpisodeSearchResult? in
            guard let feedString = raw.feedUrl, let feedURL = URL(string: feedString) else { return nil }
            return PodcastEpisodeSearchResult(
                id: raw.trackId,
                podcastID: raw.collectionId,
                title: raw.trackName,
                podcastTitle: raw.collectionName,
                publisher: raw.artistName ?? "",
                feedURL: feedURL,
                artworkURL: raw.artworkUrl600.flatMap(URL.init),
                releaseDate: raw.releaseDate,
                duration: raw.trackTimeMillis.map { TimeInterval($0) / 1_000 },
                genre: raw.genres?.first?.name ?? "",
                episodeGUID: raw.episodeGuid
            )
        }
        return PodcastEpisodeSearchRanking.ordered(results, query: query)
    }
}

public actor PodcastSearchService {
    private let provider: PodcastShowSearchProvider

    public init() {
        provider = PodcastShowSearchProvider()
    }

    /// Compatibility entry point for tvOS. It is now storefront-correct even
    /// though the current TV surface does not expose a storefront picker.
    public func search(query: String, countryCode: String? = nil) async throws -> [PodcastSearchResult] {
        try await provider.search(
            query: query,
            countryCode: PodcastSearchStorefront.normalized(countryCode)
        )
    }
}

// MARK: - Apple Podcasts review destination

public actor ApplePodcastsReviewResolver {
    public static let shared = ApplePodcastsReviewResolver()

    private let provider = PodcastShowSearchProvider()
    private var cachedIDsByFeed: [String: Int] = [:]

    public func reviewURL(
        showTitle: String,
        feedURL: URL,
        knownApplePodcastID: Int? = nil,
        countryCode: String? = nil
    ) async -> URL? {
        let storefront = PodcastSearchStorefront.normalized(countryCode)
        if let knownApplePodcastID, knownApplePodcastID > 0 {
            return Self.showURL(id: knownApplePodcastID, storefront: storefront)
        }

        let feedKey = Self.normalizedFeedKey(feedURL)
        if let cachedID = cachedIDsByFeed[feedKey] {
            return Self.showURL(id: cachedID, storefront: storefront)
        }

        let query = showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let results = try? await provider.search(query: query, countryCode: storefront, limit: 50),
              let exactMatch = results.first(where: {
                  Self.normalizedFeedKey($0.feedURL) == feedKey
              })
        else { return nil }

        cachedIDsByFeed[feedKey] = exactMatch.id
        return Self.showURL(id: exactMatch.id, storefront: storefront)
    }

    private static func showURL(id: Int, storefront: String) -> URL? {
        URL(string: "https://podcasts.apple.com/\(storefront.lowercased())/podcast/id\(id)")
    }

    private static func normalizedFeedKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.fragment = nil
        return components.string ?? url.absoluteString.lowercased()
    }
}

private struct iTunesShowSearchResponse: Decodable {
    let results: [iTunesResult]
}

private struct iTunesResult: Decodable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let feedUrl: String?
    let artworkUrl600: String?
    let trackCount: Int?
    let primaryGenreName: String?
}

private struct iTunesEpisodeSearchResponse: Decodable {
    let results: [iTunesEpisodeResult]
}

private struct iTunesEpisodeResult: Decodable {
    struct Genre: Decodable { let name: String }

    let trackId: Int
    let collectionId: Int
    let trackName: String
    let collectionName: String
    let artistName: String?
    let feedUrl: String?
    let artworkUrl600: String?
    let releaseDate: Date?
    let trackTimeMillis: Int?
    let genres: [Genre]?
    let episodeGuid: String?
}

// MARK: - ViewModel

@MainActor
final class PodcastSearchViewModel: ObservableObject {
    enum SectionPhase<Value> {
        case idle, loading, results(Value), empty, failed
    }

    @Published private(set) var showsPhase: SectionPhase<[PodcastSearchResult]> = .idle
    @Published private(set) var episodesPhase: SectionPhase<[PodcastEpisodeSearchResult]> = .idle

    private let showProvider = PodcastShowSearchProvider()
    private let episodeProvider = PodcastEpisodeSearchProvider()
    private var debounceTask: Task<Void, Never>?
    private var searchTasks: [Task<Void, Never>] = []
    private var generation = UUID()

    func queryChanged(_ query: String, countryCode: String) {
        debounceTask?.cancel()
        searchTasks.forEach { $0.cancel() }
        searchTasks.removeAll()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showsPhase = .idle
            episodesPhase = .idle
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            performSearch(trimmed, countryCode: countryCode)
        }
    }

    func cancelSearch() {
        debounceTask?.cancel()
        searchTasks.forEach { $0.cancel() }
        searchTasks.removeAll()
        generation = UUID()
        showsPhase = .idle
        episodesPhase = .idle
    }

    private func performSearch(_ term: String, countryCode: String) {
        generation = UUID()
        let currentGeneration = generation
        showsPhase = .loading
        episodesPhase = .loading

        searchTasks = [
            Task { [weak self] in
                guard let self else { return }
                do {
                    let results = try await showProvider.search(query: term, countryCode: countryCode)
                    guard !Task.isCancelled, generation == currentGeneration else { return }
                    showsPhase = results.isEmpty ? .empty : .results(results)
                } catch {
                    guard !Task.isCancelled, generation == currentGeneration else { return }
                    showsPhase = .failed
                }
            },
            Task { [weak self] in
                guard let self else { return }
                do {
                    let results = try await episodeProvider.search(query: term, countryCode: countryCode)
                    guard !Task.isCancelled, generation == currentGeneration else { return }
                    episodesPhase = results.isEmpty ? .empty : .results(results)
                } catch {
                    guard !Task.isCancelled, generation == currentGeneration else { return }
                    episodesPhase = .failed
                }
            }
        ]
    }
}

// MARK: - Preview ViewModel

@MainActor
final class PodcastPreviewViewModel: ObservableObject {
    enum FeedPhase {
        case loading
        case loaded(ParsedFeed)
        case failed(String)
    }

    @Published private(set) var feedPhase: FeedPhase = .loading
    @Published private(set) var isLoadingFullHistory = false

    var loadedFeed: ParsedFeed? {
        if case .loaded(let feed) = feedPhase { return feed }
        return nil
    }

    private let feedURL: URL?
    private let loader = EpisodeFeedLoader()

    /// `feedURL` is nil when the view was opened straight from a subscription ID
    /// (the subscription already exists, so no feed fetch is ever needed).
    init(feedURL: URL?) {
        self.feedURL = feedURL
    }

    /// Fetches the feed (up to 50 episodes).  Call once on view appear.
    func load() async {
        guard let feedURL else { return }
        feedPhase = .loading
        do {
            let feed = try await loader.fetch(feedURL: feedURL, limit: 50)
            feedPhase = .loaded(feed)
        } catch {
            feedPhase = .failed("Couldn't load episodes. Check your connection and try again.")
        }
    }

    /// Re-fetches with no episode limit.  Only used when there is no subscription yet.
    func loadFullHistory() async {
        guard let feedURL else { return }
        guard !isLoadingFullHistory else { return }
        isLoadingFullHistory = true
        do {
            let feed = try await loader.fetch(feedURL: feedURL, limit: nil)
            feedPhase = .loaded(feed)
        } catch {
            // Keep existing loaded data if available; otherwise surface the error.
            if case .loaded = feedPhase { /* leave as-is */ } else {
                feedPhase = .failed("Couldn't load full episode history.")
            }
        }
        isLoadingFullHistory = false
    }
}
