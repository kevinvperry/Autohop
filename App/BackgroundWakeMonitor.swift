import Foundation

// AI CONTEXT — App/BackgroundWakeMonitor.swift
//
// PURPOSE / OWNERSHIP:
// Process-wide, MainActor-isolated diagnostic scope for OS-owned BGAppRefresh
// and BGProcessing executions. AppDelegate opens one session at handler entry
// and closes it on the single completion-gate winner. Feed, download, archive,
// bootstrap, and widget-projection owners contribute small counters without
// depending on AppDelegate or retaining the background task.
//
// INVARIANTS:
// - A wake emits exactly one `background.wakeSummary` through its handler.
// - Multiple overlapping OS wakes are supported; a domain event contributes to
//   every active wake because the OS execution windows overlap in real time.
// - This type records observations only. It never starts/cancels feed, download,
//   archive, widget, or BGTask work.
// - `hasActiveWake` is the authoritative suppression signal for nonessential
//   widget projection. Deferred widget reasons remain owned by
//   WidgetSnapshotCoordinator and are resumed only from a safe runtime context.
// - Counts describe work performed while the BGTask execution window was open;
//   background URLSession completions delivered after `setTaskCompleted` belong
//   to a later process wake and are intentionally not attributed retroactively.

@MainActor
final class BackgroundWakeMonitor {
    enum Kind: String {
        case appRefresh
        case processing
    }

    enum Outcome: String {
        case completed
        case cooperativeDeadline
        case expired
    }

    struct Summary {
        let metadata: [String: String]
    }

    static let shared = BackgroundWakeMonitor()

    private struct Session {
        let id: UUID
        let kind: Kind
        let identifier: String
        let startedAt: Date
        var dueFeeds = 0
        var selectedFeeds = 0
        var feedAttempts = 0
        var feedsCompleted = 0
        var downloadsSubmitted = 0
        var downloadsCompleted = 0
        var archivePasses = 0
        var episodesArchived = 0
        var widgetProjectionEventsDeferred = 0
        var bootstrapTotalMilliseconds: Double?
        var bootstrapConstructionMilliseconds: Double?
    }

    private let now: () -> Date
    private var sessions: [UUID: Session] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var hasActiveWake: Bool {
        !sessions.isEmpty
    }

    @discardableResult
    func begin(kind: Kind, identifier: String) -> UUID {
        let id = UUID()
        sessions[id] = Session(
            id: id,
            kind: kind,
            identifier: identifier,
            startedAt: now()
        )
        return id
    }

    func recordFeedPlan(due: Int, selected: Int) {
        updateAll {
            $0.dueFeeds = max($0.dueFeeds, due)
            // A BGAppRefresh wake may run one adaptive follow-up batch. Selected
            // is additive across plans, while due remains the largest backlog
            // observed during the wake.
            $0.selectedFeeds += max(0, selected)
        }
    }

    func recordFeedAttempt() {
        updateAll { $0.feedAttempts += 1 }
    }

    func recordFeedCompletion() {
        updateAll { $0.feedsCompleted += 1 }
    }

    func recordDownloadSubmitted() {
        updateAll { $0.downloadsSubmitted += 1 }
    }

    func recordDownloadCompleted() {
        updateAll { $0.downloadsCompleted += 1 }
    }

    func recordAutoArchivePass(archivedCount: Int) {
        updateAll {
            $0.archivePasses += 1
            $0.episodesArchived += max(0, archivedCount)
        }
    }

    func recordWidgetProjectionDeferred() {
        updateAll { $0.widgetProjectionEventsDeferred += 1 }
    }

    func recordBootstrap(
        totalMilliseconds: Double,
        constructionMilliseconds: Double
    ) {
        updateAll {
            $0.bootstrapTotalMilliseconds = totalMilliseconds
            $0.bootstrapConstructionMilliseconds = constructionMilliseconds
        }
    }

    func finish(
        id: UUID,
        outcome: Outcome,
        didRun: Bool?
    ) -> Summary? {
        guard let session = sessions.removeValue(forKey: id) else {
            return nil
        }
        let elapsedMilliseconds = max(
            0,
            now().timeIntervalSince(session.startedAt) * 1_000
        )
        var metadata = [
            "wakeID": session.id.uuidString,
            "identifier": session.identifier,
            "kind": session.kind.rawValue,
            "outcome": outcome.rawValue,
            "elapsedMs": String(format: "%.0f", elapsedMilliseconds),
            "dueFeeds": "\(session.dueFeeds)",
            "selectedFeeds": "\(session.selectedFeeds)",
            "feedAttempts": "\(session.feedAttempts)",
            "feedsCompleted": "\(session.feedsCompleted)",
            "feedsUnfinished":
                "\(max(0, session.feedAttempts - session.feedsCompleted))",
            "downloadsSubmitted": "\(session.downloadsSubmitted)",
            "downloadsCompletedDuringWake":
                "\(session.downloadsCompleted)",
            "autoArchivePasses": "\(session.archivePasses)",
            "episodesArchived": "\(session.episodesArchived)",
            "widgetProjectionEventsDeferred":
                "\(session.widgetProjectionEventsDeferred)"
        ]
        metadata["didRun"] = didRun.map(String.init) ?? "unknown"
        metadata["bootstrapTotalMs"] = session.bootstrapTotalMilliseconds.map {
            String(format: "%.1f", $0)
        } ?? "notColdLaunch"
        metadata["bootstrapConstructionMs"] =
            session.bootstrapConstructionMilliseconds.map {
                String(format: "%.1f", $0)
            } ?? "notColdLaunch"
        return Summary(metadata: metadata)
    }

    private func updateAll(_ mutation: (inout Session) -> Void) {
        for id in sessions.keys {
            guard var session = sessions[id] else { continue }
            mutation(&session)
            sessions[id] = session
        }
    }
}
