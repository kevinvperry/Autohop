import Foundation

// AI CONTEXT — Models/Episode.swift
// Pure value type for one podcast episode, persisted inside its Subscription
// by SubscriptionStore. Identity subtleties that matter app-wide:
//  - `id` (UUID) is local and regenerated if an episode is re-fetched; stable
//    identity across refreshes is `guid` (RSS <guid>, falling back to URL) —
//    playback positions and listening history key on guid/URL, not UUID.
//  - downloadState lifecycle: notDownloaded → queued → downloading →
//    downloaded | failed. A "downloaded" episode must also have
//    localFileURL/localFileName for the queue to accept it.
//  - playedState lifecycle: unplayed → playing/paused → played → archived
//    (archived episodes leave the queue and their file is deleted).
//  - wasCompleted is a sticky "was ever finished" flag, separate from
//    playedState: it survives the played → archived transition so episode
//    lists keep showing a Played pill on completed-then-archived episodes
//    (set/cleared by SubscriptionStore mark* methods; decode defaults it to
//    playedState == .played for stores written before the flag existed).
//  - mediaKind (.audio/.video) selects the playback path in PlaybackEngine.
//  - chapters are embedded (ID3/MP4) or fetched from externalChaptersURL
//    (PodcastIndex JSON chapters) by AppState.
public struct Episode: Identifiable, Equatable, Codable {
    public var id: UUID
    public var subscriptionID: UUID
    public var guid: String
    public var title: String
    public var description: String?
    public var subtitle: String?
    public var author: String?
    public var publishedAt: Date?
    public var durationSeconds: TimeInterval?
    public var audioURL: URL
    public var mediaKind: EpisodeMediaKind
    public var artworkURL: URL?
    public var fileSizeBytes: Int64?
    public var isExplicit: Bool?
    public var downloadState: DownloadState
    public var localFileURL: URL?
    public var localFileName: String?
    public var playedState: PlayedState
    public var chapters: [Chapter]
    public var externalChaptersURL: URL?
    public var lastPlayedAt: Date?
    /// True once the episode has been listened to completion (natural end,
    /// Skip End, or Mark Played). Survives archiving so the UI keeps showing
    /// "Played" on completed episodes that were archived afterwards. Cleared
    /// only when the episode returns to unplayed.
    public var wasCompleted: Bool

    public init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        guid: String,
        title: String,
        audioURL: URL,
        mediaKind: EpisodeMediaKind = .audio,
        downloadState: DownloadState = .notDownloaded,
        playedState: PlayedState = .unplayed,
        chapters: [Chapter] = []
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.guid = guid
        self.title = title
        self.description = nil
        self.subtitle = nil
        self.author = nil
        self.publishedAt = nil
        self.durationSeconds = nil
        self.audioURL = audioURL
        self.mediaKind = mediaKind
        self.artworkURL = nil
        self.fileSizeBytes = nil
        self.isExplicit = nil
        self.downloadState = downloadState
        self.localFileURL = nil
        self.localFileName = nil
        self.playedState = playedState
        self.chapters = chapters
        self.wasCompleted = false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case subscriptionID
        case guid
        case title
        case description
        case subtitle
        case author
        case publishedAt
        case durationSeconds
        case audioURL
        case mediaKind
        case artworkURL
        case fileSizeBytes
        case isExplicit
        case downloadState
        case localFileURL
        case localFileName
        case playedState
        case chapters
        case externalChaptersURL
        case lastPlayedAt
        case wasCompleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subscriptionID = try container.decode(UUID.self, forKey: .subscriptionID)
        guid = try container.decode(String.self, forKey: .guid)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        durationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        audioURL = try container.decode(URL.self, forKey: .audioURL)
        mediaKind = try container.decodeIfPresent(EpisodeMediaKind.self, forKey: .mediaKind) ?? .audio
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit)
        downloadState = try container.decode(DownloadState.self, forKey: .downloadState)
        localFileURL = try container.decodeIfPresent(URL.self, forKey: .localFileURL)
        localFileName = try container.decodeIfPresent(String.self, forKey: .localFileName)
        playedState = try container.decode(PlayedState.self, forKey: .playedState)
        chapters = try container.decode([Chapter].self, forKey: .chapters)
        externalChaptersURL = try container.decodeIfPresent(URL.self, forKey: .externalChaptersURL)
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        // Pre-existing stores have no completion flag; episodes currently in
        // .played state are completed by definition.
        wasCompleted = try container.decodeIfPresent(Bool.self, forKey: .wasCompleted)
            ?? (playedState == .played)
    }
}

public enum EpisodeMediaKind: String, Codable {
    case audio
    case video
}

public enum DownloadState: String, Codable {
    case notDownloaded
    case queued
    case downloading
    case downloaded
    case failed
}

public enum PlayedState: String, Codable {
    case unplayed
    case playing
    case played
    case archived
}
