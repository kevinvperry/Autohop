import Foundation

// AI CONTEXT — Widgets/Shared/WidgetSnapshot.swift
//
// PURPOSE:
// Versioned, display-only contract shared by the Autohop iPhone app and its
// WidgetKit extension. Stage 1 defines the durable boundary; Stage 2 projects
// live QueueCoordinator/PlaybackCoordinator state into this value.
//
// IDENTITY / DURABILITY:
// WidgetEpisodeIdentity is subscription-scoped and uses the same stable
// episode key as PlaybackPositionStore. Never substitute Episode.id: that UUID
// may change after a feed refresh. `schemaVersion` lets a newer app/extension
// reject or migrate incompatible snapshots without opening Autohop's database.
//
// SECURITY / PROHIBITED DATA:
// This contract may contain presentation text, durations, status flags, and a
// thumbnail *filename*. It must never contain audio URLs, local media paths,
// CloudKit identifiers, credentials, tokens, or full domain models. Keep this
// file Foundation-only so the extension remains independent of AutohopCore,
// GRDB, playback services, networking, and application state.
// TIME SEMANTICS: durationSeconds is the episode's total length.
// remainingSeconds must be nil until positive playback progress exists; once
// partially played, it contains duration minus the saved/current position.

struct WidgetEpisodeIdentity: Codable, Equatable, Hashable, Sendable {
    let subscriptionID: UUID
    let episodeKey: String
}

struct WidgetDisplayEpisode: Codable, Equatable, Sendable {
    let identity: WidgetEpisodeIdentity
    let episodeTitle: String
    let podcastTitle: String
    let durationSeconds: TimeInterval?
    /// Nil means unplayed; non-nil means playback has commenced.
    let remainingSeconds: TimeInterval?
    let isCurrent: Bool
    let thumbnailFilename: String?
    let isVideo: Bool
    let isExplicit: Bool?
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumDisplayEpisodeCount = 5

    let schemaVersion: Int
    let generatedAt: Date
    let upNextTotalCount: Int
    let isPlaying: Bool
    let episodes: [WidgetDisplayEpisode]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        upNextTotalCount: Int,
        isPlaying: Bool,
        episodes: [WidgetDisplayEpisode]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.upNextTotalCount = max(0, upNextTotalCount)
        self.isPlaying = isPlaying
        self.episodes = Array(episodes.prefix(Self.maximumDisplayEpisodeCount))
    }
}
