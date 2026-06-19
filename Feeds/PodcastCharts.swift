import Foundation

// AI CONTEXT — Feeds/PodcastCharts.swift
// Apple Podcasts charts client for the Discover page. Three public endpoints,
// no API key: the Marketing Tools v2 feed for the overall Top podcasts (hero
// cards), the same feed's episode endpoint for Top Episodes Today, and the
// legacy iTunes RSS genre endpoint for per-genre rails. Chart entries carry
// only an iTunes ID — resolveFeed() / resolveEpisodePodcastFeed() call the
// iTunes Lookup API to obtain the RSS feedUrl and build a PodcastSearchResult,
// which is the bridge into the existing browse-subscription flow.
// Responses are cached to Caches/discover-charts with a 12 h TTL (2 h for
// episodes) so Discover opens instantly and survives offline.
// Consumed by DiscoverViewModel.

// MARK: - Models

struct ChartPodcast: Identifiable, Hashable, Codable, Sendable {
    let id: String          // iTunes collection ID
    let rank: Int
    let title: String
    let artist: String
    let artworkURL: URL?
    let genreName: String
}

struct ChartEpisode: Identifiable, Hashable, Codable, Sendable {
    let id: String           // iTunes episode trackId
    let rank: Int
    let title: String
    let showName: String
    let artworkURL: URL?
    var releaseDateString: String?   // enriched after chart fetch via per-podcast lookup
    let collectionId: String?        // parent podcast iTunes ID (parsed from chart url field)

    /// Parsed from `releaseDateString` — full ISO8601 ("2026-06-18T09:45:00Z").
    var releaseDate: Date? {
        guard let s = releaseDateString else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}

struct ChartGenre: Identifiable, Hashable, Sendable {
    let id: Int             // iTunes genre ID
    let name: String

    static let rails: [ChartGenre] = [
        ChartGenre(id: 1303, name: "Comedy"),
        ChartGenre(id: 1489, name: "News"),
        ChartGenre(id: 1488, name: "True Crime"),
        ChartGenre(id: 1324, name: "Society & Culture"),
        ChartGenre(id: 1321, name: "Business"),
        ChartGenre(id: 1545, name: "Sports"),
        ChartGenre(id: 1512, name: "Health & Fitness"),
        ChartGenre(id: 1318, name: "Technology"),
        ChartGenre(id: 1533, name: "Science"),
        ChartGenre(id: 1309, name: "TV & Film"),
    ]
}

struct ChartCountry: Identifiable, Hashable, Sendable {
    let code: String        // lowercase storefront code
    let name: String
    let flag: String

    var id: String { code }

    /// Pinned to the top of the picker, ahead of the alphabetical list.
    static let featured: [ChartCountry] = [
        named("us"), named("gb"), named("au"),
    ]

    static let all: [ChartCountry] = [
        ChartCountry(code: "au", name: "Australia", flag: "🇦🇺"),
        ChartCountry(code: "at", name: "Austria", flag: "🇦🇹"),
        ChartCountry(code: "br", name: "Brazil", flag: "🇧🇷"),
        ChartCountry(code: "ca", name: "Canada", flag: "🇨🇦"),
        ChartCountry(code: "dk", name: "Denmark", flag: "🇩🇰"),
        ChartCountry(code: "fi", name: "Finland", flag: "🇫🇮"),
        ChartCountry(code: "fr", name: "France", flag: "🇫🇷"),
        ChartCountry(code: "de", name: "Germany", flag: "🇩🇪"),
        ChartCountry(code: "in", name: "India", flag: "🇮🇳"),
        ChartCountry(code: "ie", name: "Ireland", flag: "🇮🇪"),
        ChartCountry(code: "it", name: "Italy", flag: "🇮🇹"),
        ChartCountry(code: "jp", name: "Japan", flag: "🇯🇵"),
        ChartCountry(code: "mx", name: "Mexico", flag: "🇲🇽"),
        ChartCountry(code: "nl", name: "Netherlands", flag: "🇳🇱"),
        ChartCountry(code: "nz", name: "New Zealand", flag: "🇳🇿"),
        ChartCountry(code: "no", name: "Norway", flag: "🇳🇴"),
        ChartCountry(code: "za", name: "South Africa", flag: "🇿🇦"),
        ChartCountry(code: "es", name: "Spain", flag: "🇪🇸"),
        ChartCountry(code: "se", name: "Sweden", flag: "🇸🇪"),
        ChartCountry(code: "gb", name: "United Kingdom", flag: "🇬🇧"),
        ChartCountry(code: "us", name: "United States", flag: "🇺🇸"),
    ]

    static func named(_ code: String) -> ChartCountry {
        all.first(where: { $0.code == code }) ?? all.first(where: { $0.code == "us" })!
    }

    /// Best-guess storefront from the device's region setting; falls back to US.
    static var deviceDefault: ChartCountry {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        return all.first(where: { $0.code == region }) ?? named("us")
    }
}

// MARK: - Service

actor PodcastChartsService {
    private let session: URLSession
    private let cacheTTL: TimeInterval = 12 * 60 * 60
    private let episodeCacheTTL: TimeInterval = 2 * 60 * 60
    private let cacheDirectory: URL

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("discover-charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: Public API

    /// Overall top podcasts for a storefront (Marketing Tools v2 feed).
    func topPodcasts(country: String, limit: Int) async throws -> [ChartPodcast] {
        let key = "\(country)-top-\(limit)"
        if let cached: [ChartPodcast] = cachedCharts(key: key) { return cached }

        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcasts.json")!
        let (data, httpResponse) = try await session.data(from: url)
        try HTTPResponseValidation.validate(httpResponse)
        let response = try JSONDecoder().decode(MarketingToolsFeed.self, from: data)
        let charts = response.feed.results.enumerated().map { index, raw in
            ChartPodcast(
                id: raw.id,
                rank: index + 1,
                title: raw.name,
                artist: raw.artistName,
                artworkURL: raw.artworkUrl100.flatMap { upscaledArtworkURL($0) },
                genreName: raw.genres?.first?.name ?? ""
            )
        }
        storeCharts(charts, key: key)
        return charts
    }

    /// Top podcasts within a genre (legacy iTunes RSS charts endpoint).
    func topPodcasts(country: String, genre: ChartGenre, limit: Int) async throws -> [ChartPodcast] {
        let key = "\(country)-genre\(genre.id)-\(limit)"
        if let cached: [ChartPodcast] = cachedCharts(key: key) { return cached }

        let url = URL(string: "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(limit)/genre=\(genre.id)/json")!
        let (data, httpResponse) = try await session.data(from: url)
        try HTTPResponseValidation.validate(httpResponse)
        let response = try JSONDecoder().decode(LegacyChartsFeed.self, from: data)
        let charts = (response.feed.entry ?? []).enumerated().compactMap { index, raw -> ChartPodcast? in
            guard let id = raw.id.attributes?.imID else { return nil }
            let artwork = raw.imImage?
                .max(by: { (Int($0.attributes?.height ?? "0") ?? 0) < (Int($1.attributes?.height ?? "0") ?? 0) })?
                .label
            return ChartPodcast(
                id: id,
                rank: index + 1,
                title: raw.imName.label,
                artist: raw.imArtist?.label ?? "",
                artworkURL: artwork.flatMap { upscaledArtworkURL($0) },
                genreName: genre.name
            )
        }
        storeCharts(charts, key: key)
        return charts
    }

    /// Top episodes for a storefront (Marketing Tools v2 podcast-episodes feed).
    /// Parses collectionId from the Apple Podcasts URL in each result, then
    /// enriches with releaseDate via concurrent per-podcast iTunes lookups.
    /// Uses a 2 h cache TTL so the section stays reasonably fresh.
    func topEpisodes(country: String, limit: Int) async throws -> [ChartEpisode] {
        let key = "\(country)-episodes-\(limit)"
        if let cached: [ChartEpisode] = cachedEpisodes(key: key) { return cached }

        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcast-episodes.json")!
        let (data, httpResponse) = try await session.data(from: url)
        try HTTPResponseValidation.validate(httpResponse)
        let response = try JSONDecoder().decode(MarketingToolsEpisodeFeed.self, from: data)

        var episodes = response.feed.results.enumerated().map { index, raw in
            ChartEpisode(
                id: raw.id,
                rank: index + 1,
                title: raw.name,
                showName: raw.artistName,
                artworkURL: raw.artworkUrl100.flatMap { upscaledArtworkURL($0) },
                releaseDateString: nil,
                collectionId: Self.parseCollectionId(from: raw.url)
            )
        }

        // Enrich with release dates. Group episodes by parent collectionId so
        // each parent podcast triggers at most one lookup call, then match on trackId.
        let grouped = Dictionary(grouping: episodes, by: { $0.collectionId ?? "" })
            .filter { !$0.key.isEmpty }

        let dateMaps = await withTaskGroup(of: [String: String].self) { group in
            for collectionId in grouped.keys {
                group.addTask { await self.fetchEpisodeDates(collectionId: collectionId) }
            }
            var combined: [String: String] = [:]
            for await map in group { combined.merge(map) { $1 } }
            return combined
        }

        for i in episodes.indices {
            episodes[i].releaseDateString = dateMaps[episodes[i].id]
        }

        storeEpisodes(episodes, key: key)
        return episodes
    }

    /// Fetches the most-recent episodes for a parent podcast and returns a
    /// mapping of episodeId → ISO8601 releaseDate string.
    private func fetchEpisodeDates(collectionId: String) async -> [String: String] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(collectionId)&entity=podcastEpisode&limit=10") else { return [:] }
        guard let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(EpisodeLookupResponse.self, from: data)
        else { return [:] }
        var map: [String: String] = [:]
        for result in response.results where result.wrapperType == "podcastEpisode" {
            if let trackId = result.trackId, let date = result.releaseDate {
                map[String(trackId)] = date
            }
        }
        return map
    }

    /// Extracts the parent podcast's iTunes collection ID from an Apple Podcasts
    /// episode URL (…/id{collectionId}?i={episodeId}).
    private static func parseCollectionId(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString) else { return nil }
        let path = url.path
        guard let range = path.range(of: #"/id(\d+)"#, options: .regularExpression),
              let numRange = path.range(of: #"\d+"#, options: .regularExpression, range: range)
        else { return nil }
        return String(path[numRange])
    }

    /// Resolves a chart episode's parent podcast to a full search result via
    /// the iTunes Lookup API, using the episode's `collectionId`.
    func resolveEpisodePodcastFeed(for episode: ChartEpisode, country: String) async throws -> PodcastSearchResult? {
        guard let collectionId = episode.collectionId else { return nil }
        let fakePodcast = ChartPodcast(id: collectionId, rank: 0, title: episode.showName,
                                      artist: "", artworkURL: episode.artworkURL, genreName: "")
        return try await resolveFeed(for: fakePodcast, country: country)
    }

    /// Resolves a chart entry to a full search result (with RSS feed URL) via
    /// the iTunes Lookup API. Returns nil for Apple-exclusive shows with no
    /// public RSS feed — Autohop can only subscribe via RSS.
    func resolveFeed(for podcast: ChartPodcast, country: String) async throws -> PodcastSearchResult? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: podcast.id),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: country),
        ]
        let (data, httpResponse) = try await session.data(from: components.url!)
        try HTTPResponseValidation.validate(httpResponse)
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let raw = response.results.first,
              let feedString = raw.feedUrl,
              let feedURL = URL(string: feedString) else { return nil }
        return PodcastSearchResult(
            id: raw.trackId,
            title: raw.trackName,
            author: raw.artistName,
            feedURL: feedURL,
            artworkURL: (raw.artworkUrl600 ?? podcast.artworkURL?.absoluteString).flatMap(URL.init),
            episodeCount: raw.trackCount ?? 0,
            genre: raw.primaryGenreName ?? podcast.genreName
        )
    }

    // MARK: Artwork

    /// Chart feeds return small artwork (100–170 px). The CDN serves any size
    /// encoded in the final path component, so rewrite it to 400×400.
    private func upscaledArtworkURL(_ string: String) -> URL? {
        guard let range = string.range(of: #"\d+x\d+(bb)?(-\d+)?\.(png|jpg|jpeg|webp)$"#, options: .regularExpression) else {
            return URL(string: string)
        }
        let ext = string.hasSuffix(".png") ? "png" : "jpg"
        return URL(string: string.replacingCharacters(in: range, with: "400x400bb.\(ext)"))
    }

    // MARK: Disk cache

    private struct CacheEnvelope: Codable {
        let fetchedAt: Date
        let charts: [ChartPodcast]
    }

    private struct EpisodeCacheEnvelope: Codable {
        let fetchedAt: Date
        let episodes: [ChartEpisode]
    }

    private func cacheURL(key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json")
    }

    private func cachedCharts(key: String) -> [ChartPodcast]? {
        guard let data = try? Data(contentsOf: cacheURL(key: key)),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              Date().timeIntervalSince(envelope.fetchedAt) < cacheTTL,
              !envelope.charts.isEmpty else { return nil }
        return envelope.charts
    }

    private func storeCharts(_ charts: [ChartPodcast], key: String) {
        guard !charts.isEmpty else { return }
        let envelope = CacheEnvelope(fetchedAt: Date(), charts: charts)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: cacheURL(key: key), options: .atomic)
        }
    }

    private func cachedEpisodes(key: String) -> [ChartEpisode]? {
        guard let data = try? Data(contentsOf: cacheURL(key: key)),
              let envelope = try? JSONDecoder().decode(EpisodeCacheEnvelope.self, from: data),
              Date().timeIntervalSince(envelope.fetchedAt) < episodeCacheTTL,
              !envelope.episodes.isEmpty else { return nil }
        return envelope.episodes
    }

    private func storeEpisodes(_ episodes: [ChartEpisode], key: String) {
        guard !episodes.isEmpty else { return }
        let envelope = EpisodeCacheEnvelope(fetchedAt: Date(), episodes: episodes)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: cacheURL(key: key), options: .atomic)
        }
    }
}

// MARK: - Response decoding

private struct MarketingToolsFeed: Decodable {
    struct Feed: Decodable {
        let results: [Result]
    }
    struct Result: Decodable {
        struct Genre: Decodable { let name: String }
        let id: String
        let name: String
        let artistName: String
        let artworkUrl100: String?
        let genres: [Genre]?
    }
    let feed: Feed
}

private struct MarketingToolsEpisodeFeed: Decodable {
    struct Feed: Decodable {
        let results: [Result]
    }
    struct Result: Decodable {
        let id: String
        let name: String
        let artistName: String
        let artworkUrl100: String?
        let url: String?    // Apple Podcasts episode URL — collectionId parsed from path
    }
    let feed: Feed
}

private struct EpisodeLookupResponse: Decodable {
    struct Result: Decodable {
        let wrapperType: String?
        let trackId: Int?
        let releaseDate: String?
    }
    let results: [Result]
}

private struct LegacyChartsFeed: Decodable {
    struct Feed: Decodable {
        let entry: [Entry]?

        // Apple serialises a single-item chart as an object, not a one-element
        // array. Accept both.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let array = try? container.decode([Entry].self, forKey: .entry) {
                entry = array
            } else if let single = try? container.decode(Entry.self, forKey: .entry) {
                entry = [single]
            } else {
                entry = nil
            }
        }
        enum CodingKeys: String, CodingKey { case entry }
    }
    struct Entry: Decodable {
        struct Labelled: Decodable { let label: String }
        struct Image: Decodable {
            struct Attributes: Decodable { let height: String? }
            let label: String
            let attributes: Attributes?
        }
        struct EntryID: Decodable {
            struct Attributes: Decodable {
                let imID: String?
                enum CodingKeys: String, CodingKey { case imID = "im:id" }
            }
            let attributes: Attributes?
        }
        let imName: Labelled
        let imArtist: Labelled?
        let imImage: [Image]?
        let id: EntryID

        enum CodingKeys: String, CodingKey {
            case imName = "im:name"
            case imArtist = "im:artist"
            case imImage = "im:image"
            case id
        }
    }
    let feed: Feed
}

private struct LookupResponse: Decodable {
    struct Result: Decodable {
        let trackId: Int
        let trackName: String
        let artistName: String
        let feedUrl: String?
        let artworkUrl600: String?
        let trackCount: Int?
        let primaryGenreName: String?
    }
    let results: [Result]
}

// MARK: - ViewModel

@MainActor
final class DiscoverViewModel: ObservableObject {
    struct GenreRail: Identifiable {
        let genre: ChartGenre
        let podcasts: [ChartPodcast]
        var id: Int { genre.id }
    }

    /// A secondary "Top Podcasts · <Country>" hero shown in the Discover feed
    /// for a fixed spotlight storefront (see `spotlightCountries`).
    struct CountrySpotlight: Identifiable {
        let country: ChartCountry
        let podcasts: [ChartPodcast]
        var id: String { country.code }
    }

    enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var heroPodcasts: [ChartPodcast] = []
    @Published private(set) var topEpisodes: [ChartEpisode] = []
    @Published private(set) var rails: [GenreRail] = []
    /// First spotlight hero (mid-list, before Health & Fitness): US, or UK when
    /// the user is already browsing US.
    @Published private(set) var spotlightA: CountrySpotlight?
    /// Second spotlight hero (end of feed): UK, or AU when the user is already
    /// browsing UK — and AU too when A has already claimed UK (US user).
    @Published private(set) var spotlightB: CountrySpotlight?

    private let service = PodcastChartsService()
    private var loadedCountry: String?

    /// Resolves the two fixed spotlight storefronts relative to the user's
    /// selected country so neither duplicates it or each other.
    /// Card A: US, falling back to UK when the user is in the US.
    /// Card B: UK, falling back to AU when the user is in the UK or when A has
    /// already taken UK (i.e. the user is in the US).
    static func spotlightCountries(selected: String) -> (ChartCountry, ChartCountry) {
        let aCode = (selected == "us") ? "gb" : "us"
        var bCode = (selected == "gb") ? "au" : "gb"
        if bCode == aCode { bCode = "au" }
        return (.named(aCode), .named(bCode))
    }

    func load(country: String) async {
        guard loadedCountry != country else { return }
        loadedCountry = country
        phase = .loading
        heroPodcasts = []
        topEpisodes = []
        rails = []
        spotlightA = nil
        spotlightB = nil

        let (countryA, countryB) = Self.spotlightCountries(selected: country)

        // Hero, episodes, spotlights and rails load concurrently; a failed one is omitted.
        async let heroTask: [ChartPodcast]? = try? service.topPodcasts(country: country, limit: 8)
        async let episodesTask: [ChartEpisode]? = try? service.topEpisodes(country: country, limit: 8)
        async let spotlightATask: [ChartPodcast]? = try? service.topPodcasts(country: countryA.code, limit: 8)
        async let spotlightBTask: [ChartPodcast]? = try? service.topPodcasts(country: countryB.code, limit: 8)
        let railTasks = ChartGenre.rails.map { genre in
            Task { [service] in
                (genre, try? await service.topPodcasts(country: country, genre: genre, limit: 15))
            }
        }

        let hero = await heroTask ?? []
        let episodes = await episodesTask ?? []
        let spotA = await spotlightATask ?? []
        let spotB = await spotlightBTask ?? []
        var loadedRails: [GenreRail] = []
        for task in railTasks {
            let (genre, podcasts) = await task.value
            if let podcasts, !podcasts.isEmpty {
                loadedRails.append(GenreRail(genre: genre, podcasts: podcasts))
            }
        }

        guard loadedCountry == country else { return }  // user switched mid-flight
        heroPodcasts = hero
        topEpisodes = episodes
        spotlightA = spotA.isEmpty ? nil : CountrySpotlight(country: countryA, podcasts: spotA)
        spotlightB = spotB.isEmpty ? nil : CountrySpotlight(country: countryB, podcasts: spotB)
        rails = loadedRails
        phase = (hero.isEmpty && loadedRails.isEmpty)
            ? .failed("Couldn't load charts. Check your connection and try again.")
            : .loaded
    }

    func reload(country: String) async {
        loadedCountry = nil
        await load(country: country)
    }

    /// Resolve a chart entry to a search result with a usable RSS feed URL.
    func resolve(_ podcast: ChartPodcast, country: String) async -> PodcastSearchResult? {
        try? await service.resolveFeed(for: podcast, country: country)
    }

    /// Resolve a top-episode card to the parent podcast's search result.
    func resolveEpisodePodcast(_ episode: ChartEpisode, country: String) async -> PodcastSearchResult? {
        try? await service.resolveEpisodePodcastFeed(for: episode, country: country)
    }
}
