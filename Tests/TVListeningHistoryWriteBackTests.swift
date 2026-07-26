// AI CONTEXT — Tests/TVListeningHistoryWriteBackTests.swift. Tests
// SubscriptionStore.recordListeningProgress / markListeningHistoryFinished —
// the tvOS Phase 3 write path that lets a streaming platform participate in
// phone⇄device resume round-trips (position roams via ListeningHistoryEntry,
// SYNC_DESIGN.md, not EpisodeSyncState). Covers: the entry id matches
// PlaybackPositionStore.key(for:) exactly (the whole cross-device merge
// depends on this — a mismatched key would silently duplicate rather than
// resume), listenedSeconds ACCUMULATES onto an existing entry rather than
// overwriting it, and natural-finish sets status/completionKind correctly.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class TVListeningHistoryWriteBackTests: XCTestCase {

    private func makeEpisode(subscriptionID: UUID, guid: String = "g1", duration: TimeInterval? = 1800) -> Episode {
        var episode = Episode(
            subscriptionID: subscriptionID, guid: guid, title: "Episode",
            audioURL: URL(string: "https://e.com/a.mp3")!
        )
        episode.durationSeconds = duration
        return episode
    }

    func testRecordListeningProgressUsesThePlaybackPositionStoreKey() throws {
        let store = SubscriptionStore.inMemory()
        let subID = UUID()
        _ = try store.addSubscription(
            id: subID, feedURL: URL(string: "https://f.com/feed")!, title: "Show",
            author: nil, artworkURL: nil, latestEpisode: makeEpisode(subscriptionID: subID)
        )
        let episode = makeEpisode(subscriptionID: subID)

        store.recordListeningProgress(
            episode: episode, podcastTitle: "Show", artworkURL: nil,
            listenedSecondsDelta: 120, positionSeconds: 120, durationSeconds: 1800
        )

        let db = try XCTUnwrap(store.database)
        let expectedKey = PlaybackPositionStore.key(for: episode)
        let stored = try XCTUnwrap(db.historyEntry(id: expectedKey))
        XCTAssertEqual(stored.lastPositionSeconds, 120)
        XCTAssertEqual(stored.listenedSeconds, 120)
        XCTAssertEqual(stored.streamURL, episode.audioURL)
        XCTAssertEqual(stored.mediaKind, episode.mediaKind)
    }

    func testRecordListeningProgressAccumulatesOntoExistingEntry() throws {
        let store = SubscriptionStore.inMemory()
        let subID = UUID()
        let episode = makeEpisode(subscriptionID: subID)

        // Simulate a prior session (e.g. recorded on the phone) already at 300s.
        store.recordListeningProgress(
            episode: episode, podcastTitle: "Show", artworkURL: nil,
            listenedSecondsDelta: 300, positionSeconds: 300, durationSeconds: 1800
        )
        // A second (TV) session adds another 60s of listening.
        store.recordListeningProgress(
            episode: episode, podcastTitle: "Show", artworkURL: nil,
            listenedSecondsDelta: 60, positionSeconds: 360, durationSeconds: 1800
        )

        let db = try XCTUnwrap(store.database)
        let stored = try XCTUnwrap(db.historyEntry(id: PlaybackPositionStore.key(for: episode)))
        XCTAssertEqual(stored.listenedSeconds, 360, "Sessions accumulate rather than overwrite")
        XCTAssertEqual(stored.lastPositionSeconds, 360, "Position reflects the latest write")
    }

    func testRecoveredEpisodeCanWriteBackToAuthoritativeHistoryIdentity() throws {
        let store = SubscriptionStore.inMemory()
        let episode = makeEpisode(subscriptionID: UUID(), guid: "public-video-guid")
        let phoneHistoryID = "orphan-phone-sub|guid:private-feed-guid"

        store.recordListeningProgress(
            episode: episode,
            podcastTitle: "Windows Weekly",
            artworkURL: nil,
            listenedSecondsDelta: 20,
            positionSeconds: 420,
            durationSeconds: 1800,
            historyEntryID: phoneHistoryID
        )

        let db = try XCTUnwrap(store.database)
        let stored = try XCTUnwrap(db.historyEntry(id: phoneHistoryID))
        XCTAssertEqual(stored.lastPositionSeconds, 420)
        XCTAssertNil(try db.historyEntry(id: PlaybackPositionStore.key(for: episode)))
    }

    func testMarkListeningHistoryFinishedSetsPlayedStatusAndCompletionKind() throws {
        let store = SubscriptionStore.inMemory()
        let subID = UUID()
        let episode = makeEpisode(subscriptionID: subID, duration: 1800)

        store.recordListeningProgress(
            episode: episode, podcastTitle: "Show", artworkURL: nil,
            listenedSecondsDelta: 1750, positionSeconds: 1750, durationSeconds: 1800
        )
        store.markListeningHistoryFinished(
            episode: episode, podcastTitle: "Show", artworkURL: nil, finishedPositionSeconds: 1800
        )

        let db = try XCTUnwrap(store.database)
        let stored = try XCTUnwrap(db.historyEntry(id: PlaybackPositionStore.key(for: episode)))
        XCTAssertEqual(stored.status, .played)
        XCTAssertEqual(stored.completionKind, .finishedNaturally)
        XCTAssertEqual(stored.lastPositionSeconds, 1800)
        // Listening time accumulated before the finish call is preserved, not reset.
        XCTAssertEqual(stored.listenedSeconds, 1750)
    }

    func testDifferentEpisodesProduceDifferentEntries() throws {
        let store = SubscriptionStore.inMemory()
        let subID = UUID()
        let first = makeEpisode(subscriptionID: subID, guid: "g1")
        let second = makeEpisode(subscriptionID: subID, guid: "g2")

        store.recordListeningProgress(episode: first, podcastTitle: "Show", artworkURL: nil, listenedSecondsDelta: 10, positionSeconds: 10, durationSeconds: 1800)
        store.recordListeningProgress(episode: second, podcastTitle: "Show", artworkURL: nil, listenedSecondsDelta: 20, positionSeconds: 20, durationSeconds: 1800)

        let db = try XCTUnwrap(store.database)
        XCTAssertNotEqual(PlaybackPositionStore.key(for: first), PlaybackPositionStore.key(for: second))
        XCTAssertEqual(try db.historyEntry(id: PlaybackPositionStore.key(for: first))?.lastPositionSeconds, 10)
        XCTAssertEqual(try db.historyEntry(id: PlaybackPositionStore.key(for: second))?.lastPositionSeconds, 20)
    }

    // MARK: - Read side (cross-device resume + Continue Listening, 2026-07-04)

    func testSavedListeningPositionRoundTripsFromRecordedProgress() {
        let store = SubscriptionStore.inMemory()
        let episode = makeEpisode(subscriptionID: UUID())

        XCTAssertNil(store.savedListeningPosition(for: episode), "No history yet → start from the beginning")

        store.recordListeningProgress(
            episode: episode, podcastTitle: "Show", artworkURL: nil,
            listenedSecondsDelta: 600, positionSeconds: 600, durationSeconds: 1800
        )
        XCTAssertEqual(store.savedListeningPosition(for: episode), 600)
    }

    func testSavedListeningPositionIsNilForFinishedOrNearEndEntries() {
        let store = SubscriptionStore.inMemory()
        let subID = UUID()

        // Finished entry (.played) must not resume into the outro.
        let finished = makeEpisode(subscriptionID: subID, guid: "finished")
        store.recordListeningProgress(episode: finished, podcastTitle: "Show", artworkURL: nil, listenedSecondsDelta: 1750, positionSeconds: 1750, durationSeconds: 1800)
        store.markListeningHistoryFinished(episode: finished, podcastTitle: "Show", artworkURL: nil, finishedPositionSeconds: 1800)
        XCTAssertNil(store.savedListeningPosition(for: finished))

        // Near-end (.listened, within 2 s of the end) normalizes to restart.
        let nearEnd = makeEpisode(subscriptionID: subID, guid: "near-end")
        store.recordListeningProgress(episode: nearEnd, podcastTitle: "Show", artworkURL: nil, listenedSecondsDelta: 1799, positionSeconds: 1799, durationSeconds: 1800)
        XCTAssertNil(store.savedListeningPosition(for: nearEnd))
    }

    func testMostRecentInProgressEntryPicksLatestListenedAcrossShows() throws {
        let store = SubscriptionStore.inMemory()
        let db = try XCTUnwrap(store.database)

        func entry(guid: String, listenedAt: Date, position: TimeInterval, status: ListeningHistoryStatus = .listened) -> ListeningHistoryEntry {
            ListeningHistoryEntry(
                id: "sub|guid:\(guid)", subscriptionID: UUID(), episodeID: UUID(),
                episodeTitle: guid, podcastTitle: "Show", artworkURL: nil,
                publishedAt: nil, durationSeconds: 1800, listenedSeconds: position,
                lastPositionSeconds: position, lastListenedAt: listenedAt, status: status
            )
        }

        // Simulates entries arriving via sync (the engine's no-callback
        // fallback persists them as clean synced rows).
        try db.saveSyncedHistoryEntry(entry(guid: "older-audio", listenedAt: Date(timeIntervalSince1970: 1_000), position: 900))
        try db.saveSyncedHistoryEntry(entry(guid: "current-video", listenedAt: Date(timeIntervalSince1970: 2_000), position: 300))
        try db.saveSyncedHistoryEntry(entry(guid: "finished", listenedAt: Date(timeIntervalSince1970: 3_000), position: 1800, status: .played))
        try db.saveSyncedHistoryEntry(entry(guid: "barely-touched", listenedAt: Date(timeIntervalSince1970: 4_000), position: 0))

        let picked = try XCTUnwrap(store.mostRecentInProgressListeningEntry())
        // "finished" is newer but .played; "barely-touched" is newest but has
        // no usable position — the CURRENTLY-WATCHED item wins, which is
        // exactly the real-device bug this fixes (Continue Listening showed
        // an older audio show instead of the video being watched right now).
        XCTAssertEqual(picked.episodeTitle, "current-video")
    }

    func testMarkEpisodePlayingStampsLastPlayedAt() throws {
        let store = SubscriptionStore.inMemory()
        let subID = UUID()
        let episode = makeEpisode(subscriptionID: subID)
        _ = try store.addSubscription(
            id: subID, feedURL: URL(string: "https://f.com/feed")!, title: "Show",
            author: nil, artworkURL: nil, latestEpisode: episode
        )

        store.markEpisodePlaying(subscriptionID: subID, episodeID: episode.id)

        let updated = try XCTUnwrap(store.episode(subscriptionID: subID, episodeID: episode.id))
        XCTAssertEqual(updated.playedState, .playing)
        XCTAssertNotNil(updated.lastPlayedAt, "Play start must stamp recency — cross-device Continue Listening ordering depends on it")
    }
}
