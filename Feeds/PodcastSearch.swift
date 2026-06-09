import Foundation

// MARK: - Model

struct PodcastSearchResult: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let author: String
    let feedURL: URL
    let artworkURL: URL?
    let episodeCount: Int
    let genre: String
}

// MARK: - Service

actor PodcastSearchService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func search(query: String) async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
        return response.results.compactMap { raw in
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
    }
}

private struct iTunesSearchResponse: Decodable {
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

// MARK: - ViewModel

@MainActor
final class PodcastSearchViewModel: ObservableObject {
    enum Phase {
        case idle, loading, results([PodcastSearchResult]), empty, failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let service = PodcastSearchService()
    private var debounceTask: Task<Void, Never>?

    func queryChanged(_ query: String) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ term: String) async {
        phase = .loading
        do {
            let results = try await service.search(query: term)
            phase = results.isEmpty ? .empty : .results(results)
        } catch {
            phase = .failed("Search failed. Check your connection and try again.")
        }
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

    private let feedURL: URL
    private let loader = EpisodeFeedLoader()

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    /// Fetches the feed (up to 50 episodes).  Call once on view appear.
    func load() async {
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
