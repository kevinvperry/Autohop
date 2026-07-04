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
// Entries identify episodes by the STABLE subscription-scoped key
// (PlaybackPositionStore.key — guid-based, identical derivation on every
// device) plus subscriptionID; titles are carried only as a display fallback
// while a reader's catalog is still filling in. Resolution to real episodes
// happens in QueueModel.resolvedQueue (pure, tested). SYNC_DESIGN.md covers
// the record schema; storage is a single-row `queue_snapshot` table (v8).

public struct QueueSnapshotEntry: Codable, Equatable {
    /// Stable cross-device episode identity — PlaybackPositionStore.key(for:).
    public var episodeKey: String
    public var subscriptionID: UUID
    /// Display fallback only (e.g. while a reader's catalog is mid-fetch);
    /// never used for identity.
    public var episodeTitle: String

    public init(episodeKey: String, subscriptionID: UUID, episodeTitle: String) {
        self.episodeKey = episodeKey
        self.subscriptionID = subscriptionID
        self.episodeTitle = episodeTitle
    }
}

public struct QueueSnapshot: Codable, Equatable {
    public var entries: [QueueSnapshotEntry]
    /// Whole-record LWW stamp — newest authoring device wins.
    public var updatedAt: Date
    /// Which device authored this snapshot (DeviceIdentity.current) — for
    /// diagnostics and so a device can recognise its own echo.
    public var sourceDeviceID: String

    public init(entries: [QueueSnapshotEntry], updatedAt: Date, sourceDeviceID: String) {
        self.entries = entries
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}
