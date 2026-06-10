import Foundation

// MARK: - AutoArchiveSettings

public struct AutoArchiveSettings: Equatable, Codable, Sendable {

    // Rule 1: archive played episodes after this interval
    public enum AfterPlayed: String, CaseIterable, Codable, Sendable {
        case never
        case afterPlaying
        case hours24
        case days2
        case days7

        public var title: String {
            switch self {
            case .never:        return "Never"
            case .afterPlaying: return "After Playing"
            case .hours24:      return "After 24h"
            case .days2:        return "After 2 Days"
            case .days7:        return "After 1 Week"
            }
        }

        /// Nil = archive immediately on play; positive = archive after interval post-play; .never = don't archive.
        public var interval: TimeInterval? {
            switch self {
            case .never:        return nil          // disabled
            case .afterPlaying: return 0            // archive as soon as played
            case .hours24:      return 24 * 3600
            case .days2:        return 2 * 24 * 3600
            case .days7:        return 7 * 24 * 3600
            }
        }
    }

    // Rule 2: archive inactive (unplayed, untouched) episodes after this interval
    public enum AfterInactive: String, CaseIterable, Codable, Sendable {
        case never
        case hours4
        case hours8
        case hours16
        case hours24
        case days2
        case days3
        case days7
        case days14
        case days30
        case days90

        public var title: String {
            switch self {
            case .never:   return "Never"
            case .hours4:  return "4 Hours"
            case .hours8:  return "8 Hours"
            case .hours16: return "16 Hours"
            case .hours24: return "24 Hours"
            case .days2:   return "2 Days"
            case .days3:   return "3 Days"
            case .days7:   return "1 Week"
            case .days14:  return "2 Weeks"
            case .days30:  return "30 Days"
            case .days90:  return "90 Days"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .never:   return nil
            case .hours4:  return 4 * 3600
            case .hours8:  return 8 * 3600
            case .hours16: return 16 * 3600
            case .hours24: return 24 * 3600
            case .days2:   return 2 * 24 * 3600
            case .days3:   return 3 * 24 * 3600
            case .days7:   return 7 * 24 * 3600
            case .days14:  return 14 * 24 * 3600
            case .days30:  return 30 * 24 * 3600
            case .days90:  return 90 * 24 * 3600
            }
        }
    }

    // Rule 3: keep only the N most recently published episodes
    public enum EpisodeLimit: Int, CaseIterable, Codable, Sendable {
        case noLimit = 0
        case one     = 1
        case two     = 2
        case three   = 3
        case four    = 4
        case five    = 5
        case ten     = 10

        public var title: String {
            switch self {
            case .noLimit: return "No Limit"
            case .one:     return "1"
            case .two:     return "2"
            case .three:   return "3"
            case .four:    return "4"
            case .five:    return "5"
            case .ten:     return "10"
            }
        }
    }

    public var afterPlayed: AfterPlayed
    public var afterInactive: AfterInactive
    public var episodeLimit: EpisodeLimit

    public static let `default` = AutoArchiveSettings(
        afterPlayed: .afterPlaying,
        afterInactive: .days7,
        episodeLimit: .one
    )

    public init(
        afterPlayed: AfterPlayed = .afterPlaying,
        afterInactive: AfterInactive = .days7,
        episodeLimit: EpisodeLimit = .one
    ) {
        self.afterPlayed = afterPlayed
        self.afterInactive = afterInactive
        self.episodeLimit = episodeLimit
    }
}

// MARK: - RefreshStats

/// Per-feed fetch bookkeeping that drives adaptive refresh scheduling.
/// The publishing-cadence model itself is derived from episode `publishedAt`
/// dates at decision time — only fetch state and HTTP validators persist here.
public struct RefreshStats: Equatable, Codable, Sendable {
    /// HTTP validators for conditional requests (304 Not Modified).
    public var etag: String?
    public var lastModified: String?
    /// When the feed was last fetched (any outcome).
    public var lastFetchedAt: Date?
    /// When a fetch last discovered a new episode.
    public var lastNewEpisodeAt: Date?
    /// Fetches since the last new episode. Drives hiatus decay.
    public var consecutiveEmptyFetches: Int

    public init(
        etag: String? = nil,
        lastModified: String? = nil,
        lastFetchedAt: Date? = nil,
        lastNewEpisodeAt: Date? = nil,
        consecutiveEmptyFetches: Int = 0
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.lastFetchedAt = lastFetchedAt
        self.lastNewEpisodeAt = lastNewEpisodeAt
        self.consecutiveEmptyFetches = consecutiveEmptyFetches
    }

    public mutating func recordFetch(foundNewEpisode: Bool, at date: Date = Date()) {
        lastFetchedAt = date
        if foundNewEpisode {
            lastNewEpisodeAt = date
            consecutiveEmptyFetches = 0
        } else {
            consecutiveEmptyFetches += 1
        }
    }
}

// MARK: - Feed refresh scheduling

public enum FeedRefreshScheduling {
    /// Bounds for the derived publish cadence.
    public static let minPublishInterval: TimeInterval = 15 * 60
    public static let maxPublishInterval: TimeInterval = 7 * 24 * 60 * 60
    /// Used when a feed has fewer than 3 dated episodes.
    public static let defaultPublishInterval: TimeInterval = 6 * 60 * 60
    /// Default fastest in-window recheck while expecting a drop. User-tunable via
    /// the Release Radar setting (conditional requests make even 1 min cheap).
    public static let defaultMinRecheckInterval: TimeInterval = 5 * 60
    /// Slowest cadence a dormant feed decays to.
    public static let maxRecheckInterval: TimeInterval = 24 * 60 * 60
    /// Fraction of the median interval at which checking starts ahead of the expected drop.
    public static let windowOpenFraction = 0.75

    /// Median gap between recent episode publish dates (newest ~10), clamped.
    public static func medianPublishInterval(publishDates: [Date]) -> TimeInterval {
        let sorted = publishDates.sorted(by: >).prefix(10)
        guard sorted.count >= 3 else { return defaultPublishInterval }
        let gaps = zip(sorted, sorted.dropFirst()).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return defaultPublishInterval }
        let sortedGaps = gaps.sorted()
        let median = sortedGaps[sortedGaps.count / 2]
        return min(max(median, minPublishInterval), maxPublishInterval)
    }

    /// The next moment this feed deserves a fetch. Anchored to the latest episode's
    /// `publishedAt` so feeds with fixed release times (e.g. 14 past the hour)
    /// phase-lock automatically.
    public static func nextDueAt(
        latestPublishedAt: Date?,
        publishDates: [Date],
        stats: RefreshStats,
        minRecheckInterval: TimeInterval = defaultMinRecheckInterval,
        now: Date = Date()
    ) -> Date {
        let median = medianPublishInterval(publishDates: publishDates)
        guard let anchor = latestPublishedAt ?? stats.lastNewEpisodeAt else {
            // Never seen a dated episode: poll on the default cadence from last fetch.
            return (stats.lastFetchedAt ?? .distantPast).addingTimeInterval(defaultPublishInterval)
        }

        let windowOpens = anchor.addingTimeInterval(median * windowOpenFraction)
        if now < windowOpens {
            return windowOpens
        }

        // Inside (or past) the expected drop window: recheck at the user-set
        // Release Radar cadence, decaying once the feed looks late or dormant
        // (no new episode for >2 medians).
        var recheck = min(max(minRecheckInterval, 60), maxRecheckInterval)
        let lateness = now.timeIntervalSince(anchor.addingTimeInterval(median * 2))
        if lateness > 0 {
            let decaySteps = min(Double(stats.consecutiveEmptyFetches) / 4.0, 8)
            recheck = min(recheck * pow(1.5, decaySteps), maxRecheckInterval)
        }
        guard let lastFetch = stats.lastFetchedAt else { return now }
        return lastFetch.addingTimeInterval(recheck)
    }
}

// MARK: - Subscription

public struct Subscription: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var feedURL: URL
    public var title: String
    public var description: String?
    public var author: String?
    public var artworkURL: URL?
    public var priorityRank: Int
    public var playbackPreference: PlaybackPreference
    public var chapterFilter: ChapterFilter
    public var latestEpisode: Episode?
    public var episodes: [Episode]
    public var playedEpisodeKeys: Set<String>
    public var archivedEpisodeKeys: Set<String>
    public var notificationsEnabled: Bool
    public var autoArchiveSettings: AutoArchiveSettings
    public var excludeFromAutoFeedRefresh: Bool
    public var categories: [String]
    public var isExplicit: Bool?
    /// Non-nil when this subscription was auto-created by opening a search preview.
    /// Used for 30-day browse history retention and cleanup.
    public var browseDate: Date?
    public var refreshStats: RefreshStats

    public init(
        id: UUID = UUID(),
        feedURL: URL,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        priorityRank: Int,
        playbackPreference: PlaybackPreference = .default,
        chapterFilter: ChapterFilter = ChapterFilter(),
        notificationsEnabled: Bool = false,
        autoArchiveSettings: AutoArchiveSettings = .default,
        excludeFromAutoFeedRefresh: Bool = false,
        categories: [String] = [],
        isExplicit: Bool? = nil
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.priorityRank = priorityRank
        self.playbackPreference = playbackPreference
        self.chapterFilter = chapterFilter
        self.latestEpisode = nil
        self.episodes = []
        self.playedEpisodeKeys = []
        self.archivedEpisodeKeys = []
        self.notificationsEnabled = notificationsEnabled
        self.autoArchiveSettings = autoArchiveSettings
        self.excludeFromAutoFeedRefresh = excludeFromAutoFeedRefresh
        self.categories = categories
        self.isExplicit = isExplicit
        self.browseDate = nil
        self.refreshStats = RefreshStats()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case feedURL
        case title
        case description
        case author
        case artworkURL
        case priorityRank
        case playbackPreference
        case chapterFilter
        case latestEpisode
        case episodes
        case playedEpisodeKeys
        case archivedEpisodeKeys
        case notificationsEnabled
        case autoArchiveSettings
        case excludeFromAutoFeedRefresh
        case categories
        case isExplicit
        case browseDate
        case refreshStats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        feedURL = try container.decode(URL.self, forKey: .feedURL)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        priorityRank = try container.decode(Int.self, forKey: .priorityRank)
        playbackPreference = try container.decodeIfPresent(PlaybackPreference.self, forKey: .playbackPreference) ?? .default
        chapterFilter = try container.decodeIfPresent(ChapterFilter.self, forKey: .chapterFilter) ?? ChapterFilter()
        latestEpisode = try container.decodeIfPresent(Episode.self, forKey: .latestEpisode)
        episodes = try container.decodeIfPresent([Episode].self, forKey: .episodes) ?? latestEpisode.map { [$0] } ?? []
        playedEpisodeKeys = try container.decodeIfPresent(Set<String>.self, forKey: .playedEpisodeKeys) ?? []
        archivedEpisodeKeys = try container.decodeIfPresent(Set<String>.self, forKey: .archivedEpisodeKeys) ?? []
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        excludeFromAutoFeedRefresh = try container.decodeIfPresent(Bool.self, forKey: .excludeFromAutoFeedRefresh) ?? false
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit)
        browseDate = try container.decodeIfPresent(Date.self, forKey: .browseDate)
        refreshStats = try container.decodeIfPresent(RefreshStats.self, forKey: .refreshStats) ?? RefreshStats()

        autoArchiveSettings = try container.decodeIfPresent(AutoArchiveSettings.self, forKey: .autoArchiveSettings) ?? .default
    }
}
