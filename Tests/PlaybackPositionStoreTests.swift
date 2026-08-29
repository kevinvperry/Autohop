// AI CONTEXT — Tests/PlaybackPositionStoreTests.swift. Headless tests for the
// playback-position store extracted from AppState (deep-scan AH-2026-06-28-02
// first carve). Pins the behavior that used to live untested inside AppState:
// subscription-scoped position keys (guid → title+date → title+URL fallbacks),
// near-end resume normalization ("finished" → restart from 0), write-through
// save/clear round trips, the two legacy on-disk decode formats, and
// most-recently-updated restore-candidate selection. If any of these change,
// resume behavior changes on-device — treat failures as real regressions, not
// test rot. This file also pins the shared episode-list time-label boundary:
// positive sub-minute values use seconds and never appear as 0m.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class PlaybackPositionStoreTests: XCTestCase {

    func testEpisodeListTimeLabelUsesSecondsThroughoutFinalMinute() {
        XCTAssertEqual(episodeListTimeLabel(0.2), "1s")
        XCTAssertEqual(episodeListTimeLabel(1), "1s")
        XCTAssertEqual(episodeListTimeLabel(42.1), "43s")
        XCTAssertEqual(episodeListTimeLabel(59.9), "59s")
    }

    func testEpisodeListTimeLabelPreservesMinuteAndHourStyle() {
        XCTAssertEqual(episodeListTimeLabel(0), "0m")
        XCTAssertEqual(episodeListTimeLabel(60), "1m")
        XCTAssertEqual(episodeListTimeLabel(3_661), "1h 1m")
        XCTAssertEqual(episodeListTimeLabel(-5), "0m")
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("position-tests-\(UUID().uuidString)")
            .appendingPathComponent("playback-position.json")
    }

    private func makeEpisode(
        subscriptionID: UUID = UUID(),
        guid: String = "g1",
        title: String = "Episode",
        duration: TimeInterval? = 1800
    ) -> Episode {
        var episode = Episode(
            subscriptionID: subscriptionID,
            guid: guid,
            title: title,
            audioURL: URL(string: "https://e.com/a.mp3")!
        )
        episode.durationSeconds = duration
        return episode
    }

    // MARK: - Keys

    func testKeyPrefersTrimmedGUID() {
        var episode = makeEpisode(guid: "  abc  ")
        episode.publishedAt = Date()
        XCTAssertEqual(
            PlaybackPositionStore.key(for: episode),
            "\(episode.subscriptionID.uuidString)|guid:abc"
        )
    }

    func testKeyFallsBackToTitleDateThenTitleURL() {
        var dated = makeEpisode(guid: "   ", title: "My Show")
        dated.publishedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            PlaybackPositionStore.key(for: dated),
            "\(dated.subscriptionID.uuidString)|title-date:my show|1000"
        )

        let undated = makeEpisode(guid: "", title: "My Show", duration: nil)
        XCTAssertEqual(
            PlaybackPositionStore.key(for: undated),
            "\(undated.subscriptionID.uuidString)|title-url:my show|https://e.com/a.mp3"
        )
    }

    // MARK: - Resume normalization

    func testNormalizedResumeTimeTreatsNearEndAsFinished() {
        XCTAssertEqual(PlaybackPositionStore.normalizedResumeTime(1799, duration: 1800), 0)
        XCTAssertEqual(PlaybackPositionStore.normalizedResumeTime(1700, duration: 1800), 1700)
        XCTAssertEqual(PlaybackPositionStore.normalizedResumeTime(-5, duration: 1800), 0)
        XCTAssertEqual(PlaybackPositionStore.normalizedResumeTime(2400, duration: 1800), 0) // clamped to end → finished
        XCTAssertEqual(PlaybackPositionStore.normalizedResumeTime(900, duration: nil), 900)
    }

    // MARK: - Save / read / clear

    func testSaveReadRoundTripAcrossReload() {
        let url = temporaryFileURL()
        let episode = makeEpisode()

        let store = PlaybackPositionStore(fileURL: url)
        store.save(episode: episode, timeSeconds: 600)
        XCTAssertEqual(store.savedTime(for: episode), 600)

        // Fresh instance = app relaunch; must decode the same position.
        XCTAssertEqual(PlaybackPositionStore(fileURL: url).savedTime(for: episode), 600)
    }

    func testSaveNearEndClearsExistingPosition() {
        let store = PlaybackPositionStore(fileURL: temporaryFileURL())
        let episode = makeEpisode()
        store.save(episode: episode, timeSeconds: 600)
        store.save(episode: episode, timeSeconds: 1799) // within 2 s of the end
        XCTAssertEqual(store.savedTime(for: episode), 0)
    }

    func testSavedTimeRequiresMatchingSubscription() {
        let store = PlaybackPositionStore(fileURL: temporaryFileURL())
        let episode = makeEpisode(guid: "shared-guid")
        store.save(episode: episode, timeSeconds: 600)

        // Same GUID under a different subscription must not inherit the position.
        let other = makeEpisode(subscriptionID: UUID(), guid: "shared-guid")
        XCTAssertEqual(store.savedTime(for: other), 0)
    }

    func testClearRemovesPositionAndEmptyStoreRemovesFile() {
        let url = temporaryFileURL()
        let store = PlaybackPositionStore(fileURL: url)
        let episode = makeEpisode()
        store.save(episode: episode, timeSeconds: 600)
        store.clear(for: episode)

        XCTAssertEqual(store.savedTime(for: episode), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Legacy on-disk formats

    func testLegacyUUIDKeyedFileDecodesAndResolvesByEpisodeID() throws {
        let url = temporaryFileURL()
        let episode = makeEpisode()
        let legacy = [episode.id: SavedPlaybackPosition(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            episodeKey: nil,
            timeSeconds: 480,
            updatedAt: nil
        )]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: url)

        XCTAssertEqual(PlaybackPositionStore(fileURL: url).savedTime(for: episode), 480)
    }

    func testLegacySingleBarePositionFileDecodes() throws {
        let url = temporaryFileURL()
        let episode = makeEpisode()
        let legacy = SavedPlaybackPosition(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            episodeKey: nil,
            timeSeconds: 300,
            updatedAt: nil
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: url)

        XCTAssertEqual(PlaybackPositionStore(fileURL: url).savedTime(for: episode), 300)
    }

    // MARK: - Restore candidate

    func testBestRestoreCandidatePicksMostRecentlyUpdated() {
        let store = PlaybackPositionStore(fileURL: temporaryFileURL())
        let older = makeEpisode(guid: "older")
        let newer = makeEpisode(guid: "newer")
        store.save(episode: older, timeSeconds: 100, updatedAt: Date(timeIntervalSince1970: 1_000))
        store.save(episode: newer, timeSeconds: 200, updatedAt: Date(timeIntervalSince1970: 2_000))

        let candidate = store.bestRestoreCandidate(in: [older, newer])
        XCTAssertEqual(candidate?.episode.guid, "newer")
        XCTAssertEqual(candidate?.position.timeSeconds, 200)
    }

    func testBestRestoreCandidateStampedBeatsUnstamped() throws {
        let url = temporaryFileURL()
        let stamped = makeEpisode(guid: "stamped")
        let unstamped = makeEpisode(guid: "unstamped")
        // Write directly so one entry genuinely has no updatedAt (legacy data).
        let positions: [String: SavedPlaybackPosition] = [
            PlaybackPositionStore.key(for: stamped): SavedPlaybackPosition(
                episodeID: stamped.id, subscriptionID: stamped.subscriptionID,
                episodeKey: nil, timeSeconds: 50, updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            PlaybackPositionStore.key(for: unstamped): SavedPlaybackPosition(
                episodeID: unstamped.id, subscriptionID: unstamped.subscriptionID,
                episodeKey: nil, timeSeconds: 900, updatedAt: nil
            )
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(positions).write(to: url)

        let candidate = PlaybackPositionStore(fileURL: url).bestRestoreCandidate(in: [stamped, unstamped])
        XCTAssertEqual(candidate?.episode.guid, "stamped")
    }
}
