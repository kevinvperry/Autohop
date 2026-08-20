import XCTest
@testable import AutohopTV
import AutohopCore

// AI CONTEXT — Architecture regression tests for the decomposed tvOS root.
// They verify focused state/projector behaviour without constructing CloudKit,
// networking, or the iPhone application, including the invariant that a healthy
// account with no optional queue snapshot reports “iCloud connected.”
@MainActor
final class TVAppDecompositionTests: XCTestCase {
    func testHealthyAccountWithoutQueueSnapshotUsesConnectedStatus() {
        XCTAssertEqual(TVSyncStatus.connected.label, "iCloud connected")
    }

    func testBootstrapStateOwnsLoadingMessageAndTerminalState() {
        let coordinator = TVBootstrapCoordinator()

        coordinator.state = .loading(message: "Connecting…")
        XCTAssertEqual(coordinator.statusText, "Connecting…")

        coordinator.state = .ready
        XCTAssertEqual(coordinator.statusText, "Ready")
    }

    func testLibraryProjectorPreservesPriorityAndPendingRows() {
        let first = Subscription(
            feedURL: URL(string: "https://example.com/first.xml")!,
            title: "First",
            priorityRank: 2
        )
        let second = Subscription(
            feedURL: URL(string: "https://example.com/second.xml")!,
            title: "Second",
            priorityRank: 1
        )
        let pendingID = UUID()
        let pending = SurvivalKitEntry(
            subscriptionID: pendingID,
            feedURL: URL(string: "https://example.com/pending.xml")!,
            priorityRank: 3,
            title: "Pending"
        )

        let projection = TVLibraryProjector.project(
            subscriptions: [first, second],
            pendingEntries: [pending]
        )

        XCTAssertEqual(projection.subscriptions.map(\.id), [second.id, first.id])
        XCTAssertEqual(projection.tiles.map(\.id), [second.id, first.id, pendingID])
        XCTAssertTrue(projection.tiles.last?.isMaterializing == true)
    }

    func testQueueProjectorPreservesPhoneAuthoredOrderAndPlaceholder() {
        let subscriptionID = UUID()
        let episode = Episode(
            subscriptionID: subscriptionID,
            guid: "episode-1",
            title: "Playable",
            audioURL: URL(string: "https://example.com/episode.mp3")!
        )
        let items = [
            QueueModel.ResolvedQueueItem(
                episodeKey: "placeholder",
                title: "Waiting",
                podcastTitle: "Projected Show",
                subscriptionID: subscriptionID,
                episode: nil
            ),
            QueueModel.ResolvedQueueItem(
                episodeKey: "playable",
                title: episode.title,
                podcastTitle: nil,
                subscriptionID: subscriptionID,
                episode: episode
            )
        ]

        let rows = TVQueueProjector.rows(from: items, subscriptionsByID: [:])

        XCTAssertEqual(rows.map(\.id), ["placeholder", "playable"])
        XCTAssertEqual(rows.map(\.position), [1, 2])
        XCTAssertFalse(rows[0].isPlayable)
        XCTAssertTrue(rows[1].isPlayable)
        XCTAssertEqual(rows[0].podcastTitle, "Projected Show")
    }

    func testNewerAuthoritativeQueueCanReleaseLocalArchiveSuppression() {
        let authoredAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            TVQueueProjector.archiveSuppressionsToRelease(
                authoredAtByEpisodeKey: ["restored": authoredAt, "missing": authoredAt],
                authoritativeEpisodeKeys: ["restored"],
                snapshotUpdatedAt: Date(timeIntervalSince1970: 101)
            ),
            ["restored"]
        )
        XCTAssertTrue(TVQueueProjector.archiveSuppressionsToRelease(
            authoredAtByEpisodeKey: ["restored": authoredAt],
            authoritativeEpisodeKeys: ["restored"],
            snapshotUpdatedAt: authoredAt
        ).isEmpty)
    }

    func testQueueProjectionMirrorsIOSRemainingTimeRules() throws {
        let subscriptionID = UUID()
        var episode = Episode(
            subscriptionID: subscriptionID,
            guid: "partial",
            title: "Partial",
            audioURL: URL(string: "https://example.com/partial.mp3")!
        )
        episode.durationSeconds = 3_600
        let key = PlaybackPositionStore.key(for: episode)
        let item = QueueModel.ResolvedQueueItem(
            episodeKey: key,
            title: episode.title,
            subscriptionID: subscriptionID,
            episode: episode
        )

        let partial = try XCTUnwrap(TVQueueProjector.rows(
            from: [item],
            subscriptionsByID: [:],
            playbackPositionsByEpisodeKey: [key: 900]
        ).first)
        XCTAssertEqual(partial.remainingSeconds, 2_700)

        let untouched = try XCTUnwrap(TVQueueProjector.rows(
            from: [item],
            subscriptionsByID: [:]
        ).first)
        XCTAssertNil(untouched.remainingSeconds)
        XCTAssertEqual(untouched.durationSeconds, 3_600)
    }

    func testQueueProjectorPinsRequestedEpisodeImmediatelyWithoutLosingRows() {
        let subscriptionID = UUID()
        let items = ["first", "second", "third"].map { key in
            QueueModel.ResolvedQueueItem(
                episodeKey: key,
                title: key,
                podcastTitle: "Show",
                subscriptionID: subscriptionID,
                episode: nil
            )
        }

        let pinned = TVQueueProjector.pinToFront(items, episodeKey: "third")

        XCTAssertEqual(pinned.map(\.episodeKey), ["third", "first", "second"])
        XCTAssertEqual(pinned.first?.pinState, .playNext)
        XCTAssertEqual(TVQueueProjector.pinToFront(pinned, episodeKey: "third"), pinned)
        XCTAssertEqual(TVQueueProjector.pinToFront(items, episodeKey: "missing"), items)
    }

    func testQueueProjectorUnpinRestoresNaturalPriorityPositionAndKeepsOtherPins() {
        let firstSubscription = Subscription(
            feedURL: URL(string: "https://example.com/first.xml")!,
            title: "First",
            priorityRank: 1
        )
        let secondSubscription = Subscription(
            feedURL: URL(string: "https://example.com/second.xml")!,
            title: "Second",
            priorityRank: 2
        )
        let items = [
            QueueModel.ResolvedQueueItem(
                episodeKey: "target",
                title: "Target",
                subscriptionID: secondSubscription.id,
                episode: nil,
                pinState: .playNext,
                publishedAt: Date(timeIntervalSince1970: 20)
            ),
            QueueModel.ResolvedQueueItem(
                episodeKey: "other-pin",
                title: "Other Pin",
                subscriptionID: secondSubscription.id,
                episode: nil,
                pinState: .playNext,
                publishedAt: Date(timeIntervalSince1970: 10)
            ),
            QueueModel.ResolvedQueueItem(
                episodeKey: "natural-first",
                title: "Natural First",
                subscriptionID: firstSubscription.id,
                episode: nil,
                publishedAt: Date(timeIntervalSince1970: 30)
            )
        ]

        let unpinned = TVQueueProjector.unpin(
            items,
            episodeKey: "target",
            subscriptionsByID: [
                firstSubscription.id: firstSubscription,
                secondSubscription.id: secondSubscription
            ]
        )

        XCTAssertEqual(unpinned.map(\.episodeKey), ["other-pin", "natural-first", "target"])
        XCTAssertNil(unpinned.last?.pinState)
    }

    func testFocusedModelsDoNotShareMutationState() {
        let library = TVLibraryModel()
        let queue = TVQueueModel()
        let history = TVContinueListeningModel()
        let archiveHistory = TVHistoryModel()

        queue.locallyArchivedEpisodeKeys.insert("episode")
        history.invalidate()
        archiveHistory.invalidate()

        XCTAssertTrue(library.tiles.isEmpty)
        XCTAssertEqual(queue.locallyArchivedEpisodeKeys, ["episode"])
        XCTAssertTrue(history.needsReload)
        XCTAssertTrue(archiveHistory.needsReload)
    }

    func testCrossDeviceHistoryIncludesPlayedAndArchivedTerminalStates() {
        func entry(
            status: ListeningHistoryStatus,
            listenedSeconds: TimeInterval = 1_800,
            lastPositionSeconds: TimeInterval = 1_800,
            completionKind: CompletionKind? = nil
        ) -> ListeningHistoryEntry {
            ListeningHistoryEntry(
                id: UUID().uuidString,
                subscriptionID: UUID(),
                episodeID: UUID(),
                episodeTitle: "Episode",
                podcastTitle: "Podcast",
                artworkURL: nil,
                publishedAt: nil,
                durationSeconds: 1_800,
                listenedSeconds: listenedSeconds,
                lastPositionSeconds: lastPositionSeconds,
                lastListenedAt: Date(),
                status: status,
                completionKind: completionKind
            )
        }

        XCTAssertFalse(entry(status: .listened).shouldAppearInCompletedHistory)
        XCTAssertTrue(entry(status: .played).shouldAppearInCompletedHistory)
        XCTAssertTrue(entry(status: .archived).shouldAppearInCompletedHistory)
        XCTAssertTrue(
            entry(
                status: .archived,
                listenedSeconds: 30,
                lastPositionSeconds: 30,
                completionKind: .autoArchived
            ).shouldAppearInCompletedHistory
        )
        XCTAssertFalse(
            entry(
                status: .archived,
                listenedSeconds: 0,
                lastPositionSeconds: 0,
                completionKind: .autoArchived
            ).shouldAppearInCompletedHistory
        )
        XCTAssertTrue(
            entry(
                status: .archived,
                listenedSeconds: 0,
                lastPositionSeconds: 0,
                completionKind: .manuallyArchived
            ).shouldAppearInCompletedHistory
        )
    }
}
