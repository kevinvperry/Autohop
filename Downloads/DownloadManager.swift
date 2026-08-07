import Foundation
#if canImport(UIKit)
import UIKit
#endif

// AI CONTEXT — Downloads/DownloadManager.swift
// Background URLSession download layer ("com.autohop.downloads" identifier),
// continuation-based: download() suspends until the URLSession delegate fires.
// All mutable maps are accessed on the main queue only (no locks). The
// duplicate/zombie guard keys live tasks by episodeID (primary) and by media URL
// (secondary, for the same episode re-fetched with a new UUID). taskIDByMediaURL
// is [URL: Set<Int>] (B6) so two episodes that share one enclosure URL can't
// clobber each other's entry on insert or over-remove on completion —
// removeMediaURLTask(_:for:) drops only the finishing task; download() blocks if
// ANY suspected task for the URL/episode is still alive, else clears stale entries
// and starts fresh.
// HANDLES: resume-data save/restore on pause/cancel/failure; a task-aware stall
// phase-aware watchdog: pre-response/zero-byte work is classified as a first-byte
// wait and receives a separate deadline (60 s while active, four minutes once
// backgrounded); only a RUNNING task that has
// begun receiving payload bytes can hit the 10-minute active-transfer stall rule.
// Suspended tasks, connectivity waits,
// process suspension gaps, and out-of-process byte advances reset/hold the clock so
// iOS scheduling is never mistaken for a network stall; progress throttling (≤1/s/task);
// background relaunch completion (onBackgroundDownloadCompleted, when the app
// was killed and iOS relaunched it to deliver a finished download — there is
// no live continuation in that case); file storage under the app's Downloads
// directory with deterministic names (expectedLocalFileURL). The Downloads
// directory is marked isExcludedFromBackup (ASSESSMENT N1) and the directory plus
// completed media files are marked available-after-first-unlock so CarPlay can
// start downloaded playback after the phone locks in the car. Media deliberately
// stays in Application Support (NOT Caches) so iOS never purges it out from under
// the download-first queue.
// TERMINAL WATCHDOG CLEANUP: cancelDownload() clears both URLSession identity maps
// and every per-episode watchdog clock/set even when no live task remains. This is
// required after retry exhaustion; otherwise the two-minute timer repeatedly
// rediscovers an orphaned progress timestamp and emits another cancellation callback.
// FIRST-BYTE DEADLINES: deadlines are anchored to task creation/resume. Active-app
// attempts use 60 seconds; attempts created or first evaluated while the app is
// inactive receive up to four minutes because background URLSession delegate
// delivery may be delayed. Returning to foreground never shortens that generation.
// Lifecycle, network-path, BGTask-entry, and URLSession delegate events may request
// an immediate evaluation; active-transfer clocks separately receive suspension
// grace because their delegate progress can be withheld while the process is frozen.
// CONCURRENCY CAP (3) AND NETWORK POLICY (WiFi/cellular toggles) ARE NOT
// ENFORCED HERE — AppState gates calls to download().
public enum DownloadExecutionMode: Equatable {
    case durableBackground
    case activeRuntimeFallback
}

public protocol DownloadManaging: AnyObject {
    var backgroundEventsCompletionHandler: (() -> Void)? { get set }
    /// `(episodeID, subscriptionID, localFileURL)` — called when a download completes
    /// after a background app relaunch (no live continuation available).
    var onBackgroundDownloadCompleted: ((UUID, UUID, URL) -> Void)? { get set }
    /// `(episodeID, fractionCompleted, bytesWritten, bytesExpected)` — called on the main queue while downloading.
    var onProgressUpdate: ((UUID, Double, Int64, Int64) -> Void)? { get set }
    /// Called on the main queue when the watchdog cancels a stalled download. The caller should
    /// schedule a retry. Resume data has already been saved; the next `download()` call will use it.
    var onWatchdogCancelled: ((UUID) -> Void)? { get set }
    func download(_ episode: Episode, allowsCellular: Bool) async throws -> URL
    /// Uses an ordinary in-process URLSession only for a bounded recovery attempt
    /// while foreground UI or active audio keeps Autohop executable. Test doubles
    /// inherit the default implementation and continue using the durable session.
    func download(
        _ episode: Episode,
        allowsCellular: Bool,
        executionMode: DownloadExecutionMode
    ) async throws -> URL
    func pauseDownload(episodeID: UUID)
    func cancelDownload(episodeID: UUID)
    /// Discards any stored resume data for the episode so the next download call starts fresh.
    func clearResumeData(episodeID: UUID)
    func expectedLocalFileURL(for episode: Episode) throws -> URL
    func localFileURL(fileName: String) throws -> URL
    func storeDownloadedFile(from sourceURL: URL, episode: Episode) throws -> URL
    func deleteLocalFile(for episode: Episode) async throws
    /// Returns the set of episode IDs that are tracked as actively downloading in URLSession.
    /// Used at startup to reconcile persisted `.downloading` state against live tasks.
    func activeDownloadEpisodeIDs() async -> Set<UUID>
    /// Clears shared URLSession cache/credential state after Autohop observes
    /// zero-byte stalls across several unrelated hosts. This deliberately does
    /// not invalidate the background session or cancel healthy live tasks.
    func recoverFromSharedStall(reason: String)
    /// Requests an immediate absolute-deadline check. Default protocol behavior is
    /// a no-op so lightweight test doubles do not need watchdog machinery.
    func reevaluateWatchdog(reason: String)
    func configureActiveExecutionWindow(_ provider: @escaping () -> Bool)
}

public extension DownloadManaging {
    func download(
        _ episode: Episode,
        allowsCellular: Bool,
        executionMode: DownloadExecutionMode
    ) async throws -> URL {
        try await download(episode, allowsCellular: allowsCellular)
    }
    func reevaluateWatchdog(reason: String) {}
    func recoverFromSharedStall(reason: String) {}
    func configureActiveExecutionWindow(_ provider: @escaping () -> Bool) {}
}

public final class DownloadManager: NSObject, DownloadManaging {

    public static let backgroundSessionIdentifier = "com.autohop.downloads"

    private let logger = AppLogger.shared
    private var session: URLSession!
    private var activeRuntimeSession: URLSession!
    private var activeRuntimeTasks: [UUID: URLSessionDownloadTask] = [:]
    // Accessed only on the main queue — no separate lock needed.
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    // Map task → episode ID so progress callbacks know which episode to report.
    private var episodeIDByTask: [Int: UUID] = [:]
    private var taskIDByEpisodeID: [UUID: Int] = [:]
    // Keyed by media URL → the set of in-flight task IDs targeting that URL. A set
    // (not a single Int) so two episodes that happen to share one enclosure URL
    // (re-publishes, shared trailers) don't clobber each other's entry on insert
    // or over-remove on completion (B6). Almost always holds exactly one ID.
    private var taskIDByMediaURL: [URL: Set<Int>] = [:]
    private var resumeDataByEpisodeID: [UUID: Data] = [:]
    private var mediaURLByEpisodeID: [UUID: URL] = [:]
    private var lastLoggedProgressBucketByEpisodeID: [UUID: Int] = [:]
    private var intentionallyPausedEpisodeIDs = Set<UUID>()
    private var intentionallyCancelledEpisodeIDs = Set<UUID>()
    private var watchdogStalledEpisodeIDs = Set<UUID>()
    // Progress throttle: only dispatch onProgressUpdate at most once per second per task.
    private var progressLastDispatchedAt: [Int: Date] = [:]
    // Watchdog: track last time each episode received any progress bytes.
    private var progressLastReceivedAt: [UUID: Date] = [:]
    private var progressLastObservedBytes: [UUID: Int64] = [:]
    /// Creation/resume time is intentionally separate from last byte progress. A
    /// background URLSession task can remain `running` while DNS/CDN/server work is
    /// still waiting for its first response byte; that phase is not an active stall.
    private var taskStartedAtByEpisodeID: [UUID: Date] = [:]
    private var firstByteDeadlineByEpisodeID: [UUID: Date] = [:]
    /// One independently scheduled deadline per transfer attempt. The periodic
    /// watchdog remains a fallback/diagnostic sampler, but no longer determines
    /// when an executable process notices an expired first-byte wait.
    private var firstByteDeadlineWorkItems: [UUID: DispatchWorkItem] = [:]
    private var watchdogEvaluationInFlight = false
    private var watchdogCancellationClaimedTaskIDs = Set<Int>()
    private var lastFirstByteDiagnosticAtByEpisodeID: [UUID: Date] = [:]
    private var connectivityWaitingTaskIDs = Set<Int>()
    private var downloadWatchdogTimer: Timer?
    private var activeExecutionWindowProvider: (() -> Bool)?
    /// Wall-clock time of the last watchdog tick. The timer only fires while the app is
    /// running, so a gap far larger than `watchdogInterval` means the app was suspended
    /// in between — during which a background URLSession keeps transferring out-of-process
    /// but delivers no progress callbacks, staling `progressLastReceivedAt` through no
    /// fault of the download. Used to grant a grace window instead of false-cancelling.
    private var lastWatchdogTickAt = Date()
    private let progressThrottleInterval: TimeInterval = 1.0
    private let downloadStallThreshold: TimeInterval = 10 * 60
    /// A foreground download that cannot produce one payload byte within a minute
    /// releases its slot and enters the existing bounded retry policy. Inactive-app
    /// background transfers receive four minutes so delayed delegate delivery does
    /// not manufacture retry storms.
    private let foregroundFirstByteWaitThreshold: TimeInterval = 60
    private let backgroundFirstByteWaitThreshold: TimeInterval = 4 * 60
    private let firstByteDiagnosticInterval: TimeInterval = 30
    /// A short tick bounds deadline overrun to roughly 15 seconds while the app
    /// is executable. Absolute task start times survive suspension and are
    /// checked immediately by the existing lifecycle/network wake hooks.
    private let watchdogInterval: TimeInterval = 15

    private let fileManager: FileManager
    private let downloadDirectoryOverride: URL?
    private let resumeDataDirectory: URL?

    public var backgroundEventsCompletionHandler: (() -> Void)?
    public var onBackgroundDownloadCompleted: ((UUID, UUID, URL) -> Void)?
    public var onProgressUpdate: ((UUID, Double, Int64, Int64) -> Void)?
    public var onWatchdogCancelled: ((UUID) -> Void)?

    // MARK: - Init

    public init(fileManager: FileManager = .default, downloadDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.downloadDirectoryOverride = downloadDirectory
        self.resumeDataDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appendingPathComponent("Autohop/download-resume-data", isDirectory: true)
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        PodcastUserAgent.configure(config)
        #if os(iOS) || os(watchOS)
        config.sessionSendsLaunchEvents = true
        #endif
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let activeConfig = URLSessionConfiguration.default
        activeConfig.waitsForConnectivity = true
        activeConfig.allowsExpensiveNetworkAccess = true
        activeConfig.allowsConstrainedNetworkAccess = true
        PodcastUserAgent.configure(activeConfig)
        activeRuntimeSession = URLSession(configuration: activeConfig)
        rebuildTaskMapsFromLiveSession()
        startDownloadWatchdog()
    }

    /// Reconnects in-memory task maps from URLSession tasks that survived a previous app run.
    /// Must be called after `session` is assigned. Runs async but maps are populated on main queue
    /// before any delegate callbacks arrive.
    private func rebuildTaskMapsFromLiveSession() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in tasks {
                    guard let meta = self.decodeTaskMeta(task.taskDescription) else { continue }
                    self.episodeIDByTask[task.taskIdentifier] = meta.episodeID
                    self.taskIDByEpisodeID[meta.episodeID] = task.taskIdentifier
                    self.taskIDByMediaURL[meta.audioURL, default: []].insert(task.taskIdentifier)
                    self.mediaURLByEpisodeID[meta.episodeID] = meta.audioURL
                    let reconnectedAt = Date()
                    let attemptStartedAt = meta.startedAt ?? reconnectedAt
                    let firstByteThreshold =
                        self.effectiveFirstByteWaitThreshold
                    self.taskStartedAtByEpisodeID[meta.episodeID] = attemptStartedAt
                    self.firstByteDeadlineByEpisodeID[meta.episodeID] =
                        attemptStartedAt.addingTimeInterval(
                            firstByteThreshold
                        )
                    self.scheduleFirstByteDeadline(
                        episodeID: meta.episodeID,
                        taskID: task.taskIdentifier,
                        deadline: attemptStartedAt.addingTimeInterval(
                            firstByteThreshold
                        )
                    )
                    self.progressLastReceivedAt[meta.episodeID] = reconnectedAt
                    self.progressLastObservedBytes[meta.episodeID] = task.countOfBytesReceived
                    self.logger.info("download.taskReconnected", "Reconnected live task from previous session", metadata: [
                        "episodeID": meta.episodeID.uuidString,
                        "taskID": "\(task.taskIdentifier)"
                    ])
                }
            }
        }
    }

    // MARK: - DownloadManaging

    public func download(_ episode: Episode, allowsCellular: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                var suspectedTaskIDs = self.taskIDByMediaURL[episode.audioURL] ?? []
                if let byEpisode = self.taskIDByEpisodeID[episode.id] {
                    suspectedTaskIDs.insert(byEpisode)
                }

                guard !suspectedTaskIDs.isEmpty else {
                    // No in-memory map entry — safe to start immediately.
                    self.startDownloadTask(episode: episode, allowsCellular: allowsCellular, continuation: continuation)
                    return
                }

                // Map entry exists — verify a URLSession task is still alive before blocking.
                self.session.getAllTasks { [weak self] tasks in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let liveTaskIDs = Set(tasks.map(\.taskIdentifier))
                        if let aliveTaskID = suspectedTaskIDs.first(where: { liveTaskIDs.contains($0) }) {
                            self.logger.warning("download.duplicateBlocked", "Duplicate download request blocked", metadata: [
                                "episode": episode.title,
                                "episodeID": episode.id.uuidString,
                                "mediaURL": episode.audioURL.absoluteString,
                                "taskID": "\(aliveTaskID)"
                            ])
                            continuation.resume(throwing: DownloadError.duplicateDownload)
                        } else {
                            // Zombie: map entries exist but no live URLSession task remains. Clear
                            // stale state and start a fresh download.
                            self.logger.warning("download.zombieCleared", "Cleared zombie task entry; starting fresh download", metadata: [
                                "episode": episode.title,
                                "episodeID": episode.id.uuidString,
                                "staleTaskIDs": suspectedTaskIDs.map(String.init).joined(separator: ",")
                            ])
                            for staleTaskID in suspectedTaskIDs {
                                self.clearZombieMapEntries(taskID: staleTaskID, episodeID: episode.id, audioURL: episode.audioURL)
                            }
                            self.startDownloadTask(episode: episode, allowsCellular: allowsCellular, continuation: continuation)
                        }
                    }
                }
            }
        }
    }

    public func download(
        _ episode: Episode,
        allowsCellular: Bool,
        executionMode: DownloadExecutionMode
    ) async throws -> URL {
        guard executionMode == .activeRuntimeFallback else {
            return try await download(episode, allowsCellular: allowsCellular)
        }
        return try await downloadUsingActiveRuntimeSession(
            episode,
            allowsCellular: allowsCellular
        )
    }

    /// Recovery-only transfer path. It deliberately is not durable across process
    /// suspension, so callers may select it only while foreground UI or active
    /// audio supplies an execution window. The ordinary session avoids the
    /// background-session first-byte failure pattern measured in Log 23.
    private func downloadUsingActiveRuntimeSession(
        _ episode: Episode,
        allowsCellular: Bool
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DownloadError.cancelled)
                    return
                }
                guard self.activeRuntimeTasks[episode.id] == nil,
                      self.taskIDByEpisodeID[episode.id] == nil else {
                    continuation.resume(throwing: DownloadError.duplicateDownload)
                    return
                }

                var request = URLRequest(url: episode.audioURL)
                PodcastUserAgent.identify(&request)
                request.allowsCellularAccess = allowsCellular
                request.timeoutInterval = 90
                request.networkServiceType = episode.mediaKind == .video
                    ? .video : .responsiveData
                let startedAt = Date()
                let task = self.activeRuntimeSession.downloadTask(with: request) {
                    [weak self] temporaryURL, response, error in
                    guard let self else { return }
                    let result: Result<URL, Error>
                    if let error {
                        // Intentional pause/cancel sets are main-queue-owned and
                        // are classified below after returning to that queue.
                        result = .failure(error)
                    } else if let status = Self.rejectableHTTPStatus(of: response) {
                        result = .failure(DownloadError.httpStatus(status))
                    } else if let mime = Self.rejectableMIMEType(of: response) {
                        result = .failure(DownloadError.nonMediaContentType(mime))
                    } else if let temporaryURL {
                        do {
                            let values = try temporaryURL.resourceValues(
                                forKeys: [.fileSizeKey]
                            )
                            let bytes = Int64(values.fileSize ?? 0)
                            guard !Self.isImplausiblySmallDownload(
                                actualBytes: bytes,
                                expectedBytes: episode.fileSizeBytes
                            ) else {
                                throw DownloadError.incompleteDownload(
                                    actualBytes: bytes,
                                    expectedBytes: episode.fileSizeBytes
                                )
                            }
                            result = .success(
                                try self.storeDownloadedFile(
                                    from: temporaryURL,
                                    episode: episode
                                )
                            )
                        } catch {
                            result = .failure(error)
                        }
                    } else {
                        result = .failure(DownloadError.fileMoveFailed)
                    }
                    DispatchQueue.main.async {
                        self.activeRuntimeTasks.removeValue(forKey: episode.id)
                        let classifiedResult: Result<URL, Error>
                        if case .failure = result,
                           self.intentionallyCancelledEpisodeIDs.remove(
                            episode.id
                           ) != nil {
                            classifiedResult = .failure(DownloadError.cancelled)
                        } else if case .failure = result,
                                  self.intentionallyPausedEpisodeIDs.remove(
                                    episode.id
                                  ) != nil {
                            classifiedResult = .failure(DownloadError.paused)
                        } else {
                            classifiedResult = result
                        }
                        switch classifiedResult {
                        case .success(let url):
                            self.logger.info(
                                "download.activeRuntimeFallbackComplete",
                                "Active-runtime fallback download completed",
                                metadata: [
                                    "episodeID": episode.id.uuidString,
                                    "elapsedSeconds": String(
                                        format: "%.1f",
                                        Date().timeIntervalSince(startedAt)
                                    )
                                ]
                            )
                            continuation.resume(returning: url)
                        case .failure(let error):
                            self.logger.warning(
                                "download.activeRuntimeFallbackFailed",
                                "Active-runtime fallback download failed",
                                metadata: [
                                    "episodeID": episode.id.uuidString,
                                    "error": String(describing: error)
                                ]
                            )
                            continuation.resume(throwing: error)
                        }
                    }
                }
                self.activeRuntimeTasks[episode.id] = task
                self.logger.info(
                    "download.activeRuntimeFallbackStart",
                    "Starting recovery through the active-runtime URLSession",
                    metadata: [
                        "episode": episode.title,
                        "episodeID": episode.id.uuidString,
                        "mediaHost": episode.audioURL.host ?? "unknown"
                    ]
                )
                task.resume()
            }
        }
    }

    private func startDownloadTask(episode: Episode, allowsCellular: Bool, continuation: CheckedContinuation<URL, Error>) {
        let startedAt = Date()
        let firstByteThreshold = effectiveFirstByteWaitThreshold
        let task: URLSessionDownloadTask
        if let resumeData = takeResumeData(for: episode.id) {
            task = session.downloadTask(withResumeData: resumeData)
            logger.info("download.taskResumeData", "Resuming download from stored resume data", metadata: [
                "episode": episode.title,
                "episodeID": episode.id.uuidString
            ])
        } else {
            var request = URLRequest(url: episode.audioURL)
            PodcastUserAgent.identify(&request)
            request.allowsCellularAccess = allowsCellular
            request.networkServiceType = episode.mediaKind == .video ? .video : .responsiveData
            task = session.downloadTask(with: request)
        }
        task.taskDescription = encodeTaskMeta(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            audioURL: episode.audioURL,
            expectedBytes: episode.fileSizeBytes,
            startedAt: startedAt
        )
        continuations[task.taskIdentifier] = continuation
        episodeIDByTask[task.taskIdentifier] = episode.id
        taskIDByEpisodeID[episode.id] = task.taskIdentifier
        taskIDByMediaURL[episode.audioURL, default: []].insert(task.taskIdentifier)
        mediaURLByEpisodeID[episode.id] = episode.audioURL
        lastLoggedProgressBucketByEpisodeID[episode.id] = 0
        progressLastReceivedAt[episode.id] = startedAt
        taskStartedAtByEpisodeID[episode.id] = startedAt
        firstByteDeadlineByEpisodeID[episode.id] =
            startedAt.addingTimeInterval(firstByteThreshold)
        scheduleFirstByteDeadline(
            episodeID: episode.id,
            taskID: task.taskIdentifier,
            deadline: startedAt.addingTimeInterval(firstByteThreshold)
        )
        progressLastObservedBytes[episode.id] = task.countOfBytesReceived
        logger.info("download.taskResume", "Download task resumed", metadata: [
            "episode": episode.title,
            "episodeID": episode.id.uuidString,
            "taskID": "\(task.taskIdentifier)",
            "mediaKind": episode.mediaKind.rawValue,
            "expectedBytes": episode.fileSizeBytes.map(String.init) ?? "unknown",
            "firstByteDeadlineSeconds": "\(Int(firstByteThreshold))",
            "mediaURL": episode.audioURL.absoluteString
        ])
        task.resume()
    }

    private func clearZombieMapEntries(taskID: Int, episodeID: UUID, audioURL: URL) {
        episodeIDByTask.removeValue(forKey: taskID)
        taskIDByEpisodeID.removeValue(forKey: episodeID)
        removeMediaURLTask(taskID, for: audioURL)
        mediaURLByEpisodeID.removeValue(forKey: episodeID)
        lastLoggedProgressBucketByEpisodeID.removeValue(forKey: episodeID)
        progressLastDispatchedAt.removeValue(forKey: taskID)
        progressLastReceivedAt.removeValue(forKey: episodeID)
        progressLastObservedBytes.removeValue(forKey: episodeID)
        taskStartedAtByEpisodeID.removeValue(forKey: episodeID)
        firstByteDeadlineByEpisodeID.removeValue(forKey: episodeID)
        cancelFirstByteDeadline(for: episodeID)
        lastFirstByteDiagnosticAtByEpisodeID.removeValue(forKey: episodeID)
        connectivityWaitingTaskIDs.remove(taskID)
    }

    /// Removes a single task ID from the media-URL → task-IDs map, dropping the
    /// URL key entirely once no tasks remain for it. Keeps a shared-URL sibling's
    /// entry intact (B6).
    private func removeMediaURLTask(_ taskID: Int, for url: URL) {
        taskIDByMediaURL[url]?.remove(taskID)
        if taskIDByMediaURL[url]?.isEmpty == true {
            taskIDByMediaURL.removeValue(forKey: url)
        }
    }

    public func pauseDownload(episodeID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let task = self.activeRuntimeTasks.removeValue(forKey: episodeID) {
                self.intentionallyPausedEpisodeIDs.insert(episodeID)
                task.cancel()
                self.logger.info(
                    "download.activeRuntimeFallbackPaused",
                    "Active-runtime fallback cancelled for a user pause",
                    metadata: ["episodeID": episodeID.uuidString]
                )
                return
            }
            guard let taskID = self.taskIDByEpisodeID[episodeID] else { return }
            self.intentionallyPausedEpisodeIDs.insert(episodeID)
            self.session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == taskID }) as? URLSessionDownloadTask else { return }
                task.cancel { [weak self] resumeData in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let resumeData {
                            self.storeResumeData(resumeData, for: episodeID)
                        }
                        self.logger.info("download.pause", "Download paused", metadata: [
                            "episodeID": episodeID.uuidString,
                            "taskID": "\(taskID)",
                            "hasResumeData": "\(resumeData != nil)"
                        ])
                    }
                }
            }
        }
    }

    public func cancelDownload(episodeID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let activeTask = self.activeRuntimeTasks.removeValue(
                forKey: episodeID
            ) {
                self.intentionallyCancelledEpisodeIDs.insert(episodeID)
                activeTask.cancel()
            }
            // Always purge stale map entries so the episode can be re-downloaded regardless of
            // whether a live URLSession task exists (e.g. after a force-kill). Capture the task ID
            // first — we still need it to cancel the live task below.
            let removedTaskID = self.taskIDByEpisodeID.removeValue(forKey: episodeID)
            if let removedTaskID {
                self.episodeIDByTask.removeValue(forKey: removedTaskID)
            }
            if let url = self.mediaURLByEpisodeID.removeValue(forKey: episodeID), let removedTaskID {
                self.removeMediaURLTask(removedTaskID, for: url)
            }
            self.deleteResumeData(for: episodeID)
            self.lastLoggedProgressBucketByEpisodeID.removeValue(forKey: episodeID)
            // A watchdog-cancelled task may already have disappeared from the
            // URLSession maps while its progress clock remains. Retire all
            // episode-scoped watchdog state unconditionally so retry exhaustion
            // is a true terminal state rather than a callback every two minutes.
            self.progressLastReceivedAt.removeValue(forKey: episodeID)
            self.progressLastObservedBytes.removeValue(forKey: episodeID)
            self.taskStartedAtByEpisodeID.removeValue(forKey: episodeID)
            self.firstByteDeadlineByEpisodeID.removeValue(forKey: episodeID)
            self.cancelFirstByteDeadline(for: episodeID)
            self.lastFirstByteDiagnosticAtByEpisodeID.removeValue(forKey: episodeID)
            self.watchdogStalledEpisodeIDs.remove(episodeID)
            self.intentionallyPausedEpisodeIDs.remove(episodeID)

            guard let taskID = removedTaskID else {
                // No live task — map entries already cleared above; nothing more to cancel.
                self.logger.info("download.cancelNoTask", "Cancel requested but no live task found — maps cleared", metadata: [
                    "episodeID": episodeID.uuidString
                ])
                return
            }
            self.intentionallyCancelledEpisodeIDs.insert(episodeID)
            self.session.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
                DispatchQueue.main.async {
                    self.logger.info("download.cancel", "Download cancelled", metadata: [
                        "episodeID": episodeID.uuidString,
                        "taskID": "\(taskID)"
                    ])
                }
            }
        }
    }

    public func clearResumeData(episodeID: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.deleteResumeData(for: episodeID)
        }
    }

    public func storeDownloadedFile(from sourceURL: URL, episode: Episode) throws -> URL {
        let destination = try expectedLocalFileURL(for: episode)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: destination)
            LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: destination, fileManager: fileManager)
            logger.info("download.fileStored", "Downloaded file stored", metadata: [
                "episodeID": episode.id.uuidString,
                "file": destination.lastPathComponent
            ])
        } catch {
            logger.error("download.fileMoveFailed", "Could not store downloaded file", metadata: [
                "episodeID": episode.id.uuidString,
                "error": String(describing: error)
            ])
            throw DownloadError.fileMoveFailed
        }
        return destination
    }

    public func expectedLocalFileURL(for episode: Episode) throws -> URL {
        try downloadsDirectory()
            .appendingPathComponent(episode.id.uuidString)
            .appendingPathExtension(fileExtension(for: episode.audioURL))
    }

    public func localFileURL(fileName: String) throws -> URL {
        try downloadsDirectory().appendingPathComponent(fileName)
    }

    public func deleteLocalFile(for episode: Episode) async throws {
        let candidates = [
            episode.localFileURL,
            episode.localFileName.flatMap { try? localFileURL(fileName: $0) },
            try? expectedLocalFileURL(for: episode)
        ].compactMap { $0 }

        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            logger.info("download.deleteLocalFile", "No local file to delete", metadata: [
                "episode": episode.title
            ])
            return
        }
        try fileManager.removeItem(at: url)
        logger.info("download.deleteLocalFile", "Local file deleted", metadata: [
            "episode": episode.title,
            "file": url.lastPathComponent
        ])
    }

    // MARK: - Private helpers

    private func downloadsDirectory() throws -> URL {
        if let override = downloadDirectoryOverride {
            try LockedDeviceFileAccess.createDirectory(override, fileManager: fileManager)
            return override
        }
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Autohop/Downloads", isDirectory: true)
        try LockedDeviceFileAccess.createDirectory(dir, fileManager: fileManager)
        // N1: keep re-downloadable media out of iCloud/device backups. Idempotent
        // and cheap (skips the write once the flag is already set), so it's safe to
        // re-apply on every resolve — and it self-heals if a restore ever clears it.
        excludeFromBackupIfNeeded(dir)
        return dir
    }

    /// Sets `isExcludedFromBackup` on a directory if it isn't already excluded, so
    /// large, trivially re-downloadable podcast media never bloats the user's iCloud
    /// Backup or device-to-device transfer (ASSESSMENT N1). Best-effort: a failure
    /// here only means the flag isn't set, never that a download fails.
    private func excludeFromBackupIfNeeded(_ url: URL) {
        let current = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        guard current != true else { return }
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension
        return ext.isEmpty ? "audio" : ext
    }

    // MARK: - Task metadata

    private struct TaskMeta: Codable {
        var episodeID: UUID
        var subscriptionID: UUID
        var audioURL: URL
        // Feed-declared enclosure length, used to sanity-check the completed transfer size.
        // Optional + decoded with `try?` so descriptions written by older builds still decode.
        var expectedBytes: Int64?
        /// Optional for backward compatibility with task descriptions written by
        /// builds before absolute watchdog deadlines were persisted.
        var startedAt: Date?
    }

    private func encodeTaskMeta(
        episodeID: UUID,
        subscriptionID: UUID,
        audioURL: URL,
        expectedBytes: Int64?,
        startedAt: Date
    ) -> String? {
        guard let data = try? JSONEncoder().encode(
            TaskMeta(
                episodeID: episodeID,
                subscriptionID: subscriptionID,
                audioURL: audioURL,
                expectedBytes: expectedBytes,
                startedAt: startedAt
            )
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeTaskMeta(_ description: String?) -> TaskMeta? {
        guard let description, let data = description.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskMeta.self, from: data)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self, let episodeID = self.episodeIDByTask[taskID] else { return }
            let now = Date()
            let previousBytes =
                self.progressLastObservedBytes[episodeID] ?? 0
            self.progressLastReceivedAt[episodeID] = now
            self.progressLastObservedBytes[episodeID] = totalBytesWritten
            if totalBytesWritten > 0 {
                self.firstByteDeadlineByEpisodeID.removeValue(
                    forKey: episodeID
                )
                self.cancelFirstByteDeadline(for: episodeID)
                if previousBytes <= 0 {
                    self.logger.info(
                        "download.firstByte",
                        "Download delivered its first payload bytes",
                        metadata: [
                            "episodeID": episodeID.uuidString,
                            "taskID": "\(taskID)",
                            "bytesWritten": "\(totalBytesWritten)",
                            "taskToFirstByteSeconds": String(
                                format: "%.1f",
                                now.timeIntervalSince(
                                    self.taskStartedAtByEpisodeID[episodeID]
                                        ?? now
                                )
                            )
                        ]
                    )
                }
            }
            self.connectivityWaitingTaskIDs.remove(taskID)
            // Unknown Content-Length is still proof that active transfer began.
            // It cannot drive a fraction bar, but it must move the watchdog out
            // of first-byte classification.
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let shouldDispatch = self.progressLastDispatchedAt[taskID]
                .map { now.timeIntervalSince($0) >= self.progressThrottleInterval } ?? true
            if shouldDispatch {
                self.progressLastDispatchedAt[taskID] = now
                self.onProgressUpdate?(episodeID, fraction, totalBytesWritten, totalBytesExpectedToWrite)
            }

            // AI CONTEXT — UI progress remains throttled independently above.
            // Persist only quarter milestones so a normal download contributes
            // four progress records rather than ten; lifecycle, watchdog, and
            // failure events retain their existing full diagnostic detail.
            let bucket = Int((fraction * 4).rounded(.down))
            let lastBucket = self.lastLoggedProgressBucketByEpisodeID[episodeID] ?? 0
            if bucket > lastBucket {
                self.lastLoggedProgressBucketByEpisodeID[episodeID] = bucket
                self.logger.info("download.progress", "Download progress", metadata: [
                    "episodeID": episodeID.uuidString,
                    "progress": "\(bucket * 25)%",
                    "bytesWritten": "\(totalBytesWritten)",
                    "bytesExpected": "\(totalBytesExpectedToWrite)",
                    "taskID": "\(taskID)"
                ])
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let meta = decodeTaskMeta(downloadTask.taskDescription)
        let episodeID = meta?.episodeID ?? UUID()
        let audioURL  = meta?.audioURL
            ?? downloadTask.currentRequest?.url
            ?? URL(string: "https://placeholder.invalid")!

        // Validate the HTTP response before storing anything. A background download task still
        // delivers a body to didFinishDownloadingTo on 4xx/5xx (an HTML error/login/captive-portal
        // page), which must never be stored as episode media and marked downloaded.
        if let status = Self.rejectableHTTPStatus(of: downloadTask.response) {
            try? fileManager.removeItem(at: location)
            let taskID = downloadTask.taskIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearTaskTracking(taskID: taskID)
                self.logger.error("download.httpError", "Download rejected: non-success HTTP status", metadata: [
                    "taskID": "\(taskID)",
                    "episodeID": episodeID.uuidString,
                    "status": "\(status)"
                ])
                self.continuations[taskID]?.resume(throwing: DownloadError.httpStatus(status))
                self.continuations.removeValue(forKey: taskID)
            }
            return
        }

        // Reject obvious non-media content types — a 200 can still deliver a (possibly large) HTML
        // captive-portal/error page that passes the size check but must never be stored as media.
        if let mimeType = Self.rejectableMIMEType(of: downloadTask.response) {
            try? fileManager.removeItem(at: location)
            let taskID = downloadTask.taskIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearTaskTracking(taskID: taskID)
                self.logger.error("download.nonMedia", "Download rejected: non-media content type", metadata: [
                    "taskID": "\(taskID)",
                    "episodeID": episodeID.uuidString,
                    "mimeType": mimeType
                ])
                self.continuations[taskID]?.resume(throwing: DownloadError.nonMediaContentType(mimeType))
                self.continuations.removeValue(forKey: taskID)
            }
            return
        }

        // Reject implausibly small bodies — a 200 response can still deliver a tiny error/placeholder
        // body (e.g. 17 bytes where the feed declared ~30 MB) that must not be stored as media.
        let actualBytes = ((try? fileManager.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if Self.isImplausiblySmallDownload(actualBytes: actualBytes, expectedBytes: meta?.expectedBytes) {
            try? fileManager.removeItem(at: location)
            let taskID = downloadTask.taskIdentifier
            let expected = meta?.expectedBytes
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearTaskTracking(taskID: taskID)
                self.logger.error("download.tooSmall", "Download rejected: body too small to be valid media", metadata: [
                    "taskID": "\(taskID)",
                    "episodeID": episodeID.uuidString,
                    "actualBytes": "\(actualBytes)",
                    "expectedBytes": expected.map(String.init) ?? "unknown"
                ])
                self.continuations[taskID]?.resume(throwing: DownloadError.incompleteDownload(actualBytes: actualBytes, expectedBytes: expected))
                self.continuations.removeValue(forKey: taskID)
            }
            return
        }

        let placeholder = Episode(
            id: episodeID,
            subscriptionID: meta?.subscriptionID ?? UUID(),
            guid: episodeID.uuidString,
            title: "",
            audioURL: audioURL
        )

        // Move the file synchronously — location is only valid for the duration of this method.
        let moveResult = Result { try storeDownloadedFile(from: location, episode: placeholder) }

        let taskID = downloadTask.taskIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearTaskTracking(taskID: taskID)
            switch moveResult {
            case .success(let storedURL):
                self.logger.info("download.taskComplete", "Download task completed", metadata: [
                    "taskID": "\(taskID)",
                    "file": storedURL.lastPathComponent
                ])
                if let continuation = self.continuations[taskID] {
                    continuation.resume(returning: storedURL)
                    self.continuations.removeValue(forKey: taskID)
                } else if let meta {
                    self.onBackgroundDownloadCompleted?(meta.episodeID, meta.subscriptionID, storedURL)
                }
            case .failure(let error):
                self.logger.error("download.taskFailed", "Download task failed while storing file", metadata: [
                    "taskID": "\(taskID)",
                    "error": String(describing: error)
                ])
                self.continuations[taskID]?.resume(throwing: error)
                self.continuations.removeValue(forKey: taskID)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let episodeID = self.episodeIDByTask[taskID]
            self.clearTaskTracking(taskID: taskID)
            let nsError = error as NSError
            let isPauseOrCancel = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            if isPauseOrCancel, let episodeID, self.watchdogStalledEpisodeIDs.remove(episodeID) != nil {
                self.clearTaskTracking(taskID: taskID)
                self.logger.info("download.watchdogPaused", "Download paused by stall watchdog — will retry", metadata: [
                    "taskID": "\(taskID)",
                    "episodeID": episodeID.uuidString,
                    "hasResumeData": "\(self.resumeDataByEpisodeID[episodeID] != nil)"
                ])
                self.continuations[taskID]?.resume(throwing: DownloadError.paused)
                self.continuations.removeValue(forKey: taskID)
                self.onWatchdogCancelled?(episodeID)
                return
            }
            if isPauseOrCancel, let episodeID, self.intentionallyCancelledEpisodeIDs.remove(episodeID) != nil {
                self.logger.info("download.taskCancelled", "Download task cancelled", metadata: [
                    "taskID": "\(taskID)",
                    "episodeID": episodeID.uuidString
                ])
                self.continuations[taskID]?.resume(throwing: DownloadError.cancelled)
                self.continuations.removeValue(forKey: taskID)
                return
            }
            if isPauseOrCancel {
                if let episodeID {
                    self.intentionallyPausedEpisodeIDs.remove(episodeID)
                }
                self.logger.info("download.taskCancelled", "Download task cancelled or paused", metadata: [
                    "taskID": "\(taskID)",
                    "episodeID": episodeID?.uuidString ?? "unknown"
                ])
                self.continuations[taskID]?.resume(throwing: DownloadError.paused)
                self.continuations.removeValue(forKey: taskID)
                return
            }
            self.logger.error("download.taskError", "Download task completed with error", metadata: [
                "taskID": "\(taskID)",
                "error": String(describing: error)
            ])
            self.continuations[taskID]?.resume(throwing: error)
            self.continuations.removeValue(forKey: taskID)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            // alwaysPersist: fires on a background-download wake, before AppState enables
            // diagnostics, so without it this "iOS finished handing us downloads" marker
            // is silently dropped (as app.launch was).
            self?.logger.info("download.backgroundEventsFinished", "Background download events finished", alwaysPersist: true)
            self?.backgroundEventsCompletionHandler?()
            self?.backgroundEventsCompletionHandler = nil
        }
    }
}

public enum DownloadError: Error, Equatable {
    case fileMoveFailed
    case duplicateDownload
    case paused
    case cancelled
    /// The host returned a non-success HTTP status (e.g. 404/500). The delivered body
    /// (often an HTML error/login page) must not be stored as episode media.
    case httpStatus(Int)
    /// The transfer completed with a status 200 but the body is implausibly small for audio media
    /// (e.g. a 17-byte error/placeholder body where the feed declared ~30 MB). Treated as a
    /// retryable failure rather than a successful download.
    case incompleteDownload(actualBytes: Int64, expectedBytes: Int64?)
    /// The host returned a 200 with an obvious non-media content type (e.g. `text/html` —
    /// a captive-portal or error page large enough to slip past the size check). Must not be
    /// stored as episode media.
    case nonMediaContentType(String)
}

extension DownloadManager {
    // Public because it satisfies a DownloadManaging protocol requirement.
    public func activeDownloadEpisodeIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { continuation.resume(returning: []); return }
                    // Decode the episode ID straight from each task's taskDescription rather than the
                    // in-memory episodeIDByTask map: that map is rebuilt asynchronously after init
                    // (rebuildTaskMapsFromLiveSession), so at startup it may still be empty when
                    // AppState reconciles. taskDescription is set on the task itself and is always
                    // authoritative, avoiding a race that would mark live downloads as failed.
                    let durableIDs = Set(tasks.compactMap {
                        self.decodeTaskMeta($0.taskDescription)?.episodeID
                    })
                    let ids = durableIDs.union(self.activeRuntimeTasks.keys)
                    continuation.resume(returning: ids)
                }
            }
        }
    }

    public func recoverFromSharedStall(reason: String) {
        logger.warning(
            "download.sessionRecoveryRequested",
            "Resetting shared URLSession state after cross-host zero-byte stalls",
            metadata: ["reason": reason]
        )
        session.reset { [weak self] in
            self?.logger.info(
                "download.sessionRecoveryCompleted",
                "Shared URLSession cache and credential state reset",
                metadata: ["reason": reason]
            )
        }
    }
}

extension DownloadManager {
    /// Returns the offending HTTP status code if `response` is a non-success HTTP response,
    /// or `nil` when it is acceptable (a 2xx HTTP response, or a non-HTTP response we cannot
    /// classify — e.g. `file://`, which is left to downstream playability checks).
    /// Internal so it can be exercised by unit/smoke tests without a live network.
    static func rejectableHTTPStatus(of response: URLResponse?) -> Int? {
        guard let http = response as? HTTPURLResponse else { return nil }
        return (200...299).contains(http.statusCode) ? nil : http.statusCode
    }

    /// Returns the offending MIME type when `response` reports an obvious non-media content type
    /// (an HTML/JSON/plain-text error or captive-portal page that a 200 + size check can't catch),
    /// or `nil` when the type is acceptable. We only reject a small set of clearly-textual types:
    /// `mimeType` is absent on `file://` and some hosts mislabel valid audio, so anything unknown
    /// or already `audio/`/`video/`/`application/octet-stream` is left to downstream playability.
    /// Internal so it can be exercised by unit/smoke tests without a live network.
    static func rejectableMIMEType(of response: URLResponse?) -> String? {
        guard let mime = response?.mimeType?.lowercased() else { return nil }
        let rejected = ["text/html", "text/plain", "application/json", "application/xml", "text/xml"]
        return rejected.contains(mime) ? mime : nil
    }

    /// True when a completed (HTTP-200) transfer is too small to be real audio media, so it must not
    /// be stored as a downloaded episode. Catches error/placeholder bodies a host returns with a 200
    /// (e.g. 17 bytes where the feed declared ~30 MB), which the status check alone cannot detect.
    /// Internal so it is unit-testable without a live download.
    static func isImplausiblySmallDownload(actualBytes: Int64, expectedBytes: Int64?) -> Bool {
        if actualBytes <= 0 { return true }
        if let expected = expectedBytes, expected > 0 {
            // Reject when we received far less than the feed declared: below 5% of expected, capped
            // at a 64 KB floor so genuinely small clips with a large declared size still pass.
            let floor = min(Int64(65536), expected / 20)
            return actualBytes < floor
        }
        // Expected size unknown — keep the bar very low so legitimate short clips are never rejected;
        // only obviously-tiny bodies (error pages) are caught.
        return actualBytes < 1024
    }
}

extension DownloadManager {
    func clearTaskTracking(taskID: Int) {
        watchdogCancellationClaimedTaskIDs.remove(taskID)
        guard let episodeID = episodeIDByTask.removeValue(forKey: taskID) else { return }
        taskIDByEpisodeID.removeValue(forKey: episodeID)
        if let mediaURL = mediaURLByEpisodeID.removeValue(forKey: episodeID) {
            removeMediaURLTask(taskID, for: mediaURL)
        }
        lastLoggedProgressBucketByEpisodeID.removeValue(forKey: episodeID)
        progressLastDispatchedAt.removeValue(forKey: taskID)
        progressLastReceivedAt.removeValue(forKey: episodeID)
        progressLastObservedBytes.removeValue(forKey: episodeID)
        taskStartedAtByEpisodeID.removeValue(forKey: episodeID)
        firstByteDeadlineByEpisodeID.removeValue(forKey: episodeID)
        cancelFirstByteDeadline(for: episodeID)
        lastFirstByteDiagnosticAtByEpisodeID.removeValue(forKey: episodeID)
        connectivityWaitingTaskIDs.remove(taskID)
    }

    // MARK: - Watchdog

    static func firstByteWaitThreshold(
        applicationIsActive: Bool,
        hasActiveExecutionWindow: Bool = false
    )
        -> TimeInterval {
        applicationIsActive || hasActiveExecutionWindow ? 60 : 4 * 60
    }

    /// Pure final-cancellation gate used after URLSession task enumeration and
    /// again after yielding one main-queue turn. It captures the race-sensitive
    /// invariants in one testable place: task generation must still match, no
    /// evaluator may already own cancellation, the task must still be running,
    /// neither live nor delegate-tracked payload bytes may have arrived, and
    /// connectivity waiting must be false.
    static func shouldCancelFirstByteTimeout(
        taskIdentityMatches: Bool,
        cancellationAlreadyClaimed: Bool,
        taskState: URLSessionTask.State,
        liveBytes: Int64,
        trackedBytes: Int64,
        waitingForConnectivity: Bool
    ) -> Bool {
        taskIdentityMatches
            && !cancellationAlreadyClaimed
            && taskState == .running
            && liveBytes == 0
            && trackedBytes == 0
            && !waitingForConnectivity
    }

    private var effectiveFirstByteWaitThreshold: TimeInterval {
        #if canImport(UIKit)
        return Self.firstByteWaitThreshold(
            applicationIsActive:
                UIApplication.shared.applicationState == .active,
            hasActiveExecutionWindow:
                activeExecutionWindowProvider?() ?? false
        )
        #else
        return backgroundFirstByteWaitThreshold
        #endif
    }

    public func configureActiveExecutionWindow(
        _ provider: @escaping () -> Bool
    ) {
        activeExecutionWindowProvider = provider
    }

    private func tightenFirstByteDeadlinesForActiveExecutionIfNeeded(
        now: Date
    ) {
        let threshold = effectiveFirstByteWaitThreshold
        guard threshold <= foregroundFirstByteWaitThreshold else { return }
        for (episodeID, startedAt) in taskStartedAtByEpisodeID
        where (progressLastObservedBytes[episodeID] ?? 0) == 0 {
            let tightened = startedAt.addingTimeInterval(threshold)
            guard tightened < (firstByteDeadlineByEpisodeID[episodeID] ?? .distantFuture),
                  let taskID = taskIDByEpisodeID[episodeID] else {
                continue
            }
            firstByteDeadlineByEpisodeID[episodeID] = tightened
            scheduleFirstByteDeadline(
                episodeID: episodeID,
                taskID: taskID,
                deadline: tightened
            )
            logger.info(
                "download.watchdogFirstByteEscalated",
                "Shortened first-byte wait after an executable runtime window became available",
                metadata: [
                    "episodeID": episodeID.uuidString,
                    "taskID": "\(taskID)",
                    "deadlineSeconds": "\(Int(threshold))",
                    "overdueSeconds":
                        "\(max(0, Int(now.timeIntervalSince(tightened))))"
                ]
            )
        }
    }

    /// Moving an already-started transfer into the background may extend its
    /// current generation's first-byte window, but returning to the foreground
    /// never shortens an extension already granted. This avoids converting
    /// delayed background URLSession delegate delivery into an immediate cancel
    /// as the user opens the app.
    private func extendFirstByteDeadlinesForBackgroundIfNeeded(now: Date) {
        let threshold = effectiveFirstByteWaitThreshold
        guard threshold > foregroundFirstByteWaitThreshold else { return }
        for (episodeID, startedAt) in taskStartedAtByEpisodeID
        where (progressLastObservedBytes[episodeID] ?? 0) == 0 {
            let extended = startedAt.addingTimeInterval(threshold)
            guard extended > (firstByteDeadlineByEpisodeID[episodeID] ?? .distantPast),
                  let taskID = taskIDByEpisodeID[episodeID] else {
                continue
            }
            firstByteDeadlineByEpisodeID[episodeID] = extended
            scheduleFirstByteDeadline(
                episodeID: episodeID,
                taskID: taskID,
                deadline: extended
            )
            logger.info(
                "download.watchdogFirstByteExtended",
                "Extended first-byte tolerance for background URLSession delivery",
                metadata: [
                    "episodeID": episodeID.uuidString,
                    "taskID": "\(taskID)",
                    "deadlineSeconds": "\(Int(threshold))",
                    "remainingSeconds":
                        "\(max(0, Int(extended.timeIntervalSince(now))))"
                ]
            )
        }
    }

    private func startDownloadWatchdog() {
        lastWatchdogTickAt = Date()
        downloadWatchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkForStalledDownloads(reason: "periodicTimer")
            }
        }
    }

    private func scheduleFirstByteDeadline(
        episodeID: UUID,
        taskID: Int,
        deadline: Date
    ) {
        cancelFirstByteDeadline(for: episodeID)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.taskIDByEpisodeID[episodeID] == taskID,
                  (self.progressLastObservedBytes[episodeID] ?? 0) == 0
            else { return }
            self.checkForStalledDownloads(reason: "attemptDeadline")
        }
        firstByteDeadlineWorkItems[episodeID] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow),
            execute: work
        )
    }

    private func cancelFirstByteDeadline(for episodeID: UUID) {
        firstByteDeadlineWorkItems.removeValue(forKey: episodeID)?.cancel()
    }

    public func reevaluateWatchdog(reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.checkForStalledDownloads(reason: reason)
        }
    }

    private func checkForStalledDownloads(reason: String) {
        guard !watchdogEvaluationInFlight else {
            logger.verbose(
                "download.watchdogEvaluationCoalesced",
                "Skipped overlapping watchdog evaluation",
                metadata: ["reason": reason]
            )
            return
        }
        let now = Date()
        extendFirstByteDeadlinesForBackgroundIfNeeded(now: now)
        tightenFirstByteDeadlinesForActiveExecutionIfNeeded(now: now)
        // The watchdog Timer only fires while the app is running. A gap far larger than
        // its interval means the app was suspended in between — during which a background
        // URLSession keeps transferring out-of-process but delivers no progress callbacks,
        // staling `progressLastReceivedAt` through no fault of the download. Grant every
        // active-transfer task a fresh progress window. First-byte work keeps its
        // generation deadline (including any inactive-app extension) and is
        // evaluated immediately on this same tick.
        let sinceLastTick = now.timeIntervalSince(lastWatchdogTickAt)
        lastWatchdogTickAt = now
        if sinceLastTick > watchdogInterval * 1.5 {
            let activeTransferIDs = progressLastReceivedAt.keys.filter {
                (progressLastObservedBytes[$0] ?? 0) > 0
            }
            if !activeTransferIDs.isEmpty {
                for episodeID in activeTransferIDs {
                    progressLastReceivedAt[episodeID] = now
                }
                logger.info("download.watchdogResumeGrace", "App resumed after suspension — reset download stall timers", metadata: [
                    "suspendedSeconds": "\(Int(sinceLastTick.rounded()))",
                    "activeTransfers": "\(activeTransferIDs.count)",
                    "firstByteWaitsPreserved": "\(max(0, progressLastReceivedAt.count - activeTransferIDs.count))",
                    "reason": reason
                ])
            }
        }
        // Inspect both phases. First-byte waits use their creation time; active
        // transfers use the most recent observed byte time.
        let candidates = progressLastReceivedAt.filter { episodeID, lastProgressAt in
            let hasPayload = (progressLastObservedBytes[episodeID] ?? 0) > 0
            if hasPayload {
                return now.timeIntervalSince(lastProgressAt) > downloadStallThreshold
            }
            let deadline = firstByteDeadlineByEpisodeID[episodeID]
                ?? (taskStartedAtByEpisodeID[episodeID] ?? lastProgressAt)
                    .addingTimeInterval(effectiveFirstByteWaitThreshold)
            let diagnosticDue = now.timeIntervalSince(
                lastFirstByteDiagnosticAtByEpisodeID[episodeID] ?? .distantPast
            ) >= firstByteDiagnosticInterval
            return now >= deadline || diagnosticDue
        }
        guard !candidates.isEmpty else { return }
        watchdogEvaluationInFlight = true
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.watchdogEvaluationInFlight = false }
                let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskIdentifier, $0) })
                for (episodeID, lastProgressAt) in candidates {
                    guard let taskID = self.taskIDByEpisodeID[episodeID],
                          let task = tasksByID[taskID] as? URLSessionDownloadTask else {
                        if let taskID = self.taskIDByEpisodeID[episodeID] {
                            self.continuations[taskID]?.resume(throwing: DownloadError.paused)
                            self.continuations.removeValue(forKey: taskID)
                            self.clearTaskTracking(taskID: taskID)
                        }
                        // No task can ever make this progress clock advance. Clear
                        // it before notifying the owner so this orphan generates
                        // exactly one retry decision.
                        self.progressLastReceivedAt.removeValue(forKey: episodeID)
                        self.progressLastObservedBytes.removeValue(forKey: episodeID)
                        self.taskStartedAtByEpisodeID.removeValue(forKey: episodeID)
                        self.firstByteDeadlineByEpisodeID.removeValue(forKey: episodeID)
                        self.cancelFirstByteDeadline(for: episodeID)
                        self.lastFirstByteDiagnosticAtByEpisodeID.removeValue(forKey: episodeID)
                        self.watchdogStalledEpisodeIDs.remove(episodeID)
                        self.onWatchdogCancelled?(episodeID)
                        continue
                    }
                    guard !self.watchdogCancellationClaimedTaskIDs
                        .contains(taskID) else { continue }

                    // Request bytes are not response payload. Only received bytes
                    // establish that the active-transfer phase has begun.
                    let observedBytes = task.countOfBytesReceived
                    let previousBytes = self.progressLastObservedBytes[episodeID] ?? 0
                    if observedBytes > previousBytes {
                        self.progressLastObservedBytes[episodeID] = observedBytes
                        self.progressLastReceivedAt[episodeID] = now
                        self.logger.info("download.watchdogProgressRecovered", "URLSession byte counter advanced without a recent delegate callback", metadata: [
                            "episodeID": episodeID.uuidString,
                            "taskID": "\(taskID)",
                            "bytesReceived": "\(observedBytes)"
                        ])
                        continue
                    }

                    let hasReceivedPayload = observedBytes > 0
                    let hasResponse = task.response != nil
                    if !hasReceivedPayload {
                        let startedAt = self.taskStartedAtByEpisodeID[episodeID] ?? lastProgressAt
                        let waitSeconds = now.timeIntervalSince(startedAt)
                        let deadline = self.firstByteDeadlineByEpisodeID[episodeID]
                            ?? startedAt.addingTimeInterval(
                                self.effectiveFirstByteWaitThreshold
                            )
                        guard now >= deadline else {
                            let lastDiagnostic = self.lastFirstByteDiagnosticAtByEpisodeID[episodeID] ?? .distantPast
                            if now.timeIntervalSince(lastDiagnostic) >= self.firstByteDiagnosticInterval {
                                self.lastFirstByteDiagnosticAtByEpisodeID[episodeID] = now
                                self.logger.info("download.watchdogFirstByteWaiting", "Download is still waiting for its first payload byte", metadata: [
                                    "episodeID": episodeID.uuidString,
                                    "taskID": "\(taskID)",
                                    "waitSeconds": "\(Int(waitSeconds))",
                                    "responseReceived": "\(hasResponse)",
                                    "taskState": Self.taskStateLabel(task.state),
                                    "deadlineRemainingSeconds": "\(max(0, Int(deadline.timeIntervalSince(now))))",
                                    "evaluationReason": reason
                                ])
                            }
                            continue
                        }

                        guard task.state == .running,
                              !self.connectivityWaitingTaskIDs.contains(taskID) else {
                            self.taskStartedAtByEpisodeID[episodeID] = now
                            continue
                        }
                        self.revalidateAndCancelFirstByteTimeout(
                            task: task,
                            episodeID: episodeID,
                            taskID: taskID,
                            startedAt: startedAt,
                            deadline: deadline,
                            evaluationReason: reason
                        )
                        continue
                    }

                    guard task.state == .running,
                          !self.connectivityWaitingTaskIDs.contains(taskID) else {
                        self.progressLastReceivedAt[episodeID] = now
                        self.logger.info("download.watchdogDeferred", "Download stall clock held because URLSession is not actively transferring", metadata: [
                            "episodeID": episodeID.uuidString,
                            "taskID": "\(taskID)",
                            "taskState": Self.taskStateLabel(task.state),
                            "waitingForConnectivity": "\(self.connectivityWaitingTaskIDs.contains(taskID))"
                        ])
                        continue
                    }

                    self.logger.warning("download.watchdog", "Cancelling confirmed running download with no byte progress", metadata: [
                        "episodeID": episodeID.uuidString,
                        "taskID": "\(taskID)",
                        "stallSeconds": "\(Int(now.timeIntervalSince(lastProgressAt)))",
                        "bytesReceived": "\(observedBytes)",
                        "bytesExpected": "\(task.countOfBytesExpectedToReceive)",
                        "taskState": Self.taskStateLabel(task.state)
                    ])
                    self.watchdogCancellationClaimedTaskIDs.insert(taskID)
                    self.watchdogStalledEpisodeIDs.insert(episodeID)
                    task.cancel(byProducingResumeData: { [weak self] resumeData in
                        DispatchQueue.main.async {
                            guard let self, let resumeData else { return }
                            self.storeResumeData(resumeData, for: episodeID)
                        }
                    })
                }
            }
        }
    }

    private func revalidateAndCancelFirstByteTimeout(
        task: URLSessionDownloadTask,
        episodeID: UUID,
        taskID: Int,
        startedAt: Date,
        deadline: Date,
        evaluationReason: String
    ) {
        // Give URLSession progress/completion callbacks already queued by the
        // same background wake one main-queue turn to settle first.
        DispatchQueue.main.async { [weak self, weak task] in
            guard let self, let task else { return }
            let liveBytes = task.countOfBytesReceived
            let trackedBytes = self.progressLastObservedBytes[episodeID] ?? 0
            guard Self.shouldCancelFirstByteTimeout(
                taskIdentityMatches:
                    self.taskIDByEpisodeID[episodeID] == taskID,
                cancellationAlreadyClaimed:
                    self.watchdogCancellationClaimedTaskIDs.contains(taskID),
                taskState: task.state,
                liveBytes: liveBytes,
                trackedBytes: trackedBytes,
                waitingForConnectivity:
                    self.connectivityWaitingTaskIDs.contains(taskID)
            ) else {
                if max(liveBytes, trackedBytes) > 0 {
                    self.progressLastObservedBytes[episodeID] =
                        max(liveBytes, trackedBytes)
                    self.progressLastReceivedAt[episodeID] = Date()
                    self.logger.info(
                        "download.watchdogProgressRecovered",
                        "Transfer advanced before final watchdog cancellation",
                        metadata: [
                            "episodeID": episodeID.uuidString,
                            "taskID": "\(taskID)",
                            "bytesReceived": "\(max(liveBytes, trackedBytes))",
                            "evaluationReason": evaluationReason
                        ]
                    )
                }
                return
            }
            self.watchdogCancellationClaimedTaskIDs.insert(taskID)
            let now = Date()
            self.logger.warning(
                "download.watchdogFirstByteTimeout",
                "Cancelling download that exceeded the first-byte deadline",
                metadata: [
                    "episodeID": episodeID.uuidString,
                    "taskID": "\(taskID)",
                    "waitSeconds": "\(Int(now.timeIntervalSince(startedAt)))",
                    "responseReceived": "\(task.response != nil)",
                    "taskState": Self.taskStateLabel(task.state),
                    "deadlineOverrunSeconds":
                        "\(max(0, Int(now.timeIntervalSince(deadline))))",
                    "evaluationReason": evaluationReason,
                    "host": task.originalRequest?.url?.host ?? "unknown"
                ]
            )
            self.watchdogStalledEpisodeIDs.insert(episodeID)
            task.cancel(byProducingResumeData: { [weak self] resumeData in
                DispatchQueue.main.async {
                    guard let self, let resumeData else { return }
                    self.storeResumeData(resumeData, for: episodeID)
                }
            })
        }
    }

    // MARK: - Durable resume data

    /// Background URLSession preserves live tasks itself. These small files
    /// cover the different case where a user explicitly pauses a multi-GB
    /// transfer and the app is then terminated before Resume is tapped.
    private func resumeDataURL(for episodeID: UUID) -> URL? {
        resumeDataDirectory?.appendingPathComponent("\(episodeID.uuidString).resume")
    }

    private func storeResumeData(_ data: Data, for episodeID: UUID) {
        resumeDataByEpisodeID[episodeID] = data
        guard let directory = resumeDataDirectory,
              let url = resumeDataURL(for: episodeID) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("download.resumeDataPersistFailed", "Could not persist resumable transfer state", metadata: [
                "episodeID": episodeID.uuidString,
                "error": String(describing: error)
            ])
        }
    }

    private func takeResumeData(for episodeID: UUID) -> Data? {
        if let inMemory = resumeDataByEpisodeID.removeValue(forKey: episodeID) {
            if let url = resumeDataURL(for: episodeID) { try? fileManager.removeItem(at: url) }
            return inMemory
        }
        guard let url = resumeDataURL(for: episodeID),
              let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.removeItem(at: url)
        return data
    }

    private func deleteResumeData(for episodeID: UUID) {
        resumeDataByEpisodeID.removeValue(forKey: episodeID)
        if let url = resumeDataURL(for: episodeID) { try? fileManager.removeItem(at: url) }
    }

    static func taskStateLabel(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: return "running"
        case .suspended: return "suspended"
        case .canceling: return "canceling"
        case .completed: return "completed"
        @unknown default: return "unknown"
        }
    }
}

extension DownloadManager {
    public func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectivityWaitingTaskIDs.insert(task.taskIdentifier)
            if let episodeID = self.episodeIDByTask[task.taskIdentifier] {
                let restartedAt = Date()
                let threshold = self.effectiveFirstByteWaitThreshold
                self.progressLastReceivedAt[episodeID] = restartedAt
                self.taskStartedAtByEpisodeID[episodeID] = restartedAt
                self.firstByteDeadlineByEpisodeID[episodeID] =
                    restartedAt.addingTimeInterval(threshold)
                self.scheduleFirstByteDeadline(
                    episodeID: episodeID,
                    taskID: task.taskIdentifier,
                    deadline: restartedAt.addingTimeInterval(threshold)
                )
            }
            self.logger.info("download.waitingForConnectivity", "Download is waiting for network connectivity", metadata: [
                "taskID": "\(task.taskIdentifier)"
            ])
        }
    }
}
