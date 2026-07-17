// AI CONTEXT — Tests/QueueSnapshotSyncTests.swift. Tests the synced Up Next
// queue snapshot (Models/QueueSnapshot.swift, 2026-07-04): CKRecord round-trip,
// the store's dedupe-on-equal-entries write path, whole-record LWW by
// updatedAt (an older remote must never clobber a newer local author), and
// QueueModel.resolvedQueue — snapshot order is authoritative, unresolvable
// entries are skipped, and locally-known played/archived episodes are
// filtered as stale protection. This record is what makes "3 queued episodes
// of one show on the phone" mirror exactly on TV/watch.
// The database tests also protect CKSyncEngine's queued-record contract: after a
// snapshot is marked clean, the current singleton must remain readable so a late
// or repeated CKSyncEngine save request can still build `queue:current`. A stale
// acknowledgement must leave a newer locally authored snapshot pending.
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class QueueSnapshotSyncTests: XCTestCase {

    private func makeEntry(key: String, subscriptionID: UUID = UUID(), title: String = "Ep") -> QueueSnapshotEntry {
        QueueSnapshotEntry(episodeKey: key, subscriptionID: subscriptionID, episodeTitle: title)
    }

    func testRecordRoundTrip() throws {
        let snapshot = QueueSnapshot(
            entries: [makeEntry(key: "a"), makeEntry(key: "b")],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDeviceID: "device-1"
        )
        let record = CloudKitSync.makeRecord(from: snapshot)
        XCTAssertEqual(record.recordType, CloudKitSync.queueSnapshotRecordType)
        XCTAssertEqual(record.recordID.recordName, CloudKitSync.queueSnapshotRecordName)
        XCTAssertTrue(CloudKitSync.isCurrentRecordName(record.recordID.recordName),
                      "Missing from isCurrentRecordName = pending saves get retired as legacy and never push")

        let decoded = try XCTUnwrap(CloudKitSync.queueSnapshot(from: record))
        XCTAssertEqual(decoded, snapshot)
    }

    func testUpdateLocalQueueSnapshotDedupesUnchangedEntries() throws {
        let store = SubscriptionStore.inMemory()
        let db = try XCTUnwrap(store.database)
        let entries = [makeEntry(key: "a"), makeEntry(key: "b")]

        store.updateLocalQueueSnapshot(entries: entries)
        let first = try XCTUnwrap(db.queueSnapshot())
        XCTAssertNotNil(try db.pendingQueueSnapshot())

        try db.markQueueSnapshotSynced()
        XCTAssertNil(try db.pendingQueueSnapshot())

        // Same entries again → no new write, stays clean (no push churn).
        store.updateLocalQueueSnapshot(entries: entries)
        XCTAssertNil(try db.pendingQueueSnapshot())
        XCTAssertEqual(try db.queueSnapshot()?.updatedAt, first.updatedAt)

        // Genuinely different entries → dirty again.
        store.updateLocalQueueSnapshot(entries: [makeEntry(key: "c")])
        XCTAssertNotNil(try db.pendingQueueSnapshot())
    }

    func testCleanSnapshotRemainsAvailableForQueuedRecordRebuild() throws {
        let store = SubscriptionStore.inMemory()
        let db = try XCTUnwrap(store.database)
        store.updateLocalQueueSnapshot(entries: [makeEntry(key: "current")])

        try db.markQueueSnapshotSynced()

        XCTAssertNil(try db.pendingQueueSnapshot(), "Clean means do not enqueue another change")
        XCTAssertEqual(
            try db.queueSnapshot()?.entries.first?.episodeKey,
            "current",
            "A late CKSyncEngine record request must still build from current state"
        )
    }

    func testOldAcknowledgementLeavesNewerQueueSnapshotPending() throws {
        let store = SubscriptionStore.inMemory()
        let db = try XCTUnwrap(store.database)
        store.updateLocalQueueSnapshot(entries: [makeEntry(key: "old")])
        let old = try XCTUnwrap(db.pendingQueueSnapshot())

        store.updateLocalQueueSnapshot(entries: [makeEntry(key: "new")])
        let newer = try XCTUnwrap(db.pendingQueueSnapshot())

        XCTAssertTrue(try db.acknowledgeQueueSnapshot(old))
        XCTAssertEqual(try db.pendingQueueSnapshot()?.entries.first?.episodeKey, "new")
        XCTAssertFalse(try db.acknowledgeQueueSnapshot(newer))
        XCTAssertNil(try db.pendingQueueSnapshot())
    }

    func testSaveSyncedSnapshotIsLWWByUpdatedAt() throws {
        let store = SubscriptionStore.inMemory()
        let db = try XCTUnwrap(store.database)

        // This device authors a queue at t=2000 (still pending push).
        store.updateLocalQueueSnapshot(entries: [makeEntry(key: "local")])
        let local = try XCTUnwrap(db.queueSnapshot())

        // An OLDER remote snapshot arrives — must not clobber the newer local.
        let olderRemote = QueueSnapshot(
            entries: [makeEntry(key: "remote-old")],
            updatedAt: local.updatedAt.addingTimeInterval(-3600),
            sourceDeviceID: "other-device"
        )
        XCTAssertFalse(try db.saveSyncedQueueSnapshot(olderRemote))
        XCTAssertEqual(try db.queueSnapshot()?.entries.first?.episodeKey, "local")
        XCTAssertNotNil(try db.pendingQueueSnapshot(), "Local author's pending push survives an older remote")

        // A NEWER remote wins and lands clean.
        let newerRemote = QueueSnapshot(
            entries: [makeEntry(key: "remote-new")],
            updatedAt: local.updatedAt.addingTimeInterval(3600),
            sourceDeviceID: "other-device"
        )
        XCTAssertTrue(try db.saveSyncedQueueSnapshot(newerRemote))
        XCTAssertEqual(try db.queueSnapshot()?.entries.first?.episodeKey, "remote-new")
        XCTAssertNil(try db.pendingQueueSnapshot())
    }

    func testResolvedQueuePreservesSnapshotOrderIncludingMultiplePerShow() {
        let subID = UUID()
        var sub = Subscription(id: subID, feedURL: URL(string: "https://f.com/a")!, title: "Show", priorityRank: 1)
        func episode(_ guid: String) -> Episode {
            Episode(subscriptionID: subID, guid: guid, title: guid, audioURL: URL(string: "https://e.com/\(guid).mp3")!)
        }
        let e1 = episode("e1"), e2 = episode("e2"), e3 = episode("e3")
        sub.episodes = [e3, e1, e2]

        let otherID = UUID()
        var other = Subscription(id: otherID, feedURL: URL(string: "https://f.com/b")!, title: "Other", priorityRank: 2)
        let o1 = Episode(subscriptionID: otherID, guid: "o1", title: "o1", audioURL: URL(string: "https://e.com/o1.mp3")!)
        other.episodes = [o1]

        // Phone's queue: THREE episodes of one show interleaved with another —
        // exactly the composition local derivation can't produce.
        let snapshot = QueueSnapshot(
            entries: [
                makeEntry(key: PlaybackPositionStore.key(for: e2), subscriptionID: subID),
                makeEntry(key: PlaybackPositionStore.key(for: o1), subscriptionID: otherID),
                makeEntry(key: PlaybackPositionStore.key(for: e1), subscriptionID: subID),
                makeEntry(key: PlaybackPositionStore.key(for: e3), subscriptionID: subID)
            ],
            updatedAt: Date(), sourceDeviceID: "phone"
        )

        let resolved = QueueModel.resolvedQueue(from: snapshot, subscriptions: [sub, other])
        XCTAssertEqual(resolved.map(\.guid), ["e2", "o1", "e1", "e3"], "Snapshot order is authoritative — not priority-rank order")
    }

    func testResolvedQueueSkipsUnresolvedAndFiltersLocallyFinishedEpisodes() {
        let subID = UUID()
        var sub = Subscription(id: subID, feedURL: URL(string: "https://f.com/a")!, title: "Show", priorityRank: 1)
        var playable = Episode(subscriptionID: subID, guid: "playable", title: "p", audioURL: URL(string: "https://e.com/p.mp3")!)
        var finished = Episode(subscriptionID: subID, guid: "finished", title: "f", audioURL: URL(string: "https://e.com/f.mp3")!)
        finished.playedState = .played
        sub.episodes = [playable, finished]
        playable.subscriptionID = subID

        let snapshot = QueueSnapshot(
            entries: [
                makeEntry(key: PlaybackPositionStore.key(for: finished), subscriptionID: subID),
                makeEntry(key: "\(subID.uuidString)|guid:not-fetched-yet", subscriptionID: subID),
                makeEntry(key: PlaybackPositionStore.key(for: playable), subscriptionID: subID)
            ],
            updatedAt: Date(), sourceDeviceID: "phone"
        )

        let resolved = QueueModel.resolvedQueue(from: snapshot, subscriptions: [sub])
        XCTAssertEqual(resolved.map(\.guid), ["playable"],
                       "Finished-locally episodes are stale-filtered; unresolvable keys are skipped, not fatal")
    }

    // Churn fix (2026-07-05): resolvedQueueItems keeps not-yet-materialized
    // entries as placeholders (episode == nil) in snapshot order, so Up Next is
    // stable during a cold sync instead of falling back to a churny local queue.
    func testResolvedQueueItemsKeepsUnresolvedEntriesAsPlaceholders() {
        let subID = UUID()
        var sub = Subscription(id: subID, feedURL: URL(string: "https://f.com/a")!, title: "Show", priorityRank: 1)
        var playable = Episode(subscriptionID: subID, guid: "playable", title: "Playable Title", audioURL: URL(string: "https://e.com/p.mp3")!)
        playable.subscriptionID = subID
        sub.episodes = [playable]

        let snapshot = QueueSnapshot(
            entries: [
                makeEntry(key: "\(subID.uuidString)|guid:not-fetched-yet", subscriptionID: subID, title: "Coming Soon"),
                makeEntry(key: PlaybackPositionStore.key(for: playable), subscriptionID: subID, title: "ignored-when-resolved")
            ],
            updatedAt: Date(), sourceDeviceID: "phone"
        )

        let items = QueueModel.resolvedQueueItems(from: snapshot, subscriptions: [sub])
        XCTAssertEqual(items.count, 2, "Order is preserved; the unresolved entry is a placeholder, not dropped")

        // Placeholder: no episode, title from the snapshot entry.
        XCTAssertNil(items[0].episode)
        XCTAssertEqual(items[0].title, "Coming Soon")

        // Resolved: carries the local episode + its real title.
        XCTAssertEqual(items[1].episode?.guid, "playable")
        XCTAssertEqual(items[1].title, "Playable Title")

        // resolvedQueue (episodes-only, for playback) still excludes placeholders.
        XCTAssertEqual(QueueModel.resolvedQueue(from: snapshot, subscriptions: [sub]).map(\.guid), ["playable"])
    }
}
