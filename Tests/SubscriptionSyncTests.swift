// AI CONTEXT — Tests/SubscriptionSyncTests.swift. Tests subscription-settings
// sync (SYNC_DESIGN.md step 4): SubscriptionSyncState field-level merge, the
// type-namespaced CKRecord mapping, legacy record-name decode compatibility, and
// SubscriptionStore.applyRemoteSubscriptionState (settings apply / unsubscribe /
// materialization signal). No CloudKit network. Subscription records carry
// `subscriptionID` as a field because the current CloudKit record name is
// prefixed; keep the legacy unprefixed decode path for existing iCloud data.
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class SubscriptionSyncTests: XCTestCase {

    private func makeSubscription(id: UUID = UUID(), title: String = "Show") -> Subscription {
        Subscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: title, priorityRank: 1)
    }

    // MARK: - Merge

    func testRemoteUnsubscribeWinsOverCleanLocal() {
        let sub = makeSubscription()
        var local = SubscriptionSyncState(subscription: sub)
        local.markClean()

        let remote = SubscriptionSyncState(subscription: sub, subscribed: false, dirtyAt: Date())

        let merged = local.merged(withRemote: remote)
        XCTAssertFalse(merged.subscribed)
    }

    func testNewerLocalSettingBeatsOlderRemote() {
        let sub = makeSubscription()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        var local = SubscriptionSyncState(subscription: sub, dirtyAt: new)
        local.notificationsEnabled = true // re-stamps newer

        let remote = SubscriptionSyncState(subscription: sub, dirtyAt: old)

        let merged = local.merged(withRemote: remote)
        XCTAssertTrue(merged.notificationsEnabled)        // local newer kept
        XCTAssertTrue(merged.$notificationsEnabled.hasPendingChange)
    }

    // MARK: - CKRecord mapping

    func testSubscriptionRecordRoundTrip() {
        var sub = makeSubscription(title: "My Podcast")
        sub.playbackPreference.speed = 1.6
        sub.notificationsEnabled = true
        let state = SubscriptionSyncState(subscription: sub)

        let record = CloudKitSync.makeRecord(from: state)
        XCTAssertEqual(record.recordType, CloudKitSync.subscriptionRecordType)
        XCTAssertEqual(record.recordID.recordName, CloudKitSync.subscriptionRecordName(id: sub.id))

        let decoded = CloudKitSync.subscriptionSyncState(from: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.title, "My Podcast")
        XCTAssertEqual(decoded?.feedURL, sub.feedURL)
        XCTAssertEqual(decoded?.playbackPreference.speed, 1.6)
        XCTAssertEqual(decoded?.notificationsEnabled, true)
    }

    func testLegacySubscriptionRecordNameStillDecodes() {
        let sub = makeSubscription(title: "Legacy Podcast")
        let record = CKRecord(
            recordType: CloudKitSync.subscriptionRecordType,
            recordID: CKRecord.ID(recordName: sub.id.uuidString, zoneID: CloudKitSync.zoneID)
        )
        record["feedURL"] = sub.feedURL.absoluteString
        record["title"] = sub.title

        let decoded = CloudKitSync.subscriptionSyncState(from: record)
        XCTAssertEqual(decoded?.subscriptionID, sub.id)
        XCTAssertEqual(decoded?.feedURL, sub.feedURL)
    }

    // MARK: - Apply to local

    @MainActor
    func testApplyUpdatesExistingSubscriptionSettings() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let ep = Episode(subscriptionID: id, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        let created = try store.addSubscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Old", author: nil, artworkURL: nil, latestEpisode: ep)
        await store.flushPendingSaves()

        var remoteSub = created
        remoteSub.title = "New Title"
        remoteSub.playbackPreference.speed = 2.0
        let remote = SubscriptionSyncState(subscription: remoteSub, dirtyAt: Date())

        let outcome = store.applyRemoteSubscriptionState(remote)
        await store.flushPendingSaves()

        if case .applied = outcome {} else { XCTFail("expected .applied") }
        XCTAssertEqual(store.subscription(id: id)?.title, "New Title")
        XCTAssertEqual(store.subscription(id: id)?.playbackPreference.speed, 2.0)
    }

    @MainActor
    func testApplyUnknownSubscriptionRequestsMaterialization() {
        let store = SubscriptionStore.inMemory()
        let remoteSub = makeSubscription(id: UUID(), title: "Remote Only")
        let remote = SubscriptionSyncState(subscription: remoteSub, dirtyAt: Date())

        let outcome = store.applyRemoteSubscriptionState(remote)
        if case .needsMaterialization(let state) = outcome {
            XCTAssertEqual(state.feedURL, remoteSub.feedURL)
        } else {
            XCTFail("expected .needsMaterialization")
        }
    }

    @MainActor
    func testRemoteUnsubscribeRemovesLocalSubscription() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let ep = Episode(subscriptionID: id, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        let created = try store.addSubscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Show", author: nil, artworkURL: nil, latestEpisode: ep)
        await store.flushPendingSaves()

        let remote = SubscriptionSyncState(subscription: created, subscribed: false, dirtyAt: Date())
        store.applyRemoteSubscriptionState(remote)
        await store.flushPendingSaves()

        XCTAssertNil(store.subscription(id: id))
    }
}
