import Foundation
import BackgroundTasks

// AI CONTEXT — App/BackgroundTaskCoordinator.swift
// Stateless helper owning the BGAppRefreshTask identifier and submit logic for
// Release Radar background feed refresh. Called from AppDelegate (registration/
// initial schedule) and AppState (re-schedule with the next feed due date after
// each refresh cycle). 15-minute floor on earliestBeginDate; identifier must
// stay in sync with Info.plist BGTaskSchedulerPermittedIdentifiers.

/// Owns the `BGTaskScheduler` registration identifiers and submit logic.
///
/// The task identifier must also appear in Info.plist under
/// `BGTaskSchedulerPermittedIdentifiers` for the system to allow scheduling.
struct BackgroundTaskCoordinator {

    static let feedRefreshIdentifier = "com.autohop.feedrefresh"

    /// Schedules a refresh only when no request is already pending, preventing
    /// every app launch from resetting the earliestBeginDate clock.
    static func scheduleAppRefreshIfNeeded() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            guard !requests.contains(where: { $0.identifier == feedRefreshIdentifier }) else { return }
            scheduleAppRefresh()
        }
    }

    /// Submits a `BGAppRefreshTaskRequest`. Pass the soonest feed due date so iOS
    /// gets accurate scheduling information; wakes are opportunistic and the
    /// actual time is not guaranteed. Floor: 15 minutes from now.
    static func scheduleAppRefresh(earliestBeginDate: Date? = nil) {
        let floorDate = Date(timeIntervalSinceNow: 15 * 60)
        let request = BGAppRefreshTaskRequest(identifier: feedRefreshIdentifier)
        request.earliestBeginDate = max(earliestBeginDate ?? floorDate, floorDate)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.info("background.schedule", "Scheduled background app refresh", metadata: [
                "identifier": feedRefreshIdentifier,
                "earliestBeginDate": request.earliestBeginDate?.description ?? "unknown"
            ])
        } catch BGTaskScheduler.Error.notPermitted {
            AppLogger.shared.error("background.scheduleFailed", "Background app refresh was not permitted", metadata: [
                "identifier": feedRefreshIdentifier,
                "reason": "notPermitted"
            ])
        } catch {
            AppLogger.shared.error("background.scheduleFailed", "Background app refresh could not be scheduled", metadata: [
                "identifier": feedRefreshIdentifier,
                "error": String(describing: error)
            ])
        }
    }
}
