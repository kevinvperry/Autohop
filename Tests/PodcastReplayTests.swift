// AI CONTEXT — Podcast Replay's deterministic policy and sync regressions.
// Exercises due-slot debt, capacity, filters, fresh-feed catch-up, historical
// replay, portable queues and concurrent journal merges without real services.
// Calendar cases cover multiple daily times, chosen weekdays, DST gaps/repeats,
// shared limits, wire round trips and schedule-edit versus progress conflicts.
// Binge cases cover one-ahead capacity, durable start dedupe, sync, filtering,
// stale history and unchanged priority/pin semantics.
import XCTest
import Combine
#if AUTOHOP_SPM
@testable import AutohopCore
private typealias Subscription = AutohopCore.Subscription
#else
@testable import Autohop
private typealias Subscription = Autohop.Subscription
#endif

final class PodcastReplayTests: XCTestCase {
    let day: TimeInterval = 86_400
    let monday = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture(count: Int = 6, limit: AutoArchiveSettings.EpisodeLimit = .one) -> (Subscription, PodcastReplay) {
        var sub = Subscription(feedURL: URL(string: "https://example.com/feed")!, title: "Replay", priorityRank: 1)
        sub.episodes = (0..<count).map { index in
            var ep = Episode(subscriptionID: sub.id, guid: "g\(index)", title: "Episode \(index)", audioURL: URL(string: "https://example.com/\(index).mp3")!)
            ep.publishedAt = monday.addingTimeInterval(Double(index) * day - 100 * day)
            ep.durationSeconds = index == 0 ? 1200 : 3600
            return ep
        }
        sub.autoArchiveSettings.episodeLimit = limit
        let replay = PodcastReplay(start: sub.episodes[0], firstRelease: monday, everyDays: 1, ownerID: "phone", timeZoneID: "UTC", now: monday)
        return (sub, replay)
    }
    func testNoReleaseBeforeDueAndReservationIsIdempotent() {
        let (sub, original) = fixture(); var replay = original
        replay.reserve(in: sub, now: monday.addingTimeInterval(-1)); XCTAssertTrue(replay.releases.isEmpty)
        replay.reserve(in: sub, now: monday); let once = replay
        replay.reserve(in: sub, now: monday); XCTAssertEqual(replay, once)
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 0"])
    }
    func testLimitOneRetainsOverdueSlotUntilResolved() {
        let (sub, original) = fixture(); var replay = original
        replay.reserve(in: sub, now: monday.addingTimeInterval(2 * day))
        XCTAssertEqual(replay.releases.count, 1)
        replay.releases[0].resolved = true
        replay.reserve(in: sub, now: monday.addingTimeInterval(2 * day))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 1"])
        XCTAssertEqual(replay.releases[1].due, original.nextDate(after: monday))
    }
    func testLargerLimitFillsOnlyDueSlotsAndLoweringLimitNeverEvicts() {
        var (sub, replay) = fixture(limit: .three)
        replay.reserve(in: sub, now: monday.addingTimeInterval(5 * day))
        XCTAssertEqual(replay.outstanding.count, 3)
        sub.autoArchiveSettings.episodeLimit = .one
        replay.reserve(in: sub, now: monday.addingTimeInterval(6 * day))
        XCTAssertEqual(replay.outstanding.count, 3)
    }
    func testFiltersDoNotConsumeSlot() {
        var (sub, replay) = fixture()
        sub.downloadFilterSettings.durationEnabled = true
        sub.downloadFilterSettings.durationRules = [.init(behavior: .include, comparison: .longerThan, minutes: 40)]
        replay.reserve(in: sub, now: monday)
        XCTAssertEqual(replay.outstanding.first?.episode.title, "Episode 1")
        XCTAssertEqual(replay.outstanding.first?.due, monday)
    }
    func testUnknownDurationDefersInsteadOfDeclaringCatchUp() {
        var (sub, replay) = fixture()
        sub.downloadFilterSettings.durationEnabled = true
        sub.downloadFilterSettings.durationRules = [.init(behavior: .include, comparison: .longerThan, minutes: 40)]
        sub.episodes[0].durationSeconds = nil
        replay.reserve(in: sub, now: monday)
        XCTAssertTrue(replay.releases.isEmpty)
        XCTAssertTrue(replay.hasUnknownDuration(in: sub))
        XCTAssertFalse(replay.caughtUp(in: sub))
    }
    func testUnknownFutureDurationDoesNotBlockEarlierKnownMatchingEpisode() {
        var (sub, replay) = fixture(limit: .three)
        sub.downloadFilterSettings.durationEnabled = true
        sub.downloadFilterSettings.durationRules = [.init(behavior: .include, comparison: .longerThan, minutes: 10)]
        sub.episodes[1].durationSeconds = nil
        replay.reserve(in: sub, now: monday.addingTimeInterval(3 * day))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 0"])
    }
    func testManualExistingDownloadConsumesCapacity() {
        var (sub, replay) = fixture()
        sub.episodes[5].downloadState = .downloaded
        replay.reserve(in: sub, now: monday)
        XCTAssertTrue(replay.releases.isEmpty)
    }
    func testInactiveAndDisabledDoNotReserve() {
        var (sub, replay) = fixture()
        sub.excludeFromAutoFeedRefresh = true
        replay.reserve(in: sub, now: monday); XCTAssertTrue(replay.releases.isEmpty)
        sub.excludeFromAutoFeedRefresh = false; replay.enabled = false
        replay.reserve(in: sub, now: monday); XCTAssertTrue(replay.releases.isEmpty)
    }
    func testNoLimitUsesResumableBatches() {
        let (sub, initial) = fixture(count: 40, limit: .noLimit); var replay = initial
        let now = monday.addingTimeInterval(50 * day)
        replay.reserve(in: sub, now: now); XCTAssertEqual(replay.releases.count, 16)
        replay.reserve(in: sub, now: now); XCTAssertEqual(replay.releases.count, 32)
        replay.reserve(in: sub, now: now); XCTAssertEqual(replay.releases.count, 40)
    }
    func testCatchUpNeedsResolutionAndFreshSuccessfulFetch() {
        var (sub, replay) = fixture(count: 1)
        replay.reserve(in: sub, now: monday)
        XCTAssertFalse(replay.caughtUp(in: sub))
        replay.releases[0].resolved = true; replay.releases[0].resolvedAt = monday
        XCTAssertTrue(replay.caughtUp(in: sub)); XCTAssertFalse(replay.confirmedCaughtUp(in: sub))
        sub.refreshStats.lastFetchedAt = monday.addingTimeInterval(1)
        XCTAssertTrue(replay.confirmedCaughtUp(in: sub))
    }
    func testHistoricalPlayedEpisodeHasNewLogicalQueueMembershipAndResume() {
        var (sub, replay) = fixture()
        sub.episodes[0].playedState = .played; sub.episodes[0].wasCompleted = true
        sub.episodes[0].lastPlayedAt = monday.addingTimeInterval(-day)
        replay.reserve(in: sub, now: monday); sub.autoArchiveSettings.replay = replay
        let queue = QueueService().downloadedQueue(from: [sub])
        XCTAssertEqual(queue.map(\.title), ["Episode 0"])
        XCTAssertEqual(queue[0].downloadState, .notDownloaded)
        XCTAssertEqual(queue[0].playedState, .unplayed)
        XCTAssertTrue(sub.episodes[0].wasCompleted)
        XCTAssertEqual(replay.resumeTime(for: sub.episodes[0], savedTime: 1199), 0)
        sub.episodes[0].lastPlayedAt = monday.addingTimeInterval(1)
        XCTAssertEqual(replay.resumeTime(for: sub.episodes[0], savedTime: 120), 120)
    }
    func testManualRedownloadOfResolvedEpisodeRemainsQueuedAfterReplayDisabled() {
        var (sub, replay) = fixture()
        replay.reserve(in: sub, now: monday)
        replay.releases[0].resolved = true; replay.enabled = false
        sub.autoArchiveSettings.replay = replay
        sub.episodes[0].downloadState = .downloaded
        sub.episodes[0].localFileName = "manual.mp3"
        sub.episodes[0].isManualDownloadProtected = true
        XCTAssertEqual(QueueService().downloadedQueue(from: [sub]).map(\.title), ["Episode 0"])
    }
    func testPortablePayloadStripsLocalFilesAndLargeFeedContent() {
        let (sub, _) = fixture(); var ep = sub.episodes[0]
        ep.localFileURL = URL(fileURLWithPath: "/private/audio.mp3"); ep.localFileName = "audio.mp3"
        ep.description = String(repeating: "description", count: 10_000)
        let portable = PodcastReplay.portable(ep)
        XCTAssertNil(portable.localFileURL); XCTAssertNil(portable.localFileName); XCTAssertNil(portable.description)
    }
    func testConcurrentDisableAndCompletionPreserveBoth() {
        let (sub, initial) = fixture(); var owner = initial
        owner.reserve(in: sub, now: monday)
        var other = owner; other.enabled = false; other.edit(now: monday.addingTimeInterval(1))
        owner.releases[0].resolved = true
        let a = PodcastReplay.merged(owner, other)!
        let b = PodcastReplay.merged(other, owner)!
        XCTAssertEqual(a, b); XCTAssertFalse(a.enabled); XCTAssertTrue(a.releases[0].resolved)
        XCTAssertEqual(PodcastReplay.merged(a, owner), a)
    }
    func testConcurrentResolutionAndPinEditMergeIndependently() {
        let (sub, initial) = fixture(); var owner = initial
        owner.reserve(in: sub, now: monday)
        var other = owner
        other.releases[0].pin = .playNext; other.releases[0].pinEditedAt = monday; other.releases[0].pinEditID = "a"
        owner.releases[0].resolved = true
        let merged = PodcastReplay.merged(owner, other)!
        XCTAssertTrue(merged.releases[0].resolved); XCTAssertEqual(merged.releases[0].pin, .playNext)
    }
    func testOlderClientMissingReplayCannotEraseJournal() {
        let (_, replay) = fixture()
        XCTAssertEqual(PodcastReplay.merged(replay, nil), replay)
        XCTAssertEqual(PodcastReplay.merged(nil, replay), replay)
    }
    func testMergedProgressRemainsDirtyForUpload() {
        var (sub, replay) = fixture(); replay.reserve(in: sub, now: monday)
        sub.autoArchiveSettings.replay = replay
        var local = SubscriptionSyncState(subscription: sub); local.markClean()
        sub.autoArchiveSettings.replay?.releases[0].resolved = true
        var remote = SubscriptionSyncState(subscription: sub)
        remote.autoArchiveSettings.replay?.enabled = false
        let merged = local.merged(withRemote: remote)
        XCTAssertTrue(merged.autoArchiveSettings.replay!.releases[0].resolved)
        // A union identical to remote is clean; a locally retained release must upload.
        var localMore = sub; localMore.autoArchiveSettings.replay?.keptSchedule = true
        var projection = SubscriptionSyncState(subscription: localMore); projection.markClean()
        XCTAssertTrue(projection.merged(withRemote: remote).hasPendingChanges)
    }
    func testLegacySettingsDecodeDisabledAndRoundTripRetainsReplay() throws {
        XCTAssertNil(try JSONDecoder().decode(AutoArchiveSettings.self, from: Data("{}".utf8)).replay)
        var (sub, replay) = fixture(); replay.reserve(in: sub, now: monday); sub.autoArchiveSettings.replay = replay
        XCTAssertEqual(try JSONDecoder().decode(AutoArchiveSettings.self, from: JSONEncoder().encode(sub.autoArchiveSettings)), sub.autoArchiveSettings)
    }
    func testCalendarRecurrencePreservesFourAMAcrossMelbourneDST() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let before = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 4))!
        let (sub, _) = fixture()
        let replay = PodcastReplay(start: sub.episodes[0], firstRelease: before, everyDays: 1, ownerID: "phone", timeZoneID: "Australia/Melbourne")
        let next = replay.nextDate(after: before)
        XCTAssertEqual(calendar.component(.hour, from: next), 4)
        XCTAssertEqual(next.timeIntervalSince(before), 23 * 3600)
    }
    func testTVSnapshotRetainsReplayedHistoryUntilJournalResolves() {
        var (sub, replay) = fixture(); replay.reserve(in: sub, now: monday)
        sub.autoArchiveSettings.replay = replay; sub.episodes[0].playedState = .played
        var entry = QueueSnapshotEntry(episode: sub.episodes[0], podcastTitle: sub.title, podcastArtworkURL: nil)
        entry.replaySessionID = replay.sessionID
        let snapshot = QueueSnapshot(entries: [entry], updatedAt: monday, sourceDeviceID: "phone")
        XCTAssertEqual(QueueModel.resolvedQueueItems(from: snapshot, subscriptions: [sub]).count, 1)
        sub.autoArchiveSettings.replay?.releases[0].resolved = true
        XCTAssertTrue(QueueModel.resolvedQueueItems(from: snapshot, subscriptions: [sub]).isEmpty)
    }
    @MainActor
    private func makeStore(reservationDate: Date? = nil) throws -> (SubscriptionStore, Subscription, PodcastReplay) {
        let (sub, original) = fixture()
        let store = SubscriptionStore.inMemory()
        _ = try store.addSubscription(id: sub.id, feedURL: sub.feedURL, title: sub.title,
            author: nil, artworkURL: nil, latestEpisode: sub.episodes[0], insertAtBottom: true)
        store.updateEpisodes(subscriptionID: sub.id, episodes: sub.episodes)
        var replay = original
        if let reservationDate { replay.nextDue = reservationDate }
        replay.reserve(in: sub, now: reservationDate ?? monday)
        store.updatePodcastReplay(subscriptionID: sub.id, replay: replay)
        return (store, sub, replay)
    }
    @MainActor
    func testUnchangedJournalDoesNotPublishOrRestartScheduler() throws {
        let (store, sub, replay) = try makeStore()
        var emissions = 0
        let observation = store.objectWillChange.sink { emissions += 1 }
        store.updatePodcastReplay(subscriptionID: sub.id, replay: replay)
        XCTAssertEqual(emissions, 0)
        withExtendedLifetime(observation) {}
    }
    @MainActor
    func testManualArchiveResolvesReservationOnlyOnce() throws {
        let (store, sub, _) = try makeStore()
        store.markEpisodeArchived(subscriptionID: sub.id, episodeID: sub.episodes[0].id)
        let first = store.subscription(id: sub.id)?.autoArchiveSettings.replay
        XCTAssertEqual(first?.outstanding.count, 0)
        store.markEpisodeArchived(subscriptionID: sub.id, episodeID: sub.episodes[0].id)
        XCTAssertEqual(store.subscription(id: sub.id)?.autoArchiveSettings.replay, first)
    }
    @MainActor
    func testTVCompletionResolvesOwnerReservationThroughEpisodeStateSync() async throws {
        let (store, sub, _) = try makeStore()
        await store.flushPendingSaves()
        var episode = sub.episodes[0]; episode.playedState = .played; episode.wasCompleted = true
        episode.lastPlayedAt = monday.addingTimeInterval(60)
        let remote = EpisodeSyncState(episode: episode, subscriptionID: sub.id, dirtyAt: monday.addingTimeInterval(60))
        _ = store.applyRemoteEpisodeState(remote)
        XCTAssertTrue(store.subscription(id: sub.id)!.autoArchiveSettings.replay!.outstanding.isEmpty)
    }
    @MainActor
    func testOldRemoteHistoryCannotResolveNewReservation() async throws {
        let (store, sub, _) = try makeStore()
        await store.flushPendingSaves()
        var episode = sub.episodes[0]; episode.playedState = .played; episode.wasCompleted = true
        episode.lastPlayedAt = monday.addingTimeInterval(-day)
        _ = store.applyRemoteEpisodeState(EpisodeSyncState(episode: episode, subscriptionID: sub.id, dirtyAt: monday.addingTimeInterval(-day)))
        XCTAssertEqual(store.subscription(id: sub.id)!.autoArchiveSettings.replay!.outstanding.count, 1)
    }
    #if !AUTOHOP_SPM
    @MainActor
    func testQueueReadinessUpdatesWithoutChangingCompositionAndPinIsShared() throws {
        let (store, sub, _) = try makeStore()
        let queue = QueueCoordinator(subscriptionStore: store, queueService: QueueService(), currentEpisode: { nil }, showBadge: { false }, pinsFileURL: nil)
        queue.recompute(reason: "test")
        XCTAssertEqual(queue.episodes.first?.downloadState, .notDownloaded)
        var episodes = sub.episodes
        episodes[0].downloadState = .downloaded; episodes[0].localFileName = "ready.mp3"
        store.updateEpisodes(subscriptionID: sub.id, episodes: episodes)
        // Feed merge intentionally preserves local availability; mark through the lifecycle API instead.
        store.markEpisodeDownloaded(subscriptionID: sub.id, episodeID: episodes[0].id, localFileURL: URL(fileURLWithPath: "/tmp/ready.mp3"))
        queue.recompute(reason: "test.ready")
        XCTAssertEqual(queue.episodes.first?.downloadState, .downloaded)
        queue.playNext(queue.episodes[0])
        XCTAssertEqual(store.subscription(id: sub.id)?.autoArchiveSettings.replay?.releases[0].pin, .playNext)
    }
    #endif

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendarReplay(weekdays: [Int], minutes: [Int], from: String = "2026-09-14T00:00:00Z") -> PodcastReplay {
        var replay = fixture().1
        replay.calendarSchedule = .init(weekdays: weekdays, minutes: minutes)!
        replay.firstRelease = instant(from)
        replay.nextDue = replay.calendarSchedule!.nextDate(onOrAfter: replay.firstRelease, timeZoneID: "UTC")!
        return replay
    }
    func testCommuterHasTwoDistinctSlotsEachWeekdayAndSkipsWeekend() {
        let replay = calendarReplay(weekdays: [2, 3, 4, 5, 6], minutes: [360, 960])
        XCTAssertEqual(replay.nextDue, instant("2026-09-14T06:00:00Z"))
        XCTAssertEqual(replay.nextDate(after: replay.nextDue), instant("2026-09-14T16:00:00Z"))
        XCTAssertEqual(replay.nextDate(after: instant("2026-09-18T16:00:00Z")), instant("2026-09-21T06:00:00Z"))
    }
    func testTuesdayThursdayRollsStartDateForwardAndWrapsWeek() {
        let replay = calendarReplay(weekdays: [3, 5], minutes: [360, 960])
        XCTAssertEqual(replay.nextDue, instant("2026-09-15T06:00:00Z"))
        XCTAssertEqual(replay.nextDate(after: instant("2026-09-15T16:00:00Z")), instant("2026-09-17T06:00:00Z"))
        XCTAssertEqual(replay.nextDate(after: instant("2026-09-17T16:00:00Z")), instant("2026-09-22T06:00:00Z"))
    }
    func testSingleSelectedMondayAndDailyMidnight() {
        let weekly = calendarReplay(weekdays: [2], minutes: [240])
        XCTAssertEqual(weekly.nextDate(after: weekly.nextDue), instant("2026-09-21T04:00:00Z"))
        let daily = calendarReplay(weekdays: Array(1...7), minutes: [0, 1439])
        XCTAssertEqual(daily.nextDue, instant("2026-09-14T00:00:00Z"))
        XCTAssertEqual(daily.nextDate(after: daily.nextDue), instant("2026-09-14T23:59:00Z"))
        XCTAssertEqual(daily.nextDate(after: instant("2026-09-14T23:59:00Z")), instant("2026-09-15T00:00:00Z"))
    }
    func testCalendarValidationNormalisesDuplicatesAndRejectsEmpty() throws {
        let schedule = PodcastReplay.CalendarSchedule(weekdays: [3, 2, 2, 8], minutes: [960, 360, 360, -1])!
        XCTAssertEqual(schedule.weekdays, [2, 3]); XCTAssertEqual(schedule.minutes, [360, 960])
        XCTAssertNil(PodcastReplay.CalendarSchedule(weekdays: [], minutes: [360]))
        XCTAssertNil(PodcastReplay.CalendarSchedule(weekdays: [2], minutes: [1440]))
        XCTAssertThrowsError(try JSONDecoder().decode(PodcastReplay.CalendarSchedule.self, from: Data("{\"weekdays\":[],\"minutes\":[360]}".utf8)))
    }
    func testSubdailyCapacityOneWaitsThenRefillsOverdueAfternoonWithoutDuplicate() {
        let sub = fixture().0
        var replay = calendarReplay(weekdays: Array(1...7), minutes: [360, 960])
        replay.reserve(in: sub, now: instant("2026-09-14T06:00:00Z"))
        replay.reserve(in: sub, now: instant("2026-09-14T17:00:00Z"))
        XCTAssertEqual(replay.releases.count, 1)
        replay.releases[0].resolved = true
        replay.reserve(in: sub, now: instant("2026-09-14T17:00:00Z"))
        XCTAssertEqual(replay.releases.map(\.due), [instant("2026-09-14T06:00:00Z"), instant("2026-09-14T16:00:00Z")])
        let once = replay
        replay.reserve(in: sub, now: instant("2026-09-14T17:00:00Z"))
        XCTAssertEqual(replay, once)
    }
    func testSubdailyFiltersAndLimitTwoUseOnlyDueMatchingSlots() {
        var sub = fixture(limit: .two).0
        sub.downloadFilterSettings.durationEnabled = true
        sub.downloadFilterSettings.durationRules = [.init(behavior: .include, comparison: .longerThan, minutes: 40)]
        var replay = calendarReplay(weekdays: Array(1...7), minutes: [360, 960])
        replay.reserve(in: sub, now: instant("2026-09-14T15:59:59Z"))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 1"])
        replay.reserve(in: sub, now: instant("2026-09-14T16:00:00Z"))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 1", "Episode 2"])
    }
    func testCalendarDSTGapCollapsesCoincidentSlotsAndRepeatedHourReleasesOnce() {
        let schedule = PodcastReplay.CalendarSchedule(weekdays: Array(1...7), minutes: [150, 180])!
        let zone = "Australia/Melbourne"
        // 02:30 does not exist on 4 October: nextTime becomes 03:00.
        let first = schedule.nextDate(onOrAfter: instant("2026-10-03T14:00:00Z"), timeZoneID: zone)!
        XCTAssertEqual(first, instant("2026-10-03T16:00:00Z"))
        let next = schedule.nextDate(onOrAfter: first.addingTimeInterval(1), timeZoneID: zone)!
        XCTAssertEqual(next, instant("2026-10-04T15:30:00Z"))
        let repeated = PodcastReplay.CalendarSchedule(weekdays: Array(1...7), minutes: [150])!
        let autumn = repeated.nextDate(onOrAfter: instant("2026-04-04T13:00:00Z"), timeZoneID: zone)!
        XCTAssertEqual(autumn, instant("2026-04-04T15:30:00Z"))
        XCTAssertEqual(repeated.nextDate(onOrAfter: autumn.addingTimeInterval(1), timeZoneID: zone), instant("2026-04-05T16:30:00Z"))
    }
    func testCalendarUsesStoredZoneAcrossDSTAndDeviceZoneDifferences() {
        let schedule = PodcastReplay.CalendarSchedule(weekdays: Array(1...7), minutes: [360, 960])!
        let boundary = instant("2026-10-03T20:00:00Z")
        XCTAssertEqual(schedule.nextDate(onOrAfter: boundary, timeZoneID: "Australia/Melbourne"), instant("2026-10-04T05:00:00Z"))
        XCTAssertEqual(schedule.nextDate(onOrAfter: boundary, timeZoneID: "UTC"), instant("2026-10-04T06:00:00Z"))
    }
    func testCalendarPayloadRoundTripsInsideSyncedSettings() throws {
        var sub = fixture().0
        sub.autoArchiveSettings.replay = calendarReplay(weekdays: [3, 5], minutes: [360, 960])
        let data = try JSONEncoder().encode(sub.autoArchiveSettings)
        XCTAssertEqual(try JSONDecoder().decode(AutoArchiveSettings.self, from: data), sub.autoArchiveSettings)
    }
    func testCadenceEditWinsOverOldCursorButRetainsConcurrentReservations() {
        let sub = fixture(limit: .three).0
        var old = calendarReplay(weekdays: Array(1...7), minutes: [360])
        var edited = old
        edited.calendarSchedule = .init(weekdays: [3, 5], minutes: [360, 960])!
        edited.nextDue = instant("2026-09-15T06:00:00Z")
        edited.edit(now: old.editedAt.addingTimeInterval(1))
        old.reserve(in: sub, now: instant("2026-09-16T12:00:00Z"))
        let merged = PodcastReplay.merged(old, edited)!
        XCTAssertEqual(merged.calendarSchedule, edited.calendarSchedule)
        XCTAssertEqual(merged.nextDue, edited.nextDue)
        XCTAssertEqual(merged.releases, old.releases)
        XCTAssertEqual(PodcastReplay.merged(edited, old), merged)
        XCTAssertEqual(PodcastReplay.merged(merged, old), merged)
    }
    @MainActor
    func testSharedEpisodeLimitWritesPreserveReplayAndOtherArchiveSettings() throws {
        let (store, sub, replay) = try makeStore()
        var settings = store.subscription(id: sub.id)!.autoArchiveSettings
        settings.episodeLimit = .two
        store.updateAutoArchiveSettings(subscriptionID: sub.id, settings: settings)
        let saved = store.subscription(id: sub.id)!.autoArchiveSettings
        XCTAssertEqual(saved.episodeLimit, .two)
        XCTAssertEqual(saved.replay, replay)
        XCTAssertEqual(SubscriptionSyncState(subscription: store.subscription(id: sub.id)!).autoArchiveSettings.episodeLimit, .two)
        settings = saved; settings.episodeLimit = .one
        store.updateAutoArchiveSettings(subscriptionID: sub.id, settings: settings)
        XCTAssertEqual(store.subscription(id: sub.id)!.autoArchiveSettings.episodeLimit, .one)
        XCTAssertEqual(store.subscription(id: sub.id)!.autoArchiveSettings.replay!.outstanding.count, 1)
    }

    func testBingeSeedsImmediatelyWithoutStartingPlaybackOrWaitingForCalendar() {
        let sub = fixture().0
        var replay = calendarReplay(weekdays: [2], minutes: [360], from: "2030-01-01T00:00:00Z")
        replay.bingeMode = true
        replay.reserve(in: sub, now: monday)
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 0"])
        XCTAssertEqual(replay.outstanding.first?.due, monday)
        XCTAssertNil(replay.outstanding.first?.startedAt)
    }
    func testBingeLimitOneKeepsPlayingPlusOneUpcomingAndResumeDoesNotFanOut() {
        let sub = fixture().0
        var replay = fixture().1; replay.bingeMode = true
        replay.reserve(in: sub, now: monday)
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(1))
        replay.reserve(in: sub, now: monday.addingTimeInterval(1))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 0", "Episode 1"])
        let once = replay
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(60))
        replay.reserve(in: sub, now: monday.addingTimeInterval(60))
        XCTAssertEqual(replay, once)
        replay.releases[0].resolved = true
        replay.recordStart(of: sub.episodes[1], at: monday.addingTimeInterval(120))
        replay.reserve(in: sub, now: monday.addingTimeInterval(120))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 1", "Episode 2"])
    }
    func testBingeNoLimitStillPrefetchesOnlyOneUnstartedEpisode() {
        let sub = fixture(limit: .noLimit).0
        var replay = fixture().1; replay.bingeMode = true
        replay.reserve(in: sub, now: monday.addingTimeInterval(100 * day))
        XCTAssertEqual(replay.releases.count, 1)
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(101 * day))
        replay.reserve(in: sub, now: monday.addingTimeInterval(101 * day))
        XCTAssertEqual(replay.releases.count, 2)
    }
    func testBingeFiltersUnknownDurationAndExistingDownloadsStillGatePrefetch() {
        var sub = fixture().0
        sub.downloadFilterSettings.durationEnabled = true
        sub.downloadFilterSettings.durationRules = [.init(behavior: .include, comparison: .longerThan, minutes: 40)]
        var replay = fixture().1; replay.bingeMode = true
        sub.episodes[1].durationSeconds = nil
        replay.reserve(in: sub, now: monday); XCTAssertTrue(replay.releases.isEmpty)
        sub.episodes[1].durationSeconds = 3600
        replay.reserve(in: sub, now: monday)
        XCTAssertEqual(replay.outstanding.first?.episode.title, "Episode 1")
        replay.recordStart(of: sub.episodes[1], at: monday.addingTimeInterval(1))
        sub.episodes[5].downloadState = .downloaded
        replay.reserve(in: sub, now: monday.addingTimeInterval(1))
        XCTAssertEqual(replay.releases.count, 1)
        sub.episodes[5].playedState = .archived
        replay.reserve(in: sub, now: monday.addingTimeInterval(2))
        XCTAssertEqual(replay.releases.count, 2)
    }
    func testBingeDoesNotDiscountEveryPreviouslyStartedEpisode() {
        let sub = fixture().0
        var replay = fixture().1; replay.bingeMode = true
        replay.reserve(in: sub, now: monday)
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(1))
        replay.reserve(in: sub, now: monday.addingTimeInterval(1))
        // Explicitly start the next episode without finishing the previous one.
        replay.recordStart(of: sub.episodes[1], at: monday.addingTimeInterval(2))
        replay.reserve(in: sub, now: monday.addingTimeInterval(2))
        XCTAssertEqual(replay.releases.count, 2)
        XCTAssertEqual(replay.bingePlayingKey, sub.episodes[1].audioURL.absoluteString)
    }
    func testBingeStartMergeTriggersOneSuccessorAndRetainsDisable() {
        let sub = fixture().0
        var owner = fixture().1; owner.bingeMode = true
        owner.reserve(in: sub, now: monday)
        var follower = owner
        follower.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(1))
        owner = PodcastReplay.merged(owner, follower)!
        owner.reserve(in: sub, now: monday.addingTimeInterval(2))
        XCTAssertEqual(owner.releases.count, 2)
        let once = owner
        owner = PodcastReplay.merged(owner, follower)!
        owner.reserve(in: sub, now: monday.addingTimeInterval(3))
        XCTAssertEqual(owner, once)
        follower.enabled = false; follower.edit(now: monday.addingTimeInterval(10))
        let disabled = PodcastReplay.merged(owner, follower)!
        XCTAssertFalse(disabled.enabled); XCTAssertNotNil(disabled.releases[0].startedAt)
    }
    func testOldStartAndUnreleasedEpisodeCannotTriggerBinge() {
        let sub = fixture().0
        var replay = fixture().1; replay.bingeMode = true
        replay.reserve(in: sub, now: monday)
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(-1))
        replay.recordStart(of: sub.episodes[4], at: monday.addingTimeInterval(1))
        replay.reserve(in: sub, now: monday.addingTimeInterval(2))
        XCTAssertEqual(replay.releases.count, 1); XCTAssertNil(replay.releases[0].startedAt)
    }
    func testBingePayloadRoundTripAndExistingPayloadDefaultsOff() throws {
        var replay = fixture().1
        XCTAssertFalse(try JSONDecoder().decode(PodcastReplay.self, from: JSONEncoder().encode(replay)).isBinge)
        replay.bingeMode = true
        replay.reserve(in: fixture().0, now: monday)
        replay.recordStart(of: replay.start, at: monday.addingTimeInterval(1))
        XCTAssertEqual(try JSONDecoder().decode(PodcastReplay.self, from: JSONEncoder().encode(replay)), replay)
    }
    @MainActor
    func testSuccessfulLocalAndRemoteStartsAuthorBingeEvidence() throws {
        let (store, sub, _) = try makeStore(reservationDate: Date().addingTimeInterval(-1))
        store.markEpisodePlaying(subscriptionID: sub.id, episodeID: sub.episodes[0].id)
        XCTAssertNotNil(store.subscription(id: sub.id)!.autoArchiveSettings.replay!.releases[0].startedAt)
        let (otherStore, otherSub, replay) = try makeStore()
        var episode = otherSub.episodes[0]; episode.playedState = .playing
        episode.lastPlayedAt = max(Date(), replay.createdAt).addingTimeInterval(1)
        let remote = EpisodeSyncState(episode: episode, subscriptionID: otherSub.id, dirtyAt: episode.lastPlayedAt!)
        _ = otherStore.applyRemoteEpisodeState(remote)
        XCTAssertNotNil(otherStore.subscription(id: otherSub.id)!.autoArchiveSettings.replay!.releases[0].startedAt)
    }
    func testBingeLeavesPriorityStackAndManualPinsUnchanged() {
        var (sub, replay) = fixture(); replay.bingeMode = true
        replay.reserve(in: sub, now: monday)
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(1))
        replay.reserve(in: sub, now: monday.addingTimeInterval(1))
        sub.autoArchiveSettings.replay = replay; sub.priorityRank = 2
        var other = Subscription(feedURL: URL(string: "https://other.example/feed")!, title: "Priority", priorityRank: 1)
        var ep = Episode(subscriptionID: other.id, guid: "priority", title: "Priority episode", audioURL: URL(string: "https://other.example/1.mp3")!)
        ep.downloadState = .downloaded; ep.localFileName = "1.mp3"; other.episodes = [ep]
        let queue = QueueModel.downloadedQueue(from: [sub, other], pins: QueuePins())
        XCTAssertEqual(queue.first?.id, ep.id)
        let pinned = QueueModel.applyPins(queue, pins: QueuePins(playNextIDs: [sub.episodes[1].id]))
        XCTAssertEqual(pinned.first?.id, sub.episodes[1].id)
    }

    func testBingeAdoptsAlreadyDownloadedStartingEpisodeWithoutDoubleCountingCapacity() {
        var sub = fixture().0
        sub.episodes[0].downloadState = .downloaded
        var replay = fixture().1; replay.bingeMode = true
        replay.reserve(in: sub, now: monday)
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 0"])
        replay.recordStart(of: sub.episodes[0], at: monday.addingTimeInterval(1))
        replay.reserve(in: sub, now: monday.addingTimeInterval(1))
        XCTAssertEqual(replay.outstanding.map(\.episode.title), ["Episode 0", "Episode 1"])
    }

}
