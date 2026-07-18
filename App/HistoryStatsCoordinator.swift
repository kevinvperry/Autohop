import Combine
import Foundation

// AI CONTEXT — App/HistoryStatsCoordinator.swift
//
// PURPOSE / OWNERSHIP:
// Stage 3 owner of iOS listening-history and listening-Stats orchestration.
// It owns playback-tick accumulation, terminal history outcomes, derived history
// groups/counts, discrete Stats credits, lifecycle persistence checkpoints, and
// the temporary CloudKit remote-apply adapters. The underlying persistence
// formats remain owned by ListeningHistoryStore and ListeningStatsStore.
//
// DEPENDENCIES:
// Injected history/stats stores and SubscriptionStore metadata lookup. A sync
// flush is supplied as a closure at checkpoint time so this coordinator never
// owns CloudSyncEngine or creates a dependency cycle.
//
// CONCURRENCY / EVENTS:
// MainActor-only. `objectWillChange` publishes only projection changes from
// `refreshHistoryProjection`; AppState forwards it during the compatibility
// phase. Tick state is episode-scoped and reset whenever playback is not active
// or the loaded episode changes.
//
// PERSISTENCE / SYNC INVARIANTS:
// - Valid listening deltas are >0 and <=3 seconds, matching legacy AppState.
// - History progress is buffered by ListeningHistoryStore at its existing
//   30-second cadence; Stats retains its existing throttles.
// - Terminal marks flush buffered history before changing completion status.
// - Lifecycle checkpoints save history, then Stats/sync rows, then request the
//   CloudKit deferred-push flush.
// - Remote history remains whole-entry LWW; remote Stats remain additive
//   per-device partitions through the existing stores.
// - This coordinator must not control playback, queue, downloads, archive rules,
//   feed refresh, CloudKit lifecycle, or SwiftUI navigation.
@MainActor
final class HistoryStatsCoordinator: ObservableObject {
    let historyStore: ListeningHistoryStore
    let statsStore: ListeningStatsStore

    @Published private(set) var historyGroups: [(String, [ListeningHistoryEntry])] = []
    @Published private(set) var completedEpisodeCount = 0

    private let subscriptionStore: SubscriptionStore
    private var trackingEpisodeID: UUID?
    private var trackingLastTime: TimeInterval?

    init(
        historyStore: ListeningHistoryStore,
        statsStore: ListeningStatsStore,
        subscriptionStore: SubscriptionStore
    ) {
        self.historyStore = historyStore
        self.statsStore = statsStore
        self.subscriptionStore = subscriptionStore
        refreshHistoryProjection()
    }

    func attachSyncDatabase(_ database: AutohopDatabase?) {
        historyStore.syncDatabase = database
        statsStore.syncDatabase = database
    }

    func applyRemoteHistory(_ entry: ListeningHistoryEntry) {
        historyStore.applyRemote(entry)
        refreshHistoryProjection()
    }

    func reloadRemoteStats() {
        statsStore.reloadRemoteStats()
    }

    func recordPlaybackProgress(
        at time: TimeInterval,
        isPlaying: Bool,
        episode: Episode?,
        subscription: Subscription?
    ) {
        guard isPlaying, let episode, let subscription else {
            resetPlaybackTracking()
            return
        }

        guard trackingEpisodeID == episode.id, let lastTime = trackingLastTime else {
            trackingEpisodeID = episode.id
            trackingLastTime = time
            return
        }

        trackingLastTime = time
        let delta = time - lastTime
        guard delta > 0, delta <= 3 else { return }

        historyStore.recordProgress(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSeconds: delta,
            positionSeconds: time,
            durationSeconds: episode.durationSeconds
        )
    }

    func beginPlaybackTracking(episodeID: UUID, at time: TimeInterval) {
        trackingEpisodeID = episodeID
        trackingLastTime = time
    }

    func resetPlaybackTracking() {
        trackingEpisodeID = nil
        trackingLastTime = nil
    }

    func recordListeningTime(
        _ seconds: TimeInterval,
        speed: Double,
        subscription: Subscription
    ) {
        statsStore.addListeningTime(
            seconds,
            speed: speed,
            subscriptionID: subscription.id,
            showTitle: subscription.title
        )
    }

    func recordManualSkipForward(_ seconds: TimeInterval, subscriptionID: UUID?) {
        statsStore.addManualSkipForward(seconds, subscriptionID: subscriptionID)
    }

    func recordAutoSkip(_ seconds: TimeInterval, subscriptionID: UUID?) {
        statsStore.addAutoSkip(seconds, subscriptionID: subscriptionID)
    }

    func recordTrimSilenceSaved(_ seconds: TimeInterval, subscriptionID: UUID?) {
        statsStore.addTrimSilenceSaved(seconds, subscriptionID: subscriptionID)
    }

    func recordEpisodeStarted(subscriptionID: UUID, showTitle: String) {
        statsStore.recordEpisodeStarted(subscriptionID: subscriptionID, showTitle: showTitle)
    }

    /// Creates the zero-credit, fresh-recency history row used by other devices'
    /// Continue Listening projection, then requests the existing immediate sync
    /// checkpoint. A minimum position of one second preserves the legacy TV
    /// eligibility contract.
    func recordPlaybackStart(
        episode: Episode,
        subscription: Subscription,
        position: TimeInterval,
        requestSyncFlush: (String) -> Void
    ) {
        historyStore.recordProgress(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSeconds: 0,
            positionSeconds: max(position, 1),
            durationSeconds: episode.durationSeconds
        )
        requestSyncFlush("playback.start")
    }

    func recordEpisodeCompleted(subscriptionID: UUID) {
        statsStore.recordEpisodeCompleted(subscriptionID: subscriptionID)
    }

    func recordDownload(bytes: Int64) {
        statsStore.recordDownload(bytes: bytes)
    }

    func mark(
        _ episode: Episode,
        status: ListeningHistoryStatus,
        completionKind: CompletionKind,
        positionSeconds: TimeInterval? = nil
    ) {
        let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
        historyStore.mark(
            episode: episode,
            podcastTitle: subscription?.title ?? episode.author ?? "Podcast",
            artworkURL: episode.artworkURL ?? subscription?.artworkURL,
            status: status,
            completionKind: completionKind,
            positionSeconds: positionSeconds
        )
        refreshHistoryProjection()
    }

    func refreshHistoryProjection(calendar: Calendar = .current) {
        let commenced = historyStore.entries.filter {
            $0.listenedSeconds >= 60 || $0.lastPositionSeconds >= 60
        }
        let grouped = Dictionary(grouping: commenced) { entry -> String in
            if calendar.isDateInToday(entry.lastListenedAt) { return "Today" }
            if calendar.isDateInYesterday(entry.lastListenedAt) { return "Yesterday" }
            return entry.lastListenedAt.formatted(date: .abbreviated, time: .omitted)
        }
        historyGroups = grouped
            .map { ($0.key, $0.value.sorted { $0.lastListenedAt > $1.lastListenedAt }) }
            .sorted {
                ($0.1.first?.lastListenedAt ?? .distantPast)
                    > ($1.1.first?.lastListenedAt ?? .distantPast)
            }
        completedEpisodeCount = commenced.filter {
            $0.status == .played || $0.status == .archived
        }.count
    }

    func checkpoint(reason: String, requestSyncFlush: (String) -> Void) {
        prepareLocalCheckpoint()
        requestSyncFlush(reason)
    }

    func prepareLocalCheckpoint() {
        historyStore.save()
        statsStore.save()
    }

    func saveHistory() {
        historyStore.save()
    }

    func saveStats() {
        statsStore.save()
    }

}
