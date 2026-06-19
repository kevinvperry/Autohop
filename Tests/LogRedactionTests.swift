// AI CONTEXT — Tests/LogRedactionTests.swift. Covers AppLogger.redactSensitiveText
// (AH-P2-015): signed query strings, URL fragments, key=value credentials, and
// bearer tokens must be stripped from diagnostic log text, while ordinary values
// are left intact.
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
        XCTAssertTrue(out.contains("https://cdn.example.com/a.mp3?[redacted]"))
    }

    func testStripsUrlFragment() {
        let out = AppLogger.redactSensitiveText("url https://host.example/path#token=abc.def")
        XCTAssertFalse(out.contains("abc.def"))
        XCTAssertTrue(out.contains("#[redacted]"))
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
}
