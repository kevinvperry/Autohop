import Foundation
import Darwin

// AI CONTEXT — Aggregates read-only subsystem state for Settings & Diagnostics.
// The view does not reach into mutable stores/coordinators directly.
extension TVAppModel {
    var diagnosticsSnapshot: TVDiagnosticsSnapshot {
        let hang = TVHangWatchdog.shared.snapshot()
        return TVDiagnosticsSnapshot(
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
            pendingHistoryUploads: subscriptionStore.pendingListeningHistoryUploadCount(),
            rootState: rootState.diagnosticLabel,
            appUptimeSeconds: max(0, Int(Date().timeIntervalSince(diagnosticStartedAt))),
            memoryFootprintMegabytes: Self.currentMemoryFootprintMegabytes(),
            thermalState: ProcessInfo.processInfo.thermalState.diagnosticLabel,
            mainThreadHangCount: hang.detectedCount,
            maximumMainThreadHangMilliseconds: hang.maximumBlockedMilliseconds,
            inactiveWatchdogGapCount: hang.inactiveGapCount,
            topShelf: topShelfPublisher.healthDiagnostics()
        )
    }

    func refreshTopShelfDiagnostics() async {
        await topShelfPublisher.publishImmediately(candidate: topShelfCandidate(), reason: "manualDiagnosticsRefresh")
    }

    private static func currentMemoryFootprintMegabytes() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}

private extension TVAppModel.RootState {
    var diagnosticLabel: String {
        switch self {
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .empty: return "Setup / Empty"
        }
    }
}

private extension ProcessInfo.ThermalState {
    var diagnosticLabel: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
