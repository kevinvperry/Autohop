import Foundation

// AI CONTEXT — App/PlaybackChapterWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Playback chapter presentation and mutation workflow. It resolves current,
// active, and displayable chapter state; applies subscription chapter filters
// live; calculates previous/next navigation; and asynchronously loads
// `podcast:chapters` JSON after playback starts.
//
// CONCURRENCY / RELIABILITY:
// External requests use a bounded ephemeral URLSession (10 s request / 20 s
// resource). Results apply only when PlaybackCoordinator's episode generation
// and episode identity still match. The subscription's latest ChapterFilter is
// read after the network await so a late response cannot undo settings changed
// while the request was in flight.
//
// INVARIANTS:
// Chapter navigation enters the shared seek workflow. Filtering mutates one
// subscription and updates only the matching loaded engine episode. This type
// owns no playback transport, queue order, or feed refresh.

@MainActor
protocol PlaybackChapterPresenting: AnyObject {
    var currentChapter: Chapter? { get }
    var activeChapters: [Chapter] { get }
    var chapterEpisode: Episode? { get }
    var supportsChapters: Bool { get }
    var previousTarget: TimeInterval? { get }
    var nextTarget: TimeInterval? { get }
}

@MainActor
final class PlaybackChapterWorkflow: PlaybackChapterPresenting {
    private let playback: PlaybackCoordinator
    private let chapterService: any ChapterServicing
    private let subscriptionStore: SubscriptionStore
    private let queueCoordinator: QueueCoordinator
    private let seekWorkflow: PlaybackSeekWorkflow

    init(
        playback: PlaybackCoordinator,
        chapterService: any ChapterServicing,
        subscriptionStore: SubscriptionStore,
        queueCoordinator: QueueCoordinator,
        seekWorkflow: PlaybackSeekWorkflow
    ) {
        self.playback = playback
        self.chapterService = chapterService
        self.subscriptionStore = subscriptionStore
        self.queueCoordinator = queueCoordinator
        self.seekWorkflow = seekWorkflow
    }

    var currentChapter: Chapter? {
        guard let episode = playback.currentEpisode else { return nil }
        return chapterService.chapter(
            atTime: playback.clock.time,
            in: episode
        )
    }

    var activeChapters: [Chapter] {
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return []
        }
        return chapterService.activeChapters(
            for: episode,
            filter: subscription.chapterFilter
        )
    }

    var chapterEpisode: Episode? {
        let episode = playback.currentEpisode
            ?? queueCoordinator.nextPlayableEpisode
        return episode?.chapters.isEmpty == false ? episode : nil
    }

    var supportsChapters: Bool {
        chapterEpisode != nil
    }

    var previousTarget: TimeInterval? {
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return nil
        }
        return PlaybackSessionPolicy.previousChapterStart(
            at: playback.clock.time,
            currentChapter: currentChapter,
            in: chapterService.activeChapters(
                for: episode,
                filter: subscription.chapterFilter
            )
        )
    }

    var nextTarget: TimeInterval? {
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return nil
        }
        return PlaybackSessionPolicy.nextChapterStart(
            at: playback.clock.time,
            in: chapterService.activeChapters(
                for: episode,
                filter: subscription.chapterFilter
            )
        )
    }

    func toggleChapter(subscriptionID: UUID, position: Int) {
        guard let subscription = subscriptionStore.subscription(
            id: subscriptionID
        ) else {
            return
        }
        var filter = subscription.chapterFilter
        if filter.skippedPositions.contains(position) {
            filter.skippedPositions.remove(position)
        } else {
            filter.skippedPositions.insert(position)
        }
        apply(filter, subscriptionID: subscriptionID)
    }

    func apply(_ filter: ChapterFilter, subscriptionID: UUID) {
        subscriptionStore.updateChapterFilter(
            subscriptionID: subscriptionID,
            filter: filter
        )
        guard let episode = playback.currentEpisode,
              episode.subscriptionID == subscriptionID else {
            return
        }
        playback.engine.updateChapterFilter(filter, for: episode.id)
    }

    func navigateToPrevious() {
        guard let previousTarget else { return }
        seekWorkflow.seek(to: previousTarget)
    }

    func navigateToNext() {
        guard let nextTarget else { return }
        seekWorkflow.seek(to: nextTarget)
    }

    func scheduleExternalFetch(
        url: URL,
        episodeID: UUID,
        subscriptionID: UUID,
        generation: UInt64
    ) {
        Task { [weak self] in
            guard let self,
                  let chapters = await self.fetchExternalChapters(
                    url: url,
                    episodeID: episodeID
                  ),
                  self.playback.isCurrent(
                    generation: generation,
                    episodeID: episodeID
                  ) else {
                return
            }
            self.subscriptionStore.updateEpisodeChapters(
                subscriptionID: subscriptionID,
                episodeID: episodeID,
                chapters: chapters
            )
            self.playback.currentEpisode?.chapters = chapters
            let latestFilter = self.subscriptionStore.subscription(
                id: subscriptionID
            )?.chapterFilter ?? ChapterFilter()
            self.playback.engine.updateChapters(
                chapters,
                filter: latestFilter,
                for: episodeID
            )
        }
    }

    private func fetchExternalChapters(
        url: URL,
        episodeID: UUID
    ) async -> [Chapter]? {
        guard let (data, response) = try? await Self.fetchSession.data(
            from: url
        ),
              HTTPResponseValidation.isAcceptable(response) else {
            return nil
        }
        struct JSONChapters: Decodable {
            struct JSONChapter: Decodable {
                var startTime: TimeInterval
                var title: String?
                var img: URL?
            }
            var chapters: [JSONChapter]
        }
        guard let parsed = try? JSONDecoder().decode(
            JSONChapters.self,
            from: data
        ),
              !parsed.chapters.isEmpty else {
            return nil
        }
        return parsed.chapters.enumerated().map { index, chapter in
            Chapter(
                episodeID: episodeID,
                position: index + 1,
                title: chapter.title ?? "Chapter \(index + 1)",
                startSeconds: chapter.startTime,
                artworkURL: chapter.img,
                source: .podcastChaptersJSON
            )
        }
    }

    private static let fetchSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
}
