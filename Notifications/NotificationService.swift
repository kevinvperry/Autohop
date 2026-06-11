import Foundation
import UIKit
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

    // MARK: - Badge

    /// Updates the app icon badge to reflect the number of downloaded episodes in the queue.
    /// Pass 0 to clear the badge.
    @MainActor
    func updateBadge(count: Int) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    // MARK: - Post notifications

    /// Fired after a new episode is detected by feed refresh or background download.
    ///
    /// - Parameters:
    ///   - episodeTitle: Displayed as the notification body.
    ///   - podcastName: Displayed as the notification title (bold, top line).
    ///   - artworkURL: Remote URL of the podcast artwork. Downloaded and attached as the
    ///                 notification thumbnail (shown on the right, like Pocket Casts).
    func notifyNewEpisode(episodeTitle: String, podcastName: String, artworkURL: URL?) async {
        let content = UNMutableNotificationContent()
        content.title = podcastName
        content.body = episodeTitle
        content.sound = .default

        if let artworkURL, let attachment = await makeArtworkAttachment(from: artworkURL) {
            content.attachments = [attachment]
        }

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

    /// Downloads artwork from `url`, writes it to a temp file, and returns a
    /// `UNNotificationAttachment` suitable for use as a notification thumbnail.
    private func makeArtworkAttachment(from url: URL) async -> UNNotificationAttachment? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        guard (try? data.write(to: tempURL)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: UUID().uuidString, url: tempURL)
    }
}
