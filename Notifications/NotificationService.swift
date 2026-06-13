import Foundation
import UIKit
import UserNotifications

// AI CONTEXT — Notifications/NotificationService.swift
// Singleton UNUserNotificationCenter wrapper AND the app's notification-center
// delegate (set in AppDelegate.didFinishLaunching). New-episode notifications
// fire only when BOTH the global toggle (AppSettings.notifyNewEpisodes) and the
// per-podcast toggle (Subscription.notificationsEnabled, default OFF) are on —
// that gating lives in AppState.notifyNewEpisodeIfAllowed, not here. Also owns
// the app icon badge (queue count, behind the showQueueBadge setting).
//
// Sleep Schedule "still listening?" prompt: postSleepSchedulePrompt() fires a
// .timeSensitive notification (breaks through Sleep Focus/DND — requires the
// "Time Sensitive Notifications" capability in Xcode) carrying a "Still
// Listening" action button. The action is a BACKGROUND action (empty options):
// tapping it on the lock screen confirms WITHOUT unlocking or opening the app.
// The delegate routes that tap to onStillListening (wired by AppState to
// SleepScheduleService.userResponded()). AppState clears the notification via
// clearSleepSchedulePrompt() whenever the prompt ends (see the service's
// onPromptDismissed callback).
//
// PERMISSION TIMING: configure() (delegate + categories) runs at launch but does
// NOT prompt. Authorization is requested via requestPermission() only from
// user-triggered opt-ins — the notification toggles (NotificationSettingsView)
// and enabling Sleep Schedule (SleepScheduleView). This avoids an unprompted
// launch-time permission dialog and improves opt-in rates.

/// Wraps `UNUserNotificationCenter` for Autohop-specific notifications.
///
/// Permission is requested only when the user opts in (see requestPermission()).
/// All `post*` methods are no-ops if the user has denied permission — no extra
/// guard needed at call sites.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private override init() { super.init() }

    // MARK: - Sleep Schedule prompt identifiers

    private static let sleepPromptCategoryID = "sleepSchedulePrompt"
    private static let stillListeningActionID = "stillListening"
    private static let sleepPromptNotificationID = "sleep-schedule-prompt"

    /// Invoked (on the main actor) when the user taps "Still Listening" on the
    /// prompt notification — from the lock screen, banner or notification list.
    /// Wired by AppState to SleepScheduleService.userResponded().
    var onStillListening: (() -> Void)?

    /// Set true if a "Still Listening" tap arrives before `onStillListening` is
    /// wired (e.g. a cold launch via the action). Flushed when the handler lands.
    private var pendingStillListening = false

    // MARK: - Permission & setup

    /// Installs this object as the notification-center delegate and registers
    /// the Sleep Schedule action category. Called once at launch (AppDelegate).
    /// Does NOT prompt for permission — the prompt is deferred to a
    /// user-triggered moment (see `requestPermission()`).
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let stillListening = UNNotificationAction(
            identifier: Self.stillListeningActionID,
            title: "Still Listening",
            // Empty options: runs in the background, no unlock, no app launch —
            // so a half-asleep user can confirm straight from the lock screen.
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.sleepPromptCategoryID,
            actions: [stillListening],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Requests notification authorization. Call this only in response to a
    /// user action that opts into notifications — turning on a notification
    /// toggle, or enabling Sleep Schedule — never unprompted at launch. iOS
    /// shows the system prompt only the first time; later calls are no-ops.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    /// Allows AppState to flush a tap that arrived before its handler was wired.
    func setStillListeningHandler(_ handler: @escaping () -> Void) {
        onStillListening = handler
        if pendingStillListening {
            pendingStillListening = false
            DispatchQueue.main.async { handler() }
        }
    }

    // MARK: - Sleep Schedule prompt

    /// Posts the lock-screen "Are you still listening?" prompt with a "Still
    /// Listening" action button. Time-sensitive so it breaks through Sleep Focus.
    func postSleepSchedulePrompt() {
        let content = UNMutableNotificationContent()
        content.title = "Are you still listening?"
        content.body = "Tap \u{201C}Still Listening\u{201D} to keep playing — otherwise Autohop pauses where you last heard."
        content.sound = .default
        content.categoryIdentifier = Self.sleepPromptCategoryID
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        schedule(content, identifier: Self.sleepPromptNotificationID)
    }

    /// Removes the prompt notification (delivered or pending). Called whenever
    /// the prompt ends — confirmed, timed out, or torn down.
    func clearSleepSchedulePrompt() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.sleepPromptNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.sleepPromptNotificationID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.stillListeningActionID {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let handler = self.onStillListening {
                    handler()
                } else {
                    self.pendingStillListening = true
                }
                self.clearSleepSchedulePrompt()
            }
        }
        completionHandler()
    }

    /// Show the prompt as a banner even when the app is foregrounded (e.g. the
    /// screen-on video case), alongside the in-app overlay.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
