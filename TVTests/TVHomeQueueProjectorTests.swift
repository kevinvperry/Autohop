import XCTest
import AutohopCore
@testable import AutohopTV

// AI CONTEXT — Regression coverage for Home's presentation-only hero/queue
// deduplication. The projector must hide the featured episode without changing
// the authoritative phone-authored queue or disturbing its remaining order.
final class TVHomeQueueProjectorTests: XCTestCase {
    func testContinueListeningEpisodeIsExcludedFromRenderedQueue() {
        let first = episode(title: "First", guid: "first")
        let second = episode(title: "Second", guid: "second")
        let rows = [row(first, position: 1), row(second, position: 2)]
        let continuation = TVContinueListening(entry: history(first), episode: first)

        let projected = TVHomeQueueProjector.rows(
            queueRows: rows, currentEpisode: nil, continueListening: continuation
        )

        XCTAssertEqual(projected.map(\.id), [PlaybackPositionStore.key(for: second)])
        XCTAssertEqual(rows.count, 2, "Projection must not mutate the authoritative queue")
    }

    func testUnresolvedContinueListeningUsesHistoryIdentityForExclusion() {
        let first = episode(title: "First", guid: "first")
        let continuation = TVContinueListening(entry: history(first), episode: nil)
        let projected = TVHomeQueueProjector.rows(
            queueRows: [row(first, position: 1)], currentEpisode: nil,
            continueListening: continuation
        )
        XCTAssertTrue(projected.isEmpty)
    }

    private func episode(title: String, guid: String) -> Episode {
        Episode(subscriptionID: UUID(), guid: guid, title: title,
                audioURL: URL(string: "https://example.com/\(guid).mp3")!)
    }

    private func row(_ episode: Episode, position: Int) -> TVQueueRowModel {
        .init(id: PlaybackPositionStore.key(for: episode),
              subscriptionID: episode.subscriptionID, position: position,
              title: episode.title, podcastTitle: "Podcast", artworkURL: nil,
              durationSeconds: nil, playbackPositionSeconds: nil,
              mediaKind: episode.mediaKind, episode: episode, pinState: nil)
    }

    private func history(_ episode: Episode) -> ListeningHistoryEntry {
        .init(id: PlaybackPositionStore.key(for: episode),
              subscriptionID: episode.subscriptionID, episodeID: episode.id,
              episodeTitle: episode.title, podcastTitle: "Podcast",
              artworkURL: nil, streamURL: episode.audioURL,
              mediaKind: episode.mediaKind, publishedAt: nil,
              durationSeconds: 1_000, listenedSeconds: 100,
              lastPositionSeconds: 100, lastListenedAt: Date(), status: .listened)
    }
}
