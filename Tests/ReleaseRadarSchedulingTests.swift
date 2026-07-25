// AI CONTEXT — Tests/ReleaseRadarSchedulingTests.swift. Regression tests for
// Release Radar's learned-window scheduler and tight-budget selector. These
// protect the background-refresh behavior users feel most: one-episode daily
// shows should be checked roughly 30 minutes before their expected release time,
// rolling news bulletins should get :00/:30 release windows instead of random
// surveillance, daily windows should outrank random backlog work, and short
// BGAppRefresh wakes should spend protected slots on pre/active/missed release
// windows before ordinary random/deferred backlog work. Also protects the
// background-audio hard ceiling: urgent windows may bypass the routine cap but
// never the resource-aware absolute maximum. Also protects the
// Download Filters contract: episodes skipped by per-subscription filters must
// not train Release Radar's learned profile. And the Release Radar v2 Stage-1
// Also protects the BGProcessing cadence policy: app-launch, useful, empty, and
// expired outcomes must produce bounded delays and expiry retries must back off.
// This pure policy test deliberately supplies jitter rather than invoking iOS's
// BGTaskScheduler, which is unavailable as a deterministic unit-test surface.
// It also verifies that active feed-failure backoff replaces an overdue feed date
// for BGAppRefresh scheduling, while expired backoff is ignored.
// And the Release Radar v2 Stage-1
// classifier: cadence + active-day pattern decides the kind (publish TIME never
// gates) — variable-time weekday feeds classify as dailyWeekdays/Weekdays, 7-day
// feeds as Daily, 2–4 days as multiSlot, irregular days stay Random, and weekends
// stay out of a Mon–Fri feed's active set. And the Stage-2 window/scheduling: the
// learned window hugs the densest publish-time mode but widens when the full observed
// spread is genuinely messy, broad safety sweeps catch out-of-window ordinary feeds,
// recency retunes it toward recent times, and a medium-probability weekday gets light-
// tier checks rather than full rotation or being skipped. See RELEASE_RADAR_V2.md.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class ReleaseRadarSchedulingTests: XCTestCase {
    private struct Candidate: Equatable {
        var id: String
        var state: FeedRefreshWindowState
    }

    func testExtractedCyclePlannerRetainsDeferredFairnessAndDeterministicOrder() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var first = Subscription(
            feedURL: URL(string: "https://example.com/first.xml")!,
            title: "First",
            priorityRank: 1
        )
        var deferred = Subscription(
            feedURL: URL(string: "https://example.com/deferred.xml")!,
            title: "Deferred",
            priorityRank: 2
        )
        first.refreshStats.lastFetchedAt = now.addingTimeInterval(-24 * 60 * 60)
        deferred.refreshStats.lastFetchedAt = now.addingTimeInterval(-24 * 60 * 60)
        let randomProfile = FeedScheduleProfile(
            kind: .random,
            confidence: 0.2,
            observationCount: 0,
            reliableDateCount: 0,
            activeWeekdays: [],
            reason: "characterization"
        )

        let result = ReleaseRadarCyclePlanner.candidates(
            subscriptions: [first, deferred],
            cachedProfiles: [
                first.id: randomProfile,
                deferred.id: randomProfile
            ],
            deferred: [
                deferred.id: RefreshPlanningDeferredSnapshot(
                    firstDeferredAt: now.addingTimeInterval(-2 * 60 * 60),
                    deferralCount: 2
                )
            ],
            minimumRecheckInterval: 5 * 60,
            now: now
        )

        XCTAssertEqual(result.map(\.subscription.id), [deferred.id, first.id])
        XCTAssertEqual(result.first?.deferredCount, 2)
        XCTAssertEqual(result.first?.deferredScoreBoost, 28)
        XCTAssertTrue(result.first?.priority.factors.contains("deferred 2x") == true)
    }

    func testHardSuccessfulCheckAgeOverridesFuturePrediction() {
        let now = Date(timeIntervalSince1970: 1_774_137_600)
        var subscription = Subscription(
            feedURL: URL(string: "https://example.com/freshness.xml")!,
            title: "Freshness",
            priorityRank: 1
        )
        subscription.refreshStats.lastFetchedAt =
            now.addingTimeInterval(-2 * 60 * 60)
        let tomorrowWeekday = Calendar.current.component(
            .weekday,
            from: now.addingTimeInterval(24 * 60 * 60)
        )
        let profile = FeedScheduleProfile(
            kind: .weekly,
            confidence: 0.9,
            observationCount: 8,
            reliableDateCount: 8,
            activeWeekdays: [tomorrowWeekday],
            typicalMinuteOfDay: 12 * 60,
            releaseWindow: FeedScheduleWindow(
                activeWeekdays: [tomorrowWeekday],
                startMinuteOfDay: 11 * 60,
                endMinuteOfDay: 13 * 60,
                typicalMinuteOfDay: 12 * 60,
                observedEpisodeCount: 8
            ),
            reason: "Weekly tomorrow"
        )

        let withoutCeiling = ReleaseRadarCyclePlanner.candidates(
            subscriptions: [subscription],
            cachedProfiles: [subscription.id: profile],
            deferred: [:],
            minimumRecheckInterval: 5 * 60,
            now: now
        )
        let withCeiling = ReleaseRadarCyclePlanner.candidates(
            subscriptions: [subscription],
            cachedProfiles: [subscription.id: profile],
            deferred: [:],
            minimumRecheckInterval: 5 * 60,
            maximumSuccessfulCheckAge: 90 * 60,
            now: now
        )

        XCTAssertTrue(withoutCeiling.isEmpty)
        XCTAssertEqual(withCeiling.count, 1)
        XCTAssertTrue(withCeiling[0].freshnessOverride)
        XCTAssertTrue(
            withCeiling[0].priority.factors.contains(
                "hard freshness ceiling"
            )
        )
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

    func testUrgentWindowBypassStopsAtHardMaximum() {
        let candidates = (0..<12).map {
            Candidate(id: "urgent-\($0)", state: .activeWindow)
        }

        let selection = FeedRefreshBudgeting.select(
            candidates: candidates,
            policy: FeedRefreshBudgetPolicy(
                maxSelections: 7,
                maxTotalSelections: 10,
                capBypassStates: [.preWindow, .activeWindow, .missedRelease]
            ),
            state: { $0.state }
        )

        XCTAssertEqual(selection.selected.count, 10)
        XCTAssertEqual(selection.deferred.count, 2)
    }

    func testDeferredFairnessReplacesUrgentBypassWithinHardMaximum() {
        let candidates = [
            Candidate(id: "urgent-1", state: .activeWindow),
            Candidate(id: "urgent-2", state: .activeWindow),
            Candidate(id: "urgent-3", state: .activeWindow),
            Candidate(id: "urgent-4", state: .activeWindow),
            Candidate(id: "urgent-5", state: .activeWindow),
            Candidate(id: "urgent-6", state: .activeWindow),
            Candidate(id: "oldest-deferred", state: .fallback),
            Candidate(id: "missed-release", state: .missedRelease)
        ]

        let selection = FeedRefreshBudgeting.select(
            candidates: candidates,
            policy: FeedRefreshBudgetPolicy(
                maxSelections: 4,
                maxTotalSelections: 6,
                capBypassStates: [.preWindow, .activeWindow, .missedRelease],
                fairnessCandidateIndices: [6],
                minimumFairnessSelections: 1
            ),
            state: { $0.state }
        )

        XCTAssertEqual(selection.selected.count, 6)
        XCTAssertTrue(
            selection.selected.map(\.id).contains("oldest-deferred")
        )
        XCTAssertEqual(
            selection.selected.filter { $0.state == .activeWindow }.count,
            4
        )
        XCTAssertTrue(selection.selected.map(\.id).contains("missed-release"))
        XCTAssertEqual(
            selection.deferred.map(\.id),
            ["urgent-5", "urgent-6"]
        )
    }

    func testBackgroundAudioFairnessThresholdsReserveWithinExistingBudget() {
        XCTAssertEqual(
            FeedRefreshBudgeting.fairnessReservationCount(
                isBackgroundAudio: true,
                deferredAges: [7 * 60 + 59]
            ),
            0
        )
        XCTAssertEqual(
            FeedRefreshBudgeting.fairnessReservationCount(
                isBackgroundAudio: true,
                deferredAges: [8 * 60]
            ),
            1
        )
        XCTAssertEqual(
            FeedRefreshBudgeting.fairnessReservationCount(
                isBackgroundAudio: true,
                deferredAges: [21 * 60]
            ),
            1,
            "A second slot cannot be reserved when only one feed is eligible"
        )
        XCTAssertEqual(
            FeedRefreshBudgeting.fairnessReservationCount(
                isBackgroundAudio: true,
                deferredAges: [20 * 60, 9 * 60, 2 * 60]
            ),
            2
        )
        XCTAssertEqual(
            FeedRefreshBudgeting.fairnessReservationCount(
                isBackgroundAudio: false,
                deferredAges: [60 * 60, 60 * 60]
            ),
            0,
            "Hard fairness reservation is intentionally audio-background only"
        )
    }

    #if !AUTOHOP_SPM
    func testBackgroundTaskExpirationCancelsOnlyItsOwnedHeadlessCycle() {
        XCTAssertEqual(
            FeedRefreshCycleWorkflow.backgroundExpirationDisposition(
                activeTaskIdentifier: "other-task",
                requestingTaskIdentifier: "expired-task",
                appForeground: false,
                audioPlaying: false
            ),
            .detachNotOwner
        )
        XCTAssertEqual(
            FeedRefreshCycleWorkflow.backgroundExpirationDisposition(
                activeTaskIdentifier: "expired-task",
                requestingTaskIdentifier: "expired-task",
                appForeground: true,
                audioPlaying: false
            ),
            .detachLiveForegroundOrAudio
        )
        XCTAssertEqual(
            FeedRefreshCycleWorkflow.backgroundExpirationDisposition(
                activeTaskIdentifier: "expired-task",
                requestingTaskIdentifier: "expired-task",
                appForeground: false,
                audioPlaying: true
            ),
            .detachLiveForegroundOrAudio
        )
        XCTAssertEqual(
            FeedRefreshCycleWorkflow.backgroundExpirationDisposition(
                activeTaskIdentifier: "expired-task",
                requestingTaskIdentifier: "expired-task",
                appForeground: false,
                audioPlaying: false
            ),
            .cancelOwnedCycle
        )
    }
    #endif

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

    func testRollingBulletinPredictionUsesHalfHourReleaseSlot() {
        let calendar = utcCalendar()
        let profile = FeedScheduleProfile(
            kind: .rollingBulletin,
            confidence: 0.84,
            observationCount: 12,
            reliableDateCount: 12,
            activeWeekdays: [3],
            typicalMinuteOfHour: 0,
            typicalMinutesOfHour: [0, 30],
            cadenceSeconds: 60 * 60,
            reason: "test rolling bulletin"
        )
        let now = date(2026, 6, 23, 10, 29, calendar: calendar)
        let prediction = FeedRefreshScheduling.prediction(
            profile: profile,
            latestPublishedAt: date(2026, 6, 23, 10, 0, calendar: calendar),
            publishDates: [],
            stats: RefreshStats(lastFetchedAt: date(2026, 6, 23, 10, 20, calendar: calendar)),
            minRecheckInterval: 5 * 60,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(prediction.state, .activeWindow)
        XCTAssertEqual(prediction.expectedWindowStart, date(2026, 6, 23, 10, 28, calendar: calendar))
        XCTAssertEqual(prediction.expectedWindowEnd, date(2026, 6, 23, 10, 45, calendar: calendar))
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

    /// Regression for the surveillance-boost suppression: a dormant no-pattern feed that is
    /// very stale, very "overdue", and highly user-ranked must NOT climb above a genuinely-
    /// fresh release-window feed — otherwise a short/uncapped BGProcessing window gets spent
    /// polling backlog ahead of real content. Without the suppression the random feed would
    /// score ~118 (rank + staleness + overdue) vs the fresh window's ~98; the assert would fail.
    func testStaleOverdueRandomSurveillanceStaysBelowFreshReleaseWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let freshActive = FeedRefreshPrediction(
            nextDueAt: now,
            state: .activeWindow,
            profileKind: .dailyWeekdays,
            expectedWindowStart: now.addingTimeInterval(-5 * 60),
            expectedWindowEnd: now.addingTimeInterval(55 * 60),
            recheckInterval: 60,
            reason: "fresh release window"
        )
        let staleRandom = FeedRefreshPrediction(
            nextDueAt: now.addingTimeInterval(-10 * 60 * 60),
            state: .randomSurveillance,
            profileKind: .random,
            recheckInterval: 30 * 60,
            reason: "dormant random backlog"
        )

        let activeScore = FeedRefreshPrioritizer.priority(
            prediction: freshActive,
            profile: FeedScheduleProfile(
                kind: .dailyWeekdays,
                confidence: 0.6,
                observationCount: 40,
                reliableDateCount: 40,
                activeWeekdays: [3],
                typicalMinuteOfDay: 8 * 60,
                reason: "fresh"
            ),
            priorityRank: 12,
            lastFetchedAt: now,
            now: now
        ).score

        let randomScore = FeedRefreshPrioritizer.priority(
            prediction: staleRandom,
            profile: FeedScheduleProfile(
                kind: .random,
                confidence: 0.9,
                observationCount: 40,
                reliableDateCount: 40,
                activeWeekdays: [3],
                typicalMinuteOfDay: 8 * 60,
                reason: "random"
            ),
            priorityRank: 1,
            lastFetchedAt: now.addingTimeInterval(-48 * 60 * 60),
            now: now
        ).score

        XCTAssertLessThan(randomScore, activeScore)
    }

    // MARK: - Weekly classification with variable publish times

    /// A produced weekly show whose publish time drifts must still classify as `.weekly`
    /// (it never depended on time). Stage 2: the window hugs the densest publish-time
    /// mode and excludes stragglers (those are caught by the missed-release soft tail),
    /// rather than spanning the full observed range.
    func testWeeklyWindowHugsDensestModeIgnoringStragglers() {
        let calendar = utcCalendar()
        let base = date(2024, 1, 4, 19, 0, calendar: calendar) // a Thursday
        // 15 episodes clustered ~19:00, 3 stragglers at 23:00 (interleaved so recency
        // doesn't favour the stragglers).
        let times: [(Int, Int)] = [
            (19, 0), (19, 5), (18, 55), (19, 0), (19, 5), (23, 0),
            (19, 0), (19, 5), (18, 55), (19, 0), (19, 5), (23, 0),
            (19, 0), (19, 5), (18, 55), (19, 0), (19, 5), (23, 0)
        ]
        let observations = weeklyObservations(count: 18, times: times, base: base, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .weekly)
        guard let window = profile.releaseWindow else {
            return XCTFail("Weekly profile should carry a learned release window")
        }
        // Window hugs the 19:00 mode …
        XCTAssertGreaterThanOrEqual(window.startMinuteOfDay, 18 * 60)
        XCTAssertLessThanOrEqual(window.endMinuteOfDay, 20 * 60)
        // … and the 23:00 stragglers fall outside it (the soft tail handles them).
        XCTAssertLessThan(window.endMinuteOfDay, 23 * 60)
    }

    /// Stage 2 recency: a feed that recently shifted its publish time retunes the window
    /// toward the recent cluster rather than the older one.
    func testWindowFollowsRecentPublishTime() {
        let calendar = utcCalendar()
        let base = date(2024, 1, 4, 0, 0, calendar: calendar) // a Thursday
        // First 10 weeks at 14:00, most recent 10 weeks at 09:00.
        let times: [(Int, Int)] = Array(repeating: (14, 0), count: 10) + Array(repeating: (9, 0), count: 10)
        let observations = weeklyObservations(count: 20, times: times, base: base, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .weekly)
        guard let window = profile.releaseWindow else {
            return XCTFail("Weekly profile should carry a learned release window")
        }
        // The learned centre follows the recent 09:00 cluster, not the older 14:00 one.
        XCTAssertLessThan(window.typicalMinuteOfDay, 12 * 60)
        XCTAssertGreaterThanOrEqual(window.typicalMinuteOfDay, 8 * 60)
    }

    /// Stage 2 three-tier intensity: a Mon–Fri feed that occasionally publishes on
    /// Saturday keeps Saturday OUT of its active set (weekends aren't full-watched), but
    /// Saturday is still watched at a lighter cadence than a weekday rather than skipped.
    func testMediumProbabilityDayGetsLightTierChecks() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        var observations = observationsOnWeekdays(weeks: 10, weekdays: [2, 3, 4, 5, 6], times: [(10, 0)], startSunday: sunday, calendar: calendar)
        // Saturday in 5 mid-run weeks → a medium (recency-weighted) probability.
        observations += observationsOnWeekdays(weeks: 5, weekdays: [7], times: [(10, 0)], startSunday: calendar.date(byAdding: .weekOfYear, value: 3, to: sunday)!, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)
        XCTAssertEqual(Set(profile.activeWeekdays), [2, 3, 4, 5, 6], "Saturday is medium-probability, not active")
        let saturdayProbability = profile.weekdayProbabilities?[7] ?? 0
        XCTAssertGreaterThanOrEqual(saturdayProbability, 0.25)
        XCTAssertLessThan(saturdayProbability, 0.6)

        func prediction(at now: Date) -> FeedRefreshPrediction {
            FeedRefreshScheduling.prediction(
                profile: profile,
                latestPublishedAt: nil,
                publishDates: [],
                stats: RefreshStats(lastFetchedAt: now.addingTimeInterval(-3600)),
                minRecheckInterval: 5 * 60,
                now: now,
                calendar: calendar
            )
        }
        let saturday = prediction(at: date(2024, 1, 13, 10, 0, calendar: calendar)) // a Saturday, in-window
        let monday = prediction(at: date(2024, 1, 15, 10, 0, calendar: calendar))   // a Monday, in-window

        XCTAssertEqual(saturday.state, .activeWindow, "Light-tier Saturday is still watched, not skipped")
        XCTAssertEqual(monday.state, .activeWindow)
        XCTAssertGreaterThan(saturday.recheckInterval ?? 0, monday.recheckInterval ?? 0, "Light tier checks less often than full tier")
    }

    /// A razor-tight weekly feed (always ~09:00) should still be weekly, with the window
    /// held to the 1-hour floor rather than collapsing to a single minute.
    func testTightWeeklyFeedGetsNarrowFloorWindow() {
        let calendar = utcCalendar()
        let base = date(2024, 1, 4, 9, 0, calendar: calendar)
        let observations = weeklyObservations(count: 16, times: [(9, 0)], base: base, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .weekly)
        guard let window = profile.releaseWindow else {
            return XCTFail("Weekly profile should carry a learned release window")
        }
        XCTAssertEqual(window.endMinuteOfDay - window.startMinuteOfDay, 60, "Tight feed should sit at the 1-hour floor")
        XCTAssertEqual(window.typicalMinuteOfDay, 9 * 60)
    }

    /// A normal weekday feed with releases spread across much of the day should still
    /// classify as Weekdays, but its primary window should not stay razor-thin around
    /// one mode. The wider floor plus lower confidence prevents the Radar from acting
    /// overconfident about a messy publisher.
    func testWideSpreadWeekdayFeedGetsBroaderWindowAndLowerConfidence() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        let times: [(Int, Int)] = [(8, 0), (10, 0), (13, 0), (17, 0), (21, 0)]
        let observations = observationsOnWeekdays(
            weeks: 8,
            weekdays: [2, 3, 4, 5, 6],
            times: times,
            startSunday: sunday,
            calendar: calendar
        )

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .dailyWeekdays)
        guard let window = profile.releaseWindow else {
            return XCTFail("Weekday profile should carry a learned release window")
        }
        XCTAssertGreaterThanOrEqual(window.observedSpreadMinutes ?? 0, 8 * 60)
        XCTAssertGreaterThanOrEqual(window.endMinuteOfDay - window.startMinuteOfDay, 4 * 60)
        XCTAssertLessThan(profile.confidence, 0.9)
    }

    /// After the learned window has already produced an episode, a daily/weekly/multi
    /// feed should not disappear until the next normal window. A broad safety sweep gives
    /// messy real-world feeds a low-priority second chance without making hourly news
    /// windows wider.
    func testLearnedFeedGetsSafetySweepOutsideWindow() {
        let calendar = utcCalendar()
        let now = date(2026, 6, 23, 21, 0, calendar: calendar) // Tuesday
        let latestPublishedAt = date(2026, 6, 23, 8, 15, calendar: calendar)
        let lastFetched = date(2026, 6, 23, 8, 30, calendar: calendar)
        let profile = FeedScheduleProfile(
            kind: .dailyWeekdays,
            confidence: 0.78,
            observationCount: 30,
            reliableDateCount: 30,
            activeWeekdays: [3],
            typicalMinuteOfDay: 8 * 60 + 30,
            cadenceSeconds: 24 * 60 * 60,
            releaseWindow: FeedScheduleWindow(
                activeWeekdays: [3],
                startMinuteOfDay: 8 * 60,
                endMinuteOfDay: 9 * 60,
                typicalMinuteOfDay: 8 * 60 + 30,
                observedEpisodeCount: 30,
                observedSpreadMinutes: 60
            ),
            reason: "test daily show"
        )
        let stats = RefreshStats(lastFetchedAt: lastFetched)

        let prediction = FeedRefreshScheduling.prediction(
            profile: profile,
            latestPublishedAt: latestPublishedAt,
            publishDates: [],
            stats: stats,
            minRecheckInterval: 5 * 60,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(prediction.state, .fallback)
        XCTAssertLessThanOrEqual(prediction.nextDueAt, now)
        XCTAssertEqual(prediction.recheckInterval, TimeInterval(12 * 60 * 60))
        XCTAssertTrue(prediction.reason.localizedCaseInsensitiveContains("safety"))
    }

    // MARK: - Release Radar v2 — Stage 1 (cadence + active-day, no time gate)

    /// A weekday show (Mon–Fri) whose publish time varies widely must classify as
    /// dailyWeekdays — publish time no longer gates classification — with the weekend
    /// left out of the active set so no weekend slots are spent.
    func testVariableTimeWeekdayFeedClassifiesAsWeekdays() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        let times: [(Int, Int)] = [(14, 0), (15, 30), (16, 45), (18, 0), (20, 0)]
        let observations = observationsOnWeekdays(weeks: 8, weekdays: [2, 3, 4, 5, 6], times: times, startSunday: sunday, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .dailyWeekdays)
        XCTAssertEqual(Set(profile.activeWeekdays), [2, 3, 4, 5, 6])
        XCTAssertEqual(profile.categoryLabel, "Weekdays")
        XCTAssertTrue(Set(profile.activeWeekdays).isDisjoint(with: [1, 7]), "Weekend must not be watched")
    }

    /// A 7-day feed classifies as daily-cadence with the weekend in its active set and
    /// reads as "Daily".
    func testSevenDayFeedClassifiesAsDailyIncludingWeekend() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        let observations = observationsOnWeekdays(weeks: 6, weekdays: [1, 2, 3, 4, 5, 6, 7], times: [(6, 0), (7, 30), (9, 0)], startSunday: sunday, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .dailyWeekdays)
        XCTAssertEqual(Set(profile.activeWeekdays), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(profile.categoryLabel, "Daily")
    }

    /// A twice-weekly show (Mon + Thu) classifies as several-times-a-week.
    func testTwiceWeeklyFeedClassifiesAsMultiSlot() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        let observations = observationsOnWeekdays(weeks: 10, weekdays: [2, 5], times: [(14, 5)], startSunday: sunday, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .multiSlot)
        XCTAssertEqual(Set(profile.activeWeekdays), [2, 5])
        XCTAssertEqual(profile.categoryLabel, "Several times a week")
    }

    /// DST: a feed stamped at a fixed UTC instant (02:00 UTC every Thursday) spans the
    /// April DST change — 02:00 UTC reads 1pm AEDT (summer) but 12pm AEST (winter). The
    /// window must NOT drift to the winter time; with "now" in summer it reads 1pm.
    func testFixedUtcFeedWindowDoesNotDriftAcrossDST() {
        var melbourne = Calendar(identifier: .gregorian)
        melbourne.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let utc = utcCalendar()
        let firstThursday = date(2024, 1, 4, 2, 0, calendar: utc) // Thu 4 Jan 2024, 02:00 UTC
        let observations = (0..<30).map { week -> FeedReleaseObservation in
            let published = utc.date(byAdding: .day, value: 7 * week, to: firstThursday)!
            return FeedReleaseObservation(
                episodeKey: "u-\(week)", guid: "ug-\(week)", title: "Ep \(week)",
                audioURL: nil, publishedAt: published, firstSeenAt: published, lastSeenAt: published,
                dateQuality: .plausible, wasNewWhenFirstSeen: true)
        }
        let nowSummer = date(2024, 12, 1, 0, 0, calendar: utc) // AEDT

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: melbourne, now: nowSummer)

        XCTAssertEqual(profile.kind, .weekly)
        XCTAssertEqual(profile.releaseWindow?.typicalMinuteOfDay, 13 * 60, "02:00 UTC must read 1pm AEDT, not the winter 12pm")
    }

    /// DST: a feed stamped at a fixed LOCAL time (1pm Melbourne every Thursday) across the
    /// same boundary keeps its wall-clock time — the window must stay at 1pm (not anchor
    /// to UTC and drift).
    func testFixedLocalFeedWindowStaysAtLocalTimeAcrossDST() {
        var melbourne = Calendar(identifier: .gregorian)
        melbourne.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let baseThursday = date(2024, 1, 4, 0, 0, calendar: melbourne)
        let observations = (0..<30).map { week -> FeedReleaseObservation in
            let day = melbourne.date(byAdding: .day, value: 7 * week, to: baseThursday)!
            let published = melbourne.date(bySettingHour: 13, minute: 0, second: 0, of: day)!
            return FeedReleaseObservation(
                episodeKey: "l-\(week)", guid: "lg-\(week)", title: "Ep \(week)",
                audioURL: nil, publishedAt: published, firstSeenAt: published, lastSeenAt: published,
                dateQuality: .plausible, wasNewWhenFirstSeen: true)
        }
        let nowSummer = date(2024, 12, 1, 0, 0, calendar: melbourne)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: melbourne, now: nowSummer)

        XCTAssertEqual(profile.kind, .weekly)
        XCTAssertEqual(profile.releaseWindow?.typicalMinuteOfDay, 13 * 60, "Fixed local 1pm must stay 1pm across DST")
    }

    /// (a) Episode-share weekly: one weekday holds ~all the episodes on a ~weekly cadence,
    /// but a hiatus drops its per-week probability below the active bar. It must still
    /// classify as weekly (via episode share), not Random.
    func testEpisodeShareWeeklyClassifiesDespiteSkippedWeeks() {
        let calendar = utcCalendar()
        let base = date(2024, 1, 4, 9, 0, calendar: calendar) // a Thursday
        let weekday = calendar.component(.weekday, from: base)
        // Weekly Thursdays in two clusters with a long hiatus between, so the per-week
        // probability sits below the active bar while Thursday still holds every episode.
        let weekOffsets = Array(0..<5) + Array(15..<20)
        let observations = weekOffsets.map { offset -> FeedReleaseObservation in
            let published = calendar.date(byAdding: .day, value: 7 * offset, to: base)!
            return FeedReleaseObservation(
                episodeKey: "wk-\(offset)", guid: "wk-guid-\(offset)", title: "Episode \(offset)",
                audioURL: nil, publishedAt: published, firstSeenAt: published, lastSeenAt: published,
                dateQuality: .plausible, wasNewWhenFirstSeen: true)
        }

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .weekly)
        XCTAssertEqual(profile.activeWeekdays, [weekday])
        XCTAssertLessThan(profile.weekdayProbabilities?[weekday] ?? 1, 0.6, "Classified by episode share, not per-week probability")
    }

    /// (b) Recency weighting self-corrects a stale/biased capture: an old Sunday-only
    /// history followed by the feed's true recent Mon–Fri pattern must classify as
    /// Weekdays, not weekly-Sunday.
    func testRecencyWeightingSelfCorrectsStaleCapture() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        var observations = observationsOnWeekdays(weeks: 20, weekdays: [1], times: [(20, 0)], startSunday: sunday, calendar: calendar)
        observations += observationsOnWeekdays(weeks: 16, weekdays: [2, 3, 4, 5, 6], times: [(8, 0)], startSunday: calendar.date(byAdding: .weekOfYear, value: 20, to: sunday)!, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .dailyWeekdays, "Recent Mon–Fri must override stale Sunday-only history")
        XCTAssertEqual(Set(profile.activeWeekdays), [2, 3, 4, 5, 6])
        XCTAssertFalse(Set(profile.activeWeekdays).contains(1), "Stale Sunday is no longer active")
    }

    /// The Daily scenario: a long Sunday-only back-catalogue (the RSS only retains
    /// Sunday episodes long-term) plus only ~2 weeks of genuine 7-day capture. The
    /// recent daily history is too short for any weekday's per-week probability to clear
    /// the active bar, so the recency-windowed PRESENCE rescue must classify it Daily
    /// rather than Weekly-on-Sunday.
    func testStaleSundaySeedWithShortDailyCaptureClassifiesDaily() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 20, 0, calendar: calendar)
        // 30 weeks of Sunday-only seed (what survives in the feed long-term).
        var observations = observationsOnWeekdays(weeks: 30, weekdays: [1], times: [(20, 0)], startSunday: sunday, calendar: calendar)
        // Then just 2 weeks where all 7 days are actually captured.
        let recentStart = calendar.date(byAdding: .weekOfYear, value: 30, to: sunday)!
        observations += observationsOnWeekdays(weeks: 2, weekdays: [1, 2, 3, 4, 5, 6, 7], times: [(20, 0)], startSunday: recentStart, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .dailyWeekdays, "Recent 7-day capture must override the stale Sunday-only seed")
        XCTAssertEqual(profile.categoryLabel, "Daily", "7 active days incl. weekend → Daily, not Weekdays")
        XCTAssertTrue(Set(profile.activeWeekdays).isSuperset(of: [1, 7]), "A 7-day feed opens weekend slots too")
    }

    /// Multiple episodes per day on MOST days → "Daily – Multiple Episodes" (burst kind).
    func testMultipleEpisodesPerDayMostDaysIsDailyMultiple() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        let observations = burstObservations(weeks: 4, weekdays: [2, 3, 4, 5, 6], perDay: 3, startSunday: sunday, calendar: calendar)

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .burst)
        XCTAssertEqual(profile.categoryLabel, "Daily – Multiple Episodes")
    }

    /// Multiple episodes per day but on only ONE weekday → a weekly show split into
    /// segments, so it must classify as Weekly (not Daily – Multiple).
    func testMultipleEpisodesOnOneWeekdayIsWeekly() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        let observations = burstObservations(weeks: 6, weekdays: [3], perDay: 3, startSunday: sunday, calendar: calendar) // Tuesdays only

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .weekly)
    }

    /// The burst window must cover the full daily spread, including days that run LATER
    /// than the median — the old median-first/median-last range left late episodes
    /// outside the window.
    func testBurstWindowCoversLateRunningDays() {
        let calendar = utcCalendar()
        let sunday = date(2024, 1, 7, 0, 0, calendar: calendar)
        var observations: [FeedReleaseObservation] = []
        var index = 0
        for week in 0..<8 {
            for weekday in [2, 3, 4, 5, 6] {
                let dayOffset = 7 * week + (weekday - 1)
                let day = calendar.date(byAdding: .day, value: dayOffset, to: sunday)!
                // Every day starts 9:00; Thu/Fri run late to 11:00, the rest end 9:30.
                let secondTime = (weekday == 5 || weekday == 6) ? (11, 0) : (9, 30)
                for time in [(9, 0), secondTime] {
                    let published = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)!
                    observations.append(FeedReleaseObservation(
                        episodeKey: "e-\(index)", guid: "g-\(index)", title: "E\(index)",
                        audioURL: nil, publishedAt: published, firstSeenAt: published, lastSeenAt: published,
                        dateQuality: .plausible, wasNewWhenFirstSeen: true))
                    index += 1
                }
            }
        }

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .burst)
        guard let window = profile.burstWindow else { return XCTFail("expected a burst window") }
        XCTAssertGreaterThanOrEqual(window.endMinuteOfDay, 11 * 60, "Window must reach the late (11:00) episodes")
        XCTAssertLessThanOrEqual(window.startMinuteOfDay, 9 * 60, "Window should start by the 9:00 first episode")
    }

    /// No consistent active day → stays Random (the genuine no-pattern case).
    func testIrregularDaysStayRandom() {
        let calendar = utcCalendar()
        let base = date(2024, 1, 7, 12, 0, calendar: calendar)
        let dayOffsets = [0, 5, 9, 16, 18, 27, 33, 41, 50, 58, 70, 79]
        let observations = dayOffsets.enumerated().map { index, offset -> FeedReleaseObservation in
            let published = calendar.date(byAdding: .day, value: offset, to: base)!
            return FeedReleaseObservation(
                episodeKey: "irr-\(index)", guid: "irr-guid-\(index)", title: "Episode \(index)",
                audioURL: nil, publishedAt: published, firstSeenAt: published, lastSeenAt: published,
                dateQuality: .plausible, wasNewWhenFirstSeen: true)
        }

        let profile = FeedScheduleProfiler.profile(from: observations, calendar: calendar)

        XCTAssertEqual(profile.kind, .random)
    }

    /// The scheduler must honour the learned weekly window (not the old ±120 band):
    /// inside the window it reports `.activeWindow` bounded by exactly that window.
    func testWeeklyPredictionHonoursLearnedWindow() {
        let calendar = utcCalendar()
        let now = date(2026, 6, 25, 19, 0, calendar: calendar)
        let weekday = calendar.component(.weekday, from: now)
        let profile = FeedScheduleProfile(
            kind: .weekly,
            confidence: 0.8,
            observationCount: 16,
            reliableDateCount: 16,
            activeWeekdays: [weekday],
            typicalMinuteOfDay: 19 * 60 + 30,
            cadenceSeconds: 7 * 24 * 60 * 60,
            releaseWindow: FeedScheduleWindow(
                activeWeekdays: [weekday],
                startMinuteOfDay: 18 * 60,
                endMinuteOfDay: 21 * 60,
                typicalMinuteOfDay: 19 * 60 + 30,
                observedEpisodeCount: 16
            ),
            reason: "test weekly window"
        )

        let prediction = FeedRefreshScheduling.prediction(
            profile: profile,
            latestPublishedAt: date(2026, 6, 18, 19, 0, calendar: calendar),
            publishDates: [],
            stats: RefreshStats(lastFetchedAt: date(2026, 6, 25, 18, 30, calendar: calendar)),
            minRecheckInterval: 5 * 60,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(prediction.state, .activeWindow)
        XCTAssertEqual(prediction.expectedWindowStart, date(2026, 6, 25, 18, 0, calendar: calendar))
        XCTAssertEqual(prediction.expectedWindowEnd, date(2026, 6, 25, 21, 0, calendar: calendar))
    }

    /// The per-subscription diagnostic's gate checks must mirror the real classifier:
    /// a weekly feed passes every weekly gate, fails at least one daily gate, and the
    /// surfaced dominant weekday matches the data.
    func testDiagnosticsMirrorsWeeklyClassification() {
        let calendar = utcCalendar()
        let base = date(2024, 1, 4, 18, 0, calendar: calendar) // a Thursday
        let times: [(Int, Int)] = [(18, 0), (18, 30), (19, 0), (19, 30), (20, 0), (20, 30), (21, 0)]
        let observations = weeklyObservations(count: 18, times: times, base: base, calendar: calendar)

        let diag = FeedScheduleProfiler.diagnostics(from: observations, calendar: calendar)

        XCTAssertEqual(diag.profile.kind, .weekly)
        XCTAssertTrue(diag.weeklyChecks.allSatisfy(\.passed), "Every weekly gate should pass for a weekly feed")
        XCTAssertFalse(diag.dailyChecks.allSatisfy(\.passed), "A single-weekday feed should fail a daily gate")
        XCTAssertEqual(diag.dominantWeekday, calendar.component(.weekday, from: base))
        XCTAssertEqual(diag.reliableDateCount, 18)
    }

    func testDownloadFiltersExcludeTitleMatchedObservationsFromReleaseRadarProfile() {
        let calendar = utcCalendar()
        let weeklyBase = date(2024, 1, 4, 8, 0, calendar: calendar)
        let weekly = weeklyObservations(count: 8, times: [(8, 0)], base: weeklyBase, calendar: calendar)
        let trailers = dailyObservations(
            count: 12,
            titlePrefix: "Trailer",
            durationSeconds: 12 * 60,
            base: date(2024, 1, 1, 12, 0, calendar: calendar),
            calendar: calendar
        )
        let stats = RefreshStats(releaseObservations: weekly + trailers)
        var filters = DownloadFilterSettings.default
        filters.titleEnabled = true
        filters.titleRules = [
            .init(behavior: .exclude, operation: .contains, term: "trailer")
        ]

        let profile = stats.scheduleProfile(downloadFilterSettings: filters, calendar: calendar)
        let included = stats.releaseObservations(includedBy: filters)

        XCTAssertEqual(included.count, weekly.count)
        XCTAssertTrue(included.allSatisfy { !$0.title.localizedCaseInsensitiveContains("trailer") })
        XCTAssertEqual(profile.observationCount, weekly.count)
        XCTAssertEqual(profile.kind, .weekly)
    }

    func testDownloadFiltersExcludeShortDurationObservationsFromReleaseRadarProfile() {
        let calendar = utcCalendar()
        var weekly = weeklyObservations(
            count: 8,
            times: [(9, 0)],
            base: date(2024, 1, 4, 9, 0, calendar: calendar),
            calendar: calendar
        )
        weekly = weekly.map { observation in
            var copy = observation
            copy.durationSeconds = 60 * 60
            return copy
        }
        let shortDailies = dailyObservations(
            count: 12,
            titlePrefix: "Briefing",
            durationSeconds: 10 * 60,
            base: date(2024, 1, 1, 7, 0, calendar: calendar),
            calendar: calendar
        )
        let stats = RefreshStats(releaseObservations: weekly + shortDailies)
        var filters = DownloadFilterSettings.default
        filters.durationEnabled = true
        filters.durationRules = [
            .init(behavior: .include, comparison: .longerThan, minutes: 40)
        ]

        let profile = stats.scheduleProfile(downloadFilterSettings: filters, calendar: calendar)
        let included = stats.releaseObservations(includedBy: filters)

        XCTAssertEqual(included.count, weekly.count)
        XCTAssertTrue(included.allSatisfy { ($0.durationSeconds ?? 0) > 40 * 60 })
        XCTAssertEqual(profile.observationCount, weekly.count)
        XCTAssertEqual(profile.kind, .weekly)
    }

    /// Builds `count` weekly observations 7 days apart on a fixed weekday, cycling the
    /// supplied publish times so the time-of-day spread can be controlled per test.
    private func weeklyObservations(
        count: Int,
        times: [(Int, Int)],
        base: Date,
        calendar: Calendar
    ) -> [FeedReleaseObservation] {
        (0..<count).map { index in
            let time = times[index % times.count]
            let day = calendar.date(byAdding: .day, value: 7 * index, to: base)!
            let published = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)!
            return FeedReleaseObservation(
                episodeKey: "ep-\(index)",
                guid: "guid-\(index)",
                title: "Episode \(index)",
                audioURL: nil,
                publishedAt: published,
                firstSeenAt: published,
                lastSeenAt: published,
                dateQuality: .plausible,
                wasNewWhenFirstSeen: true
            )
        }
    }

    private func dailyObservations(
        count: Int,
        titlePrefix: String,
        durationSeconds: TimeInterval,
        base: Date,
        calendar: Calendar
    ) -> [FeedReleaseObservation] {
        (0..<count).map { index in
            let published = calendar.date(byAdding: .day, value: index, to: base)!
            return FeedReleaseObservation(
                episodeKey: "\(titlePrefix)-\(index)",
                guid: "\(titlePrefix)-guid-\(index)",
                title: "\(titlePrefix) \(index)",
                durationSeconds: durationSeconds,
                audioURL: nil,
                publishedAt: published,
                firstSeenAt: published,
                lastSeenAt: published,
                dateQuality: .plausible,
                wasNewWhenFirstSeen: true
            )
        }
    }

    /// Builds `weeks` weeks of observations on the given Calendar weekdays (1 = Sun …
    /// 7 = Sat), cycling `times`. `startSunday` must be a Sunday so weekday offsets line
    /// up. Used to construct daily / weekday / multi-day patterns for Stage-1 tests.
    private func observationsOnWeekdays(
        weeks: Int,
        weekdays: [Int],
        times: [(Int, Int)],
        startSunday: Date,
        calendar: Calendar
    ) -> [FeedReleaseObservation] {
        var result: [FeedReleaseObservation] = []
        var index = 0
        for week in 0..<weeks {
            for weekday in weekdays.sorted() {
                let dayOffset = 7 * week + (weekday - 1)
                let day = calendar.date(byAdding: .day, value: dayOffset, to: startSunday)!
                let time = times[index % times.count]
                let published = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)!
                result.append(FeedReleaseObservation(
                    episodeKey: "wd-\(index)",
                    guid: "wd-guid-\(index)",
                    title: "Episode \(index)",
                    audioURL: nil,
                    publishedAt: published,
                    firstSeenAt: published,
                    lastSeenAt: published,
                    dateQuality: .plausible,
                    wasNewWhenFirstSeen: true
                ))
                index += 1
            }
        }
        return result
    }

    /// Builds `weeks` weeks of observations with `perDay` episodes at the same time (a
    /// tight daily burst) on each of `weekdays`. For "Daily – Multiple Episodes" tests.
    private func burstObservations(
        weeks: Int,
        weekdays: [Int],
        perDay: Int,
        startSunday: Date,
        calendar: Calendar
    ) -> [FeedReleaseObservation] {
        var result: [FeedReleaseObservation] = []
        var index = 0
        for week in 0..<weeks {
            for weekday in weekdays.sorted() {
                let dayOffset = 7 * week + (weekday - 1)
                let day = calendar.date(byAdding: .day, value: dayOffset, to: startSunday)!
                let published = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
                for _ in 0..<perDay {
                    result.append(FeedReleaseObservation(
                        episodeKey: "b-\(index)",
                        guid: "b-guid-\(index)",
                        title: "Episode \(index)",
                        audioURL: nil,
                        publishedAt: published,
                        firstSeenAt: published,
                        lastSeenAt: published,
                        dateQuality: .plausible,
                        wasNewWhenFirstSeen: true
                    ))
                    index += 1
                }
            }
        }
        return result
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

#if !AUTOHOP_SPM
final class BackgroundProcessingScheduleTests: XCTestCase {
    private let hour: TimeInterval = 60 * 60

    func testNormalOutcomesUseLongCadence() {
        XCTAssertEqual(BackgroundTaskCoordinator.processingDelay(after: .initial, consecutiveFailures: 0, jitterUnit: 0), 12 * hour)
        XCTAssertEqual(BackgroundTaskCoordinator.processingDelay(after: .completed(didRun: true), consecutiveFailures: 0, jitterUnit: 0), 18 * hour)
        XCTAssertEqual(BackgroundTaskCoordinator.processingDelay(after: .completed(didRun: false), consecutiveFailures: 0, jitterUnit: 0), 8 * hour)
        XCTAssertEqual(BackgroundTaskCoordinator.processingDelay(after: .completed(didRun: false), consecutiveFailures: 0, jitterUnit: 1), 10 * hour)
    }

    func testExpirationRetriesBackOffAndCapAtOneDay() {
        let expectedHours: [TimeInterval] = [2, 4, 8, 16, 24, 24]
        for (offset, expected) in expectedHours.enumerated() {
            XCTAssertEqual(
                BackgroundTaskCoordinator.processingDelay(after: .expired, consecutiveFailures: offset + 1, jitterUnit: 0),
                expected * hour
            )
        }
    }

    func testJitterIsClampedAndOnlyDelaysTheRequest() {
        let base = BackgroundTaskCoordinator.processingDelay(after: .completed(didRun: true), consecutiveFailures: 0, jitterUnit: -1)
        let maximum = BackgroundTaskCoordinator.processingDelay(after: .completed(didRun: true), consecutiveFailures: 0, jitterUnit: 2)
        XCTAssertEqual(base, 18 * hour)
        XCTAssertEqual(maximum, 19 * hour)
    }

    func testActiveFeedBackoffDelaysEffectiveBackgroundDueDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let overdue = now.addingTimeInterval(-10 * 24 * hour)
        let backoff = now.addingTimeInterval(2 * hour)
        XCTAssertEqual(BackgroundTaskCoordinator.effectiveFeedDueDate(feedDueDate: overdue, backoffUntil: backoff, now: now), backoff)
    }

    func testExpiredBackoffDoesNotDelayFeed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let due = now.addingTimeInterval(hour)
        let expired = now.addingTimeInterval(-hour)
        XCTAssertEqual(BackgroundTaskCoordinator.effectiveFeedDueDate(feedDueDate: due, backoffUntil: expired, now: now), due)
    }

    func testPendingAppRefreshIsNotReplacedByLaterCandidate() {
        let pending = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(
            BackgroundTaskCoordinator.shouldReplacePendingAppRefresh(
                pendingDate: pending,
                candidateDate: pending.addingTimeInterval(4 * 60)
            )
        )
    }

    func testPendingAppRefreshRequiresMateriallyEarlierCandidate() {
        let pending = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(
            BackgroundTaskCoordinator.shouldReplacePendingAppRefresh(
                pendingDate: pending,
                candidateDate: pending.addingTimeInterval(-30)
            )
        )
        XCTAssertTrue(
            BackgroundTaskCoordinator.shouldReplacePendingAppRefresh(
                pendingDate: pending,
                candidateDate: pending.addingTimeInterval(-60)
            )
        )
    }
}
#endif
