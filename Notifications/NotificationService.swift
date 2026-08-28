import Foundation
import UIKit
import UserNotifications

// AI CONTEXT — Notifications/NotificationService.swift
// Singleton UNUserNotificationCenter wrapper AND the app's notification-center
// delegate (set in AppDelegate.didFinishLaunching). New-episode notifications
// fire when the per-podcast toggle (Subscription.notificationsEnabled) is on —
// AppSettings.notifyNewEpisodes is only the default snapshotted by future local
// subscriptions, not a delivery gate. Eligibility lives in
// NewEpisodeNotificationWorkflow, not here. Also owns
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
// user-triggered opt-ins — the notification toggles (NotificationSettingsView),
// enabling Sleep Schedule (SleepScheduleView), and enabling a Listening Recap
// (RecapSettingsView). This avoids an unprompted launch-time permission dialog.
//
// LISTENING RECAPS: scheduleRecaps(weekly:monthly:yearly:) reconciles three
// opt-in recurring local calendar notifications (Mon 9am / 1st 9am / Jan 1 9am)
// against AppSettings.recap*Enabled — idempotent (remove-then-add), called on
// toggle change, on RecapSettingsView appear, and at launch from RootView. The
// body is an evergreen teaser; the real figures are shown in-app on tap. The
// userInfo recapUserInfoKey carries which period, and the delegate routes it
// into the matching Stats "Last" view. Mechanism B — see FEATURES.md §14.1.
//
// Artwork thumbnails for new-episode notifications use ArtworkImageCache.sourceData
// rather than a separate URLSession download, so notification art shares the same
// response validation, source-byte disk cache, failure cooldown, and pruning rules
// as visible episode/podcast artwork.

enum ListeningRecapPeriod: String, Hashable {
    case weekly
    case monthly
    case yearly

    init?(userInfoValue: Any?) {
        guard let rawValue = userInfoValue as? String else { return nil }
        self.init(rawValue: rawValue)
    }
}

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

    /// Invoked (on the main actor) when the user taps a Listening Recap
    /// notification. Wired by RootView so the app opens the correct Stats period.
    var onListeningRecap: ((ListeningRecapPeriod) -> Void)?

    /// Stores a recap tap that arrives before RootView has installed the handler
    /// during cold launch from a notification.
    private var pendingListeningRecap: ListeningRecapPeriod?

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

    /// Allows RootView to flush a recap notification tap that arrived during cold
    /// launch before SwiftUI navigation was ready.
    func setListeningRecapHandler(_ handler: @escaping (ListeningRecapPeriod) -> Void) {
        onListeningRecap = handler
        if let pendingListeningRecap {
            self.pendingListeningRecap = nil
            DispatchQueue.main.async { handler(pendingListeningRecap) }
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
        let userInfo = response.notification.request.content.userInfo
        if let recapPeriod = ListeningRecapPeriod(userInfoValue: userInfo[Self.recapUserInfoKey]) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                AppLogger.shared.info("notification.recapTapped", "Listening recap notification tapped", metadata: [
                    "period": recapPeriod.rawValue
                ])
                if let handler = self.onListeningRecap {
                    handler(recapPeriod)
                } else {
                    self.pendingListeningRecap = recapPeriod
                }
            }
        } else if response.actionIdentifier == Self.stillListeningActionID {
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

    // MARK: - Listening Recaps (opt-in periodic stats summaries)

    /// userInfo key carrying which recap a tapped notification belongs to, so the
    /// delegate can deep-link into the matching Stats "Last" period.
    static let recapUserInfoKey = "autohopRecap"

    private static let recapWeeklyID = "recap.weekly"
    private static let recapMonthlyID = "recap.monthly"
    private static let recapYearlyID = "recap.yearly"

    /// Reconciles the three recap notifications against the user's opt-in flags.
    /// Idempotent — safe to call on every toggle change and at launch. Each recap
    /// is a recurring local calendar notification delivered at 9am (Mechanism B):
    /// the body is an evergreen teaser; the real numbers are shown in-app when the
    /// user taps it (it deep-links into the Stats "Last" view).
    func scheduleRecaps(weekly: Bool, monthly: Bool, yearly: Bool) {
        // Weekly — Monday 09:00 (Gregorian weekday 2 = Monday), for the prior week.
        reconcileRecap(
            id: Self.recapWeeklyID, enabled: weekly, recapKey: ListeningRecapPeriod.weekly.rawValue,
            components: DateComponents(hour: 9, minute: 0, weekday: 2),
            title: "Your week in listening 📊",
            body: "Tap to see how you listened last week."
        )
        // Monthly — the 1st at 09:00, for the prior month.
        reconcileRecap(
            id: Self.recapMonthlyID, enabled: monthly, recapKey: ListeningRecapPeriod.monthly.rawValue,
            components: DateComponents(day: 1, hour: 9, minute: 0),
            title: "Your month in listening 📊",
            body: "Tap to see your month in podcasts."
        )
        // Yearly — Jan 1 at 09:00, for the year just gone.
        reconcileRecap(
            id: Self.recapYearlyID, enabled: yearly, recapKey: ListeningRecapPeriod.yearly.rawValue,
            components: DateComponents(month: 1, day: 1, hour: 9, minute: 0),
            title: "Your year in listening 🎧",
            body: "Tap to see your year in podcasts."
        )
    }

    private func reconcileRecap(
        id: String, enabled: Bool, recapKey: String,
        components: DateComponents, title: String, body: String
    ) {
        let center = UNUserNotificationCenter.current()
        // Always clear first so a toggle-off removes it and a toggle-on never
        // stacks duplicates.
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.recapUserInfoKey: recapKey]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
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

    /// Loads artwork from the shared cache, writes it to a temp file, and returns
    /// a `UNNotificationAttachment` suitable for use as a notification thumbnail.
    private func makeArtworkAttachment(from url: URL) async -> UNNotificationAttachment? {
        guard let data = await ArtworkImageCache.shared.sourceData(for: url, priority: .background),
              data.count <= 5 * 1024 * 1024 else { return nil }

        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        guard (try? data.write(to: tempURL)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: UUID().uuidString, url: tempURL)
    }
}
