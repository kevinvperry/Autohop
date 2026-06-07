import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter` for Autohop-specific notifications.
///
/// Permission is requested once at first launch.  All `post*` methods are
/// no-ops if the user has denied permission — no extra guard needed at call sites.
final class NotificationService {

    static let shared = NotificationService()

    private init() {}

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    // MARK: - Post notifications

    /// Fired after a new episode is detected by feed refresh or background download.
    func notifyNewEpisode(title: String, podcastName: String) {
        let content = UNMutableNotificationContent()
        content.title = "New episode ready"
        content.body = "\(title) — \(podcastName)"
        content.sound = .default

        schedule(content, identifier: "new-episode-\(UUID().uuidString)")
    }

    // MARK: - Private

    private func schedule(_ content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // Deliver immediately.
        )
        UNUserNotificationCenter.current().add(request)
    }
}
