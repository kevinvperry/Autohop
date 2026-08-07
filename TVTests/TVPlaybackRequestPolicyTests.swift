import XCTest
@testable import AutohopTV
import AutohopCore

// AI CONTEXT — TVTests/TVPlaybackRequestPolicyTests.swift
// PURPOSE: Regression coverage for asynchronous player-presentation ownership
// and same-media detection across locally reconstructed tvOS episode objects.
// OWNERSHIP: Tests TVPlaybackRequestOwnership and
// TVPlaybackPresentationPolicy without constructing AVPlayer or navigation UI.
// INVARIANTS: Only the newest request generation may present or mutate player
// state; identical enclosure URLs represent the same playable episode even if
// local UUID/GUID values were reconstructed; different enclosures must start a
// new playback session.
// FAILURE MEANING: A failure risks stale async work reopening the player,
// restarting video, or losing resume state. Fix the policy boundary rather than
// adding competing identity checks in TVMainTabView or TVPlayerView.
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
