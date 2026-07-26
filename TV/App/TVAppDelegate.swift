import UIKit
import AutohopCore

// AI CONTEXT — TV/App/TVAppDelegate.swift (added 2026-07-10)
// tvOS mirror of App/AppDelegate.swift's relay wiring (item 9 in that file's
// header) — much smaller, since TV needs only registration + wake-push
// receiving, not the BGTask/background-URLSession/CarPlay machinery iOS
// carries. Bridged into AutohopTVApp's SwiftUI @main via
// @UIApplicationDelegateAdaptor, same mechanism iOS uses.
// registerForRemoteNotifications() is called unconditionally at launch — TV
// has no local entitlement check of its own (RELAY_TIER1_IMPLEMENTATION.md
// §14.1 tvOS-gating is still undecided; this piggybacks on whichever iPhone
// shares its sync_group_id already having an active Autohop Pro subscription
// via POST /v1/register-paired), so obtaining a token is unconditionally
// worth doing — TVAppModel.registerWithRelayIfPossible() decides whether the
// attempt can succeed once a token is available.
final class TVAppDelegate: NSObject, UIApplicationDelegate {
    /// Buffer for an APNs token that arrives BEFORE TVAppModel exists — the
    /// model is created lazily one frame after launch (2026-07-11 splash fix,
    /// see AutohopTVApp's LAZY MODEL note) and registerForRemoteNotifications
    /// fires at didFinishLaunching, so the token can genuinely win that race.
    /// TVAppModel.init consumes and clears this.
    @MainActor static var pendingRelayToken: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            if let model = TVAppModel.shared {
                model.relayTokenReceived(token)
            } else {
                Self.pendingRelayToken = token
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppLogger.shared.warning("relay.tvApnsRegisterFailed", "TV failed to register for remote notifications", metadata: [
            "error": error.localizedDescription
        ])
    }

    /// Dispatches by the relay's `type` payload key, same contract as iOS's
    /// AppDelegate: complete fast, no UI. "feed-updated" is a no-op here — TV
    /// has no downloads of its own for the relay to wake it for; only
    /// "sync-nudge" is meaningful on tvOS (the whole reason TV registers at all).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let type = userInfo["type"] as? String else {
            completionHandler(.noData)
            return
        }
        AppLogger.shared.info("relay.tvPushReceived", "TV silent push received", metadata: ["type": type], alwaysPersist: true)
        Task { @MainActor in
            guard type == "sync-nudge", let model = TVAppModel.shared else {
                completionHandler(.noData)
                return
            }
            let announcedGeneration = (userInfo["queueGeneration"] as? NSNumber)?.int64Value
                ?? Int64(userInfo["queueGeneration"] as? String ?? "")
            let announcedEpoch = userInfo["queueEpoch"] as? String
            await model.receiveSyncNudge(announcedGeneration: announcedGeneration, announcedEpoch: announcedEpoch)
            completionHandler(.newData)
        }
    }
}
