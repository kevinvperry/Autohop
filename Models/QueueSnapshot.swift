import Foundation

// AI CONTEXT — Models/QueueSnapshot.swift
// The synced Up Next queue (2026-07-04, Kevin's decision): "the Up Next queue
// is the centre of the Autohop project" — so its COMPOSITION now roams as a
// first-class CloudKit record instead of each device re-deriving its own
// approximation. The iPhone (whose queue is the product's source of truth —
// downloads + pins + Priority Stack) writes a snapshot of its queue's episode
// identities IN ORDER whenever the queue changes; read-only surfaces (tvOS,
// future watch) render exactly that, so "3 episodes of one show queued on the
// phone" mirrors everywhere. ONE record per account ("queue:current"),
// whole-record LWW by `updatedAt` (like listening history) — the most recent
// authoring device wins outright; there is no per-entry merge, because a
// queue is one coherent ordered list, not a set of independent fields.
// VERSION 2 (tvOS rebuild Phase 2, 2026-07-26): the same record is now a
// self-contained TV projection. Each entry carries enough denormalized display
// and streaming data to render/play without fetching its RSS feed. `generation`
// is monotonic within `authorityEpoch`; legacy v1 payloads decode as generation
// zero with optional projection fields absent. Whole-record ordering remains
// authoritative and is never entry-merged. SYNC_DESIGN.md covers the schema;
// storage remains the existing single queue_snapshot row.
// VERSION 3 (2026-08-02): every entry also carries its authoritative pin
// state. Readers must never infer "pinned" merely because an episode is first;
// the first unpinned episode is simply the natural Priority Stack leader.

public enum QueuePinState: String, Codable, Equatable, Sendable {
    case playNext
    case playLast
}

public struct QueueSnapshotEntry: Codable, Equatable, Sendable {
    /// Stable cross-device episode identity — PlaybackPositionStore.key(for:).
    public var episodeKey: String
    public var subscriptionID: UUID
    /// Display fallback only (e.g. while a reader's catalog is mid-fetch);
    /// never used for identity.
    public var episodeTitle: String

    /// Version-2 projection fields. Optional for backward compatibility with
    /// queue payloads authored by Version 1.4 and earlier.
    public var podcastTitle: String?
    public var streamURL: URL?
    public var mediaKind: EpisodeMediaKind?
    public var artworkURL: URL?
    public var durationSeconds: TimeInterval?
    public var publishedAt: Date?
    public var isExplicit: Bool?
    /// iPhone-authored queue override. Nil means natural Priority Stack order.
    public var pinState: QueuePinState?

    public init(
        episodeKey: String,
        subscriptionID: UUID,
        episodeTitle: String,
        podcastTitle: String? = nil,
        streamURL: URL? = nil,
        mediaKind: EpisodeMediaKind? = nil,
        artworkURL: URL? = nil,
        durationSeconds: TimeInterval? = nil,
        publishedAt: Date? = nil,
        isExplicit: Bool? = nil,
        pinState: QueuePinState? = nil
    ) {
        self.episodeKey = episodeKey
        self.subscriptionID = subscriptionID
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.streamURL = streamURL
        self.mediaKind = mediaKind
        self.artworkURL = artworkURL
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.isExplicit = isExplicit
        self.pinState = pinState
    }

    /// Builds a complete projection entry from the phone's authoritative queue.
    public init(episode: Episode, podcastTitle: String?, podcastArtworkURL: URL?) {
        self.init(
            episodeKey: PlaybackPositionStore.key(for: episode),
            subscriptionID: episode.subscriptionID,
            episodeTitle: episode.title,
            podcastTitle: podcastTitle,
            streamURL: episode.audioURL,
            mediaKind: episode.mediaKind,
            artworkURL: episode.artworkURL ?? podcastArtworkURL,
            durationSeconds: episode.durationSeconds,
            publishedAt: episode.publishedAt,
            isExplicit: episode.isExplicit
        )
    }

    /// Creates a streamable local value without requiring RSS materialization.
    /// The deterministic UUID avoids SwiftUI identity churn across renders.
    public func projectedEpisode() -> Episode? {
        // Legacy v1 compatibility: some publishers (including TWiT video
        // feeds) use the enclosure URL itself as <guid>. The phone's stable key
        // therefore already contains a playable URL even though v1 had no
        // explicit streamURL field. Accept only http(s) GUIDs with recognised
        // media extensions; ordinary web-page GUIDs remain non-playable and use
        // targeted RSS recovery. This avoids fetching a private/large feed just
        // to recover data already present in the signed-in user's queue record.
        let resolvedStreamURL = streamURL ?? legacyEnclosureURLFromEpisodeKey
        guard let resolvedStreamURL else { return nil }
        let resolvedMediaKind = mediaKind ?? Self.inferredMediaKind(for: resolvedStreamURL)
        var episode = Episode(
            id: Self.deterministicUUID(from: episodeKey),
            subscriptionID: subscriptionID,
            guid: episodeKey,
            title: episodeTitle,
            audioURL: resolvedStreamURL,
            mediaKind: resolvedMediaKind ?? .audio
        )
        episode.artworkURL = artworkURL
        episode.durationSeconds = durationSeconds
        episode.publishedAt = publishedAt
        episode.isExplicit = isExplicit
        return episode
    }

    private var legacyEnclosureURLFromEpisodeKey: URL? {
        guard let marker = episodeKey.range(of: "|guid:") else { return nil }
        let value = String(episodeKey[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              Self.inferredMediaKind(for: url) != nil else { return nil }
        return url
    }

    private static func inferredMediaKind(for url: URL) -> EpisodeMediaKind? {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "webm"].contains(ext) { return .video }
        if ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].contains(ext) { return .audio }
        return nil
    }

    private static func deterministicUUID(from value: String) -> UUID {
        // Stable FNV-derived 128-bit identity. This is display/local identity,
        // never a sync key; episodeKey remains authoritative cross-device.
        let bytes = Array(value.utf8)
        func hash(seed: UInt64) -> UInt64 {
            bytes.reduce(seed) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        var raw = withUnsafeBytes(of: hash(seed: 14_695_981_039_346_656_037).bigEndian, Array.init)
        raw += withUnsafeBytes(of: hash(seed: 10_995_116_282_111).bigEndian, Array.init)
        raw[6] = (raw[6] & 0x0F) | 0x50
        raw[8] = (raw[8] & 0x3F) | 0x80
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}

public struct QueueSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var generation: Int64
    /// Generation is comparable only inside this authority epoch. A fresh phone
    /// install can start a new epoch without an older high generation winning.
    public var authorityEpoch: String
    public var entries: [QueueSnapshotEntry]
    /// Whole-record LWW stamp — newest authoring device wins.
    public var updatedAt: Date
    /// Which device authored this snapshot (DeviceIdentity.current) — for
    /// diagnostics and so a device can recognise its own echo.
    public var sourceDeviceID: String

    public init(
        entries: [QueueSnapshotEntry],
        updatedAt: Date,
        sourceDeviceID: String,
        schemaVersion: Int = QueueSnapshot.currentSchemaVersion,
        generation: Int64 = 0,
        authorityEpoch: String = "legacy"
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.authorityEpoch = authorityEpoch
        self.entries = entries
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, authorityEpoch, entries, updatedAt, sourceDeviceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generation = try container.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        authorityEpoch = try container.decodeIfPresent(String.self, forKey: .authorityEpoch) ?? "legacy"
        entries = try container.decode([QueueSnapshotEntry].self, forKey: .entries)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
    }
}

/// Persistent phone-authority epoch. Generation counters restart only when the
/// app installation creates a new epoch; readers compare generation inside it.
public enum QueueProjectionAuthority {
    private static let epochKey = "com.autohop.queueProjection.authorityEpoch.v2"

    public static var currentEpoch: String {
        if let existing = UserDefaults.standard.string(forKey: epochKey) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: epochKey)
        return created
    }
}

// AI CONTEXT — Companion queue commands are deliberately separate from the
// phone-authored QueueSnapshot. A television may request one narrow mutation,
// but it may never publish or replace the complete queue. The iPhone resolves
// this stable cross-device identity, applies its existing QueueCoordinator
// policy, then republishes the authoritative snapshot.
public enum QueueCommandAction: String, Codable, Equatable, Sendable {
    case playNext
    case unpin
}

public struct QueuePlayNextRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let action: QueueCommandAction
    public let episodeKey: String
    public let subscriptionID: UUID
    public let episodeTitle: String
    public let createdAt: Date
    public let sourceDeviceID: String

    public init(
        id: UUID = UUID(),
        action: QueueCommandAction = .playNext,
        episodeKey: String,
        subscriptionID: UUID,
        episodeTitle: String,
        createdAt: Date = Date(),
        sourceDeviceID: String = DeviceIdentity.current
    ) {
        self.id = id
        self.action = action
        self.episodeKey = episodeKey
        self.subscriptionID = subscriptionID
        self.episodeTitle = episodeTitle
        self.createdAt = createdAt
        self.sourceDeviceID = sourceDeviceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, episodeKey, subscriptionID, episodeTitle, createdAt, sourceDeviceID
    }

    /// Commands authored before Unpin existed omitted `action`; preserving
    /// their original Play Next meaning keeps an in-flight legacy command safe.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        action = try container.decodeIfPresent(QueueCommandAction.self, forKey: .action) ?? .playNext
        episodeKey = try container.decode(String.self, forKey: .episodeKey)
        subscriptionID = try container.decode(UUID.self, forKey: .subscriptionID)
        episodeTitle = try container.decode(String.self, forKey: .episodeTitle)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
    }
}

/// Companion commands are user intent, not permanent queue state. A command
/// that the phone cannot resolve within one day must be acknowledged and
/// removed rather than replayed forever or unexpectedly mutating a much later
/// queue. Future-dated timestamps are treated as fresh to tolerate clock skew.
public enum QueueCommandResolutionPolicy {
    public static let unresolvedLifetime: TimeInterval = 24 * 60 * 60
    public static let persistentWarningInterval: TimeInterval = 6 * 60 * 60

    public static func isExpired(createdAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) >= unresolvedLifetime
    }

    public static func shouldPersistWarning(lastLoggedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastLoggedAt else { return true }
        return now.timeIntervalSince(lastLoggedAt) >= persistentWarningInterval
    }
}
