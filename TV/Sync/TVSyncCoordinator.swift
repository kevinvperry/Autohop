import Foundation
import Observation
import AutohopCore

// AI CONTEXT — One tvOS owner for CloudKit engine lifetime, foreground
// freshness polling, shared history-prime work, and user-visible sync status.
// It does not build Queue/Library/History display projections.

@MainActor
@Observable
final class TVSyncCoordinator {
    var status: TVSyncStatus = .updating
    internal var engine: CloudSyncEngine?
    var isSceneActive = true

    private let foregroundCoordinator = TVForegroundSyncCoordinator()
    private(set) var lastHistoryPrimeAt = Date.distantPast
    private var historyPrimeTask: Task<Int, Never>?

    func startForegroundPolling(_ operation: @escaping @MainActor () async -> Void) {
        foregroundCoordinator.start(performPoll: operation)
    }

    func sharedRecentHistoryPrime(
        reason: String,
        limit: Int = 100
    ) -> Task<Int, Never>? {
        guard let engine else { return nil }
        if let historyPrimeTask { return historyPrimeTask }
        let task = Task { [weak self] in
            let count = await engine.fetchRecentHistoryNow(reason: reason, limit: limit)
            guard let self else { return count }
            self.lastHistoryPrimeAt = Date()
            self.historyPrimeTask = nil
            return count
        }
        historyPrimeTask = task
        return task
    }

    func shouldPrimeHistory(now: Date = Date(), maximumAge: TimeInterval) -> Bool {
        now.timeIntervalSince(lastHistoryPrimeAt) >= maximumAge
    }

    func flush(reason: String) {
        engine?.flushAndSendDeferredPushes(reason: reason)
    }
}
