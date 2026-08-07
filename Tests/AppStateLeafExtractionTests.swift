// AI CONTEXT — Tests/AppStateLeafExtractionTests.swift
//
// Stage 0 characterization coverage for the physically independent Stage 2
// leaves. These tests pin the compatibility APIs and the Play Instant cue's
// binary container contract. SwiftPM intentionally excludes the iOS-only
// Playback/Downloads directories, so this file runs in the Xcode app test target.
// The shared Release Radar/history behavior remains covered by the headless
// AutohopCore suite.
import XCTest

#if !AUTOHOP_SPM
@testable import Autohop

@MainActor
final class AppStateLeafExtractionTests: XCTestCase {
    func testPlaybackClockRetainsCurrentTimeProjection() {
        let subject = PlaybackClock()

        subject.time = 123.5

        XCTAssertEqual(subject.time, 123.5)
    }

    func testDownloadProgressModelRetainsEpisodeFractionProjection() {
        let subject = DownloadProgressModel()
        let episodeID = UUID()

        subject.progress[episodeID] = 0.625

        XCTAssertEqual(subject.progress[episodeID], 0.625)
    }

    func testPlayInstantWarningCueRetainsWaveContainerContract() throws {
        let data = try XCTUnwrap(PlaybackCueService.makePlayInstantWarningWAV())

        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(from: data, offset: 24), 22_050)
        XCTAssertEqual(readUInt16(from: data, offset: 22), 1)
        XCTAssertEqual(readUInt16(from: data, offset: 34), 16)
        XCTAssertEqual(readUInt32(from: data, offset: 40), UInt32(data.count - 44))
        XCTAssertEqual(data.count, 24_298)
    }

    func testSleepFadeUsesThirtySecondSmoothMonotonicEnvelope() {
        XCTAssertEqual(SleepTimerService.gradualFadeDuration, 30)
        XCTAssertEqual(SleepTimerService.gradualFadeVolume(remaining: 30), 1)
        XCTAssertEqual(SleepTimerService.gradualFadeVolume(remaining: 15), 0.5)
        XCTAssertEqual(SleepTimerService.gradualFadeVolume(remaining: 0), 0)
        XCTAssertGreaterThan(
            SleepTimerService.gradualFadeVolume(remaining: 20),
            SleepTimerService.gradualFadeVolume(remaining: 10)
        )
    }

    private func readUInt16(from data: Data, offset: Int) -> UInt16 {
        data[offset..<(offset + 2)]
            .enumerated()
            .reduce(into: UInt16(0)) { value, pair in
                value |= UInt16(pair.element) << UInt16(pair.offset * 8)
            }
    }

    private func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)]
            .enumerated()
            .reduce(into: UInt32(0)) { value, pair in
                value |= UInt32(pair.element) << UInt32(pair.offset * 8)
            }
    }
}
#endif
