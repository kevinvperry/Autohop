import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

// AI CONTEXT — Phase 6 regression gates for the purgeable tvOS projection DB.
// These prove launch cache round trips, bounded detail retention and total
// purge/rebuild semantics without CloudKit or a physical Apple TV.
final class TVProjectionStoreTests: XCTestCase {
    private func makeStore() throws -> (TVProjectionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try TVProjectionStore(path: directory.appendingPathComponent("projection.sqlite").path), directory)
    }

    func testCompactLibraryAndQueueRoundTripThenPurge() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let library = [TVLibraryProjectionEntry(id: id, title: "Show", author: "Host", artworkURL: nil, feedURL: URL(string: "https://example.com/feed.xml")!, priorityRank: 2)]
        let queue = QueueSnapshot(entries: [.init(episodeKey: "guid:1", subscriptionID: id, episodeTitle: "Episode", streamURL: URL(string: "https://example.com/episode.mp3"))], updatedAt: Date(), sourceDeviceID: "phone", generation: 7, authorityEpoch: "epoch")

        try store.saveLibrary(library)
        try store.saveQueue(queue)
        XCTAssertEqual(try store.loadLibrary(), library)
        XCTAssertEqual(try store.loadQueue(), queue)

        try store.purge()
        XCTAssertTrue(try store.loadLibrary().isEmpty)
        XCTAssertNil(try store.loadQueue())
    }

    func testEpisodeProjectionIsCappedAtTwentyFive() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscriptionID = UUID()
        let episodes = (0..<40).map { index in
            Episode(subscriptionID: subscriptionID, guid: "\(index)", title: "Episode \(index)", audioURL: URL(string: "https://example.com/\(index).mp3")!)
        }
        try store.saveEpisodes(TVEpisodeProjection(subscriptionID: subscriptionID, episodes: episodes))
        XCTAssertEqual(try store.loadEpisodes(subscriptionID: subscriptionID)?.episodes.count, 25)
    }

    func testParsedVideoEpisodeCreatesLightweightPlayableProjection() throws {
        let subscriptionID = UUID()
        let parsed = ParsedEpisode(
            guid: "video-guid", title: "Video Episode", description: nil,
            subtitle: nil, author: nil, publishedAt: Date(), durationSeconds: 60,
            audioURL: URL(string: "https://example.com/video.mp4"), mediaKind: .video,
            artworkURL: nil, fileSizeBytes: 42, isExplicit: false, chapters: [],
            externalChaptersURL: nil
        )
        let episode = try XCTUnwrap(parsed.projectedEpisode(
            subscriptionID: subscriptionID,
            feedArtworkURL: URL(string: "https://example.com/art.jpg")
        ))
        XCTAssertEqual(episode.mediaKind, .video)
        XCTAssertEqual(episode.audioURL.pathExtension, "mp4")
        XCTAssertEqual(episode.subscriptionID, subscriptionID)
        XCTAssertEqual(episode.artworkURL?.lastPathComponent, "art.jpg")
    }
}
