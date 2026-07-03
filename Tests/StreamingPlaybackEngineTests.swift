// AI CONTEXT — Tests/StreamingPlaybackEngineTests.swift. Headless coverage for
// the Phase 0 streaming engine's PURE parts: asset resolution (local file →
// enclosure URL when streaming is allowed → nil otherwise) and the
// no-playable-source failure path. Live AVPlayer playback, observers, and
// end-skip are device work (tvOS Phase 3); do not try to test them here.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class StreamingPlaybackEngineTests: XCTestCase {

    private func makeEpisode() -> Episode {
        Episode(
            subscriptionID: UUID(),
            guid: "g1",
            title: "Episode",
            audioURL: URL(string: "https://e.com/a.mp3")!
        )
    }

    private func makeLocalFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-tests-\(UUID().uuidString).mp3")
        try Data([0x00]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testResolvedAssetPrefersResolverFile() throws {
        let local = try makeLocalFile()
        let url = StreamingPlaybackEngine.resolvedAssetURL(
            for: makeEpisode(),
            capabilities: .tvStreaming,
            localFileResolver: { _ in local }
        )
        XCTAssertEqual(url, local)
    }

    func testResolvedAssetUsesExistingLocalFileURLBeforeStreaming() throws {
        let local = try makeLocalFile()
        var episode = makeEpisode()
        episode.localFileURL = local

        let url = StreamingPlaybackEngine.resolvedAssetURL(for: episode, capabilities: .tvStreaming)
        XCTAssertEqual(url, local)
    }

    func testResolvedAssetFallsBackToEnclosureWhenStreamingAllowed() {
        let episode = makeEpisode()
        let url = StreamingPlaybackEngine.resolvedAssetURL(for: episode, capabilities: .tvStreaming)
        XCTAssertEqual(url, episode.audioURL)
    }

    func testResolvedAssetNilWhenNoLocalFileAndStreamingOff() {
        // iOSFull keeps streaming OFF until the Tier 1 "instant play" feature —
        // a missing local file must NOT silently start streaming on iPhone.
        let url = StreamingPlaybackEngine.resolvedAssetURL(for: makeEpisode(), capabilities: .iOSFull)
        XCTAssertNil(url)
    }

    func testStaleLocalFileURLThatNoLongerExistsFallsBackToStreaming() {
        var episode = makeEpisode()
        episode.localFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-\(UUID().uuidString).mp3")

        let url = StreamingPlaybackEngine.resolvedAssetURL(for: episode, capabilities: .tvStreaming)
        XCTAssertEqual(url, episode.audioURL)
    }

    func testPlayThrowsWhenNoPlayableSource() async {
        let engine = StreamingPlaybackEngine(capabilities: .iOSFull) // streaming off
        do {
            try await engine.play(makeEpisode(), preference: .default, filter: ChapterFilter())
            XCTFail("Expected noPlayableSource")
        } catch let error as StreamingPlaybackEngine.StreamingPlaybackError {
            XCTAssertEqual(error, .noPlayableSource)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(engine.currentEpisode)
        XCTAssertFalse(engine.isPlaying)
    }

    func testCapabilitiesPresetsMatchPlatformContract() {
        XCTAssertTrue(PlaybackCapabilities.iOSFull.trimSilence)
        XCTAssertFalse(PlaybackCapabilities.iOSFull.streaming)
        XCTAssertFalse(PlaybackCapabilities.tvStreaming.trimSilence)
        XCTAssertFalse(PlaybackCapabilities.tvStreaming.vocalBoost)
        XCTAssertTrue(PlaybackCapabilities.tvStreaming.streaming)
        XCTAssertTrue(PlaybackCapabilities.tvStreaming.video)
    }
}
