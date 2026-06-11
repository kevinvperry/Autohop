import Foundation

// AI CONTEXT — Downloads/DownloadActivityStore.swift
// UI-facing record of download activity (one DownloadActivity per episode
// download: downloading/paused/failed/completed with byte progress), persisted
// to download-activity.json so the Downloads page survives relaunch. This is
// presentation/bookkeeping state — the source of truth for whether an episode
// is actually on disk is Episode.downloadState + the file system (reconciled
// at launch by AppState.reconcileOrphanedDownloads).
public enum DownloadActivityStatus: String, Codable {
    case downloading
    case paused
    case failed
    case completed
}

public struct DownloadActivity: Identifiable, Codable, Equatable {
    public var id: UUID
    public var episodeID: UUID
    public var subscriptionID: UUID
    public var episodeTitle: String
    public var podcastTitle: String
    public var mediaURL: URL
    public var artworkURL: URL?
    public var mediaKind: EpisodeMediaKind
    public var expectedBytes: Int64?
    public var writtenBytes: Int64
    public var progress: Double
    public var status: DownloadActivityStatus
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    public var localFileName: String?

    public init(
        id: UUID = UUID(),
        episodeID: UUID,
        subscriptionID: UUID,
        episodeTitle: String,
        podcastTitle: String,
        mediaURL: URL,
        artworkURL: URL?,
        mediaKind: EpisodeMediaKind,
        expectedBytes: Int64?,
        writtenBytes: Int64 = 0,
        progress: Double = 0,
        status: DownloadActivityStatus = .downloading,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        localFileName: String? = nil
    ) {
        self.id = id
        self.episodeID = episodeID
        self.subscriptionID = subscriptionID
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.mediaURL = mediaURL
        self.artworkURL = artworkURL
        self.mediaKind = mediaKind
        self.expectedBytes = expectedBytes
        self.writtenBytes = writtenBytes
        self.progress = progress
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.localFileName = localFileName
    }
}

@MainActor
public final class DownloadActivityStore: ObservableObject {
    @Published public private(set) var activities: [DownloadActivity] = [] {
        didSet { scheduleSave() }
    }

    private let fileURL: URL?
    private var pendingSaveTask: Task<Void, Never>?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.fileURL = appSupport.appendingPathComponent("Autohop/download-activity.json")
        } else {
            self.fileURL = nil
        }
        load()
    }

    public var activeActivities: [DownloadActivity] {
        activities
            .filter { $0.status == .downloading || $0.status == .paused }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public var failedActivities: [DownloadActivity] {
        activities
            .filter { $0.status == .failed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var completedActivities: [DownloadActivity] {
        activities
            .filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    public var recentCompletedActivities: [DownloadActivity] {
        completedActivities.prefix(15).map { $0 }
    }

    public func start(episode: Episode, podcastTitle: String, expectedBytes: Int64?) {
        let now = Date()
        let existingIndex = activities.firstIndex { $0.episodeID == episode.id }
        let activity = DownloadActivity(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            episodeTitle: episode.title,
            podcastTitle: podcastTitle,
            mediaURL: episode.audioURL,
            artworkURL: episode.artworkURL,
            mediaKind: episode.mediaKind,
            expectedBytes: expectedBytes ?? episode.fileSizeBytes,
            status: .downloading,
            startedAt: existingIndex.flatMap { activities[$0].startedAt } ?? now,
            updatedAt: now
        )

        if let existingIndex {
            activities[existingIndex] = activity
        } else {
            activities.insert(activity, at: 0)
        }
        trim()
    }

    public func progress(
        episodeID: UUID,
        fraction: Double,
        writtenBytes: Int64,
        expectedBytes: Int64?
    ) {
        guard let index = activities.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        activities[index].status = .downloading
        activities[index].progress = max(0, min(1, fraction))
        activities[index].writtenBytes = writtenBytes
        if let expectedBytes, expectedBytes > 0 {
            activities[index].expectedBytes = expectedBytes
        }
        activities[index].updatedAt = Date()
    }

    /// Removes all activity records for the given episode (active, failed, and completed).
    /// Called when an episode is archived from the Downloads page — the row should disappear immediately.
    public func remove(episodeID: UUID) {
        activities.removeAll { $0.episodeID == episodeID }
    }

    public func pause(episodeID: UUID) {
        guard let index = activities.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        activities[index].status = .paused
        activities[index].updatedAt = Date()
    }

    public func fail(episode: Episode, podcastTitle: String, error: String) {
        upsertTerminal(
            episode: episode,
            podcastTitle: podcastTitle,
            status: .failed,
            localFileName: nil,
            errorMessage: error
        )
    }

    public func complete(episode: Episode, podcastTitle: String, localFileName: String) {
        upsertTerminal(
            episode: episode,
            podcastTitle: podcastTitle,
            status: .completed,
            localFileName: localFileName,
            errorMessage: nil
        )
    }

    private func upsertTerminal(
        episode: Episode,
        podcastTitle: String,
        status: DownloadActivityStatus,
        localFileName: String?,
        errorMessage: String?
    ) {
        let now = Date()
        if let index = activities.firstIndex(where: { $0.episodeID == episode.id }) {
            activities[index].status = status
            activities[index].progress = status == .completed ? 1 : activities[index].progress
            activities[index].writtenBytes = status == .completed
                ? (activities[index].expectedBytes ?? activities[index].writtenBytes)
                : activities[index].writtenBytes
            activities[index].completedAt = status == .completed ? now : nil
            activities[index].updatedAt = now
            activities[index].errorMessage = errorMessage
            activities[index].localFileName = localFileName
        } else {
            activities.insert(
                DownloadActivity(
                    episodeID: episode.id,
                    subscriptionID: episode.subscriptionID,
                    episodeTitle: episode.title,
                    podcastTitle: podcastTitle,
                    mediaURL: episode.audioURL,
                    artworkURL: episode.artworkURL,
                    mediaKind: episode.mediaKind,
                    expectedBytes: episode.fileSizeBytes,
                    writtenBytes: status == .completed ? (episode.fileSizeBytes ?? 0) : 0,
                    progress: status == .completed ? 1 : 0,
                    status: status,
                    updatedAt: now,
                    completedAt: status == .completed ? now : nil,
                    errorMessage: errorMessage,
                    localFileName: localFileName
                ),
                at: 0
            )
        }
        trim()
    }

    private func trim() {
        let active = activities
            .filter { $0.status == .downloading || $0.status == .paused }
            .sorted { $0.startedAt < $1.startedAt }
        let failed = activities.filter { $0.status == .failed }.sorted { $0.updatedAt > $1.updatedAt }
        let completed = activities.filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        activities = active + failed + completed
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        activities = (try? JSONDecoder().decode([DownloadActivity].self, from: data)) ?? []
    }

    // Debounce disk writes: during progress bursts we only write once per 300 ms.
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.performSave()
        }
    }

    private func performSave() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(activities)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.warning("downloadActivity.save", "Could not save download activity", metadata: [
                "error": String(describing: error)
            ])
        }
    }
}
