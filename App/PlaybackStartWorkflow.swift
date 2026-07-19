import Foundation

// AI CONTEXT — App/PlaybackStartWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Ordered transaction that turns a selected downloaded Episode into an active
// playback session. It validates/repairs local media identity and duration,
// downloads a missing file, resolves resume-vs-start-skip policy, starts the
// engine, publishes authoritative playback state, seeds cross-device history,
// starts sleep services, schedules external chapters, and publishes Now Playing.
//
// DURABILITY / FAILURE INVARIANTS:
// - Missing media is downloaded before playback and the refreshed store episode
//   is re-read before retrying once.
// - Resume time is normalized against the measured local-file duration.
// - The engine starts before store/history/Now Playing state says "playing".
// - Fresh starts alone credit episode-start Stats.
// - Cross-device history is seeded and flushed immediately after state commit.
// - Failure leaves `isPlaying == false` and a user-visible playback message.
//
// CONCURRENCY:
// MainActor-only. External chapter loading is delegated after the first audio
// frame and receives PlaybackCoordinator's current episode generation.

@MainActor
final class PlaybackStartWorkflow {
    private let playback: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let settingsStore: any SettingsStoring
    private let historyStatsCoordinator: HistoryStatsCoordinator
    private let logger: AppLogger
    private let mediaWorkflow: PlaybackMediaWorkflow
    private let downloadWorkflow: DownloadTransferWorkflow
    private let preferenceWorkflow: PlaybackPreferenceWorkflow
    private let syncCoordinator: SyncCoordinator
    private let chapterWorkflow: PlaybackChapterWorkflow
    private let runtimeWorkflow: AppRuntimeWorkflow

    init(
        playback: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        settingsStore: any SettingsStoring,
        historyStatsCoordinator: HistoryStatsCoordinator,
        logger: AppLogger,
        mediaWorkflow: PlaybackMediaWorkflow,
        downloadWorkflow: DownloadTransferWorkflow,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        syncCoordinator: SyncCoordinator,
        chapterWorkflow: PlaybackChapterWorkflow,
        runtimeWorkflow: AppRuntimeWorkflow
    ) {
        self.playback = playback
        self.subscriptionStore = subscriptionStore
        self.settingsStore = settingsStore
        self.historyStatsCoordinator = historyStatsCoordinator
        self.logger = logger
        self.mediaWorkflow = mediaWorkflow
        self.downloadWorkflow = downloadWorkflow
        self.preferenceWorkflow = preferenceWorkflow
        self.syncCoordinator = syncCoordinator
        self.chapterWorkflow = chapterWorkflow
        self.runtimeWorkflow = runtimeWorkflow
    }

    func start(episode: Episode, resumeFrom: TimeInterval) async -> Bool {
        guard let subscription = subscriptionStore.subscription(
            id: episode.subscriptionID
        ) else {
            return false
        }
        runtimeWorkflow.logResourceSnapshot(reason: "player.start.before", extra: [
            "episode": episode.title,
            "podcast": subscription.title
        ], force: false)
        logger.info("player.start", "Preparing playback", metadata: [
            "episode": episode.title,
            "podcast": subscription.title,
            "resume": "\(Int(resumeFrom))"
        ])

        var playableEpisode = subscriptionStore.episode(
            subscriptionID: subscription.id,
            episodeID: episode.id
        ) ?? episode
        if let repairedURL = mediaWorkflow.resolveLocalURL(
            for: playableEpisode
        ) {
            playableEpisode.localFileURL = repairedURL
        }
        if let localFileURL = playableEpisode.localFileURL,
           let duration = await mediaWorkflow.localDuration(
            from: localFileURL
           ) {
            playableEpisode.durationSeconds = duration
            subscriptionStore.updateEpisodeDuration(
                subscriptionID: subscription.id,
                episodeID: playableEpisode.id,
                durationSeconds: duration
            )
        }
        let safeResumeTime = PlaybackPositionStore.normalizedResumeTime(
            resumeFrom,
            duration: playableEpisode.durationSeconds
        )

        guard let localFileURL = mediaWorkflow.resolveLocalURL(
            for: playableEpisode
        ) else {
            playback.message = "Downloading \(playableEpisode.title) before playback."
            logger.warning(
                "player.missingFile",
                "Local audio file missing before playback",
                metadata: [
                    "episode": playableEpisode.title,
                    "episodeID": playableEpisode.id.uuidString,
                    "storedPath": playableEpisode.localFileURL?.path ?? "none",
                    "expectedPath":
                        mediaWorkflow.expectedLocalPath(for: playableEpisode)
                        ?? "unknown"
                ]
            )
            await downloadWorkflow.download(
                playableEpisode,
                subscriptionID: subscription.id,
                podcastTitle: subscription.title,
                showCompletionMessage: true
            )
            guard let refreshedEpisode = subscriptionStore.episode(
                subscriptionID: subscription.id,
                episodeID: playableEpisode.id
            ),
                  mediaWorkflow.resolveLocalURL(for: refreshedEpisode)
                    != nil else {
                playback.isPlaying = false
                playback.message = "Could not download \(playableEpisode.title)."
                logger.error(
                    "player.downloadBeforePlaybackFailed",
                    "Could not download missing episode before playback",
                    metadata: ["episode": playableEpisode.title]
                )
                return false
            }
            return await start(episode: refreshedEpisode, resumeFrom: 0)
        }
        playableEpisode.localFileURL = localFileURL

        do {
            playback.engine.setVolume(1)
            let preference = preferenceWorkflow.effectivePreference(
                for: subscription
            )
            try await playback.engine.play(
                playableEpisode,
                preference: preference,
                filter: subscription.chapterFilter
            )

            let start = PlaybackSessionPolicy.startResolution(
                resumeTime: safeResumeTime,
                startSkipSeconds: preference.startSkipSeconds
            )
            if let seekTarget = start.seekTarget {
                playback.engine.seek(to: seekTarget)
            }
            playback.clock.time = start.reportedStartTime
            subscriptionStore.markEpisodePlaying(
                subscriptionID: subscription.id,
                episodeID: playableEpisode.id
            )
            if start.isFreshStart {
                historyStatsCoordinator.recordEpisodeStarted(
                    subscriptionID: subscription.id,
                    showTitle: subscription.title
                )
            }
            playback.currentEpisode = playableEpisode
            playback.isPlaying = true
            if !settingsStore.appSettings.hasPlayedFirstEpisode {
                settingsStore.appSettings.hasPlayedFirstEpisode = true
            }
            playback.resetTimeUpdatePersistenceCadence()
            historyStatsCoordinator.beginPlaybackTracking(
                episodeID: playableEpisode.id,
                at: playback.clock.time
            )
            playback.message = nil

            historyStatsCoordinator.recordPlaybackStart(
                episode: playableEpisode,
                subscription: subscription,
                position: start.reportedStartTime
            )
            syncCoordinator.flushDeferredPushes(reason: "playback.start")

            if playableEpisode.chapters.isEmpty,
               let chaptersURL = playableEpisode.externalChaptersURL {
                chapterWorkflow.scheduleExternalFetch(
                    url: chaptersURL,
                    episodeID: playableEpisode.id,
                    subscriptionID: subscription.id,
                    generation: playback.generation
                )
            }
            if playback.sleepTimerService.checkAutoRestart() {
                logger.info(
                    "sleepTimer.autoRestart",
                    "Sleep timer auto-restarted on playback resume"
                )
            }
            playback.sleepScheduleService.playbackStarted()

            logger.info("player.started", "Playback started", metadata: [
                "episode": playableEpisode.title,
                "podcast": subscription.title,
                "duration": playableEpisode.durationSeconds.map {
                    "\(Int($0))"
                } ?? "unknown",
                "speed": PlaybackPreference.speedLabel(preference.speed),
                "vocalBoost": preference.vocalBoostLevel.title,
                "sharedListening": "\(settingsStore.appSettings.sharedListeningActive)"
            ])
            NowPlayingService.shared.update(
                episode: playableEpisode,
                podcastTitle: subscription.title,
                currentTime: start.reportedStartTime,
                duration: playableEpisode.durationSeconds,
                speed: preference.speed,
                isPlaying: true,
                artworkURL: playableEpisode.artworkURL ?? subscription.artworkURL
            )
            runtimeWorkflow.logResourceSnapshot(reason: "player.start.afterSuccess", extra: [
                "episode": playableEpisode.title,
                "podcast": subscription.title
            ], force: false)
            return true
        } catch {
            playback.isPlaying = false
            playback.message = "Could not play \(playableEpisode.title)."
            logger.error("player.failed", "Playback failed", metadata: [
                "episode": playableEpisode.title,
                "error": String(describing: error)
            ])
            runtimeWorkflow.logResourceSnapshot(reason: "player.start.afterFailure", extra: [
                "episode": playableEpisode.title,
                "podcast": subscription.title
            ], force: true)
            return false
        }
    }
}
