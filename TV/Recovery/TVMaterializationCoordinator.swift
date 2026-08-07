import Foundation
import Observation
import AutohopCore

// AI CONTEXT — Owns the mutable task/retry state for bounded tvOS
// subscription materialisation. TVAppModel currently supplies the proven
// workflow callbacks while the coordinator prevents task ownership leaking
// into Library or Queue models.

@MainActor
@Observable
final class TVMaterializationCoordinator {
    let survivalKitStore: SurvivalKitStore
    let feedLoader: EpisodeFeedLoader
    internal var retryTasks: [UUID: Task<Void, Never>] = [:]
    internal var attempts: [UUID: Int] = [:]

    init(survivalKitStore: SurvivalKitStore, feedLoader: EpisodeFeedLoader) {
        self.survivalKitStore = survivalKitStore
        self.feedLoader = feedLoader
    }

    func cancelRetry(subscriptionID: UUID) {
        retryTasks[subscriptionID]?.cancel()
        retryTasks[subscriptionID] = nil
        attempts[subscriptionID] = nil
    }
}

