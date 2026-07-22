import Foundation
import XCTest
@testable import Autohop

// AI CONTEXT — Tests/WidgetSharedStorageTests.swift
//
// Characterizes the Stage 1/2 widget boundary without requiring an App Group
// entitlement: every test injects an isolated temporary container. These tests
// protect the five-episode display cap, atomic Codable round-trip, required
// thumbnail directory, schema rejection, basename-only thumbnail rule, bounded
// artwork garbage collection, and the explicit 24-hour stale contract. They
// intentionally do not exercise WidgetKit rendering or physical-device reloads.

final class WidgetSharedStorageTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testSnapshotCapsDisplayEpisodesButPreservesFullQueueCount() {
        let episodes = (0..<8).map(makeEpisode)

        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 100),
            upNextTotalCount: 8,
            isPlaying: true,
            episodes: episodes
        )

        XCTAssertEqual(snapshot.episodes.count, 5)
        XCTAssertEqual(snapshot.upNextTotalCount, 8)
        XCTAssertEqual(snapshot.episodes.map(\.episodeTitle), [
            "Episode 0", "Episode 1", "Episode 2", "Episode 3", "Episode 4"
        ])
    }

    func testAtomicSnapshotRoundTripAndArtworkDirectoryCreation() throws {
        let storage = WidgetSharedStorage(containerURL: temporaryDirectory)
        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 123.456),
            upNextTotalCount: 1,
            isPlaying: false,
            episodes: [makeEpisode(index: 0)]
        )

        try storage.write(snapshot)

        XCTAssertEqual(try storage.read(), snapshot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try storage.snapshotURL().path
        ))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try storage.artworkDirectoryURL().path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testUnsupportedSchemaIsRejectedBeforeWrite() {
        let storage = WidgetSharedStorage(containerURL: temporaryDirectory)
        let snapshot = WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion + 1,
            generatedAt: Date(),
            upNextTotalCount: 0,
            isPlaying: false,
            episodes: []
        )

        XCTAssertThrowsError(try storage.write(snapshot)) { error in
            XCTAssertEqual(
                error as? WidgetSharedStorageError,
                .unsupportedSchemaVersion(WidgetSnapshot.currentSchemaVersion + 1)
            )
        }
    }

    func testThumbnailLocationRejectsPathTraversal() {
        let storage = WidgetSharedStorage(containerURL: temporaryDirectory)

        XCTAssertNoThrow(try storage.thumbnailURL(filename: "episode.jpg"))
        XCTAssertThrowsError(try storage.thumbnailURL(filename: "../episode.jpg")) {
            error in
            XCTAssertEqual(
                error as? WidgetSharedStorageError,
                .invalidThumbnailFilename
            )
        }
        XCTAssertThrowsError(try storage.thumbnailURL(filename: "folder/episode.jpg"))
    }

    func testThumbnailWriteEnumerationAndGarbageCollection() throws {
        let storage = WidgetSharedStorage(containerURL: temporaryDirectory)
        try storage.writeThumbnail(Data([1, 2, 3]), filename: "keep.jpg")
        try storage.writeThumbnail(Data([4, 5, 6]), filename: "remove.jpg")

        XCTAssertEqual(
            try storage.thumbnailFilenames(),
            ["keep.jpg", "remove.jpg"]
        )

        try storage.removeThumbnails(except: ["keep.jpg"])

        XCTAssertEqual(try storage.thumbnailFilenames(), ["keep.jpg"])
        XCTAssertEqual(
            try Data(contentsOf: storage.thumbnailURL(filename: "keep.jpg")),
            Data([1, 2, 3])
        )
    }

    func testStaleSnapshotBoundaryIsTwentyFourHours() {
        XCTAssertEqual(
            WidgetSharedConfiguration.staleSnapshotInterval,
            24 * 60 * 60
        )
    }

    func testCorruptSnapshotCanBeRemovedWithoutDeletingArtwork() throws {
        let storage = WidgetSharedStorage(containerURL: temporaryDirectory)
        try storage.prepareDirectories()
        try Data("not-json".utf8).write(to: storage.snapshotURL())
        try storage.writeThumbnail(Data([7]), filename: "retained.jpg")

        XCTAssertThrowsError(try storage.read())
        try storage.removeSnapshot()

        XCTAssertNil(try storage.read())
        XCTAssertEqual(try storage.thumbnailFilenames(), ["retained.jpg"])
    }

    func testThumbnailReadBudgetIsOneMegabyte() {
        XCTAssertEqual(
            WidgetSharedConfiguration.maximumThumbnailBytes,
            1_048_576
        )
    }

    private func makeEpisode(index: Int) -> WidgetDisplayEpisode {
        WidgetDisplayEpisode(
            identity: WidgetEpisodeIdentity(
                subscriptionID: UUID(
                    uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))"
                )!,
                episodeKey: "guid:episode-\(index)"
            ),
            episodeTitle: "Episode \(index)",
            podcastTitle: "Podcast",
            durationSeconds: 3_600,
            remainingSeconds: 1_800,
            isCurrent: index == 0,
            thumbnailFilename: "episode-\(index).jpg",
            isVideo: false,
            isExplicit: nil
        )
    }
}
