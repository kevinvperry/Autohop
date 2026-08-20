import XCTest
@testable import AutohopTV

// AI CONTEXT — Regression coverage for the Release-build, in-memory App Review
// demonstration. Tests protect deterministic fixtures, reset semantics and the
// absence of persistence-facing dependencies from the demo session contract.

@MainActor
final class TVDemoSessionTests: XCTestCase {
    func testFixtureCoversLibraryQueueHistoryAudioAndVideo() {
        let session = TVDemoSession()

        XCTAssertEqual(session.shows.count, 4)
        XCTAssertGreaterThanOrEqual(session.upNext.count, 4)
        XCTAssertFalse(session.history.isEmpty)
        XCTAssertTrue(session.shows.flatMap(\.episodes).contains { $0.mediaKind == .audio })
        XCTAssertTrue(session.shows.flatMap(\.episodes).contains { $0.mediaKind == .video })
        XCTAssertNotNil(session.continueEpisode)
    }

    func testMutationsRemainEphemeralAndResetRestoresFixture() {
        let session = TVDemoSession()
        let baselineQueue = session.upNext
        let baselineQueueIDs = baselineQueue.map(\.id)
        let episode = try! XCTUnwrap(baselineQueue.last)

        session.playNext(episode)
        session.recordProgress(7, for: episode)
        session.archive(episode)
        XCTAssertNotEqual(session.upNext, baselineQueue)
        XCTAssertTrue(session.archivedEpisodeIDs.contains(episode.id))

        session.reset()
        XCTAssertEqual(session.upNext.map(\.id), baselineQueueIDs)
        XCTAssertTrue(session.archivedEpisodeIDs.isEmpty)
        XCTAssertNil(session.progressByEpisodeID[episode.id])
    }
}
