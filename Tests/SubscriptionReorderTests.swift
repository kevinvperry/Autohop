// AI CONTEXT — Tests/SubscriptionReorderTests.swift
// Regression coverage for the 2026-07-18 Subscriptions-page reorder repair.
// Reorder input is a stable UUID draft containing active real subscriptions
// only; Inactive subscriptions stay below that draft and browse previews never
// participate. A session performs one validated commit, defers incoming remote
// order while the user drags, and persists one atomic SubscriptionOrder
// generation. These tests also protect the stale-ack invariant: an older
// CloudKit response must never clear a newer local reorder or field edit.
import XCTest
import CloudKit
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class SubscriptionReorderTests: XCTestCase {

    @MainActor
    private func addSubscription(
        _ title: String,
        index: Int,
        to store: SubscriptionStore
    ) throws -> UUID {
        let id = UUID()
        let episode = Episode(
            subscriptionID: id,
            guid: "episode-\(index)",
            title: "\(title) Episode",
            audioURL: URL(string: "https://episodes.example/\(index).mp3")!
        )
        _ = try store.addSubscription(
            id: id,
            feedURL: URL(string: "https://feeds.example/\(index).xml")!,
            title: title,
            author: nil,
            artworkURL: nil,
            latestEpisode: episode,
            insertAtBottom: true
        )
        return id
    }

    @MainActor
    private func addBrowsePreview(index: Int, to store: SubscriptionStore) throws -> UUID {
        let parsed = ParsedFeed(
            title: "Preview \(index)",
            author: nil,
            artworkURL: nil,
            latestEpisode: nil
        )
        return try store.addPreviewSubscription(
            parsedFeed: parsed,
            feedURL: URL(string: "https://preview.example/\(index).xml")!
        ).id
    }

    private func makeSubscription(id: UUID, title: String, rank: Int) -> Subscription {
        Subscription(
            id: id,
            feedURL: URL(string: "https://feeds.example/\(id.uuidString).xml")!,
            title: title,
            priorityRank: rank
        )
    }

    /// SwiftUI's Collection.move helper is unavailable to the headless
    /// AutohopCore test linker, so model a single drag with identical insertion
    /// semantics using only the standard library.
    private func moving(_ ids: [UUID], from source: Int, to destination: Int) -> [UUID] {
        var result = ids
        let moved = result.remove(at: source)
        let insertion = destination > source ? destination - 1 : destination
        result.insert(moved, at: insertion)
        return result
    }

    @MainActor
    func testRepeatedDraftMovesCommitExactUUIDOrderOnce() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription("A", index: 1, to: store)
        let b = try addSubscription("B", index: 2, to: store)
        let c = try addSubscription("C", index: 3, to: store)
        let d = try addSubscription("D", index: 4, to: store)
        await store.flushPendingSaves()

        var draft = store.beginPriorityReorderSession()
        draft = moving(draft, from: 0, to: 4)
        draft = moving(draft, from: 1, to: 0)

        XCTAssertTrue(store.commitPriorityReorderSession(
            orderedActiveSubscriptionIDs: draft,
            reason: "test.multipleMoves"
        ))
        let saved = await store.flushPendingSaves()
        XCTAssertTrue(saved)
        XCTAssertEqual(draft, [c, b, d, a])
        XCTAssertEqual(store.subscriptions.map(\.id), [c, b, d, a])
    }

    @MainActor
    func testInactiveAndBrowseRowsNeverEnterDragIndexSpace() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription("A", index: 1, to: store)
        let b = try addSubscription("B", index: 2, to: store)
        let inactive = try addSubscription("Inactive", index: 3, to: store)
        store.updateExcludeFromAutoFeedRefresh(subscriptionID: inactive, excluded: true)
        let preview = try addBrowsePreview(index: 4, to: store)
        await store.flushPendingSaves()

        let draft = store.beginPriorityReorderSession()
        XCTAssertEqual(draft, [a, b])
        XCTAssertFalse(draft.contains(inactive))
        XCTAssertFalse(draft.contains(preview))

        XCTAssertTrue(store.commitPriorityReorderSession(
            orderedActiveSubscriptionIDs: [b, a],
            reason: "test.filteredRows"
        ))
        let saved = await store.flushPendingSaves()
        XCTAssertTrue(saved)
        XCTAssertEqual(store.subscriptions.map(\.id), [b, a, inactive, preview])

        // The numeric Podcast Settings editor shares the active-only boundary;
        // an oversized value means "last active", not after hidden/fixed rows.
        store.updatePriorityRank(subscriptionID: b, priorityRank: 99)
        let numericSaved = await store.flushPendingSaves()
        XCTAssertTrue(numericSaved)
        XCTAssertEqual(store.subscriptions.map(\.id), [a, b, inactive, preview])
    }

    @MainActor
    func testMalformedDraftIsRejectedWithoutGuessingAtIndices() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription("A", index: 1, to: store)
        let b = try addSubscription("B", index: 2, to: store)
        await store.flushPendingSaves()

        _ = store.beginPriorityReorderSession()
        XCTAssertFalse(store.commitPriorityReorderSession(
            orderedActiveSubscriptionIDs: [a, a],
            reason: "test.invalid"
        ))
        XCTAssertEqual(store.subscriptions.map(\.id), [a, b])
    }

    @MainActor
    func testRemoteOrderWaitsForUnchangedLocalSessionThenApplies() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription("A", index: 1, to: store)
        let b = try addSubscription("B", index: 2, to: store)
        let c = try addSubscription("C", index: 3, to: store)
        await store.flushPendingSaves()

        let unchangedDraft = store.beginPriorityReorderSession()
        store.applyRemoteSubscriptionOrder(SubscriptionOrderState(
            orderedSubscriptionIDs: [c, b, a],
            updatedAt: Date().addingTimeInterval(60),
            sourceDeviceID: "remote-test-device"
        ))
        XCTAssertEqual(store.subscriptions.map(\.id), [a, b, c])

        XCTAssertTrue(store.commitPriorityReorderSession(
            orderedActiveSubscriptionIDs: unchangedDraft,
            reason: "test.doneWithoutMove"
        ))
        let saved = await store.flushPendingSaves()
        XCTAssertTrue(saved)
        XCTAssertEqual(store.subscriptions.map(\.id), [c, b, a])
    }

    @MainActor
    func testLocalMoveWinsOverRemoteOrderReceivedDuringDrag() async throws {
        let store = SubscriptionStore.inMemory()
        let a = try addSubscription("A", index: 1, to: store)
        let b = try addSubscription("B", index: 2, to: store)
        let c = try addSubscription("C", index: 3, to: store)
        await store.flushPendingSaves()

        _ = store.beginPriorityReorderSession()
        store.applyRemoteSubscriptionOrder(SubscriptionOrderState(
            orderedSubscriptionIDs: [c, b, a],
            updatedAt: Date().addingTimeInterval(60),
            sourceDeviceID: "remote-test-device"
        ))
        XCTAssertTrue(store.commitPriorityReorderSession(
            orderedActiveSubscriptionIDs: [b, a, c],
            reason: "test.localWins"
        ))
        let saved = await store.flushPendingSaves()
        XCTAssertTrue(saved)
        XCTAssertEqual(store.subscriptions.map(\.id), [b, a, c])
    }

    @MainActor
    func testFailedReorderWriteRetriesAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-reorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("subscriptions.json")

        let store = SubscriptionStore(fileURL: legacyURL)
        let a = try addSubscription("A", index: 1, to: store)
        let b = try addSubscription("B", index: 2, to: store)
        let c = try addSubscription("C", index: 3, to: store)
        let initialSave = await store.flushPendingSaves()
        XCTAssertTrue(initialSave)

        _ = store.beginPriorityReorderSession()
        store.database?._testFailNextPersist = true
        XCTAssertTrue(store.commitPriorityReorderSession(
            orderedActiveSubscriptionIDs: [c, a, b],
            reason: "test.retry"
        ))
        let reorderedSave = await store.flushPendingSaves()
        XCTAssertTrue(reorderedSave)
        XCTAssertNil(store.lastPersistenceErrorDescription)

        let reloaded = SubscriptionStore(fileURL: legacyURL)
        XCTAssertEqual(reloaded.subscriptions.map(\.id), [c, a, b])
    }

    func testAtomicOrderAcknowledgementCannotClearNewerGeneration() throws {
        let database = try AutohopDatabase()
        let a = UUID()
        let b = UUID()
        let first = [
            makeSubscription(id: a, title: "A", rank: 1),
            makeSubscription(id: b, title: "B", rank: 2)
        ]
        try database.persist(current: first, previous: [:])
        let firstGeneration = try XCTUnwrap(database.pendingSubscriptionOrder())

        let second = [
            makeSubscription(id: b, title: "B", rank: 1),
            makeSubscription(id: a, title: "A", rank: 2)
        ]
        try database.persist(
            current: second,
            previous: Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        )
        let secondGeneration = try XCTUnwrap(database.pendingSubscriptionOrder())
        XCTAssertNotEqual(firstGeneration.generationID, secondGeneration.generationID)

        XCTAssertTrue(try database.acknowledgeSubscriptionOrder(
            generationID: firstGeneration.generationID
        ))
        XCTAssertEqual(
            try database.pendingSubscriptionOrder()?.generationID,
            secondGeneration.generationID
        )

        XCTAssertFalse(try database.acknowledgeSubscriptionOrder(
            generationID: secondGeneration.generationID
        ))
        XCTAssertNil(try database.pendingSubscriptionOrder())
    }

    func testLocalOrderClockAdvancesPastPreviouslyAdoptedFutureTimestamp() throws {
        let database = try AutohopDatabase()
        let a = UUID()
        let b = UUID()
        let futureRemote = SubscriptionOrderState(
            orderedSubscriptionIDs: [a, b],
            updatedAt: Date().addingTimeInterval(3_600),
            sourceDeviceID: "future-clock-device"
        )
        XCTAssertTrue(try database.saveSyncedSubscriptionOrder(futureRemote))

        let local = [
            makeSubscription(id: b, title: "B", rank: 1),
            makeSubscription(id: a, title: "A", rank: 2)
        ]
        try database.persist(current: local, previous: [:])

        let pending = try XCTUnwrap(database.pendingSubscriptionOrder())
        XCTAssertEqual(pending.orderedSubscriptionIDs, [b, a])
        XCTAssertGreaterThan(pending.updatedAt, futureRemote.updatedAt)
    }

    func testAtomicOrderCloudKitRecordRoundTrip() throws {
        let state = SubscriptionOrderState(
            orderedSubscriptionIDs: [UUID(), UUID(), UUID()],
            generationID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1_234_567),
            sourceDeviceID: "mapping-test-device"
        )

        let record = CloudKitSync.makeRecord(from: state)
        XCTAssertEqual(record.recordType, CloudKitSync.subscriptionOrderRecordType)
        XCTAssertEqual(record.recordID.recordName, CloudKitSync.subscriptionOrderRecordName)
        XCTAssertEqual(CloudKitSync.subscriptionOrder(from: record), state)
    }

    func testReadOnlySyncGuardBlocksAtomicOrderSaveAndDelete() {
        let recordID = CloudKitSync.subscriptionOrderRecordID
        XCTAssertTrue(CloudSyncEngine.isSubscriptionStateChange(.saveRecord(recordID)))
        XCTAssertTrue(CloudSyncEngine.isSubscriptionStateChange(.deleteRecord(recordID)))
    }

    func testOldFieldAcknowledgementLeavesNewerEditPending() {
        let subscription = makeSubscription(id: UUID(), title: "Show", rank: 1)
        var current = SubscriptionSyncState(subscription: subscription)
        current.markClean()
        current.$priorityRank = Synced(
            wrappedValue: 2,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let acknowledged = current
        current.$priorityRank = Synced(
            wrappedValue: 3,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        current.markAcknowledged(by: acknowledged)

        XCTAssertEqual(current.priorityRank, 3)
        XCTAssertTrue(current.$priorityRank.hasPendingChange)
        XCTAssertEqual(
            current.$priorityRank.modifiedAt,
            Date(timeIntervalSince1970: 2_000)
        )
    }

}
