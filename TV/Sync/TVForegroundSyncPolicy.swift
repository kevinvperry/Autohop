import Foundation

// AI CONTEXT — tvOS foreground-sync safety-net policy.
//
// CloudKit change notifications and Relay nudges remain the primary fast path.
// This policy owns only the deterministic foreground fallback. The prior code
// slept five minutes and then skipped snapshots younger than five minutes,
// permitting almost ten minutes of stale Up Next state while its comment
// promised 45 seconds. A 60-second poll with a 90-second maximum snapshot age
// bounds ordinary foreground convergence without issuing a network request on
// every tick. The pure function is isolated for tvOS regression testing.
enum TVForegroundSyncPolicy {
    static let pollInterval: TimeInterval = 60
    static let maximumSnapshotAge: TimeInterval = 90

    static func shouldFetch(snapshotUpdatedAt: Date?, now: Date = Date()) -> Bool {
        guard let snapshotUpdatedAt else { return true }
        return now.timeIntervalSince(snapshotUpdatedAt) >= maximumSnapshotAge
    }
}

/// Owns the lifetime and cancellation of the foreground safety timer. The
/// actual CloudKit operations remain injected by TVAppModel, allowing this
/// first decomposition step to move scheduling responsibility out of the
/// composition root without duplicating sync state or changing iPhone sync.
@MainActor
final class TVForegroundSyncCoordinator {
    private var pollingTask: Task<Void, Never>?

    func start(performPoll: @escaping @MainActor () async -> Void) {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TVForegroundSyncPolicy.pollInterval))
                guard !Task.isCancelled else { return }
                await performPoll()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
