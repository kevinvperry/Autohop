import CarPlay
import UIKit
import BackgroundTasks

// AI CONTEXT — App/AppDelegate.swift
// UIKit delegate bridged into the SwiftUI app via @UIApplicationDelegateAdaptor
// (see AutohopApp.swift). Handles the five things SwiftUI cannot:
//  1. BGTaskScheduler registration for "com.autohop.feedrefresh" (BGAppRefreshTask,
//     short ~30 s wake) AND "com.autohop.feedprocessing" (BGProcessingTask, a longer
//     charging+Wi-Fi catch-up) — both registered before didFinishLaunching returns.
//     The refresh handler calls refreshSubscriptionsForBackground(taskIdentifier:);
//     the processing handler calls refreshSubscriptionsForProcessing(taskIdentifier:)
//     for a fuller, uncapped due-feed sweep that drains the backlog (e.g. overnight).
//     On expiration, cancelRefreshCycleIfBackgroundOnly cancels the active refresh
//     cycle ONLY when no live foreground/audio context owns it (otherwise it detaches
//     and lets that context finish) — a real cancel checkpoints selected-but-unfinished
//     feeds into Release Radar's deferred backlog. Task
//     identifiers are forwarded for diagnostics so logs can distinguish each wake
//     source (BGAppRefreshTask / BGProcessingTask / foreground / background-audio).
//  2. Background URLSession wake: bootstraps AppState on demand, then stores the
//     system completion handler on DownloadManager so it fires after
//     urlSessionDidFinishEvents.
//  3. OPML/.xml file-open events → AppState.importOPML, bootstrapping on demand
//     because AppState is no longer created in AutohopApp.init.
//  4. Orientation lock: delegates to VideoOrientationController so landscape
//     is only allowed during full-screen video playback.
//  5. Installs NotificationService as the UNUserNotificationCenter delegate
//     (before launch returns) so Sleep Schedule "Still Listening" action taps
//     that wake the app from the lock screen are handled.
//  6. CarPlay cold-launch scene routing: when the app is opened from CarPlay
//     after the iPhone app has been swiped closed, iOS may connect only the
//     CarPlay template scene. The delegate returns an explicit CarPlay scene
//     configuration so CarPlaySceneDelegate is used even without an iPhone
//     WindowGroup already alive.
//  7. Launch diagnostics: logs `app.launch` at didFinishLaunching with
//     launchState (background = iOS system-launched us, a good sign; foreground =
//     user-initiated, the only way a terminated/force-quit app comes back) and
//     the Background App Refresh authorisation. The BG task entry logs
//     (background.launch / background.processingLaunch) also carry the
//     authorisation, so a refresh review can tell "iOS never fired the task"
//     (no entry log) from "fired but not permitted".
// GOTCHA: a BGAppRefreshTask run with "no feeds due" still reports success —
// reporting failure teaches iOS to deprioritise future background wakes.
// GOTCHA: iOS never runs BGTasks for a user-force-quit app; an app.launch with
// launchState=foreground on every start (never background) is the log signature
// of that — the app is only ever coming back because the user reopened it.
final class AppDelegate: NSObject, UIApplicationDelegate {

    weak var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        // Record how this launch began and whether iOS will grant background
        // wakes at all. launchState=background means the system cold-launched us
        // (BGTask / push) — proof iOS is willing to wake the app; launchState=
        // foreground on every launch means the app was terminated and only the
        // user brought it back (a force-quit app never gets background wakes).
        let launchState: String
        switch application.applicationState {
        case .background: launchState = "background"
        case .active, .inactive: launchState = "foreground"
        @unknown default: launchState = "unknown"
        }
        AppLogger.shared.info("app.launch", "App launched", metadata: [
            "launchState": launchState,
            "backgroundRefreshStatus": BackgroundTaskCoordinator.backgroundRefreshStatusLabel
        ])
        // Install the notification-center delegate before launch returns so
        // "Still Listening" action taps that wake the app are delivered.
        NotificationService.shared.configure()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" {
            let configuration = UISceneConfiguration(
                name: "CarPlay",
                sessionRole: connectingSceneSession.role
            )
            configuration.sceneClass = CPTemplateApplicationScene.self
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }

        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
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
        guard ext == "opml" || ext == "xml" else { return false }
        Task { @MainActor [weak self] in
            let state = AppState.sharedOrBootstrap()
            self?.appState = state
            _ = await state.importOPML(from: url)
        }
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
        Task { @MainActor [weak self] in
            let state = AppState.sharedOrBootstrap()
            self?.appState = state
            state.downloadManager.backgroundEventsCompletionHandler = completionHandler
        }
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

        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.feedProcessingIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else { return }
            AppDelegate.handleFeedProcessing(task)
        }
        AppLogger.shared.info("background.register", "Registered background processing task", metadata: [
            "identifier": BackgroundTaskCoordinator.feedProcessingIdentifier,
            "registered": "\(processingRegistered)"
        ])

        BackgroundTaskCoordinator.scheduleAppRefreshIfNeeded()
        BackgroundTaskCoordinator.scheduleProcessingIfNeeded()
    }

    private static func handleFeedRefresh(_ task: BGAppRefreshTask) {
        // Delivered on the main queue (register(using: nil)), so assumeIsolated is
        // safe for the main-actor status read.
        let refreshStatus = MainActor.assumeIsolated {
            BackgroundTaskCoordinator.backgroundRefreshStatusLabel
        }
        AppLogger.shared.info("background.launch", "Background app refresh task started", metadata: [
            "identifier": task.identifier,
            "backgroundRefreshStatus": refreshStatus
        ])
        BackgroundTaskCoordinator.scheduleAppRefresh()

        let work = Task {
            let state = AppState.sharedOrBootstrap()
            let didRun = await state.refreshSubscriptionsForBackground(taskIdentifier: task.identifier)
            // Unawaited on purpose: draining awaits full media transfers, which
            // must not hold setTaskCompleted (a stalled BG task teaches iOS to
            // stop granting wakes). Intents are persisted, so anything this Task
            // doesn't reach before suspension is retried at the next drain point.
            Task { @MainActor in
                await state.drainAutoDownloadIntents(reason: "bgRefresh")
            }
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
            Task { @MainActor in
                AppState.sharedOrBootstrap().cancelRefreshCycleIfBackgroundOnly(reason: "background.expired")
            }
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private static func handleFeedProcessing(_ task: BGProcessingTask) {
        // Delivered on the main queue (register(using: nil)), so assumeIsolated is
        // safe for the main-actor status read.
        let refreshStatus = MainActor.assumeIsolated {
            BackgroundTaskCoordinator.backgroundRefreshStatusLabel
        }
        AppLogger.shared.info("background.processingLaunch", "Background processing task started", metadata: [
            "identifier": task.identifier,
            "backgroundRefreshStatus": refreshStatus
        ])
        BackgroundTaskCoordinator.scheduleProcessing()

        let work = Task {
            let state = AppState.sharedOrBootstrap()
            let didRun = await state.refreshSubscriptionsForProcessing(taskIdentifier: task.identifier)
            // Unawaited for the same reason as the refresh handler: never hold
            // setTaskCompleted on media transfers. BGProcessing runs are long
            // (charging + Wi-Fi), so this usually drains everything.
            Task { @MainActor in
                await state.drainAutoDownloadIntents(reason: "bgProcessing")
            }
            AppLogger.shared.info("background.processingComplete", "Background processing completed", metadata: [
                "identifier": task.identifier,
                "didRun": "\(didRun)"
            ])
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            AppLogger.shared.warning("background.processingExpired", "Background processing expired before finishing", metadata: [
                "identifier": task.identifier
            ])
            Task { @MainActor in
                AppState.sharedOrBootstrap().cancelRefreshCycleIfBackgroundOnly(reason: "background.processing.expired")
            }
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
