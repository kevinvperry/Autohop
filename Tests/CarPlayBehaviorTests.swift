// AI CONTEXT - Tests/CarPlayBehaviorTests.swift
// Coverage for CarPlay behavior that can be verified without a live CarPlay
// runtime: queue/subscription projection, cold-launch resume, action routing
// decisions, speed cycling, system playback-rate command routing, and Shared Listening state. SwiftPM's
// AutohopCore target intentionally excludes App/CarPlay, so these tests compile
// only in the Xcode app test target.
import XCTest

#if !AUTOHOP_SPM
import AVFoundation
@testable import Autohop

@MainActor
final class CarPlayBehaviorTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testQueueProjectionShowsDownloadedRowsOnlyWithProgress() throws {
        let harness = try makeHarness()
        let downloaded = makeEpisode(subscriptionID: harness.subscriptionID, guid: "downloaded", title: "Downloaded", duration: 100)
        let notDownloaded = makeEpisode(subscriptionID: harness.subscriptionID, guid: "remote", title: "Remote", duration: 100)
        try harness.installEpisodes([downloaded, notDownloaded], downloadedIDs: [downloaded.id])

        harness.appState.currentPlayerEpisode = harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: downloaded.id)
        harness.appState.currentPlayerTime = 25

        let rows = CarPlayEpisodePresenter().rows(from: harness.appState)

        XCTAssertEqual(rows.map(\.title), ["Downloaded"])
        XCTAssertEqual(rows.first?.podcastTitle, "CarPlay Show")
        XCTAssertEqual(try XCTUnwrap(rows.first?.playbackProgress), 0.25, accuracy: 0.001)
        XCTAssertEqual(rows.first?.isCurrentEpisode, true)
    }

    func testQueueProjectionEmptyWhenNothingIsDownloaded() throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "remote", title: "Remote")
        try harness.installEpisodes([episode], downloadedIDs: [])

        XCTAssertTrue(CarPlayEpisodePresenter().rows(from: harness.appState).isEmpty)
    }

    func testSubscriptionProjectionShowsRealSubscriptionsInPriorityOrder() throws {
        let harness = try makeHarness()
        let secondSubscriptionID = UUID()
        let secondSeed = makeEpisode(subscriptionID: secondSubscriptionID, guid: "later-seed", title: "Later Seed")
        _ = try harness.store.addSubscription(
            id: secondSubscriptionID,
            feedURL: URL(string: "https://example.com/later.xml")!,
            title: "Later Show",
            author: nil,
            artworkURL: nil,
            latestEpisode: secondSeed,
            insertAtBottom: true
        )

        let rows = CarPlayEpisodePresenter().subscriptionRows(from: harness.appState)

        XCTAssertEqual(rows.map(\.title), ["CarPlay Show", "Later Show"])
        XCTAssertEqual(rows.map(\.id), [harness.subscriptionID, secondSubscriptionID])
    }

    func testSubscriptionProjectionExcludesBrowsePreviews() throws {
        let harness = try makeHarness()
        let parsedEpisode = ParsedEpisode(
            guid: "preview",
            title: "Preview Episode",
            description: nil,
            subtitle: nil,
            author: nil,
            publishedAt: nil,
            durationSeconds: nil,
            audioURL: URL(string: "https://example.com/preview.mp3"),
            artworkURL: nil,
            fileSizeBytes: nil,
            isExplicit: nil,
            chapters: [],
            externalChaptersURL: nil
        )
        let parsedFeed = ParsedFeed(
            title: "Preview Show",
            author: nil,
            artworkURL: nil,
            latestEpisode: parsedEpisode
        )
        _ = try harness.store.addPreviewSubscription(
            parsedFeed: parsedFeed,
            feedURL: URL(string: "https://example.com/preview.xml")!
        )

        let rows = CarPlayEpisodePresenter().subscriptionRows(from: harness.appState)

        XCTAssertEqual(rows.map(\.title), ["CarPlay Show"])
    }

    func testSubscriptionEpisodeProjectionShowsRecentEpisodesLatestFirstWithDownloadState() throws {
        let harness = try makeHarness()
        let old = makeEpisode(
            subscriptionID: harness.subscriptionID,
            guid: "old",
            title: "Old",
            publishedAt: Date(timeIntervalSince1970: 1)
        )
        let new = makeEpisode(
            subscriptionID: harness.subscriptionID,
            guid: "new",
            title: "New",
            publishedAt: Date(timeIntervalSince1970: 2)
        )
        let remote = makeEpisode(
            subscriptionID: harness.subscriptionID,
            guid: "remote",
            title: "Remote",
            publishedAt: Date(timeIntervalSince1970: 3)
        )
        var played = makeEpisode(
            subscriptionID: harness.subscriptionID,
            guid: "played",
            title: "Played",
            publishedAt: Date(timeIntervalSince1970: 4)
        )
        played.playedState = .played
        var archived = makeEpisode(
            subscriptionID: harness.subscriptionID,
            guid: "archived",
            title: "Archived",
            publishedAt: Date(timeIntervalSince1970: 5)
        )
        archived.playedState = .archived
        try harness.installEpisodes([old, new, remote, played, archived], downloadedIDs: [old.id, new.id])

        let subscription = try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID))
        let rows = CarPlayEpisodePresenter().episodeRows(for: subscription, appState: harness.appState)

        XCTAssertEqual(rows.map(\.title), ["Archived", "Played", "Remote", "New", "Old"])
        XCTAssertEqual(rows.map(\.podcastTitle), Array(repeating: "CarPlay Show", count: 5))
        XCTAssertEqual(rows.map(\.requiresDownload), [true, true, true, false, false])
    }

    func testCarPlayDownloadHelperDownloadsAndReturnsPlayableEpisode() async throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "remote-download", title: "Remote Download")
        try harness.installEpisodes([episode], downloadedIDs: [])
        harness.download.downloadHandler = { try harness.makeLocalFile($0.id) }

        let stored = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: episode.id))
        let downloaded = await harness.appState.downloadEpisodeForCarPlayAction(stored)

        XCTAssertEqual(downloaded?.id, episode.id)
        XCTAssertEqual(downloaded?.downloadState, .downloaded)
        XCTAssertNotNil(downloaded?.localFileName)
        XCTAssertEqual(harness.download.downloadedEpisodeIDs, [episode.id])
    }

    func testCarPlayColdLaunchResumesRestoredEpisode() async throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "restored", title: "Restored", duration: 300)
        try harness.installEpisodes([episode], downloadedIDs: [episode.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: episode.id))
        harness.appState.currentPlayerTime = 123

        await harness.appState.resumePlaybackForCarPlayLaunchIfNeeded()

        XCTAssertEqual(harness.playback.playedEpisodes.map(\.id), [episode.id])
        XCTAssertEqual(try XCTUnwrap(harness.playback.lastSeek), 123, accuracy: 0.001)
        XCTAssertTrue(harness.appState.isPlaying)
    }

    func testPlayNextWithoutCurrentEpisodePlaysImmediately() async throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "first", title: "First")
        try harness.installEpisodes([episode], downloadedIDs: [episode.id])
        let stored = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: episode.id))

        await CarPlayActionRouter(appState: harness.appState).playNext(stored)

        XCTAssertEqual(harness.playback.playedEpisodes.map(\.id), [episode.id])
        XCTAssertEqual(harness.appState.currentPlayerEpisode?.id, episode.id)
        XCTAssertTrue(harness.appState.isPlaying)
    }

    func testPlayNextWithCurrentEpisodePinsAfterCurrent() async throws {
        let harness = try makeHarness()
        let first = makeEpisode(subscriptionID: harness.subscriptionID, guid: "first", title: "First", publishedAt: Date(timeIntervalSince1970: 1))
        let second = makeEpisode(subscriptionID: harness.subscriptionID, guid: "second", title: "Second", publishedAt: Date(timeIntervalSince1970: 2))
        try harness.installEpisodes([first, second], downloadedIDs: [first.id, second.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: first.id))

        await CarPlayActionRouter(appState: harness.appState).playNext(try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: second.id)))

        XCTAssertEqual(harness.appState.downloadedQueue.first?.id, second.id)
        XCTAssertTrue(harness.playback.playedEpisodes.isEmpty)
    }

    func testPlayLastDemotesEpisodeToEndOfQueue() throws {
        let harness = try makeHarness()
        let first = makeEpisode(subscriptionID: harness.subscriptionID, guid: "first", title: "First", publishedAt: Date(timeIntervalSince1970: 1))
        let second = makeEpisode(subscriptionID: harness.subscriptionID, guid: "second", title: "Second", publishedAt: Date(timeIntervalSince1970: 2))
        let third = makeEpisode(subscriptionID: harness.subscriptionID, guid: "third", title: "Third", publishedAt: Date(timeIntervalSince1970: 3))
        try harness.installEpisodes([first, second, third], downloadedIDs: [first.id, second.id, third.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: first.id))

        CarPlayActionRouter(appState: harness.appState).playLast(try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: second.id)))

        XCTAssertEqual(harness.appState.downloadedQueue.map(\.id), [first.id, third.id, second.id])
    }

    func testArchiveCurrentAdvancesOrClearsWhenQueueIsEmpty() async throws {
        let harness = try makeHarness()
        let first = makeEpisode(subscriptionID: harness.subscriptionID, guid: "first", title: "First", publishedAt: Date(timeIntervalSince1970: 1))
        let second = makeEpisode(subscriptionID: harness.subscriptionID, guid: "second", title: "Second", publishedAt: Date(timeIntervalSince1970: 2))
        try harness.installEpisodes([first, second], downloadedIDs: [first.id, second.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: first.id))

        await CarPlayActionRouter(appState: harness.appState).archiveCurrent()

        XCTAssertEqual(harness.appState.currentPlayerEpisode?.id, second.id)
        XCTAssertFalse(harness.appState.downloadedQueue.contains { $0.id == first.id })

        await CarPlayActionRouter(appState: harness.appState).archiveCurrent()

        XCTAssertNil(harness.appState.currentPlayerEpisode)
        XCTAssertTrue(harness.appState.downloadedQueue.isEmpty)
    }

    func testSpeedCycleAdvancesAndWrapsWhenSharedListeningIsOff() throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "speed", title: "Speed")
        try harness.installEpisodes([episode], downloadedIDs: [episode.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: episode.id))

        var preference = try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference)
        preference.speed = 1.0
        harness.store.updatePlaybackPreference(subscriptionID: harness.subscriptionID, preference: preference)

        CarPlayActionRouter(appState: harness.appState).cyclePlaybackSpeed()

        XCTAssertEqual(try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference.speed), 1.1, accuracy: 0.001)

        preference.speed = PlaybackPreference.speedOptions.last!
        harness.store.updatePlaybackPreference(subscriptionID: harness.subscriptionID, preference: preference)
        CarPlayActionRouter(appState: harness.appState).cyclePlaybackSpeed()

        XCTAssertEqual(
            try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference.speed),
            PlaybackPreference.speedOptions.first!,
            accuracy: 0.001
        )
    }

    func testSystemPlaybackRateCommandUpdatesCurrentPodcastSpeed() throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "rate", title: "Rate")
        try harness.installEpisodes([episode], downloadedIDs: [episode.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: episode.id))
        harness.appState.isPlaying = true

        harness.appState.setPlaybackSpeedForCurrentEpisode(1.6)

        XCTAssertEqual(try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference.speed), 1.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(harness.playback.lastSpeed), 1.6, accuracy: 0.001)

        CarPlayActionRouter(appState: harness.appState).setSharedListening(active: true)
        harness.appState.setPlaybackSpeedForCurrentEpisode(2.0)

        XCTAssertEqual(try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference.speed), 1.6, accuracy: 0.001)
    }

    func testSharedListeningBlocksPodcastSpeedCycleAndUpdatesSharedSpeed() throws {
        let harness = try makeHarness()
        let episode = makeEpisode(subscriptionID: harness.subscriptionID, guid: "shared", title: "Shared")
        try harness.installEpisodes([episode], downloadedIDs: [episode.id])
        harness.appState.currentPlayerEpisode = try XCTUnwrap(harness.store.episode(subscriptionID: harness.subscriptionID, episodeID: episode.id))

        var preference = try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference)
        preference.speed = 1.6
        harness.store.updatePlaybackPreference(subscriptionID: harness.subscriptionID, preference: preference)

        let router = CarPlayActionRouter(appState: harness.appState)
        router.setSharedListening(active: true)
        router.cyclePlaybackSpeed()

        XCTAssertTrue(harness.settings.appSettings.sharedListeningActive)
        XCTAssertEqual(try XCTUnwrap(harness.store.subscription(id: harness.subscriptionID)?.playbackPreference.speed), 1.6, accuracy: 0.001)

        router.selectSharedListeningSpeed(1.3)

        XCTAssertEqual(harness.settings.appSettings.sharedListeningSpeed, 1.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(harness.playback.lastSpeed), 1.3, accuracy: 0.001)

        harness.appState.currentPlayerEpisode = nil
        XCTAssertTrue(harness.settings.appSettings.sharedListeningActive)
    }

    private func makeHarness() throws -> Harness {
        let store = SubscriptionStore.inMemory()
        let subscriptionID = UUID()
        let seed = makeEpisode(subscriptionID: subscriptionID, guid: "seed", title: "Seed")
        _ = try store.addSubscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/feed.xml")!,
            title: "CarPlay Show",
            author: nil,
            artworkURL: URL(string: "https://example.com/show.jpg"),
            latestEpisode: seed
        )
        let playback = PlaybackSpy()
        let download = TestDownloadManager()
        let settings = TestSettingsStore()
        let appState = AppState(
            feedService: TestFeedService(),
            downloadManager: download,
            playbackEngine: playback,
            chapterService: ChapterService(),
            queueService: QueueService(),
            settingsStore: settings,
            subscriptionStore: store
        )
        return Harness(
            appState: appState,
            store: store,
            playback: playback,
            download: download,
            settings: settings,
            subscriptionID: subscriptionID,
            makeLocalFile: { [weak self] id in try self?.makeLocalFile(id: id) ?? URL(fileURLWithPath: "/dev/null") }
        )
    }

    private func makeEpisode(
        subscriptionID: UUID,
        guid: String,
        title: String,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil
    ) -> Episode {
        var episode = Episode(
            subscriptionID: subscriptionID,
            guid: guid,
            title: title,
            audioURL: URL(string: "https://example.com/\(guid).mp3")!
        )
        episode.durationSeconds = duration
        episode.publishedAt = publishedAt
        return episode
    }

    private func makeLocalFile(id: UUID) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohop-carplay-\(id.uuidString)")
            .appendingPathExtension("mp3")
        try Data("test-audio".utf8).write(to: url)
        temporaryFiles.append(url)
        return url
    }
}

@MainActor
private struct Harness {
    let appState: AppState
    let store: SubscriptionStore
    let playback: PlaybackSpy
    let download: TestDownloadManager
    let settings: TestSettingsStore
    let subscriptionID: UUID
    let makeLocalFile: (UUID) throws -> URL

    func installEpisodes(_ episodes: [Episode], downloadedIDs: Set<UUID>) throws {
        store.updateEpisodes(subscriptionID: subscriptionID, episodes: episodes)
        for episode in episodes where downloadedIDs.contains(episode.id) {
            store.markEpisodeDownloaded(
                subscriptionID: subscriptionID,
                episodeID: episode.id,
                localFileURL: try makeLocalFile(episode.id)
            )
        }
    }
}

private final class TestSettingsStore: SettingsStoring {
    var appSettings: AppSettings = .default
}

private final class TestFeedService: FeedServicing {
    func refresh(feedURL: URL, subscriptionID: UUID, episodeLimit: Int?) async throws -> FeedRefreshResult {
        throw TestError.unexpectedCall
    }

    func refreshIfModified(
        feedURL: URL,
        subscriptionID: UUID,
        episodeLimit: Int?,
        validators: FeedValidators?
    ) async throws -> FeedRefreshOutcome {
        throw TestError.unexpectedCall
    }
}

private final class TestDownloadManager: DownloadManaging {
    var backgroundEventsCompletionHandler: (() -> Void)?
    var onBackgroundDownloadCompleted: ((UUID, UUID, URL) -> Void)?
    var onProgressUpdate: ((UUID, Double, Int64, Int64) -> Void)?
    var onWatchdogCancelled: ((UUID) -> Void)?
    var downloadHandler: ((Episode) throws -> URL)?
    private(set) var downloadedEpisodeIDs: [UUID] = []

    func download(_ episode: Episode, allowsCellular: Bool) async throws -> URL {
        downloadedEpisodeIDs.append(episode.id)
        if let downloadHandler {
            return try downloadHandler(episode)
        }
        throw TestError.unexpectedCall
    }

    func pauseDownload(episodeID: UUID) {}
    func cancelDownload(episodeID: UUID) {}
    func clearResumeData(episodeID: UUID) {}
    func expectedLocalFileURL(for episode: Episode) throws -> URL { throw TestError.unexpectedCall }
    func localFileURL(fileName: String) throws -> URL { throw TestError.unexpectedCall }
    func storeDownloadedFile(from sourceURL: URL, episode: Episode) throws -> URL { throw TestError.unexpectedCall }
    func deleteLocalFile(for episode: Episode) async throws {}
    func activeDownloadEpisodeIDs() async -> Set<UUID> { [] }
}

private final class PlaybackSpy: PlaybackControlling {
    var onEpisodeFinished: ((Episode) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackInterrupted: (() -> Void)?
    var onPlaybackResumed: (() -> Void)?
    var onManualSkipForward: ((TimeInterval) -> Void)?
    var onAutoSkip: ((TimeInterval) -> Void)?
    var onTrimSilenceSaved: ((TimeInterval) -> Void)?

    private(set) var currentEpisode: Episode?
    private(set) var isPlaying = false
    var videoPlayer: AVPlayer? { nil }
    var capabilities: PlaybackCapabilities { .iOSFull }
    var playedEpisodes: [Episode] = []
    var lastSpeed: Double?
    var lastSeek: TimeInterval?

    func play(_ episode: Episode, preference: PlaybackPreference, filter: ChapterFilter) async throws {
        currentEpisode = episode
        isPlaying = true
        playedEpisodes.append(episode)
        lastSpeed = preference.speed
    }

    func pause() { isPlaying = false }
    func resume() { isPlaying = true }
    func skipForward(seconds: TimeInterval) {}
    func skipBackward(seconds: TimeInterval) {}
    func seek(to seconds: TimeInterval) { lastSeek = seconds }
    func updatePlaybackSpeed(_ speed: Double) { lastSpeed = speed }
    func updateVocalBoost(_ level: VocalBoostLevel) {}
    func updateTrimSilence(_ amount: TrimSilenceAmount) {}
    func updateEpisodeTrim(startSkipSeconds: TimeInterval, endSkipSeconds: TimeInterval) {}
    func updateChapters(_ chapters: [Chapter], filter: ChapterFilter, for episodeID: UUID) {}
    func updateChapterFilter(_ filter: ChapterFilter, for episodeID: UUID) {}
    func stop() {
        currentEpisode = nil
        isPlaying = false
    }
    func setVolume(_ volume: Float) {}
}

private enum TestError: Error {
    case unexpectedCall
}
#endif
