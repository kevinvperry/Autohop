import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class DownloadRecoveryPolicyTests: XCTestCase {
    func testScheduledRetryOwnsRecoveryBeforeStoredState() {
        XCTAssertEqual(
            DownloadRecoveryPolicy.disposition(
                storedState: .downloading,
                hasScheduledRetry: true,
                hasLiveTask: false,
                isLocallyQueued: false
            ),
            .scheduledRetry
        )
    }

    func testLiveTaskAndLocalQueueAreConcreteOwners() {
        XCTAssertEqual(
            DownloadRecoveryPolicy.disposition(
                storedState: .downloading,
                hasScheduledRetry: false,
                hasLiveTask: true,
                isLocallyQueued: false
            ),
            .liveURLSessionTask
        )
        XCTAssertEqual(
            DownloadRecoveryPolicy.disposition(
                storedState: .queued,
                hasScheduledRetry: false,
                hasLiveTask: false,
                isLocallyQueued: true
            ),
            .localPendingQueue
        )
    }

    func testStoredTransferWithoutOwnerIsRecoverableOrphan() {
        for state in [DownloadState.downloading, .queued] {
            XCTAssertEqual(
                DownloadRecoveryPolicy.disposition(
                    storedState: state,
                    hasScheduledRetry: false,
                    hasLiveTask: false,
                    isLocallyQueued: false
                ),
                .orphanedStoredTransfer
            )
        }
    }

    func testFailedOrNotDownloadedIntentIsEligible() {
        for state in [DownloadState.failed, .notDownloaded] {
            XCTAssertEqual(
                DownloadRecoveryPolicy.disposition(
                    storedState: state,
                    hasScheduledRetry: false,
                    hasLiveTask: false,
                    isLocallyQueued: false
                ),
                .eligibleForRecovery
            )
        }
    }

    func testRetryPresentationRequiresConcreteRetryOwnership() {
        XCTAssertEqual(
            DownloadRecoveryPolicy.retryPresentation(
                hasScheduledRetry: true,
                isTerminalFailure: false
            ),
            .waitingToRetry
        )
        XCTAssertEqual(
            DownloadRecoveryPolicy.retryPresentation(
                hasScheduledRetry: false,
                isTerminalFailure: true
            ),
            .preserveTerminalFailure
        )
        XCTAssertEqual(
            DownloadRecoveryPolicy.retryPresentation(
                hasScheduledRetry: false,
                isTerminalFailure: false
            ),
            .paused
        )
    }
}
