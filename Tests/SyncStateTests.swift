// AI CONTEXT — Tests/SyncStateTests.swift. Unit tests for the field-level
// dirty-tracking primitive (@Synced) and the EpisodeSyncState/
// SubscriptionSyncState projections introduced for cross-device sync
// (SYNC_DESIGN.md). Includes the subscription-scoped EpisodeSyncState.syncKey.
// Pure value-type tests — no database. The nil-remote-stamp test protects the
// namespace repair rule that absent CloudKit fields are "no opinion", not
// destructive defaults.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class SyncStateTests: XCTestCase {

    // MARK: - @Synced wrapper

    func testCleanByDefault() {
        let synced = Synced(wrappedValue: 5)
        XCTAssertNil(synced.modifiedAt)
        XCTAssertFalse(synced.hasPendingChange)
    }

    func testStampsOnActualChange() {
        var synced = Synced(wrappedValue: 5)
        synced.wrappedValue = 9
        XCTAssertTrue(synced.hasPendingChange)
        XCTAssertNotNil(synced.modifiedAt)
    }

    func testNoStampWhenValueUnchanged() {
        var synced = Synced(wrappedValue: 5)
        synced.wrappedValue = 5
        XCTAssertFalse(synced.hasPendingChange)
    }

    func testMarkCleanClearsStamp() {
        var synced = Synced(wrappedValue: 5)
        synced.wrappedValue = 9
        synced.markClean()
        XCTAssertFalse(synced.hasPendingChange)
        XCTAssertNil(synced.modifiedAt)
    }

    func testCodableRoundTripPreservesStamp() throws {
        var synced = Synced(wrappedValue: "a")
        synced.wrappedValue = "b"
        let data = try JSONEncoder().encode(synced)
        let decoded = try JSONDecoder().decode(Synced<String>.self, from: data)
        XCTAssertEqual(decoded.value, "b")
        XCTAssertEqual(decoded.modifiedAt, synced.modifiedAt)
    }

    func testRemoteWithoutStampPreservesLocalValue() {
        let local = Synced(wrappedValue: 1.6)
        let remote = Synced(wrappedValue: 1.0)

        let merged = mergedSyncedField(local: local, remote: remote)

        XCTAssertEqual(merged.value, 1.6)
        XCTAssertNil(merged.modifiedAt)
    }

    // MARK: - EpisodeSyncState

    func testFreshEpisodeStateWithUserStateIsDirty() {
        var episode = Episode(subscriptionID: UUID(), guid: "g1", title: "t", audioURL: URL(string: "https://e.com/a.mp3")!)
        episode.playedState = .played
        episode.wasCompleted = true

        let state = EpisodeSyncState(episode: episode, subscriptionID: episode.subscriptionID)
        XCTAssertTrue(state.hasPendingChanges)
        XCTAssertEqual(state.guid, "g1")
        XCTAssertEqual(state.syncKey, EpisodeSyncState.syncKey(subscriptionID: episode.subscriptionID, guid: "g1"))
    }

    func testPristineEpisodeIsDetected() {
        let episode = Episode(subscriptionID: UUID(), guid: "g1", title: "t", audioURL: URL(string: "https://e.com/a.mp3")!)
        XCTAssertTrue(EpisodeSyncState.isPristine(episode))
    }

    func testApplyStampsOnlyChangedFields() {
        var episode = Episode(subscriptionID: UUID(), guid: "g1", title: "t", audioURL: URL(string: "https://e.com/a.mp3")!)
        episode.playedState = .played
        var state = EpisodeSyncState(episode: episode, subscriptionID: episode.subscriptionID)
        state.markClean()
        XCTAssertFalse(state.hasPendingChanges)

        // Change only wasCompleted.
        episode.wasCompleted = true
        state.apply(episode)

        XCTAssertTrue(state.hasPendingChanges)
        XCTAssertTrue(state.$wasCompleted.hasPendingChange)
        XCTAssertFalse(state.$playedState.hasPendingChange)
    }

    func testApplyWithNoChangeStaysClean() {
        var episode = Episode(subscriptionID: UUID(), guid: "g1", title: "t", audioURL: URL(string: "https://e.com/a.mp3")!)
        episode.playedState = .played
        var state = EpisodeSyncState(episode: episode, subscriptionID: episode.subscriptionID)
        state.markClean()

        state.apply(episode) // identical values
        XCTAssertFalse(state.hasPendingChanges)
    }

    // MARK: - SubscriptionSyncState

    func testUnsubscribeStampsSubscribedField() {
        let subscription = Subscription(id: UUID(), feedURL: URL(string: "https://f.com/feed")!, title: "Show", priorityRank: 1)
        var state = SubscriptionSyncState(subscription: subscription)
        state.markClean()

        state.subscribed = false
        XCTAssertTrue(state.hasPendingChanges)
        XCTAssertTrue(state.$subscribed.hasPendingChange)
    }

    func testSettingsChangeStampsOnlyThatField() {
        let subscription = Subscription(id: UUID(), feedURL: URL(string: "https://f.com/feed")!, title: "Show", priorityRank: 1)
        var state = SubscriptionSyncState(subscription: subscription)
        state.markClean()

        var changed = subscription
        changed.notificationsEnabled.toggle()
        state.apply(changed)

        XCTAssertTrue(state.$notificationsEnabled.hasPendingChange)
        XCTAssertFalse(state.$priorityRank.hasPendingChange)
    }
}
