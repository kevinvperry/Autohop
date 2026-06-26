// AI CONTEXT — Tests/ReleaseRadarSchedulingTests.swift. Regression tests for
// Release Radar's learned-window scheduler and tight-budget selector. These
// protect the background-refresh behavior users feel most: one-episode daily
// shows should be checked roughly 30 minutes before their expected release time,
// rolling news bulletins should get :00/:30 release windows instead of random
// surveillance, daily windows should outrank random backlog work, and short
// BGAppRefresh wakes should spend protected slots on pre/active/missed release
// windows before ordinary random/deferred backlog work. Also protects the
// Download Filters contract: episodes skipped by per-subscription filters must
// not train Release Radar's learned profile. And the Release Radar v2 Stage-1
// classifier: cadence + active-day pattern decides the kind (publish TIME never
// gates) — variable-time weekday feeds classify as dailyWeekdays/Weekdays, 7-day
// feeds as Daily, 2–4 days as multiSlot, irregular days stay Random, and weekends
// stay out of a Mon–Fri feed's active set. And the Stage-2 window/scheduling: the
// learned window hugs the densest publish-time mode (stragglers go to the soft tail),
// recency retunes it toward recent times, and a medium-probability weekday gets light-
// tier checks rather than full rotation or being skipped. See RELEASE_RADAR_V2.md.
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
