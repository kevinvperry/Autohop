import Foundation
import AutohopCore

// AI CONTEXT — TV/Discover/TVDiscoverModels.swift
// Immutable, tvOS-owned presentation contracts for Discover. These values are
// catalogue projections, never Subscriptions. The mutation policy is explicit
// so later detail/playback phases cannot accidentally acquire library or queue
// authority while adding convenience actions.

struct TVDiscoverMutationPolicy: Equatable, Sendable {
    let canChangeSubscriptions = false
    let canChangePriority = false
    let canChangeQueue = false
    let canArchiveCatalogueEpisodes = false
}

struct TVDiscoverLanding: Equatable, Sendable {
    let topEpisodes: [PodcastChartEpisode]
    let newAndNotable: [PodcastChartShow]
    let topShows: [PodcastChartShow]
    let categories: [PodcastChartCategory]
    let categoryShelves: [TVDiscoverCategoryShelf]

    static let empty = TVDiscoverLanding(
        topEpisodes: [],
        newAndNotable: [],
        topShows: [],
        categories: [],
        categoryShelves: []
    )
}

struct TVDiscoverCategoryShelf: Identifiable, Equatable, Sendable {
    let category: PodcastChartCategory
    let shows: [PodcastChartShow]
    var id: Int { category.id }
}

enum TVDiscoverRoute: Hashable {
    case search
    case category(PodcastChartCategory)
    case show(PodcastChartShow)
    case episode(PodcastChartEpisode)
    case searchShow(PodcastSearchResult)
}

struct TVDiscoverResolvedShow: Sendable {
    let catalogue: PodcastSearchResult
    let feed: ParsedFeed
    let subscription: Subscription
    let episodes: [Episode]
}
