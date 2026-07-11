// AI CONTEXT — Tests/MaterializeSettingsPreservationTests.swift.
// Regression guard for the 2026-07-05 data-integrity fix (found via tvOS
// real-device testing): materialising a remote subscription must ADOPT the
// already-synced clean sync projection's user settings instead of seeding
// DEFAULTS. Seeding defaults used to re-dirty the clean projection at `now`,
// and field-level LWW then pushed those fresh defaults back over the phone's
// older real values — "loading older info in the TV app damages newer info on
// the phone." These tests assert both halves: the materialised subscription
// carries the real settings, AND the projection stays clean (nothing to push).
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class MaterializeSettingsPreservationTests: XCTestCase {

    /// Simulates the engine having adopted a CLEAN remote subscription
    /// projection (applyRemoteSubscriptionState's unknown-podcast branch) that
    /// carries the user's real, non-default settings.
    private func seedCleanRemoteProjection(
        into store: SubscriptionStore,
        id: UUID
    ) throws {
        var real = Subscription(
            id: id,
            feedURL: URL(string: "https://f.com/feed")!,
            title: "Show",
            author: nil,
            artworkURL: nil,
            priorityRank: 3
        )
        real.playbackPreference.speed = 2.0
        real.autoArchiveSettings.afterInactive = .hours16
        real.notificationsEnabled = true // differs from the default (false)

        var state = SubscriptionSyncState(subscription: real, subscribed: true)
        state.markClean() // adopted from remote → nothing pending
        try store.database?.saveSubscriptionSyncState(state)
    }

    private func feed() -> ParsedFeed {
        ParsedFeed(title: "Show", author: nil, artworkURL: nil, latestEpisode: nil, episodes: [])
    }

    func testMaterializeAdoptsSyncedSettingsInsteadOfDefaults() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        try seedCleanRemoteProjection(into: store, id: id)

        _ = store.materialize(parsedFeed: feed(), feedURL: URL(string: "https://f.com/feed")!, subscriptionID: id)
        await store.flushPendingSaves()

        let sub = try XCTUnwrap(store.subscription(id: id))
        XCTAssertEqual(sub.playbackPreference.speed, 2.0, "materialize should adopt the synced playback speed, not the default")
        XCTAssertEqual(sub.autoArchiveSettings.afterInactive, .hours16, "materialize should adopt the synced auto-archive setting, not the default")
        XCTAssertTrue(sub.notificationsEnabled, "materialize should adopt the synced notifications setting, not the default")
    }

    func testMaterializeDoesNotDirtyTheCleanProjection() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        try seedCleanRemoteProjection(into: store, id: id)

        _ = store.materialize(parsedFeed: feed(), feedURL: URL(string: "https://f.com/feed")!, subscriptionID: id)
        await store.flushPendingSaves()

        // The whole point of the fix: nothing gets pushed back, so the phone's
        // real settings are never clobbered.
        let pending = try store.database?.pendingSubscriptionSyncStates() ?? []
        XCTAssertFalse(
            pending.contains { $0.subscriptionID == id },
            "materialize must not re-dirty the adopted clean projection (would push defaults over the phone's settings)"
        )
    }

    /// Regression guard for the SECOND fix in this bug class (2026-07-11,
    /// found via real cross-device damage): a survival-kit PURGE REBUILD
    /// materialises into an EMPTY database — no projection exists to adopt —
    /// and the "first sighting seeds a fully-dirty projection" rule then
    /// pushed DEFAULT settings over the phone's real values for every
    /// subscription. materialize must seed a CLEAN projection in that case:
    /// a materialized-by-identity subscription never originates settings.
    func testMaterializeWithNoProjectionSeedsCleanNotDirty() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        // No seeded projection — the post-purge rebuild case.

        _ = store.materialize(parsedFeed: feed(), feedURL: URL(string: "https://f.com/feed")!, subscriptionID: id)
        await store.flushPendingSaves()

        let pending = try store.database?.pendingSubscriptionSyncStates() ?? []
        XCTAssertFalse(
            pending.contains { $0.subscriptionID == id },
            "a purge-rebuild materialize must not create a dirty default-settings projection (would push defaults over the phone's settings)"
        )
        // The projection should exist (clean), so later remote state merges
        // into it rather than re-seeding dirty on the next local save.
        let projection = try store.database?.subscriptionSyncState(id: id)
        XCTAssertNotNil(projection, "materialize should seed a clean projection when none exists")
        XCTAssertEqual(projection?.hasPendingChanges, false)
    }

    /// The genuine new-local-subscribe path must still seed DIRTY — that's how
    /// a subscription made ON this device reaches other devices at all.
    func testAddStillSeedsDirtyProjection() async throws {
        let store = SubscriptionStore.inMemory()

        let sub = try store.add(parsedFeed: feed(), feedURL: URL(string: "https://f.com/feed")!)
        await store.flushPendingSaves()

        let pending = try store.database?.pendingSubscriptionSyncStates() ?? []
        XCTAssertTrue(
            pending.contains { $0.subscriptionID == sub.id },
            "a genuine local subscribe must push its full projection"
        )
    }

    /// The one-shot TV launch repair: pre-fix dirty default projections are
    /// de-dirtied without being pushed.
    func testMarkAllPendingSubscriptionProjectionsClean() async throws {
        let store = SubscriptionStore.inMemory()
        _ = try store.add(parsedFeed: feed(), feedURL: URL(string: "https://f.com/feed")!)
        await store.flushPendingSaves()
        XCTAssertFalse(try XCTUnwrap(store.database?.pendingSubscriptionSyncStates()).isEmpty)

        let cleaned = store.markAllPendingSubscriptionProjectionsClean()

        XCTAssertEqual(cleaned, 1)
        XCTAssertTrue(try XCTUnwrap(store.database?.pendingSubscriptionSyncStates()).isEmpty)
    }
}
