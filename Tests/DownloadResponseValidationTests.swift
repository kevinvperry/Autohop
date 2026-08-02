// AI CONTEXT — Tests/DownloadResponseValidationTests.swift. Regression coverage
// for AH-P1-002: DownloadManager must reject non-success HTTP responses in
// didFinishDownloadingTo so a 4xx/5xx body (HTML error/login/captive-portal page)
// is never stored as episode media. Exercises the pure classifier
// DownloadManager.rejectableHTTPStatus(of:) which gates the store path.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class DownloadResponseValidationTests: XCTestCase {

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://host.example/audio/ep.mp3")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testSuccessStatusesAreAccepted() {
        for status in [200, 201, 206, 299] {
            XCTAssertNil(
                DownloadManager.rejectableHTTPStatus(of: httpResponse(status)),
                "Status \(status) should be accepted as a successful download"
            )
        }
    }

    func testErrorStatusesAreRejectedWithTheirCode() {
        for status in [301, 400, 401, 404, 410, 500, 503] {
            XCTAssertEqual(
                DownloadManager.rejectableHTTPStatus(of: httpResponse(status)),
                status,
                "Status \(status) should be rejected and surface its code"
            )
        }
    }

    func testNilResponseIsAccepted() {
        // A missing response should not block storage — downstream playability checks apply.
        XCTAssertNil(DownloadManager.rejectableHTTPStatus(of: nil))
    }

    func testNonHTTPResponseIsAccepted() {
        let nonHTTP = URLResponse(
            url: URL(string: "file:///tmp/ep.mp3")!,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertNil(DownloadManager.rejectableHTTPStatus(of: nonHTTP))
    }

    func testHTTPStatusErrorCarriesCode() {
        XCTAssertEqual(DownloadError.httpStatus(404), DownloadError.httpStatus(404))
        XCTAssertNotEqual(DownloadError.httpStatus(404), DownloadError.httpStatus(500))
    }

    // MARK: - Implausibly small body (LOG-DL-001: 17-byte body for a 30 MB episode)

    func testRejectsTinyBodyWhenFeedDeclaredLarge() {
        // The exact logged case: 17 bytes received, feed declared ~30 MB.
        XCTAssertTrue(DownloadManager.isImplausiblySmallDownload(actualBytes: 17, expectedBytes: 30_304_896))
    }

    func testRejectsZeroBytes() {
        XCTAssertTrue(DownloadManager.isImplausiblySmallDownload(actualBytes: 0, expectedBytes: 30_304_896))
        XCTAssertTrue(DownloadManager.isImplausiblySmallDownload(actualBytes: 0, expectedBytes: nil))
    }

    func testAcceptsFullSizeDownload() {
        XCTAssertFalse(DownloadManager.isImplausiblySmallDownload(actualBytes: 30_304_896, expectedBytes: 30_304_896))
    }

    func testAcceptsPlausibleSmallerThanDeclared() {
        // 50 KB actual against a 100 KB declared clip — above the 5%/64 KB floor, so accepted.
        XCTAssertFalse(DownloadManager.isImplausiblySmallDownload(actualBytes: 51_200, expectedBytes: 102_400))
    }

    func testUnknownExpectedRejectsOnlyTinyBodies() {
        XCTAssertTrue(DownloadManager.isImplausiblySmallDownload(actualBytes: 17, expectedBytes: nil))
        XCTAssertFalse(DownloadManager.isImplausiblySmallDownload(actualBytes: 200_000, expectedBytes: nil))
    }

    func testFloorBoundary() {
        // 64 KB exactly against a large declared size is accepted; just under is rejected.
        XCTAssertFalse(DownloadManager.isImplausiblySmallDownload(actualBytes: 65_536, expectedBytes: 30_304_896))
        XCTAssertTrue(DownloadManager.isImplausiblySmallDownload(actualBytes: 65_535, expectedBytes: 30_304_896))
    }

    func testIncompleteDownloadErrorEquatable() {
        XCTAssertEqual(DownloadError.incompleteDownload(actualBytes: 17, expectedBytes: 30),
                       DownloadError.incompleteDownload(actualBytes: 17, expectedBytes: 30))
        XCTAssertNotEqual(DownloadError.incompleteDownload(actualBytes: 17, expectedBytes: 30),
                          DownloadError.incompleteDownload(actualBytes: 18, expectedBytes: 30))
    }

    func testFirstByteToleranceExpandsOutsideActiveApplication() {
        XCTAssertEqual(
            DownloadManager.firstByteWaitThreshold(applicationIsActive: true),
            60
        )
        XCTAssertEqual(
            DownloadManager.firstByteWaitThreshold(applicationIsActive: false),
            4 * 60
        )
        XCTAssertEqual(
            DownloadManager.firstByteWaitThreshold(
                applicationIsActive: false,
                hasActiveExecutionWindow: true
            ),
            60,
            "Screen-closed audio is an executable window, not suspension"
        )
    }

    func testWatchdogFinalGateCancelsOnlyCurrentZeroByteRunningTask() {
        XCTAssertTrue(DownloadManager.shouldCancelFirstByteTimeout(
            taskIdentityMatches: true,
            cancellationAlreadyClaimed: false,
            taskState: .running,
            liveBytes: 0,
            trackedBytes: 0,
            waitingForConnectivity: false
        ))
    }

    func testWatchdogFinalGateRejectsDuplicateAndStaleGenerationDecisions() {
        XCTAssertFalse(DownloadManager.shouldCancelFirstByteTimeout(
            taskIdentityMatches: true,
            cancellationAlreadyClaimed: true,
            taskState: .running,
            liveBytes: 0,
            trackedBytes: 0,
            waitingForConnectivity: false
        ))
        XCTAssertFalse(DownloadManager.shouldCancelFirstByteTimeout(
            taskIdentityMatches: false,
            cancellationAlreadyClaimed: false,
            taskState: .running,
            liveBytes: 0,
            trackedBytes: 0,
            waitingForConnectivity: false
        ))
    }

    func testWatchdogFinalGateTreatsLatePayloadOrCompletionAsRecovery() {
        for state in [
            URLSessionTask.State.suspended,
            .canceling,
            .completed
        ] {
            XCTAssertFalse(DownloadManager.shouldCancelFirstByteTimeout(
                taskIdentityMatches: true,
                cancellationAlreadyClaimed: false,
                taskState: state,
                liveBytes: 0,
                trackedBytes: 0,
                waitingForConnectivity: false
            ))
        }
        XCTAssertFalse(DownloadManager.shouldCancelFirstByteTimeout(
            taskIdentityMatches: true,
            cancellationAlreadyClaimed: false,
            taskState: .running,
            liveBytes: 1,
            trackedBytes: 0,
            waitingForConnectivity: false
        ))
        XCTAssertFalse(DownloadManager.shouldCancelFirstByteTimeout(
            taskIdentityMatches: true,
            cancellationAlreadyClaimed: false,
            taskState: .running,
            liveBytes: 0,
            trackedBytes: 1,
            waitingForConnectivity: false
        ))
        XCTAssertFalse(DownloadManager.shouldCancelFirstByteTimeout(
            taskIdentityMatches: true,
            cancellationAlreadyClaimed: false,
            taskState: .running,
            liveBytes: 0,
            trackedBytes: 0,
            waitingForConnectivity: true
        ))
    }
}
