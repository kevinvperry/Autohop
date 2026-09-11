import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

// AI CONTEXT — Regression coverage for Episode Limit rotation and multi-release
// feed scans. Rotation retains N automatic downloads and treats explicit
// downloads/queue pins as additive protected content. Batch selection must keep
// every newly discovered eligible episode up to the limit, newest first.
final class EpisodeLimitRetentionPolicyTests: XCTestCase {
    func testOnlyOneItemRollingFeedDiscardsPreviousLatest() {
        XCTAssertTrue(
            FeedReplacementPolicy.shouldDiscardPreviousLatest(
                parsedEpisodeCount: 1
            )
        )
        XCTAssertFalse(
            FeedReplacementPolicy.shouldDiscardPreviousLatest(
                parsedEpisodeCount: 10
            )
        )
    }

    func testLimitTenDoesNotCollapseOrdinaryFeedToNewestEpisode() {
        let episodes = (0..<10).map {
            makeStoredEpisode(index: $0)
        }

        XCTAssertTrue(
            EpisodeLimitRetentionPolicy.excessEpisodes(
                from: episodes,
                limit: 10
            ).isEmpty
        )
    }

    func testFeedScanSelectsAllNewEpisodesWhenLimitAllowsThem() {
        let older = makeUnstoredEpisode(index: 1)
        let newer = makeUnstoredEpisode(index: 2)

        let candidates = AutomaticDownloadBatchPolicy.candidates(
            from: [older, newer],
            episodeLimit: 10
        )

        XCTAssertEqual(candidates.map(\.guid), ["episode-2", "episode-1"])
    }

    func testFeedScanBoundsNewEpisodeBatchToEpisodeLimit() {
        let episodes = (0..<3).map { makeUnstoredEpisode(index: $0) }

        let candidates = AutomaticDownloadBatchPolicy.candidates(
            from: episodes,
            episodeLimit: 2
        )

        XCTAssertEqual(candidates.map(\.guid), ["episode-2", "episode-1"])
    }

    func testNoLimitSelectsEveryNewEligibleEpisode() {
        let episodes = (0..<12).map { makeUnstoredEpisode(index: $0) }

        XCTAssertEqual(
            AutomaticDownloadBatchPolicy.candidates(
                from: episodes,
                episodeLimit: 0
            ).count,
            12
        )
    }

    func testBatchExcludesAlreadyStoredOrCompletedEpisodes() {
        var downloaded = makeUnstoredEpisode(index: 1)
        downloaded.downloadState = .downloaded
        var played = makeUnstoredEpisode(index: 2)
        played.playedState = .played
        let eligible = makeUnstoredEpisode(index: 3)

        let candidates = AutomaticDownloadBatchPolicy.candidates(
            from: [downloaded, played, eligible],
            episodeLimit: 10
        )

        XCTAssertEqual(candidates.map(\.guid), ["episode-3"])
    }

    func testIncomingAutomaticDownloadReplacesOldestManagedEpisode() {
        let episodes = (0..<10).map {
            makeStoredEpisode(index: $0)
        }

        let excess = EpisodeLimitRetentionPolicy.excessEpisodes(
            from: episodes,
            limit: 10,
            reservedAutomaticSlots: 1
        )

        XCTAssertEqual(excess.map(\.guid), ["episode-0"])
    }

    func testManualDownloadAndQueuePinAreProtectedAndDoNotConsumeLimit() {
        var manual = makeStoredEpisode(index: 0)
        manual.isManualDownloadProtected = true
        let pinned = makeStoredEpisode(index: 1)
        let automatic = (2..<13).map {
            makeStoredEpisode(index: $0)
        }

        let excess = EpisodeLimitRetentionPolicy.excessEpisodes(
            from: [manual, pinned] + automatic,
            limit: 10,
            externallyProtectedIDs: [pinned.id]
        )

        XCTAssertEqual(excess.map(\.guid), ["episode-2"])
        XCTAssertFalse(excess.contains { $0.id == manual.id })
        XCTAssertFalse(excess.contains { $0.id == pinned.id })
    }

    func testLegacyEpisodeDecodesWithoutManualProtection() throws {
        let episode = makeStoredEpisode(index: 1)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(episode)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "isManualDownloadProtected")

        let decoded = try JSONDecoder().decode(
            Episode.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.isManualDownloadProtected)
    }

    func testManualProtectionRoundTrips() throws {
        var episode = makeStoredEpisode(index: 1)
        episode.isManualDownloadProtected = true

        let decoded = try JSONDecoder().decode(
            Episode.self,
            from: JSONEncoder().encode(episode)
        )

        XCTAssertTrue(decoded.isManualDownloadProtected)
    }

    private func makeStoredEpisode(index: Int) -> Episode {
        var episode = Episode(
            subscriptionID: UUID(),
            guid: "episode-\(index)",
            title: "Episode \(index)",
            audioURL: URL(string: "https://example.com/\(index).mp3")!,
            downloadState: .downloaded
        )
        episode.publishedAt = Date(timeIntervalSince1970: TimeInterval(index))
        episode.localFileName = "\(index).mp3"
        return episode
    }

    private func makeUnstoredEpisode(index: Int) -> Episode {
        var episode = Episode(
            subscriptionID: UUID(),
            guid: "episode-\(index)",
            title: "Episode \(index)",
            audioURL: URL(string: "https://example.com/\(index).mp3")!
        )
        episode.publishedAt = Date(timeIntervalSince1970: TimeInterval(index))
        return episode
    }
}
