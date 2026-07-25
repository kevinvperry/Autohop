import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

// AI CONTEXT — Regression coverage for Episode Limit rotation. The policy
// retains N automatic downloads, reserves room for a newly discovered episode,
// and treats explicit downloads/queue pins as additive protected content.
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
}
