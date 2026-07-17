import XCTest

#if canImport(AutohopCore)
@testable import AutohopCore
#else
@testable import Autohop
#endif

// AI CONTEXT — Regression coverage for the Version 1.4 development-build bug
// where After Playing Auto Archive rewrote a completed Listening History entry.
// Repair is intentionally limited to an exact EOF position so nearly-complete
// but genuinely auto-archived episodes retain their archived outcome.
final class ListeningHistoryCompletionRepairTests: XCTestCase {
    private func entry(position: TimeInterval, duration: TimeInterval) -> ListeningHistoryEntry {
        ListeningHistoryEntry(
            id: "subscription|guid:episode",
            subscriptionID: UUID(),
            episodeID: UUID(),
            episodeTitle: "Episode",
            podcastTitle: "Podcast",
            artworkURL: nil,
            publishedAt: nil,
            durationSeconds: duration,
            listenedSeconds: position,
            lastPositionSeconds: position,
            lastListenedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .archived,
            completionKind: .autoArchived,
            completionPercent: nil,
            listenedDurationSeconds: nil,
            episodeDurationSeconds: duration
        )
    }

    func testRepairsAutoArchiveOverwriteAtEndOfEpisode() {
        var subject = entry(position: 1_800, duration: 1_800)

        XCTAssertTrue(subject.repairAutoArchiveOverwriteIfClearlyCompleted())
        XCTAssertEqual(subject.status, .played)
        XCTAssertEqual(subject.completionKind, .finishedNaturally)
        XCTAssertEqual(subject.completionPercent, 1)
        XCTAssertEqual(subject.listenedDurationSeconds, 1_800)
    }

    func testDoesNotReclassifyGenuineAutoArchiveBeforeEnd() {
        var subject = entry(position: 1_790, duration: 1_800)

        XCTAssertFalse(subject.repairAutoArchiveOverwriteIfClearlyCompleted())
        XCTAssertEqual(subject.status, .archived)
        XCTAssertEqual(subject.completionKind, .autoArchived)
    }
}
