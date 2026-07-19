import Combine
import Foundation

// AI CONTEXT — App/QueueCoordinator.swift
//
// PURPOSE / OWNERSHIP:
// Stage 4 owner of the iPhone downloaded Priority Stack projection. It owns the
// memoized ordered queue, Play Next/Play Last pins, pin persistence, Up Next,
// badge projection, debounced invalidation, and explicit changed-composition
// QueueSnapshot publication. QueueService/QueueModel remain pure policy.
//
// DEPENDENCIES / EVENTS:
// Reads SubscriptionStore and subscribes only to its queueDidChange event, not
// broad objectWillChange. `observePlayback(_:)` owns the narrow current-episode
// subscription and provider. Badge publication is also performed here because
// it is a direct projection of the queue count and queue-badge setting.
//
// PERSISTENCE / SYNC:
// Pins retain Application Support/Autohop/queue-pins.json and the existing
// Codable shape. A queue snapshot is written only after the episode identity
// sequence changes; SubscriptionStore retains its equality dedupe as a second
// safety boundary.
//
// INVARIANTS:
// - Queue reads are side-effect free.
// - One queue-affecting store event schedules at most one recompute.
// - Current playback is excluded only from Up Next resolution.
// - Pin semantics and base ordering are delegated unchanged to QueueModel.
// - No playback, download, archive, feed, CloudKit lifecycle, or navigation
//   policy belongs here.
@MainActor
final class QueueCoordinator: ObservableObject {
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var upNextEpisode: Episode?

    private(set) var pins = QueuePins()
    private let subscriptionStore: SubscriptionStore
    private let queueService: QueueServicing
    private var currentEpisode: () -> Episode?
    private let showBadge: () -> Bool
    private let logger: AppLogger
    private let pinsFileURL: URL?
    private var lastPublishedIDs: [UUID] = []
    private var recomputeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var playbackObservationInstalled = false

    /// Preserve the exact pre-Stage-4 JSON keys.
    private struct SavedQueuePins: Codable {
        var overrideIDs: [UUID]
        var demotedIDs: [UUID]
    }

    init(
        subscriptionStore: SubscriptionStore,
        queueService: QueueServicing,
        currentEpisode: @escaping () -> Episode?,
        showBadge: @escaping () -> Bool,
        logger: AppLogger = .shared
    ) {
        self.subscriptionStore = subscriptionStore
        self.queueService = queueService
        self.currentEpisode = currentEpisode
        self.showBadge = showBadge
        self.logger = logger
        self.pinsFileURL = Self.defaultPinsFileURL()

        subscriptionStore.queueDidChange
            .sink { [weak self] in self?.scheduleRecompute(reason: "store.queueChanged") }
            .store(in: &cancellables)
    }

    /// Explicit persistence location is a test seam; nil disables pin I/O.
    init(
        subscriptionStore: SubscriptionStore,
        queueService: QueueServicing,
        currentEpisode: @escaping () -> Episode?,
        showBadge: @escaping () -> Bool,
        logger: AppLogger = .shared,
        pinsFileURL: URL?
    ) {
        self.subscriptionStore = subscriptionStore
        self.queueService = queueService
        self.currentEpisode = currentEpisode
        self.showBadge = showBadge
        self.logger = logger
        self.pinsFileURL = pinsFileURL

        subscriptionStore.queueDidChange
            .sink { [weak self] in self?.scheduleRecompute(reason: "store.queueChanged") }
            .store(in: &cancellables)
    }

    var nextPlayableEpisode: Episode? { episodes.first }
    var count: Int { episodes.count }

    func start() {
        recompute(reason: "queue.start")
        publishBadge()
    }

    /// Connects the queue to playback without exposing a callback slot for
    /// AppState to populate. The weak provider prevents a queue/player retain
    /// cycle, while the typed publisher invalidates only current-dependent
    /// Up Next resolution.
    func observePlayback(_ playbackCoordinator: PlaybackCoordinator) {
        guard !playbackObservationInstalled else { return }
        playbackObservationInstalled = true
        currentEpisode = { [weak playbackCoordinator] in
            playbackCoordinator?.currentEpisode
        }
        playbackCoordinator.$currentEpisode
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleRecompute(reason: "player.currentChanged")
            }
            .store(in: &cancellables)
    }

    func loadPins() {
        guard let pinsFileURL,
              let data = try? Data(contentsOf: pinsFileURL),
              let restored = try? JSONDecoder().decode(SavedQueuePins.self, from: data)
        else { return }
        LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: pinsFileURL)
        pins = QueuePins(
            playNextIDs: restored.overrideIDs,
            playLastIDs: restored.demotedIDs
        )
        logger.info("queue.pinsLoaded", "Queue pins restored", metadata: [
            "overrideCount": "\(pins.playNextIDs.count)",
            "demotedCount": "\(pins.playLastIDs.count)"
        ])
        recompute(reason: "queue.pinsLoaded")
    }

    func isPinnedNext(_ episode: Episode) -> Bool {
        pins.playNextIDs.contains(episode.id)
    }

    func isPinnedLast(_ episode: Episode) -> Bool {
        pins.playLastIDs.contains(episode.id)
    }

    func playNext(_ episode: Episode) {
        let current = currentEpisode()
        guard current?.id != episode.id else { return }
        pins.playLastIDs.removeAll { $0 == episode.id }
        pins.playNextIDs.removeAll { $0 == episode.id }
        pins.playNextIDs.insert(episode.id, at: 0)
        persistPins()
        recompute(reason: "queue.playNextOverride")
        logger.info(
            "queue.playNextOverride",
            "Episode moved to play next",
            metadata: [
                "episode": episode.title,
                "current": current?.title ?? "none"
            ]
        )
    }

    func playLast(_ episode: Episode) {
        let current = currentEpisode()
        guard current?.id != episode.id else { return }
        pins.playNextIDs.removeAll { $0 == episode.id }
        pins.playLastIDs.removeAll { $0 == episode.id }
        pins.playLastIDs.append(episode.id)
        persistPins()
        recompute(reason: "queue.playLastDemotion")
        logger.info(
            "queue.playLastDemotion",
            "Episode moved to play last",
            metadata: [
                "episode": episode.title,
                "current": current?.title ?? "none"
            ]
        )
    }

    @discardableResult
    func unpin(_ episode: Episode) -> (wasNext: Bool, wasLast: Bool) {
        let result = (
            wasNext: pins.playNextIDs.contains(episode.id),
            wasLast: pins.playLastIDs.contains(episode.id)
        )
        guard result.wasNext || result.wasLast else { return result }
        pins.playNextIDs.removeAll { $0 == episode.id }
        pins.playLastIDs.removeAll { $0 == episode.id }
        persistPins()
        recompute(reason: "queue.unpin")
        logger.info(
            "queue.unpin",
            "Episode unpinned",
            metadata: [
                "episode": episode.title,
                "wasOverride": "\(result.wasNext)"
            ]
        )
        return result
    }

    func removePins(for episodeID: UUID) {
        let previous = pins
        pins.playNextIDs.removeAll { $0 == episodeID }
        pins.playLastIDs.removeAll { $0 == episodeID }
        guard pins != previous else { return }
        persistPins()
        recompute(reason: "queue.pinConsumed")
    }

    func scheduleRecompute(reason: String) {
        recomputeTask?.cancel()
        recomputeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.recompute(reason: reason)
        }
    }

    func recompute(reason: String) {
        let base = queueService.downloadedQueue(from: subscriptionStore.subscriptions)
        let computed = QueueModel.applyPins(base, pins: pins)
        let computedIDs = computed.map(\.id)
        let compositionChanged = computedIDs != lastPublishedIDs
        let resolvedUpNext: Episode? = {
            guard let current = currentEpisode() else { return computed.first }
            return computed.first { $0.id != current.id }
        }()
        let upNextChanged = resolvedUpNext?.id != upNextEpisode?.id

        if compositionChanged {
            episodes = computed
            lastPublishedIDs = computedIDs
            subscriptionStore.updateLocalQueueSnapshot(entries: computed.map {
                QueueSnapshotEntry(
                    episodeKey: PlaybackPositionStore.key(for: $0),
                    subscriptionID: $0.subscriptionID,
                    episodeTitle: $0.title
                )
            })
            publishBadge()
        }
        if upNextChanged {
            upNextEpisode = resolvedUpNext
        }
        if compositionChanged || upNextChanged || reason != "state.changed" {
            logger.info("queue.upNextRefresh", "Resolved Up Next episode", metadata: [
                "reason": reason,
                "current": currentEpisode()?.title ?? "none",
                "resolved": resolvedUpNext?.title ?? "none",
                "queueCount": "\(computed.count)",
                "compositionChanged": "\(compositionChanged)",
                "upNextChanged": "\(upNextChanged)"
            ])
        }
    }

    private func persistPins() {
        guard let pinsFileURL,
              let data = try? JSONEncoder().encode(SavedQueuePins(
                overrideIDs: pins.playNextIDs,
                demotedIDs: pins.playLastIDs
              ))
        else { return }
        try? LockedDeviceFileAccess.writeDataAtomically(data, to: pinsFileURL)
    }

    private func publishBadge() {
        NotificationService.shared.updateBadge(count: showBadge() ? episodes.count : 0)
    }

    private static func defaultPinsFileURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/queue-pins.json")
    }
}
