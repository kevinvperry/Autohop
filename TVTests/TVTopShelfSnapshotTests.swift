import XCTest
import UIKit
import AutohopCore
@testable import AutohopTV

// AI CONTEXT — Regression coverage for the dynamic Top Shelf materialized-view
// boundary: Home ordering, Continue deduplication/progress, strict schema/path
// validation, atomic cache storage, and dual-location permission probes. Tests
// use isolated temporary folders and never depend on a simulator App Group.

final class TVTopShelfSnapshotTests: XCTestCase {
    func testPreparedFallbackUsesFourAcrossPosterDimensions() async throws {
        let artwork = await TVTopShelfArtworkPreparer.prepare(sourceURL: nil, stableID: "fallback")
        let oneX = try XCTUnwrap(UIImage(data: artwork.data1x))
        let twoX = try XCTUnwrap(UIImage(data: artwork.data2x))
        XCTAssertEqual(oneX.size, CGSize(width: 404, height: 608))
        XCTAssertEqual(twoX.size, CGSize(width: 808, height: 1_216))
        XCTAssertEqual(artwork.source, .placeholder)
    }

    func testBuilderPreservesQueueOrderAndDeduplicatesContinueListening() throws {
        let subscriptionID = UUID()
        let first = episode(subscriptionID: subscriptionID, title: "First", guid: "first")
        let second = episode(subscriptionID: subscriptionID, title: "Second", guid: "second")
        let firstKey = PlaybackPositionStore.key(for: first)
        let continuation = TVContinueListening(
            entry: history(episode: first, position: 600, duration: 1_800),
            episode: first
        )
        let candidate = try XCTUnwrap(TVTopShelfSnapshotBuilder.build(
            continueListening: continuation,
            queueRows: [row(first, position: 1), row(second, position: 2)]
        ))
        XCTAssertEqual(candidate.sections.map(\.kind), [.continueListening, .upNext])
        XCTAssertEqual(candidate.sections[0].items[0].episodeKey, firstKey)
        XCTAssertEqual(try XCTUnwrap(candidate.sections[0].items[0].playbackProgress), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(candidate.sections[1].items.map(\.episodeTitle), ["Second"])
    }

    func testBuilderOmitsEffectivelyFinishedContinueAndCapsItems() throws {
        let subscriptionID = UUID()
        let first = episode(subscriptionID: subscriptionID, title: "Nearly Done", guid: "near")
        let rows = (0..<14).map {
            row(episode(subscriptionID: subscriptionID, title: "E\($0)", guid: "g\($0)"), position: $0 + 1)
        }
        let candidate = try XCTUnwrap(TVTopShelfSnapshotBuilder.build(
            continueListening: .init(
                entry: history(episode: first, position: 1_750, duration: 1_800),
                episode: first
            ),
            queueRows: rows
        ))
        XCTAssertEqual(candidate.sections.map(\.kind), [.upNext])
        XCTAssertEqual(candidate.sections[0].items.count, TVTopShelfSnapshot.maximumItems)
    }

    func testNowPlayingIsFirstWhenEpisodeFallsBelowQueueCapAndIsDeduplicated() throws {
        let subscriptionID = UUID()
        let episodes = (0..<12).map {
            episode(subscriptionID: subscriptionID, title: "E\($0)", guid: "g\($0)")
        }
        let playing = episodes[11]
        let candidate = try XCTUnwrap(TVTopShelfSnapshotBuilder.build(
            nowPlaying: .init(
                episode: playing,
                podcastTitle: "Podcast",
                positionSeconds: 450
            ),
            continueListening: nil,
            queueRows: episodes.enumerated().map { row($0.element, position: $0.offset + 1) }
        ))

        XCTAssertEqual(candidate.sections.map(\.kind), [.currentlyPlaying, .upNext])
        XCTAssertEqual(candidate.sections[0].items[0].episodeKey, PlaybackPositionStore.key(for: playing))
        XCTAssertEqual(candidate.sections.flatMap(\.items).count, TVTopShelfSnapshot.maximumItems)
        XCTAssertEqual(
            candidate.sections.flatMap(\.items).filter { $0.episodeKey == PlaybackPositionStore.key(for: playing) }.count,
            1
        )
        XCTAssertEqual(try XCTUnwrap(candidate.sections[0].items[0].playbackProgress), 0.25, accuracy: 0.0001)
    }

    func testQueueTileCarriesSyncedProgress() throws {
        let subscriptionID = UUID()
        let partiallyPlayed = episode(subscriptionID: subscriptionID, title: "Partial", guid: "partial")
        let candidate = try XCTUnwrap(TVTopShelfSnapshotBuilder.build(
            continueListening: nil,
            queueRows: [row(partiallyPlayed, position: 1, playbackPosition: 600)]
        ))

        XCTAssertEqual(try XCTUnwrap(candidate.sections[0].items[0].playbackProgress), 1.0 / 3.0, accuracy: 0.0001)
    }

    func testAtomicStorageRoundTripAndTraversalRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TVTopShelfSharedStorage(containerURL: root)
        let item = TVTopShelfSnapshot.Item(
            id: "stable", subscriptionID: UUID(), episodeKey: "key",
            episodeTitle: "Episode", podcastTitle: "Podcast",
            artworkFilename1x: "stable@1x.jpg", artworkFilename2x: nil,
            playbackProgress: 0.5, expiresAt: nil
        )
        let publishedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000)
        let snapshot = TVTopShelfSnapshot(
            generation: 1, publishedAt: publishedAt, accountScope: "scope",
            sections: [.init(kind: .upNext, title: "Up Next", items: [item])]
        )
        try storage.write(snapshot, artwork: ["stable@1x.jpg": Data([1, 2, 3])])
        XCTAssertEqual(try storage.read(), snapshot)
        XCTAssertThrowsError(try storage.artworkURL(generation: 1, filename: "../secret"))
    }

    func testUnsupportedSchemaAndDuplicateIdentityFailClosed() {
        let item = TVTopShelfSnapshot.Item(
            id: "same", subscriptionID: UUID(), episodeKey: "key",
            episodeTitle: "Episode", podcastTitle: "Podcast",
            artworkFilename1x: "art.jpg", artworkFilename2x: nil,
            playbackProgress: nil, expiresAt: nil
        )
        let unsupported = TVTopShelfSnapshot(
            schemaVersion: 999, generation: 1, publishedAt: Date(), accountScope: "scope",
            sections: [.init(kind: .upNext, title: "Up Next", items: [item])]
        )
        XCTAssertThrowsError(try unsupported.validated())
        let duplicate = TVTopShelfSnapshot(
            generation: 1, publishedAt: Date(), accountScope: "scope",
            sections: [.init(kind: .upNext, title: "Up Next", items: [item, item])]
        )
        XCTAssertThrowsError(try duplicate.validated())
    }

    func testExtensionDiagnosticHeartbeatIsBoundedAndContainsNoContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TVTopShelfSharedStorage(containerURL: root)
        let heartbeat = TVTopShelfExtensionDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .manifestMissing,
            generation: nil,
            sectionCount: 0,
            itemCount: 0,
            loadMilliseconds: 4,
            detailCode: nil
        )

        try storage.writeExtensionDiagnostic(heartbeat)

        XCTAssertEqual(storage.readExtensionDiagnostic(), heartbeat)
        let encoded = try Data(contentsOf: root
            .appendingPathComponent("Library/Caches")
            .appendingPathComponent(TVTopShelfSharedConfiguration.directoryName)
            .appendingPathComponent(TVTopShelfExtensionDiagnostic.filename))
        XCTAssertLessThanOrEqual(encoded.count, TVTopShelfExtensionDiagnostic.maximumEncodedBytes)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("episodeTitle"))
    }


    func testStorageFailureReportsTheExactOperationWithoutAPath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-top-shelf-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        let storage = TVTopShelfSharedStorage(containerURL: file)
        let snapshot = TVTopShelfSnapshot(
            generation: 1, publishedAt: Date(), accountScope: "scope",
            sections: [.init(kind: .upNext, title: "Up Next", items: [.init(
                id: "stable", subscriptionID: UUID(), episodeKey: "key",
                episodeTitle: "Episode", podcastTitle: "Podcast",
                artworkFilename1x: "stable.jpg", artworkFilename2x: nil,
                playbackProgress: nil, expiresAt: nil
            )])]
        )
        XCTAssertThrowsError(try storage.write(snapshot, artwork: ["stable.jpg": Data([1])])) { error in
            let storageError = error as? TVTopShelfStorageError
            XCTAssertEqual(storageError?.operation, .createCaches)
            XCTAssertFalse(storageError?.diagnosticCode.contains(file.path) ?? true)
        }
    }

    func testWriteProbeSeparatelyReportsRootAndCaches() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = TVTopShelfSharedStorage(containerURL: root).probeWriteAccess()
        XCTAssertTrue(probe.containerAvailable)
        XCTAssertEqual(probe.containerRoot, "Writable")
        XCTAssertEqual(probe.libraryCaches, "Writable")
    }

    private func episode(subscriptionID: UUID, title: String, guid: String) -> Episode {
        var value = Episode(
            id: UUID(), subscriptionID: subscriptionID, guid: guid, title: title,
            audioURL: URL(string: "https://example.com/\(guid).mp3")!
        )
        value.durationSeconds = 1_800
        value.artworkURL = URL(string: "https://example.com/art.jpg")
        return value
    }

    private func row(
        _ episode: Episode,
        position: Int,
        playbackPosition: TimeInterval? = nil
    ) -> TVQueueRowModel {
        .init(
            id: PlaybackPositionStore.key(for: episode), subscriptionID: episode.subscriptionID,
            position: position, title: episode.title, podcastTitle: "Podcast",
            artworkURL: episode.artworkURL, durationSeconds: episode.durationSeconds,
            playbackPositionSeconds: playbackPosition,
            mediaKind: episode.mediaKind, episode: episode, pinState: nil
        )
    }

    private func history(episode: Episode, position: TimeInterval, duration: TimeInterval) -> ListeningHistoryEntry {
        .init(
            id: PlaybackPositionStore.key(for: episode), subscriptionID: episode.subscriptionID,
            episodeID: episode.id, episodeTitle: episode.title, podcastTitle: "Podcast",
            artworkURL: episode.artworkURL, streamURL: episode.audioURL, mediaKind: episode.mediaKind,
            publishedAt: nil, durationSeconds: duration, listenedSeconds: position,
            lastPositionSeconds: position, lastListenedAt: Date(), status: .listened
        )
    }
}
