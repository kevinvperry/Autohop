//
//  DownloadCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 6 AppState decomposition owner for download runtime state and policy.
//  It owns the NWPathMonitor, current network path, three-slot FIFO accounting,
//  progress/activity projections, automatic-failure cooldowns, bounded watchdog
//  attempts, superseded rolling-feed cancellation identity, and orphan-facing
//  activity state. AppState retains compatibility commands while their bodies
//  execute against this single state owner.
//
//  Automatic provenance remains durable in AutoDownloadIntentStore. This type
//  does not decide feed eligibility, queue order, Play Instant policy, or
//  listening-history outcomes.
//

import Combine
import Foundation
import Network

@MainActor
final class DownloadCoordinator: ObservableObject {
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
    private(set) var latestNetworkPath: NWPath?
    private var cancellables = Set<AnyCancellable>()

    // Internal access is limited to the AppState compatibility façade during
    // Stages 6–8. These values have one storage owner and are not published.
    var pendingQueue: [PendingDownload] = []
    var activeCount = 0
    var failureBackoff: [String: (failures: Int, retryAfter: Date)] = [:]
    var watchdogRetryCounts: [UUID: Int] = [:]
    var supersededCancellationIDs = Set<UUID>()
    var isDrainingAutomaticIntents = false

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
            }
        }
        networkMonitor.start(
            queue: DispatchQueue(label: "au.com.autohop.networkmonitor", qos: .utility)
        )
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
