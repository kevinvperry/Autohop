//
//  DownloadCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 6 AppState decomposition owner for download runtime state and policy.
//  It owns the NWPathMonitor, current network path, three-slot FIFO accounting,
//  progress/activity projections, automatic-failure cooldowns, bounded watchdog
//  attempts, superseded rolling-feed cancellation identity, and orphan-facing
//  activity state. It also idempotently owns DownloadManager progress callback
//  installation and coalesces progress publications before updating its two
//  observable download projections. AppState retains only platform/view command
//  names; DownloadTransferWorkflow and DownloadActionsWorkflow own behavior.
//
//  Automatic provenance remains durable in AutoDownloadIntentStore. This type
//  does not decide feed eligibility, queue order, Play Instant policy, or
//  listening-history outcomes.
//

import AVFoundation
import Combine
import Foundation
import Network

@MainActor
final class DownloadCoordinator: ObservableObject {
    struct EpisodeDetection {
        let detectedAt: Date
        let context: String
        let sceneActivationSequence: Int
    }
    struct PendingDownload {
        let episode: Episode
        let subscriptionID: UUID
        let podcastTitle: String
        let showCompletionMessage: Bool
        let isAutomatic: Bool
    }

    let progressModel: DownloadProgressModel
    let activityStore: DownloadActivityStore
    let maxConcurrentDownloads: Int

    @Published private(set) var downloadedActivities: [DownloadActivity] = []
    @Published var message: String?

    private let networkMonitor: NWPathMonitor
    private var monitorStarted = false
    private var progressCallbackInstalled = false
    private var watchdogCallbackInstalled = false
    private var backgroundCompletionCallbackInstalled = false
    private var remoteFileDeletionCallbackInstalled = false
    private weak var watchdogDownloadManager: (any DownloadManaging)?
    private(set) var latestNetworkPath: NWPath?
    private var cancellables = Set<AnyCancellable>()
    private var watchdogRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var watchdogRetryGeneration: [UUID: Int] = [:]
    private weak var autoDownloadIntentStore: AutoDownloadIntentStore?
    private struct HostCircuit {
        var terminalFailures: [Date] = []
        var openUntil: Date?
    }
    private var hostCircuits: [String: HostCircuit] = [:]
    private var globalCircuitOpenUntil: Date?
    private var episodeDetections: [UUID: EpisodeDetection] = [:]

    // Internal access is limited to typed download/runtime workflows. These
    // values have one storage owner and are not published.
    var pendingQueue: [PendingDownload] = []
    var activeCount = 0
    var failureBackoff: [String: (failures: Int, retryAfter: Date)] = [:]
    var watchdogRetryCounts: [UUID: Int] = [:]
    var supersededCancellationIDs = Set<UUID>()

    init(
        progressModel: DownloadProgressModel? = nil,
        activityStore: DownloadActivityStore? = nil,
        maxConcurrentDownloads: Int = 3,
        networkMonitor: NWPathMonitor = NWPathMonitor()
    ) {
        self.progressModel = progressModel ?? DownloadProgressModel()
        self.activityStore = activityStore ?? DownloadActivityStore()
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.networkMonitor = networkMonitor
        self.activityStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func startNetworkMonitoring() {
        guard !monitorStarted else { return }
        monitorStarted = true
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.latestNetworkPath = path
                self?.reevaluateWatchdog(reason: "networkPathChanged")
            }
        }
        networkMonitor.start(
            queue: DispatchQueue(label: "au.com.autohop.networkmonitor", qos: .utility)
        )
    }

    /// Installs the UI progress callback exactly once.
    ///
    /// AI CONTEXT — DownloadManager already limits each task to approximately
    /// one callback per second. Multiple concurrent downloads can still produce
    /// excessive SwiftUI invalidations, so this owner retains the established
    /// one-percentage-point coalescing rule. Completion always publishes.
    /// Callback delivery enters MainActor before touching observable state.
    func installProgressCallback(on downloadManager: any DownloadManaging) {
        guard !progressCallbackInstalled else { return }
        progressCallbackInstalled = true

        downloadManager.onProgressUpdate = {
            [weak self] episodeID, fraction, writtenBytes, expectedBytes in
            Task { @MainActor in
                guard let self else { return }
                let lastFraction = self.progressModel.progress[episodeID] ?? -1
                guard fraction >= 1 || abs(fraction - lastFraction) >= 0.01 else {
                    return
                }
                self.progressModel.progress[episodeID] = fraction
                self.activityStore.progress(
                    episodeID: episodeID,
                    fraction: fraction,
                    writtenBytes: writtenBytes,
                    expectedBytes: expectedBytes
                )
            }
        }
    }

    /// Owns the cross-device archive cleanup adapter.
    ///
    /// AI CONTEXT — SubscriptionStore intentionally does not know how media is
    /// stored. A remote played/archived merge supplies the still-populated
    /// Episode before clearing its download fields; this adapter deletes the
    /// corresponding local file asynchronously. Installation is idempotent and
    /// AppState never receives or installs the domain callback.
    func installRemoteFileDeletionCallback(
        on subscriptionStore: SubscriptionStore,
        downloadManager: any DownloadManaging
    ) {
        guard !remoteFileDeletionCallbackInstalled else { return }
        remoteFileDeletionCallbackInstalled = true
        subscriptionStore.onEpisodeFileShouldDelete = {
            [weak downloadManager] episode in
            Task {
                try? await downloadManager?.deleteLocalFile(for: episode)
            }
        }
    }

    /// Installs bounded watchdog recovery and owns every delayed retry task.
    ///
    /// AI CONTEXT — A confirmed transfer stall may retry at 30, 60, and
    /// 120 seconds. A fourth cancellation is terminal: URLSession identity and
    /// resume data are retired, the episode returns to failed state, and the
    /// activity becomes user-retryable. Repeated callbacks replace/cancel the
    /// prior delayed task, preventing exhausted or superseded work from firing.
    /// DownloadActionsWorkflow is the typed re-entry point after the
    /// coordinator-owned delay.
    func installWatchdogCallback(
        on downloadManager: any DownloadManaging,
        subscriptionStore: SubscriptionStore,
        autoDownloadIntentStore: AutoDownloadIntentStore,
        logger: AppLogger,
        actions: DownloadActionsWorkflow
    ) {
        guard !watchdogCallbackInstalled else { return }
        watchdogCallbackInstalled = true
        watchdogDownloadManager = downloadManager
        self.autoDownloadIntentStore = autoDownloadIntentStore

        downloadManager.onWatchdogCancelled = {
            [weak self, weak downloadManager, weak subscriptionStore, weak autoDownloadIntentStore] episodeID in
            Task { @MainActor in
                guard let self, let downloadManager, let subscriptionStore,
                      let autoDownloadIntentStore else {
                    return
                }
                // Two watchdog evaluators can observe the same URLSession task
                // generation before either callback reaches MainActor. The first
                // callback owns retry advancement; later callbacks are coalesced
                // instead of consuming attempts 2 and 3 for one timeout.
                guard self.watchdogRetryTasks[episodeID] == nil else {
                    logger.info(
                        "download.watchdogRetryCoalesced",
                        "Ignored duplicate watchdog retry decision",
                        metadata: ["episodeID": episodeID.uuidString]
                    )
                    return
                }
                let generation = (self.watchdogRetryGeneration[episodeID] ?? 0) + 1
                self.watchdogRetryGeneration[episodeID] = generation
                let attempt = (self.watchdogRetryCounts[episodeID] ?? 0) + 1
                self.watchdogRetryCounts[episodeID] = attempt

                guard attempt <= 3 else {
                    downloadManager.cancelDownload(episodeID: episodeID)
                    downloadManager.clearResumeData(episodeID: episodeID)
                    var durableCooldownSeconds = "unavailable"
                    var consecutiveExhaustions = "unavailable"
                    if let activity = self.activityStore.activeActivities.first(
                        where: { $0.episodeID == episodeID }
                    ),
                       let episode = subscriptionStore.episode(
                        subscriptionID: activity.subscriptionID,
                        episodeID: episodeID
                       ),
                       let subscription = subscriptionStore.subscription(
                        id: activity.subscriptionID
                       ) {
                        let failure = autoDownloadIntentStore.recordExhaustion(
                            episodeID: episodeID,
                            subscriptionID: activity.subscriptionID,
                            mediaURL: episode.audioURL,
                            host: episode.audioURL.host,
                            now: Date()
                        )
                        durableCooldownSeconds = String(
                            format: "%.0f",
                            failure.retryAfter.timeIntervalSinceNow
                        )
                        consecutiveExhaustions =
                            "\(failure.consecutiveExhaustions)"
                        self.recordTerminalDownloadFailure(
                            for: episode.audioURL,
                            now: Date()
                        )
                        subscriptionStore.markEpisodeDownloadFailed(
                            subscriptionID: activity.subscriptionID,
                            episodeID: episodeID
                        )
                        self.activityStore.fail(
                            episode: episode,
                            podcastTitle: subscription.title,
                            error: "Download stalled repeatedly. Tap to retry."
                        )
                    }
                    logger.warning(
                        "download.watchdogRetryExhausted",
                        "Automatic retries stopped after repeated confirmed stalls",
                        metadata: [
                            "episodeID": episodeID.uuidString,
                            "attempts": "\(attempt - 1)",
                            "durableIntentRetired": "false",
                            "durableCooldownSeconds": durableCooldownSeconds,
                            "consecutiveExhaustions": consecutiveExhaustions,
                            "retryGeneration": "\(generation)"
                        ]
                    )
                    return
                }

                let delay = TimeInterval(30 * (1 << (attempt - 1)))
                logger.info(
                    "download.watchdogRetryScheduled",
                    "Scheduled bounded watchdog retry",
                    metadata: [
                        "episodeID": episodeID.uuidString,
                        "attempt": "\(attempt)",
                        "delaySeconds": "\(Int(delay))"
                    ]
                )
                self.watchdogRetryTasks[episodeID] = Task {
                    @MainActor [weak self, weak actions] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled,
                          self?.watchdogRetryGeneration[episodeID] == generation
                    else { return }
                    await actions?.retryWatchdogCancelledDownload(
                        episodeID: episodeID
                    )
                    self?.watchdogRetryTasks.removeValue(forKey: episodeID)
                }
            }
        }
    }

    func clearWatchdogRetryState(for episodeID: UUID) {
        watchdogRetryCounts.removeValue(forKey: episodeID)
        watchdogRetryTasks.removeValue(forKey: episodeID)?.cancel()
        watchdogRetryGeneration[episodeID, default: 0] += 1
    }

    func isAutomaticDownload(episodeID: UUID) -> Bool {
        autoDownloadIntentStore?.contains(episodeID: episodeID) == true
    }

    func recordEpisodeDetection(
        episodeID: UUID,
        detectedAt: Date,
        context: String,
        sceneActivationSequence: Int
    ) {
        episodeDetections[episodeID] = EpisodeDetection(
            detectedAt: detectedAt,
            context: context,
            sceneActivationSequence: sceneActivationSequence
        )
    }

    func detectionMetadata(
        episodeID: UUID,
        now: Date,
        sceneActivationSequence: Int
    ) -> [String: String] {
        guard let detection = episodeDetections[episodeID] else {
            return [
                "detectedAt": "unknown",
                "detectionContext": "unknown",
                "detectElapsedSeconds": "unknown",
                "foregroundActivationsSinceDetection": "unknown"
            ]
        }
        return [
            "detectedAt": detection.detectedAt.ISO8601Format(),
            "detectionContext": detection.context,
            "detectElapsedSeconds": String(
                format: "%.1f",
                max(0, now.timeIntervalSince(detection.detectedAt))
            ),
            "foregroundActivationsSinceDetection":
                "\(max(0, sceneActivationSequence - detection.sceneActivationSequence))"
        ]
    }

    func clearEpisodeDetection(episodeID: UUID) {
        episodeDetections.removeValue(forKey: episodeID)
    }

    /// Automatic work observes per-host and cross-host circuit breakers.
    /// Manual user actions deliberately bypass them.
    func automaticDownloadBlock(for mediaURL: URL, now: Date = Date()) -> String? {
        if let until = globalCircuitOpenUntil, until > now {
            return "session"
        }
        guard let host = mediaURL.host?.lowercased(),
              let until = hostCircuits[host]?.openUntil,
              until > now else {
            return nil
        }
        return "host"
    }

    func recordDownloadSuccess(episodeID: UUID, mediaURL: URL) {
        autoDownloadIntentStore?.clearFailure(episodeID: episodeID)
        guard let host = mediaURL.host?.lowercased() else { return }
        hostCircuits.removeValue(forKey: host)
        if hostCircuits.values.allSatisfy({ $0.openUntil == nil }) {
            globalCircuitOpenUntil = nil
        }
    }

    func recordTerminalDownloadFailure(for mediaURL: URL, now: Date) {
        guard let host = mediaURL.host?.lowercased() else { return }
        let windowStart = now.addingTimeInterval(-10 * 60)
        var circuit = hostCircuits[host] ?? HostCircuit()
        circuit.terminalFailures.removeAll { $0 < windowStart }
        circuit.terminalFailures.append(now)
        if circuit.terminalFailures.count >= 2 {
            circuit.openUntil = now.addingTimeInterval(15 * 60)
        }
        hostCircuits[host] = circuit

        let failingHosts = hostCircuits.filter { _, value in
            value.terminalFailures.contains { $0 >= windowStart }
        }.count
        if failingHosts >= 3 {
            globalCircuitOpenUntil = now.addingTimeInterval(5 * 60)
        }
    }

    /// AI CONTEXT — Lifecycle/BGTask/network owners enter through this narrow
    /// seam instead of retaining or downcasting the concrete DownloadManager.
    /// The manager evaluates absolute first-byte deadlines immediately while
    /// preserving suspension grace only for transfers that already received data.
    func reevaluateWatchdog(reason: String) {
        watchdogDownloadManager?.reevaluateWatchdog(reason: reason)
    }

    /// Owns the out-of-process completion callback delivered after iOS
    /// relaunches the app for a finished background URLSession transfer.
    ///
    /// AI CONTEXT — Durable automatic intent is sampled before store settlement,
    /// because only automatic transfers may trigger Play Instant. This method
    /// owns download-state, duration, byte-stat, activity, progress, and
    /// downloaded-projection settlement. Notification, Play Instant, and durable
    /// intent policy enter through their typed workflow owners. File metadata is
    /// prepared off-main; store mutations use one observer transaction; slow
    /// settlements report sub-stage timings instead of one opaque duration.
    func installBackgroundCompletionCallback(
        on downloadManager: any DownloadManaging,
        subscriptionStore: SubscriptionStore,
        autoDownloadIntentStore: AutoDownloadIntentStore,
        historyStatsCoordinator: HistoryStatsCoordinator,
        notificationWorkflow: NewEpisodeNotificationWorkflow,
        playInstantWorkflow: PlayInstantWorkflow,
        autoDownloadIntentWorkflow: AutoDownloadIntentWorkflow
    ) {
        guard !backgroundCompletionCallbackInstalled else { return }
        backgroundCompletionCallbackInstalled = true

        downloadManager.onBackgroundDownloadCompleted = {
            [
                weak self,
                weak subscriptionStore,
                weak autoDownloadIntentStore,
                weak historyStatsCoordinator,
                weak notificationWorkflow,
                weak playInstantWorkflow,
                weak autoDownloadIntentWorkflow
            ]
            episodeID, subscriptionID, localFileURL in
            Task { @MainActor in
                let settlementStartedAt = CFAbsoluteTimeGetCurrent()
                guard let self,
                      let subscriptionStore,
                      let autoDownloadIntentStore,
                      let historyStatsCoordinator,
                      let notificationWorkflow,
                      let playInstantWorkflow,
                      let autoDownloadIntentWorkflow else {
                    return
                }

                let lookupStartedAt = CFAbsoluteTimeGetCurrent()
                let wasAutomatic = autoDownloadIntentStore.contains(
                    episodeID: episodeID
                )
                async let mediaDuration = Self.localMediaDuration(
                    from: localFileURL
                )
                async let downloadedByteCount = Self.localFileByteCount(
                    at: localFileURL
                )
                // Resolve file metadata before opening the store notification
                // transaction. Holding the transaction across suspension could
                // accidentally defer unrelated foreground store publications.
                let resolvedDuration = await mediaDuration
                let downloadedBytes = await downloadedByteCount
                let lookupMs =
                    (CFAbsoluteTimeGetCurrent() - lookupStartedAt) * 1_000

                let storeStartedAt = CFAbsoluteTimeGetCurrent()
                subscriptionStore.beginChangeNotificationCoalescing()
                subscriptionStore.markEpisodeDownloaded(
                    subscriptionID: subscriptionID,
                    episodeID: episodeID,
                    localFileURL: localFileURL,
                    protectFromEpisodeLimit: !wasAutomatic
                )
                if let duration = resolvedDuration {
                    subscriptionStore.updateEpisodeDuration(
                        subscriptionID: subscriptionID,
                        episodeID: episodeID,
                        durationSeconds: duration
                    )
                }
                subscriptionStore.endChangeNotificationCoalescing()
                let storeMs =
                    (CFAbsoluteTimeGetCurrent() - storeStartedAt) * 1_000
                self.progressModel.progress.removeValue(forKey: episodeID)

                let statsStartedAt = CFAbsoluteTimeGetCurrent()
                historyStatsCoordinator.recordDownload(bytes: downloadedBytes)
                let statsMs =
                    (CFAbsoluteTimeGetCurrent() - statsStartedAt) * 1_000

                let effectsStartedAt = CFAbsoluteTimeGetCurrent()
                if let subscription = subscriptionStore.subscription(
                    id: subscriptionID
                ),
                   let episode = subscriptionStore.episode(
                    subscriptionID: subscriptionID,
                    episodeID: episodeID
                   ) {
                self.activityStore.complete(
                    episode: episode,
                    podcastTitle: subscription.title,
                    localFileName: localFileURL.lastPathComponent
                )
                BackgroundWakeMonitor.shared.recordDownloadCompleted()
                    notificationWorkflow.notifyIfAllowed(
                        episode: episode,
                        subscription: subscription
                    )
                    if wasAutomatic {
                        playInstantWorkflow.enqueueIfEligible(
                            episodeID: episodeID,
                            subscriptionID: subscriptionID
                        )
                    }
                }

                autoDownloadIntentWorkflow.resolveIfSettled(
                    episodeID: episodeID,
                    subscriptionID: subscriptionID
                )
                self.rebuildDownloadedActivities(
                    from: subscriptionStore.subscriptions
                )
                let effectsMs =
                    (CFAbsoluteTimeGetCurrent() - effectsStartedAt) * 1_000
                let totalMs =
                    (CFAbsoluteTimeGetCurrent() - settlementStartedAt) * 1_000
                if totalMs >= 100 {
                    AppLogger.shared.warning(
                        "ui.mainActorOperationSlow",
                        "Download completion settlement occupied the main actor",
                        metadata: [
                            "operation": "download.settlement",
                            "durationMs": String(format: "%.1f", totalMs),
                            "lookupMs": String(format: "%.1f", lookupMs),
                            "storeAndMediaMs": String(format: "%.1f", storeMs),
                            "statsMs": String(format: "%.1f", statsMs),
                            "effectsMs": String(format: "%.1f", effectsMs),
                            "episodeID": episodeID.uuidString,
                            "subscriptionCount": "\(subscriptionStore.subscriptions.count)"
                        ]
                    )
                }
            }
        }
    }

    private static func localMediaDuration(from url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        return duration
    }

    private static func localFileByteCount(at url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            (
                (try? FileManager.default.attributesOfItem(
                    atPath: url.path
                ))?[.size] as? NSNumber
            )?.int64Value ?? 0
        }.value
    }

    func isAllowed(settings: AppSettings) -> Bool {
        guard let path = latestNetworkPath, path.status == .satisfied else {
            return settings.downloadOverWifi
        }
        if path.usesInterfaceType(.wifi) && !settings.downloadOverWifi { return false }
        if path.usesInterfaceType(.cellular) && !settings.downloadOverCellular { return false }
        return true
    }

    func recordFailure(guid: String, title: String, logger: AppLogger) {
        guard !guid.isEmpty else { return }
        let failures = (failureBackoff[guid]?.failures ?? 0) + 1
        let cooldownMinutes = min(2.0 * pow(4.0, Double(failures - 1)), 120.0)
        failureBackoff[guid] = (
            failures,
            Date().addingTimeInterval(cooldownMinutes * 60)
        )
        logger.info("download.backoffScheduled", "Backing off repeated download failure", metadata: [
            "episode": title,
            "failures": "\(failures)",
            "retryAfterMinutes": String(format: "%.0f", cooldownMinutes)
        ])
    }

    func rebuildDownloadedActivities(from subscriptions: [Subscription]) {
        let completed = activityStore.completedActivities.reduce(
            into: [UUID: DownloadActivity]()
        ) { result, activity in
            if result[activity.episodeID] == nil { result[activity.episodeID] = activity }
        }
        downloadedActivities = subscriptions.flatMap { subscription in
            subscription.episodes.compactMap { episode -> DownloadActivity? in
                guard episode.downloadState == .downloaded, episode.localFileURL != nil else {
                    return nil
                }
                if let existing = completed[episode.id] { return existing }
                return DownloadActivity(
                    id: episode.id,
                    episodeID: episode.id,
                    subscriptionID: subscription.id,
                    episodeTitle: episode.title,
                    podcastTitle: subscription.title,
                    mediaURL: episode.audioURL,
                    artworkURL: subscription.artworkURL ?? episode.artworkURL,
                    mediaKind: episode.mediaKind,
                    expectedBytes: episode.fileSizeBytes,
                    writtenBytes: episode.fileSizeBytes ?? 0,
                    progress: 1,
                    status: .completed,
                    startedAt: episode.publishedAt ?? .distantPast,
                    updatedAt: episode.publishedAt ?? .distantPast,
                    completedAt: episode.publishedAt,
                    localFileName: episode.localFileName ?? episode.localFileURL?.lastPathComponent
                )
            }
        }
        .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }
}
