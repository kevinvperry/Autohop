import CarPlay
import UIKit
import BackgroundTasks
import MetricKit

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
final class AppDelegate: NSObject, UIApplicationDelegate, MXMetricManagerSubscriber {

    weak var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        registerMetricKitSubscriber()
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

    func applicationDidBecomeActive(_ application: UIApplication) {
        AppLogger.shared.info("app.didBecomeActive", "Application became active", metadata: [
            "applicationState": applicationStateLabel(application.applicationState)
        ])
        existingAppState()?.logResourceSnapshot(reason: "app.didBecomeActive", extra: [
            "applicationState": applicationStateLabel(application.applicationState)
        ], force: true)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        AppLogger.shared.info("app.willResignActive", "Application will resign active", metadata: [
            "applicationState": applicationStateLabel(application.applicationState)
        ])
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        let metadata = ["applicationState": applicationStateLabel(application.applicationState)]
        AppLogger.shared.info("app.didEnterBackground", "Application entered background", metadata: metadata)
        if let state = existingAppState() {
            state.logActivePlaybackDiagnostics(reason: "app.didEnterBackground", extra: metadata)
            state.logResourceSnapshot(reason: "app.didEnterBackground", extra: metadata, force: true)
            state.releasePausedPlaybackResourcesForBackground(reason: "app.didEnterBackground")
        } else {
            ResourceMonitor.shared.logSnapshot(reason: "app.didEnterBackground", context: metadata, force: true)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        let metadata = ["applicationState": applicationStateLabel(application.applicationState)]
        AppLogger.shared.warning("app.willTerminate", "Application will terminate", metadata: metadata)
        if let state = existingAppState() {
            state.logActivePlaybackDiagnostics(reason: "app.willTerminate", extra: metadata)
            state.logResourceWarningSnapshot(
                event: "app.willTerminate.resources",
                message: "Resource snapshot before application termination",
                reason: "app.willTerminate",
                extra: metadata
            )
        } else {
            ResourceMonitor.shared.logWarningSnapshot(
                event: "app.willTerminate.resources",
                message: "Resource snapshot before application termination",
                reason: "app.willTerminate",
                context: metadata
            )
        }
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

    private func registerMetricKitSubscriber() {
        MXMetricManager.shared.add(self)
        AppLogger.shared.info("metrics.register", "MetricKit subscriber registered")

        let pastPayloads = MXMetricManager.shared.pastPayloads
        if !pastPayloads.isEmpty {
            Self.logMetricPayloads(pastPayloads, source: "past")
        }

        let pastDiagnosticPayloads = MXMetricManager.shared.pastDiagnosticPayloads
        if !pastDiagnosticPayloads.isEmpty {
            Self.logDiagnosticPayloads(pastDiagnosticPayloads, source: "past")
        }
    }

    private static func handleFeedRefresh(_ task: BGAppRefreshTask) {
        let startedAt = Date()
        // Delivered on the main queue (register(using: nil)), so assumeIsolated is
        // safe for the main-actor status read.
        let refreshStatus = MainActor.assumeIsolated {
            BackgroundTaskCoordinator.backgroundRefreshStatusLabel
        }
        let startMetadata = [
            "identifier": task.identifier,
            "backgroundRefreshStatus": refreshStatus,
            "taskKind": "BGAppRefreshTask"
        ]
        AppLogger.shared.info("background.launch", "Background app refresh task started", metadata: startMetadata)
        MainActor.assumeIsolated {
            ResourceMonitor.shared.logSnapshot(reason: "background.appRefresh.start", context: startMetadata, force: true)
        }
        BackgroundTaskCoordinator.scheduleAppRefresh()

        let work = Task {
            let state = AppState.sharedOrBootstrap()
            state.logResourceSnapshot(reason: "background.appRefresh.workStart", extra: startMetadata, force: true)
            let didRun = await state.refreshSubscriptionsForBackground(taskIdentifier: task.identifier)
            // Unawaited on purpose: draining awaits full media transfers, which
            // must not hold setTaskCompleted (a stalled BG task teaches iOS to
            // stop granting wakes). Intents are persisted, so anything this Task
            // doesn't reach before suspension is retried at the next drain point.
            Task { @MainActor in
                await state.drainAutoDownloadIntents(reason: "bgRefresh")
            }
            let elapsedMs = elapsedMilliseconds(since: startedAt)
            AppLogger.shared.info("background.complete", "Background app refresh completed", metadata: [
                "identifier": task.identifier,
                "didRun": "\(didRun)",
                "elapsedMs": elapsedMs
            ])
            state.logResourceSnapshot(reason: "background.appRefresh.complete", extra: [
                "identifier": task.identifier,
                "didRun": "\(didRun)",
                "elapsedMs": elapsedMs,
                "taskKind": "BGAppRefreshTask"
            ], force: true)
            // "No feeds due" is still a successful run — reporting failure here
            // teaches the system to deprioritise future refresh wakes.
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            let elapsedMs = elapsedMilliseconds(since: startedAt)
            AppLogger.shared.warning("background.expired", "Background app refresh expired before finishing", metadata: [
                "identifier": task.identifier,
                "elapsedMs": elapsedMs,
                "taskKind": "BGAppRefreshTask"
            ])
            Task { @MainActor in
                let state = AppState.sharedOrBootstrap()
                state.logResourceWarningSnapshot(
                    event: "background.expired.resources",
                    message: "Resource snapshot at background app refresh expiration",
                    reason: "background.expired",
                    extra: [
                        "identifier": task.identifier,
                        "elapsedMs": elapsedMs,
                        "taskKind": "BGAppRefreshTask"
                    ]
                )
                state.cancelRefreshCycleIfBackgroundOnly(reason: "background.expired")
            }
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private static func handleFeedProcessing(_ task: BGProcessingTask) {
        let startedAt = Date()
        // Delivered on the main queue (register(using: nil)), so assumeIsolated is
        // safe for the main-actor status read.
        let refreshStatus = MainActor.assumeIsolated {
            BackgroundTaskCoordinator.backgroundRefreshStatusLabel
        }
        let startMetadata = [
            "identifier": task.identifier,
            "backgroundRefreshStatus": refreshStatus,
            "taskKind": "BGProcessingTask"
        ]
        AppLogger.shared.info("background.processingLaunch", "Background processing task started", metadata: startMetadata)
        MainActor.assumeIsolated {
            ResourceMonitor.shared.logSnapshot(reason: "background.processing.start", context: startMetadata, force: true)
        }
        BackgroundTaskCoordinator.scheduleProcessing()

        let work = Task {
            let state = AppState.sharedOrBootstrap()
            state.logResourceSnapshot(reason: "background.processing.workStart", extra: startMetadata, force: true)
            let didRun = await state.refreshSubscriptionsForProcessing(taskIdentifier: task.identifier)
            // Unawaited for the same reason as the refresh handler: never hold
            // setTaskCompleted on media transfers. BGProcessing runs are long
            // (charging + Wi-Fi), so this usually drains everything.
            Task { @MainActor in
                await state.drainAutoDownloadIntents(reason: "bgProcessing")
            }
            let elapsedMs = elapsedMilliseconds(since: startedAt)
            AppLogger.shared.info("background.processingComplete", "Background processing completed", metadata: [
                "identifier": task.identifier,
                "didRun": "\(didRun)",
                "elapsedMs": elapsedMs
            ])
            state.logResourceSnapshot(reason: "background.processing.complete", extra: [
                "identifier": task.identifier,
                "didRun": "\(didRun)",
                "elapsedMs": elapsedMs,
                "taskKind": "BGProcessingTask"
            ], force: true)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            let elapsedMs = elapsedMilliseconds(since: startedAt)
            AppLogger.shared.warning("background.processingExpired", "Background processing expired before finishing", metadata: [
                "identifier": task.identifier,
                "elapsedMs": elapsedMs,
                "taskKind": "BGProcessingTask"
            ])
            Task { @MainActor in
                let state = AppState.sharedOrBootstrap()
                state.logResourceWarningSnapshot(
                    event: "background.processingExpired.resources",
                    message: "Resource snapshot at background processing expiration",
                    reason: "background.processing.expired",
                    extra: [
                        "identifier": task.identifier,
                        "elapsedMs": elapsedMs,
                        "taskKind": "BGProcessingTask"
                    ]
                )
                state.cancelRefreshCycleIfBackgroundOnly(reason: "background.processing.expired")
            }
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXMetricPayload]) {
        Self.logMetricPayloads(payloads, source: "daily")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.logDiagnosticPayloads(payloads, source: "daily")
    }

    private static func logMetricPayloads(_ payloads: [MXMetricPayload], source: String) {
        for (index, payload) in payloads.enumerated() {
            var base = [
                "source": source,
                "payloadIndex": "\(index)",
                "periodStart": iso8601(payload.timeStampBegin),
                "periodEnd": iso8601(payload.timeStampEnd),
                "latestApplicationVersion": payload.latestApplicationVersion,
                "includesMultipleApplicationVersions": "\(payload.includesMultipleApplicationVersions)"
            ]

            guard let exitMetrics = payload.applicationExitMetrics else {
                AppLogger.shared.info("metrics.metricPayload", "MetricKit metric payload received", metadata: base)
                continue
            }

            let background = exitMetrics.backgroundExitData
            let foreground = exitMetrics.foregroundExitData
            let unexpectedBackground =
                background.cumulativeMemoryResourceLimitExitCount
                + background.cumulativeCPUResourceLimitExitCount
                + background.cumulativeMemoryPressureExitCount
                + background.cumulativeBadAccessExitCount
                + background.cumulativeAbnormalExitCount
                + background.cumulativeIllegalInstructionExitCount
                + background.cumulativeAppWatchdogExitCount
                + background.cumulativeSuspendedWithLockedFileExitCount
                + background.cumulativeBackgroundTaskAssertionTimeoutExitCount

            base.merge([
                "backgroundNormal": "\(background.cumulativeNormalAppExitCount)",
                "backgroundMemoryLimit": "\(background.cumulativeMemoryResourceLimitExitCount)",
                "backgroundCPULimit": "\(background.cumulativeCPUResourceLimitExitCount)",
                "backgroundMemoryPressure": "\(background.cumulativeMemoryPressureExitCount)",
                "backgroundBadAccess": "\(background.cumulativeBadAccessExitCount)",
                "backgroundAbnormal": "\(background.cumulativeAbnormalExitCount)",
                "backgroundIllegalInstruction": "\(background.cumulativeIllegalInstructionExitCount)",
                "backgroundWatchdog": "\(background.cumulativeAppWatchdogExitCount)",
                "backgroundSuspendedWithLockedFile": "\(background.cumulativeSuspendedWithLockedFileExitCount)",
                "backgroundTaskAssertionTimeout": "\(background.cumulativeBackgroundTaskAssertionTimeoutExitCount)",
                "backgroundUnexpectedTotal": "\(unexpectedBackground)",
                "foregroundMemoryLimit": "\(foreground.cumulativeMemoryResourceLimitExitCount)",
                "foregroundAbnormal": "\(foreground.cumulativeAbnormalExitCount)",
                "foregroundWatchdog": "\(foreground.cumulativeAppWatchdogExitCount)"
            ]) { _, new in new }

            if unexpectedBackground > 0 {
                AppLogger.shared.warning("metrics.backgroundExit", "MetricKit background exit metrics reported unexpected exits", metadata: base)
            } else {
                AppLogger.shared.info("metrics.backgroundExit", "MetricKit background exit metrics received", metadata: base)
            }
        }
    }

    private static func logDiagnosticPayloads(_ payloads: [MXDiagnosticPayload], source: String) {
        for (index, payload) in payloads.enumerated() {
            let diagnosticCount =
                (payload.cpuExceptionDiagnostics?.count ?? 0)
                + (payload.diskWriteExceptionDiagnostics?.count ?? 0)
                + (payload.hangDiagnostics?.count ?? 0)
                + (payload.appLaunchDiagnostics?.count ?? 0)
                + (payload.crashDiagnostics?.count ?? 0)
            let metadata = [
                "source": source,
                "payloadIndex": "\(index)",
                "periodStart": iso8601(payload.timeStampBegin),
                "periodEnd": iso8601(payload.timeStampEnd),
                "cpuExceptionDiagnostics": "\(payload.cpuExceptionDiagnostics?.count ?? 0)",
                "diskWriteExceptionDiagnostics": "\(payload.diskWriteExceptionDiagnostics?.count ?? 0)",
                "hangDiagnostics": "\(payload.hangDiagnostics?.count ?? 0)",
                "appLaunchDiagnostics": "\(payload.appLaunchDiagnostics?.count ?? 0)",
                "crashDiagnostics": "\(payload.crashDiagnostics?.count ?? 0)",
                "diagnosticTotal": "\(diagnosticCount)"
            ]
            if diagnosticCount > 0 {
                AppLogger.shared.warning("metrics.diagnostics", "MetricKit diagnostics received", metadata: metadata)
            } else {
                AppLogger.shared.info("metrics.diagnostics", "MetricKit diagnostic payload received", metadata: metadata)
            }
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> String {
        "\(Int((Date().timeIntervalSince(start) * 1000).rounded()))"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func existingAppState() -> AppState? {
        if let appState { return appState }
        let shared: AppState? = AppState.shared
        return shared
    }

    private func applicationStateLabel(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
