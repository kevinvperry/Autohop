import Foundation

// AI CONTEXT — Read-only aggregation boundary for TVDiagnosticsView. It keeps
// diagnostics useful without giving that view mutable access to every runtime
// coordinator.

struct TVDiagnosticsSnapshot: Equatable {
    var syncLabel: String
    var queueRowCount: Int
    var unresolvedQueue: [String]
    var libraryPodcastCount: Int
    var pendingMaterialization: [String]
    var playbackTitle: String
    var playbackState: String
    var playbackPositionSeconds: Int
    var configuredSpeed: Double
    var playerRate: Double
    var pendingHistoryUploads: Int
    var rootState: String
    var appUptimeSeconds: Int
    var memoryFootprintMegabytes: Int?
    var thermalState: String
    var mainThreadHangCount: Int
    var maximumMainThreadHangMilliseconds: Int
    var inactiveWatchdogGapCount: Int
    var topShelf: TVTopShelfHealthDiagnostics
}
