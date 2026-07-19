import AVFoundation
import Foundation

// AI CONTEXT — App/PlaybackMediaWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Playback-local-media identity and resume-state workflow. It resolves a
// playable file from the durable filename, stored URL, or DownloadManager's
// canonical expected path; repairs stale SubscriptionStore metadata; measures
// local duration; owns current-position save/read/clear helpers; and restores
// the newest valid downloaded resume candidate during cold launch.
//
// DURABILITY / RELIABILITY:
// PlaybackPositionStore remains the sole JSON/cache owner. This workflow is the
// application transaction boundary around that store and the media filesystem.
// A restore candidate is published to PlaybackCoordinator only after the
// current SubscriptionStore row still says downloaded and a real local file is
// resolved. Invalid or near-finished candidates are cleared deterministically.
//
// CONCURRENCY:
// MainActor serializes SubscriptionStore repair and PlaybackCoordinator state.
// AVAsset duration loading is asynchronous. No network request or download is
// started here.

@MainActor
final class PlaybackMediaWorkflow {
    private let playback: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let downloadManager: any DownloadManaging
    private let positionStore: PlaybackPositionStore
    private let logger: AppLogger

    init(
        playback: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        downloadManager: any DownloadManaging,
        positionStore: PlaybackPositionStore,
        logger: AppLogger
    ) {
        self.playback = playback
        self.subscriptionStore = subscriptionStore
        self.downloadManager = downloadManager
        self.positionStore = positionStore
        self.logger = logger
    }

    func resolveLocalURL(for episode: Episode) -> URL? {
        if let fileName = episode.localFileName,
           let url = try? downloadManager.localFileURL(fileName: fileName),
           FileManager.default.fileExists(atPath: url.path) {
            repairStoredLocationIfNeeded(episode, resolvedURL: url)
            return url
        }

        if let url = episode.localFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            if episode.localFileName == nil {
                subscriptionStore.markEpisodeDownloaded(
                    subscriptionID: episode.subscriptionID,
                    episodeID: episode.id,
                    localFileURL: url
                )
            }
            return url
        }

        guard let expectedURL = try? downloadManager.expectedLocalFileURL(
            for: episode
        ),
              FileManager.default.fileExists(atPath: expectedURL.path) else {
            return nil
        }
        repairStoredLocationIfNeeded(episode, resolvedURL: expectedURL)
        return expectedURL
    }

    func expectedLocalPath(for episode: Episode) -> String? {
        try? downloadManager.expectedLocalFileURL(for: episode).path
    }

    func localFileExists(for episode: Episode) -> Bool {
        resolveLocalURL(for: episode) != nil
    }

    func localDuration(from url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        return duration
    }

    func saveCurrentPosition() {
        guard let episode = playback.currentEpisode,
              playback.clock.time > 0 else {
            return
        }
        positionStore.save(
            episode: episode,
            timeSeconds: playback.clock.time
        )
    }

    func savedTime(for episode: Episode) -> TimeInterval {
        positionStore.savedTime(for: episode)
    }

    func clearPosition(for episode: Episode) {
        positionStore.clear(for: episode)
    }

    func clearPosition(episodeID: UUID) {
        positionStore.clear(episodeID: episodeID)
    }

    @discardableResult
    func restoreNewestCandidate(in episodes: [Episode]) -> Bool {
        guard let restored = positionStore.bestRestoreCandidate(
            in: episodes
        ) else {
            return false
        }
        let candidate = restored.episode
        guard let storedEpisode = subscriptionStore.episode(
            subscriptionID: candidate.subscriptionID,
            episodeID: candidate.id
        ),
              storedEpisode.downloadState == .downloaded,
              resolveLocalURL(for: storedEpisode) != nil else {
            positionStore.clear(for: candidate)
            return false
        }

        let resumeTime = PlaybackPositionStore.normalizedResumeTime(
            restored.position.timeSeconds,
            duration: storedEpisode.durationSeconds
        )
        guard resumeTime > 0 else {
            positionStore.clear(for: storedEpisode)
            return false
        }
        playback.currentEpisode = storedEpisode
        playback.clock.time = resumeTime
        logger.info(
            "player.restorePosition",
            "Restored playback position",
            metadata: [
                "episode": storedEpisode.title,
                "resume": "\(Int(resumeTime))"
            ]
        )
        return true
    }

    private func repairStoredLocationIfNeeded(
        _ episode: Episode,
        resolvedURL: URL
    ) {
        guard episode.localFileURL?.path != resolvedURL.path else { return }
        logger.info(
            "download.localFilePathRepaired",
            "Repaired stale local media path",
            metadata: [
                "episode": episode.title,
                "episodeID": episode.id.uuidString,
                "storedPath": episode.localFileURL?.path ?? "none",
                "repairedPath": resolvedURL.path
            ]
        )
        subscriptionStore.markEpisodeDownloaded(
            subscriptionID: episode.subscriptionID,
            episodeID: episode.id,
            localFileURL: resolvedURL
        )
    }
}
