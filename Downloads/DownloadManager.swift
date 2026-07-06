import Foundation

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
// HANDLES: resume-data save/restore on pause/cancel/failure; a stall watchdog
// (no progress bytes for 10 min → cancel with resume data, notify AppState via
// onWatchdogCancelled to schedule a retry) — the watchdog detects app suspension
// from its own tick gap and grants a fresh window instead of false-cancelling
// background transfers that ran out-of-process while suspended; progress throttling (≤1/s/task);
// background relaunch completion (onBackgroundDownloadCompleted, when the app
// was killed and iOS relaunched it to deliver a finished download — there is
// no live continuation in that case); file storage under the app's Downloads
// directory with deterministic names (expectedLocalFileURL). The Downloads
// directory is marked isExcludedFromBackup (ASSESSMENT N1) and the directory plus
// completed media files are marked available-after-first-unlock so CarPlay can
// start downloaded playback after the phone locks in the car. Media deliberately
// stays in Application Support (NOT Caches) so iOS never purges it out from under
// the download-first queue.
// CONCURRENCY CAP (3) AND NETWORK POLICY (WiFi/cellular toggles) ARE NOT
// ENFORCED HERE — AppState gates calls to download().
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
}

public final class DownloadManager: NSObject, DownloadManaging {

    public static let backgroundSessionIdentifier = "com.autohop.downloads"

    private let logger = AppLogger.shared
    private var session: URLSession!
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
    private var downloadWatchdogTimer: Timer?
    /// Wall-clock time of the last watchdog tick. The timer only fires while the app is
    /// running, so a gap far larger than `watchdogInterval` means the app was suspended
    /// in between — during which a background URLSession keeps transferring out-of-process
    /// but delivers no progress callbacks, staling `progressLastReceivedAt` through no
    /// fault of the download. Used to grant a grace window instead of false-cancelling.
    private var lastWatchdogTickAt = Date()
    private let progressThrottleInterval: TimeInterval = 1.0
    private let downloadStallThreshold: TimeInterval = 10 * 60
    private let watchdogInterval: TimeInterval = 2 * 60

    private let fileManager: FileManager
    private let downloadDirectoryOverride: URL?

    public var backgroundEventsCompletionHandler: (() -> Void)?
    public var onBackgroundDownloadCompleted: ((UUID, UUID, URL) -> Void)?
    public var onProgressUpdate: ((UUID, Double, Int64, Int64) -> Void)?
    public var onWatchdogCancelled: ((UUID) -> Void)?

    // MARK: - Init

    public init(fileManager: FileManager = .default, downloadDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.downloadDirectoryOverride = downloadDirectory
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        config.isDiscretionary = false
        #if os(iOS) || os(watchOS)
        config.sessionSendsLaunchEvents = true
        #endif
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
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

    private func startDownloadTask(episode: Episode, allowsCellular: Bool, continuation: CheckedContinuation<URL, Error>) {
        let task: URLSessionDownloadTask
        if let resumeData = resumeDataByEpisodeID.removeValue(forKey: episode.id) {
            task = session.downloadTask(withResumeData: resumeData)
            logger.info("download.taskResumeData", "Resuming download from stored resume data", metadata: [
                "episode": episode.title,
                "episodeID": episode.id.uuidString
            ])
        } else {
            var request = URLRequest(url: episode.audioURL)
            request.allowsCellularAccess = allowsCellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = encodeTaskMeta(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            audioURL: episode.audioURL,
            expectedBytes: episode.fileSizeBytes
        )
        continuations[task.taskIdentifier] = continuation
        episodeIDByTask[task.taskIdentifier] = episode.id
        taskIDByEpisodeID[episode.id] = task.taskIdentifier
        taskIDByMediaURL[episode.audioURL, default: []].insert(task.taskIdentifier)
        mediaURLByEpisodeID[episode.id] = episode.audioURL
        lastLoggedProgressBucketByEpisodeID[episode.id] = 0
        progressLastReceivedAt[episode.id] = Date()
        logger.info("download.taskResume", "Download task resumed", metadata: [
            "episode": episode.title,
            "episodeID": episode.id.uuidString,
            "taskID": "\(task.taskIdentifier)",
            "mediaKind": episode.mediaKind.rawValue,
            "expectedBytes": episode.fileSizeBytes.map(String.init) ?? "unknown",
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
            guard let self, let taskID = self.taskIDByEpisodeID[episodeID] else { return }
            self.intentionallyPausedEpisodeIDs.insert(episodeID)
            self.session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == taskID }) as? URLSessionDownloadTask else { return }
                task.cancel { [weak self] resumeData in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let resumeData {
                            self.resumeDataByEpisodeID[episodeID] = resumeData
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
            self.resumeDataByEpisodeID.removeValue(forKey: episodeID)
            self.lastLoggedProgressBucketByEpisodeID.removeValue(forKey: episodeID)

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
            self?.resumeDataByEpisodeID.removeValue(forKey: episodeID)
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
    }

    private func encodeTaskMeta(episodeID: UUID, subscriptionID: UUID, audioURL: URL, expectedBytes: Int64?) -> String? {
        guard let data = try? JSONEncoder().encode(
            TaskMeta(episodeID: episodeID, subscriptionID: subscriptionID, audioURL: audioURL, expectedBytes: expectedBytes)
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
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = downloadTask.taskIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self, let episodeID = self.episodeIDByTask[taskID] else { return }
            self.progressLastReceivedAt[episodeID] = Date()
            let now = Date()
            let shouldDispatch = self.progressLastDispatchedAt[taskID]
                .map { now.timeIntervalSince($0) >= self.progressThrottleInterval } ?? true
            if shouldDispatch {
                self.progressLastDispatchedAt[taskID] = now
                self.onProgressUpdate?(episodeID, fraction, totalBytesWritten, totalBytesExpectedToWrite)
            }

            let bucket = Int((fraction * 10).rounded(.down))
            let lastBucket = self.lastLoggedProgressBucketByEpisodeID[episodeID] ?? 0
            if bucket > lastBucket {
                self.lastLoggedProgressBucketByEpisodeID[episodeID] = bucket
                self.logger.info("download.progress", "Download progress", metadata: [
                    "episodeID": episodeID.uuidString,
                    "progress": "\(bucket * 10)%",
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
                    let ids = Set(tasks.compactMap { self.decodeTaskMeta($0.taskDescription)?.episodeID })
                    continuation.resume(returning: ids)
                }
            }
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

private extension DownloadManager {
    func clearTaskTracking(taskID: Int) {
        guard let episodeID = episodeIDByTask.removeValue(forKey: taskID) else { return }
        taskIDByEpisodeID.removeValue(forKey: episodeID)
        if let mediaURL = mediaURLByEpisodeID.removeValue(forKey: episodeID) {
            removeMediaURLTask(taskID, for: mediaURL)
        }
        lastLoggedProgressBucketByEpisodeID.removeValue(forKey: episodeID)
        progressLastDispatchedAt.removeValue(forKey: taskID)
        progressLastReceivedAt.removeValue(forKey: episodeID)
    }

    // MARK: - Watchdog

    private func startDownloadWatchdog() {
        lastWatchdogTickAt = Date()
        downloadWatchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkForStalledDownloads() }
        }
    }

    private func checkForStalledDownloads() {
        let now = Date()
        // The watchdog Timer only fires while the app is running. A gap far larger than
        // its interval means the app was suspended in between — during which a background
        // URLSession keeps transferring out-of-process but delivers no progress callbacks,
        // staling `progressLastReceivedAt` through no fault of the download. Grant every
        // in-flight task a fresh window and skip this tick rather than cancelling healthy
        // background downloads the moment the app resumes.
        let sinceLastTick = now.timeIntervalSince(lastWatchdogTickAt)
        lastWatchdogTickAt = now
        if sinceLastTick > watchdogInterval * 1.5 {
            if !progressLastReceivedAt.isEmpty {
                let count = progressLastReceivedAt.count
                progressLastReceivedAt = progressLastReceivedAt.mapValues { _ in now }
                logger.info("download.watchdogResumeGrace", "App resumed after suspension — reset download stall timers", metadata: [
                    "suspendedSeconds": "\(Int(sinceLastTick.rounded()))",
                    "activeDownloads": "\(count)"
                ])
            }
            return
        }
        let stalled = progressLastReceivedAt.filter { now.timeIntervalSince($0.value) > downloadStallThreshold }
        guard !stalled.isEmpty else { return }
        for (episodeID, _) in stalled {
            guard let taskID = taskIDByEpisodeID[episodeID] else { continue }
            logger.warning("download.watchdog", "Cancelling stalled download — no progress received", metadata: [
                "episodeID": episodeID.uuidString,
                "taskID": "\(taskID)",
                "stallMinutes": "\(Int(downloadStallThreshold / 60))"
            ])
            // Mark as watchdog-stalled so didCompleteWithError can fire onWatchdogCancelled.
            // Do NOT pre-clear task tracking here — that would orphan the episodeID lookup in
            // the delegate and silently drop the retry callback.
            watchdogStalledEpisodeIDs.insert(episodeID)
            session.getAllTasks { [weak self] tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == taskID }) as? URLSessionDownloadTask else {
                    // Task already gone — clean up directly and still fire the retry callback.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.watchdogStalledEpisodeIDs.remove(episodeID)
                        self.clearTaskTracking(taskID: taskID)
                        self.onWatchdogCancelled?(episodeID)
                    }
                    return
                }
                // Use cancel(byProducingResumeData:) so the partial download isn't thrown away.
                task.cancel(byProducingResumeData: { [weak self] resumeData in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if let resumeData {
                            self.resumeDataByEpisodeID[episodeID] = resumeData
                        }
                        // didCompleteWithError will fire next and handle the rest.
                    }
                })
            }
        }
    }
}
