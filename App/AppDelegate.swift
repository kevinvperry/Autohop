import UIKit
import BackgroundTasks

// AI CONTEXT — App/AppDelegate.swift
// UIKit delegate bridged into the SwiftUI app via @UIApplicationDelegateAdaptor
// (see AutohopApp.swift). Handles the four things SwiftUI cannot:
//  1. BGTaskScheduler registration for "com.autohop.feedrefresh" (must happen
//     before didFinishLaunching returns) and the BGAppRefreshTask handler,
//     which calls AppState.shared.refreshSubscriptionsForBackground().
//  2. Background URLSession wake: stores the system completion handler on
//     DownloadManager so it fires after urlSessionDidFinishEvents.
//  3. OPML/.xml file-open events → AppState.importOPML.
//  4. Orientation lock: delegates to VideoOrientationController so landscape
//     is only allowed during full-screen video playback.
// GOTCHA: a BGAppRefreshTask run with "no feeds due" still reports success —
// reporting failure teaches iOS to deprioritise future background wakes.
final class AppDelegate: NSObject, UIApplicationDelegate {

    weak var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        VideoOrientationController.supportedOrientations
    }

    // MARK: - File open handling

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard (ext == "opml" || ext == "xml"), let appState else { return false }
        Task { await appState.importOPML(from: url) }
        return true
    }

    // MARK: - Background URLSession

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        // Hand the completion handler to DownloadManager so it can call it after
        // urlSessionDidFinishEvents(forBackgroundURLSession:) fires.
        appState?.downloadManager.backgroundEventsCompletionHandler = completionHandler
    }

    // MARK: - BGTask registration

    private func registerBackgroundTasks() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.feedRefreshIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            AppDelegate.handleFeedRefresh(task)
        }
        AppLogger.shared.info("background.register", "Registered background app refresh task", metadata: [
            "identifier": BackgroundTaskCoordinator.feedRefreshIdentifier,
            "registered": "\(registered)"
        ])
        BackgroundTaskCoordinator.scheduleAppRefreshIfNeeded()
    }

    private static func handleFeedRefresh(_ task: BGAppRefreshTask) {
        AppLogger.shared.info("background.launch", "Background app refresh task started", metadata: [
            "identifier": task.identifier
        ])
        BackgroundTaskCoordinator.scheduleAppRefresh()

        let work = Task {
            let didRun = await AppState.shared.refreshSubscriptionsForBackground()
            AppLogger.shared.info("background.complete", "Background app refresh completed", metadata: [
                "identifier": task.identifier,
                "didRun": "\(didRun)"
            ])
            // "No feeds due" is still a successful run — reporting failure here
            // teaches the system to deprioritise future refresh wakes.
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            AppLogger.shared.warning("background.expired", "Background app refresh expired before finishing", metadata: [
                "identifier": task.identifier
            ])
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
