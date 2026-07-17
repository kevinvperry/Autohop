// AI CONTEXT — Tests/SubscriptionSyncTests.swift. Tests subscription-settings
// sync (SYNC_DESIGN.md step 4): SubscriptionSyncState field-level merge, the
// type-namespaced CKRecord mapping, legacy record-name decode compatibility, and
// SubscriptionStore.applyRemoteSubscriptionState (settings apply / unsubscribe /
// materialization signal). No CloudKit network. Subscription records carry
// `subscriptionID` as a field because the current CloudKit record name is
// prefixed; keep the legacy unprefixed decode path for existing iCloud data.
// Also covers the namespace data-loss repair: absent remote fields must not wipe
// local settings, fresh records write full snapshots, and legacy records can
// restore settings then queue a full namespaced upload.
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

    @MainActor
    private func addSubscription(
        to store: SubscriptionStore,
        title: String,
        feedIndex: Int
    ) throws -> UUID {
        let id = UUID()
        let episode = Episode(
            subscriptionID: id,
            guid: "g\(feedIndex)",
            title: "Episode \(feedIndex)",
            audioURL: URL(string: "https://e.com/\(feedIndex).mp3")!
        )
        _ = try store.addSubscription(
            id: id,
            feedURL: URL(string: "https://f.com/\(feedIndex)/feed")!,
            title: title,
            author: nil,
            artworkURL: nil,
            latestEpisode: episode,
            insertAtBottom: true
        )
        return id
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

    func testRemoteFieldWithoutStampDoesNotResetCleanLocalSetting() {
        var sub = makeSubscription()
        sub.playbackPreference = PlaybackPreference(
            speed: 1.8,
            startSkipSeconds: 0,
            endSkipSeconds: 0,
            vocalBoostLevel: .strong,
            trimSilence: .low,
            volumeAdjustment: 2
        )
        var local = SubscriptionSyncState(subscription: sub)
        local.markClean()

        let remote = SubscriptionSyncState(
            subscriptionID: sub.id,
            feedURL: sub.feedURL,
            subscribed: Synced(wrappedValue: true),
            title: Synced(wrappedValue: ""),
            priorityRank: Synced(wrappedValue: 0),
            notificationsEnabled: Synced(wrappedValue: false),
            excludeFromAutoFeedRefresh: Synced(wrappedValue: false),
            playbackPreference: Synced(wrappedValue: .default),
            autoArchiveSettings: Synced(wrappedValue: .default),
            chapterFilter: Synced(wrappedValue: ChapterFilter())
        )

        let merged = local.merged(withRemote: remote)

        XCTAssertEqual(merged.playbackPreference.speed, 1.8)
        XCTAssertEqual(merged.playbackPreference.trimSilence, .low)
        XCTAssertEqual(merged.playbackPreference.vocalBoostLevel, .strong)
        XCTAssertEqual(merged.playbackPreference.volumeAdjustment, 2)
    }

    // MARK: - CKRecord mapping

    func testSubscriptionRecordRoundTrip() {
        var sub = makeSubscription(title: "My Podcast")
        sub.playbackPreference.speed = 1.6
        sub.notificationsEnabled = true
        sub.excludeFromAutoFeedRefresh = true
        sub.autoFeedRefreshReturnPriorityRank = 2
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
        XCTAssertEqual(decoded?.excludeFromAutoFeedRefresh, true)
        XCTAssertEqual(decoded?.autoFeedRefreshReturnPriorityRank, 2)
    }

    func testFreshSubscriptionRecordWritesCleanFields() {
        var sub = makeSubscription(title: "Clean Podcast")
        sub.playbackPreference.speed = 1.7
        var state = SubscriptionSyncState(subscription: sub)
        state.markClean()

        let record = CloudKitSync.makeRecord(from: state)

        XCTAssertNotNil(record["playbackPreference"])
        XCTAssertNotNil(record["playbackPreferenceModifiedAt"])
        XCTAssertNotNil(record["autoArchiveSettingsModifiedAt"])
        XCTAssertNotNil(record["chapterFilterModifiedAt"])
        XCTAssertEqual(CloudKitSync.subscriptionSyncState(from: record)?.playbackPreference.speed, 1.7)
    }

    func testSparseSubscriptionPopulateLeavesCleanFieldsUntouched() {
        let sub = makeSubscription()
        var state = SubscriptionSyncState(subscription: sub)
        state.markClean()
        state.notificationsEnabled = true

        let record = CKRecord(recordType: CloudKitSync.subscriptionRecordType, recordID: CloudKitSync.subscriptionRecordID(id: sub.id))
        CloudKitSync.populate(record, from: state)

        XCTAssertEqual(record["notificationsEnabled"] as? Int, 1)
        XCTAssertNil(record["playbackPreferenceModifiedAt"])
        XCTAssertNil(record["autoArchiveSettingsModifiedAt"])
        XCTAssertNil(record["chapterFilterModifiedAt"])
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
    func testAutoFeedRefreshExclusionMovesToBottomAndRestoresSavedRank() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription(to: store, title: "A", feedIndex: 1)
        let b = try addSubscription(to: store, title: "B", feedIndex: 2)
        let c = try addSubscription(to: store, title: "C", feedIndex: 3)
        let d = try addSubscription(to: store, title: "D", feedIndex: 4)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscriptions.map(\.id), [a, b, c, d])

        var customPreference = try XCTUnwrap(store.subscription(id: b)?.playbackPreference)
        customPreference.speed = 1.9
        customPreference.trimSilence = .low
        store.updatePlaybackPreference(subscriptionID: b, preference: customPreference)

        store.updateExcludeFromAutoFeedRefresh(subscriptionID: b, excluded: true)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscriptions.map(\.id), [a, c, d, b])
        XCTAssertEqual(store.subscription(id: b)?.autoFeedRefreshReturnPriorityRank, 2)
        XCTAssertTrue(store.subscription(id: b)?.excludeFromAutoFeedRefresh == true)

        store.updateExcludeFromAutoFeedRefresh(subscriptionID: b, excluded: false)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscriptions.map(\.id), [a, b, c, d])
        XCTAssertNil(store.subscription(id: b)?.autoFeedRefreshReturnPriorityRank)
        XCTAssertEqual(store.subscription(id: b)?.playbackPreference.speed, 1.9)
        XCTAssertEqual(store.subscription(id: b)?.playbackPreference.trimSilence, .low)
    }

    @MainActor
    func testPriorityRankEditIsIgnoredWhileSubscriptionIsInactive() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription(to: store, title: "A", feedIndex: 1)
        let b = try addSubscription(to: store, title: "B", feedIndex: 2)
        let c = try addSubscription(to: store, title: "C", feedIndex: 3)
        await store.flushPendingSaves()

        store.updateExcludeFromAutoFeedRefresh(subscriptionID: b, excluded: true)
        store.updatePriorityRank(subscriptionID: b, priorityRank: 1)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscriptions.map(\.id), [a, c, b])
        XCTAssertEqual(store.subscription(id: b)?.autoFeedRefreshReturnPriorityRank, 2)
    }

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
    func testSparseRemoteRecordDoesNotResetExistingSubscriptionSettings() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let ep = Episode(subscriptionID: id, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        _ = try store.addSubscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Show", author: nil, artworkURL: nil, latestEpisode: ep)
        var preference = PlaybackPreference(
            speed: 1.9,
            startSkipSeconds: 0,
            endSkipSeconds: 0,
            vocalBoostLevel: .strong,
            trimSilence: .low
        )
        preference.startSkipSeconds = 5
        store.updatePlaybackPreference(subscriptionID: id, preference: preference)
        await store.flushPendingSaves()
        let db = try XCTUnwrap(store.database)
        try db.markSynced(episodeSyncKeys: [], subscriptionIDs: [id])

        let sparseRemote = SubscriptionSyncState(
            subscriptionID: id,
            feedURL: URL(string: "https://f.com/feed")!,
            subscribed: Synced(wrappedValue: true),
            title: Synced(wrappedValue: ""),
            priorityRank: Synced(wrappedValue: 0),
            notificationsEnabled: Synced(wrappedValue: false),
            excludeFromAutoFeedRefresh: Synced(wrappedValue: false),
            playbackPreference: Synced(wrappedValue: .default),
            autoArchiveSettings: Synced(wrappedValue: .default),
            chapterFilter: Synced(wrappedValue: ChapterFilter())
        )

        store.applyRemoteSubscriptionState(sparseRemote)
        await store.flushPendingSaves()

        let result = try XCTUnwrap(store.subscription(id: id)?.playbackPreference)
        XCTAssertEqual(result.speed, 1.9)
        XCTAssertEqual(result.startSkipSeconds, 5)
        XCTAssertEqual(result.trimSilence, .low)
        XCTAssertEqual(result.vocalBoostLevel, .strong)
    }

    @MainActor
    func testLegacySubscriptionRecoveryRestoresSettingsAndQueuesFullUpload() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let ep = Episode(subscriptionID: id, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        _ = try store.addSubscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Show", author: nil, artworkURL: nil, latestEpisode: ep)
        await store.flushPendingSaves()
        let db = try XCTUnwrap(store.database)
        try db.markSynced(episodeSyncKeys: [], subscriptionIDs: [id])

        var legacySub = try XCTUnwrap(store.subscription(id: id))
        legacySub.playbackPreference = PlaybackPreference(
            speed: 1.8,
            startSkipSeconds: 7,
            endSkipSeconds: 3,
            vocalBoostLevel: .strong,
            trimSilence: .low,
            volumeAdjustment: -2
        )
        let legacy = SubscriptionSyncState(subscription: legacySub, dirtyAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(store.recoverSettingsFromLegacySubscriptionState(legacy))
        await store.flushPendingSaves()

        let result = try XCTUnwrap(store.subscription(id: id)?.playbackPreference)
        XCTAssertEqual(result.speed, 1.8)
        XCTAssertEqual(result.startSkipSeconds, 7)
        XCTAssertEqual(result.endSkipSeconds, 3)
        XCTAssertEqual(result.trimSilence, .low)
        XCTAssertEqual(result.vocalBoostLevel, .strong)
        XCTAssertEqual(result.volumeAdjustment, -2)

        let pending = try db.pendingSubscriptionSyncStates()
        let upload = try XCTUnwrap(pending.first { $0.subscriptionID == id })
        XCTAssertTrue(upload.$playbackPreference.hasPendingChange)
        XCTAssertTrue(upload.$autoArchiveSettings.hasPendingChange)
        XCTAssertTrue(upload.$chapterFilter.hasPendingChange)
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

    // MARK: - Download Filters sync (joined the projection July 2026)

    private func makeCustomFilters() -> DownloadFilterSettings {
        var filters = DownloadFilterSettings.default
        filters.titleEnabled = true
        filters.matchMode = .any
        filters.titleRules = [DownloadFilterSettings.TextRule(behavior: .exclude, operation: .contains, term: "trailer")]
        filters.durationEnabled = true
        filters.durationRules = [DownloadFilterSettings.DurationRule(behavior: .include, comparison: .longerThan, minutes: 20)]
        return filters
    }

    func testDownloadFilterSettingsRecordRoundTrip() throws {
        var sub = makeSubscription(title: "Filtered")
        sub.downloadFilterSettings = makeCustomFilters()
        let state = SubscriptionSyncState(subscription: sub)

        let record = CloudKitSync.makeRecord(from: state)
        let decoded = try XCTUnwrap(CloudKitSync.subscriptionSyncState(from: record))

        XCTAssertEqual(decoded.downloadFilterSettings, sub.downloadFilterSettings)
        XCTAssertNotNil(decoded.$downloadFilterSettings.modifiedAt)
    }

    func testRemoteRecordWithoutFiltersFieldPreservesLocalFilters() throws {
        var sub = makeSubscription()
        sub.downloadFilterSettings = makeCustomFilters()
        var local = SubscriptionSyncState(subscription: sub)
        local.markClean()

        // A record written before filters joined sync has no filter field; it
        // must decode with a nil stamp ("no remote opinion"), never as an
        // authoritative default that could wipe local filters.
        let record = CKRecord(
            recordType: CloudKitSync.subscriptionRecordType,
            recordID: CloudKitSync.subscriptionRecordID(id: sub.id)
        )
        record["subscriptionID"] = sub.id.uuidString
        record["feedURL"] = sub.feedURL.absoluteString
        let remote = try XCTUnwrap(CloudKitSync.subscriptionSyncState(from: record))
        XCTAssertNil(remote.$downloadFilterSettings.modifiedAt)

        let merged = local.merged(withRemote: remote)
        XCTAssertEqual(merged.downloadFilterSettings, sub.downloadFilterSettings)
    }

    @MainActor
    func testApplyRemoteFiltersUpdatesExistingSubscription() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let ep = Episode(subscriptionID: id, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        let created = try store.addSubscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Show", author: nil, artworkURL: nil, latestEpisode: ep)
        await store.flushPendingSaves()

        var remoteSub = created
        remoteSub.downloadFilterSettings = makeCustomFilters()
        let remote = SubscriptionSyncState(subscription: remoteSub, dirtyAt: Date())

        store.applyRemoteSubscriptionState(remote)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscription(id: id)?.downloadFilterSettings, remoteSub.downloadFilterSettings)
    }

    @MainActor
    func testLocalFilterEditMarksOnlyFiltersPending() async throws {
        let store = SubscriptionStore.inMemory()
        let id = UUID()
        let ep = Episode(subscriptionID: id, guid: "g1", title: "Ep", audioURL: URL(string: "https://e.com/a.mp3")!)
        _ = try store.addSubscription(id: id, feedURL: URL(string: "https://f.com/feed")!, title: "Show", author: nil, artworkURL: nil, latestEpisode: ep)
        await store.flushPendingSaves()
        let db = try XCTUnwrap(store.database)
        try db.markSynced(episodeSyncKeys: [], subscriptionIDs: [id])

        store.updateDownloadFilterSettings(subscriptionID: id, settings: makeCustomFilters())
        await store.flushPendingSaves()

        let pending = try db.pendingSubscriptionSyncStates()
        let state = try XCTUnwrap(pending.first { $0.subscriptionID == id })
        XCTAssertTrue(state.$downloadFilterSettings.hasPendingChange)
        // Field-level dirty-tracking: an untouched sibling setting stays clean.
        XCTAssertFalse(state.$playbackPreference.hasPendingChange)
    }
}
