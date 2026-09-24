import XCTest
@testable import Autohop

// AI CONTEXT — Regression boundary for the route-safe Play Instant waiting
// policy. Integration state remains MainActor-owned by PlayInstantWorkflow;
// these tests pin its bounded lifetime, exact expiry semantics, and the final
// 120-second no-interruption boundary so a later refactor cannot restore
// indefinite pending autoplay, premature expiry, or end-of-episode disruption.
@MainActor
final class PlayInstantPolicyTests: XCTestCase {
    func testPendingCandidateExpiresAfterThirtyMinutes() {
        let queuedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            PlayInstantWorkflow.expiryDate(forQueuedAt: queuedAt),
            Date(timeIntervalSince1970: 2_800)
        )
    }

    func testCandidateRemainsArmedUntilExpiryBoundary() {
        let queuedAt = Date(timeIntervalSince1970: 1_000)
        let candidate = PlaybackCoordinator.PlayInstantCandidate(
            episodeID: UUID(),
            subscriptionID: UUID(),
            queuedAt: queuedAt,
            expiresAt: PlayInstantWorkflow.expiryDate(forQueuedAt: queuedAt)
        )

        XCTAssertFalse(
            PlayInstantWorkflow.isExpired(
                candidate,
                now: Date(timeIntervalSince1970: 2_799.999)
            )
        )
        XCTAssertTrue(
            PlayInstantWorkflow.isExpired(
                candidate,
                now: Date(timeIntervalSince1970: 2_800)
            )
        )
    }

    func testCurrentEpisodeWithExactlyTwoMinutesRemainingIsNotInterrupted() {
        XCTAssertFalse(
            PlayInstantWorkflow.mayInterruptCurrentEpisode(
                duration: 1_000,
                position: 880
            )
        )
    }

    func testCurrentEpisodeAboveTwoMinutesRemainingMayBeInterrupted() {
        XCTAssertTrue(
            PlayInstantWorkflow.mayInterruptCurrentEpisode(
                duration: 1_000,
                position: 879.999
            )
        )
    }

    func testCurrentEpisodeBelowTwoMinutesRemainingIsNotInterrupted() {
        XCTAssertFalse(
            PlayInstantWorkflow.mayInterruptCurrentEpisode(
                duration: 1_000,
                position: 999
            )
        )
    }

    func testUnknownDurationPreservesExistingEligibility() {
        XCTAssertTrue(
            PlayInstantWorkflow.mayInterruptCurrentEpisode(
                duration: nil,
                position: 100
            )
        )
    }
}
