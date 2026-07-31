// AI CONTEXT — Tests/AutoDownloadIntentStoreTests.swift. Headless tests for the
// durable auto-download intent store (deep-scan AH-2026-06-28-01): record is
// write-through and reload-safe (the intent must survive a suspension/kill right
// after a BG feed refresh), remove is idempotent, and pruning enforces the age
// and count caps. The drain/settle logic lives in AppState (app target) and is
// device-verified via download.intentDrain / download.intentResolved log keys.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class AutoDownloadIntentStoreTests: XCTestCase {

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-tests-\(UUID().uuidString)")
            .appendingPathComponent("auto-download-intents.json")
    }

    func testRecordPersistsAcrossReload() {
        let url = temporaryFileURL()
        let episodeID = UUID()
        let subscriptionID = UUID()

        let store = AutoDownloadIntentStore(fileURL: url)
        store.record(episodeID: episodeID, subscriptionID: subscriptionID, podcastTitle: "Show")

        // A fresh instance simulates the app being killed right after the BG
        // feed cycle — the persisted intent is the recovery source.
        let reloaded = AutoDownloadIntentStore(fileURL: url)
        XCTAssertTrue(reloaded.contains(episodeID: episodeID))
        XCTAssertEqual(reloaded.intents.first?.subscriptionID, subscriptionID)
        XCTAssertEqual(reloaded.intents.first?.podcastTitle, "Show")
    }

    func testRecordSameEpisodeReplacesInsteadOfDuplicating() {
        let store = AutoDownloadIntentStore(fileURL: temporaryFileURL())
        let episodeID = UUID()
        let subscriptionID = UUID()

        store.record(episodeID: episodeID, subscriptionID: subscriptionID, podcastTitle: "Show")
        store.record(episodeID: episodeID, subscriptionID: subscriptionID, podcastTitle: "Show")

        XCTAssertEqual(store.intents.count, 1)
    }

    func testRemoveSettlesIntentAndPersists() {
        let url = temporaryFileURL()
        let episodeID = UUID()

        let store = AutoDownloadIntentStore(fileURL: url)
        store.record(episodeID: episodeID, subscriptionID: UUID(), podcastTitle: "Show")
        store.remove(episodeID: episodeID)
        store.remove(episodeID: episodeID) // idempotent

        XCTAssertFalse(store.contains(episodeID: episodeID))
        XCTAssertTrue(AutoDownloadIntentStore(fileURL: url).intents.isEmpty)
    }

    func testExpiredIntentsArePrunedOnReload() {
        let url = temporaryFileURL()
        let store = AutoDownloadIntentStore(fileURL: url)
        let stale = Date().addingTimeInterval(-AutoDownloadIntentStore.maxAge - 3600)
        store.record(episodeID: UUID(), subscriptionID: UUID(), podcastTitle: "Old", now: stale)
        let freshID = UUID()
        store.record(episodeID: freshID, subscriptionID: UUID(), podcastTitle: "Fresh")

        let reloaded = AutoDownloadIntentStore(fileURL: url)
        XCTAssertEqual(reloaded.intents.count, 1)
        XCTAssertTrue(reloaded.contains(episodeID: freshID))
    }

    func testCountCapDropsOldestFirst() {
        let store = AutoDownloadIntentStore(fileURL: temporaryFileURL())
        let base = Date()
        var ids: [UUID] = []
        for offset in 0...(AutoDownloadIntentStore.maxCount) {
            let id = UUID()
            ids.append(id)
            store.record(
                episodeID: id,
                subscriptionID: UUID(),
                podcastTitle: "Show \(offset)",
                now: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        XCTAssertEqual(store.intents.count, AutoDownloadIntentStore.maxCount)
        XCTAssertFalse(store.contains(episodeID: ids[0]), "Oldest intent is dropped at the cap")
        XCTAssertTrue(store.contains(episodeID: ids.last!))
    }

    func testMissingFileLoadsEmpty() {
        let store = AutoDownloadIntentStore(fileURL: temporaryFileURL())
        XCTAssertTrue(store.intents.isEmpty)
    }

    func testTerminalExhaustionPersistsAndUsesProgressiveCooldown() {
        let url = temporaryFileURL()
        let episodeID = UUID()
        let subscriptionID = UUID()
        let mediaURL = URL(string: "https://media.example/episode.mp3")!
        let now = Date()
        let store = AutoDownloadIntentStore(fileURL: url)

        let first = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: now
        )
        XCTAssertEqual(first.retryAfter.timeIntervalSince(now), 15 * 60, accuracy: 0.01)

        let secondAt = first.retryAfter
        let second = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: secondAt
        )
        XCTAssertEqual(second.retryAfter.timeIntervalSince(secondAt), 30 * 60, accuracy: 0.01)

        let reloaded = AutoDownloadIntentStore(fileURL: url)
        XCTAssertEqual(reloaded.failures.first?.consecutiveExhaustions, 2)
        XCTAssertNotNil(reloaded.activeFailure(
            episodeID: episodeID,
            mediaURL: mediaURL,
            now: secondAt
        ))
    }

    func testExpiredCooldownRetainsDurableExhaustionHistory() {
        let store = AutoDownloadIntentStore(fileURL: temporaryFileURL())
        let episodeID = UUID()
        let mediaURL = URL(string: "https://media.example/recovery.mp3")!
        let startedAt = Date()
        let failure = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: UUID(),
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: startedAt
        )

        XCTAssertNil(store.activeFailure(
            episodeID: episodeID,
            mediaURL: mediaURL,
            now: failure.retryAfter.addingTimeInterval(1)
        ))
        XCTAssertEqual(
            store.failureRecord(episodeID: episodeID)?.consecutiveExhaustions,
            1,
            "Starting a fresh short ladder must not erase durable cooldown escalation"
        )
    }

    func testChangedEnclosureClearsTerminalCooldown() {
        let store = AutoDownloadIntentStore(fileURL: temporaryFileURL())
        let episodeID = UUID()
        let oldURL = URL(string: "https://media.example/old.mp3")!
        let newURL = URL(string: "https://media.example/new.mp3")!
        store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: UUID(),
            mediaURL: oldURL,
            host: oldURL.host
        )

        XCTAssertNil(store.activeFailure(
            episodeID: episodeID,
            mediaURL: newURL
        ))
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testTerminalCooldownCapsAtOneHourAndPersistsEscalation() {
        let url = temporaryFileURL()
        let store = AutoDownloadIntentStore(fileURL: url)
        let episodeID = UUID()
        let subscriptionID = UUID()
        let mediaURL = URL(string: "https://media.example/retry.mp3")!
        let start = Date()

        let first = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: start
        )
        let second = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: first.retryAfter
        )
        let third = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: second.retryAfter
        )
        let fourth = store.recordExhaustion(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            mediaURL: mediaURL,
            host: mediaURL.host,
            now: third.retryAfter
        )

        XCTAssertEqual(
            third.retryAfter.timeIntervalSince(second.retryAfter),
            60 * 60,
            accuracy: 0.01
        )
        XCTAssertEqual(
            fourth.retryAfter.timeIntervalSince(third.retryAfter),
            60 * 60,
            accuracy: 0.01
        )
        XCTAssertNil(store.activeFailure(
            episodeID: episodeID,
            mediaURL: mediaURL,
            now: fourth.retryAfter
        ))
        XCTAssertEqual(
            AutoDownloadIntentStore(fileURL: url)
                .failures.first?.consecutiveExhaustions,
            4
        )
    }

    func testLoadsLegacyIntentArrayAndMigratesOnNextSave() throws {
        let url = temporaryFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let episodeID = UUID()
        let legacy = [AutoDownloadIntent(
            episodeID: episodeID,
            subscriptionID: UUID(),
            podcastTitle: "Legacy"
        )]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = AutoDownloadIntentStore(fileURL: url)
        XCTAssertTrue(store.contains(episodeID: episodeID))
        store.record(
            episodeID: UUID(),
            subscriptionID: UUID(),
            podcastTitle: "New"
        )
        XCTAssertEqual(
            AutoDownloadIntentStore(fileURL: url).intents.count,
            2
        )
    }
}
