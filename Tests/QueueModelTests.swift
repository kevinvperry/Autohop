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
}
