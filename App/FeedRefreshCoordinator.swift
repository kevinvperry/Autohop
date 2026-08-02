//
//  FeedRefreshCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 7 AppState decomposition state owner for feed refresh and Release Radar.
//  It owns the active/joinable cycle, cycle attribution, cancellation state,
//  deferred-feed fairness backlog, feed failure backoff, background-audio cadence,
//  and fingerprinted Release Radar profile cache. AppState retains only platform
//  compatibility commands; FeedRefreshCycleWorkflow owns cycle behavior.
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
}

enum FeedRefreshExecutionContext: String, Sendable, Hashable {
    case manual
    case foregroundVisible
    case backgroundRefreshTask
    case backgroundAudioAlive
    case backgroundProcessingTask
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
    struct EfficiencyWindow {
        var startedAt: Date
        var cycles = 0
        var attempted = 0
        var completed = 0
        var materialChanges = 0
        var zeroResultCycles = 0
        var networkHosts = Set<String>()
        var durationMs: Double = 0
    }

    var activeCycle: Task<Bool, Never>?
    var activeCycleDiagnostics: RefreshCycleDiagnostics?
    var deferredBacklog: [UUID: DeferredRefreshBacklogEntry] = [:]
    var failureBackoffUntil: [UUID: Date] = [:]
    /// Runtime host-level protection complements persisted per-subscription
    /// quarantine. Once one feed causes extreme growth, sibling feeds from the
    /// same host cannot compound memory within this process or refresh cycle.
    var parseMemoryHostQuarantineUntil: [String: Date] = [:]
    var profileCache: [UUID: ReleaseRadarProfileCacheEntry] = [:]
    var lastBackgroundAudioRefreshAt: Date?
    /// Last completed due-feed cycle across foreground, BGAppRefresh and active
    /// audio. A background-audio timer may use this to avoid reopening the radio
    /// immediately after another execution context already refreshed due work.
    var lastSuccessfulDueRefreshAt: Date?
    var activeCycleMaterialChangeCount = 0
    var efficiencyWindows: [FeedRefreshExecutionContext: EfficiencyWindow] = [:]

    static let profileCacheTTL: TimeInterval = 15 * 60

    func mergeWarmedProfiles(_ entries: [UUID: ReleaseRadarProfileCacheEntry]) {
        profileCache.merge(entries) { existing, _ in existing }
    }
}

// MARK: - Durable automatic-download workflow

/// Stage 7 owner of persisted auto-download intent orchestration. The intent
/// store remains the source of truth before an asynchronous transfer is started.
/// AutoDownloadIntentWorkflow supplies eligibility and transfer behavior; this
/// state owner serializes drains and never starts the same drain twice.
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
