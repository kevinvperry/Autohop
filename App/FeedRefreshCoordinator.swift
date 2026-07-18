//
//  FeedRefreshCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 7 AppState decomposition state owner for feed refresh and Release Radar.
//  It owns the active/joinable cycle, cycle attribution, cancellation state,
//  deferred-feed fairness backlog, feed failure backoff, background-audio cadence,
//  and fingerprinted Release Radar profile cache. Existing AppState entry points
//  remain compatibility façades while refresh bodies use this storage owner.
//
//  The extraction intentionally preserves sequential feed merges, conditional
//  validators, selection caps, resource-pressure reductions, diagnostic labels,
//  autorelease boundaries, and memory checkpoint batch sizes.
//

import Foundation

enum FeedRefreshTrigger: String, Sendable {
    case manualButton
    case foregroundTimer
    case backgroundRefreshTask = "BGAppRefreshTask"
    case backgroundProcessingTask = "BGProcessingTask"
    case relayPush = "AutohopRelay"
}

enum FeedRefreshExecutionContext: String, Sendable {
    case manual
    case foregroundVisible
    case backgroundRefreshTask
    case backgroundAudioAlive
    case backgroundProcessingTask
    case relayPush
}

struct RefreshCycleDiagnostics: Sendable {
    var cycleID: String
    var reason: String
    var trigger: FeedRefreshTrigger
    var executionContext: FeedRefreshExecutionContext
    var startSceneActive: Bool
    var backgroundTaskIdentifier: String?

    func metadata(currentSceneActive: Bool) -> [String: String] {
        [
            "refreshCycleID": cycleID,
            "refreshReason": reason,
            "trigger": trigger.rawValue,
            "executionContext": executionContext.rawValue,
            "startSceneActive": "\(startSceneActive)",
            "currentSceneActive": "\(currentSceneActive)",
            "backgroundTaskIdentifier": backgroundTaskIdentifier ?? "none"
        ]
    }
}

struct DeferredRefreshBacklogEntry {
    var subscriptionID: UUID
    var title: String
    var feedURL: URL
    var firstDeferredAt: Date
    var lastDeferredAt: Date
    var lastDueAt: Date
    var deferralCount: Int
    var state: FeedRefreshWindowState
    var score: Double
}

@MainActor
final class FeedRefreshCoordinator: ObservableObject {
    var activeCycle: Task<Bool, Never>?
    var activeCycleDiagnostics: RefreshCycleDiagnostics?
    var deferredBacklog: [UUID: DeferredRefreshBacklogEntry] = [:]
    var failureBackoffUntil: [UUID: Date] = [:]
    var profileCache: [UUID: ReleaseRadarProfileCacheEntry] = [:]
    var lastBackgroundAudioRefreshAt: Date?

    static let profileCacheTTL: TimeInterval = 15 * 60

    func mergeWarmedProfiles(_ entries: [UUID: ReleaseRadarProfileCacheEntry]) {
        profileCache.merge(entries) { existing, _ in existing }
    }
}

// MARK: - Durable automatic-download workflow

/// Stage 7 owner of persisted auto-download intent orchestration. The intent
/// store remains the source of truth before an asynchronous transfer is started.
/// AppState supplies the current eligibility/attempt adapters during the
/// compatibility period; this workflow serializes drains and never starts the
/// same drain twice.
@MainActor
final class AutoDownloadWorkflow {
    let intentStore: AutoDownloadIntentStore
    private(set) var isDraining = false

    init(intentStore: AutoDownloadIntentStore? = nil) {
        self.intentStore = intentStore ?? AutoDownloadIntentStore()
    }

    func withExclusiveDrain(_ operation: () async -> Void) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        await operation()
    }
}
