// AI CONTEXT — Tests/SubscriptionPersistenceFailureTests.swift. Regression tests
// for two data-loss bugs found in the 2026-06-16 audit:
//  • AH-P1-006: SubscriptionStore.save() advanced persistedSnapshot even when the
//    GRDB write failed, so a later unrelated save would diff against an unwritten
//    snapshot and silently drop the failed mutation.
//  • AH-P1-007: the legacy subscriptions.json import renamed the source file even
//    when decoding failed, leaving an empty database and no file to retry from.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class SubscriptionPersistenceFailureTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func episode(_ guid: String, subID: UUID) -> Episode {
        Episode(subscriptionID: subID, guid: guid, title: "Ep \(guid)",
                audioURL: URL(string: "https://e.com/\(guid).mp3")!)
    }

    // MARK: - AH-P1-006

    @MainActor
    func testFailedPersistDoesNotDropMutationOnLaterUnrelatedSave() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("subscriptions.json")

        let idA = UUID(); let idB = UUID()
        let store = SubscriptionStore(fileURL: legacy)
        _ = try store.addSubscription(id: idA, feedURL: URL(string: "https://f.com/a")!,
                                      title: "A", author: nil, artworkURL: nil,
                                      latestEpisode: episode("a", subID: idA))
        _ = try store.addSubscription(id: idB, feedURL: URL(string: "https://f.com/b")!,
                                      title: "B", author: nil, artworkURL: nil,
                                      latestEpisode: episode("b", subID: idB))
        await store.flushPendingSaves()

        // The next disk write fails (simulated disk-full / locked DB) while renaming A.
        store.database?._testFailNextPersist = true
        store.updateTitle(subscriptionID: idA, title: "A-renamed")
        await store.flushPendingSaves()

        // An unrelated change to B now persists successfully. With the bug, A's row is
        // skipped here (prior == current against the wrongly-advanced snapshot) and the
        // rename is lost forever.
        store.updateTitle(subscriptionID: idB, title: "B-renamed")
        await store.flushPendingSaves()

        // Reload from the same on-disk database.
        let reloaded = SubscriptionStore(fileURL: legacy)
        XCTAssertEqual(reloaded.subscription(id: idA)?.title, "A-renamed",
                       "Mutation that failed its first write must survive a later save")
        XCTAssertEqual(reloaded.subscription(id: idB)?.title, "B-renamed")
    }

    // MARK: - AH-P1-007

    @MainActor
    func testInvalidLegacyFileIsPreservedForRetry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("subscriptions.json")
        try Data("{ not valid json".utf8).write(to: legacy)

        let store = SubscriptionStore(fileURL: legacy)
        await store.flushPendingSaves()

        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path),
                      "An undecodable legacy file must be kept so migration can retry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated").path),
                       "A failed import must not rename the source to .migrated")
    }

    @MainActor
    func testValidLegacyFileIsImportedAndRetired() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("subscriptions.json")
        let sub = Subscription(id: UUID(), feedURL: URL(string: "https://f.com/legacy")!,
                               title: "Legacy Show", priorityRank: 0)
        try JSONEncoder().encode([sub]).write(to: legacy)

        let store = SubscriptionStore(fileURL: legacy)
        await store.flushPendingSaves()

        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(store.subscriptions.first?.title, "Legacy Show")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "A successful import should retire the source file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated").path),
                      "Retired legacy file should be kept as .migrated for recoverability")
    }

    // A CloudKit/redirect spelling difference must not enter the in-memory
    // store and later trip SQLite's unique feedURL constraint.
    @MainActor
    func testCanonicalFeedDuplicateIsRejectedBeforePersistence() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SubscriptionStore(fileURL: dir.appendingPathComponent("subscriptions.json"))
        let firstID = UUID()
        _ = try store.addSubscription(
            id: firstID,
            feedURL: URL(string: "https://EXAMPLE.com/feed/")!,
            title: "Original", author: nil, artworkURL: nil,
            latestEpisode: episode("one", subID: firstID)
        )
        let duplicateID = UUID()
        XCTAssertThrowsError(try store.addSubscription(
            id: duplicateID,
            feedURL: URL(string: "https://example.com/feed")!,
            title: "Duplicate", author: nil, artworkURL: nil,
            latestEpisode: episode("two", subID: duplicateID)
        ))
        await store.flushPendingSaves()
        XCTAssertEqual(store.subscriptions.count, 1)
    }
}
