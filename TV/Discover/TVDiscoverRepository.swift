import Foundation
import AutohopCore

// AI CONTEXT — TV/Discover/TVDiscoverRepository.swift
// Actor-backed orchestration for the initial TV landing page. Apple networking
// and disk chart caching remain in AutohopCore; this layer owns only TV request
// batching, cancellation and the deliberately small eager-shelf budget. One
// stable instance is shared by landing/cards/destinations; successful media
// classification is cached and transient failures receive bounded backoff.

actor TVDiscoverRepository {
    private let charts: any PodcastChartsProviding
    private let feedLoader = EpisodeFeedLoader()
    private var videoShowCache: [String: Bool] = [:]
    private var failedVideoProbeRetryAfter: [String: Date] = [:]
    private var activeVideoProbes = 0
    private var videoProbeWaiters: [CheckedContinuation<Void, Never>] = []

    init(charts: any PodcastChartsProviding = ApplePodcastChartsProvider()) {
        self.charts = charts
    }

    func landing(countryCode: String) async throws -> TVDiscoverLanding {
        async let topEpisodes = charts.topEpisodes(countryCode: countryCode, limit: 8)
        async let newAndNotable = charts.newAndNotable(countryCode: countryCode, limit: 10)
        async let topShows = charts.topShows(countryCode: countryCode, limit: 15)
        async let categories = charts.categories(countryCode: countryCode)

        let (episodes, notable, shows, categoryList) = try await (
            topEpisodes,
            newAndNotable,
            topShows,
            categories
        )
        try Task.checkCancellation()

        // Four eager category shelves keep cold-start radio/artwork work
        // bounded. Expanded shelves and focus-proximity loading land later.
        var shelves: [TVDiscoverCategoryShelf] = []
        for category in categoryList.prefix(4) {
            try Task.checkCancellation()
            let values = try await charts.shows(
                countryCode: countryCode,
                categoryID: category.id,
                limit: 12
            )
            shelves.append(TVDiscoverCategoryShelf(category: category, shows: values))
        }

        return TVDiscoverLanding(
            topEpisodes: episodes,
            newAndNotable: notable.count >= 3 ? notable : [],
            topShows: shows,
            categories: categoryList,
            categoryShelves: shelves
        )
    }

    func category(countryCode: String, id: Int) async throws -> [PodcastChartShow] {
        try await charts.shows(countryCode: countryCode, categoryID: id, limit: 50)
    }

    func show(countryCode: String, id: String) async throws -> TVDiscoverResolvedShow {
        guard let catalogue = try await charts.resolveShow(id: id, countryCode: countryCode) else {
            throw TVDiscoverResolutionError.feedUnavailable
        }
        return try await show(catalogue: catalogue)
    }

    func show(catalogue: PodcastSearchResult) async throws -> TVDiscoverResolvedShow {
        let feed = try await feedLoader.fetch(feedURL: catalogue.feedURL, limit: 75)
        let subscriptionID = UUID()
        var subscription = Subscription(
            id: subscriptionID,
            feedURL: catalogue.feedURL,
            title: feed.title.isEmpty ? catalogue.title : feed.title,
            author: feed.author ?? catalogue.author,
            artworkURL: feed.artworkURL ?? catalogue.artworkURL,
            priorityRank: 0,
            categories: feed.categories,
            isExplicit: feed.isExplicit
        )
        subscription.description = feed.description
        let episodes = feed.episodes.compactMap {
            $0.projectedEpisode(subscriptionID: subscriptionID, feedArtworkURL: subscription.artworkURL)
        }
        subscription.episodes = episodes
        subscription.latestEpisode = episodes.first
        return TVDiscoverResolvedShow(catalogue: catalogue, feed: feed, subscription: subscription, episodes: episodes)
    }

    func episode(
        countryCode: String,
        chartEpisode: PodcastChartEpisode
    ) async throws -> (TVDiscoverResolvedShow, Episode) {
        guard let collectionID = chartEpisode.collectionID else {
            throw TVDiscoverResolutionError.feedUnavailable
        }
        let resolved = try await show(countryCode: countryCode, id: collectionID)
        let wanted = Self.normalized(chartEpisode.title)
        guard let episode = resolved.episodes.min(by: { lhs, rhs in
            Self.matchDistance(lhs, wanted: wanted, date: chartEpisode.releaseDate)
                < Self.matchDistance(rhs, wanted: wanted, date: chartEpisode.releaseDate)
        }), Self.normalized(episode.title) == wanted else {
            throw TVDiscoverResolutionError.episodeUnavailable
        }
        return (resolved, episode)
    }

    /// Apple chart records do not declare whether a podcast is audio or video.
    /// Confirm the badge from a small publisher-RSS sample and cache it; never
    /// infer video from a title, publisher name or artwork.
    func isVideoShow(countryCode: String, id: String) async -> Bool {
        let key = "\(countryCode.lowercased()):\(id)"
        if let cached = videoShowCache[key] { return cached }
        if let retryAfter = failedVideoProbeRetryAfter[key], retryAfter > Date() { return false }
        await acquireVideoProbePermit()
        defer { releaseVideoProbePermit() }
        if let cached = videoShowCache[key] { return cached }
        if let retryAfter = failedVideoProbeRetryAfter[key], retryAfter > Date() { return false }
        do {
            guard let catalogue = try await charts.resolveShow(id: id, countryCode: countryCode) else {
                videoShowCache[key] = false
                return false
            }
            let feed = try await feedLoader.fetch(feedURL: catalogue.feedURL, limit: 3)
            let value = feed.episodes.contains(where: { $0.mediaKind == .video })
            videoShowCache[key] = value
            failedVideoProbeRetryAfter[key] = nil
            return value
        } catch {
            // Treat transport/parser failures as unknown, not permanently
            // audio. A short backoff prevents card recycling from creating a
            // request storm while still allowing the badge to self-heal.
            failedVideoProbeRetryAfter[key] = Date().addingTimeInterval(5 * 60)
            return false
        }
    }

    func isVideoEpisode(countryCode: String, episode: PodcastChartEpisode) async -> Bool {
        guard let collectionID = episode.collectionID else { return false }
        return await isVideoShow(countryCode: countryCode, id: collectionID)
    }

    /// Large shelves can materialise several cards together. Keep RSS media
    /// classification deliberately narrow so badge discovery cannot compete
    /// with focus navigation, artwork loading or an episode the user selected.
    private func acquireVideoProbePermit() async {
        if activeVideoProbes < 2 {
            activeVideoProbes += 1
            return
        }
        await withCheckedContinuation { videoProbeWaiters.append($0) }
    }

    private func releaseVideoProbePermit() {
        if videoProbeWaiters.isEmpty {
            activeVideoProbes = max(0, activeVideoProbes - 1)
        } else {
            videoProbeWaiters.removeFirst().resume()
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func matchDistance(_ episode: Episode, wanted: String, date: Date?) -> TimeInterval {
        guard normalized(episode.title) == wanted else { return .greatestFiniteMagnitude }
        guard let date, let published = episode.publishedAt else { return 0 }
        return abs(published.timeIntervalSince(date))
    }
}

enum TVDiscoverResolutionError: Error {
    case feedUnavailable
    case episodeUnavailable
}
