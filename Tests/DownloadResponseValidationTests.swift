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
}
