import Foundation

// AI CONTEXT — Models/SyncState.swift
// The record-shaped projections that cross-device sync operates on (see
// SYNC_DESIGN.md). They hold ONLY the mutable user-state worth syncing — never
// catalog content (title/description/artwork rehydrate from the feed) and never
// device-local fields (download state/files). Each syncable field is a @Synced
// value, so the projection tracks exactly which fields changed since the last
// push.
//
// Identity follows the design: episodes key on a subscription-scoped
// `(subscriptionID, guid)` sync key (the local UUID regenerates, and GUIDs can
// collide across feeds), subscriptions key on `subscriptionID`.
//
// Playback POSITION is intentionally absent here — it lives in the listening-
// history domain and is handled in a later sync step.
//
// `markAllDirty` is used by CloudKit namespace repair/recovery when a brand-new
// namespaced server record must be uploaded as a full snapshot, even if the
// local fields were previously clean. SubscriptionSyncState also syncs the
// hidden auto-feed-refresh return rank so an Inactive show can move to the
// bottom on one device and later restore its old Priority Stack position on
// another.
//
// downloadFilterSettings joined the projection in July 2026 (it was
// local/backup-only in v1). Struct-level LWW like the other settings
// sub-structs. UPGRADE PATH: adding the field makes pre-upgrade projection
// payloads undecodable, which deliberately routes through the existing re-seed
// heal (AutohopDatabase decode-failure fallback + reseedUndecodableSyncState):
// each subscription re-seeds fully dirty and re-uploads a complete snapshot,
// which is also what first populates the filters on the server. Old remote
// records without the field decode with a nil stamp = "no remote opinion", so
// they can never reset local filters to defaults.
//
// ACK SAFETY: markAcknowledged(by:) compares each current field with the exact
// value+modifiedAt returned by CloudKit. A response for edit A therefore cannot
// clear newer edit B when B occurred while A was in flight.

// MARK: - Episode

/// Per-episode user-state projection, keyed by `(subscriptionID, guid)`.
public struct EpisodeSyncState: Codable, Equatable {
    public let guid: String
    public let subscriptionID: UUID
    @Synced public var playedState: PlayedState
    @Synced public var wasCompleted: Bool
    @Synced public var lastPlayedAt: Date?

    /// Designated initializer from already-wrapped fields — used when decoding a
    /// server CKRecord, where each field carries the server's authoritative stamp.
    public init(
        guid: String,
        subscriptionID: UUID,
        playedState: Synced<PlayedState>,
        wasCompleted: Synced<Bool>,
        lastPlayedAt: Synced<Date?>
    ) {
        self.guid = guid
        self.subscriptionID = subscriptionID
        _playedState = playedState
        _wasCompleted = wasCompleted
        _lastPlayedAt = lastPlayedAt
    }

    /// Seed a projection from an episode with every field stamped dirty — used
    /// the first time an episode acquires sync-worthy state (nothing about it is
    /// known to be on the server yet).
    public init(episode: Episode, subscriptionID: UUID, dirtyAt: Date = Date()) {
        self.guid = episode.guid
        self.subscriptionID = subscriptionID
        _playedState = Synced(wrappedValue: episode.playedState, modifiedAt: dirtyAt)
        _wasCompleted = Synced(wrappedValue: episode.wasCompleted, modifiedAt: dirtyAt)
        _lastPlayedAt = Synced(wrappedValue: episode.lastPlayedAt, modifiedAt: dirtyAt)
    }

    /// Apply current episode values, stamping only the fields that actually changed.
    public mutating func apply(_ episode: Episode) {
        playedState = episode.playedState
        wasCompleted = episode.wasCompleted
        lastPlayedAt = episode.lastPlayedAt
    }

    /// An episode with no user-state worth syncing yet.
    public static func isPristine(_ episode: Episode) -> Bool {
        episode.playedState == .unplayed && !episode.wasCompleted && episode.lastPlayedAt == nil
    }

    public var hasPendingChanges: Bool {
        _playedState.hasPendingChange || _wasCompleted.hasPendingChange || _lastPlayedAt.hasPendingChange
    }

    public mutating func markClean() {
        _playedState.markClean()
        _wasCompleted.markClean()
        _lastPlayedAt.markClean()
    }

    public mutating func markAcknowledged(by acknowledged: EpisodeSyncState) {
        guard syncKey == acknowledged.syncKey else { return }
        _playedState.markClean(ifAcknowledgedBy: acknowledged._playedState)
        _wasCompleted.markClean(ifAcknowledgedBy: acknowledged._wasCompleted)
        _lastPlayedAt.markClean(ifAcknowledgedBy: acknowledged._lastPlayedAt)
    }

    public mutating func markAllDirty(at date: Date = Date()) {
        _playedState.markDirty(at: date)
        _wasCompleted.markDirty(at: date)
        _lastPlayedAt.markDirty(at: date)
    }

    /// Field-level last-write-wins merge of an incoming remote projection into
    /// this local one. Per field:
    ///  - a non-nil local `modifiedAt` is an unsynced local edit; it wins only
    ///    if it is strictly newer than the remote field's authoritative stamp,
    ///    and then stays dirty (it will be pushed back, overwriting the server).
    ///  - otherwise a stamped remote value is adopted and the field is marked clean.
    ///  - a nil remote stamp means "field absent / no remote opinion", so local
    ///    is preserved instead of fabricating a default.
    /// A clean local field therefore yields only to a stamped remote value.
    public func merged(withRemote remote: EpisodeSyncState) -> EpisodeSyncState {
        var result = self
        result._playedState = mergedSyncedField(local: _playedState, remote: remote._playedState)
        result._wasCompleted = mergedSyncedField(local: _wasCompleted, remote: remote._wasCompleted)
        result._lastPlayedAt = mergedSyncedField(local: _lastPlayedAt, remote: remote._lastPlayedAt)
        return result
    }

    public var syncKey: String {
        Self.syncKey(subscriptionID: subscriptionID, guid: guid)
    }

    public static func syncKey(subscriptionID: UUID, guid: String) -> String {
        "\(subscriptionID.uuidString)|guid:\(guid)"
    }

    public static func subscriptionID(fromSyncKey syncKey: String) -> UUID? {
        guard let range = syncKey.range(of: "|guid:") else { return nil }
        return UUID(uuidString: String(syncKey[..<range.lowerBound]))
    }

    public static func guid(fromSyncKey syncKey: String) -> String? {
        guard let range = syncKey.range(of: "|guid:") else { return nil }
        return String(syncKey[range.upperBound...])
    }
}

// MARK: - Subscription

/// Per-subscription user-state projection (subscription itself + per-podcast
/// settings), keyed by `subscriptionID`.
public struct SubscriptionSyncState: Codable, Equatable {
    public let subscriptionID: UUID
    /// The feed URL — constant identity metadata, carried so a device that
    /// doesn't have this podcast can materialise it by fetching the feed.
    public let feedURL: URL
    @Synced public var subscribed: Bool
    @Synced public var title: String
    @Synced public var priorityRank: Int
    @Synced public var notificationsEnabled: Bool
    @Synced public var excludeFromAutoFeedRefresh: Bool
    @Synced public var autoFeedRefreshReturnPriorityRank: Int?
    @Synced public var playbackPreference: PlaybackPreference
    @Synced public var autoArchiveSettings: AutoArchiveSettings
    @Synced public var chapterFilter: ChapterFilter
    @Synced public var downloadFilterSettings: DownloadFilterSettings

    /// Seed from a subscription with every field stamped dirty — a new local
    /// subscription needs to be pushed in full on first sync.
    public init(subscription: Subscription, subscribed: Bool = true, dirtyAt: Date = Date()) {
        self.subscriptionID = subscription.id
        self.feedURL = subscription.feedURL
        _subscribed = Synced(wrappedValue: subscribed, modifiedAt: dirtyAt)
        _title = Synced(wrappedValue: subscription.title, modifiedAt: dirtyAt)
        _priorityRank = Synced(wrappedValue: subscription.priorityRank, modifiedAt: dirtyAt)
        _notificationsEnabled = Synced(wrappedValue: subscription.notificationsEnabled, modifiedAt: dirtyAt)
        _excludeFromAutoFeedRefresh = Synced(wrappedValue: subscription.excludeFromAutoFeedRefresh, modifiedAt: dirtyAt)
        _autoFeedRefreshReturnPriorityRank = Synced(wrappedValue: subscription.autoFeedRefreshReturnPriorityRank, modifiedAt: dirtyAt)
        _playbackPreference = Synced(wrappedValue: subscription.playbackPreference, modifiedAt: dirtyAt)
        _autoArchiveSettings = Synced(wrappedValue: subscription.autoArchiveSettings, modifiedAt: dirtyAt)
        _chapterFilter = Synced(wrappedValue: subscription.chapterFilter, modifiedAt: dirtyAt)
        _downloadFilterSettings = Synced(wrappedValue: subscription.downloadFilterSettings, modifiedAt: dirtyAt)
    }

    /// Designated initializer from already-wrapped fields — used when decoding a
    /// server CKRecord (each field carries the server's authoritative stamp).
    public init(
        subscriptionID: UUID,
        feedURL: URL,
        subscribed: Synced<Bool>,
        title: Synced<String>,
        priorityRank: Synced<Int>,
        notificationsEnabled: Synced<Bool>,
        excludeFromAutoFeedRefresh: Synced<Bool>,
        autoFeedRefreshReturnPriorityRank: Synced<Int?> = Synced(wrappedValue: nil),
        playbackPreference: Synced<PlaybackPreference>,
        autoArchiveSettings: Synced<AutoArchiveSettings>,
        chapterFilter: Synced<ChapterFilter>,
        downloadFilterSettings: Synced<DownloadFilterSettings> = Synced(wrappedValue: .default)
    ) {
        self.subscriptionID = subscriptionID
        self.feedURL = feedURL
        _subscribed = subscribed
        _title = title
        _priorityRank = priorityRank
        _notificationsEnabled = notificationsEnabled
        _excludeFromAutoFeedRefresh = excludeFromAutoFeedRefresh
        _autoFeedRefreshReturnPriorityRank = autoFeedRefreshReturnPriorityRank
        _playbackPreference = playbackPreference
        _autoArchiveSettings = autoArchiveSettings
        _chapterFilter = chapterFilter
        _downloadFilterSettings = downloadFilterSettings
    }

    /// Field-level last-write-wins merge of a remote projection into this one.
    public func merged(withRemote remote: SubscriptionSyncState) -> SubscriptionSyncState {
        var result = self
        result._subscribed = mergedSyncedField(local: _subscribed, remote: remote._subscribed)
        result._title = mergedSyncedField(local: _title, remote: remote._title)
        result._priorityRank = mergedSyncedField(local: _priorityRank, remote: remote._priorityRank)
        result._notificationsEnabled = mergedSyncedField(local: _notificationsEnabled, remote: remote._notificationsEnabled)
        result._excludeFromAutoFeedRefresh = mergedSyncedField(local: _excludeFromAutoFeedRefresh, remote: remote._excludeFromAutoFeedRefresh)
        result._autoFeedRefreshReturnPriorityRank = mergedSyncedField(local: _autoFeedRefreshReturnPriorityRank, remote: remote._autoFeedRefreshReturnPriorityRank)
        result._playbackPreference = mergedSyncedField(local: _playbackPreference, remote: remote._playbackPreference)
        result._autoArchiveSettings = mergedSyncedField(local: _autoArchiveSettings, remote: remote._autoArchiveSettings)
        result._chapterFilter = mergedSyncedField(local: _chapterFilter, remote: remote._chapterFilter)
        result._downloadFilterSettings = mergedSyncedField(local: _downloadFilterSettings, remote: remote._downloadFilterSettings)
        return result
    }

    /// Apply current subscription values, stamping only what changed.
    public mutating func apply(_ subscription: Subscription, subscribed: Bool = true) {
        self.subscribed = subscribed
        title = subscription.title
        priorityRank = subscription.priorityRank
        notificationsEnabled = subscription.notificationsEnabled
        excludeFromAutoFeedRefresh = subscription.excludeFromAutoFeedRefresh
        autoFeedRefreshReturnPriorityRank = subscription.autoFeedRefreshReturnPriorityRank
        playbackPreference = subscription.playbackPreference
        autoArchiveSettings = subscription.autoArchiveSettings
        chapterFilter = subscription.chapterFilter
        downloadFilterSettings = subscription.downloadFilterSettings
    }

    public var hasPendingChanges: Bool {
        _subscribed.hasPendingChange
            || _title.hasPendingChange
            || _priorityRank.hasPendingChange
            || _notificationsEnabled.hasPendingChange
            || _excludeFromAutoFeedRefresh.hasPendingChange
            || _autoFeedRefreshReturnPriorityRank.hasPendingChange
            || _playbackPreference.hasPendingChange
            || _autoArchiveSettings.hasPendingChange
            || _chapterFilter.hasPendingChange
            || _downloadFilterSettings.hasPendingChange
    }

    public mutating func markClean() {
        _subscribed.markClean()
        _title.markClean()
        _priorityRank.markClean()
        _notificationsEnabled.markClean()
        _excludeFromAutoFeedRefresh.markClean()
        _autoFeedRefreshReturnPriorityRank.markClean()
        _playbackPreference.markClean()
        _autoArchiveSettings.markClean()
        _chapterFilter.markClean()
        _downloadFilterSettings.markClean()
    }

    public mutating func markAcknowledged(by acknowledged: SubscriptionSyncState) {
        guard subscriptionID == acknowledged.subscriptionID else { return }
        _subscribed.markClean(ifAcknowledgedBy: acknowledged._subscribed)
        _title.markClean(ifAcknowledgedBy: acknowledged._title)
        _priorityRank.markClean(ifAcknowledgedBy: acknowledged._priorityRank)
        _notificationsEnabled.markClean(ifAcknowledgedBy: acknowledged._notificationsEnabled)
        _excludeFromAutoFeedRefresh.markClean(ifAcknowledgedBy: acknowledged._excludeFromAutoFeedRefresh)
        _autoFeedRefreshReturnPriorityRank.markClean(ifAcknowledgedBy: acknowledged._autoFeedRefreshReturnPriorityRank)
        _playbackPreference.markClean(ifAcknowledgedBy: acknowledged._playbackPreference)
        _autoArchiveSettings.markClean(ifAcknowledgedBy: acknowledged._autoArchiveSettings)
        _chapterFilter.markClean(ifAcknowledgedBy: acknowledged._chapterFilter)
        _downloadFilterSettings.markClean(ifAcknowledgedBy: acknowledged._downloadFilterSettings)
    }

    public mutating func markAllDirty(at date: Date = Date()) {
        _subscribed.markDirty(at: date)
        _title.markDirty(at: date)
        _priorityRank.markDirty(at: date)
        _notificationsEnabled.markDirty(at: date)
        _excludeFromAutoFeedRefresh.markDirty(at: date)
        _autoFeedRefreshReturnPriorityRank.markDirty(at: date)
        _playbackPreference.markDirty(at: date)
        _autoArchiveSettings.markDirty(at: date)
        _chapterFilter.markDirty(at: date)
        _downloadFilterSettings.markDirty(at: date)
    }
}
