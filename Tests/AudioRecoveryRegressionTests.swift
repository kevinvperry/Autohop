// AI CONTEXT — Diagnostic repairs, 20 September 2026. Hosted simulator tests
// exercise real buffer generations, natural completion and cancellation of a
// delayed graph rebuild using disposable silent audio. These are not Bluetooth
// or physical-device latency measurements. Keep EOF rejection tests mid-file.
#if !AUTOHOP_SPM
import XCTest
import AVFoundation
@testable import Autohop

@MainActor
final class AudioRecoveryRegressionTests: XCTestCase {
    func testEOFClassificationDoesNotHideMidFileOrOtherErrors() {
        let eof = NSError(domain: NSOSStatusErrorDomain, code: -39)
        XCTAssertTrue(PlaybackEngine.isEndOfAudioFile(eof, position: 100, length: 100))
        XCTAssertFalse(PlaybackEngine.isEndOfAudioFile(eof, position: 99, length: 100))
        XCTAssertFalse(PlaybackEngine.isEndOfAudioFile(NSError(domain: NSOSStatusErrorDomain, code: -50), position: 100, length: 100))
        XCTAssertTrue(PlaybackEngine.isEndOfAudioFile(NSError(domain: "Foundation._GenericObjCError", code: 0), position: 100, length: 100))
    }

    func testResumeRetiresPausedReaderAndReportsNoSyntheticRender() async throws {
        let (engine, url) = try await playingEngine(seconds: 3)
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.pause()
        let pausedGeneration = engine._testBufferGeneration
        // Let the paused semaphore wait expire; resume must use a fresh producer.
        try await Task.sleep(for: .milliseconds(2100))
        engine.resume()
        XCTAssertGreaterThan(engine._testBufferGeneration, pausedGeneration)
        XCTAssertEqual(engine.playbackDiagnosticMetadata(reason: "test")["lastRenderedAgeMs"], "unknown")
        XCTAssertEqual(engine.playbackDiagnosticMetadata(reason: "test")["playbackLikelyProducingAudio"], "false")
        XCTAssertTrue(engine.isPlaying)
    }

    func testPauseCancelsDelayedRecovery() async throws {
        let (engine, url) = try await playingEngine(seconds: 3)
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        var resumed = false
        engine.onPlaybackResumed = { resumed = true }
        engine._testRequestFullRecovery()
        engine.pause()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(resumed)
    }

    func testNaturalEOFCompletesExactlyOnce() async throws {
        let (engine, url) = try await playingEngine(seconds: 1)
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        var completions = 0
        engine.onEpisodeFinished = { _ in completions += 1 }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(completions, 1)
    }

    private func playingEngine(seconds: Double) async throws -> (PlaybackEngine, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let count = AVAudioFrameCount(seconds * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(count)) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var episode = Episode(subscriptionID: UUID(), guid: UUID().uuidString, title: "Silent regression fixture", audioURL: url)
        episode.localFileURL = url
        let engine = PlaybackEngine(chapterService: ChapterService(), queueService: QueueService())
        try await engine.play(episode, preference: PlaybackPreference(speed: 1, startSkipSeconds: 0, endSkipSeconds: 0, audioChannelMode: .mono), filter: ChapterFilter())
        return (engine, url)
    }
}
#endif
