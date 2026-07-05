// AI CONTEXT — Tests/ArtworkURLTests.swift. Guards ArtworkURL.upscaled — the
// best-effort mzstatic/iTunes art upscaler used by the tvOS artwork loader.
// The contract: upgrade recognized resizable URLs that are too small; leave
// everything else (self-hosted, unknown, already-large) untouched.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class ArtworkURLTests: XCTestCase {

    func testUpscalesSmallMzstaticURL() {
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/abc/def/300x300bb.jpg")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 1000)
        XCTAssertEqual(out?.absoluteString, "https://is1-ssl.mzstatic.com/image/thumb/abc/def/1000x1000bb.jpg")
    }

    func testPreservesSuffixlessAndOtherExtensions() {
        let url = URL(string: "https://cdn.example.com/art/64x64.png")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 600)
        XCTAssertEqual(out?.absoluteString, "https://cdn.example.com/art/600x600.png")
    }

    func testDoesNotShrinkAlreadyLargeArt() {
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/x/y/3000x3000bb.jpg")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 1000)
        XCTAssertEqual(out?.absoluteString, url?.absoluteString, "Never downscale a larger source")
    }

    func testLeavesNonResizableURLUnchanged() {
        let url = URL(string: "https://example.com/podcast/cover-art.jpg")
        XCTAssertEqual(ArtworkURL.upscaled(url, toMinimumPixels: 1000)?.absoluteString, url?.absoluteString)
    }

    func testNonImageExtensionUnchanged() {
        let url = URL(string: "https://example.com/a/300x300.mp3")
        XCTAssertEqual(ArtworkURL.upscaled(url, toMinimumPixels: 1000)?.absoluteString, url?.absoluteString)
    }

    func testNilAndPreservesQuery() {
        XCTAssertNil(ArtworkURL.upscaled(nil, toMinimumPixels: 1000))
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/x/y/200x200bb.jpg?v=2")
        let out = ArtworkURL.upscaled(url, toMinimumPixels: 800)
        XCTAssertEqual(out?.absoluteString, "https://is1-ssl.mzstatic.com/image/thumb/x/y/800x800bb.jpg?v=2")
    }
}
