// AI CONTEXT — Tests/LogRedactionTests.swift. Covers AppLogger.redactSensitiveText
// (AH-P2-015): signed query strings, URL user-info/fragments, key=value
// credentials, and bearer tokens must be stripped from diagnostic log text.
// URLs are then replaced with stable privacy-safe pseudonyms, so tests must not
// require even a sanitised host/path to survive. Also pins the 2026-07-21 lazy
// metadata gate so disabled diagnostics cannot perform expensive projection.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class LogRedactionTests: XCTestCase {

    func testStripsQueryString() {
        let out = AppLogger.redactSensitiveText("GET https://cdn.example.com/a.mp3?token=secret123&exp=999 ok")
        XCTAssertFalse(out.contains("secret123"))
        XCTAssertFalse(out.contains("cdn.example.com"))
        XCTAssertTrue(out.contains("[url:"))
    }

    func testStripsUrlFragment() {
        let out = AppLogger.redactSensitiveText("url https://host.example/path#token=abc.def")
        XCTAssertFalse(out.contains("abc.def"))
        XCTAssertFalse(out.contains("host.example"))
        XCTAssertTrue(out.contains("[url:"))
    }

    func testStripsURLUserInformation() {
        let out = AppLogger.redactSensitiveText(
            "GET https://member:privatePassword@example.com/audio.mp3"
        )
        XCTAssertFalse(out.contains("member:privatePassword"))
        XCTAssertFalse(out.contains("example.com"))
        XCTAssertTrue(out.contains("[url:"))
    }

    func testRedactsAuthorizationAndCookieKeys() {
        XCTAssertFalse(AppLogger.redactSensitiveText("authorization=Bearerabc123").contains("Bearerabc123"))
        XCTAssertFalse(AppLogger.redactSensitiveText("cookie=sessionid=xyz").contains("sessionid=xyz"))
        XCTAssertFalse(AppLogger.redactSensitiveText("jwt=eyJhbGciOi").contains("eyJhbGciOi"))
    }

    func testRedactsBearerToken() {
        let out = AppLogger.redactSensitiveText("Authorization: Bearer eyJ0eXAiOiJKV1Qi.payload.sig")
        XCTAssertFalse(out.contains("eyJ0eXAiOiJKV1Qi"))
        XCTAssertTrue(out.contains("Bearer [redacted]"))
    }

    func testLeavesOrdinaryTextIntact() {
        let text = "episode=My Show count=42 duration=1800"
        XCTAssertEqual(AppLogger.redactSensitiveText(text), text)
    }

    func testDisabledLoggerDoesNotEvaluateMetadata() {
        let logger = AppLogger()
        logger.setEnabled(false)
        var evaluated = false
        func expensiveMetadata() -> [String: String] {
            evaluated = true
            return ["value": "built"]
        }

        logger.info(
            "test.lazyMetadata",
            "Metadata should remain lazy",
            metadata: expensiveMetadata()
        )

        XCTAssertFalse(evaluated)
    }

    func testVerboseLoggerDoesNotEvaluateMetadataWhenVerboseIsDisabled() {
        let logger = AppLogger()
        logger.setEnabled(true)
        logger.setVerboseEnabled(false)
        var evaluated = false
        func expensiveMetadata() -> [String: String] {
            evaluated = true
            return ["value": "built"]
        }

        logger.verbose(
            "test.verboseLazyMetadata",
            "Verbose metadata should remain lazy",
            metadata: expensiveMetadata()
        )

        XCTAssertFalse(evaluated)
    }
}
