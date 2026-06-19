// AI CONTEXT — Tests/HTTPResponseValidationTests.swift. Covers the shared HTTP
// status gate (AH-P2-008) used by the feed/search/charts/preview/chapters/artwork
// network clients: non-2xx responses are rejected, 304 and non-HTTP pass.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class HTTPResponseValidationTests: XCTestCase {

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://h.example/x")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    func testSuccessAndNotModifiedPass() throws {
        for status in [200, 201, 204, 299, 304] {
            XCTAssertNoThrow(try HTTPResponseValidation.validate(http(status)))
            XCTAssertTrue(HTTPResponseValidation.isAcceptable(http(status)))
        }
    }

    func testErrorStatusesThrow() {
        for status in [400, 401, 403, 404, 500, 503] {
            XCTAssertThrowsError(try HTTPResponseValidation.validate(http(status))) { error in
                XCTAssertEqual(error as? HTTPResponseError, .unacceptableStatus(status))
            }
            XCTAssertFalse(HTTPResponseValidation.isAcceptable(http(status)))
        }
    }

    func testNonHTTPAndNilPass() throws {
        XCTAssertNoThrow(try HTTPResponseValidation.validate(nil))
        let nonHTTP = URLResponse(url: URL(string: "file:///x")!, mimeType: nil,
                                  expectedContentLength: 0, textEncodingName: nil)
        XCTAssertNoThrow(try HTTPResponseValidation.validate(nonHTTP))
        XCTAssertTrue(HTTPResponseValidation.isAcceptable(nil))
    }
}
