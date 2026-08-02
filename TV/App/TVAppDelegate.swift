import UIKit
import AutohopCore

// AI CONTEXT — TV/App/TVAppDelegate.swift
// Registers for APNs so CKSyncEngine can receive private CloudKit change
// notifications. No token is forwarded to application code or any external
// service; CKSyncEngine owns CloudKit notification handling internally.
final class TVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppLogger.shared.warning("sync.tvApnsRegisterFailed", "TV failed to register for private iCloud notifications", metadata: [
            "error": error.localizedDescription
        ])
    }
}
