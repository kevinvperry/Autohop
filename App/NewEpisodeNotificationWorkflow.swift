import Foundation

// AI CONTEXT — App/NewEpisodeNotificationWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Sole application policy for notifying about a newly downloaded episode. It
// applies the global master switch and per-subscription switch, records an
// explainable skipped/sent diagnostic, and submits the local notification.
//
// CONCURRENCY:
// Eligibility is read on MainActor. NotificationService delivery is launched
// asynchronously because download settlement must not wait for artwork or
// notification-centre work. This workflow never requests notification
// permission; permission prompts remain explicitly user initiated.

@MainActor
final class NewEpisodeNotificationWorkflow {
    private let settingsStore: any SettingsStoring
    private let logger: AppLogger

    init(
        settingsStore: any SettingsStoring,
        logger: AppLogger
    ) {
        self.settingsStore = settingsStore
        self.logger = logger
    }

    func notifyIfAllowed(
        episode: Episode,
        subscription: Subscription
    ) {
        guard settingsStore.appSettings.notifyNewEpisodes,
              subscription.notificationsEnabled else {
            logger.info(
                "notification.skipped",
                "New episode notification skipped",
                metadata: [
                    "podcast": subscription.title,
                    "episode": episode.title,
                    "globalEnabled":
                        "\(settingsStore.appSettings.notifyNewEpisodes)",
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
