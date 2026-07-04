import Foundation

// AI CONTEXT — Persistence/SubscriptionSurvivalKit.swift
// tvOS Phase 1 (Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md §6, decision T2):
// the compact, DURABLE record of the user's library that survives tvOS purges.
// Platform fact: on Apple TV only ~500 KB of UserDefaults persists reliably;
// Caches (where the TV database lives) can be wiped whenever the app isn't
// running. The kit stores just enough to rebuild from nothing — subscription
// IDENTITY (the UUID synced records are keyed by — losing it orphans every
// EpisodeState/SubscriptionState record), feed URL, priority rank, and title —
// plus the sync opt-in flag. Rebuild path: read kit → fetch each feed →
// SubscriptionStore.materialize(parsedFeed:feedURL:subscriptionID:) with the
// PRESERVED id → CloudSyncEngine fetch overlays user-state → catalog fills
// from RSS. ~100 bytes/podcast; save() logs an error past the sanity threshold
// but still writes (an oversized kit beats no kit). The TV app rewrites the
// kit on every subscription change (TVAppModel store sink). iOS does not use
// this type. Headless tests: Tests/SubscriptionSurvivalKitTests.swift.

public struct SurvivalKitEntry: Codable, Equatable {
    /// The subscription's stable identity — MUST be preserved across rebuilds
    /// or synced records (keyed by subscriptionID) no longer apply.
    public var subscriptionID: UUID
    public var feedURL: URL
    public var priorityRank: Int
    /// Display fallback while the feed refetch is in flight.
    public var title: String

    public init(subscriptionID: UUID, feedURL: URL, priorityRank: Int, title: String) {
        self.subscriptionID = subscriptionID
        self.feedURL = feedURL
        self.priorityRank = priorityRank
        self.title = title
    }
}

public struct SubscriptionSurvivalKit: Codable, Equatable {
    public var entries: [SurvivalKitEntry]
    public var iCloudSyncEnabled: Bool

    public init(entries: [SurvivalKitEntry], iCloudSyncEnabled: Bool) {
        self.entries = entries
        self.iCloudSyncEnabled = iCloudSyncEnabled
    }

    /// Snapshot of the current library. Browse-preview subscriptions
    /// (browseDate != nil) are not part of the user's library and are excluded.
    public static func capture(from subscriptions: [Subscription], iCloudSyncEnabled: Bool) -> SubscriptionSurvivalKit {
        let entries = subscriptions
            .filter { $0.browseDate == nil }
            .sorted { $0.priorityRank < $1.priorityRank }
            .map {
                SurvivalKitEntry(
                    subscriptionID: $0.id,
                    feedURL: $0.feedURL,
                    priorityRank: $0.priorityRank,
                    title: $0.title
                )
            }
        return SubscriptionSurvivalKit(entries: entries, iCloudSyncEnabled: iCloudSyncEnabled)
    }
}

@MainActor
public final class SurvivalKitStore {
    /// Stay far below the ~500 KB durable-UserDefaults budget; past this the
    /// save is logged as an error (sanity signal, not a refusal — T2 says
    /// assert, don't limit).
    public static let sanityByteThreshold = 400_000

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.autohop.tv.survivalKit.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SubscriptionSurvivalKit? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SubscriptionSurvivalKit.self, from: data)
    }

    public func save(_ kit: SubscriptionSurvivalKit) {
        guard let data = try? JSONEncoder().encode(kit) else { return }
        if data.count > Self.sanityByteThreshold {
            AppLogger.shared.error("tv.survivalKitOversized", "Survival kit exceeds the durable-UserDefaults sanity threshold", metadata: [
                "bytes": "\(data.count)",
                "entries": "\(kit.entries.count)"
            ], alwaysPersist: true)
        }
        defaults.set(data, forKey: key)
    }
}
