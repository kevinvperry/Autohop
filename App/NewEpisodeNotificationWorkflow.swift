import Foundation

// AI CONTEXT — App/NewEpisodeNotificationWorkflow.swift
// REPLAY (Version 1.7, 2026-09-12): Replay releases never emit normal new-publisher notifications, including completion of an in-flight release after disable.
//
// PURPOSE / OWNERSHIP:
// Sole application policy for notifying about a newly downloaded episode. It
// applies the subscription's independently persisted switch, records an
// explainable skipped/sent diagnostic, and submits the local notification.
// AppSettings.notifyNewEpisodes is only a creation default for future local
// subscriptions and must never gate an existing subscription here.
//
// CONCURRENCY:
// Eligibility is read on MainActor. NotificationService delivery is launched
// asynchronously because download settlement must not wait for artwork or
// notification-centre work. This workflow never requests notification
// permission; permission prompts remain explicitly user initiated.

@MainActor
final class NewEpisodeNotificationWorkflow {
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func notifyIfAllowed(
        episode: Episode,
        subscription: Subscription
    ) {
        guard subscription.autoArchiveSettings.replay?.enabled != true,
              subscription.autoArchiveSettings.replay?.releases.contains(where: { $0.key == episode.audioURL.absoluteString }) != true,
              subscription.notificationsEnabled else {
            logger.info(
                "notification.skipped",
                "New episode notification skipped",
                metadata: [
                    "podcast": subscription.title,
                    "episode": episode.title,
                    "subscriptionEnabled":
                        "\(subscription.notificationsEnabled)"
                ]
            )
            return
        }

        let episodeTitle = episode.title
        let podcastName = subscription.title
        let artworkURL = subscription.artworkURL
        Task {
            await NotificationService.shared.notifyNewEpisode(
                episodeTitle: episodeTitle,
                podcastName: podcastName,
                artworkURL: artworkURL
            )
        }
        logger.info(
            "notification.sent",
            "New episode notification sent",
            metadata: [
                "podcast": subscription.title,
                "episode": episode.title
            ]
        )
    }
}
