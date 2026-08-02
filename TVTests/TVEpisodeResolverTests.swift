import XCTest
@testable import AutohopTV
import AutohopCore

// AI CONTEXT — Regression coverage for the tvOS-only compatibility boundary.
// These scenarios reproduce the Windows Weekly failures reported on physical
// Apple TV: legacy history without mediaKind, a reinstalled subscription UUID,
// distinct audio/video show titles, and resume identity crossing projections.
@MainActor
final class TVEpisodeResolverTests: XCTestCase {
    private func context(
        subscriptions: [Subscription] = [],
        queueItems: [QueueModel.ResolvedQueueItem] = []
    ) -> TVEpisodeResolver.Context {
        .init(
            subscriptions: subscriptions,
            subscriptionsByID: Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) }),
            queueItems: queueItems,
            legacyQueueEpisodes: [:],
            uniqueEpisodesByGUID: [:],
            uniqueEpisodesByNormalizedTitle: [:]
        )
    }

    private func history(
        subscriptionID: UUID,
        streamURL: URL,
        mediaKind: EpisodeMediaKind? = nil,
        podcastTitle: String = "Windows Weekly (Video)",
        playbackSpeed: Double? = nil
    ) -> ListeningHistoryEntry {
        ListeningHistoryEntry(
            id: "\(subscriptionID)|guid:\(streamURL.absoluteString)",
            subscriptionID: subscriptionID,
            episodeID: UUID(),
            episodeTitle: "WW 993",
            podcastTitle: podcastTitle,
            artworkURL: nil,
            streamURL: streamURL,
            mediaKind: mediaKind,
            publishedAt: nil,
            durationSeconds: 7_200,
            listenedSeconds: 900,
            lastPositionSeconds: 900,
            lastListenedAt: Date(),
            status: .listened,
            playbackSpeed: playbackSpeed
        )
    }

    func testLegacyHistoryInfersVideoFromEnclosureExtension() throws {
        let entry = history(
            subscriptionID: UUID(),
            streamURL: URL(string: "https://cdn.example.com/windows-weekly.mp4")!
        )

        let episode = try XCTUnwrap(
            TVEpisodeResolver(context: context()).resolveEpisode(from: entry)
        )

        XCTAssertEqual(episode.mediaKind, .video)
        XCTAssertEqual(episode.audioURL, entry.streamURL)
    }

    func testStaleUUIDStillInheritsExactVideoSubscriptionSettings() throws {
        let currentID = UUID()
        let staleID = UUID()
        let videoPreference = PlaybackPreference(
            speed: 1.5,
            startSkipSeconds: 0,
            endSkipSeconds: 0
        )
        let videoSubscription = Subscription(
            id: currentID,
            feedURL: URL(string: "https://example.com/video.xml")!,
            title: "Windows Weekly (Video)",
            priorityRank: 1,
            playbackPreference: videoPreference
        )
        let audioSubscription = Subscription(
            feedURL: URL(string: "https://example.com/audio.xml")!,
            title: "Windows Weekly",
            priorityRank: 2
        )
        let entry = history(
            subscriptionID: staleID,
            streamURL: URL(string: "https://cdn.example.com/ww.mp4")!
        )
        let resolver = TVEpisodeResolver(context: context(
            subscriptions: [audioSubscription, videoSubscription]
        ))
        let episode = try XCTUnwrap(resolver.resolveEpisode(from: entry))

        let resolution = resolver.playbackResolution(for: episode, candidateHistory: entry)

        XCTAssertEqual(resolution.subscription.id, currentID)
        XCTAssertEqual(resolution.subscription.playbackPreference.speed, 1.5)
        XCTAssertEqual(resolution.historyEntry?.lastPositionSeconds, 900)
        XCTAssertEqual(resolution.episode.mediaKind, .video)
    }

    func testAudioAndVideoSubscriptionsRemainDistinct() throws {
        let audio = Subscription(
            feedURL: URL(string: "https://example.com/audio.xml")!,
            title: "Windows Weekly",
            priorityRank: 1
        )
        let video = Subscription(
            feedURL: URL(string: "https://example.com/video.xml")!,
            title: "Windows Weekly (Video)",
            priorityRank: 2,
            playbackPreference: PlaybackPreference(
                speed: 1.5,
                startSkipSeconds: 0,
                endSkipSeconds: 0
            )
        )
        let entry = history(
            subscriptionID: UUID(),
            streamURL: URL(string: "https://cdn.example.com/ww.mp4")!
        )
        let resolver = TVEpisodeResolver(context: context(subscriptions: [audio, video]))
        let episode = try XCTUnwrap(resolver.resolveEpisode(from: entry))

        XCTAssertEqual(resolver.resolveSubscription(for: episode, history: entry).id, video.id)
    }

    func testTitleAloneCannotAttachHistoryFromAnotherSubscription() {
        let firstID = UUID()
        let secondID = UUID()
        let episode = Episode(
            subscriptionID: firstID,
            guid: "episode-a",
            title: "Daily Update",
            audioURL: URL(string: "https://one.example.com/a.mp3")!
        )
        let entry = ListeningHistoryEntry(
            id: "\(secondID)|guid:episode-b",
            subscriptionID: secondID,
            episodeID: UUID(),
            episodeTitle: "Daily Update",
            podcastTitle: "Different Show",
            artworkURL: nil,
            publishedAt: nil,
            durationSeconds: 600,
            listenedSeconds: 100,
            lastPositionSeconds: 100,
            lastListenedAt: Date(),
            status: .listened
        )

        XCTAssertFalse(
            TVEpisodeResolver(context: context()).historyEntry(entry, belongsTo: episode)
        )
    }

    func testProjectionHistoryRestoresExplicitPlaybackSpeed() throws {
        let entry = history(
            subscriptionID: UUID(),
            streamURL: URL(string: "https://cdn.example.com/intelligent-machines.mp4")!,
            playbackSpeed: 1.4
        )
        let resolver = TVEpisodeResolver(context: context())
        let episode = try XCTUnwrap(resolver.resolveEpisode(from: entry))

        let resolution = resolver.playbackResolution(for: episode, candidateHistory: entry)

        XCTAssertEqual(resolution.subscription.playbackPreference.speed, 1.4)
    }

    func testNestedLegacyGUIDIsCanonicalizedBeforeCompanionStateAuthorship() {
        let subscriptionID = UUID()
        let nested = "\(subscriptionID)|guid:\(subscriptionID)|guid:urn:bbc:podcast:episode-1"
        var episode = Episode(
            subscriptionID: subscriptionID,
            guid: nested,
            title: "Bulletin",
            audioURL: URL(string: "https://example.com/bulletin.mp3")!
        )
        episode = TVEpisodeResolver.canonicalized(episode)

        XCTAssertEqual(episode.guid, "urn:bbc:podcast:episode-1")
    }
}
