import XCTest
@testable import AutohopTV
import AutohopCore

final class TVPlaybackRequestPolicyTests: XCTestCase {
    private func episode(
        id: UUID = UUID(),
        subscriptionID: UUID = UUID(),
        guid: String,
        url: String
    ) -> Episode {
        Episode(
            id: id,
            subscriptionID: subscriptionID,
            guid: guid,
            title: guid,
            audioURL: URL(string: url)!
        )
    }

    func testOnlyNewestAsyncRequestOwnsPresentationState() {
        var ownership = TVPlaybackRequestOwnership()
        let first = ownership.begin()
        let second = ownership.begin()

        XCTAssertFalse(ownership.owns(first))
        XCTAssertTrue(ownership.owns(second))

        ownership.invalidate()
        XCTAssertFalse(ownership.owns(second))
    }

    func testSameEnclosureReopensWithoutRestartAcrossReconstructedIDs() {
        let current = episode(
            subscriptionID: UUID(),
            guid: "old-guid",
            url: "https://cdn.example.com/episode.mp4"
        )
        let reconstructed = episode(
            subscriptionID: UUID(),
            guid: "new-guid",
            url: "https://cdn.example.com/episode.mp4"
        )

        XCTAssertTrue(
            TVPlaybackPresentationPolicy.representsSameEpisode(current, as: reconstructed)
        )
    }

    func testDifferentEnclosureStartsNewPlayback() {
        let current = episode(guid: "one", url: "https://cdn.example.com/one.mp4")
        let selected = episode(guid: "two", url: "https://cdn.example.com/two.mp4")

        XCTAssertFalse(
            TVPlaybackPresentationPolicy.representsSameEpisode(current, as: selected)
        )
    }
}
