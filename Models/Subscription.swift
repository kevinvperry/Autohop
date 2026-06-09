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

        autoArchiveSettings = try container.decodeIfPresent(AutoArchiveSettings.self, forKey: .autoArchiveSettings) ?? .default
    }
}
