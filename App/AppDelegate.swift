import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {

    // Set by AutohopApp once appState is available.
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
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleFeedRefresh(task)
        }
        AppLogger.shared.info("background.register", "Registered background app refresh task", metadata: [
            "identifier": BackgroundTaskCoordinator.feedRefreshIdentifier,
            "registered": "\(registered)"
        ])
        // Schedule the first background wake-up.
        BackgroundTaskCoordinator.scheduleAppRefresh()
    }

    private func handleFeedRefresh(_ task: BGAppRefreshTask) {
        AppLogger.shared.info("background.launch", "Background app refresh task started", metadata: [
            "identifier": task.identifier
        ])
        // Re-schedule so the system continues to wake the app after this run.
        BackgroundTaskCoordinator.scheduleAppRefresh()

        let work = Task { [weak self] in
            guard let appState = self?.appState else {
                AppLogger.shared.error("background.noAppState", "Background app refresh had no app state available", metadata: [
                    "identifier": task.identifier
                ])
                task.setTaskCompleted(success: false)
                return
            }
            let didRun = await appState.refreshSubscriptionsForBackground()
            AppLogger.shared.info("background.complete", "Background app refresh completed", metadata: [
                "identifier": task.identifier,
                "didRun": "\(didRun)"
            ])
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
