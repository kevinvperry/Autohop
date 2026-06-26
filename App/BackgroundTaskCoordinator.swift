import Foundation
import BackgroundTasks

// AI CONTEXT — App/BackgroundTaskCoordinator.swift
// Stateless helper owning the BGAppRefreshTask + BGProcessingTask identifiers and
// submit logic for Release Radar background feed refresh. BGAppRefreshTask is the
// short opportunistic wake (~30 s); BGProcessingTask is a longer charging+Wi-Fi
// catch-up (several minutes) that drains the due-feed backlog (e.g. overnight).
// Called from AppDelegate (registration/
// initial schedule) and AppState (re-schedule with the next feed due date after
// each refresh cycle). 15-minute floor on earliestBeginDate; identifier must
// stay in sync with Info.plist BGTaskSchedulerPermittedIdentifiers. Diagnostics
// intentionally log requested vs effective earliestBeginDate plus pending-request
// skips so background-refresh reviews can separate "Autohop asked at the right
// time" from "iOS delivered the wake later" or "a prior request was already
// waiting."

/// Owns the `BGTaskScheduler` registration identifiers and submit logic.
///
/// The task identifier must also appear in Info.plist under
/// `BGTaskSchedulerPermittedIdentifiers` for the system to allow scheduling.
struct BackgroundTaskCoordinator {

    static let feedRefreshIdentifier = "com.autohop.feedrefresh"
    static let feedProcessingIdentifier = "com.autohop.feedprocessing"

    /// Schedules a refresh only when no request is already pending, preventing
    /// every app launch from resetting the earliestBeginDate clock.
    static func scheduleAppRefreshIfNeeded() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            if let pending = requests.first(where: { $0.identifier == feedRefreshIdentifier }) {
                AppLogger.shared.info("background.scheduleSkipped", "Background app refresh request is already pending", metadata: [
                    "identifier": feedRefreshIdentifier,
                    "pendingEarliestBeginDate": pending.earliestBeginDate?.description ?? "unknown"
                ])
                return
            }
            scheduleAppRefresh()
        }
    }

    /// Submits a `BGAppRefreshTaskRequest`. Pass the soonest feed due date so iOS
    /// gets accurate scheduling information; wakes are opportunistic and the
    /// actual time is not guaranteed. Floor: 15 minutes from now.
    static func scheduleAppRefresh(earliestBeginDate: Date? = nil) {
        let floorDate = Date(timeIntervalSinceNow: 15 * 60)
        let requestedDate = earliestBeginDate
        let requestedSeconds = requestedDate.map { Int($0.timeIntervalSinceNow.rounded()) }
        let request = BGAppRefreshTaskRequest(identifier: feedRefreshIdentifier)
        request.earliestBeginDate = max(requestedDate ?? floorDate, floorDate)
        let effectiveDate = request.earliestBeginDate
        let effectiveSeconds = effectiveDate.map { Int($0.timeIntervalSinceNow.rounded()) }
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.info("background.schedule", "Scheduled background app refresh", metadata: [
                "identifier": feedRefreshIdentifier,
                "requestedEarliestBeginDate": requestedDate?.description ?? "none",
                "effectiveEarliestBeginDate": effectiveDate?.description ?? "unknown",
                "floorEarliestBeginDate": floorDate.description,
                "secondsUntilRequested": requestedSeconds.map(String.init) ?? "none",
                "secondsUntilEffective": effectiveSeconds.map(String.init) ?? "unknown",
                "clampedToFifteenMinuteFloor": "\(requestedDate.map { $0 < floorDate } ?? true)"
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

    /// Schedules a processing catch-up only when none is pending, so launches don't
    /// reset the clock.
    static func scheduleProcessingIfNeeded() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            guard !requests.contains(where: { $0.identifier == feedProcessingIdentifier }) else { return }
            scheduleProcessing()
        }
    }

    /// Submits a `BGProcessingTaskRequest` gated on external power + network for a
    /// longer feed catch-up than BGAppRefreshTask allows. No earliestBeginDate floor:
    /// iOS picks the ideal charging-idle window (typically overnight). Identifier must
    /// also appear in Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: feedProcessingIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.info("background.scheduleProcessing", "Scheduled background processing catch-up", metadata: [
                "identifier": feedProcessingIdentifier
            ])
        } catch BGTaskScheduler.Error.notPermitted {
            AppLogger.shared.error("background.scheduleProcessingFailed", "Background processing was not permitted", metadata: [
                "identifier": feedProcessingIdentifier,
                "reason": "notPermitted"
            ])
        } catch {
            AppLogger.shared.error("background.scheduleProcessingFailed", "Background processing could not be scheduled", metadata: [
                "identifier": feedProcessingIdentifier,
                "error": String(describing: error)
            ])
        }
    }
}
