import Foundation

// AI CONTEXT — App/PlaybackLaunchWorkflow.swift
//
// Owns the one-shot playback launch policy shared by phone and CarPlay. Phone
// launch loads the first queued episode paused when no restored position exists.
// CarPlay launch reasserts an already-running engine or actively resumes the
// restored episode. The handled flag lives in PlaybackCoordinator so multiple
// scenes cannot execute competing launch paths.

@MainActor
final class PlaybackLaunchWorkflow {
    private let playback: PlaybackCoordinator
    private let queueCoordinator: QueueCoordinator
    private let subscriptionStore: SubscriptionStore
    private let logger: AppLogger
    private let preferenceWorkflow: PlaybackPreferenceWorkflow
    private let startWorkflow: PlaybackStartWorkflow

    init(
        playback: PlaybackCoordinator,
        queueCoordinator: QueueCoordinator,
        subscriptionStore: SubscriptionStore,
        logger: AppLogger,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        startWorkflow: PlaybackStartWorkflow
    ) {
        self.playback = playback
        self.queueCoordinator = queueCoordinator
        self.subscriptionStore = subscriptionStore
        self.logger = logger
        self.preferenceWorkflow = preferenceWorkflow
        self.startWorkflow = startWorkflow
    }

    func preparePhoneLaunch() async {
        guard !playback.hasHandledLaunchPlayback else { return }
        playback.hasHandledLaunchPlayback = true
        if playback.currentEpisode != nil {
            logger.info("player.launch", "Restored episode loaded in paused state", metadata: [
                "episode": playback.currentEpisode?.title ?? "none"
            ])
            return
        }
        guard let episode = queueCoordinator.nextPlayableEpisode else {
            logger.info("player.launch", "No episode available on launch")
            return
        }
        playback.currentEpisode = episode
        playback.clock.time = 0
        logger.info("player.launch", "Loaded episode in paused state on launch", metadata: [
            "episode": episode.title
        ])
    }

    func resumeForCarPlayLaunch() async {
        guard !playback.hasHandledLaunchPlayback else { return }
        playback.hasHandledLaunchPlayback = true

        if playback.engine.isPlaying {
            playback.isPlaying = true
            if let episode = playback.currentEpisode,
               let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
               ) {
                let speed = preferenceWorkflow.effectiveSpeed(
                    for: subscription
                )
                playback.engine.updatePlaybackSpeed(speed)
                NowPlayingService.shared.updateTime(
                    currentTime: playback.clock.time,
                    isPlaying: true,
                    speed: speed
                )
            }
            logger.info("player.carplayLaunch", "Playback already active on CarPlay launch", metadata: [
                "episode": playback.currentEpisode?.title ?? "none"
            ])
            return
        }

        if let episode = playback.currentEpisode {
            logger.info("player.carplayLaunch", "Resuming restored episode from CarPlay launch", metadata: [
                "episode": episode.title,
                "resume": "\(Int(playback.clock.time))"
            ])
            if await startWorkflow.start(
                episode: episode,
                resumeFrom: playback.clock.time
            ) {
                return
            }
        }
        logger.info(
            "player.carplayLaunch",
            "No restored episode available for CarPlay launch"
        )
    }
}
