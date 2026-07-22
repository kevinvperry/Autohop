import Foundation
import Network

// AI CONTEXT — App/FeedRefreshCycleWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Exclusive multi-feed refresh-cycle state machine. It owns manual, timed,
// background-audio, BGAppRefresh, BGProcessing, and Relay-targeted cycle
// requests; active-cycle join/follow-up rules; expiration cancellation; adaptive
// device-pressure budgets; Release Radar selection; deferred-feed fairness;
// sequential item execution; memory batch boundaries; background rescheduling;
// queue refresh; Auto Archive follow-up; and cycle diagnostics.
//
// CONCURRENCY / MEMORY:
// FeedRefreshCoordinator stores the sole active Task and diagnostics. Feed
// merges remain sequential. Every 16 feeds, the workflow logs physical
// footprint and yields; large manual cycles use smaller batches, trim transient
// artwork allocations, and add a short parser/download-settlement drain pause.
//
// INVARIANTS:
// - A BG task joins existing work instead of reporting premature completion.
// - Relay-targeted work may request one follow-up after a joined capped cycle.
// - BG expiration detaches when foreground or active audio still owns the cycle.
// - Backoff, inactive-feed exclusion, protected Radar slots, urgent cap bypass,
//   and oldest-deferred fairness remain explicit.
// - Foreground state is injected by AppRuntimeWorkflow; this state machine does
//   not read UIApplication directly and can be exercised deterministically.
// - AppState exposes entry commands but contains no refresh-cycle internals.
// - While an OS BGTask diagnostic scope is active, selection/attempt/completion
//   counters are reported to BackgroundWakeMonitor; the monitor is observational
//   only and cannot alter selection, cancellation, or rescheduling behavior.
// - BGAppRefresh may request one adaptive second batch after its eight-feed base
//   batch. The follow-up is limited to two feeds while unplugged and up to four
//   on external power, and is rejected under low power, thermal/network pressure,
//   large active downloads, or insufficient deadline.
// - OS BGTask feed mutations are one SubscriptionStore notification transaction.
//   Nested per-feed transactions are depth-counted by the store; queue, widget,
//   sync, and view observers receive the settled batch rather than every setter.

@MainActor
final class FeedRefreshCycleWorkflow {
    struct Policy {
        let defaultEpisodeLimit: Int
        let backgroundRefreshLimit: Int
        let backgroundProtectedMinimum: Int
        let backgroundProtectedStates: Set<FeedRefreshWindowState>
        let foregroundLimit: Int
        let backgroundAudioLimit: Int
        let backgroundAudioHardLimit: Int
        let backgroundAudioMinimumInterval: TimeInterval
        let foregroundCapBypassStates: Set<FeedRefreshWindowState>
        let backgroundAudioCapBypassStates: Set<FeedRefreshWindowState>
    }

    private let coordinator: FeedRefreshCoordinator
    private let subscriptionStore: SubscriptionStore
    private let downloadCoordinator: DownloadCoordinator
    private let playback: PlaybackCoordinator
    private let releaseRadar: ReleaseRadarWorkflow
    private let itemWorkflow: FeedRefreshItemWorkflow
    private let queueCoordinator: QueueCoordinator
    private let autoArchiveCoordinator: AutoArchiveCoordinator
    private let logger: AppLogger
    private let policy: Policy
    private let sceneActive: () -> Bool
    private let appForeground: () -> Bool
    private let runtimeWorkflow: AppRuntimeWorkflow

    init(
        coordinator: FeedRefreshCoordinator,
        subscriptionStore: SubscriptionStore,
        downloadCoordinator: DownloadCoordinator,
        playback: PlaybackCoordinator,
        releaseRadar: ReleaseRadarWorkflow,
        itemWorkflow: FeedRefreshItemWorkflow,
        queueCoordinator: QueueCoordinator,
        autoArchiveCoordinator: AutoArchiveCoordinator,
        logger: AppLogger,
        policy: Policy,
        sceneActive: @escaping () -> Bool,
        appForeground: @escaping () -> Bool,
        runtimeWorkflow: AppRuntimeWorkflow
    ) {
        self.coordinator = coordinator
        self.subscriptionStore = subscriptionStore
        self.downloadCoordinator = downloadCoordinator
        self.playback = playback
        self.releaseRadar = releaseRadar
        self.itemWorkflow = itemWorkflow
        self.queueCoordinator = queueCoordinator
        self.autoArchiveCoordinator = autoArchiveCoordinator
        self.logger = logger
        self.policy = policy
        self.sceneActive = sceneActive
        self.appForeground = appForeground
        self.runtimeWorkflow = runtimeWorkflow
    }

    func refreshAll(includeBackoffFeeds: Bool) async {
        _ = await refresh(
            reason: "manual",
            trigger: .manualButton,
            executionContext: .manual,
            maxSubscriptions: nil,
            includeBackoffFeeds: includeBackoffFeeds,
            onlyDueFeeds: false
        )
    }

    @discardableResult
    func refreshDue() async -> Bool {
        let foreground = isAppForeground
        let budget = foreground ? nil : backgroundAudioBudget()
        if !foreground {
            let now = runtimeWorkflow.now
            if let last = coordinator.lastBackgroundAudioRefreshAt,
               now.timeIntervalSince(last)
                    < policy.backgroundAudioMinimumInterval {
                return false
            }
            coordinator.lastBackgroundAudioRefreshAt = now
            if let lastSuccess = coordinator.lastSuccessfulDueRefreshAt,
               now.timeIntervalSince(lastSuccess) < 90 {
                logger.info(
                    "feed.backgroundAudioSuppressed",
                    "Skipped background-audio network cycle after a recent successful refresh",
                    metadata: [
                        "secondsSinceSuccessfulRefresh": String(
                            format: "%.1f",
                            now.timeIntervalSince(lastSuccess)
                        ),
                        "minimumSeparationSeconds": "90",
                        "executionContext": FeedRefreshExecutionContext
                            .backgroundAudioAlive.rawValue
                    ]
                )
                return false
            }
        }
        return await refresh(
            reason: "timed-due",
            trigger: .foregroundTimer,
            executionContext: foreground
                ? .foregroundVisible
                : .backgroundAudioAlive,
            maxSubscriptions: foreground
                ? policy.foregroundLimit
                : budget?.routineLimit,
            maxTotalSelections: foreground ? nil : budget?.hardLimit,
            capBypassStates: foreground
                ? policy.foregroundCapBypassStates
                : policy.backgroundAudioCapBypassStates,
            includeBackoffFeeds: false,
            onlyDueFeeds: true
        )
    }

    @discardableResult
    func refreshForBackground(taskIdentifier: String) async -> Bool {
        logger.info(
            "background.refreshRequested",
            "Background app refresh requested feed refresh cycle",
            metadata: [
                "identifier": taskIdentifier,
                "sceneActive": "\(sceneActive())",
                "trigger":
                    FeedRefreshTrigger.backgroundRefreshTask.rawValue,
                "executionContext":
                    FeedRefreshExecutionContext.backgroundRefreshTask.rawValue
            ]
        )
        return await refresh(
            reason: "background",
            trigger: .backgroundRefreshTask,
            executionContext: .backgroundRefreshTask,
            maxSubscriptions: policy.backgroundRefreshLimit,
            protectedStates: policy.backgroundProtectedStates,
            minimumProtectedSelections:
                policy.backgroundProtectedMinimum,
            includeBackoffFeeds: false,
            onlyDueFeeds: true,
            joinActiveCycle: true,
            backgroundTaskIdentifier: taskIdentifier
        )
    }

    /// Attempts one small follow-up batch after the normal BGAppRefresh selection.
    /// Recomputing due candidates naturally excludes feeds completed by batch one
    /// and lets deferred-fairness scores choose the oldest remaining work.
    @discardableResult
    func refreshAdditionalForBackground(
        taskIdentifier: String,
        cooperativeSecondsRemaining: TimeInterval
    ) async -> Bool {
        let capacity = additionalBackgroundCapacity(
            cooperativeSecondsRemaining: cooperativeSecondsRemaining
        )
        guard capacity > 0 else { return false }
        logger.info(
            "background.additionalBatch",
            "Starting opportunistic BGAppRefresh follow-up batch",
            metadata: [
                "identifier": taskIdentifier,
                "capacity": "\(capacity)",
                "cooperativeSecondsRemaining": String(
                    format: "%.1f",
                    cooperativeSecondsRemaining
                )
            ]
        )
        return await refresh(
            reason: "background.additional",
            trigger: .backgroundRefreshTask,
            executionContext: .backgroundRefreshTask,
            maxSubscriptions: capacity,
            protectedStates: policy.backgroundProtectedStates,
            minimumProtectedSelections: min(
                capacity,
                policy.backgroundProtectedMinimum
            ),
            includeBackoffFeeds: false,
            onlyDueFeeds: true,
            joinActiveCycle: false,
            backgroundTaskIdentifier: taskIdentifier
        )
    }

    @discardableResult
    func refreshForProcessing(taskIdentifier: String) async -> Bool {
        logger.info(
            "background.processingRequested",
            "Background processing requested feed catch-up",
            metadata: [
                "identifier": taskIdentifier,
                "sceneActive": "\(sceneActive())",
                "trigger":
                    FeedRefreshTrigger.backgroundProcessingTask.rawValue,
                "executionContext":
                    FeedRefreshExecutionContext
                        .backgroundProcessingTask.rawValue
            ]
        )
        return await refresh(
            reason: "processing",
            trigger: .backgroundProcessingTask,
            executionContext: .backgroundProcessingTask,
            maxSubscriptions: nil,
            includeBackoffFeeds: true,
            onlyDueFeeds: true,
            joinActiveCycle: true,
            backgroundTaskIdentifier: taskIdentifier
        )
    }

    func cancelIfBackgroundOnly(reason: String) {
        if isAppForeground || playback.isPlaying {
            logger.info(
                "feed.refreshAll.expirationDetached",
                "BGTask expired but a live foreground/audio context owns the refresh cycle — detaching, not cancelling",
                metadata: [
                    "reason": reason,
                    "appForeground": "\(isAppForeground)",
                    "isPlaying": "\(playback.isPlaying)",
                    "activeCycleID":
                        coordinator.activeCycleDiagnostics?.cycleID ?? "none",
                    "activeTrigger":
                        coordinator.activeCycleDiagnostics?.trigger.rawValue
                            ?? "none",
                    "activeExecutionContext":
                        coordinator.activeCycleDiagnostics?
                            .executionContext.rawValue ?? "none"
                ]
            )
            return
        }
        cancel(reason: reason)
    }

    func cancel(reason: String) {
        guard let activeCycle = coordinator.activeCycle else {
            logger.info(
                "feed.refreshAll.cancelRequestIgnored",
                "No refresh cycle was active",
                metadata: ["reason": reason]
            )
            return
        }
        logger.warning(
            "feed.refreshAll.cancelRequested",
            "Refresh cycle cancellation requested",
            metadata: [
                "reason": reason,
                "backlogCount": "\(coordinator.deferredBacklog.count)",
                "sceneActive": "\(sceneActive())",
                "activeCycleID":
                    coordinator.activeCycleDiagnostics?.cycleID ?? "unknown",
                "activeReason":
                    coordinator.activeCycleDiagnostics?.reason ?? "unknown",
                "activeTrigger":
                    coordinator.activeCycleDiagnostics?.trigger.rawValue
                        ?? "unknown",
                "activeExecutionContext":
                    coordinator.activeCycleDiagnostics?
                        .executionContext.rawValue ?? "unknown"
            ]
        )
        activeCycle.cancel()
    }

    @discardableResult
    func refresh(
        reason: String,
        trigger: FeedRefreshTrigger,
        executionContext: FeedRefreshExecutionContext,
        maxSubscriptions: Int?,
        maxTotalSelections: Int? = nil,
        capBypassStates: Set<FeedRefreshWindowState> = [],
        protectedStates: Set<FeedRefreshWindowState> = [],
        minimumProtectedSelections: Int = 0,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool,
        joinActiveCycle: Bool = false,
        backgroundTaskIdentifier: String? = nil,
        targetSubscriptionIDs: Set<UUID>? = nil,
        refreshAfterJoiningActiveCycle: Bool = false
    ) async -> Bool {
        if let active = coordinator.activeCycle {
            guard joinActiveCycle else {
                logger.info(
                    "feed.refreshAll.skip",
                    "Refresh-all skipped because another cycle is already running",
                    metadata: [
                        "count":
                            "\(subscriptionStore.subscriptions.count)",
                        "reason": reason,
                        "trigger": trigger.rawValue,
                        "executionContext": executionContext.rawValue,
                        "sceneActive": "\(sceneActive())",
                        "activeCycleID":
                            coordinator.activeCycleDiagnostics?.cycleID
                                ?? "unknown",
                        "activeReason":
                            coordinator.activeCycleDiagnostics?.reason
                                ?? "unknown",
                        "activeTrigger":
                            coordinator.activeCycleDiagnostics?.trigger
                                .rawValue ?? "unknown",
                        "activeExecutionContext":
                            coordinator.activeCycleDiagnostics?
                                .executionContext.rawValue ?? "unknown"
                    ]
                )
                return false
            }
            logger.info(
                "feed.refreshAll.join",
                "Joining refresh cycle already in flight",
                metadata: [
                    "reason": reason,
                    "trigger": trigger.rawValue,
                    "executionContext": executionContext.rawValue,
                    "sceneActive": "\(sceneActive())",
                    "backgroundTaskIdentifier":
                        backgroundTaskIdentifier ?? "none",
                    "joinedRefreshCycleID":
                        coordinator.activeCycleDiagnostics?.cycleID
                            ?? "unknown",
                    "joinedReason":
                        coordinator.activeCycleDiagnostics?.reason
                            ?? "unknown",
                    "joinedTrigger":
                        coordinator.activeCycleDiagnostics?.trigger.rawValue
                            ?? "unknown",
                    "joinedExecutionContext":
                        coordinator.activeCycleDiagnostics?
                            .executionContext.rawValue ?? "unknown"
                ]
            )
            let joinedResult = await active.value
            guard refreshAfterJoiningActiveCycle else { return joinedResult }
            while coordinator.activeCycle != nil { await Task.yield() }
            return await refresh(
                reason: reason,
                trigger: trigger,
                executionContext: executionContext,
                maxSubscriptions: maxSubscriptions,
                maxTotalSelections: maxTotalSelections,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                includeBackoffFeeds: includeBackoffFeeds,
                onlyDueFeeds: onlyDueFeeds,
                joinActiveCycle: false,
                backgroundTaskIdentifier: backgroundTaskIdentifier,
                targetSubscriptionIDs: targetSubscriptionIDs,
                refreshAfterJoiningActiveCycle: false
            )
        }

        let diagnostics = RefreshCycleDiagnostics(
            cycleID: UUID().uuidString,
            reason: reason,
            trigger: trigger,
            executionContext: executionContext,
            startSceneActive: sceneActive(),
            backgroundTaskIdentifier: backgroundTaskIdentifier
        )
        let cycle = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.perform(
                diagnostics: diagnostics,
                maxSubscriptions: maxSubscriptions,
                maxTotalSelections: maxTotalSelections,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                includeBackoffFeeds: includeBackoffFeeds,
                onlyDueFeeds: onlyDueFeeds,
                targetSubscriptionIDs: targetSubscriptionIDs
            )
        }
        coordinator.activeCycle = cycle
        coordinator.activeCycleDiagnostics = diagnostics
        defer {
            coordinator.activeCycle = nil
            coordinator.activeCycleDiagnostics = nil
        }
        return await cycle.value
    }

    private func perform(
        diagnostics: RefreshCycleDiagnostics,
        maxSubscriptions: Int?,
        maxTotalSelections: Int?,
        capBypassStates: Set<FeedRefreshWindowState>,
        protectedStates: Set<FeedRefreshWindowState>,
        minimumProtectedSelections: Int,
        includeBackoffFeeds: Bool,
        onlyDueFeeds: Bool,
        targetSubscriptionIDs: Set<UUID>?
    ) async -> Bool {
        let cycleStartedAt = CFAbsoluteTimeGetCurrent()
        coordinator.activeCycleMaterialChangeCount = 0
        let refreshContext = diagnostics.metadata(
            currentSceneActive: sceneActive()
        )
        let requested = targetSubscriptionIDs.map { targetIDs in
            subscriptionStore.subscriptions.filter {
                targetIDs.contains($0.id)
            }
        } ?? subscriptionStore.subscriptions
        logger.info("feed.refreshAll", "Refreshing podcast feeds", metadata: [
            "count": "\(requested.count)",
            "reason": diagnostics.reason,
            "maxSubscriptions": maxSubscriptions.map(String.init) ?? "all",
            "targeted": "\(targetSubscriptionIDs != nil)"
        ].merging(refreshContext) { _, new in new })

        let skipped = requested.filter(\.excludeFromAutoFeedRefresh)
        let active = requested.filter { !$0.excludeFromAutoFeedRefresh }
        let now = runtimeWorkflow.now
        let backedOff = active.filter {
            guard let until = coordinator.failureBackoffUntil[$0.id] else {
                return false
            }
            return until > now
        }
        let eligible = includeBackoffFeeds
            ? active
            : active.filter {
                guard let until = coordinator.failureBackoffUntil[$0.id]
                else { return true }
                return until <= now
            }
        let dueCandidates = onlyDueFeeds
            ? await releaseRadar.candidates(from: eligible, now: now)
            : []
        let budget = FeedRefreshBudgeting.select(
            candidates: dueCandidates,
            policy: FeedRefreshBudgetPolicy(
                maxSelections: maxSubscriptions,
                maxTotalSelections: maxTotalSelections,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections
            ),
            state: { $0.prediction.state }
        )
        let selected = budget.selected
        let deferred = budget.deferred
        let subscriptions = onlyDueFeeds
            ? selected.map(\.subscription)
            : eligible
        BackgroundWakeMonitor.shared.recordFeedPlan(
            due: onlyDueFeeds ? dueCandidates.count : subscriptions.count,
            selected: subscriptions.count
        )
        if onlyDueFeeds {
            reconcileBacklog(
                dueCandidates: dueCandidates,
                selectedCandidates: selected,
                deferredCandidates: deferred,
                now: now,
                diagnostics: diagnostics
            )
            logPlan(
                candidates: dueCandidates,
                selectedCandidates: selected,
                deferredCandidates: deferred,
                eligibleCount: eligible.count,
                skippedBackoffCount: backedOff.count,
                skippedInactiveCount: skipped.count,
                maxSubscriptions: maxSubscriptions,
                maxTotalSelections: maxTotalSelections,
                capBypassStates: capBypassStates,
                protectedStates: protectedStates,
                minimumProtectedSelections: minimumProtectedSelections,
                diagnostics: diagnostics
            )
        }
        if onlyDueFeeds, selected.isEmpty {
            coordinator.lastSuccessfulDueRefreshAt = runtimeWorkflow.now
            releaseRadar.scheduleNextBackgroundRefresh()
            logCycleSummary(
                outcome: "noDue",
                attempted: 0,
                completed: 0,
                eligible: eligible.count,
                due: dueCandidates.count,
                deferred: deferred.count,
                skippedBackoff: backedOff.count,
                skippedInactive: skipped.count,
                selectedSubscriptions: [],
                completedIDs: [],
                startedAt: cycleStartedAt,
                context: refreshContext
            )
            return false
        }

        let selectedByID = Dictionary(
            uniqueKeysWithValues: selected.map {
                ($0.subscription.id, $0)
            }
        )
        if !skipped.isEmpty {
            logger.verbose(
                "feed.refreshAll.skippedInactive",
                "Skipped subscriptions excluded from auto feed refresh",
                metadata: [
                    "count": "\(skipped.count)",
                    "podcasts": skipped.map(\.title).joined(separator: ", ")
                ].merging(refreshContext) { _, new in new }
            )
        }
        if !includeBackoffFeeds, !backedOff.isEmpty {
            logger.verbose(
                "feed.refreshAll.skippedBackoff",
                "Skipped subscriptions temporarily paused after failed refreshes",
                metadata: [
                    "count": "\(backedOff.count)",
                    "podcasts": backedOff.map(\.title).joined(separator: ", ")
                ].merging(refreshContext) { _, new in new }
            )
        }

        var completedIDs = Set<UUID>()
        var wasCancelled = false
        let coalescesBackgroundMutations =
            diagnostics.executionContext == .backgroundRefreshTask
            || diagnostics.executionContext == .backgroundProcessingTask
        if coalescesBackgroundMutations {
            subscriptionStore.beginChangeNotificationCoalescing()
        }
        defer {
            if coalescesBackgroundMutations {
                subscriptionStore.endChangeNotificationCoalescing()
            }
        }
        let largeManual = diagnostics.executionContext == .manual
            && subscriptions.count > 8
        let batchSize = largeManual ? 8 : 16
        for (index, subscription) in subscriptions.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            var startMetadata = releaseRadar.feedMetadata(
                for: subscription,
                extra: [
                    "index": "\(index + 1)",
                    "total": "\(subscriptions.count)",
                    "reason": diagnostics.reason
                ].merging(refreshContext) { _, new in new }
            )
            if let candidate = selectedByID[subscription.id] {
                startMetadata.merge(decisionMetadata(for: candidate)) {
                    _, new in new
                }
            }
            logger.verbose(
                "feed.refreshAll.itemStart",
                "Refreshing subscription in timed cycle",
                metadata: startMetadata
            )
            BackgroundWakeMonitor.shared.recordFeedAttempt()
            await itemWorkflow.refresh(
                subscription,
                episodeLimit: policy.defaultEpisodeLimit,
                refreshUpNextAfterMerge: false
            )
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            completedIDs.insert(subscription.id)
            BackgroundWakeMonitor.shared.recordFeedCompletion()
            logger.verbose(
                "feed.refreshAll.itemFinished",
                "Finished subscription in timed cycle",
                metadata: releaseRadar.feedMetadata(
                    for: subscription,
                    includeURL: false,
                    extra: [
                        "index": "\(index + 1)",
                        "total": "\(subscriptions.count)",
                        "reason": diagnostics.reason
                    ].merging(refreshContext) { _, new in new }
                )
            )
            let completedCount = index + 1
            if completedCount % batchSize == 0,
               completedCount < subscriptions.count {
                runtimeWorkflow.logResourceSnapshot(
                    reason: "feed.refreshAll.batchCheckpoint",
                    extra: refreshContext.merging([
                        "completedFeeds": "\(completedCount)",
                        "totalFeeds": "\(subscriptions.count)",
                        "batchSize": "\(batchSize)",
                        "manualDrainPause": "\(largeManual)"
                    ]) { _, new in new },
                    force: true
                )
                await Task.yield()
                if largeManual {
                    // Manual refresh can parse all active feeds while downloads
                    // begin settling. Drain transient artwork/parser allocations
                    // between smaller batches instead of allowing both workloads
                    // to accumulate into a 700+ MB peak.
                    await ArtworkImageCache.shared.trimMemory(
                        reason: "manualRefreshBatch"
                    )
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
        }

        if wasCancelled {
            let unfinished = selected.filter {
                !completedIDs.contains($0.subscription.id)
            }
            restoreUnfinishedBacklog(
                candidates: unfinished,
                now: runtimeWorkflow.now,
                diagnostics: diagnostics
            )
            releaseRadar.scheduleNextBackgroundRefresh()
            logger.warning(
                "feed.refreshAll.cancelled",
                "Refresh cycle stopped before all selected feeds completed",
                metadata: [
                    "attempted": "\(completedIDs.count)",
                    "unfinished": "\(unfinished.count)",
                    "deferredBacklog":
                        "\(coordinator.deferredBacklog.count)",
                    "reason": diagnostics.reason
                ].merging(refreshContext) { _, new in new }
            )
            runtimeWorkflow.logResourceSnapshot(
                reason: "feed.refreshAll.cancelled",
                extra: refreshContext,
                force: true
            )
            logCycleSummary(
                outcome: "cancelled",
                attempted: completedIDs.count + 1,
                completed: completedIDs.count,
                eligible: eligible.count,
                due: onlyDueFeeds ? dueCandidates.count : subscriptions.count,
                deferred: unfinished.count,
                skippedBackoff: backedOff.count,
                skippedInactive: skipped.count,
                selectedSubscriptions: subscriptions,
                completedIDs: completedIDs,
                startedAt: cycleStartedAt,
                context: refreshContext
            )
            return !completedIDs.isEmpty
        }

        releaseRadar.scheduleNextBackgroundRefresh()
        queueCoordinator.recompute(reason: "feed.refreshAll.finished")
        await autoArchiveCoordinator.runIfNeeded(
            reason: "feed.refreshAll",
            force: false
        )
        logCycleSummary(
            outcome: "completed",
            attempted: subscriptions.count,
            completed: completedIDs.count,
            eligible: eligible.count,
            due: onlyDueFeeds ? dueCandidates.count : subscriptions.count,
            deferred: deferred.count,
            skippedBackoff: backedOff.count,
            skippedInactive: skipped.count,
            selectedSubscriptions: subscriptions,
            completedIDs: completedIDs,
            startedAt: cycleStartedAt,
            context: refreshContext
        )
        if onlyDueFeeds {
            coordinator.lastSuccessfulDueRefreshAt = runtimeWorkflow.now
        }
        return true
    }

    /// AI CONTEXT — Normal-tier terminal record for a complete foreground,
    /// background-audio, BGAppRefresh, or BGProcessing feed cycle. It replaces
    /// routine per-feed start/finish narration while retaining the selection,
    /// fairness, execution-context, completion, and duration evidence needed to
    /// diagnose missed background work. Per-feed traces remain available through
    /// AppLogger's verbose tier; failures and material feed changes stay normal.
    private func logCycleSummary(
        outcome: String,
        attempted: Int,
        completed: Int,
        eligible: Int,
        due: Int,
        deferred: Int,
        skippedBackoff: Int,
        skippedInactive: Int,
        selectedSubscriptions: [Subscription],
        completedIDs: Set<UUID>,
        startedAt: CFAbsoluteTime,
        context: [String: String]
    ) {
        let durationMs =
            (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        logger.info(
            "feed.cycleSummary",
            "Feed refresh cycle summary",
            metadata: [
                "outcome": outcome,
                "attempted": "\(attempted)",
                "completed": "\(completed)",
                "unfinished": "\(max(0, attempted - completed))",
                "eligible": "\(eligible)",
                "due": "\(due)",
                "deferred": "\(deferred)",
                "skippedBackoff": "\(skippedBackoff)",
                "skippedInactive": "\(skippedInactive)",
                "deferredBacklog": "\(coordinator.deferredBacklog.count)",
                "materialChanges":
                    "\(coordinator.activeCycleMaterialChangeCount)",
                "batteryState": ResourceMonitor.shared
                    .externalPowerStateLabel,
                "selectedFeedHashes": selectedSubscriptions.prefix(10).map {
                    releaseRadar.feedHash(for: $0.feedURL)
                }.joined(separator: ","),
                "completedFeedHashes": selectedSubscriptions.filter {
                    completedIDs.contains($0.id)
                }.prefix(10).map {
                    releaseRadar.feedHash(for: $0.feedURL)
                }.joined(separator: ","),
                "unfinishedFeedHashes": selectedSubscriptions.filter {
                    !completedIDs.contains($0.id)
                }.prefix(10).map {
                    releaseRadar.feedHash(for: $0.feedURL)
                }.joined(separator: ","),
                "durationMs": String(
                    format: "%.0f",
                    durationMs
                )
            ].merging(context) { _, new in new }
        )
        recordEfficiencyWindow(
            context: context,
            attempted: attempted,
            completed: completed,
            materialChanges: coordinator.activeCycleMaterialChangeCount,
            networkHosts: Set(
                selectedSubscriptions.compactMap { $0.feedURL.host }
            ),
            durationMs: durationMs
        )
    }

    private func recordEfficiencyWindow(
        context: [String: String],
        attempted: Int,
        completed: Int,
        materialChanges: Int,
        networkHosts: Set<String>,
        durationMs: Double
    ) {
        guard let rawContext = context["executionContext"],
              let executionContext = FeedRefreshExecutionContext(
                rawValue: rawContext
              ),
              executionContext == .backgroundAudioAlive
                || executionContext == .backgroundRefreshTask else {
            return
        }
        let now = runtimeWorkflow.now
        var window = coordinator.efficiencyWindows[executionContext]
            ?? .init(startedAt: now)
        window.cycles += 1
        window.attempted += attempted
        window.completed += completed
        window.materialChanges += materialChanges
        window.zeroResultCycles += materialChanges == 0 ? 1 : 0
        window.networkHosts.formUnion(networkHosts)
        window.durationMs += durationMs
        guard now.timeIntervalSince(window.startedAt) >= 60 * 60 else {
            coordinator.efficiencyWindows[executionContext] = window
            return
        }
        logger.info(
            "feed.backgroundEfficiencySummary",
            "Rolling background refresh efficiency summary",
            metadata: [
                "executionContext": executionContext.rawValue,
                "windowSeconds": "\(Int(now.timeIntervalSince(window.startedAt)))",
                "cycles": "\(window.cycles)",
                "attempted": "\(window.attempted)",
                "completed": "\(window.completed)",
                "materialChanges": "\(window.materialChanges)",
                "zeroResultCycles": "\(window.zeroResultCycles)",
                "distinctFeedHosts": "\(window.networkHosts.count)",
                "refreshWallMs": String(format: "%.0f", window.durationMs),
                "batteryState": ResourceMonitor.shared
                    .externalPowerStateLabel
            ]
        )
        coordinator.efficiencyWindows[executionContext] = .init(startedAt: now)
    }

    private func backgroundAudioBudget()
        -> (routineLimit: Int, hardLimit: Int) {
        var routine = policy.backgroundAudioLimit
        var hard = policy.backgroundAudioHardLimit
        func reduce(routine newRoutine: Int, hard newHard: Int) {
            routine = min(routine, newRoutine)
            hard = min(hard, newHard)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            reduce(routine: 4, hard: 6)
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            reduce(routine: 3, hard: 5)
        case .critical:
            reduce(routine: 2, hard: 3)
        case .nominal, .fair:
            break
        @unknown default:
            reduce(routine: 4, hard: 6)
        }
        if let path = downloadCoordinator.latestNetworkPath,
           path.usesInterfaceType(.cellular)
                || path.isConstrained
                || path.isExpensive {
            reduce(routine: 4, hard: 6)
        }
        let largeDownload = downloadCoordinator.activityStore.activeActivities
            .contains {
                $0.status == .downloading
                    && max($0.expectedBytes ?? 0, $0.writtenBytes)
                        >= 100 * 1_024 * 1_024
            }
        if largeDownload {
            reduce(routine: 4, hard: 6)
        }
        return (routine, max(routine, hard))
    }

    private func additionalBackgroundCapacity(
        cooperativeSecondsRemaining: TimeInterval
    ) -> Int {
        func reject(_ reason: String) -> Int {
            logger.info(
                "background.additionalBatchSkipped",
                "Skipped opportunistic BGAppRefresh follow-up batch",
                metadata: [
                    "reason": reason,
                    "cooperativeSecondsRemaining": String(
                        format: "%.1f",
                        cooperativeSecondsRemaining
                    )
                ]
            )
            return 0
        }
        guard cooperativeSecondsRemaining >= 7 else {
            return reject("deadline")
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return reject("lowPowerMode")
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            break
        case .serious, .critical:
            return reject("thermal")
        @unknown default:
            return reject("thermalUnknown")
        }
        if let path = downloadCoordinator.latestNetworkPath,
           path.usesInterfaceType(.cellular)
                || path.isConstrained
                || path.isExpensive {
            return reject("networkConstrained")
        }
        let hasLargeDownload = downloadCoordinator.activityStore.activeActivities
            .contains {
                $0.status == .downloading
                    && max($0.expectedBytes ?? 0, $0.writtenBytes)
                        >= 100 * 1_024 * 1_024
            }
        guard !hasLargeDownload else { return reject("largeDownload") }
        let powerState = ResourceMonitor.shared.externalPowerStateLabel
        let onExternalPower = powerState == "charging" || powerState == "full"
        let capacity = cooperativeSecondsRemaining >= 11 && onExternalPower
            ? 4 : 2
        logger.info(
            "background.additionalBatchBudget",
            "Selected power-aware BGAppRefresh follow-up capacity",
            metadata: [
                "capacity": "\(capacity)",
                "batteryState": powerState,
                "onExternalPower": "\(onExternalPower)",
                "cooperativeSecondsRemaining": String(
                    format: "%.1f",
                    cooperativeSecondsRemaining
                )
            ]
        )
        return capacity
    }

    private func logPlan(
        candidates: [RefreshCycleCandidate],
        selectedCandidates: [RefreshCycleCandidate],
        deferredCandidates: [RefreshCycleCandidate],
        eligibleCount: Int,
        skippedBackoffCount: Int,
        skippedInactiveCount: Int,
        maxSubscriptions: Int?,
        maxTotalSelections: Int?,
        capBypassStates: Set<FeedRefreshWindowState>,
        protectedStates: Set<FeedRefreshWindowState>,
        minimumProtectedSelections: Int,
        diagnostics: RefreshCycleDiagnostics
    ) {
        let protectedSelectedCount = selectedCandidates.filter {
            protectedStates.contains($0.prediction.state)
        }.count
        logger.info(
            "feed.refreshAll.plan",
            "Planned due-feed refresh cycle",
            metadata: [
                "reason": diagnostics.reason,
                "eligible": "\(eligibleCount)",
                "due": "\(candidates.count)",
                "selected": "\(selectedCandidates.count)",
                "cappedOut":
                    "\(max(0, candidates.count - selectedCandidates.count))",
                "maxSubscriptions":
                    maxSubscriptions.map(String.init) ?? "all",
                "maxTotalSelections":
                    maxTotalSelections.map(String.init) ?? "unlimited",
                "capBypassStates": stateList(capBypassStates),
                "protectedStates": stateList(protectedStates),
                "protectedMinimum": "\(minimumProtectedSelections)",
                "protectedSelected": "\(protectedSelectedCount)",
                "selectedFeedHashes": selectedCandidates.prefix(10).map {
                    releaseRadar.feedHash(for: $0.subscription.feedURL)
                }.joined(separator: ","),
                "skippedBackoff": "\(skippedBackoffCount)",
                "skippedInactive": "\(skippedInactiveCount)",
                "deferredBacklog":
                    "\(coordinator.deferredBacklog.count)",
                "stateCounts": stateCounts(for: candidates)
            ].merging(
                backlogMetadata(now: runtimeWorkflow.now)
            ) { _, new in new }
             .merging(
                diagnostics.metadata(currentSceneActive: sceneActive())
             ) { _, new in new }
        )
        logger.verbose(
            "feed.refreshAll.planDetail",
            "Verbose due-feed selection detail",
            metadata: [
                "topCandidates": topSummary(for: candidates),
                "selectedCandidates": topSummary(for: selectedCandidates),
                "deferredCandidates": topSummary(for: deferredCandidates)
            ].merging(
                diagnostics.metadata(currentSceneActive: sceneActive())
            ) { _, new in new }
        )
    }

    private func decisionMetadata(
        for candidate: RefreshCycleCandidate
    ) -> [String: String] {
        var metadata = [
            "refreshScore": String(
                format: "%.1f",
                candidate.priority.score
            ),
            "refreshFactors": candidate.priority.reason,
            "profileKind": candidate.profile.kind.rawValue,
            "profileConfidence": String(
                format: "%.2f",
                candidate.profile.confidence
            ),
            "profileObservations":
                "\(candidate.profile.observationCount)",
            "profileReliableDates":
                "\(candidate.profile.reliableDateCount)",
            "predictionState": candidate.prediction.state.rawValue,
            "predictionReason": candidate.prediction.reason,
            "nextDueAt": releaseRadar.logDate(
                candidate.prediction.nextDueAt
            ),
            "expectedWindowStart": releaseRadar.logDate(
                candidate.prediction.expectedWindowStart
            ),
            "expectedWindowEnd": releaseRadar.logDate(
                candidate.prediction.expectedWindowEnd
            ),
            "recheckIntervalSeconds":
                candidate.prediction.recheckInterval.map {
                    "\(Int($0.rounded()))"
                } ?? "none"
        ]
        if let window = candidate.profile.releaseWindow {
            metadata["releaseWindow"] = String(
                format: "%02d:%02d-%02d:%02d",
                window.startMinuteOfDay / 60,
                window.startMinuteOfDay % 60,
                window.endMinuteOfDay / 60,
                window.endMinuteOfDay % 60
            )
            if let spread = window.observedSpreadMinutes {
                metadata["releaseWindowObservedSpreadMinutes"] =
                    "\(spread)"
            }
        }
        if candidate.deferredCount > 0 {
            metadata["deferredRefreshCount"] =
                "\(candidate.deferredCount)"
            metadata["deferredRefreshSince"] = releaseRadar.logDate(
                candidate.deferredSince
            )
            metadata["deferredRefreshBoost"] = String(
                format: "%.1f",
                candidate.deferredScoreBoost
            )
        }
        return metadata
    }

    private func stateCounts(
        for candidates: [RefreshCycleCandidate]
    ) -> String {
        let counts = candidates.reduce(
            into: [FeedRefreshWindowState: Int]()
        ) {
            $0[$1.prediction.state, default: 0] += 1
        }
        return FeedRefreshWindowState.allCases
            .compactMap {
                guard let count = counts[$0], count > 0 else { return nil }
                return "\($0.rawValue)=\(count)"
            }
            .joined(separator: ",")
    }

    private func stateList(
        _ states: Set<FeedRefreshWindowState>
    ) -> String {
        let values = FeedRefreshWindowState.allCases
            .filter(states.contains)
            .map(\.rawValue)
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    private func topSummary(
        for candidates: [RefreshCycleCandidate]
    ) -> String {
        candidates.prefix(5)
            .map {
                let score = String(format: "%.1f", $0.priority.score)
                let hash = releaseRadar.feedHash(
                    for: $0.subscription.feedURL
                )
                let deferred = $0.deferredCount > 0
                    ? "|deferred:\($0.deferredCount)"
                    : ""
                return "\(score)|\($0.prediction.state.rawValue)|\($0.profile.kind.rawValue)|id:\($0.subscription.id.uuidString)|hash:\(hash)\(deferred)|\($0.subscription.title)"
            }
            .joined(separator: "; ")
    }

    private func reconcileBacklog(
        dueCandidates: [RefreshCycleCandidate],
        selectedCandidates: [RefreshCycleCandidate],
        deferredCandidates: [RefreshCycleCandidate],
        now: Date,
        diagnostics: RefreshCycleDiagnostics
    ) {
        let previousCount = coordinator.deferredBacklog.count
        let dueIDs = Set(dueCandidates.map(\.subscription.id))
        coordinator.deferredBacklog = coordinator.deferredBacklog.filter {
            dueIDs.contains($0.key)
        }
        for candidate in selectedCandidates {
            coordinator.deferredBacklog.removeValue(
                forKey: candidate.subscription.id
            )
        }
        for candidate in deferredCandidates {
            recordDeferred(candidate, now: now)
        }
        if !deferredCandidates.isEmpty
            || coordinator.deferredBacklog.count != previousCount {
            logger.info(
                "feed.refreshAll.backlog",
                "Checkpointed deferred due-feed backlog",
                metadata: [
                    "reason": diagnostics.reason,
                    "selected": "\(selectedCandidates.count)",
                    "deferred": "\(deferredCandidates.count)",
                    "backlogCount":
                        "\(coordinator.deferredBacklog.count)",
                    "deferredCandidates":
                        topSummary(for: deferredCandidates)
                ].merging(backlogMetadata(now: now)) { _, new in new }
                 .merging(
                    diagnostics.metadata(currentSceneActive: sceneActive())
                 ) { _, new in new }
            )
        }
    }

    private func restoreUnfinishedBacklog(
        candidates: [RefreshCycleCandidate],
        now: Date,
        diagnostics: RefreshCycleDiagnostics
    ) {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            recordDeferred(candidate, now: now)
        }
        logger.warning(
            "feed.refreshAll.checkpoint",
            "Checkpointed unfinished selected feeds",
            metadata: [
                "reason": diagnostics.reason,
                "unfinished": "\(candidates.count)",
                "backlogCount": "\(coordinator.deferredBacklog.count)",
                "unfinishedCandidates": topSummary(for: candidates)
            ].merging(backlogMetadata(now: now)) { _, new in new }
             .merging(
                diagnostics.metadata(currentSceneActive: sceneActive())
             ) { _, new in new }
        )
    }

    private func backlogMetadata(now: Date) -> [String: String] {
        guard let oldest = coordinator.deferredBacklog.values.min(
            by: { $0.firstDeferredAt < $1.firstDeferredAt }
        ) else {
            return [
                "oldestDeferredAgeSeconds": "0",
                "oldestDeferredPodcast": "none",
                "oldestDeferredSubscriptionID": "none",
                "oldestDeferredCount": "0",
                "oldestDeferredState": "none"
            ]
        }
        return [
            "oldestDeferredAgeSeconds":
                "\(max(0, Int(now.timeIntervalSince(oldest.firstDeferredAt).rounded())))",
            "oldestDeferredSince":
                releaseRadar.logDate(oldest.firstDeferredAt),
            "oldestDeferredPodcast": oldest.title,
            "oldestDeferredSubscriptionID":
                oldest.subscriptionID.uuidString,
            "oldestDeferredCount": "\(oldest.deferralCount)",
            "oldestDeferredState": oldest.state.rawValue
        ]
    }

    private func recordDeferred(
        _ candidate: RefreshCycleCandidate,
        now: Date
    ) {
        let subscription = candidate.subscription
        if var entry = coordinator.deferredBacklog[subscription.id] {
            entry.title = subscription.title
            entry.feedURL = subscription.feedURL
            entry.lastDeferredAt = now
            entry.lastDueAt = candidate.prediction.nextDueAt
            entry.deferralCount += 1
            entry.state = candidate.prediction.state
            entry.score = candidate.priority.score
            coordinator.deferredBacklog[subscription.id] = entry
        } else {
            coordinator.deferredBacklog[subscription.id] =
                DeferredRefreshBacklogEntry(
                    subscriptionID: subscription.id,
                    title: subscription.title,
                    feedURL: subscription.feedURL,
                    firstDeferredAt: now,
                    lastDeferredAt: now,
                    lastDueAt: candidate.prediction.nextDueAt,
                    deferralCount: 1,
                    state: candidate.prediction.state,
                    score: candidate.priority.score
                )
        }
    }

    private var isAppForeground: Bool {
        appForeground()
    }
}
