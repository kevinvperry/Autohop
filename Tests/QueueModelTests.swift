// AI CONTEXT — Tests/QueueModelTests.swift. Pins the Priority Stack pin
// semantics extracted from AppState into QueueModel (tvOS proposal Phase 0):
// Play Next pins move to the front in pin order, Play Last pins append in pin
// order, pins referencing episodes outside the base queue are ignored, and no
// pins = identity. These semantics are shared by iPhone/CarPlay today and
// tvOS/watch later — a failure here means queue ordering diverges on-device.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class QueueModelTests: XCTestCase {

    private func makeEpisode(title: String) -> Episode {
        Episode(
            subscriptionID: UUID(),
            guid: title,
            title: title,
            audioURL: URL(string: "https://e.com/\(title).mp3")!
        )
    }

    func testNoPinsReturnsBaseQueueUnchanged() {
        let base = [makeEpisode(title: "a"), makeEpisode(title: "b")]
        XCTAssertEqual(
            QueueModel.applyPins(base, pins: QueuePins()).map(\.id),
            base.map(\.id)
        )
    }

    func testPlayNextPinsMoveToFrontInPinOrder() {
        let a = makeEpisode(title: "a")
        let b = makeEpisode(title: "b")
        let c = makeEpisode(title: "c")
        let d = makeEpisode(title: "d")

        let ordered = QueueModel.applyPins(
            [a, b, c, d],
            pins: QueuePins(playNextIDs: [c.id, b.id])
        )

        XCTAssertEqual(ordered.map(\.title), ["c", "b", "a", "d"])
    }

    func testPlayLastPinsAppendInPinOrder() {
        let a = makeEpisode(title: "a")
        let b = makeEpisode(title: "b")
        let c = makeEpisode(title: "c")

        let ordered = QueueModel.applyPins(
            [a, b, c],
            pins: QueuePins(playLastIDs: [a.id])
        )

        XCTAssertEqual(ordered.map(\.title), ["b", "c", "a"])
    }

    func testPinsForEpisodesOutsideBaseQueueAreIgnored() {
        let a = makeEpisode(title: "a")
        let b = makeEpisode(title: "b")

        let ordered = QueueModel.applyPins(
            [a, b],
            pins: QueuePins(playNextIDs: [UUID()], playLastIDs: [UUID()])
        )

        XCTAssertEqual(ordered.map(\.title), ["a", "b"])
    }

    func testCombinedPinsKeepUnpinnedBaseOrderBetween() {
        let a = makeEpisode(title: "a")
        let b = makeEpisode(title: "b")
        let c = makeEpisode(title: "c")
        let d = makeEpisode(title: "d")

        let ordered = QueueModel.applyPins(
            [a, b, c, d],
            pins: QueuePins(playNextIDs: [d.id], playLastIDs: [a.id])
        )

        XCTAssertEqual(ordered.map(\.title), ["d", "b", "c", "a"])
    }

    // MARK: - streamableQueue (tvOS Phase 2)

    private func makeSubscription(title: String, rank: Int, episodes: [Episode]) -> Subscription {
        var sub = Subscription(
            id: UUID(), feedURL: URL(string: "https://f.com/\(title)")!,
            title: title, priorityRank: rank
        )
        sub.episodes = episodes
        return sub
    }

    private func makeEpisode(
        subscriptionID: UUID,
        title: String,
        publishedAt: Date,
        playedState: PlayedState = .unplayed,
        downloadState: DownloadState = .notDownloaded
    ) -> Episode {
        var episode = Episode(
            subscriptionID: subscriptionID, guid: title, title: title,
            audioURL: URL(string: "https://e.com/\(title).mp3")!
        )
        episode.publishedAt = publishedAt
        episode.playedState = playedState
        episode.downloadState = downloadState
        return episode
    }

    func testStreamableQueueIncludesNonDownloadedEpisodes() {
        // The whole point of this projection: unlike QueueService's
        // downloadedQueue, a streaming platform needs every unplayed episode,
        // downloaded or not.
        let subID = UUID()
        let episode = makeEpisode(subscriptionID: subID, title: "a", publishedAt: Date(), downloadState: .notDownloaded)
        let sub = makeSubscription(title: "Show", rank: 1, episodes: [episode])

        let queue = QueueModel.streamableQueue(from: [sub])
        XCTAssertEqual(queue.map(\.title), ["a"])
    }

    func testStreamableQueueExcludesPlayedAndArchivedPickingOldestRemainingUnplayed() {
        let subID = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        // "played"/"archived" are the oldest two — excluding them must not
        // just skip the show; the oldest still-eligible one ("playing") must
        // surface, not "unplayed" (which is newer).
        let played = makeEpisode(subscriptionID: subID, title: "played", publishedAt: base, playedState: .played)
        let archived = makeEpisode(subscriptionID: subID, title: "archived", publishedAt: base.addingTimeInterval(1), playedState: .archived)
        let playing = makeEpisode(subscriptionID: subID, title: "playing", publishedAt: base.addingTimeInterval(2), playedState: .playing)
        let unplayed = makeEpisode(subscriptionID: subID, title: "unplayed", publishedAt: base.addingTimeInterval(3))
        let sub = makeSubscription(title: "Show", rank: 1, episodes: [unplayed, played, archived, playing])

        let queue = QueueModel.streamableQueue(from: [sub])
        XCTAssertEqual(queue.map(\.title), ["playing"])
    }

    func testStreamableQueueReturnsOnlyOldestUnplayedPerShowInterleavedByPriority() {
        // The fix (2026-07-04): a show's full back-catalog must NOT dump
        // consecutively into Up Next — only its oldest unplayed episode
        // appears, interleaved with other shows by priority rank.
        let subA = UUID()
        let subB = UUID()
        let old = makeEpisode(subscriptionID: subA, title: "old", publishedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeEpisode(subscriptionID: subA, title: "newer", publishedAt: Date(timeIntervalSince1970: 2_000))
        let newest = makeEpisode(subscriptionID: subA, title: "newest", publishedAt: Date(timeIntervalSince1970: 3_000))
        let other = makeEpisode(subscriptionID: subB, title: "other", publishedAt: Date(timeIntervalSince1970: 1_500))

        let queue = QueueModel.streamableQueue(from: [
            makeSubscription(title: "Second", rank: 2, episodes: [other]),
            makeSubscription(title: "First", rank: 1, episodes: [newest, old, newer])
        ])

        // Only "old" (First's oldest unplayed) — not "newer"/"newest" too —
        // then "other" (Second, lower priority).
        XCTAssertEqual(queue.map(\.title), ["old", "other"])
    }
}
