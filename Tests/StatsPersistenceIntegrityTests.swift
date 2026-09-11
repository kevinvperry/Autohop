// AI CONTEXT — Tests/StatsPersistenceIntegrityTests.swift
// Regression coverage for the Phase 1 Stats/history durability envelope.
// These tests exercise locked-launch deferral, checksum rejection, backup
// recovery, and lossless merging of activity recorded before protected data
// becomes readable. No CloudKit or device filesystem is required.
import XCTest

#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class StatsPersistenceIntegrityTests: XCTestCase {
    @MainActor
    func testUnavailableStatsLoadCannotOverwriteAndMergesAfterRetry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.json")
        let subscriptionID = UUID()

        let initial = ListeningStatsStore(
            fileURL: url,
            legacyFileURL: nil,
            protectedDataAvailable: { true }
        )
        initial.addListeningTime(10, speed: 1, subscriptionID: subscriptionID, showTitle: "Show")
        initial.save()
        let durableBeforeLockedLaunch = try Data(contentsOf: url)

        var protectedDataIsAvailable = false
        let relaunched = ListeningStatsStore(
            fileURL: url,
            legacyFileURL: nil,
            protectedDataAvailable: { protectedDataIsAvailable }
        )
        XCTAssertEqual(relaunched.persistenceState, .temporarilyUnavailable)

        relaunched.addListeningTime(5, speed: 1, subscriptionID: subscriptionID, showTitle: "Show")
        relaunched.save()
        XCTAssertEqual(try Data(contentsOf: url), durableBeforeLockedLaunch)

        protectedDataIsAvailable = true
        relaunched.retryProtectedDataLoad()

        XCTAssertEqual(relaunched.persistenceState, .loaded)
        XCTAssertEqual(relaunched.summary(for: .lifetime).wallClockSeconds, 15, accuracy: 0.001)
        XCTAssertNotEqual(try Data(contentsOf: url), durableBeforeLockedLaunch)
    }

    @MainActor
    func testChecksumMismatchIsQuarantinedAndBlocksOverwriteWithoutBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.json")
        let subscriptionID = UUID()

        let initial = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        initial.addListeningTime(10, speed: 1, subscriptionID: subscriptionID, showTitle: "Show")

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["revision"] = 999
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try tampered.write(to: url, options: .atomic)

        let rejected = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        XCTAssertEqual(rejected.persistenceState, .corruptOrIncompatible)
        rejected.addListeningTime(5, speed: 1, subscriptionID: subscriptionID, showTitle: "Show")
        rejected.save()

        XCTAssertEqual(try Data(contentsOf: url), tampered)
        XCTAssertEqual(try corruptCopies(in: directory, prefix: "stats.corrupt-").count, 1)
    }

    @MainActor
    func testStatsStoreRestoresLastKnownGoodBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.json")
        let subscriptionID = UUID()

        let initial = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        initial.addListeningTime(10, speed: 1, subscriptionID: subscriptionID, showTitle: "Show")
        initial.addListeningTime(2, speed: 1, subscriptionID: subscriptionID, showTitle: "Show")
        initial.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stats.backup.json").path))

        try Data("not-json".utf8).write(to: url, options: .atomic)
        let recovered = ListeningStatsStore(fileURL: url, legacyFileURL: nil)

        XCTAssertEqual(recovered.persistenceState, .loaded)
        XCTAssertEqual(recovered.summary(for: .lifetime).wallClockSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(try corruptCopies(in: directory, prefix: "stats.corrupt-").count, 1)
    }

    @MainActor
    func testInvalidBackupWithMissingPrimaryIsNotTreatedAsFirstLaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primaryURL = directory.appendingPathComponent("stats.json")
        let backupURL = directory.appendingPathComponent("stats.backup.json")
        let invalidBackup = Data("recoverable-looking-but-invalid".utf8)
        try invalidBackup.write(to: backupURL, options: .atomic)

        let rejected = ListeningStatsStore(fileURL: primaryURL, legacyFileURL: nil)
        XCTAssertEqual(rejected.persistenceState, .corruptOrIncompatible)
        rejected.addListeningTime(5, speed: 1, subscriptionID: UUID(), showTitle: "Show")
        rejected.save()

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), invalidBackup)
        XCTAssertEqual(try corruptCopies(in: directory, prefix: "stats.backup.corrupt-").count, 1)
    }

    @MainActor
    func testUnavailableHistoryLoadCannotOverwriteAndMergesAfterRetry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let episode = makeEpisode()

        let initial = ListeningHistoryStore(fileURL: url, protectedDataAvailable: { true })
        initial.recordProgress(
            episode: episode,
            podcastTitle: "Show",
            artworkURL: nil,
            listenedSeconds: 10,
            positionSeconds: 10,
            durationSeconds: 100
        )
        initial.save()
        let durableBeforeLockedLaunch = try Data(contentsOf: url)

        var protectedDataIsAvailable = false
        let relaunched = ListeningHistoryStore(
            fileURL: url,
            protectedDataAvailable: { protectedDataIsAvailable }
        )
        relaunched.recordProgress(
            episode: episode,
            podcastTitle: "Show",
            artworkURL: nil,
            listenedSeconds: 5,
            positionSeconds: 15,
            durationSeconds: 100
        )
        relaunched.save()
        XCTAssertEqual(try Data(contentsOf: url), durableBeforeLockedLaunch)

        protectedDataIsAvailable = true
        relaunched.retryProtectedDataLoad()

        XCTAssertEqual(relaunched.persistenceState, .loaded)
        XCTAssertEqual(relaunched.entries.count, 1)
        XCTAssertEqual(relaunched.entries[0].listenedSeconds, 15, accuracy: 0.001)
        XCTAssertEqual(relaunched.entries[0].lastPositionSeconds, 15, accuracy: 0.001)
    }

    @MainActor
    func testFailedProjectionWriteIsReconciledAfterRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.json")
        let database = try AutohopDatabase()
        let show = UUID()

        var store: ListeningStatsStore? = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        store?.syncDatabase = database
        database._testFailNextStatsDayWrite = true
        store?.addListeningTime(12, speed: 1, subscriptionID: show, showTitle: "Show")
        store?.save()
        store = nil

        let relaunched = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        relaunched.syncDatabase = database

        XCTAssertEqual(try XCTUnwrap(database.pendingStatsDays().first).wallClockSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(relaunched.summary(for: .lifetime).wallClockSeconds, 12, accuracy: 0.001)
    }

    @MainActor
    func testOwnedCloudPartitionRestoresMissingLocalJSON() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AutohopDatabase()
        let day = DayStats(dayKey: "2026-09-01", wallClockSeconds: 42)
        let metadata = try StatsPartitionMetadata.make(
            day: day,
            generationID: "cloud-generation",
            revision: 7,
            writerDeviceID: DeviceIdentity.current
        )
        try database.registerOwnedStatsDeviceIDs([DeviceIdentity.current])
        XCTAssertTrue(try database.reconcileOwnedCloudStats(day: day, metadata: metadata, systemFields: nil))

        let store = ListeningStatsStore(
            fileURL: directory.appendingPathComponent("missing-stats.json"),
            legacyFileURL: nil
        )
        store.syncDatabase = database

        XCTAssertEqual(store.summary(for: .lifetime).wallClockSeconds, 42, accuracy: 0.001)
        XCTAssertEqual(store.healthSnapshot.recoveryStatus, "Recovered local days from SQLite")
    }

    @MainActor
    func testMissingJSONRetiresProjectionFromPreviousInstallationIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AutohopDatabase()
        let day = DayStats(dayKey: "2026-08-31", wallClockSeconds: 18)
        let metadata = try StatsPartitionMetadata.make(
            day: day,
            generationID: "retired-generation",
            revision: 4,
            writerDeviceID: "restored-installation-id"
        )
        try database.recordStatsDay(day, metadata: metadata)

        let store = ListeningStatsStore(
            fileURL: directory.appendingPathComponent("missing-stats.json"),
            legacyFileURL: nil
        )
        store.syncDatabase = database

        XCTAssertEqual(store.summary(for: .lifetime).wallClockSeconds, 18, accuracy: 0.001)
        XCTAssertTrue(try database.pendingStatsDays().isEmpty)
        XCTAssertTrue(try database.isOwnedStatsDeviceID("restored-installation-id"))
        XCTAssertTrue(try database.isRetiredStatsGeneration("retired-generation"))
    }

    @MainActor
    func testNewerSameGenerationSQLiteRevisionRepairsStaleJSON() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.json")
        let database = try AutohopDatabase()
        let original = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        original.syncDatabase = database
        original.addListeningTime(10, speed: 1, subscriptionID: UUID(), showTitle: "Show")
        original.save()

        let existing = try XCTUnwrap(database.allStatsDayProjections().first)
        var recoveredDay = existing.day
        recoveredDay.wallClockSeconds = 25
        let newerMetadata = try StatsPartitionMetadata.make(
            day: recoveredDay,
            generationID: existing.metadata.generationID,
            revision: existing.metadata.revision + 1,
            writerDeviceID: existing.metadata.writerDeviceID
        )
        try database.recordStatsDay(recoveredDay, metadata: newerMetadata)

        let relaunched = ListeningStatsStore(fileURL: url, legacyFileURL: nil)
        relaunched.syncDatabase = database

        XCTAssertEqual(relaunched.summary(for: .lifetime).wallClockSeconds, 25, accuracy: 0.001)
        XCTAssertEqual(relaunched.healthSnapshot.recoveryStatus, "Recovered local days from SQLite")
    }

    func testRemoteStatsAreIsolatedByCloudAccountScope() throws {
        let database = try AutohopDatabase()
        try database.setActiveStatsAccountScope("account-a")
        try database.applyRemoteStatsPartition(
            deviceID: "remote-device",
            day: DayStats(dayKey: "2026-09-01", wallClockSeconds: 10)
        )
        XCTAssertEqual(try database.remoteStatsByDayKey()["2026-09-01"]?.first?.wallClockSeconds, 10)

        try database.setActiveStatsAccountScope("account-b")
        XCTAssertTrue(try database.remoteStatsByDayKey().isEmpty)
        try database.applyRemoteStatsPartition(
            deviceID: "remote-device",
            day: DayStats(dayKey: "2026-09-01", wallClockSeconds: 20)
        )
        XCTAssertEqual(try database.remoteStatsByDayKey()["2026-09-01"]?.first?.wallClockSeconds, 20)

        try database.setActiveStatsAccountScope("account-a")
        XCTAssertEqual(try database.remoteStatsByDayKey()["2026-09-01"]?.first?.wallClockSeconds, 10)
    }

    @MainActor
    func testJSONArchiveRoundTripIsIdempotentAndDoesNotBecomeNewSyncAuthorship() throws {
        let sourceDirectory = try temporaryDirectory()
        let destinationDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let source = ListeningStatsStore(
            fileURL: sourceDirectory.appendingPathComponent("stats.json"),
            legacyFileURL: nil
        )
        source.addListeningTime(33, speed: 1, subscriptionID: UUID(), showTitle: "Show")
        let archive = try source.makeJSONExport()
        defer { try? FileManager.default.removeItem(at: archive) }

        let destination = ListeningStatsStore(
            fileURL: destinationDirectory.appendingPathComponent("stats.json"),
            legacyFileURL: nil
        )
        try destination.importJSONArchive(from: archive)
        XCTAssertEqual(destination.summary(for: .lifetime).wallClockSeconds, 33, accuracy: 0.001)
        XCTAssertThrowsError(try destination.importJSONArchive(from: archive))

        let database = try AutohopDatabase()
        destination.syncDatabase = database
        XCTAssertTrue(try database.pendingStatsDays().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-stats-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func corruptCopies(in directory: URL, prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private func makeEpisode() -> Episode {
        var episode = Episode(
            subscriptionID: UUID(),
            guid: "integrity-episode",
            title: "Episode",
            audioURL: URL(string: "https://example.com/episode.mp3")!
        )
        episode.durationSeconds = 100
        return episode
    }
}
