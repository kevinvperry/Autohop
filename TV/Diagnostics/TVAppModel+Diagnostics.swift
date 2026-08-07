import Foundation

// AI CONTEXT — Aggregates read-only subsystem state for Settings & Diagnostics.
// The view does not reach into mutable stores/coordinators directly.
extension TVAppModel {
    var diagnosticsSnapshot: TVDiagnosticsSnapshot {
        TVDiagnosticsSnapshot(
            syncLabel: syncCoordinator.status.label,
            queueRowCount: queueModel.rows.count,
            unresolvedQueue: unresolvedQueueDiagnostics,
            libraryPodcastCount: libraryModel.tiles.count,
            pendingMaterialization: pendingMaterializationDiagnostics,
            playbackTitle: playbackModel.currentEpisode?.title ?? "None",
            playbackState: String(describing: playbackModel.playbackState),
            playbackPositionSeconds: Int(playbackModel.currentTime),
            configuredSpeed: playbackModel.currentSpeed,
            playerRate: Double(playbackModel.avPlayer?.rate ?? 0),
            pendingHistoryUploads: subscriptionStore.pendingListeningHistoryUploadCount()
        )
    }
}
