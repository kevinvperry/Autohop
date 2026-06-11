import Foundation

// Moved out of App/AppState.swift (June 2026) so AutohopCore — and the
// ShowEngagementAnalyzer smoke tests — can consume listening history entries.
// `ListeningHistoryStore` itself stays in AppState.swift; only the value types
// live here.

public enum ListeningHistoryStatus: String, Codable {
    case listened
    case played
    case archived

    public var title: String {
        switch self {
        case .listened: return "Listened"
        case .played: return "Played"
        case .archived: return "Archived"
        }
    }
}

/// Describes *how* an episode's listening session ended.
public enum CompletionKind: String, Codable {
    /// Episode played to the end naturally.
    case finishedNaturally
    /// User swiped/tapped Archive while mid-episode.
    case manuallyArchived
    /// Auto-archive policy removed the episode.
    case autoArchived
    /// User explicitly marked as played without finishing.
    case markedPlayed
}

public struct ListeningHistoryEntry: Identifiable, Codable, Equatable {
    public var id: String
    public var subscriptionID: UUID
    public var episodeID: UUID
    public var episodeTitle: String
    public var podcastTitle: String
    public var artworkURL: URL?
    public var publishedAt: Date?
    public var durationSeconds: TimeInterval?
    public var listenedSeconds: TimeInterval
    public var lastPositionSeconds: TimeInterval
    public var lastListenedAt: Date
    public var status: ListeningHistoryStatus

    // MARK: - Richer completion data (added 2026-06; absent in older JSON entries)

    /// How this episode ended. Nil for entries recorded before this field was added.
    public var completionKind: CompletionKind?

    /// 0.0–1.0 position fraction at the moment the entry was recorded. Nil when duration was unknown.
    public var completionPercent: Double?

    /// How far through the episode the user was at time of recording (saved position).
    public var listenedDurationSeconds: TimeInterval?

    /// Episode duration as reported at time of recording.
    public var episodeDurationSeconds: TimeInterval?

    // MARK: Codable — graceful decoding of old JSON that lacks the new fields

    enum CodingKeys: String, CodingKey {
        case id, subscriptionID, episodeID, episodeTitle, podcastTitle, artworkURL
        case publishedAt, durationSeconds, listenedSeconds, lastPositionSeconds
        case lastListenedAt, status
        case completionKind, completionPercent, listenedDurationSeconds, episodeDurationSeconds
    }

    public init(
        id: String,
        subscriptionID: UUID,
        episodeID: UUID,
        episodeTitle: String,
        podcastTitle: String,
        artworkURL: URL?,
        publishedAt: Date?,
        durationSeconds: TimeInterval?,
        listenedSeconds: TimeInterval,
        lastPositionSeconds: TimeInterval,
        lastListenedAt: Date,
        status: ListeningHistoryStatus,
        completionKind: CompletionKind? = nil,
        completionPercent: Double? = nil,
        listenedDurationSeconds: TimeInterval? = nil,
        episodeDurationSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.artworkURL = artworkURL
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.listenedSeconds = listenedSeconds
        self.lastPositionSeconds = lastPositionSeconds
        self.lastListenedAt = lastListenedAt
        self.status = status
        self.completionKind = completionKind
        self.completionPercent = completionPercent
        self.listenedDurationSeconds = listenedDurationSeconds
        self.episodeDurationSeconds = episodeDurationSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subscriptionID = try c.decode(UUID.self, forKey: .subscriptionID)
        episodeID = try c.decode(UUID.self, forKey: .episodeID)
        episodeTitle = try c.decode(String.self, forKey: .episodeTitle)
        podcastTitle = try c.decode(String.self, forKey: .podcastTitle)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        listenedSeconds = try c.decode(TimeInterval.self, forKey: .listenedSeconds)
        lastPositionSeconds = try c.decode(TimeInterval.self, forKey: .lastPositionSeconds)
        lastListenedAt = try c.decode(Date.self, forKey: .lastListenedAt)
        status = try c.decode(ListeningHistoryStatus.self, forKey: .status)
        // New fields — absent in old JSON; default to nil.
        completionKind = try c.decodeIfPresent(CompletionKind.self, forKey: .completionKind)
        completionPercent = try c.decodeIfPresent(Double.self, forKey: .completionPercent)
        listenedDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .listenedDurationSeconds)
        episodeDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .episodeDurationSeconds)
    }
}
