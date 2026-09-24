// AI CONTEXT — Diagnostic repairs, 20 September 2026.
// Download stats await the durable snapshot checkpoint; callers must await completion
// before reporting settlement. Other lifecycle save contracts remain synchronous.
// Evidence and validation limits: Docs/DIAGNOSTIC_REPAIRS_2026-09-20.md.

import Combine
import Foundation

// AI CONTEXT — App/HistoryStatsCoordinator.swift
//
// PURPOSE / OWNERSHIP:
// Stage 3 owner of iOS listening-history and listening-Stats orchestration.
// It owns rendered-playback accumulation, terminal history outcomes, derived history
// groups/counts, discrete Stats credits, lifecycle persistence checkpoints, and
// the temporary CloudKit remote-apply adapters. The underlying persistence
// formats remain owned by ListeningHistoryStore and ListeningStatsStore.
//
// DEPENDENCIES:
// Injected history/stats stores and SubscriptionStore metadata lookup.
// PlaybackCheckpointWorkflow orders local durability before SyncCoordinator
// flushes; this owner never controls CloudSyncEngine lifecycle.
//
// CONCURRENCY / EVENTS:
// MainActor-only. `objectWillChange` publishes only projection changes from
// `refreshHistoryProjection`; SwiftUI observes this owner directly. Playback
// backends provide explicit rendered intervals; UI position ticks are not an
// accounting source.
//
// PERSISTENCE / SYNC INVARIANTS:
// - History and Stats receive positive wall-clock duration from backend-confirmed
//   rendered intervals. Position changes, seeks and trimmed frames are separate.
// - History progress is buffered by ListeningHistoryStore at its existing
//   30-second cadence; Stats retains its existing throttles.
// - Terminal marks flush buffered history before changing completion status.
// - Lifecycle checkpoints save history, then Stats/sync rows, then request the
//   CloudKit deferred-push flush.
// - Remote history uses a monotonic outcome/listening merge; remote Stats remain
//   additive per-device partitions through the existing stores.
// - This coordinator must not control playback, queue, downloads, archive rules,
//   feed refresh, CloudKit lifecycle, or SwiftUI navigation.
@MainActor
final class HistoryStatsCoordinator: ObservableObject {
    let historyStore: ListeningHistoryStore
    let statsStore: ListeningStatsStore

    @Published private(set) var historyGroups: [(String, [ListeningHistoryEntry])] = []
    @Published private(set) var completedEpisodeCount = 0

    private let subscriptionStore: SubscriptionStore
    private let playbackPositionStore: PlaybackPositionStore?
    /// Invoked only after a remote history merge changes navigation state and is matched to a
    /// concrete local episode. AppCompositionRoot uses this narrow seam to
    /// move an already-open, PAUSED iPhone player to the newly accepted TV
    /// position. An actively playing phone remains authoritative and is never
    /// interrupted by a remote progress update.
    var onRemotePlaybackPositionAdopted: ((Episode, TimeInterval, ListeningHistoryEntry) -> Void)?

    init(
        historyStore: ListeningHistoryStore,
        statsStore: ListeningStatsStore,
        subscriptionStore: SubscriptionStore,
        playbackPositionStore: PlaybackPositionStore? = nil
    ) {
        self.historyStore = historyStore
        self.statsStore = statsStore
        self.subscriptionStore = subscriptionStore
        self.playbackPositionStore = playbackPositionStore
        refreshHistoryProjection()
    }

    func attachSyncDatabase(_ database: AutohopDatabase?) {
        historyStore.syncDatabase = database
        statsStore.syncDatabase = database
    }

    func applyRemoteHistory(_ entry: ListeningHistoryEntry) {
        if let navigationUpdate = historyStore.applyRemote(entry) {
            applyRemotePlaybackPosition(navigationUpdate)
        } else {
            AppLogger.shared.info("sync.historyPositionIgnored", "Remote listening position did not win local history merge", metadata: [
                "id": entry.id,
                "position": String(format: "%.1f", entry.lastPositionSeconds),
                "lastListenedAt": ISO8601DateFormatter().string(from: entry.lastListenedAt)
            ], alwaysPersist: true)
        }
        refreshHistoryProjection()
    }

    /// iPhone resume playback is owned by PlaybackPositionStore, while the
    /// cross-device transport is ListeningHistoryEntry. An accepted remote
    /// history row must update both stores; otherwise History displays the TV
    /// session but playback still resumes from the phone's stale local cache.
    private func applyRemotePlaybackPosition(_ entry: ListeningHistoryEntry) {
        guard let playbackPositionStore else { return }
        guard let episode = localEpisode(matching: entry) else {
            AppLogger.shared.warning("sync.historyPositionUnresolved", "Received history but could not match it to a local episode", metadata: [
                "id": entry.id,
                "episodeID": entry.episodeID.uuidString,
                "subscriptionID": entry.subscriptionID.uuidString,
                "title": entry.episodeTitle,
                "streamHost": entry.streamURL?.host ?? "unknown"
            ], alwaysPersist: true)
            return
        }

        let position = PlaybackPositionStore.normalizedResumeTime(
            entry.lastPositionSeconds,
            duration: episode.durationSeconds ?? entry.durationSeconds
        )
        if entry.status == .listened, position > 0 {
            playbackPositionStore.save(
                episode: episode,
                timeSeconds: position,
                updatedAt: entry.lastListenedAt
            )
            onRemotePlaybackPositionAdopted?(episode, position, entry)
        } else {
            playbackPositionStore.clear(for: episode)
        }
        AppLogger.shared.info("sync.historyPositionApplied", "Applied remote listening position to iPhone resume store", metadata: [
            "id": entry.id,
            "localEpisodeID": episode.id.uuidString,
            "localKey": PlaybackPositionStore.key(for: episode),
            "position": String(format: "%.1f", position),
            "status": String(describing: entry.status)
        ], alwaysPersist: true)
    }

    /// Match strongly by the phone's current catalogue identity, then by the
    /// enclosure URL carried in the synced history projection. Title-only
    /// matching is deliberately excluded because recurring shows often reuse
    /// titles and a false match would move an unrelated episode's position.
    private func localEpisode(matching entry: ListeningHistoryEntry) -> Episode? {
        if let subscription = subscriptionStore.subscription(id: entry.subscriptionID),
           let exact = subscription.episodes.first(where: {
               $0.id == entry.episodeID || PlaybackPositionStore.key(for: $0) == entry.id
           }) {
            return exact
        }
        guard let streamURL = entry.streamURL else { return nil }
        let matches = subscriptionStore.subscriptions
            .flatMap(\.episodes)
            .filter { $0.audioURL == streamURL }
        return matches.count == 1 ? matches[0] : nil
    }

    func reloadRemoteStats() {
        statsStore.reloadRemoteStats()
    }

    func recordPlaybackInterval(
        _ interval: PlaybackAccountingInterval,
        episode: Episode?,
        subscription: Subscription?
    ) {
        guard let episode, let subscription,
              interval.wallClockSeconds.isFinite,
              interval.wallClockSeconds > 0,
              interval.mediaHeardSeconds.isFinite,
              interval.mediaHeardSeconds > 0,
              interval.positionSeconds.isFinite,
              interval.positionSeconds >= 0,
              interval.playbackSpeed.isFinite,
              interval.playbackSpeed > 0 else { return }

        historyStore.recordProgress(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSeconds: interval.wallClockSeconds,
            positionSeconds: interval.positionSeconds,
            durationSeconds: episode.durationSeconds
        )
        statsStore.addListeningTime(
            interval.wallClockSeconds,
            speed: interval.playbackSpeed,
            subscriptionID: subscription.id,
            showTitle: subscription.title,
            feedURL: subscription.feedURL,
            endedAt: interval.endedAt
        )
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
            showTitle: subscription.title,
            feedURL: subscription.feedURL
        )
    }

    func recordManualSkipForward(_ seconds: TimeInterval, subscriptionID: UUID?) {
        let subscription = subscriptionID.flatMap { subscriptionStore.subscription(id: $0) }
        statsStore.addManualSkipForward(
            seconds,
            subscriptionID: subscriptionID,
            feedURL: subscription?.feedURL,
            showTitle: subscription?.title
        )
    }

    func recordAutoSkip(_ seconds: TimeInterval, subscriptionID: UUID?) {
        let subscription = subscriptionID.flatMap { subscriptionStore.subscription(id: $0) }
        statsStore.addAutoSkip(
            seconds,
            subscriptionID: subscriptionID,
            feedURL: subscription?.feedURL,
            showTitle: subscription?.title
        )
    }

    func recordTrimSilenceSaved(_ seconds: TimeInterval, subscriptionID: UUID?) {
        let subscription = subscriptionID.flatMap { subscriptionStore.subscription(id: $0) }
        statsStore.addTrimSilenceSaved(
            seconds,
            subscriptionID: subscriptionID,
            feedURL: subscription?.feedURL,
            showTitle: subscription?.title
        )
    }

    func recordEpisodeStarted(subscriptionID: UUID, showTitle: String) {
        statsStore.recordEpisodeStarted(
            subscriptionID: subscriptionID,
            showTitle: showTitle,
            feedURL: subscriptionStore.subscription(id: subscriptionID)?.feedURL
        )
    }

    /// Creates the zero-credit, fresh-recency history row used by other devices'
    /// Continue Listening projection, then requests the existing immediate sync
    /// checkpoint. A minimum position of one second preserves the legacy TV
    /// eligibility contract.
    func recordPlaybackStart(
        episode: Episode,
        subscription: Subscription,
        position: TimeInterval
    ) {
        historyStore.recordProgress(
            episode: episode,
            podcastTitle: subscription.title,
            artworkURL: episode.artworkURL ?? subscription.artworkURL,
            listenedSeconds: 0,
            positionSeconds: max(position, 1),
            durationSeconds: episode.durationSeconds
        )
    }

    func recordDownload(bytes: Int64) async {
        await statsStore.recordDownloadAndSave(bytes: bytes)
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
        statsStore.recordEpisodeOutcome(
            episode: episode,
            subscription: subscription,
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
