import Foundation

// AI CONTEXT — App/PlaybackCheckpointWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Ordered durability boundary for playback position, Listening History, Stats,
// and their deferred CloudKit sync rows. It centralizes pause/sleep/lifecycle
// checkpoints so every caller preserves local-save-before-sync ordering.
//
// INVARIANTS:
// - Current playback position is written before history/Stats persistence.
// - `checkpoint(reason:)` lets HistoryStatsCoordinator flush pending local rows
//   before SyncCoordinator scans and pushes deferred changes.
// - `prepareLocalCheckpoint()` performs only the local phase because the scene
//   adapter must first await SubscriptionStore's pending SQLite transaction
//   before explicitly requesting the sync scan.

@MainActor
final class PlaybackCheckpointWorkflow {
    private let mediaWorkflow: PlaybackMediaWorkflow
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let syncCoordinator: SyncCoordinator

    init(
        mediaWorkflow: PlaybackMediaWorkflow,
        historyStatsCoordinator: HistoryStatsCoordinator,
        syncCoordinator: SyncCoordinator
    ) {
        self.mediaWorkflow = mediaWorkflow
        self.historyStatsCoordinator = historyStatsCoordinator
        self.syncCoordinator = syncCoordinator
    }

    func persistLocal() {
        mediaWorkflow.saveCurrentPosition()
        historyStatsCoordinator.saveHistory()
    }

    func checkpoint(reason: String) {
        mediaWorkflow.saveCurrentPosition()
        historyStatsCoordinator.checkpoint(reason: reason) {
            [weak syncCoordinator] checkpointReason in
            syncCoordinator?.flushDeferredPushes(reason: checkpointReason)
        }
    }

    func prepareLocalCheckpoint() {
        mediaWorkflow.saveCurrentPosition()
        historyStatsCoordinator.prepareLocalCheckpoint()
    }
}
