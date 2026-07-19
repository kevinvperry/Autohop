// AI CONTEXT — Tests/EpisodeCompletionWorkflowTests.swift
//
// Focused Stage 14 characterization for the extracted completion transaction.
// It proves stale engine generations are side-effect free and that an accepted
// completion records finished history, marks the subscription episode played,
// clears playback state, deletes media, and advances while excluding the
// completed episode. No live audio, network, CloudKit, or notification delivery
// is used.

import AVFoundation
import XCTest

#if !AUTOHOP_SPM
@testable import Autohop

@MainActor
final class EpisodeCompletionWorkflowTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testStaleGenerationDoesNotApplyCompletionEffects() async throws {
        let fixture = try makeFixture()
        fixture.playback.currentEpisode = fixture.episode
        let staleGeneration = fixture.playback.generation
        fixture.playback.currentEpisode = fixture.replacementEpisode

        await fixture.workflow.handle(
            fixture.episode,
            expectedGeneration: staleGeneration
        )

        XCTAssertTrue(fixture.history.historyStore.entries.isEmpty)
        XCTAssertTrue(fixture.downloadManager.deletedEpisodeIDs.isEmpty)
        XCTAssertTrue(fixture.advancedExclusions.value.isEmpty)
        XCTAssertEqual(fixture.playback.currentEpisode?.id, fixture.replacementEpisode.id)
    }

    func testAcceptedCompletionSettlesHistoryStoreAndPlaybackBeforeAdvancing() async throws {
        let fixture = try makeFixture()
        fixture.playback.currentEpisode = fixture.episode
        fixture.playback.isPlaying = true
        fixture.playback.clock.time = 99
        let generation = fixture.playback.generation

        await fixture.workflow.handle(
            fixture.episode,
            expectedGeneration: generation
        )

        let entry = try XCTUnwrap(fixture.history.historyStore.entries.first)
        XCTAssertEqual(entry.status, .played)
        XCTAssertEqual(entry.completionKind, .finishedNaturally)
        XCTAssertEqual(entry.lastPositionSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(fixture.downloadManager.deletedEpisodeIDs, [fixture.episode.id])
        XCTAssertEqual(
            fixture.store.episode(
                subscriptionID: fixture.episode.subscriptionID,
                episodeID: fixture.episode.id
            )?.playedState,
            .played
        )
        XCTAssertFalse(fixture.playback.isPlaying)
        XCTAssertEqual(fixture.playback.clock.time, 0)
        XCTAssertEqual(fixture.advancedExclusions.value, [fixture.episode.id])
    }

    private func makeFixture() throws -> CompletionFixture {
        let store = SubscriptionStore.inMemory()
        let subscriptionID = UUID()
        var episode = Episode(
            subscriptionID: subscriptionID,
            guid: "completed",
            title: "Completed Episode",
            audioURL: URL(string: "https://example.com/completed.mp3")!
        )
        episode.durationSeconds = 100
        let replacement = Episode(
            subscriptionID: subscriptionID,
            guid: "replacement",
            title: "Replacement Episode",
            audioURL: URL(string: "https://example.com/replacement.mp3")!
        )
        _ = try store.addSubscription(
            id: subscriptionID,
            feedURL: URL(string: "https://example.com/feed.xml")!,
            title: "Completion Show",
            author: nil,
            artworkURL: nil,
            latestEpisode: episode
        )

        let history = HistoryStatsCoordinator(
            historyStore: ListeningHistoryStore(
                fileURL: temporaryURL("history.json")
            ),
            statsStore: ListeningStatsStore(
                fileURL: temporaryURL("stats.json"),
                legacyFileURL: nil
            ),
            subscriptionStore: store
        )
        let playback = PlaybackCoordinator(engine: CompletionPlaybackSpy())
        let downloadManager = CompletionDownloadManager()
        let advancedExclusions = CompletionSetBox()
        let workflow = EpisodeCompletionWorkflow(
            playbackCoordinator: playback,
            historyStatsCoordinator: history,
            subscriptionStore: store,
            downloadManager: downloadManager,
            playbackPositionStore: PlaybackPositionStore(
                fileURL: temporaryURL("positions.json")
            ),
            logger: .shared,
            cancelPlayInstantSession: { _ in },
            finishPlayInstantAndAdvance: { _ in },
            playNextEpisode: { excluded in
                advancedExclusions.value = excluded
            }
        )
        return CompletionFixture(
            workflow: workflow,
            playback: playback,
            history: history,
            store: store,
            downloadManager: downloadManager,
            episode: episode,
            replacementEpisode: replacement,
            advancedExclusions: advancedExclusions
        )
    }

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("episode-completion-\(UUID().uuidString)-\(name)")
        temporaryURLs.append(url)
        return url
    }
}

@MainActor
private struct CompletionFixture {
    let workflow: EpisodeCompletionWorkflow
    let playback: PlaybackCoordinator
    let history: HistoryStatsCoordinator
    let store: SubscriptionStore
    let downloadManager: CompletionDownloadManager
    let episode: Episode
    let replacementEpisode: Episode
    let advancedExclusions: CompletionSetBox
}

@MainActor
private final class CompletionSetBox {
    var value = Set<UUID>()
}

private final class CompletionDownloadManager: DownloadManaging {
    var backgroundEventsCompletionHandler: (() -> Void)?
    var onBackgroundDownloadCompleted: ((UUID, UUID, URL) -> Void)?
    var onProgressUpdate: ((UUID, Double, Int64, Int64) -> Void)?
    var onWatchdogCancelled: ((UUID) -> Void)?
    private(set) var deletedEpisodeIDs: [UUID] = []

    func download(_ episode: Episode, allowsCellular: Bool) async throws -> URL {
        throw CompletionTestError.unexpectedCall
    }
    func pauseDownload(episodeID: UUID) {}
    func cancelDownload(episodeID: UUID) {}
    func clearResumeData(episodeID: UUID) {}
    func expectedLocalFileURL(for episode: Episode) throws -> URL {
        throw CompletionTestError.unexpectedCall
    }
    func localFileURL(fileName: String) throws -> URL {
        throw CompletionTestError.unexpectedCall
    }
    func storeDownloadedFile(from sourceURL: URL, episode: Episode) throws -> URL {
        throw CompletionTestError.unexpectedCall
    }
    func deleteLocalFile(for episode: Episode) async throws {
        deletedEpisodeIDs.append(episode.id)
    }
    func activeDownloadEpisodeIDs() async -> Set<UUID> { [] }
}

private final class CompletionPlaybackSpy: PlaybackControlling {
    var onEpisodeFinished: ((Episode) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackInterrupted: (() -> Void)?
    var onPlaybackResumed: (() -> Void)?
    var onManualSkipForward: ((TimeInterval) -> Void)?
    var onAutoSkip: ((TimeInterval) -> Void)?
    var onTrimSilenceSaved: ((TimeInterval) -> Void)?
    var currentEpisode: Episode?
    var isPlaying = false
    var videoPlayer: AVPlayer? { nil }
    var capabilities: PlaybackCapabilities { .iOSFull }

    func play(
        _ episode: Episode,
        preference: PlaybackPreference,
        filter: ChapterFilter
    ) async throws {
        currentEpisode = episode
        isPlaying = true
    }
    func pause() { isPlaying = false }
    func resume() { isPlaying = true }
    func skipForward(seconds: TimeInterval) {}
    func skipBackward(seconds: TimeInterval) {}
    func seek(to seconds: TimeInterval) {}
    func updatePlaybackSpeed(_ speed: Double) {}
    func updateVocalBoost(_ level: VocalBoostLevel) {}
    func updateTrimSilence(_ amount: TrimSilenceAmount) {}
    func updateAudioChannelMode(_ mode: AudioChannelMode) {}
    func updateVolumeAdjustment(_ adjustment: Int) {}
    func updateEpisodeTrim(
        startSkipSeconds: TimeInterval,
        endSkipSeconds: TimeInterval
    ) {}
    func updateChapters(
        _ chapters: [Chapter],
        filter: ChapterFilter,
        for episodeID: UUID
    ) {}
    func updateChapterFilter(_ filter: ChapterFilter, for episodeID: UUID) {}
    func stop() {
        currentEpisode = nil
        isPlaying = false
    }
    func setVolume(_ volume: Float) {}
}

private enum CompletionTestError: Error {
    case unexpectedCall
}
#endif
