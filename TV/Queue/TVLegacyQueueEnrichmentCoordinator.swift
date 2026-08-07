import Foundation
import Observation

// AI CONTEXT — Single owner of bounded legacy queue-enrichment tasks and
// retries. Identity matching remains in TVEpisodeResolver; this coordinator
// owns scheduling only and never performs an all-library feed sweep.

@MainActor
@Observable
final class TVLegacyQueueEnrichmentCoordinator {
    internal var tasks: [UUID: Task<Void, Never>] = [:]
    internal var pendingSubscriptionIDs: [UUID] = []
    internal var failedSubscriptionIDs: Set<UUID> = []
    internal var attempts: [UUID: Int] = [:]

    func enqueue(_ subscriptionID: UUID) {
        guard tasks[subscriptionID] == nil,
              !pendingSubscriptionIDs.contains(subscriptionID),
              !failedSubscriptionIDs.contains(subscriptionID) else { return }
        pendingSubscriptionIDs.append(subscriptionID)
    }

    func finish(_ subscriptionID: UUID) {
        tasks[subscriptionID] = nil
    }
}
