// AI CONTEXT — Tests/AppStateCoordinatorExtractionTests.swift
//
// Characterization gates for AppState decomposition Stages 3–8. These tests
// verify exclusive history/Stats tick ownership and checkpoint ordering, narrow
// queue invalidation plus side-effect-free reads and legacy pin persistence,
// onboarding single-vs-bulk milestone behavior, and typed routing commands.
// They use isolated temporary persistence paths and no CloudKit/network/audio.
import Combine
import XCTest

#if !AUTOHOP_SPM
@testable import Autohop

@MainActor
final class AppStateCoordinatorExtractionTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        cancellables.removeAll()
        super.tearDown()
    }

    func testHistoryStatsCoordinatorPreservesTickBoundsCompletionAndCheckpointOrder() throws {
        let store = SubscriptionStore.inMemory()
        let historyURL = temporaryURL("history.json")
        let statsURL = temporaryURL("stats.json")
        let history = ListeningHistoryStore(fileURL: historyURL)
        let stats = ListeningStatsStore(fileURL: statsURL, legacyFileURL: nil)
        let subject = HistoryStatsCoordinator(
            historyStore: history,
            statsStore: stats,
            subscriptionStore: store
        )
        let subscriptionID = UUID()
        let subscription = Subscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/history.xml")!,
            title: "History Show",
            priorityRank: 1
        )
        var episode = Episode(
            subscriptionID: subscriptionID,
            guid: "history-episode",
            title: "History Episode",
            audioURL: URL(string: "https://example.com/history.mp3")!
        )
        episode.durationSeconds = 100

        subject.recordPlaybackProgress(
            at: 10,
            isPlaying: true,
            episode: episode,
            subscription: subscription
        )
        subject.recordPlaybackProgress(
            at: 10.5,
            isPlaying: true,
            episode: episode,
            subscription: subscription
        )
        subject.recordPlaybackProgress(
            at: 15,
            isPlaying: true,
            episode: episode,
            subscription: subscription
        ) // invalid >3 s delta
        subject.recordPlaybackProgress(
            at: 16,
            isPlaying: false,
            episode: episode,
            subscription: subscription
        )
        subject.recordListeningTime(0.5, speed: 1.5, subscription: subscription)

        var syncObservedDurableFiles = false
        subject.checkpoint(reason: "test.lifecycle") { reason in
            XCTAssertEqual(reason, "test.lifecycle")
            syncObservedDurableFiles =
                FileManager.default.fileExists(atPath: historyURL.path)
                && FileManager.default.fileExists(atPath: statsURL.path)
        }

        XCTAssertTrue(syncObservedDurableFiles)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].listenedSeconds, 0.5, accuracy: 0.001)

        subject.mark(
            episode,
            status: .played,
            completionKind: .finishedNaturally,
            positionSeconds: 100
        )
        XCTAssertEqual(history.entries[0].status, .played)
        XCTAssertEqual(history.entries[0].completionKind, .finishedNaturally)
        XCTAssertEqual(subject.completedEpisodeCount, 1)
    }

    func testQueueCoordinatorUsesNarrowInvalidationAndQueueReadsDoNotWrite() throws {
        let store = SubscriptionStore.inMemory()
        let subscriptionID = UUID()
        let episode = makeEpisode(subscriptionID: subscriptionID, guid: "queue")
        _ = try store.addSubscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/queue.xml")!,
            title: "Queue Show",
            author: nil,
            artworkURL: nil,
            latestEpisode: episode
        )
        var queueEvents = 0
        store.queueDidChange
            .sink { queueEvents += 1 }
            .store(in: &cancellables)

        store.updateTitle(subscriptionID: subscriptionID, title: "Renamed")
        XCTAssertEqual(queueEvents, 0)

        let localURL = temporaryURL("queue.mp3")
        try Data("audio".utf8).write(to: localURL)
        store.markEpisodeDownloaded(
            subscriptionID: subscriptionID,
            episodeID: episode.id,
            localFileURL: localURL
        )
        XCTAssertEqual(queueEvents, 1)

        let subject = QueueCoordinator(
            subscriptionStore: store,
            queueService: QueueService(),
            currentEpisode: { nil },
            showBadge: { true },
            pinsFileURL: nil
        )
        subject.start()
        let snapshotBeforeReads = store.syncedQueueSnapshot()

        _ = subject.episodes
        _ = subject.episodes
        _ = subject.nextPlayableEpisode

        XCTAssertEqual(subject.episodes.map(\.id), [episode.id])
        XCTAssertEqual(
            store.syncedQueueSnapshot()?.updatedAt,
            snapshotBeforeReads?.updatedAt
        )
    }

    func testQueueCoordinatorPreservesLegacyPinFileKeys() throws {
        let store = SubscriptionStore.inMemory()
        let subscriptionID = UUID()
        let episode = makeEpisode(subscriptionID: subscriptionID, guid: "pin")
        _ = try store.addSubscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/pin.xml")!,
            title: "Pin Show",
            author: nil,
            artworkURL: nil,
            latestEpisode: episode
        )
        let localURL = temporaryURL("pin.mp3")
        try Data("audio".utf8).write(to: localURL)
        store.markEpisodeDownloaded(
            subscriptionID: subscriptionID,
            episodeID: episode.id,
            localFileURL: localURL
        )
        let pinsURL = temporaryURL("queue-pins.json")
        let writer = QueueCoordinator(
            subscriptionStore: store,
            queueService: QueueService(),
            currentEpisode: { nil },
            showBadge: { false },
            pinsFileURL: pinsURL
        )
        writer.start()
        writer.playLast(try XCTUnwrap(store.episode(
            subscriptionID: subscriptionID,
            episodeID: episode.id
        )))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: pinsURL)) as? [String: Any]
        )
        XCTAssertNotNil(object["overrideIDs"])
        XCTAssertNotNil(object["demotedIDs"])
        XCTAssertNil(object["playNextIDs"])

        let reader = QueueCoordinator(
            subscriptionStore: store,
            queueService: QueueService(),
            currentEpisode: { nil },
            showBadge: { false },
            pinsFileURL: pinsURL
        )
        reader.loadPins()
        XCTAssertTrue(reader.isPinnedLast(episode))
    }

    func testOnboardingCoordinatorEmitsSingleMilestoneButCoalescesBulkImport() async throws {
        let singleStore = SubscriptionStore.inMemory()
        let singleSettings = TestSettingsStore()
        let single = OnboardingCoordinator(
            subscriptionStore: singleStore,
            settingsStore: singleSettings
        )
        var singleOutputs: [OnboardingOutput] = []
        single.onOutput = { singleOutputs.append($0) }
        let singleID = UUID()
        _ = try singleStore.addSubscription(
            id: singleID,
            feedURL: URL(string: "https://example.com/single.xml")!,
            title: "Single",
            author: nil,
            artworkURL: nil,
            latestEpisode: makeEpisode(subscriptionID: singleID, guid: "single")
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(singleOutputs, [.firstSubscription(singleID)])

        let bulkStore = SubscriptionStore.inMemory()
        let bulkSettings = TestSettingsStore()
        let bulk = OnboardingCoordinator(
            subscriptionStore: bulkStore,
            settingsStore: bulkSettings
        )
        var bulkOutputs: [OnboardingOutput] = []
        bulk.onOutput = { bulkOutputs.append($0) }
        for index in 0..<2 {
            let id = UUID()
            _ = try bulkStore.addSubscription(
                id: id,
                feedURL: URL(string: "https://example.com/bulk-\(index).xml")!,
                title: "Bulk \(index)",
                author: nil,
                artworkURL: nil,
                latestEpisode: makeEpisode(subscriptionID: id, guid: "bulk-\(index)")
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(bulkOutputs.isEmpty)
        XCTAssertTrue(bulkSettings.appSettings.hasSubscribedFirstShow)
    }

    func testRoutingCoordinatorProducesTypedLaunchAndPresentationCommands() {
        let subject = AppRoutingCoordinator()
        var received: [AppRouteCommand] = []
        subject.commands
            .sink { received.append($0) }
            .store(in: &cancellables)

        XCTAssertEqual(
            subject.launchCommand(isFirstRun: true, launchScreen: .player),
            .presentWelcome
        )
        XCTAssertEqual(
            subject.launchCommand(isFirstRun: false, launchScreen: .discover),
            .openDiscover
        )
        XCTAssertEqual(subject.welcomeCompleted(.findShows), .openDiscover)

        let subscriptionID = UUID()
        subject.send(.presentFirstSubscription(subscriptionID))
        XCTAssertEqual(received, [.presentFirstSubscription(subscriptionID)])
    }

    func testDownloadCoordinatorOwnsBoundedSlotsBackoffAndActivityProjection() throws {
        let subject = DownloadCoordinator()
        XCTAssertEqual(subject.maxConcurrentDownloads, 3)

        subject.recordFailure(guid: "failure-guid", title: "Failure", logger: .shared)
        XCTAssertEqual(subject.failureBackoff["failure-guid"]?.failures, 1)
        XCTAssertNotNil(subject.failureBackoff["failure-guid"]?.retryAfter)

        let subscriptionID = UUID()
        var episode = makeEpisode(subscriptionID: subscriptionID, guid: "downloaded")
        let localURL = temporaryURL("downloaded.mp3")
        try Data("audio".utf8).write(to: localURL)
        episode.downloadState = .downloaded
        episode.localFileURL = localURL
        var subscription = Subscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/downloaded.xml")!,
            title: "Downloaded",
            priorityRank: 1
        )
        subscription.episodes = [episode]
        subject.rebuildDownloadedActivities(from: [subscription])
        XCTAssertEqual(subject.downloadedActivities.map(\.episodeID), [episode.id])
    }

    func testAutoDownloadWorkflowSerializesReentrantDrain() async {
        let subject = AutoDownloadWorkflow(
            intentStore: AutoDownloadIntentStore(fileURL: temporaryURL("intents.json"))
        )
        var operations = 0
        await subject.withExclusiveDrain {
            operations += 1
            await subject.withExclusiveDrain {
                operations += 100
            }
        }
        XCTAssertEqual(operations, 1)
        XCTAssertFalse(subject.isDraining)
    }

    func testAutoArchiveCoordinatorAppliesInactiveRuleAndHonorsGate() async throws {
        let store = SubscriptionStore.inMemory()
        let settingsStore = TestSettingsStore()
        let activityURL = temporaryURL("auto-archive.json")
        let activityStore = AutoArchiveActivityStore(fileURL: activityURL)
        let subscriptionID = UUID()
        var episode = makeEpisode(subscriptionID: subscriptionID, guid: "inactive")
        episode.downloadedAt = Date().addingTimeInterval(-5 * 3600)
        episode.downloadState = .downloaded
        _ = try store.addSubscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/inactive.xml")!,
            title: "Inactive",
            author: nil,
            artworkURL: nil,
            latestEpisode: episode
        )
        store.updateAutoArchiveSettings(
            subscriptionID: subscriptionID,
            settings: AutoArchiveSettings(
                afterPlayed: .never,
                afterInactive: .hours4,
                episodeLimit: .noLimit
            )
        )

        let subject = AutoArchiveCoordinator(
            subscriptionStore: store,
            settingsStore: settingsStore,
            activityStore: activityStore
        )
        var archivedIDs: [UUID] = []
        subject.installRuntimeAdapters(
            archive: { episode, _ in archivedIDs.append(episode.id) },
            currentEpisodeID: { nil },
            refreshQueue: { _ in },
            resourceContext: { [:] }
        )

        await subject.runIfNeeded(reason: "test", force: true)
        XCTAssertEqual(archivedIDs, [episode.id])
        XCTAssertEqual(activityStore.entries.first?.rule, .inactiveEpisodes)

        await subject.runIfNeeded(reason: "test.gated")
        XCTAssertEqual(archivedIDs.count, 1)
    }

    private func makeEpisode(subscriptionID: UUID, guid: String) -> Episode {
        Episode(
            subscriptionID: subscriptionID,
            guid: guid,
            title: guid,
            audioURL: URL(string: "https://example.com/\(guid).mp3")!
        )
    }

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-stage3-8-\(UUID().uuidString)-\(name)")
        temporaryURLs.append(url)
        return url
    }
}

private final class TestSettingsStore: SettingsStoring {
    var appSettings: AppSettings = .default
}
#endif
