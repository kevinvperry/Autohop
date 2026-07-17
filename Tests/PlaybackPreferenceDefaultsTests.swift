// AI CONTEXT — Tests/PlaybackPreferenceDefaultsTests.swift. Regression test for
// B3 (ASSESSMENT.md): `PlaybackPreference.default`, the member-wise init's
// vocalBoostLevel default, and `init(from:)`'s missing-key fallback must all
// agree on `.off` — previously the init and decoder silently fell back to
// `.strong`. The legacy `vocalBoostEnabled` boolean key must still map
// true→.strong / false→.off. Also protects the shared episode-trim display
// wording used by both settings pages (including singular/plural boundaries).
// Mono Audio is also protected as an opt-in preference: legacy payloads and
// factory defaults are Stereo, while an explicit Mono choice round-trips. Volume
// Adjustment likewise defaults legacy/new data to 0 and clamps to -3...+3.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class PlaybackPreferenceDefaultsTests: XCTestCase {

    func testMemberwiseInitDefaultsVocalBoostToOff() {
        let pref = PlaybackPreference(speed: 1.5, startSkipSeconds: 0, endSkipSeconds: 0)
        XCTAssertEqual(pref.vocalBoostLevel, .off)
        XCTAssertEqual(pref.vocalBoostLevel, PlaybackPreference.default.vocalBoostLevel)
    }

    func testDecodeWithNoVocalBoostKeysFallsBackToOff() throws {
        // A payload that predates both the level and the legacy boolean key.
        let json = #"{"speed":1.2,"startSkipSeconds":0,"endSkipSeconds":0,"trimSilence":"off"}"#
        let pref = try JSONDecoder().decode(PlaybackPreference.self, from: Data(json.utf8))
        XCTAssertEqual(pref.vocalBoostLevel, .off)
    }

    func testDecodeLegacyBooleanKeyStillMaps() throws {
        let enabled = #"{"speed":1.0,"startSkipSeconds":0,"endSkipSeconds":0,"vocalBoostEnabled":true}"#
        let disabled = #"{"speed":1.0,"startSkipSeconds":0,"endSkipSeconds":0,"vocalBoostEnabled":false}"#
        XCTAssertEqual(try JSONDecoder().decode(PlaybackPreference.self, from: Data(enabled.utf8)).vocalBoostLevel, .strong)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackPreference.self, from: Data(disabled.utf8)).vocalBoostLevel, .off)
    }

    func testExplicitLevelIsPreservedRoundTrip() throws {
        let pref = PlaybackPreference(speed: 1.0, startSkipSeconds: 0, endSkipSeconds: 0, vocalBoostLevel: .standard)
        let data = try JSONEncoder().encode(pref)
        let decoded = try JSONDecoder().decode(PlaybackPreference.self, from: data)
        XCTAssertEqual(decoded.vocalBoostLevel, .standard)
    }

    func testAudioChannelModeDefaultsStereoForNewAndLegacyPreferences() throws {
        XCTAssertEqual(PlaybackPreference.default.audioChannelMode, .stereo)
        let legacy = #"{"speed":1.2,"startSkipSeconds":0,"endSkipSeconds":0,"trimSilence":"off"}"#
        let decoded = try JSONDecoder().decode(PlaybackPreference.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.audioChannelMode, .stereo)
    }

    func testMonoAudioPreferenceRoundTrips() throws {
        let preference = PlaybackPreference(
            speed: 1.0,
            startSkipSeconds: 0,
            endSkipSeconds: 0,
            audioChannelMode: .mono
        )
        let decoded = try JSONDecoder().decode(
            PlaybackPreference.self,
            from: JSONEncoder().encode(preference)
        )
        XCTAssertEqual(decoded.audioChannelMode, .mono)
    }

    func testVolumeAdjustmentDefaultsToZeroAndRoundTrips() throws {
        XCTAssertEqual(PlaybackPreference.default.volumeAdjustment, 0)
        let legacy = #"{"speed":1.2,"startSkipSeconds":0,"endSkipSeconds":0}"#
        XCTAssertEqual(
            try JSONDecoder().decode(PlaybackPreference.self, from: Data(legacy.utf8)).volumeAdjustment,
            0
        )
        let preference = PlaybackPreference(
            speed: 1,
            startSkipSeconds: 0,
            endSkipSeconds: 0,
            volumeAdjustment: 3
        )
        XCTAssertEqual(
            try JSONDecoder().decode(PlaybackPreference.self, from: JSONEncoder().encode(preference)).volumeAdjustment,
            3
        )
    }

    func testVolumeAdjustmentClampsAndFormats() {
        XCTAssertEqual(PlaybackPreference.clampedVolumeAdjustment(-9), -3)
        XCTAssertEqual(PlaybackPreference.clampedVolumeAdjustment(9), 3)
        XCTAssertEqual(PlaybackPreference.volumeAdjustmentLabel(-2), "-2 dB")
        XCTAssertEqual(PlaybackPreference.volumeAdjustmentLabel(0), "0 dB")
        XCTAssertEqual(PlaybackPreference.volumeAdjustmentLabel(2), "+2 dB")
    }

    func testEpisodeTrimDurationTextUsesMinutesAndSeconds() {
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 0), "Off")
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 5), "5 secs")
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 60), "1 min")
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 61), "1 min 1 sec")
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 90), "1 min 30 secs")
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 120), "2 mins")
        XCTAssertEqual(EpisodeTrimDurationText.string(for: 300), "5 mins")
    }
}
