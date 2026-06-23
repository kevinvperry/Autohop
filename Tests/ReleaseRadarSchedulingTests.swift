// AI CONTEXT — Tests/ReleaseRadarSchedulingTests.swift. Regression tests for
// Release Radar's learned-window scheduler and tight-budget selector. These
// protect the background-refresh behavior users feel most: one-episode daily
// shows should be checked roughly 30 minutes before their expected release time,
// daily windows should outrank random backlog work, and short BGAppRefresh wakes
// should spend protected slots on pre/active/missed release windows before
// ordinary random/deferred backlog work.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class ReleaseRadarSchedulingTests: XCTestCase {
    private struct Candidate: Equatable {
        var id: String
        var state: FeedRefreshWindowState
    }

    func testBackgroundBudgetProtectsReleaseRadarCandidatesFirst() {
        let candidates = [
            Candidate(id: "random-high-score", state: .randomSurveillance),
            Candidate(id: "daily-pre-window", state: .preWindow),
            Candidate(id: "random-backlog", state: .randomSurveillance),
            Candidate(id: "daily-active-window", state: .activeWindow),
            Candidate(id: "daily-missed-release", state: .missedRelease),
            Candidate(id: "fallback", state: .fallback)
        ]

        let selection = FeedRefreshBudgeting.select(
            candidates: candidates,
            policy: FeedRefreshBudgetPolicy(
                maxSelections: 3,
                protectedStates: [.preWindow, .activeWindow, .missedRelease],
                minimumProtectedSelections: 2
            ),
            state: { $0.state }
        )

        XCTAssertEqual(
            selection.selected.map(\.id),
            ["daily-pre-window", "daily-active-window", "random-high-score"]
        )
        XCTAssertEqual(
            selection.deferred.map(\.id),
            ["random-backlog", "daily-missed-release", "fallback"]
        )
    }

    func testDailyWeekdayPredictionStartsCheckingBeforeExpectedRelease() {
        let calendar = utcCalendar()
        let now = date(2026, 6, 23, 7, 35, calendar: calendar)
        let previousRelease = date(2026, 6, 22, 8, 0, calendar: calendar)
        let lastFetched = date(2026, 6, 23, 7, 0, calendar: calendar)
        let profile = FeedScheduleProfile(
            kind: .dailyWeekdays,
            confidence: 0.9,
            observationCount: 12,
            reliableDateCount: 12,
            activeWeekdays: [3],
            typicalMinuteOfDay: 8 * 60,
            cadenceSeconds: 24 * 60 * 60,
            reason: "test daily show"
        )
        let stats = RefreshStats(lastFetchedAt: lastFetched)

        let prediction = FeedRefreshScheduling.prediction(
            profile: profile,
            latestPublishedAt: previousRelease,
            publishDates: [],
            stats: stats,
            minRecheckInterval: 5 * 60,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(prediction.state, .preWindow)
        XCTAssertEqual(prediction.expectedWindowStart, date(2026, 6, 23, 7, 50, calendar: calendar))
        XCTAssertEqual(prediction.expectedWindowEnd, date(2026, 6, 23, 9, 15, calendar: calendar))
        XCTAssertLessThanOrEqual(prediction.nextDueAt, now)
    }

    func testDailyReleaseWindowOutscoresRandomBacklog() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let activeDaily = FeedRefreshPrediction(
            nextDueAt: now,
            state: .activeWindow,
            profileKind: .dailyWeekdays,
            expectedWindowStart: now.addingTimeInterval(-10 * 60),
            expectedWindowEnd: now.addingTimeInterval(60 * 60),
            recheckInterval: 5 * 60,
            reason: "daily window"
        )
        let random = FeedRefreshPrediction(
            nextDueAt: now.addingTimeInterval(-60 * 60),
            state: .randomSurveillance,
            profileKind: .random,
            recheckInterval: 30 * 60,
            reason: "random backlog"
        )

        let dailyPriority = FeedRefreshPrioritizer.priority(
            prediction: activeDaily,
            profile: FeedScheduleProfile(
                kind: .dailyWeekdays,
                confidence: 0.9,
                observationCount: 12,
                reliableDateCount: 12,
                activeWeekdays: [3],
                typicalMinuteOfDay: 8 * 60,
                reason: "daily"
            ),
            priorityRank: 10,
            lastFetchedAt: now.addingTimeInterval(-60 * 60),
            now: now
        )
        let randomPriority = FeedRefreshPrioritizer.priority(
            prediction: random,
            profile: FeedScheduleProfile(
                kind: .random,
                confidence: 0.9,
                observationCount: 12,
                reliableDateCount: 12,
                activeWeekdays: [3],
                typicalMinuteOfDay: 8 * 60,
                reason: "random"
            ),
            priorityRank: 1,
            lastFetchedAt: now.addingTimeInterval(-6 * 60 * 60),
            now: now
        )

        XCTAssertGreaterThan(dailyPriority.score, randomPriority.score)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}
