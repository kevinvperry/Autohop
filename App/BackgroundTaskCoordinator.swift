import Foundation
import BackgroundTasks
import UIKit

// AI CONTEXT — App/BackgroundTaskCoordinator.swift
// Scheduling policy owner for the BGAppRefreshTask + BGProcessingTask identifiers
// used by Release Radar background feed refresh. BGAppRefreshTask is the
// short opportunistic wake (~30 s); BGProcessingTask is a longer charging+Wi-Fi
// catch-up (several minutes) that drains the due-feed backlog (e.g. overnight).
// Called from AppDelegate (registration/
// initial schedule) and AppState (re-schedule with the next feed due date after
// each refresh cycle). 15-minute floor on earliestBeginDate; identifier must
// stay in sync with Info.plist BGTaskSchedulerPermittedIdentifiers. Diagnostics
// intentionally log requested vs effective earliestBeginDate plus pending-request
// skips so background-refresh reviews can separate "Autohop asked at the right
// time" from "iOS delivered the wake later" or "a prior request was already
// waiting." BGProcessing is outcome-paced and persisted: launch scheduling uses a
// 12-hour delay, useful/empty runs use 18/24 hours, and expirations use exponential
// retry backoff. Random positive jitter prevents synchronized, metronomic wakes.
// Never submit a replacement processing request at task start; submit it only after
// the run outcome is known. BGAppRefresh feed-date selection calls
// effectiveFeedDueDate so an active per-feed failure backoff overrides that feed's
// stale/overdue prediction without delaying healthy feeds. `backgroundRefreshStatusLabel` exposes the OS Background App Refresh
// authorisation for the launch log (AppDelegate app.launch) and the Release Radar
// export header, so a review can rule the permission in/out from the log alone.

/// Owns the `BGTaskScheduler` registration identifiers and submit logic.
///
/// The task identifier must also appear in Info.plist under
/// `BGTaskSchedulerPermittedIdentifiers` for the system to allow scheduling.
struct BackgroundTaskCoordinator {

    static let feedRefreshIdentifier = "com.autohop.feedrefresh"
    static let feedProcessingIdentifier = "com.autohop.feedprocessing"

    /// Pure policy shared by AppState's next-feed selector and unit tests. A feed
    /// that is already overdue but temporarily backed off must not anchor every
    /// BGAppRefresh request to the 15-minute floor. Expired backoff is ignored;
    /// active backoff delays only that feed, never unrelated healthy feeds.
    static func effectiveFeedDueDate(
        feedDueDate: Date,
        backoffUntil: Date?,
        now: Date
    ) -> Date {
        guard let backoffUntil, backoffUntil > now else { return feedDueDate }
        return max(feedDueDate, backoffUntil)
    }

    /// Why the next long-running catch-up is being requested. The distinction is
    /// deliberately retained in logs and persisted scheduling state so diagnostics
    /// can explain whether a short retry followed an expiry or a normal daily cadence.
    enum ProcessingScheduleOutcome: Equatable {
        case initial
        case completed(didRun: Bool)
        case expired

        var label: String {
            switch self {
            case .initial: return "initial"
            case .completed(true): return "completedWork"
            case .completed(false): return "completedNoWork"
            case .expired: return "expired"
            }
        }
    }

    private enum ProcessingStateKey {
        static let consecutiveFailures = "background.processing.consecutiveFailures"
        static let nextEligibleDate = "background.processing.nextEligibleDate"
        static let lastSuccessfulDate = "background.processing.lastSuccessfulDate"
    }

    /// Human-readable Background App Refresh authorisation, for diagnostics.
    /// `.available` = iOS may run our BGTasks; `.denied` = user turned it off in
    /// Settings; `.restricted` = Screen Time / MDM block. Logged at launch and
    /// stamped into the Release Radar export header so a review can confirm the OS
    /// permission from the log alone (a `submit()` succeeding already implies
    /// `.available`, but an explicit label removes the guesswork). Must be read on
    /// the main actor — `backgroundRefreshStatus` is a UIApplication API.
    @MainActor
    static var backgroundRefreshStatusLabel: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:  return "available"
        case .denied:     return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

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

    /// Schedules a processing catch-up only when none is pending. App launch uses
    /// `.initial`; task completion/expiry supplies the actual outcome. The pending
    /// guard prevents relaunches and duplicate completion paths from resetting the
    /// persisted eligibility clock.
    static func scheduleProcessingIfNeeded(after outcome: ProcessingScheduleOutcome = .initial) {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            if let pending = requests.first(where: { $0.identifier == feedProcessingIdentifier }) {
                AppLogger.shared.info("background.scheduleProcessingSkipped", "Background processing request is already pending", metadata: [
                    "identifier": feedProcessingIdentifier,
                    "outcome": outcome.label,
                    "pendingEarliestBeginDate": pending.earliestBeginDate?.description ?? "unknown"
                ])
                return
            }
            scheduleProcessing(after: outcome)
        }
    }

    /// Pure delay policy exposed internally for deterministic unit tests. Jitter is
    /// positive rather than ± so an outcome can never retry earlier than its base
    /// safety interval. Expiry backoff is 2, 4, 8, 16, then 24 hours.
    static func processingDelay(
        after outcome: ProcessingScheduleOutcome,
        consecutiveFailures: Int,
        jitterUnit: Double
    ) -> TimeInterval {
        let hour: TimeInterval = 60 * 60
        let base: TimeInterval
        let jitterWindow: TimeInterval
        switch outcome {
        case .initial:
            base = 12 * hour
            jitterWindow = 30 * 60
        case .completed(true):
            base = 18 * hour
            jitterWindow = 60 * 60
        case .completed(false):
            base = 24 * hour
            jitterWindow = 60 * 60
        case .expired:
            let exponent = min(max(consecutiveFailures - 1, 0), 4)
            base = min(2 * hour * pow(2, Double(exponent)), 24 * hour)
            jitterWindow = 30 * 60
        }
        return base + min(max(jitterUnit, 0), 1) * jitterWindow
    }

    /// Submits a charging + network `BGProcessingTaskRequest` with a persisted,
    /// outcome-derived earliest date. iOS still chooses the actual idle window.
    /// Identifier must appear in Info.plist permitted identifiers.
    static func scheduleProcessing(
        after outcome: ProcessingScheduleOutcome,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        jitterUnit: Double = Double.random(in: 0...1)
    ) {
        let priorFailures = defaults.integer(forKey: ProcessingStateKey.consecutiveFailures)
        let failureCount: Int
        switch outcome {
        case .expired:
            failureCount = min(priorFailures + 1, 5)
        case .completed:
            failureCount = 0
            defaults.set(now, forKey: ProcessingStateKey.lastSuccessfulDate)
        case .initial:
            failureCount = priorFailures
        }
        defaults.set(failureCount, forKey: ProcessingStateKey.consecutiveFailures)

        let delay = processingDelay(after: outcome, consecutiveFailures: failureCount, jitterUnit: jitterUnit)
        let policyDate = now.addingTimeInterval(delay)
        let persistedDate = defaults.object(forKey: ProcessingStateKey.nextEligibleDate) as? Date
        let effectiveDate = max(policyDate, persistedDate ?? policyDate)
        let request = BGProcessingTaskRequest(identifier: feedProcessingIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = effectiveDate
        do {
            try BGTaskScheduler.shared.submit(request)
            defaults.set(effectiveDate, forKey: ProcessingStateKey.nextEligibleDate)
            AppLogger.shared.info("background.scheduleProcessing", "Scheduled background processing catch-up", metadata: [
                "identifier": feedProcessingIdentifier,
                "outcome": outcome.label,
                "consecutiveFailures": "\(failureCount)",
                "policyEarliestBeginDate": policyDate.description,
                "effectiveEarliestBeginDate": effectiveDate.description,
                "secondsUntilEffective": "\(Int(effectiveDate.timeIntervalSince(now).rounded()))",
                "preservedPersistedEligibility": "\(persistedDate.map { $0 > policyDate } ?? false)"
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
