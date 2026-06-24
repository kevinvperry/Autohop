import Foundation

// AI CONTEXT — Models/Subscription.swift
// Value types and pure refresh intelligence for one subscribed podcast and its
// per-podcast policies. All persisted by SubscriptionStore except transient
// scheduling/priority predictions. Contains:
//  - AutoArchiveSettings: three independent rules (AfterPlayed delay,
//    AfterInactive timeout, EpisodeLimit keep-N). Defaults: afterPlaying /
//    1 week / keep 1. Enforced by AppState.runAutoArchive every ≤30 min.
//  - ChapterFilter: set of DISABLED chapter position indices; position-based
//    so a disabled slot skips that chapter in every future episode.
//  - RefreshStats: Release Radar state — ETag/Last-Modified for HTTP
//    conditional GETs, last fetch/new-episode timing, legacy recentPublishDates,
//    and capped releaseObservations. releaseObservations persist each episode's
//    GUID/title/audio URL, RSS publishedAt, first/last seen time, date quality,
//    and whether it was new when first observed; AppState/SubscriptionStore keep
//    this updated so one-item feeds can still accumulate schedule history.
//  - FeedScheduleProfiler: classifies observations into learning, unreliable
//    dates, hourly, rolling-bulletin, burst, weekday-daily, weekly, multi-slot,
//    or random profiles. It learns active weekdays, typical minutes, mixed
//    half-hour/hourly bulletin slots, burst windows, cadence, and confidence
//    without touching app state or network code.
//  - FeedRefreshScheduling: converts a schedule profile plus fetch stats into a
//    FeedRefreshPrediction. Learned feeds open pre-release windows, check in high
//    rotation during active/fresh-missed windows, expire stale missed-release
//    urgency after repeated empty checks or window age, stand down during quiet
//    periods, and fall back to the legacy cadence model when the profile is
//    incomplete. Daily weekday feeds deliberately start checking about 30 min
//    before the learned release time; missed-release urgency expires after 10
//    post-window empty checks or 8 hours so a late show does not dominate forever.
//  - FeedRefreshPrioritizer: scores already-due feeds so AppState's timed and
//    background cycles spend limited refresh slots on missed releases, active
//    windows, high-confidence hourly/rolling-bulletin/burst/daily feeds (daily
//    gets the strongest release-window kind boost), learning/random feeds, user
//    priority rank, stale feeds, and overdue feeds before ordinary due work.
//  - FeedRefreshBudgeting: pure budget selector used by AppState to cap due-feed
//    cycles while letting active/pre-window states bypass the foreground cap and
//    protecting Release Radar states in tight background budgets.
//  - Subscription: priorityRank (1 = top of Priority Stack, drives queue
//    order), episodes array, playbackPreference, notificationsEnabled
//    (default false), excludeFromAutoFeedRefresh, remembered return rank for
//    inactive shows, and browseDate — non-nil marks an invisible "browse
//    subscription" auto-created when the user previews a podcast in search
//    (deleted after 30 days if untouched).

// MARK: - AutoArchiveSettings

public struct AutoArchiveSettings: Equatable, Codable, Sendable {

    // Rule 1: archive played episodes after this interval
    public enum AfterPlayed: String, CaseIterable, Codable, Sendable {
        case never
        case afterPlaying
        case hours24
        case days2
        case days7

        public var title: String {
            switch self {
            case .never:        return "Never"
            case .afterPlaying: return "After Playing"
            case .hours24:      return "After 24h"
            case .days2:        return "After 2 Days"
            case .days7:        return "After 1 Week"
            }
        }

        /// Nil = archive immediately on play; positive = archive after interval post-play; .never = don't archive.
        public var interval: TimeInterval? {
            switch self {
            case .never:        return nil          // disabled
            case .afterPlaying: return 0            // archive as soon as played
            case .hours24:      return 24 * 3600
            case .days2:        return 2 * 24 * 3600
            case .days7:        return 7 * 24 * 3600
            }
        }
    }

    // Rule 2: archive inactive (unplayed, untouched) episodes after this interval
    public enum AfterInactive: String, CaseIterable, Codable, Sendable {
        case never
        case hours4
        case hours8
        case hours16
        case hours24
        case days2
        case days3
        case days7
        case days14
        case days30
        case days90

        public var title: String {
            switch self {
            case .never:   return "Never"
            case .hours4:  return "4 Hours"
            case .hours8:  return "8 Hours"
            case .hours16: return "16 Hours"
            case .hours24: return "24 Hours"
            case .days2:   return "2 Days"
            case .days3:   return "3 Days"
            case .days7:   return "1 Week"
            case .days14:  return "2 Weeks"
            case .days30:  return "30 Days"
            case .days90:  return "90 Days"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .never:   return nil
            case .hours4:  return 4 * 3600
            case .hours8:  return 8 * 3600
            case .hours16: return 16 * 3600
            case .hours24: return 24 * 3600
            case .days2:   return 2 * 24 * 3600
            case .days3:   return 3 * 24 * 3600
            case .days7:   return 7 * 24 * 3600
            case .days14:  return 14 * 24 * 3600
            case .days30:  return 30 * 24 * 3600
            case .days90:  return 90 * 24 * 3600
            }
        }
    }

    // Rule 3: keep only the N most recently published episodes
    public enum EpisodeLimit: Int, CaseIterable, Codable, Sendable {
        case noLimit = 0
        case one     = 1
        case two     = 2
        case three   = 3
        case four    = 4
        case five    = 5
        case ten     = 10

        public var title: String {
            switch self {
            case .noLimit: return "No Limit"
            case .one:     return "1"
            case .two:     return "2"
            case .three:   return "3"
            case .four:    return "4"
            case .five:    return "5"
            case .ten:     return "10"
            }
        }
    }

    public var afterPlayed: AfterPlayed
    public var afterInactive: AfterInactive
    public var episodeLimit: EpisodeLimit

    public static let `default` = AutoArchiveSettings(
        afterPlayed: .afterPlaying,
        afterInactive: .days7,
        episodeLimit: .one
    )

    public init(
        afterPlayed: AfterPlayed = .afterPlaying,
        afterInactive: AfterInactive = .days7,
        episodeLimit: EpisodeLimit = .one
    ) {
        self.afterPlayed = afterPlayed
        self.afterInactive = afterInactive
        self.episodeLimit = episodeLimit
    }
}

// MARK: - Feed release observations

/// Quality marker for RSS publish dates captured in release observations.
public enum FeedReleaseDateQuality: String, Codable, Sendable {
    case missing
    case plausible
    case futureDated
    case implausiblyOld
}

/// One episode's release signal as seen in a feed refresh.
public struct FeedReleaseObservation: Equatable, Codable, Sendable {
    public var episodeKey: String
    public var guid: String
    public var title: String
    public var audioURL: URL?
    public var publishedAt: Date?
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var dateQuality: FeedReleaseDateQuality
    /// True when the episode was not present in the subscription before the fetch
    /// that first recorded this observation.
    public var wasNewWhenFirstSeen: Bool

    public init(
        episodeKey: String,
        guid: String,
        title: String,
        audioURL: URL?,
        publishedAt: Date?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        dateQuality: FeedReleaseDateQuality,
        wasNewWhenFirstSeen: Bool
    ) {
        self.episodeKey = episodeKey
        self.guid = guid
        self.title = title
        self.audioURL = audioURL
        self.publishedAt = publishedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.dateQuality = dateQuality
        self.wasNewWhenFirstSeen = wasNewWhenFirstSeen
    }
}

// MARK: - RefreshStats

/// Per-feed fetch bookkeeping that drives adaptive refresh scheduling and stores
/// longer release observations for the next-generation schedule learner.
public struct RefreshStats: Equatable, Codable, Sendable {
    /// HTTP validators for conditional requests (304 Not Modified).
    public var etag: String?
    public var lastModified: String?
    /// When the feed was last fetched (any outcome).
    public var lastFetchedAt: Date?
    /// When a fetch last discovered a new episode.
    public var lastNewEpisodeAt: Date?
    /// Fetches since the last new episode. Drives hiatus decay.
    public var consecutiveEmptyFetches: Int
    /// Publish dates of recently discovered latest episodes (newest last, capped).
    /// Feeds that expose only one item at a time (hourly or mixed-cadence news
    /// bulletins) carry too few dates to derive a cadence from the feed alone —
    /// this history fills the gap.
    public var recentPublishDates: [Date]
    /// Longer per-episode observation history for schedule learning. Current
    /// refresh scheduling intentionally does not read this yet.
    public var releaseObservations: [FeedReleaseObservation]

    public static let maxRecentPublishDates = 10
    public static let maxReleaseObservations = 200

    public init(
        etag: String? = nil,
        lastModified: String? = nil,
        lastFetchedAt: Date? = nil,
        lastNewEpisodeAt: Date? = nil,
        consecutiveEmptyFetches: Int = 0,
        recentPublishDates: [Date] = [],
        releaseObservations: [FeedReleaseObservation] = []
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.lastFetchedAt = lastFetchedAt
        self.lastNewEpisodeAt = lastNewEpisodeAt
        self.consecutiveEmptyFetches = consecutiveEmptyFetches
        self.recentPublishDates = recentPublishDates
        self.releaseObservations = releaseObservations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        lastFetchedAt = try container.decodeIfPresent(Date.self, forKey: .lastFetchedAt)
        lastNewEpisodeAt = try container.decodeIfPresent(Date.self, forKey: .lastNewEpisodeAt)
        consecutiveEmptyFetches = try container.decodeIfPresent(Int.self, forKey: .consecutiveEmptyFetches) ?? 0
        recentPublishDates = try container.decodeIfPresent([Date].self, forKey: .recentPublishDates) ?? []
        releaseObservations = try container.decodeIfPresent([FeedReleaseObservation].self, forKey: .releaseObservations) ?? []
    }

    public mutating func recordFetch(foundNewEpisode: Bool, publishedAt: Date? = nil, at date: Date = Date()) {
        lastFetchedAt = date
        if foundNewEpisode {
            lastNewEpisodeAt = date
            consecutiveEmptyFetches = 0
            if let publishedAt, !recentPublishDates.contains(publishedAt) {
                recentPublishDates.append(publishedAt)
                recentPublishDates.sort()
                if recentPublishDates.count > Self.maxRecentPublishDates {
                    recentPublishDates.removeFirst(recentPublishDates.count - Self.maxRecentPublishDates)
                }
            }
        } else {
            consecutiveEmptyFetches += 1
        }
    }

    @discardableResult
    public mutating func recordEpisodeObservations(
        _ episodes: [Episode],
        previouslyKnownEpisodeKeys: Set<String>,
        at date: Date = Date()
    ) -> Int {
        guard !episodes.isEmpty else { return 0 }

        var observationsByKey: [String: Int] = [:]
        for (index, observation) in releaseObservations.enumerated() {
            observationsByKey[observation.episodeKey] = observationsByKey[observation.episodeKey] ?? index
        }
        var newlyRecorded = 0

        for episode in episodes {
            let key = Self.releaseObservationKey(for: episode)
            let dateQuality = Self.releaseDateQuality(for: episode.publishedAt, observedAt: date)

            if let index = observationsByKey[key] {
                releaseObservations[index].guid = episode.guid
                releaseObservations[index].title = episode.title
                releaseObservations[index].audioURL = episode.audioURL
                releaseObservations[index].publishedAt = episode.publishedAt
                releaseObservations[index].lastSeenAt = date
                releaseObservations[index].dateQuality = dateQuality
            } else {
                let observation = FeedReleaseObservation(
                    episodeKey: key,
                    guid: episode.guid,
                    title: episode.title,
                    audioURL: episode.audioURL,
                    publishedAt: episode.publishedAt,
                    firstSeenAt: date,
                    lastSeenAt: date,
                    dateQuality: dateQuality,
                    wasNewWhenFirstSeen: !previouslyKnownEpisodeKeys.contains(key)
                )
                releaseObservations.append(observation)
                observationsByKey[key] = releaseObservations.count - 1
                newlyRecorded += 1
            }
        }

        releaseObservations.sort {
            ($0.publishedAt ?? $0.firstSeenAt) < ($1.publishedAt ?? $1.firstSeenAt)
        }
        if releaseObservations.count > Self.maxReleaseObservations {
            releaseObservations.removeFirst(releaseObservations.count - Self.maxReleaseObservations)
        }
        return newlyRecorded
    }

    public static func releaseObservationKey(for episode: Episode) -> String {
        let trimmedGUID = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGUID.isEmpty {
            return "guid:\(trimmedGUID)"
        }
        return "audio:\(episode.audioURL.absoluteString)"
    }

    private static func releaseDateQuality(for publishedAt: Date?, observedAt: Date) -> FeedReleaseDateQuality {
        guard let publishedAt else { return .missing }
        if publishedAt > observedAt.addingTimeInterval(24 * 60 * 60) {
            return .futureDated
        }
        if observedAt.timeIntervalSince(publishedAt) > 10 * 365 * 24 * 60 * 60 {
            return .implausiblyOld
        }
        return .plausible
    }

    public func scheduleProfile(calendar: Calendar = .current) -> FeedScheduleProfile {
        FeedScheduleProfiler.profile(from: releaseObservations, calendar: calendar)
    }
}

// MARK: - Feed schedule profiling

public enum FeedScheduleKind: String, Codable, Sendable {
    case learning
    case unreliableDates
    case hourly
    case rollingBulletin
    case burst
    case dailyWeekdays
    case weekly
    case multiSlot
    case random
}

public struct FeedScheduleWindow: Equatable, Codable, Sendable {
    /// Swift Calendar weekday numbers: 1 = Sunday, 2 = Monday, ... 7 = Saturday.
    public var activeWeekdays: [Int]
    /// Minutes after local midnight.
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int
    public var typicalMinuteOfDay: Int
    public var observedEpisodeCount: Int

    public init(
        activeWeekdays: [Int],
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        typicalMinuteOfDay: Int,
        observedEpisodeCount: Int
    ) {
        self.activeWeekdays = activeWeekdays
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.typicalMinuteOfDay = typicalMinuteOfDay
        self.observedEpisodeCount = observedEpisodeCount
    }
}

public struct FeedScheduleProfile: Equatable, Codable, Sendable {
    public var kind: FeedScheduleKind
    public var confidence: Double
    public var observationCount: Int
    public var reliableDateCount: Int
    /// Swift Calendar weekday numbers: 1 = Sunday, 2 = Monday, ... 7 = Saturday.
    public var activeWeekdays: [Int]
    public var typicalMinuteOfDay: Int?
    public var typicalMinuteOfHour: Int?
    /// Multiple minute-of-hour slots for rolling bulletin feeds that mix hourly
    /// and half-hourly releases, for example :00 and :30.
    public var typicalMinutesOfHour: [Int]?
    public var cadenceSeconds: TimeInterval?
    public var burstWindow: FeedScheduleWindow?
    public var reason: String

    public init(
        kind: FeedScheduleKind,
        confidence: Double,
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int],
        typicalMinuteOfDay: Int? = nil,
        typicalMinuteOfHour: Int? = nil,
        typicalMinutesOfHour: [Int]? = nil,
        cadenceSeconds: TimeInterval? = nil,
        burstWindow: FeedScheduleWindow? = nil,
        reason: String
    ) {
        self.kind = kind
        self.confidence = min(max(confidence, 0), 1)
        self.observationCount = observationCount
        self.reliableDateCount = reliableDateCount
        self.activeWeekdays = activeWeekdays
        self.typicalMinuteOfDay = typicalMinuteOfDay
        self.typicalMinuteOfHour = typicalMinuteOfHour
        self.typicalMinutesOfHour = typicalMinutesOfHour
        self.cadenceSeconds = cadenceSeconds
        self.burstWindow = burstWindow
        self.reason = reason
    }
}

public enum FeedScheduleProfiler {
    private static let minimumReliableDates = 4
    private static let hourlyMinimumDates = 6
    private static let burstMinimumDays = 3

    public static func profile(
        from observations: [FeedReleaseObservation],
        calendar: Calendar = .current
    ) -> FeedScheduleProfile {
        let observationCount = observations.count
        let reliableObservations = observations
            .filter { $0.dateQuality == .plausible }
            .compactMap { observation -> (observation: FeedReleaseObservation, publishedAt: Date)? in
                guard let publishedAt = observation.publishedAt else { return nil }
                return (observation, publishedAt)
            }
            .sorted { $0.publishedAt < $1.publishedAt }
        let reliableDateCount = reliableObservations.count
        let activeWeekdays = sortedActiveWeekdays(
            from: reliableObservations.map(\.publishedAt),
            calendar: calendar
        )

        if observationCount >= minimumReliableDates,
           reliableDateCount < max(2, observationCount / 2) {
            return FeedScheduleProfile(
                kind: .unreliableDates,
                confidence: 0.75,
                observationCount: observationCount,
                reliableDateCount: reliableDateCount,
                activeWeekdays: activeWeekdays,
                reason: "Most observed episodes have missing or suspicious RSS publish dates."
            )
        }

        guard reliableDateCount >= minimumReliableDates else {
            return FeedScheduleProfile(
                kind: .learning,
                confidence: learningConfidence(reliableDateCount),
                observationCount: observationCount,
                reliableDateCount: reliableDateCount,
                activeWeekdays: activeWeekdays,
                reason: "Not enough reliable publish dates to classify this feed yet."
            )
        }

        let dates = reliableObservations.map(\.publishedAt)
        let minuteOfDayCluster = circularCluster(
            minutes: dates.map { minuteOfDay(for: $0, calendar: calendar) },
            modulo: 24 * 60
        )
        let minuteOfHourCluster = circularCluster(
            minutes: dates.map { calendar.component(.minute, from: $0) },
            modulo: 60
        )
        let intervals = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 }
        let medianInterval = median(intervals)
        let weekdayCounts = countsByWeekday(dates, calendar: calendar)

        if let profile = hourlyProfile(
            dates: dates,
            minuteOfHourCluster: minuteOfHourCluster,
            medianInterval: medianInterval,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays
        ) {
            return profile
        }

        if let profile = rollingBulletinProfile(
            dates: dates,
            calendar: calendar,
            intervals: intervals,
            medianInterval: medianInterval,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays
        ) {
            return profile
        }

        if let profile = burstProfile(
            dates: dates,
            calendar: calendar,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays
        ) {
            return profile
        }

        if let profile = dailyWeekdaysProfile(
            dates: dates,
            minuteOfDayCluster: minuteOfDayCluster,
            weekdayCounts: weekdayCounts,
            medianInterval: medianInterval,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays
        ) {
            return profile
        }

        if let profile = weeklyProfile(
            dates: dates,
            minuteOfDayCluster: minuteOfDayCluster,
            weekdayCounts: weekdayCounts,
            medianInterval: medianInterval,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays
        ) {
            return profile
        }

        if let profile = multiSlotProfile(
            dates: dates,
            minuteOfDayCluster: minuteOfDayCluster,
            weekdayCounts: weekdayCounts,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays
        ) {
            return profile
        }

        return FeedScheduleProfile(
            kind: .random,
            confidence: min(0.8, 0.45 + Double(min(reliableDateCount, 12)) / 40.0),
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays,
            typicalMinuteOfDay: minuteOfDayCluster.center,
            cadenceSeconds: medianInterval,
            reason: "Reliable dates exist, but they do not form a stable hourly, rolling-bulletin, burst, daily, weekly, or multi-slot pattern."
        )
    }

    private static func hourlyProfile(
        dates: [Date],
        minuteOfHourCluster: (center: Int, spread: Int),
        medianInterval: TimeInterval?,
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int]
    ) -> FeedScheduleProfile? {
        guard reliableDateCount >= hourlyMinimumDates,
              let medianInterval,
              (30 * 60)...(2 * 60 * 60) ~= medianInterval,
              minuteOfHourCluster.spread <= 14
        else { return nil }

        let confidence = 0.62
            + min(0.18, Double(reliableDateCount - hourlyMinimumDates) * 0.02)
            + max(0, 0.15 - Double(minuteOfHourCluster.spread) / 100.0)
        return FeedScheduleProfile(
            kind: .hourly,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays,
            typicalMinuteOfHour: minuteOfHourCluster.center,
            cadenceSeconds: medianInterval,
            reason: "Episodes arrive at a near-hourly cadence around the same minute of the hour."
        )
    }

    private static func rollingBulletinProfile(
        dates: [Date],
        calendar: Calendar,
        intervals: [TimeInterval],
        medianInterval: TimeInterval?,
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int]
    ) -> FeedScheduleProfile? {
        guard reliableDateCount >= hourlyMinimumDates + 2,
              intervals.count >= hourlyMinimumDates,
              let medianInterval,
              (25 * 60)...(75 * 60) ~= medianInterval
        else { return nil }

        let cadenceMatches = intervals.filter(isRollingBulletinInterval).count
        let cadenceRatio = Double(cadenceMatches) / Double(max(intervals.count, 1))
        guard cadenceRatio >= 0.65 else { return nil }

        let minuteBuckets = dominantMinuteOfHourBuckets(dates: dates, calendar: calendar)
        guard (2...4).contains(minuteBuckets.count) else { return nil }

        let bucketSet = Set(minuteBuckets)
        let coveredDates = dates.filter { date in
            let bucket = roundedMinuteOfHour(calendar.component(.minute, from: date))
            return bucketSet.contains(bucket)
        }.count
        let coverageRatio = Double(coveredDates) / Double(max(dates.count, 1))
        guard coverageRatio >= 0.75 else { return nil }

        let confidence = 0.58
            + min(0.16, Double(reliableDateCount - hourlyMinimumDates) * 0.015)
            + min(0.16, cadenceRatio * 0.16)
            + min(0.1, coverageRatio * 0.1)
        return FeedScheduleProfile(
            kind: .rollingBulletin,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays,
            typicalMinuteOfHour: minuteBuckets.first,
            typicalMinutesOfHour: minuteBuckets,
            cadenceSeconds: medianInterval,
            reason: "Rolling bulletin feed with predictable minute marks and mixed half-hour/hourly cadence."
        )
    }

    private static func burstProfile(
        dates: [Date],
        calendar: Calendar,
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int]
    ) -> FeedScheduleProfile? {
        let groupedByDay = Dictionary(grouping: dates) { calendar.startOfDay(for: $0) }
        let burstDays = groupedByDay.values.compactMap { dayDates -> (start: Int, end: Int, center: Int, count: Int)? in
            guard dayDates.count >= 2 else { return nil }
            let minutes = dayDates.map { minuteOfDay(for: $0, calendar: calendar) }.sorted()
            guard let first = minutes.first, let last = minutes.last else { return nil }
            let span = last - first
            guard span <= 120 else { return nil }
            return (first, last, first + span / 2, dayDates.count)
        }
        guard burstDays.count >= burstMinimumDays else { return nil }

        let centers = burstDays.map(\.center)
        let centerCluster = circularCluster(minutes: centers, modulo: 24 * 60)
        guard centerCluster.spread <= 90 else { return nil }

        let start = median(burstDays.map(\.start)) ?? max(0, centerCluster.center - centerCluster.spread / 2)
        let end = median(burstDays.map(\.end)) ?? min(24 * 60 - 1, centerCluster.center + centerCluster.spread / 2)
        let averageEpisodesPerBurst = Double(burstDays.map(\.count).reduce(0, +)) / Double(burstDays.count)
        let confidence = 0.58
            + min(0.2, Double(burstDays.count - burstMinimumDays) * 0.04)
            + min(0.12, max(0, averageEpisodesPerBurst - 2) * 0.04)
            + max(0, 0.1 - Double(centerCluster.spread) / 900.0)

        return FeedScheduleProfile(
            kind: .burst,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays,
            typicalMinuteOfDay: centerCluster.center,
            burstWindow: FeedScheduleWindow(
                activeWeekdays: activeWeekdays,
                startMinuteOfDay: start,
                endMinuteOfDay: end,
                typicalMinuteOfDay: centerCluster.center,
                observedEpisodeCount: burstDays.map(\.count).reduce(0, +)
            ),
            reason: "Multiple episodes repeatedly appear within a short daily window, followed by quiet time."
        )
    }

    private static func dailyWeekdaysProfile(
        dates: [Date],
        minuteOfDayCluster: (center: Int, spread: Int),
        weekdayCounts: [Int: Int],
        medianInterval: TimeInterval?,
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int]
    ) -> FeedScheduleProfile? {
        let weekdayTotal = weekdayCounts
            .filter { isBusinessWeekday($0.key) }
            .map(\.value)
            .reduce(0, +)
        let weekdayRatio = Double(weekdayTotal) / Double(max(dates.count, 1))
        let distinctBusinessWeekdays = Set(activeWeekdays.filter(isBusinessWeekday)).count
        guard reliableDateCount >= 6,
              distinctBusinessWeekdays >= 3,
              weekdayRatio >= 0.85,
              minuteOfDayCluster.spread <= 90,
              (medianInterval ?? 24 * 60 * 60) <= 3 * 24 * 60 * 60
        else { return nil }

        let confidence = 0.62
            + min(0.16, Double(distinctBusinessWeekdays) * 0.025)
            + min(0.12, Double(reliableDateCount - 6) * 0.015)
            + max(0, 0.1 - Double(minuteOfDayCluster.spread) / 900.0)
        return FeedScheduleProfile(
            kind: .dailyWeekdays,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays,
            typicalMinuteOfDay: minuteOfDayCluster.center,
            cadenceSeconds: medianInterval,
            reason: "Episodes cluster around one time of day on business weekdays."
        )
    }

    private static func weeklyProfile(
        dates: [Date],
        minuteOfDayCluster: (center: Int, spread: Int),
        weekdayCounts: [Int: Int],
        medianInterval: TimeInterval?,
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int]
    ) -> FeedScheduleProfile? {
        guard let dominant = weekdayCounts.max(by: { $0.value < $1.value }) else { return nil }
        let dominantRatio = Double(dominant.value) / Double(max(dates.count, 1))
        guard reliableDateCount >= 4,
              dominantRatio >= 0.7,
              minuteOfDayCluster.spread <= 120,
              let medianInterval,
              (5 * 24 * 60 * 60)...(9 * 24 * 60 * 60) ~= medianInterval
        else { return nil }

        let confidence = 0.6
            + min(0.16, Double(reliableDateCount - 4) * 0.025)
            + min(0.12, dominantRatio * 0.12)
            + max(0, 0.1 - Double(minuteOfDayCluster.spread) / 1200.0)
        return FeedScheduleProfile(
            kind: .weekly,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: [dominant.key],
            typicalMinuteOfDay: minuteOfDayCluster.center,
            cadenceSeconds: medianInterval,
            reason: "Episodes repeatedly land on the same weekday around the same time."
        )
    }

    private static func multiSlotProfile(
        dates: [Date],
        minuteOfDayCluster: (center: Int, spread: Int),
        weekdayCounts: [Int: Int],
        observationCount: Int,
        reliableDateCount: Int,
        activeWeekdays: [Int]
    ) -> FeedScheduleProfile? {
        let distinctWeekdays = Set(activeWeekdays)
        guard reliableDateCount >= 6,
              (2...4).contains(distinctWeekdays.count),
              minuteOfDayCluster.spread <= 90
        else { return nil }

        let dominantRatio = Double(weekdayCounts.values.max() ?? 0) / Double(max(dates.count, 1))
        guard dominantRatio < 0.7 else { return nil }

        let confidence = 0.54
            + min(0.16, Double(reliableDateCount - 6) * 0.02)
            + max(0, 0.12 - Double(minuteOfDayCluster.spread) / 900.0)
        return FeedScheduleProfile(
            kind: .multiSlot,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: activeWeekdays,
            typicalMinuteOfDay: minuteOfDayCluster.center,
            reason: "Episodes recur on a small set of weekdays around the same time."
        )
    }

    private static func countsByWeekday(_ dates: [Date], calendar: Calendar) -> [Int: Int] {
        dates.reduce(into: [:]) { counts, date in
            counts[calendar.component(.weekday, from: date), default: 0] += 1
        }
    }

    private static func sortedActiveWeekdays(from dates: [Date], calendar: Calendar) -> [Int] {
        countsByWeekday(dates, calendar: calendar)
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private static func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private static func circularCluster(minutes: [Int], modulo: Int) -> (center: Int, spread: Int) {
        let normalized = minutes.map { (($0 % modulo) + modulo) % modulo }.sorted()
        guard let first = normalized.first else { return (0, modulo) }
        guard normalized.count > 1 else { return (first, 0) }

        var largestGap = -1
        var largestGapIndex = 0
        for index in normalized.indices {
            let current = normalized[index]
            let next = index == normalized.count - 1 ? normalized[0] + modulo : normalized[index + 1]
            let gap = next - current
            if gap > largestGap {
                largestGap = gap
                largestGapIndex = index
            }
        }

        let startIndex = (largestGapIndex + 1) % normalized.count
        let start = normalized[startIndex]
        let spread = max(0, modulo - largestGap)
        return ((start + spread / 2) % modulo, spread)
    }

    private static func dominantMinuteOfHourBuckets(dates: [Date], calendar: Calendar) -> [Int] {
        var counts: [Int: Int] = [:]
        for date in dates {
            let bucket = roundedMinuteOfHour(calendar.component(.minute, from: date))
            counts[bucket, default: 0] += 1
        }

        let minimumBucketCount = max(2, Int(ceil(Double(dates.count) * 0.12)))
        return counts
            .filter { $0.value >= minimumBucketCount }
            .sorted { $0.key < $1.key }
            .map(\.key)
    }

    private static func roundedMinuteOfHour(_ minute: Int) -> Int {
        let granularity = 5
        let normalized = ((minute % 60) + 60) % 60
        return ((normalized + granularity / 2) / granularity * granularity) % 60
    }

    private static func isRollingBulletinInterval(_ interval: TimeInterval) -> Bool {
        (25 * 60)...(40 * 60) ~= interval || (50 * 60)...(70 * 60) ~= interval
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func isBusinessWeekday(_ weekday: Int) -> Bool {
        (2...6).contains(weekday)
    }

    private static func learningConfidence(_ reliableDateCount: Int) -> Double {
        min(0.45, Double(reliableDateCount) / Double(minimumReliableDates) * 0.45)
    }
}

// MARK: - Feed refresh scheduling

public enum FeedRefreshWindowState: String, CaseIterable, Codable, Sendable, Hashable {
    case learning
    case unreliableDates
    case randomSurveillance
    case quiet
    case preWindow
    case activeWindow
    case missedRelease
    case fallback
}

public struct FeedRefreshPrediction: Equatable, Codable, Sendable {
    public var nextDueAt: Date
    public var state: FeedRefreshWindowState
    public var profileKind: FeedScheduleKind
    public var expectedWindowStart: Date?
    public var expectedWindowEnd: Date?
    public var recheckInterval: TimeInterval?
    public var reason: String

    public init(
        nextDueAt: Date,
        state: FeedRefreshWindowState,
        profileKind: FeedScheduleKind,
        expectedWindowStart: Date? = nil,
        expectedWindowEnd: Date? = nil,
        recheckInterval: TimeInterval? = nil,
        reason: String
    ) {
        self.nextDueAt = nextDueAt
        self.state = state
        self.profileKind = profileKind
        self.expectedWindowStart = expectedWindowStart
        self.expectedWindowEnd = expectedWindowEnd
        self.recheckInterval = recheckInterval
        self.reason = reason
    }
}

public enum FeedRefreshScheduling {
    /// Bounds for the derived publish cadence.
    public static let minPublishInterval: TimeInterval = 15 * 60
    public static let maxPublishInterval: TimeInterval = 7 * 24 * 60 * 60
    /// Used when a feed has fewer than 3 dated episodes.
    public static let defaultPublishInterval: TimeInterval = 6 * 60 * 60
    /// Default fastest in-window recheck while expecting a drop. User-tunable via
    /// the Release Radar setting (conditional requests make even 1 min cheap).
    public static let defaultMinRecheckInterval: TimeInterval = 5 * 60
    /// Slowest cadence a dormant feed decays to.
    public static let maxRecheckInterval: TimeInterval = 24 * 60 * 60
    /// Fraction of the median interval at which checking starts ahead of the expected drop.
    public static let windowOpenFraction = 0.75
    /// Missed-release urgency is deliberately short-lived. After enough post-window
    /// 304/no-new checks, or once the missed window is old, the feed falls back to
    /// low-priority surveillance instead of dominating future capped cycles.
    public static let missedReleaseEmptyFetchLimit = 10
    public static let missedReleaseMaxUrgencyAge: TimeInterval = 8 * 60 * 60

    private struct RefreshSlot {
        var preWindowStart: Date
        var windowStart: Date
        var windowEnd: Date
    }

    /// Median gap between recent episode publish dates (newest ~10), clamped.
    /// Returns nil when there are too few dated episodes to derive a cadence.
    public static func knownPublishInterval(publishDates: [Date]) -> TimeInterval? {
        let sorted = publishDates.sorted(by: >).prefix(10)
        guard sorted.count >= 3 else { return nil }
        let gaps = zip(sorted, sorted.dropFirst()).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return nil }
        let sortedGaps = gaps.sorted()
        let median = sortedGaps[sortedGaps.count / 2]
        return min(max(median, minPublishInterval), maxPublishInterval)
    }

    public static func medianPublishInterval(publishDates: [Date]) -> TimeInterval {
        knownPublishInterval(publishDates: publishDates) ?? defaultPublishInterval
    }

    public static func nextDueAt(
        profile: FeedScheduleProfile,
        latestPublishedAt: Date?,
        publishDates: [Date],
        stats: RefreshStats,
        minRecheckInterval: TimeInterval = defaultMinRecheckInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        prediction(
            profile: profile,
            latestPublishedAt: latestPublishedAt,
            publishDates: publishDates,
            stats: stats,
            minRecheckInterval: minRecheckInterval,
            now: now,
            calendar: calendar
        ).nextDueAt
    }

    public static func prediction(
        profile: FeedScheduleProfile,
        latestPublishedAt: Date?,
        publishDates: [Date],
        stats: RefreshStats,
        minRecheckInterval: TimeInterval = defaultMinRecheckInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FeedRefreshPrediction {
        let baseRecheck = min(max(minRecheckInterval, 60), maxRecheckInterval)

        switch profile.kind {
        case .hourly:
            guard let minute = profile.typicalMinuteOfHour else {
                return fallbackPrediction(
                    profile: profile,
                    latestPublishedAt: latestPublishedAt,
                    publishDates: publishDates,
                    stats: stats,
                    minRecheckInterval: minRecheckInterval,
                    now: now
                )
            }
            return hourlyPrediction(
                profile: profile,
                targetMinute: minute,
                latestPublishedAt: latestPublishedAt,
                stats: stats,
                baseRecheck: baseRecheck,
                now: now,
                calendar: calendar
            )

        case .rollingBulletin:
            let targetMinutes = profile.typicalMinutesOfHour
                ?? profile.typicalMinuteOfHour.map { [$0] }
                ?? []
            guard !targetMinutes.isEmpty else {
                return fallbackPrediction(
                    profile: profile,
                    latestPublishedAt: latestPublishedAt,
                    publishDates: publishDates,
                    stats: stats,
                    minRecheckInterval: minRecheckInterval,
                    now: now
                )
            }
            return rollingBulletinPrediction(
                profile: profile,
                targetMinutes: targetMinutes,
                latestPublishedAt: latestPublishedAt,
                stats: stats,
                baseRecheck: baseRecheck,
                now: now,
                calendar: calendar
            )

        case .burst:
            guard let burstWindow = profile.burstWindow else {
                return fallbackPrediction(
                    profile: profile,
                    latestPublishedAt: latestPublishedAt,
                    publishDates: publishDates,
                    stats: stats,
                    minRecheckInterval: minRecheckInterval,
                    now: now
                )
            }
            return windowedPrediction(
                profile: profile,
                slots: dailySlots(
                    activeWeekdays: burstWindow.activeWeekdays,
                    windowStartMinute: burstWindow.startMinuteOfDay,
                    windowEndMinute: min(24 * 60 - 1, burstWindow.endMinuteOfDay + 30),
                    preWindowLead: 10 * 60,
                    now: now,
                    calendar: calendar
                ),
                latestPublishedAt: latestPublishedAt,
                stats: stats,
                baseRecheck: baseRecheck,
                missedRecheck: missedRecheckInterval,
                now: now,
                continueCheckingAfterPublishUntilWindowEnd: true,
                activeReason: "Burst release window is active; keep checking because more episodes may follow.",
                quietReason: "Burst window already produced an episode and has closed."
            )

        case .dailyWeekdays:
            guard let minute = profile.typicalMinuteOfDay else {
                return fallbackPrediction(
                    profile: profile,
                    latestPublishedAt: latestPublishedAt,
                    publishDates: publishDates,
                    stats: stats,
                    minRecheckInterval: minRecheckInterval,
                    now: now
                )
            }
            return windowedPrediction(
                profile: profile,
                slots: dailySlots(
                    activeWeekdays: profile.activeWeekdays,
                    windowStartMinute: max(0, minute - 10),
                    windowEndMinute: min(24 * 60 - 1, minute + 75),
                    preWindowLead: 20 * 60,
                    now: now,
                    calendar: calendar
                ),
                latestPublishedAt: latestPublishedAt,
                stats: stats,
                baseRecheck: baseRecheck,
                missedRecheck: missedRecheckInterval,
                now: now,
                continueCheckingAfterPublishUntilWindowEnd: false,
                activeReason: "Learned weekday release window is open.",
                quietReason: "Expected weekday episode appears to have arrived; wait for the next learned weekday window."
            )

        case .weekly:
            guard let minute = profile.typicalMinuteOfDay else {
                return fallbackPrediction(
                    profile: profile,
                    latestPublishedAt: latestPublishedAt,
                    publishDates: publishDates,
                    stats: stats,
                    minRecheckInterval: minRecheckInterval,
                    now: now
                )
            }
            return windowedPrediction(
                profile: profile,
                slots: dailySlots(
                    activeWeekdays: profile.activeWeekdays,
                    windowStartMinute: max(0, minute - 10),
                    windowEndMinute: min(24 * 60 - 1, minute + 120),
                    preWindowLead: 20 * 60,
                    now: now,
                    calendar: calendar
                ),
                latestPublishedAt: latestPublishedAt,
                stats: stats,
                baseRecheck: baseRecheck,
                missedRecheck: missedRecheckInterval,
                now: now,
                continueCheckingAfterPublishUntilWindowEnd: false,
                activeReason: "Learned weekly release window is open.",
                quietReason: "Expected weekly episode appears to have arrived; wait for the next learned weekly window."
            )

        case .multiSlot:
            guard let minute = profile.typicalMinuteOfDay else {
                return fallbackPrediction(
                    profile: profile,
                    latestPublishedAt: latestPublishedAt,
                    publishDates: publishDates,
                    stats: stats,
                    minRecheckInterval: minRecheckInterval,
                    now: now
                )
            }
            return windowedPrediction(
                profile: profile,
                slots: dailySlots(
                    activeWeekdays: profile.activeWeekdays,
                    windowStartMinute: max(0, minute - 5),
                    windowEndMinute: min(24 * 60 - 1, minute + 60),
                    preWindowLead: 10 * 60,
                    now: now,
                    calendar: calendar
                ),
                latestPublishedAt: latestPublishedAt,
                stats: stats,
                baseRecheck: baseRecheck,
                missedRecheck: missedRecheckInterval,
                now: now,
                continueCheckingAfterPublishUntilWindowEnd: false,
                activeReason: "Learned multi-slot release window is open.",
                quietReason: "Expected multi-slot episode appears to have arrived; wait for the next learned slot."
            )

        case .random:
            let interval = randomSurveillanceRecheckInterval(
                stats: stats,
                baseRecheck: baseRecheck,
                now: now
            )
            return regularPrediction(
                profile: profile,
                state: .randomSurveillance,
                stats: stats,
                recheckInterval: interval,
                now: now,
                reason: "Random feed: use low-frequency surveillance because no reliable quiet window is known."
            )

        case .learning:
            let interval = learningRecheckInterval(
                profile: profile,
                stats: stats,
                baseRecheck: baseRecheck
            )
            return regularPrediction(
                profile: profile,
                state: .learning,
                stats: stats,
                recheckInterval: interval,
                now: now,
                reason: "Learning feed: check frequently at first, then decay after repeated empty checks."
            )

        case .unreliableDates:
            let interval = unreliableDatesRecheckInterval(
                stats: stats,
                baseRecheck: baseRecheck,
                now: now
            )
            return regularPrediction(
                profile: profile,
                state: .unreliableDates,
                stats: stats,
                recheckInterval: interval,
                now: now,
                reason: "RSS dates are unreliable; use low-frequency first-seen surveillance."
            )
        }
    }

    /// The next moment this feed deserves a fetch. Anchored to the latest episode's
    /// `publishedAt` so feeds with fixed release times (e.g. 14 past the hour)
    /// phase-lock automatically.
    public static func nextDueAt(
        latestPublishedAt: Date?,
        publishDates: [Date],
        stats: RefreshStats,
        minRecheckInterval: TimeInterval = defaultMinRecheckInterval,
        now: Date = Date()
    ) -> Date {
        let baseRecheck = min(max(minRecheckInterval, 60), maxRecheckInterval)

        func decayedRecheck() -> TimeInterval {
            let decaySteps = min(Double(stats.consecutiveEmptyFetches) / 4.0, 8)
            return min(baseRecheck * pow(1.5, decaySteps), maxRecheckInterval)
        }

        guard let median = knownPublishInterval(publishDates: publishDates),
              let anchor = latestPublishedAt ?? stats.lastNewEpisodeAt
        else {
            // Cadence unknown — typically a feed exposing a single item at a time
            // (hourly news bulletins) or one never fetched. Poll at the Release Radar
            // cadence from the last fetch, decaying while nothing new appears, so an
            // hourly feed self-tunes to hourly instead of stalling on a 6 h default.
            guard let lastFetch = stats.lastFetchedAt else { return now }
            return lastFetch.addingTimeInterval(decayedRecheck())
        }

        let windowOpens = anchor.addingTimeInterval(median * windowOpenFraction)
        if now < windowOpens {
            return windowOpens
        }

        // Inside (or past) the expected drop window: recheck at the user-set
        // Release Radar cadence, decaying once the feed looks late or dormant
        // (no new episode for >2 medians).
        var recheck = baseRecheck
        let lateness = now.timeIntervalSince(anchor.addingTimeInterval(median * 2))
        if lateness > 0 {
            recheck = decayedRecheck()
        }
        guard let lastFetch = stats.lastFetchedAt else { return now }
        return lastFetch.addingTimeInterval(recheck)
    }

    private static func hourlyPrediction(
        profile: FeedScheduleProfile,
        targetMinute: Int,
        latestPublishedAt: Date?,
        stats: RefreshStats,
        baseRecheck: TimeInterval,
        now: Date,
        calendar: Calendar
    ) -> FeedRefreshPrediction {
        guard let hourStart = calendar.dateInterval(of: .hour, for: now)?.start else {
            return regularPrediction(
                profile: profile,
                state: .fallback,
                stats: stats,
                recheckInterval: baseRecheck,
                now: now,
                reason: "Could not resolve the current hour; using regular checks."
            )
        }
        let clampedMinute = max(0, min(59, targetMinute))
        let slots = (-2...3).compactMap { offset -> RefreshSlot? in
            guard let targetHour = calendar.date(byAdding: .hour, value: offset, to: hourStart) else { return nil }
            let target = targetHour.addingTimeInterval(TimeInterval(clampedMinute * 60))
            return RefreshSlot(
                preWindowStart: target.addingTimeInterval(-3 * 60),
                windowStart: target.addingTimeInterval(-2 * 60),
                windowEnd: target.addingTimeInterval(15 * 60)
            )
        }
        return windowedPrediction(
            profile: profile,
            slots: slots,
            latestPublishedAt: latestPublishedAt,
            stats: stats,
            baseRecheck: min(baseRecheck, 5 * 60),
            missedRecheck: { _, base in min(base, 10 * 60) },
            now: now,
            continueCheckingAfterPublishUntilWindowEnd: false,
            activeReason: "Learned hourly release minute is near.",
            quietReason: "Expected hourly episode appears to have arrived; wait for the next hour."
        )
    }

    private static func rollingBulletinPrediction(
        profile: FeedScheduleProfile,
        targetMinutes: [Int],
        latestPublishedAt: Date?,
        stats: RefreshStats,
        baseRecheck: TimeInterval,
        now: Date,
        calendar: Calendar
    ) -> FeedRefreshPrediction {
        guard let hourStart = calendar.dateInterval(of: .hour, for: now)?.start else {
            return regularPrediction(
                profile: profile,
                state: .fallback,
                stats: stats,
                recheckInterval: baseRecheck,
                now: now,
                reason: "Could not resolve the current hour; using regular checks."
            )
        }
        let clampedMinutes = Array(Set(targetMinutes.map { max(0, min(59, $0)) })).sorted()
        guard !clampedMinutes.isEmpty else {
            return regularPrediction(
                profile: profile,
                state: .fallback,
                stats: stats,
                recheckInterval: baseRecheck,
                now: now,
                reason: "Rolling bulletin profile has no minute slots; using regular checks."
            )
        }

        let slots = (-2...3).flatMap { offset -> [RefreshSlot] in
            guard let targetHour = calendar.date(byAdding: .hour, value: offset, to: hourStart) else { return [] }
            return clampedMinutes.map { minute in
                let target = targetHour.addingTimeInterval(TimeInterval(minute * 60))
                return RefreshSlot(
                    preWindowStart: target.addingTimeInterval(-3 * 60),
                    windowStart: target.addingTimeInterval(-2 * 60),
                    windowEnd: target.addingTimeInterval(15 * 60)
                )
            }
        }
        return windowedPrediction(
            profile: profile,
            slots: slots,
            latestPublishedAt: latestPublishedAt,
            stats: stats,
            baseRecheck: min(baseRecheck, 5 * 60),
            missedRecheck: { _, base in min(base, 10 * 60) },
            now: now,
            continueCheckingAfterPublishUntilWindowEnd: false,
            activeReason: "Rolling bulletin release minute is near.",
            quietReason: "Expected rolling bulletin appears to have arrived; wait for the next bulletin slot."
        )
    }

    private static func windowedPrediction(
        profile: FeedScheduleProfile,
        slots: [RefreshSlot],
        latestPublishedAt: Date?,
        stats: RefreshStats,
        baseRecheck: TimeInterval,
        missedRecheck: (TimeInterval, TimeInterval) -> TimeInterval,
        now: Date,
        continueCheckingAfterPublishUntilWindowEnd: Bool,
        activeReason: String,
        quietReason: String
    ) -> FeedRefreshPrediction {
        let orderedSlots = slots.sorted { $0.preWindowStart < $1.preWindowStart }
        guard !orderedSlots.isEmpty else {
            return regularPrediction(
                profile: profile,
                state: .fallback,
                stats: stats,
                recheckInterval: baseRecheck,
                now: now,
                reason: "No schedule windows could be generated; using regular checks."
            )
        }

        let nextSlot = orderedSlots.first { $0.preWindowStart > now }
        let currentSlot = orderedSlots.last { $0.preWindowStart <= now }

        guard let slot = currentSlot else {
            let nextDue = nextSlot?.preWindowStart ?? now.addingTimeInterval(baseRecheck)
            return FeedRefreshPrediction(
                nextDueAt: nextDue,
                state: .quiet,
                profileKind: profile.kind,
                expectedWindowStart: nextSlot?.windowStart,
                expectedWindowEnd: nextSlot?.windowEnd,
                reason: "Outside the learned release window; wait for the next pre-window check."
            )
        }

        let publishedInSlot = latestPublishedAt.map { $0 >= slot.windowStart } ?? false
        if publishedInSlot, !continueCheckingAfterPublishUntilWindowEnd {
            let nextDue = nextSlot?.preWindowStart ?? slot.windowEnd.addingTimeInterval(baseRecheck)
            return FeedRefreshPrediction(
                nextDueAt: nextDue,
                state: .quiet,
                profileKind: profile.kind,
                expectedWindowStart: nextSlot?.windowStart,
                expectedWindowEnd: nextSlot?.windowEnd,
                reason: quietReason
            )
        }

        if now < slot.windowStart {
            return FeedRefreshPrediction(
                nextDueAt: dueFromLastFetch(stats.lastFetchedAt, interval: baseRecheck, now: now),
                state: .preWindow,
                profileKind: profile.kind,
                expectedWindowStart: slot.windowStart,
                expectedWindowEnd: slot.windowEnd,
                recheckInterval: baseRecheck,
                reason: "Pre-window is open; start checking shortly before the learned release time."
            )
        }

        if now <= slot.windowEnd {
            return FeedRefreshPrediction(
                nextDueAt: dueFromLastFetch(stats.lastFetchedAt, interval: baseRecheck, now: now),
                state: .activeWindow,
                profileKind: profile.kind,
                expectedWindowStart: slot.windowStart,
                expectedWindowEnd: slot.windowEnd,
                recheckInterval: baseRecheck,
                reason: activeReason
            )
        }

        if publishedInSlot {
            let nextDue = nextSlot?.preWindowStart ?? now.addingTimeInterval(baseRecheck)
            return FeedRefreshPrediction(
                nextDueAt: nextDue,
                state: .quiet,
                profileKind: profile.kind,
                expectedWindowStart: nextSlot?.windowStart,
                expectedWindowEnd: nextSlot?.windowEnd,
                reason: quietReason
            )
        }

        let lateBy = now.timeIntervalSince(slot.windowEnd)
        if missedReleaseUrgencyExpired(lateBy: lateBy, stats: stats, slot: slot) {
            let interval = expiredMissedReleaseRecheckInterval(baseRecheck: baseRecheck)
            let fallbackDue = dueFromLastFetch(stats.lastFetchedAt, interval: interval, now: now)
            let nextWindowDue = nextSlot?.preWindowStart
            let nextDue = [fallbackDue, nextWindowDue].compactMap { $0 }.min() ?? fallbackDue
            return FeedRefreshPrediction(
                nextDueAt: nextDue,
                state: .fallback,
                profileKind: profile.kind,
                expectedWindowStart: slot.windowStart,
                expectedWindowEnd: slot.windowEnd,
                recheckInterval: interval,
                reason: "Missed-release urgency expired after repeated empty checks or window age; use low-priority surveillance until the next learned window."
            )
        }

        let interval = missedRecheck(lateBy, baseRecheck)
        return FeedRefreshPrediction(
            nextDueAt: dueFromLastFetch(stats.lastFetchedAt, interval: interval, now: now),
            state: .missedRelease,
            profileKind: profile.kind,
            expectedWindowStart: slot.windowStart,
            expectedWindowEnd: slot.windowEnd,
            recheckInterval: interval,
            reason: "Expected release window passed without a matching episode; keep checking on the missed-release cadence."
        )
    }

    private static func dailySlots(
        activeWeekdays: [Int],
        windowStartMinute: Int,
        windowEndMinute: Int,
        preWindowLead: TimeInterval,
        now: Date,
        calendar: Calendar
    ) -> [RefreshSlot] {
        let activeSet = Set(activeWeekdays)
        guard let todayStart = calendar.dateInterval(of: .day, for: now)?.start else { return [] }
        let clampedStart = max(0, min(24 * 60 - 1, windowStartMinute))
        let clampedEnd = max(clampedStart, min(24 * 60 - 1, windowEndMinute))

        return (-14...21).compactMap { dayOffset -> RefreshSlot? in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: todayStart) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            guard activeSet.isEmpty || activeSet.contains(weekday) else { return nil }
            let windowStart = day.addingTimeInterval(TimeInterval(clampedStart * 60))
            let windowEnd = day.addingTimeInterval(TimeInterval(clampedEnd * 60))
            return RefreshSlot(
                preWindowStart: windowStart.addingTimeInterval(-preWindowLead),
                windowStart: windowStart,
                windowEnd: windowEnd
            )
        }
    }

    private static func regularPrediction(
        profile: FeedScheduleProfile,
        state: FeedRefreshWindowState,
        stats: RefreshStats,
        recheckInterval: TimeInterval,
        now: Date,
        reason: String
    ) -> FeedRefreshPrediction {
        FeedRefreshPrediction(
            nextDueAt: dueFromLastFetch(stats.lastFetchedAt, interval: recheckInterval, now: now),
            state: state,
            profileKind: profile.kind,
            recheckInterval: recheckInterval,
            reason: reason
        )
    }

    private static func fallbackPrediction(
        profile: FeedScheduleProfile,
        latestPublishedAt: Date?,
        publishDates: [Date],
        stats: RefreshStats,
        minRecheckInterval: TimeInterval,
        now: Date
    ) -> FeedRefreshPrediction {
        FeedRefreshPrediction(
            nextDueAt: nextDueAt(
                latestPublishedAt: latestPublishedAt,
                publishDates: publishDates,
                stats: stats,
                minRecheckInterval: minRecheckInterval,
                now: now
            ),
            state: .fallback,
            profileKind: profile.kind,
            reason: "Profile is incomplete for prediction; using legacy cadence fallback."
        )
    }

    private static func dueFromLastFetch(_ lastFetchedAt: Date?, interval: TimeInterval, now: Date) -> Date {
        guard let lastFetchedAt else { return now }
        return lastFetchedAt.addingTimeInterval(interval)
    }

    private static func missedReleaseUrgencyExpired(
        lateBy: TimeInterval,
        stats: RefreshStats,
        slot: RefreshSlot
    ) -> Bool {
        if lateBy >= missedReleaseMaxUrgencyAge {
            return true
        }

        guard stats.consecutiveEmptyFetches >= missedReleaseEmptyFetchLimit,
              let lastFetchedAt = stats.lastFetchedAt,
              lastFetchedAt >= slot.windowEnd
        else {
            return false
        }
        return true
    }

    private static func expiredMissedReleaseRecheckInterval(baseRecheck: TimeInterval) -> TimeInterval {
        min(max(baseRecheck * 12, 60 * 60), 6 * 60 * 60)
    }

    private static func learningRecheckInterval(
        profile: FeedScheduleProfile,
        stats: RefreshStats,
        baseRecheck: TimeInterval
    ) -> TimeInterval {
        guard stats.lastFetchedAt != nil else { return baseRecheck }
        let emptyFetches = max(0, stats.consecutiveEmptyFetches)
        guard emptyFetches > 3 else { return baseRecheck }

        let decayStep = min(5, (emptyFetches - 1) / 3)
        let decayed = baseRecheck * pow(2, Double(decayStep))
        let cap: TimeInterval = profile.observationCount == 0 ? 30 * 60 : 60 * 60
        return min(max(baseRecheck, decayed), cap)
    }

    private static func randomSurveillanceRecheckInterval(
        stats: RefreshStats,
        baseRecheck: TimeInterval,
        now: Date
    ) -> TimeInterval {
        var interval = surveillanceBaselineInterval(
            stats: stats,
            baseRecheck: baseRecheck
        )

        if let lastNewEpisodeAt = stats.lastNewEpisodeAt {
            let age = max(0, now.timeIntervalSince(lastNewEpisodeAt))
            if age <= 2 * 60 * 60 {
                interval = min(interval, max(baseRecheck, 5 * 60))
            } else if age <= 6 * 60 * 60 {
                interval = min(interval, max(baseRecheck, 10 * 60))
            }
        }

        return interval
    }

    private static func unreliableDatesRecheckInterval(
        stats: RefreshStats,
        baseRecheck: TimeInterval,
        now: Date
    ) -> TimeInterval {
        randomSurveillanceRecheckInterval(
            stats: stats,
            baseRecheck: baseRecheck,
            now: now
        )
    }

    private static func surveillanceBaselineInterval(
        stats: RefreshStats,
        baseRecheck: TimeInterval
    ) -> TimeInterval {
        var interval = min(max(baseRecheck, 15 * 60), 60 * 60)
        let emptyFetches = max(0, stats.consecutiveEmptyFetches)
        if emptyFetches >= 24 {
            interval = max(interval, 60 * 60)
        } else if emptyFetches >= 12 {
            interval = max(interval, 30 * 60)
        }
        return interval
    }

    private static func missedRecheckInterval(lateBy: TimeInterval, baseRecheck: TimeInterval) -> TimeInterval {
        if lateBy <= 2 * 60 * 60 {
            return baseRecheck
        }
        if lateBy <= 12 * 60 * 60 {
            return min(max(baseRecheck * 2, 10 * 60), 30 * 60)
        }
        return min(max(baseRecheck * 4, 30 * 60), 2 * 60 * 60)
    }
}

// MARK: - Feed refresh prioritization

public struct FeedRefreshPriority: Equatable, Codable, Sendable {
    public var score: Double
    public var reason: String
    public var factors: [String]

    public init(score: Double, reason: String, factors: [String]) {
        self.score = score
        self.reason = reason
        self.factors = factors
    }
}

// MARK: - Feed refresh budgeting

public struct FeedRefreshBudgetPolicy: Equatable, Sendable {
    /// Nil, zero, or a negative value means "unlimited" for compatibility with
    /// the existing manual/foreground refresh paths.
    public var maxSelections: Int?
    /// States that should be selected even after the normal budget is full. These
    /// candidates do not consume budget slots.
    public var capBypassStates: Set<FeedRefreshWindowState>
    /// States that should get the first protected slots when a budget is tight.
    /// This is intentionally separate from capBypassStates: protected candidates
    /// still consume budget, but they are tried before ordinary backlog work.
    public var protectedStates: Set<FeedRefreshWindowState>
    public var minimumProtectedSelections: Int

    public init(
        maxSelections: Int?,
        capBypassStates: Set<FeedRefreshWindowState> = [],
        protectedStates: Set<FeedRefreshWindowState> = [],
        minimumProtectedSelections: Int = 0
    ) {
        self.maxSelections = maxSelections
        self.capBypassStates = capBypassStates
        self.protectedStates = protectedStates
        self.minimumProtectedSelections = minimumProtectedSelections
    }
}

public struct FeedRefreshBudgetSelection<Candidate> {
    public var selected: [Candidate]
    public var deferred: [Candidate]

    public var cappedOutCount: Int { deferred.count }

    public init(selected: [Candidate], deferred: [Candidate]) {
        self.selected = selected
        self.deferred = deferred
    }
}

public enum FeedRefreshBudgeting {
    /// Applies a refresh budget to an already-prioritized candidate list.
    /// Protected states get a first pass so release-window feeds are attempted
    /// before ordinary backlog work during short BGAppRefresh wakes. Bypass
    /// states remain selected even when the normal cap has been filled.
    public static func select<Candidate>(
        candidates: [Candidate],
        policy: FeedRefreshBudgetPolicy,
        state: (Candidate) -> FeedRefreshWindowState
    ) -> FeedRefreshBudgetSelection<Candidate> {
        guard let maxSelections = policy.maxSelections, maxSelections > 0 else {
            return FeedRefreshBudgetSelection(selected: candidates, deferred: [])
        }

        if !policy.protectedStates.isEmpty, policy.minimumProtectedSelections > 0 {
            return selectWithProtectedStates(
                candidates: candidates,
                maxSelections: maxSelections,
                policy: policy,
                state: state
            )
        }

        var remainingBudget = maxSelections
        var selected: [Candidate] = []
        var deferred: [Candidate] = []
        selected.reserveCapacity(min(candidates.count, maxSelections))

        for candidate in candidates {
            if policy.capBypassStates.contains(state(candidate)) {
                selected.append(candidate)
            } else if remainingBudget > 0 {
                selected.append(candidate)
                remainingBudget -= 1
            } else {
                deferred.append(candidate)
            }
        }

        return FeedRefreshBudgetSelection(selected: selected, deferred: deferred)
    }

    private static func selectWithProtectedStates<Candidate>(
        candidates: [Candidate],
        maxSelections: Int,
        policy: FeedRefreshBudgetPolicy,
        state: (Candidate) -> FeedRefreshWindowState
    ) -> FeedRefreshBudgetSelection<Candidate> {
        let indexedCandidates = Array(candidates.enumerated())
        let protectedLimit = min(
            maxSelections,
            max(0, policy.minimumProtectedSelections)
        )
        let protectedIndices = indexedCandidates
            .filter { policy.protectedStates.contains(state($0.element)) }
            .prefix(protectedLimit)
            .map { $0.offset }
        let protectedIndexSet = Set(protectedIndices)

        var remainingBudget = maxSelections - protectedIndices.count
        var selectedIndices = protectedIndices

        for (index, candidate) in indexedCandidates where !protectedIndexSet.contains(index) {
            let candidateState = state(candidate)
            if policy.capBypassStates.contains(candidateState) {
                selectedIndices.append(index)
            } else if remainingBudget > 0 {
                selectedIndices.append(index)
                remainingBudget -= 1
            }
        }

        let selectedIndexSet = Set(selectedIndices)
        return FeedRefreshBudgetSelection(
            selected: selectedIndices.map { candidates[$0] },
            deferred: indexedCandidates
                .filter { !selectedIndexSet.contains($0.offset) }
                .map { $0.element }
        )
    }
}

public enum FeedRefreshPrioritizer {
    public static func priority(
        prediction: FeedRefreshPrediction,
        profile: FeedScheduleProfile,
        priorityRank: Int,
        lastFetchedAt: Date?,
        now: Date = Date()
    ) -> FeedRefreshPriority {
        var score = baseScore(for: prediction.state)
        var factors = [factorLabel(for: prediction.state)]

        let releaseWindowState = isReleaseWindowState(prediction.state)
        let kindBoost = profileKindBoost(profile.kind, releaseWindowState: releaseWindowState)
        if kindBoost > 0 {
            score += kindBoost
            factors.append("\(profile.kind.rawValue) profile")
        }

        let confidenceWeight = releaseWindowState ? 14.0 : 8.0
        let confidenceBoost = min(max(profile.confidence, 0), 1) * confidenceWeight
        if confidenceBoost >= 1 {
            score += confidenceBoost
            factors.append("confidence \(Int((profile.confidence * 100).rounded()))%")
        }

        let normalizedRank = max(priorityRank, 1)
        let rankBoost = max(0, 18.0 - Double(normalizedRank - 1) * 2.0)
        if rankBoost > 0 {
            score += rankBoost
            factors.append("priority rank \(normalizedRank)")
        }

        if let lastFetchedAt {
            let hoursSinceFetch = max(0, now.timeIntervalSince(lastFetchedAt) / 3600)
            let stalenessBoost = min(18, hoursSinceFetch / 2)
            if stalenessBoost >= 1 {
                score += stalenessBoost
                factors.append("stale for \(Int(hoursSinceFetch.rounded()))h")
            }
        } else {
            score += 12
            factors.append("never fetched")
        }

        let overdueMinutes = max(0, now.timeIntervalSince(prediction.nextDueAt) / 60)
        let overdueBoost = min(25, overdueMinutes / 5)
        if overdueBoost >= 1 {
            score += overdueBoost
            factors.append("overdue by \(Int(overdueMinutes.rounded()))m")
        }

        let roundedScore = (score * 10).rounded() / 10
        return FeedRefreshPriority(
            score: roundedScore,
            reason: factors.joined(separator: ", "),
            factors: factors
        )
    }

    private static func baseScore(for state: FeedRefreshWindowState) -> Double {
        switch state {
        case .missedRelease:
            return 110
        case .activeWindow:
            return 90
        case .preWindow:
            return 70
        case .learning:
            return 55
        case .randomSurveillance:
            return 50
        case .unreliableDates:
            return 45
        case .fallback:
            return 35
        case .quiet:
            return 0
        }
    }

    private static func factorLabel(for state: FeedRefreshWindowState) -> String {
        switch state {
        case .missedRelease:
            return "missed expected release"
        case .activeWindow:
            return "active release window"
        case .preWindow:
            return "pre-release window"
        case .learning:
            return "learning schedule"
        case .randomSurveillance:
            return "random schedule surveillance"
        case .unreliableDates:
            return "unreliable RSS dates"
        case .fallback:
            return "fallback cadence"
        case .quiet:
            return "quiet window"
        }
    }

    private static func isReleaseWindowState(_ state: FeedRefreshWindowState) -> Bool {
        switch state {
        case .preWindow, .activeWindow, .missedRelease:
            return true
        case .learning, .unreliableDates, .randomSurveillance, .quiet, .fallback:
            return false
        }
    }

    private static func profileKindBoost(
        _ kind: FeedScheduleKind,
        releaseWindowState: Bool
    ) -> Double {
        switch kind {
        case .hourly:
            return releaseWindowState ? 16 : 0
        case .rollingBulletin:
            return releaseWindowState ? 18 : 0
        case .burst:
            return releaseWindowState ? 14 : 0
        case .dailyWeekdays:
            return releaseWindowState ? 22 : 0
        case .weekly, .multiSlot:
            return releaseWindowState ? 8 : 0
        case .learning:
            return 8
        case .random:
            return 6
        case .unreliableDates:
            return 0
        }
    }
}

// MARK: - Subscription

public struct Subscription: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var feedURL: URL
    public var title: String
    public var description: String?
    public var author: String?
    public var artworkURL: URL?
    public var priorityRank: Int
    public var playbackPreference: PlaybackPreference
    public var chapterFilter: ChapterFilter
    public var latestEpisode: Episode?
    public var episodes: [Episode]
    public var playedEpisodeKeys: Set<String>
    public var archivedEpisodeKeys: Set<String>
    public var notificationsEnabled: Bool
    public var autoArchiveSettings: AutoArchiveSettings
    public var excludeFromAutoFeedRefresh: Bool
    /// Previous active Priority Stack rank captured when the user marks this
    /// real subscription Inactive. Nil for active shows and browse previews.
    public var autoFeedRefreshReturnPriorityRank: Int?
    public var categories: [String]
    public var isExplicit: Bool?
    /// Non-nil when this subscription was auto-created by opening a search preview.
    /// Used for 30-day browse history retention and cleanup.
    public var browseDate: Date?
    /// When the user actually subscribed. Episodes published on/before this date are
    /// the pre-existing back-catalogue the user never had a chance to engage with —
    /// auto-archive leaves them browsable (unplayed) instead of archiving the whole
    /// backlog the moment you subscribe. Nil for legacy subscriptions (decoded
    /// before this field existed) → no backlog protection, old behaviour preserved.
    public var subscribedAt: Date?
    public var refreshStats: RefreshStats

    public init(
        id: UUID = UUID(),
        feedURL: URL,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        priorityRank: Int,
        playbackPreference: PlaybackPreference = .default,
        chapterFilter: ChapterFilter = ChapterFilter(),
        notificationsEnabled: Bool = false,
        autoArchiveSettings: AutoArchiveSettings = .default,
        excludeFromAutoFeedRefresh: Bool = false,
        categories: [String] = [],
        isExplicit: Bool? = nil
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.priorityRank = priorityRank
        self.playbackPreference = playbackPreference
        self.chapterFilter = chapterFilter
        self.latestEpisode = nil
        self.episodes = []
        self.playedEpisodeKeys = []
        self.archivedEpisodeKeys = []
        self.notificationsEnabled = notificationsEnabled
        self.autoArchiveSettings = autoArchiveSettings
        self.excludeFromAutoFeedRefresh = excludeFromAutoFeedRefresh
        self.autoFeedRefreshReturnPriorityRank = nil
        self.categories = categories
        self.isExplicit = isExplicit
        self.browseDate = nil
        self.subscribedAt = nil
        self.refreshStats = RefreshStats()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case feedURL
        case title
        case description
        case author
        case artworkURL
        case priorityRank
        case playbackPreference
        case chapterFilter
        case latestEpisode
        case episodes
        case playedEpisodeKeys
        case archivedEpisodeKeys
        case notificationsEnabled
        case autoArchiveSettings
        case excludeFromAutoFeedRefresh
        case autoFeedRefreshReturnPriorityRank
        case categories
        case isExplicit
        case browseDate
        case subscribedAt
        case refreshStats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        feedURL = try container.decode(URL.self, forKey: .feedURL)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        priorityRank = try container.decode(Int.self, forKey: .priorityRank)
        playbackPreference = try container.decodeIfPresent(PlaybackPreference.self, forKey: .playbackPreference) ?? .default
        chapterFilter = try container.decodeIfPresent(ChapterFilter.self, forKey: .chapterFilter) ?? ChapterFilter()
        latestEpisode = try container.decodeIfPresent(Episode.self, forKey: .latestEpisode)
        episodes = try container.decodeIfPresent([Episode].self, forKey: .episodes) ?? latestEpisode.map { [$0] } ?? []
        playedEpisodeKeys = try container.decodeIfPresent(Set<String>.self, forKey: .playedEpisodeKeys) ?? []
        archivedEpisodeKeys = try container.decodeIfPresent(Set<String>.self, forKey: .archivedEpisodeKeys) ?? []
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        excludeFromAutoFeedRefresh = try container.decodeIfPresent(Bool.self, forKey: .excludeFromAutoFeedRefresh) ?? false
        autoFeedRefreshReturnPriorityRank = try container.decodeIfPresent(Int.self, forKey: .autoFeedRefreshReturnPriorityRank)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit)
        browseDate = try container.decodeIfPresent(Date.self, forKey: .browseDate)
        subscribedAt = try container.decodeIfPresent(Date.self, forKey: .subscribedAt)
        refreshStats = try container.decodeIfPresent(RefreshStats.self, forKey: .refreshStats) ?? RefreshStats()

        autoArchiveSettings = try container.decodeIfPresent(AutoArchiveSettings.self, forKey: .autoArchiveSettings) ?? .default
    }
}
