import Foundation

// AI CONTEXT — Models/Subscription.swift
// Value types and pure refresh intelligence for one subscribed podcast and its
// per-podcast policies. All persisted by SubscriptionStore except transient
// scheduling/priority predictions. Contains:
//  - AutoArchiveSettings: three independent rules (AfterPlayed delay,
//    AfterInactive timeout, EpisodeLimit keep-N). Per-podcast AfterInactive
//    includes a 30-minute bulletin option; the global-new-subscription picker
//    deliberately omits that specialist value. Defaults remain afterPlaying /
//    1 week / keep 1. The same backward-compatible payload carries the opt-in
//    per-podcast Play Instant automation flag. Archive rules are enforced by
//    AppState.runAutoArchive every ≤30 min.
//  - DownloadFilterSettings: local/backup-only per-subscription auto-download
//    filters. Duration/title/description groups can be toggled independently;
//    include/exclude rules combine via All/Any, exclude wins, simple text
//    matching is case-insensitive, and missing duration fails active duration
//    rules. Used only for automatic download eligibility — manual episode
//    actions still bypass it.
//  - ChapterFilter: set of DISABLED chapter position indices; position-based
//    so a disabled slot skips that chapter in every future episode.
//  - RefreshStats: Release Radar state — ETag/Last-Modified for HTTP
//    conditional GETs, last fetch/new-episode timing, legacy recentPublishDates,
//    and capped releaseObservations. releaseObservations persist each episode's
//    GUID/title/audio URL, RSS publishedAt, first/last seen time, date quality,
//    duration/description filter metadata, and whether it was new when first
//    observed; AppState/SubscriptionStore keep this updated so one-item feeds can
//    still accumulate schedule history. Download Filters are applied before
//    observations feed Release Radar schedules, so skipped episodes do not train
//    future refresh windows.
//  - FeedScheduleProfiler: classifies observations into learning, unreliable
//    dates, hourly, rolling-bulletin, burst ("Daily – Multiple Episodes" — multiple
//    episodes/day on MOST days; ≤2 active weekdays falls through to weekly; its window
//    covers the RECENT episodes' outlier-trimmed range so late-running days aren't
//    missed), daily/weekday, weekly, several-times-a-week (multiSlot), or random profiles.
//    Hourly/rolling-bulletin/burst are detected first. Everything else goes through
//    Release Radar v2
//    (regularCadenceProfile): a feed is classified on its CADENCE + ACTIVE-DAY
//    pattern only — publish TIME never gates classification, it only sizes the
//    window. It computes a RECENCY-WEIGHTED per-weekday publish probability (weeks
//    weighted by weekdayRecencyHalfLifeWeeks, so a stale/biased capture or a schedule
//    change is corrected by current behaviour, not diluted across the full span; see
//    weekdayPublishProbabilities) and the active set is the days above
//    `activeDayThreshold`. Shape → kind: 1 active day + weekly gap → .weekly; 2–4 days
//    → .multiSlot; 5+ days → .dailyWeekdays (the kind is shared by Mon–Fri and 7-day
//    feeds — FeedScheduleProfile.categoryLabel reads the active set to print "Weekdays"
//    vs "Daily"). FALLBACK: if no day clears the active bar but one weekday holds
//    ≥`weeklyDominantShareThreshold` of all episodes on a ~weekly cadence, it's .weekly
//    by episode share (so a weekly show that skips the odd week still classifies).
//    SECOND FALLBACK (recent-daily rescue): the MEDIAN GAP and a PRESENCE-based recent
//    active-weekday set are measured over only the last `cadenceRecencyWindowSize`
//    observations (not all history); if a feed has published on 5+ distinct weekdays at
//    a ≤2-day gap within that window it's .dailyWeekdays even before any weekday's
//    per-week probability clears the active bar. This self-heals feeds whose old
//    episodes are purged from the RSS, leaving a stale single-weekday seed (e.g. The
//    Daily → Sunday-only retention) that would otherwise be misread as .weekly.
//    activeWeekdays drives scheduling, so a Mon–Fri feed never opens weekend slots.
//    Every classified feed carries a
//    releaseWindow sized (Stage 2) to the DENSEST publish-time mode, recency-weighted
//    (recencyHalfLifeWeeks), but now widened when the full observed publish spread is
//    genuinely messy. This preserves tight hourly/rolling bulletin behaviour while
//    stopping ordinary daily/weekly feeds from being trapped in over-narrow windows;
//    a low-priority safety sweep catches out-of-window releases once/twice per day.
//    Window times are DST-stable (dstStableMinutes): a UTC-stamped feed doesn't drift
//    ±1h across daylight-saving boundaries. No clear day+cadence ⇒ random.
//    weekdayProbabilities feeds Stage-2 watch tiers.
//  - FeedRefreshScheduling: converts a schedule profile plus fetch stats into a
//    FeedRefreshPrediction. Learned feeds open pre-release windows, check in high
//    rotation during active/fresh-missed windows, expire stale missed-release
//    urgency after repeated empty checks or window age, stand down during quiet
//    periods, and fall back to the legacy cadence model when the profile is
//    incomplete. Daily weekday feeds deliberately start checking about 30 min
//    before the learned release time; missed-release urgency expires after 10
//    post-window empty checks or 8 hours so a late show does not dominate forever.
//    Weekly feeds use the profile's learned releaseWindow (densest-mode, adaptively
//    widened for messy real-world feeds) and close the window the moment that week's
//    episode lands, then fall back to low-priority safety sweeps until next week.
//    Stage-2 watch tiers (releaseSlots): high-probability weekdays get the full window
//    on high rotation; medium-probability days (lightTier..fullTier) get lighter slots
//    (longer recheck, no pre-window, no missed-release escalation); low days are
//    skipped — so an occasional-Saturday show still gets a light Saturday check while a
//    strict Mon–Fri show spends nothing on the weekend.
//  - FeedRefreshPrioritizer: scores already-due feeds so AppState's timed and
//    background cycles spend limited refresh slots on missed releases, active
//    windows, high-confidence hourly/rolling-bulletin/burst/daily feeds (daily
//    gets the strongest release-window kind boost), learning/random feeds, user
//    priority rank, stale feeds, and overdue feeds before ordinary due work.
//  - FeedRefreshBudgeting: pure budget selector used by AppState to cap due-feed
//    cycles while letting active/pre-window states bypass the foreground cap and
//    protecting Release Radar states in tight background budgets.
//  - Subscription: priorityRank (1 = top of Priority Stack, drives queue
//    order), episodes array, playbackPreference, downloadFilterSettings,
//    notificationsEnabled (default false), excludeFromAutoFeedRefresh,
//    remembered return rank for inactive shows, and browseDate — non-nil marks
//    an invisible "browse subscription" auto-created when the user previews a
//    podcast in search (deleted after 30 days if untouched).

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
        case minutes30
        case hours4
        case hours6
        case hours8
        case hours12
        case hours16
        case hours24
        case days2
        case days3
        case days4
        case days5
        case days7
        case days14
        case days30
        case days90

        public var title: String {
            switch self {
            case .never:   return "Never"
            case .minutes30: return "30 Minutes"
            case .hours4:  return "4 Hours"
            case .hours6:  return "6 Hours"
            case .hours8:  return "8 Hours"
            case .hours12: return "12 Hours"
            case .hours16: return "16 Hours"
            case .hours24: return "24 Hours"
            case .days2:   return "2 Days"
            case .days3:   return "3 Days"
            case .days4:   return "4 Days"
            case .days5:   return "5 Days"
            case .days7:   return "1 Week"
            case .days14:  return "2 Weeks"
            case .days30:  return "30 Days"
            case .days90:  return "90 Days"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .never:   return nil
            case .minutes30: return 30 * 60
            case .hours4:  return 4 * 3600
            case .hours6:  return 6 * 3600
            case .hours8:  return 8 * 3600
            case .hours12: return 12 * 3600
            case .hours16: return 16 * 3600
            case .hours24: return 24 * 3600
            case .days2:   return 2 * 24 * 3600
            case .days3:   return 3 * 24 * 3600
            case .days4:   return 4 * 24 * 3600
            case .days5:   return 5 * 24 * 3600
            case .days7:   return 7 * 24 * 3600
            case .days14:  return 14 * 24 * 3600
            case .days30:  return 30 * 24 * 3600
            case .days90:  return 90 * 24 * 3600
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            // Version 1.4 originally shipped this specialist per-podcast option
            // as 40 minutes. Migrate an existing selection to the replacement
            // 30-minute option instead of silently reverting to the default.
            if rawValue == "minutes40" {
                self = .minutes30
            } else if let value = Self(rawValue: rawValue) {
                self = value
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown inactive archive interval: \(rawValue)"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
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
    /// Per-podcast automation stored alongside the other subscription automation
    /// settings so it automatically participates in existing persistence and
    /// CloudKit field-level sync. It is not itself an archive rule.
    public var playInstantEnabled: Bool

    public static let `default` = AutoArchiveSettings(
        afterPlayed: .afterPlaying,
        afterInactive: .days7,
        episodeLimit: .one,
        playInstantEnabled: false
    )

    public init(
        afterPlayed: AfterPlayed = .afterPlaying,
        afterInactive: AfterInactive = .days7,
        episodeLimit: EpisodeLimit = .one,
        playInstantEnabled: Bool = false
    ) {
        self.afterPlayed = afterPlayed
        self.afterInactive = afterInactive
        self.episodeLimit = episodeLimit
        self.playInstantEnabled = playInstantEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case afterPlayed, afterInactive, episodeLimit, playInstantEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        afterPlayed = try container.decodeIfPresent(AfterPlayed.self, forKey: .afterPlayed) ?? .afterPlaying
        afterInactive = try container.decodeIfPresent(AfterInactive.self, forKey: .afterInactive) ?? .days7
        episodeLimit = try container.decodeIfPresent(EpisodeLimit.self, forKey: .episodeLimit) ?? .one
        playInstantEnabled = try container.decodeIfPresent(Bool.self, forKey: .playInstantEnabled) ?? false
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
    public var description: String?
    public var durationSeconds: TimeInterval?
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
        description: String? = nil,
        durationSeconds: TimeInterval? = nil,
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
        self.description = description
        self.durationSeconds = durationSeconds
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
    /// Longer per-episode observation history for schedule learning and the
    /// Release Radar schedule profile.
    public var releaseObservations: [FeedReleaseObservation]
    /// Extreme parser-memory growth pauses automatic refresh for this feed.
    /// Explicit/manual refresh bypasses the persisted quarantine.
    public var parseQuarantineUntil: Date?
    public var consecutiveHighMemoryParses: Int

    public static let maxRecentPublishDates = 10
    public static let maxReleaseObservations = 200

    public init(
        etag: String? = nil,
        lastModified: String? = nil,
        lastFetchedAt: Date? = nil,
        lastNewEpisodeAt: Date? = nil,
        consecutiveEmptyFetches: Int = 0,
        recentPublishDates: [Date] = [],
        releaseObservations: [FeedReleaseObservation] = [],
        parseQuarantineUntil: Date? = nil,
        consecutiveHighMemoryParses: Int = 0
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.lastFetchedAt = lastFetchedAt
        self.lastNewEpisodeAt = lastNewEpisodeAt
        self.consecutiveEmptyFetches = consecutiveEmptyFetches
        self.recentPublishDates = recentPublishDates
        self.releaseObservations = releaseObservations
        self.parseQuarantineUntil = parseQuarantineUntil
        self.consecutiveHighMemoryParses = consecutiveHighMemoryParses
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
        parseQuarantineUntil = try container.decodeIfPresent(
            Date.self,
            forKey: .parseQuarantineUntil
        )
        consecutiveHighMemoryParses = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveHighMemoryParses
        ) ?? 0
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
        downloadFilterSettings: DownloadFilterSettings = .default,
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
            let isEligibleForLearning = downloadFilterSettings.evaluation(for: episode).isIncluded

            if let index = observationsByKey[key] {
                releaseObservations[index].guid = episode.guid
                releaseObservations[index].title = episode.title
                releaseObservations[index].description = episode.description
                releaseObservations[index].durationSeconds = episode.durationSeconds
                releaseObservations[index].audioURL = episode.audioURL
                releaseObservations[index].publishedAt = episode.publishedAt
                releaseObservations[index].lastSeenAt = date
                releaseObservations[index].dateQuality = dateQuality
            } else {
                let observation = FeedReleaseObservation(
                    episodeKey: key,
                    guid: episode.guid,
                    title: episode.title,
                    description: episode.description,
                    durationSeconds: episode.durationSeconds,
                    audioURL: episode.audioURL,
                    publishedAt: episode.publishedAt,
                    firstSeenAt: date,
                    lastSeenAt: date,
                    dateQuality: dateQuality,
                    wasNewWhenFirstSeen: !previouslyKnownEpisodeKeys.contains(key)
                )
                releaseObservations.append(observation)
                observationsByKey[key] = releaseObservations.count - 1
                if isEligibleForLearning {
                    newlyRecorded += 1
                }
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

    public func scheduleProfile(
        downloadFilterSettings: DownloadFilterSettings,
        calendar: Calendar = .current
    ) -> FeedScheduleProfile {
        FeedScheduleProfiler.profile(from: releaseObservations(includedBy: downloadFilterSettings), calendar: calendar)
    }

    /// Full diagnostic snapshot (inputs + daily/weekly gate outcomes) for the
    /// per-subscription Release Radar diagnostic screen.
    public func releaseRadarDiagnostics(calendar: Calendar = .current) -> FeedScheduleDiagnostics {
        FeedScheduleProfiler.diagnostics(from: releaseObservations, calendar: calendar)
    }

    public func releaseRadarDiagnostics(
        downloadFilterSettings: DownloadFilterSettings,
        calendar: Calendar = .current
    ) -> FeedScheduleDiagnostics {
        FeedScheduleProfiler.diagnostics(from: releaseObservations(includedBy: downloadFilterSettings), calendar: calendar)
    }

    public func releaseObservations(includedBy downloadFilterSettings: DownloadFilterSettings) -> [FeedReleaseObservation] {
        guard downloadFilterSettings.hasActiveFilters else { return releaseObservations }
        return releaseObservations.filter { downloadFilterSettings.evaluation(for: $0).isIncluded }
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
    /// Full circular spread of the reliable publish times that fed this window,
    /// before the densest-mode window was selected. Used to soften confidence and
    /// widen non-hourly windows when the feed is genuinely messy.
    public var observedSpreadMinutes: Int?

    public init(
        activeWeekdays: [Int],
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        typicalMinuteOfDay: Int,
        observedEpisodeCount: Int,
        observedSpreadMinutes: Int? = nil
    ) {
        self.activeWeekdays = activeWeekdays
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.typicalMinuteOfDay = typicalMinuteOfDay
        self.observedEpisodeCount = observedEpisodeCount
        self.observedSpreadMinutes = observedSpreadMinutes
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
    /// Learned time-of-day window for single-slot feeds. Sized from the densest
    /// publish-time mode, then widened when the full observed spread shows the
    /// feed is too messy for a narrow window. `nil` for feeds the profiler hasn't
    /// windowed.
    public var releaseWindow: FeedScheduleWindow?
    /// Release Radar v2 (Stage 1): per-weekday publish likelihood — the fraction of
    /// observed weeks the feed published on each Calendar weekday (1 = Sun … 7 = Sat).
    /// This, plus cadence, is what classifies daily/weekdays/weekly/several-times-a-week
    /// feeds — publish *time* no longer gates classification, only window sizing. `nil`
    /// for feeds classified by the hourly/rolling-bulletin/burst detectors.
    public var weekdayProbabilities: [Int: Double]?
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
        releaseWindow: FeedScheduleWindow? = nil,
        weekdayProbabilities: [Int: Double]? = nil,
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
        self.releaseWindow = releaseWindow
        self.weekdayProbabilities = weekdayProbabilities
        self.reason = reason
    }

    /// User-facing schedule label. Derived from `kind` + the learned active-day set so
    /// "Weekdays" (Mon–Fri) and "Daily" (includes the weekend) read differently even
    /// though they share the `.dailyWeekdays` kind. Used by the diagnostic pages/export.
    public var categoryLabel: String {
        switch kind {
        case .learning:        return "Still learning"
        case .unreliableDates: return "Unreliable dates"
        case .hourly:          return "Hourly"
        case .rollingBulletin: return "Rolling bulletin"
        case .burst:           return "Daily – Multiple Episodes"
        case .weekly:          return "Weekly"
        case .multiSlot:       return "Several times a week"
        case .random:          return "Random / no pattern"
        case .dailyWeekdays:
            // weekday 1 = Sunday, 7 = Saturday.
            return Set(activeWeekdays).isDisjoint(with: [1, 7]) ? "Weekdays" : "Daily"
        }
    }
}

/// Read-only snapshot of everything Release Radar derives from a subscription's
/// release observations — surfaced by the per-subscription diagnostic screen so the
/// inputs to (and blockers against) classification are visible at a glance. Built by
/// `FeedScheduleProfiler.diagnostics(from:)`; never persisted.
public struct FeedScheduleDiagnostics: Sendable, Equatable {
    /// One classifier guard, evaluated against this feed's data with the real threshold.
    public struct GateCheck: Sendable, Equatable {
        public var label: String
        public var passed: Bool
        public var detail: String
    }

    public var observationCount: Int
    public var reliableDateCount: Int
    /// Count of observations per `FeedReleaseDateQuality.rawValue` (e.g. "plausible").
    public var qualityBreakdown: [String: Int]
    /// Reliable-date count per Calendar weekday (1 = Sun … 7 = Sat).
    public var weekdayHistogram: [Int: Int]
    /// Per-weekday publish probability (fraction of observed weeks each weekday
    /// published). Maps to a watch tier via `FeedRefreshScheduling.watchTier(forProbability:)`.
    public var weekdayProbabilities: [Int: Double]
    public var dominantWeekday: Int?
    public var dominantWeekdayRatio: Double
    public var distinctWeekdays: Int
    public var distinctBusinessWeekdays: Int
    public var businessWeekdayRatio: Double
    public var timeOfDayCenterMinute: Int?
    public var timeOfDaySpreadMinutes: Int?
    public var medianIntervalSeconds: TimeInterval?
    public var firstObservedAt: Date?
    public var lastObservedAt: Date?
    /// The authoritative classification (same call Release Radar uses).
    public var profile: FeedScheduleProfile
    /// Why the feed does / doesn't qualify as daily-weekdays and weekly — the two
    /// behaviours users most expect. Each entry mirrors a real profiler guard.
    public var dailyChecks: [GateCheck]
    public var weeklyChecks: [GateCheck]
}

public enum FeedScheduleProfiler {
    private static let minimumReliableDates = 4
    private static let hourlyMinimumDates = 6
    private static let burstMinimumDays = 3
    /// "Daily – Multiple Episodes" (the burst kind) requires the multi-episode-per-day
    /// pattern on MOST days of the week. A burst on only one or two weekdays (a weekly
    /// show split into segments) falls through to the regular classifier → weekly.
    private static let burstMinimumActiveWeekdays = 5
    /// How many of the most recent episodes size the burst window — recent enough to
    /// follow a feed that shifted its posting time, large enough to be stable.
    private static let burstWindowSampleSize = 40
    /// Weekly window tuning. A weekly feed's publish time-of-day may drift this far
    /// (trimmed range, in minutes) and still count as "roughly the same time each
    /// week" — produced shows slip with post-production rather than publishing at a
    /// fixed minute. Beyond this the time really is unpredictable and the feed falls
    /// through to random surveillance.
    private static let weeklyMaxObservedSpreadMinutes = 360
    /// Padding added on each side of the observed publish-time range so episodes at
    /// the edges of the learned window aren't missed.
    private static let weeklyWindowMarginMinutes = 20
    /// Floor for the learned weekly window half-width so a razor-tight feed still
    /// gets a sensible pre/post buffer (never narrower than a 1-hour window).
    private static let weeklyMinHalfWidthMinutes = 30

    // Release Radar v2 — Stage 1 (cadence + active-day classification, no time gate).
    /// Need at least this many reliable dates before committing to any cadence pattern.
    private static let regularMinimumReliableDates = 4
    /// Need at least this many distinct weeks of history so per-weekday probabilities
    /// are stable rather than reading a one-week burst as a pattern.
    private static let regularMinimumWeeks = 3
    /// A weekday counts as "active" if the feed publishes on it in at least this
    /// fraction of observed weeks. 0.6 keeps one-off specials and biweekly noise out
    /// while tolerating the occasional skipped/holiday day.
    private static let activeDayThreshold = 0.6
    /// Daily/weekdays/several-times patterns need at least this many reliable dates
    /// (weekly is allowed fewer — see `regularMinimumReliableDates`).
    private static let multiDayMinimumReliableDates = 6
    /// Recency half-life (weeks) for the per-weekday publish probabilities. Recent weeks
    /// dominate so a stale or biased capture (old data skewed to one day) can't override
    /// the feed's current pattern, and a feed that changed its schedule self-corrects.
    private static let weekdayRecencyHalfLifeWeeks = 8.0
    /// Episode-share weekly threshold: if one weekday holds at least this fraction of ALL
    /// episodes on a ~weekly cadence, classify as weekly even when that day's per-week
    /// probability dips below `activeDayThreshold` because the show skips the odd week.
    private static let weeklyDominantShareThreshold = 0.65
    /// Cadence classification (median gap + recent active-weekday presence) runs over
    /// only the most recent this-many reliable dates, NOT all history. This keeps a
    /// stale back-catalogue from pinning the class to the wrong cadence — e.g. The
    /// Daily, whose feed only retains Sunday episodes long-term, seeds dozens of
    /// Sunday-only observations that outvote its genuine 7-days-a-week publishing.
    /// Windowing is self-healing: as fresh daily captures accumulate and the stale
    /// seed ages out of the window, the class corrects automatically. Sized in
    /// observations (not days) so it self-scales across cadences — ~25 obs is ~3½
    /// weeks for a daily feed but ~25 weeks for a weekly one, giving each enough
    /// recent signal without dragging in ancient history. The recency-weighted weekday
    /// PROBABILITIES and the time-of-day window keep using full history (they have
    /// their own recency weighting).
    private static let cadenceRecencyWindowSize = 25
    /// A weekday must appear at least this many times inside the recency window to count
    /// as a "recent active day". 2 keeps a single stray capture from inflating the
    /// distinct-weekday count while still recognising ~2 weeks of genuine daily output.
    private static let recentActiveWeekdayMinCount = 2

    // Release Radar v2 — Stage 2 (densest-mode window + recency + watch-intensity tiers).
    /// Half-width (minutes) of the search window used to locate the densest publish-time
    /// mode. Episodes within this of the densest centre form the tight primary window;
    /// the rest are caught by the lighter missed-release "soft tail".
    private static let modeSearchHalfWidthMinutes = 75
    /// Recency half-life in weeks for weighting publish times when sizing the window, so
    /// a feed that shifts its publish time retunes within a few weeks without discarding
    /// older history.
    private static let recencyHalfLifeWeeks = 10.0

    public static func profile(
        from observations: [FeedReleaseObservation],
        calendar: Calendar = .current,
        now: Date = Date()
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
            activeWeekdays: activeWeekdays,
            now: now
        ) {
            return profile
        }

        if let profile = regularCadenceProfile(
            dates: dates,
            calendar: calendar,
            medianInterval: medianInterval,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            now: now
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

    /// Surfaces the inputs and gate outcomes behind `profile(from:)` for the
    /// per-subscription diagnostic screen. Reuses the same private helpers the
    /// classifier uses, so the numbers shown match exactly what Release Radar acts on.
    public static func diagnostics(
        from observations: [FeedReleaseObservation],
        calendar: Calendar = .current
    ) -> FeedScheduleDiagnostics {
        var qualityBreakdown: [String: Int] = [:]
        for observation in observations {
            qualityBreakdown[observation.dateQuality.rawValue, default: 0] += 1
        }

        let reliable = observations
            .filter { $0.dateQuality == .plausible }
            .compactMap(\.publishedAt)
            .sorted()
        let reliableDateCount = reliable.count

        let weekdayHistogram = countsByWeekday(reliable, calendar: calendar)
        let dominant = weekdayHistogram.max { $0.value < $1.value }
        let dominantRatio = dominant.map { Double($0.value) / Double(max(reliableDateCount, 1)) } ?? 0
        let businessWeekdayTotal = weekdayHistogram
            .filter { isBusinessWeekday($0.key) }
            .map(\.value)
            .reduce(0, +)
        let businessWeekdayRatio = Double(businessWeekdayTotal) / Double(max(reliableDateCount, 1))

        let cluster = reliable.isEmpty
            ? nil
            : circularCluster(minutes: reliable.map { minuteOfDay(for: $0, calendar: calendar) }, modulo: 24 * 60)
        // Cadence stats (median gap + recent active-weekday presence) use the recency
        // window, matching regularCadenceProfile, so a stale back-catalogue doesn't skew
        // the class or these explanations. See `cadenceRecencyWindowSize`.
        let medianIntervalSeconds = recentMedianInterval(reliable)
        let medianDays = medianIntervalSeconds.map { $0 / 86_400 }
        let recentActiveCount = recentActiveWeekdays(reliable, calendar: calendar).count

        // Release Radar v2 gate checks: classification is cadence + active-day pattern,
        // NOT publish time. (Publish-time spread still shows under "Learning signal" —
        // it sizes the window now, it doesn't gate the class.)
        let (probabilities, weeksObserved) = weekdayPublishProbabilities(reliable, calendar: calendar)
        let activeDayCount = probabilities.filter { $0.value >= activeDayThreshold }.count

        let dailyChecks: [FeedScheduleDiagnostics.GateCheck] = [
            .init(label: "≥ 6 reliable dates", passed: reliableDateCount >= multiDayMinimumReliableDates, detail: "\(reliableDateCount) / 6"),
            .init(label: "≥ 3 weeks of history", passed: weeksObserved >= regularMinimumWeeks, detail: "\(weeksObserved) wk"),
            .init(label: "5+ active days/week", passed: activeDayCount >= 5 || recentActiveCount >= 5, detail: "\(activeDayCount) active · \(recentActiveCount) recent"),
            .init(label: "Median gap ≤ 2 days (recent)", passed: (medianDays ?? .greatestFiniteMagnitude) <= 2, detail: medianDays.map { String(format: "%.1f d", $0) } ?? "—")
        ]
        let weeklyChecks: [FeedScheduleDiagnostics.GateCheck] = [
            .init(label: "≥ 4 reliable dates", passed: reliableDateCount >= regularMinimumReliableDates, detail: "\(reliableDateCount) / 4"),
            .init(label: "≥ 3 weeks of history", passed: weeksObserved >= regularMinimumWeeks, detail: "\(weeksObserved) wk"),
            .init(label: "1 active day or ≥65% on one weekday", passed: activeDayCount == 1 || dominantRatio >= weeklyDominantShareThreshold, detail: "\(activeDayCount) active · \(Int((dominantRatio * 100).rounded()))%"),
            .init(label: "Median gap 4–11 days (recent)", passed: (4.0...11.0).contains(medianDays ?? -1), detail: medianDays.map { String(format: "%.1f d", $0) } ?? "—")
        ]

        return FeedScheduleDiagnostics(
            observationCount: observations.count,
            reliableDateCount: reliableDateCount,
            qualityBreakdown: qualityBreakdown,
            weekdayHistogram: weekdayHistogram,
            weekdayProbabilities: probabilities,
            dominantWeekday: dominant?.key,
            dominantWeekdayRatio: dominantRatio,
            distinctWeekdays: weekdayHistogram.keys.count,
            distinctBusinessWeekdays: distinctBusinessWeekdays(weekdayHistogram),
            businessWeekdayRatio: businessWeekdayRatio,
            timeOfDayCenterMinute: cluster?.center,
            timeOfDaySpreadMinutes: cluster?.spread,
            medianIntervalSeconds: medianIntervalSeconds,
            firstObservedAt: reliable.first,
            lastObservedAt: reliable.last,
            profile: profile(from: observations, calendar: calendar),
            dailyChecks: dailyChecks,
            weeklyChecks: weeklyChecks
        )
    }

    private static func distinctBusinessWeekdays(_ histogram: [Int: Int]) -> Int {
        histogram.keys.filter(isBusinessWeekday).count
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
        activeWeekdays: [Int],
        now: Date
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
        // Must post multiple episodes per day on MOST days of the week to count as
        // "Daily – Multiple Episodes". A burst on one/two weekdays (e.g. a weekly show
        // split into segments) falls through to the regular classifier, which — by its
        // dominant-weekday share — treats it as weekly.
        guard activeWeekdays.count >= burstMinimumActiveWeekdays else { return nil }

        let centers = burstDays.map(\.center)
        let centerCluster = circularCluster(minutes: centers, modulo: 24 * 60)
        guard centerCluster.spread <= 90 else { return nil }

        // Window spans the full daily burst from the RECENT episodes' outlier-trimmed
        // publish-time range (+ margin), so late-running days aren't missed and the
        // window follows a feed that shifted its posting time. The old median-first /
        // median-last range left the back half of slower days outside the window.
        let recentMinutes = dstStableMinutes(Array(dates.suffix(burstWindowSampleSize)), calendar: calendar, now: now)
        let windowCenter = circularCluster(minutes: recentMinutes, modulo: 24 * 60).center
        let range = trimmedOffsetRange(recentMinutes, around: windowCenter, modulo: 24 * 60)
        let start = max(0, min(windowCenter + range.low - weeklyWindowMarginMinutes,
                               windowCenter - weeklyMinHalfWidthMinutes))
        let end = min(24 * 60 - 1, max(windowCenter + range.high + weeklyWindowMarginMinutes,
                                       windowCenter + weeklyMinHalfWidthMinutes))
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
            typicalMinuteOfDay: windowCenter,
            burstWindow: FeedScheduleWindow(
                activeWeekdays: activeWeekdays,
                startMinuteOfDay: start,
                endMinuteOfDay: end,
                typicalMinuteOfDay: windowCenter,
                observedEpisodeCount: burstDays.map(\.count).reduce(0, +)
            ),
            reason: "Publishes multiple episodes per day on most days of the week."
        )
    }

    /// Release Radar v2 — Stage 1. Classifies a feed by cadence + active-day pattern
    /// WITHOUT gating on publish time (publish time only sizes the window, below). This
    /// replaces the old time-gated dailyWeekdays/weekly/multiSlot detectors, which
    /// dropped variable-time feeds to random surveillance. Runs after the hourly/
    /// rolling-bulletin/burst detectors, so it only sees feeds that publish at most
    /// ~once per active day. Active days drive scheduling, so a Mon–Fri feed simply
    /// never opens weekend slots.
    /// The most recent slice of (ascending-sorted) reliable publish dates used for
    /// cadence classification. See `cadenceRecencyWindowSize`.
    private static func recentCadenceDates(_ sortedDates: [Date]) -> [Date] {
        Array(sortedDates.suffix(cadenceRecencyWindowSize))
    }

    /// Median inter-publish gap (seconds) over the recency window of the given
    /// ascending-sorted dates — the cadence signal that decides median-gap gates.
    private static func recentMedianInterval(_ sortedDates: [Date]) -> TimeInterval? {
        let recent = recentCadenceDates(sortedDates)
        let intervals = zip(recent, recent.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 }
        return median(intervals)
    }

    /// Weekdays the feed has published on at least `recentActiveWeekdayMinCount` times
    /// within the recency window — a PRESENCE signal (not the week-fraction probability).
    /// This is what lets a feed with only a couple of weeks of genuine daily capture be
    /// recognised as daily before any single weekday's per-week probability can climb
    /// above `activeDayThreshold`.
    private static func recentActiveWeekdays(_ sortedDates: [Date], calendar: Calendar) -> [Int] {
        countsByWeekday(recentCadenceDates(sortedDates), calendar: calendar)
            .filter { $0.value >= recentActiveWeekdayMinCount }
            .keys
            .sorted()
    }

    private static func regularCadenceProfile(
        dates: [Date],
        calendar: Calendar,
        medianInterval: TimeInterval?,
        observationCount: Int,
        reliableDateCount: Int,
        now: Date
    ) -> FeedScheduleProfile? {
        guard reliableDateCount >= regularMinimumReliableDates else { return nil }

        let (probabilities, weeksObserved) = weekdayPublishProbabilities(dates, calendar: calendar)
        guard weeksObserved >= regularMinimumWeeks else { return nil }

        // Active days = weekdays the feed reliably publishes on (recency-weighted, so a
        // stale capture or a schedule change is corrected by current behaviour). One-off
        // specials and skipped holidays fall below the bar.
        let activeDays = probabilities
            .filter { $0.value >= activeDayThreshold }
            .keys
            .sorted()
        // Median gap and the recent active-weekday presence are measured over the
        // recency window, not all history, so a stale back-catalogue (e.g. The Daily's
        // Sunday-only retention) can't pin the cadence to the wrong class.
        let windowedMedianInterval = recentMedianInterval(dates)
        let medianGapDays = (windowedMedianInterval ?? medianInterval ?? .greatestFiniteMagnitude) / 86_400
        let recentActive = recentActiveWeekdays(dates, calendar: calendar)

        // Episode-SHARE dominant weekday — robust to a weekly show that skips the odd
        // week (holidays/hiatus), whose per-week probability would dip below the active
        // bar even though one weekday holds the clear majority of its episodes.
        let weekdayCounts = countsByWeekday(dates, calendar: calendar)
        let dominant = weekdayCounts.max { $0.value < $1.value }
        let dominantShare = dominant.map { Double($0.value) / Double(max(dates.count, 1)) } ?? 0

        let kind: FeedScheduleKind
        let reason: String
        let resolvedActiveDays: [Int]

        if activeDays.count == 1, (4.0...11.0).contains(medianGapDays) {
            kind = .weekly
            reason = "Publishes about once a week on a consistent day."
            resolvedActiveDays = activeDays
        } else if (2...4).contains(activeDays.count), reliableDateCount >= multiDayMinimumReliableDates, medianGapDays <= 6 {
            kind = .multiSlot
            reason = "Publishes on a small, consistent set of days each week."
            resolvedActiveDays = activeDays
        } else if activeDays.count >= 5, reliableDateCount >= multiDayMinimumReliableDates, medianGapDays <= 2 {
            let hasWeekend = !Set(activeDays).isDisjoint(with: [1, 7]) // 1 = Sun, 7 = Sat
            kind = .dailyWeekdays
            reason = hasWeekend ? "Publishes most days of the week." : "Publishes on weekdays (Mon–Fri)."
            resolvedActiveDays = activeDays
        } else if let dominantKey = dominant?.key,
                  dominantShare >= weeklyDominantShareThreshold,
                  (4.0...11.0).contains(medianGapDays) {
            // (a) Episode-share weekly: one weekday holds the clear majority of episodes
            // on a weekly cadence, even though its per-week probability is below the
            // active bar (the show skips the odd week).
            kind = .weekly
            reason = "Publishes about once a week on a consistent day (with occasional skipped weeks)."
            resolvedActiveDays = [dominantKey]
        } else if recentActive.count >= 5, medianGapDays <= 2, reliableDateCount >= multiDayMinimumReliableDates {
            // Recent-behaviour daily rescue: the feed has published on 5+ distinct
            // weekdays on a near-daily cadence within the recency window, even though no
            // single weekday's per-week probability has climbed above the active bar yet
            // (too few daily weeks so far — e.g. a show whose older episodes are purged
            // from the RSS, leaving a stale single-weekday seed). Presence over the recent
            // window, not week-fraction, is the right signal here.
            let hasWeekend = !Set(recentActive).isDisjoint(with: [1, 7])
            kind = .dailyWeekdays
            reason = hasWeekend
                ? "Publishes most days of the week (based on recent activity)."
                : "Publishes on weekdays (Mon–Fri), based on recent activity."
            resolvedActiveDays = recentActive
        } else {
            return nil
        }

        let window = releaseTimeWindow(dates: dates, activeWeekdays: resolvedActiveDays, calendar: calendar, now: now)
        let confidence = regularCadenceConfidence(
            reliableDateCount: reliableDateCount,
            activeDays: resolvedActiveDays,
            probabilities: probabilities,
            releaseWindow: window
        )
        return FeedScheduleProfile(
            kind: kind,
            confidence: confidence,
            observationCount: observationCount,
            reliableDateCount: reliableDateCount,
            activeWeekdays: resolvedActiveDays,
            typicalMinuteOfDay: window.typicalMinuteOfDay,
            cadenceSeconds: windowedMedianInterval ?? medianInterval,
            releaseWindow: window,
            weekdayProbabilities: probabilities,
            reason: reason
        )
    }

    /// Per-weekday publish likelihood, RECENCY-WEIGHTED: for each Calendar weekday
    /// (1 = Sun … 7 = Sat), the recency-weighted fraction of observed weeks the feed
    /// published on that weekday. Recent weeks count for more (weekdayRecencyHalfLifeWeeks),
    /// so a stale/biased capture or a schedule change is corrected by current behaviour
    /// rather than diluted across the full span (which permanently sank, e.g., a daily
    /// show whose older history was only captured as a weekly special). `weeksObserved`
    /// stays the raw span — used for the "enough history" guard and the diagnostics.
    private static func weekdayPublishProbabilities(
        _ dates: [Date],
        calendar: Calendar
    ) -> (probabilities: [Int: Double], weeksObserved: Int) {
        guard let first = dates.first, let last = dates.last else { return ([:], 0) }
        func weekIndex(_ date: Date) -> Int { Int(date.timeIntervalSince(first) / (7 * 86_400)) }
        let lastWeek = weekIndex(last)
        let weeksObserved = max(lastWeek + 1, 1)

        var weekdaysByWeek: [Int: Set<Int>] = [:]
        for date in dates {
            weekdaysByWeek[weekIndex(date), default: []].insert(calendar.component(.weekday, from: date))
        }

        var weightedTotal = 0.0
        var weightedByWeekday: [Int: Double] = [:]
        for week in 0...lastWeek {
            let weight = pow(0.5, Double(lastWeek - week) / weekdayRecencyHalfLifeWeeks)
            weightedTotal += weight
            for weekday in weekdaysByWeek[week] ?? [] {
                weightedByWeekday[weekday, default: 0] += weight
            }
        }
        guard weightedTotal > 0 else { return ([:], weeksObserved) }
        let probabilities = weightedByWeekday.mapValues { min(1.0, $0 / weightedTotal) }
        return (probabilities, weeksObserved)
    }

    /// Each episode's minute-of-day in whichever representation — wall-clock LOCAL vs
    /// DST-ANCHORED to the current offset — clusters more tightly, so the learned window
    /// is stable across daylight-saving changes. A feed stamped in fixed local time keeps
    /// its wall-clock time (local clusters tight); a feed stamped in fixed UTC keeps a
    /// stable instant (anchored clusters tight, expressed in the CURRENT season's local
    /// time) — removing the ±1 h drift a UTC-stamped feed otherwise suffers at each DST
    /// boundary. Degenerates to plain local minutes for a zone with no DST (e.g. UTC tests).
    private static func dstStableMinutes(_ dates: [Date], calendar: Calendar, now: Date) -> [Int] {
        let zone = calendar.timeZone
        let local = dates.map { minuteOfDay(for: $0, calendar: calendar) }
        let currentDST = Int(zone.daylightSavingTimeOffset(for: now) / 60)
        let anchored = zip(dates, local).map { date, minute -> Int in
            let episodeDST = Int(zone.daylightSavingTimeOffset(for: date) / 60)
            return (((minute + currentDST - episodeDST) % (24 * 60)) + 24 * 60) % (24 * 60)
        }
        let localSpread = circularCluster(minutes: local, modulo: 24 * 60).spread
        let anchoredSpread = circularCluster(minutes: anchored, modulo: 24 * 60).spread
        return anchoredSpread < localSpread ? anchored : local
    }

    /// Release Radar v2 — Stage 2. Sizes the primary watch window around the DENSEST
    /// publish-time mode (recency-weighted), then widens the floor when the full spread
    /// says the feed is genuinely variable. A few stragglers still stay in the missed-
    /// release/safety-sweep tail; broad messy feeds get more room so manual refresh is
    /// not needed just because the main cluster was too narrow. Recent episodes are
    /// weighted more (recencyHalfLifeWeeks) so a feed that shifts its publish time retunes
    /// within a few weeks. Episode times use `dstStableMinutes` so a UTC-stamped feed
    /// doesn't drift ±1 h across DST.
    private static func releaseTimeWindow(
        dates: [Date],
        activeWeekdays: [Int],
        calendar: Calendar,
        now: Date
    ) -> FeedScheduleWindow {
        let activeSet = Set(activeWeekdays)
        let activeDates = dates.filter { activeSet.contains(calendar.component(.weekday, from: $0)) }
        let source = activeDates.isEmpty ? dates : activeDates
        guard let mostRecent = source.last else {
            return FeedScheduleWindow(
                activeWeekdays: activeWeekdays,
                startMinuteOfDay: 0,
                endMinuteOfDay: 24 * 60 - 1,
                typicalMinuteOfDay: 0,
                observedEpisodeCount: 0,
                observedSpreadMinutes: nil
            )
        }

        let stableMinutes = dstStableMinutes(source, calendar: calendar, now: now)
        let observedSpread = circularCluster(minutes: stableMinutes, modulo: 24 * 60).spread
        let weighted: [(minute: Int, weight: Double)] = zip(source, stableMinutes).map { date, minute in
            let ageWeeks = max(0, mostRecent.timeIntervalSince(date) / (7 * 86_400))
            return (minute, pow(0.5, ageWeeks / recencyHalfLifeWeeks))
        }

        // Densest mode = the observed minute maximising the summed recency weight of
        // points within the search half-width.
        var bestCenter = weighted[0].minute
        var bestWeight = -1.0
        for candidate in weighted {
            let summed = weighted.reduce(0.0) { running, point in
                circularDistance(point.minute, candidate.minute, modulo: 24 * 60) <= modeSearchHalfWidthMinutes
                    ? running + point.weight
                    : running
            }
            if summed > bestWeight {
                bestWeight = summed
                bestCenter = candidate.minute
            }
        }

        // Tight window over just the mode members (+margin, 1-hour floor).
        let memberMinutes = weighted
            .map(\.minute)
            .filter { circularDistance($0, bestCenter, modulo: 24 * 60) <= modeSearchHalfWidthMinutes }
        let center = circularCluster(minutes: memberMinutes, modulo: 24 * 60).center
        let range = trimmedOffsetRange(memberMinutes, around: center, modulo: 24 * 60)
        let modeCoverage = Double(memberMinutes.count) / Double(max(weighted.count, 1))
        let halfWidthFloor = adaptiveWindowHalfWidth(
            observedSpreadMinutes: observedSpread,
            modeCoverage: modeCoverage
        )
        let startMinute = max(0, min(center + range.low - weeklyWindowMarginMinutes,
                                     center - halfWidthFloor))
        let endMinute = min(24 * 60 - 1, max(center + range.high + weeklyWindowMarginMinutes,
                                             center + halfWidthFloor))
        return FeedScheduleWindow(
            activeWeekdays: activeWeekdays,
            startMinuteOfDay: startMinute,
            endMinuteOfDay: endMinute,
            typicalMinuteOfDay: center,
            observedEpisodeCount: source.count,
            observedSpreadMinutes: observedSpread
        )
    }

    private static func adaptiveWindowHalfWidth(
        observedSpreadMinutes: Int,
        modeCoverage: Double
    ) -> Int {
        if modeCoverage < 0.55 || (observedSpreadMinutes >= 8 * 60 && modeCoverage < 0.75) {
            return 120
        }
        if modeCoverage < 0.70 || (observedSpreadMinutes >= 4 * 60 && modeCoverage < 0.80) {
            return 90
        }
        if observedSpreadMinutes >= 3 * 60 && modeCoverage < 0.85 {
            return 60
        }
        return weeklyMinHalfWidthMinutes
    }

    /// Smallest circular distance between two values modulo `modulo`.
    private static func circularDistance(_ a: Int, _ b: Int, modulo: Int) -> Int {
        let raw = (((a - b) % modulo) + modulo) % modulo
        return min(raw, modulo - raw)
    }

    /// Confidence rises with how reliably the active days publish and how much history
    /// backs the pattern.
    private static func regularCadenceConfidence(
        reliableDateCount: Int,
        activeDays: [Int],
        probabilities: [Int: Double],
        releaseWindow: FeedScheduleWindow
    ) -> Double {
        let activeProbabilities = activeDays.map { probabilities[$0] ?? 0 }
        let meanActive = activeProbabilities.isEmpty
            ? 0
            : activeProbabilities.reduce(0, +) / Double(activeProbabilities.count)
        let base = min(0.97, 0.55
            + 0.25 * meanActive
            + min(0.15, Double(reliableDateCount) / 200.0))
        let windowWidth = max(1, releaseWindow.endMinuteOfDay - releaseWindow.startMinuteOfDay)
        let observedSpread = releaseWindow.observedSpreadMinutes ?? windowWidth
        let spreadPenalty: Double
        if observedSpread >= 8 * 60 {
            spreadPenalty = 0.14
        } else if observedSpread >= 4 * 60 {
            spreadPenalty = 0.08
        } else if observedSpread > windowWidth * 2 {
            spreadPenalty = 0.04
        } else {
            spreadPenalty = 0
        }
        return max(0.50, base - spreadPenalty)
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

    /// Signed minute offsets (relative to `center`, in roughly `[-modulo/2, modulo/2]`)
    /// covering the bulk of `minutes`, trimming the most extreme ~5% on each side so a
    /// few stray publish times (a re-release, a special) don't stretch a learned
    /// window. With only a handful of points this collapses to the full min/max range.
    private static func trimmedOffsetRange(
        _ minutes: [Int],
        around center: Int,
        modulo: Int
    ) -> (low: Int, high: Int) {
        guard !minutes.isEmpty else { return (0, 0) }
        let offsets = minutes.map { value -> Int in
            let raw = (((value - center) % modulo) + modulo) % modulo
            return raw <= modulo / 2 ? raw : raw - modulo
        }.sorted()
        let lowIndex = min(offsets.count - 1, Int((Double(offsets.count - 1) * 0.05).rounded()))
        let highIndex = min(offsets.count - 1, Int((Double(offsets.count - 1) * 0.95).rounded()))
        return (offsets[lowIndex], offsets[highIndex])
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

/// Release Radar v2 — Stage 2 per-weekday watch intensity, derived from a feed's
/// per-weekday publish probability. `full` = watched closely in the learned window,
/// `light` = an occasional check, `skip` = not watched at all.
public enum FeedWatchTier: String, Sendable, Equatable {
    case full
    case light
    case skip
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

    // Release Radar v2 — Stage 2 watch-intensity tiers (read from weekdayProbabilities).
    /// At/above this probability a weekday is "active": full window, high rotation.
    private static let fullTierThreshold = 0.6
    /// Between `lightTierThreshold` and `fullTierThreshold` a weekday occasionally
    /// publishes — checked lightly during its window. Below it, the day is skipped.
    private static let lightTierThreshold = 0.25
    /// Recheck multiplier applied to a light-tier day's window (a fraction of the
    /// full-rotation cadence).
    private static let lightTierRecheckMultiplier = 4.0
    /// Low-priority catch-up cadence for learned non-news feeds outside their main
    /// window. Hourly/rolling bulletin feeds keep their tight minute slots; ordinary
    /// daily/weekly/multi feeds get a safety net so messy publisher timestamps don't
    /// force the user into manual refresh.
    private static let dailySafetySweepInterval: TimeInterval = 12 * 60 * 60
    private static let weeklySafetySweepInterval: TimeInterval = 24 * 60 * 60

    /// The watch tier a weekday gets for a given per-week publish probability. The single
    /// source of truth for the tier thresholds (used by scheduling and the diagnostics).
    public static func watchTier(forProbability probability: Double) -> FeedWatchTier {
        if probability >= fullTierThreshold { return .full }
        if probability >= lightTierThreshold { return .light }
        return .skip
    }

    /// The watch tier shown for a weekday on a feed, given that weekday's publish
    /// probability. The active-weekday → full shortcut applies only to the day-windowed
    /// kinds (weekly / daily-weekdays / multi-slot), where `activeWeekdays` is the resolved
    /// watch set — e.g. a weekly day classified by episode share, whose raw probability
    /// sits below the full bar. For other kinds `activeWeekdays` is merely the observed
    /// days (not a watch set), so the tier follows the probability.
    public static func watchTier(forProbability probability: Double, onWeekday weekday: Int, in profile: FeedScheduleProfile) -> FeedWatchTier {
        let dayWindowed: Bool
        switch profile.kind {
        case .weekly, .dailyWeekdays, .multiSlot: dayWindowed = true
        default: dayWindowed = false
        }
        if dayWindowed, profile.activeWeekdays.contains(weekday) { return .full }
        return watchTier(forProbability: probability)
    }

    private struct RefreshSlot {
        var preWindowStart: Date
        var windowStart: Date
        var windowEnd: Date
        /// Stage-2 watch tier. A light slot is a medium-probability day (occasionally
        /// publishes): it's checked at a lighter cadence during the window and does not
        /// escalate to missed-release surveillance afterwards.
        var isLight: Bool = false
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
                quietReason: "Burst window already produced an episode and has closed.",
                safetySweepInterval: dailySafetySweepInterval
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
                slots: releaseSlots(
                    profile: profile,
                    windowStartMinute: profile.releaseWindow?.startMinuteOfDay ?? max(0, minute - 10),
                    windowEndMinute: profile.releaseWindow?.endMinuteOfDay ?? min(24 * 60 - 1, minute + 75),
                    fullPreWindowLead: 20 * 60,
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
                quietReason: "Expected weekday episode appears to have arrived; wait for the next learned weekday window.",
                safetySweepInterval: dailySafetySweepInterval
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
                slots: releaseSlots(
                    profile: profile,
                    windowStartMinute: profile.releaseWindow?.startMinuteOfDay ?? max(0, minute - 10),
                    windowEndMinute: profile.releaseWindow?.endMinuteOfDay ?? min(24 * 60 - 1, minute + 120),
                    fullPreWindowLead: 20 * 60,
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
                quietReason: "Expected weekly episode appears to have arrived; wait for the next learned weekly window.",
                safetySweepInterval: weeklySafetySweepInterval
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
                slots: releaseSlots(
                    profile: profile,
                    windowStartMinute: profile.releaseWindow?.startMinuteOfDay ?? max(0, minute - 5),
                    windowEndMinute: profile.releaseWindow?.endMinuteOfDay ?? min(24 * 60 - 1, minute + 60),
                    fullPreWindowLead: 10 * 60,
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
                quietReason: "Expected multi-slot episode appears to have arrived; wait for the next learned slot.",
                safetySweepInterval: dailySafetySweepInterval
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
        quietReason: String,
        safetySweepInterval: TimeInterval? = nil
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
            return quietOrSafetySweepPrediction(
                profile: profile,
                stats: stats,
                now: now,
                defaultNextDue: nextDue,
                expectedWindowStart: nextSlot?.windowStart,
                expectedWindowEnd: nextSlot?.windowEnd,
                quietReason: "Outside the learned release window; wait for the next pre-window check.",
                safetySweepInterval: safetySweepInterval
            )
        }

        func quietPrediction(
            defaultNextDue: Date,
            expectedWindowStart: Date?,
            expectedWindowEnd: Date?,
            reason: String
        ) -> FeedRefreshPrediction {
            return quietOrSafetySweepPrediction(
                profile: profile,
                stats: stats,
                now: now,
                defaultNextDue: defaultNextDue,
                expectedWindowStart: expectedWindowStart,
                expectedWindowEnd: expectedWindowEnd,
                quietReason: reason,
                safetySweepInterval: safetySweepInterval
            )
        }

        let publishedInSlot = latestPublishedAt.map { $0 >= slot.windowStart } ?? false
        if publishedInSlot, !continueCheckingAfterPublishUntilWindowEnd {
            let nextDue = nextSlot?.preWindowStart ?? slot.windowEnd.addingTimeInterval(baseRecheck)
            return quietPrediction(
                defaultNextDue: nextDue,
                expectedWindowStart: nextSlot?.windowStart,
                expectedWindowEnd: nextSlot?.windowEnd,
                reason: quietReason
            )
        }

        if now < slot.windowStart {
            let preWindowRecheck = max(baseRecheck, 5 * 60)
            return FeedRefreshPrediction(
                nextDueAt: dueFromLastFetch(stats.lastFetchedAt, interval: preWindowRecheck, now: now),
                state: .preWindow,
                profileKind: profile.kind,
                expectedWindowStart: slot.windowStart,
                expectedWindowEnd: slot.windowEnd,
                recheckInterval: preWindowRecheck,
                reason: "Pre-window is open; start checking shortly before the learned release time."
            )
        }

        if now <= slot.windowEnd {
            let recheck = slot.isLight ? baseRecheck * lightTierRecheckMultiplier : baseRecheck
            return FeedRefreshPrediction(
                nextDueAt: dueFromLastFetch(stats.lastFetchedAt, interval: recheck, now: now),
                state: .activeWindow,
                profileKind: profile.kind,
                expectedWindowStart: slot.windowStart,
                expectedWindowEnd: slot.windowEnd,
                recheckInterval: recheck,
                reason: slot.isLight ? "Light check on an occasionally-active day." : activeReason
            )
        }

        if slot.isLight {
            // A light (medium-probability) day usually has no episode — don't escalate to
            // missed-release surveillance; stand down until the next learned window.
            let nextDue = nextSlot?.preWindowStart ?? now.addingTimeInterval(baseRecheck)
            return quietPrediction(
                defaultNextDue: nextDue,
                expectedWindowStart: nextSlot?.windowStart,
                expectedWindowEnd: nextSlot?.windowEnd,
                reason: "Light-tier day window passed; wait for the next learned window."
            )
        }

        if publishedInSlot {
            let nextDue = nextSlot?.preWindowStart ?? now.addingTimeInterval(baseRecheck)
            return quietPrediction(
                defaultNextDue: nextDue,
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

    /// Release Radar v2 — Stage 2 watch-intensity tiers. Builds full-rotation slots for
    /// the profile's active (high-probability) weekdays, plus lighter slots for any
    /// medium-probability weekday (`lightTierThreshold` ≤ p < `fullTierThreshold`) that
    /// occasionally publishes but isn't reliable enough to be "active". Days below
    /// `lightTierThreshold` get no slots at all (skipped — e.g. weekends for a Mon–Fri
    /// show). Profiles without learned probabilities (manually constructed) fall back to
    /// the active set only, so existing behaviour is unchanged.
    private static func releaseSlots(
        profile: FeedScheduleProfile,
        windowStartMinute: Int,
        windowEndMinute: Int,
        fullPreWindowLead: TimeInterval,
        now: Date,
        calendar: Calendar
    ) -> [RefreshSlot] {
        var slots = dailySlots(
            activeWeekdays: profile.activeWeekdays,
            windowStartMinute: windowStartMinute,
            windowEndMinute: windowEndMinute,
            preWindowLead: fullPreWindowLead,
            now: now,
            calendar: calendar
        )

        let fullSet = Set(profile.activeWeekdays)
        let lightDays = (profile.weekdayProbabilities ?? [:])
            .filter { $0.value >= lightTierThreshold && $0.value < fullTierThreshold && !fullSet.contains($0.key) }
            .keys
            .sorted()
        if !lightDays.isEmpty {
            slots += dailySlots(
                activeWeekdays: lightDays,
                windowStartMinute: windowStartMinute,
                windowEndMinute: windowEndMinute,
                preWindowLead: 0,
                now: now,
                calendar: calendar
            ).map { slot in
                var light = slot
                light.isLight = true
                return light
            }
        }
        return slots
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

    private static func quietOrSafetySweepPrediction(
        profile: FeedScheduleProfile,
        stats: RefreshStats,
        now: Date,
        defaultNextDue: Date,
        expectedWindowStart: Date?,
        expectedWindowEnd: Date?,
        quietReason: String,
        safetySweepInterval: TimeInterval?
    ) -> FeedRefreshPrediction {
        guard let safetySweepInterval else {
            return FeedRefreshPrediction(
                nextDueAt: defaultNextDue,
                state: .quiet,
                profileKind: profile.kind,
                expectedWindowStart: expectedWindowStart,
                expectedWindowEnd: expectedWindowEnd,
                reason: quietReason
            )
        }

        let safetyDue = dueFromLastFetch(stats.lastFetchedAt, interval: safetySweepInterval, now: now)
        if safetyDue <= now {
            return FeedRefreshPrediction(
                nextDueAt: safetyDue,
                state: .fallback,
                profileKind: profile.kind,
                expectedWindowStart: expectedWindowStart,
                expectedWindowEnd: expectedWindowEnd,
                recheckInterval: safetySweepInterval,
                reason: "Broad safety sweep is due outside the learned release window."
            )
        }

        let nextDue = min(defaultNextDue, safetyDue)
        let reason = safetyDue < defaultNextDue
            ? "\(quietReason) A broad safety sweep is scheduled before the next learned window."
            : quietReason
        return FeedRefreshPrediction(
            nextDueAt: nextDue,
            state: .quiet,
            profileKind: profile.kind,
            expectedWindowStart: expectedWindowStart,
            expectedWindowEnd: expectedWindowEnd,
            recheckInterval: safetyDue < defaultNextDue ? safetySweepInterval : nil,
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
            return max(baseRecheck, 5 * 60)
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
    /// Optional absolute ceiling after cap-bypass candidates are included. This
    /// lets background audio use a seven-feed routine budget while allowing urgent
    /// release-window feeds through only up to a ten-feed safety ceiling.
    public var maxTotalSelections: Int?
    /// States that should be selected even after the normal budget is full. These
    /// candidates do not consume budget slots.
    public var capBypassStates: Set<FeedRefreshWindowState>
    /// States that should get the first protected slots when a budget is tight.
    /// This is intentionally separate from capBypassStates: protected candidates
    /// still consume budget, but they are tried before ordinary backlog work.
    public var protectedStates: Set<FeedRefreshWindowState>
    public var minimumProtectedSelections: Int
    /// Candidate indices, in oldest-first order, that have already waited long
    /// enough to receive a bounded fairness reservation. They consume ordinary
    /// budget slots and therefore replace lower-priority repeated selections
    /// rather than expanding background work.
    public var fairnessCandidateIndices: [Int]
    public var minimumFairnessSelections: Int

    public init(
        maxSelections: Int?,
        maxTotalSelections: Int? = nil,
        capBypassStates: Set<FeedRefreshWindowState> = [],
        protectedStates: Set<FeedRefreshWindowState> = [],
        minimumProtectedSelections: Int = 0,
        fairnessCandidateIndices: [Int] = [],
        minimumFairnessSelections: Int = 0
    ) {
        self.maxSelections = maxSelections
        self.maxTotalSelections = maxTotalSelections
        self.capBypassStates = capBypassStates
        self.protectedStates = protectedStates
        self.minimumProtectedSelections = minimumProtectedSelections
        self.fairnessCandidateIndices = fairnessCandidateIndices
        self.minimumFairnessSelections = minimumFairnessSelections
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

        if policy.minimumFairnessSelections > 0
            || (!policy.protectedStates.isEmpty
                && policy.minimumProtectedSelections > 0) {
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
            let totalLimitReached = policy.maxTotalSelections.map { selected.count >= $0 } ?? false
            if totalLimitReached {
                deferred.append(candidate)
            } else if policy.capBypassStates.contains(state(candidate)) {
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
        let totalLimit = policy.maxTotalSelections
            .flatMap { $0 > 0 ? $0 : nil }
            ?? Int.max
        let fairnessLimit = min(
            maxSelections,
            totalLimit,
            max(0, policy.minimumFairnessSelections)
        )
        let fairnessIndices = policy.fairnessCandidateIndices
            .filter { candidates.indices.contains($0) }
            .prefix(fairnessLimit)
        let fairnessIndexSet = Set(fairnessIndices)
        let protectedLimit = min(
            max(0, maxSelections - fairnessIndices.count),
            max(0, policy.minimumProtectedSelections)
        )
        let protectedIndices = indexedCandidates
            .filter {
                !fairnessIndexSet.contains($0.offset)
                    && policy.protectedStates.contains(state($0.element))
            }
            .prefix(protectedLimit)
            .map { $0.offset }
        let protectedIndexSet = Set(protectedIndices).union(fairnessIndexSet)

        var remainingBudget =
            maxSelections - fairnessIndices.count - protectedIndices.count
        var selectedIndices = Array(fairnessIndices) + protectedIndices
        var reservedIndexSet = protectedIndexSet

        // A fairness reservation may replace a repeatedly selected pre/active
        // window candidate, but never a feed that is already in missed-release
        // recovery. Protect those first inside the same absolute ceiling.
        if !fairnessIndices.isEmpty,
           policy.capBypassStates.contains(.missedRelease) {
            for (index, candidate) in indexedCandidates
            where !reservedIndexSet.contains(index)
                && state(candidate) == .missedRelease
                && selectedIndices.count < totalLimit {
                selectedIndices.append(index)
                reservedIndexSet.insert(index)
            }
        }

        for (index, candidate) in indexedCandidates
        where !reservedIndexSet.contains(index) {
            let candidateState = state(candidate)
            let totalLimitReached = policy.maxTotalSelections.map { selectedIndices.count >= $0 } ?? false
            if totalLimitReached {
                continue
            } else if policy.capBypassStates.contains(candidateState) {
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

        // Surveillance / unreliable / fallback feeds have no real predicted schedule, so
        // "overdue" doesn't mean an episode is waiting and accumulated staleness shouldn't let
        // a dormant no-pattern feed climb above genuinely-fresh release-window feeds. Otherwise
        // a short window (esp. an uncapped BGProcessing sweep that iOS grants only seconds of)
        // gets spent polling backlog ahead of real content. Suppress overdue entirely and cap
        // staleness hard for these states so release-window feeds always sort first.
        let lowValueSurveillance = isSurveillanceState(prediction.state)

        if let lastFetchedAt {
            let hoursSinceFetch = max(0, now.timeIntervalSince(lastFetchedAt) / 3600)
            let stalenessBoost = min(lowValueSurveillance ? 6 : 18, hoursSinceFetch / 2)
            if stalenessBoost >= 1 {
                score += stalenessBoost
                factors.append("stale for \(Int(hoursSinceFetch.rounded()))h")
            }
        } else {
            score += 12
            factors.append("never fetched")
        }

        let overdueMinutes = max(0, now.timeIntervalSince(prediction.nextDueAt) / 60)
        let overdueBoost = lowValueSurveillance ? 0 : min(25, overdueMinutes / 5)
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

    /// Low-value states with no reliable predicted schedule. Their staleness/overdue boosts
    /// are suppressed (see `priority`) so a dormant no-pattern feed can't outrank genuinely-
    /// fresh release-window feeds and consume a short/constrained refresh window ahead of them.
    private static func isSurveillanceState(_ state: FeedRefreshWindowState) -> Bool {
        switch state {
        case .randomSurveillance, .unreliableDates, .fallback:
            return true
        case .missedRelease, .activeWindow, .preWindow, .learning, .quiet:
            return false
        }
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

    /// The newest episode for display/download. Derives from `episodes` — the same source
    /// the Podcast Detail page renders (newest first), kept fresh by every merge/sync path —
    /// rather than the denormalised `latestEpisode`, which can lag behind and show a stale
    /// "Updated" date/status on the Subscriptions row. Falls back to `latestEpisode` only
    /// when the episode list is empty.
    public var newestEpisode: Episode? {
        episodes.first ?? latestEpisode
    }
    public var playedEpisodeKeys: Set<String>
    public var archivedEpisodeKeys: Set<String>
    public var notificationsEnabled: Bool
    public var autoArchiveSettings: AutoArchiveSettings
    public var downloadFilterSettings: DownloadFilterSettings
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
        self.downloadFilterSettings = .default
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
        case downloadFilterSettings
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
        downloadFilterSettings = try container.decodeIfPresent(DownloadFilterSettings.self, forKey: .downloadFilterSettings) ?? .default
    }
}

public struct DownloadFilterSettings: Equatable, Codable, Sendable {
    public var durationEnabled: Bool
    public var titleEnabled: Bool
    public var descriptionEnabled: Bool
    public var matchMode: MatchMode
    public var durationRules: [DurationRule]
    public var titleRules: [TextRule]
    public var descriptionRules: [TextRule]

    public static let `default` = DownloadFilterSettings(
        durationEnabled: false,
        titleEnabled: false,
        descriptionEnabled: false,
        matchMode: .all,
        durationRules: [],
        titleRules: [],
        descriptionRules: []
    )

    public var hasActiveFilters: Bool {
        !activeRules.isEmpty
    }

    public init(
        durationEnabled: Bool,
        titleEnabled: Bool,
        descriptionEnabled: Bool,
        matchMode: MatchMode,
        durationRules: [DurationRule],
        titleRules: [TextRule],
        descriptionRules: [TextRule]
    ) {
        self.durationEnabled = durationEnabled
        self.titleEnabled = titleEnabled
        self.descriptionEnabled = descriptionEnabled
        self.matchMode = matchMode
        self.durationRules = durationRules
        self.titleRules = titleRules
        self.descriptionRules = descriptionRules
    }

    public func evaluation(for episode: Episode) -> DownloadFilterEvaluation {
        let rules = activeRules
        guard !rules.isEmpty else { return .included }

        let excludeMatch = rules.first { rule in
            rule.behavior == .exclude && rule.matches(episode)
        }
        if let excludeMatch {
            return .skipped(reason: excludeMatch.reason)
        }

        let includeRules = rules.filter { $0.behavior == .include }
        guard !includeRules.isEmpty else { return .included }

        switch matchMode {
        case .all:
            if let failedRule = includeRules.first(where: { !$0.matches(episode) }) {
                return .skipped(reason: failedRule.failureReason)
            }
            return .included
        case .any:
            if includeRules.contains(where: { $0.matches(episode) }) {
                return .included
            }
            return .skipped(reason: "No include rule matched")
        }
    }

    public func evaluation(for observation: FeedReleaseObservation) -> DownloadFilterEvaluation {
        var episode = Episode(
            subscriptionID: Self.observationSubscriptionID,
            guid: observation.guid,
            title: observation.title,
            audioURL: observation.audioURL ?? Self.observationAudioURL
        )
        episode.description = observation.description
        episode.durationSeconds = observation.durationSeconds
        return evaluation(for: episode)
    }

    private var activeRules: [AnyDownloadFilterRule] {
        var rules: [AnyDownloadFilterRule] = []
        if durationEnabled {
            rules += durationRules.map { .duration($0) }
        }
        if titleEnabled {
            rules += titleRules
                .filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { .title($0) }
        }
        if descriptionEnabled {
            rules += descriptionRules
                .filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { .description($0) }
        }
        return rules
    }

    private static let observationSubscriptionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static let observationAudioURL = URL(string: "https://autohop.local/release-observation")!

    public enum MatchMode: String, CaseIterable, Codable, Sendable {
        case all
        case any

        public var title: String {
            switch self {
            case .all: return "All"
            case .any: return "Any"
            }
        }
    }

    public enum RuleBehavior: String, CaseIterable, Codable, Sendable {
        case include
        case exclude

        public var title: String {
            switch self {
            case .include: return "Include"
            case .exclude: return "Exclude"
            }
        }
    }

    public struct DurationRule: Identifiable, Equatable, Codable, Sendable {
        public var id: UUID
        public var behavior: RuleBehavior
        public var comparison: Comparison
        public var minutes: Int

        public init(id: UUID = UUID(), behavior: RuleBehavior = .include, comparison: Comparison = .longerThan, minutes: Int = 40) {
            self.id = id
            self.behavior = behavior
            self.comparison = comparison
            self.minutes = min(300, max(1, minutes))
        }

        public enum Comparison: String, CaseIterable, Codable, Sendable {
            case longerThan
            case shorterThan

            public var title: String {
                switch self {
                case .longerThan: return "Longer than"
                case .shorterThan: return "Shorter than"
                }
            }
        }
    }

    public struct TextRule: Identifiable, Equatable, Codable, Sendable {
        public var id: UUID
        public var behavior: RuleBehavior
        public var operation: Operation
        public var term: String

        public init(id: UUID = UUID(), behavior: RuleBehavior = .include, operation: Operation = .contains, term: String = "") {
            self.id = id
            self.behavior = behavior
            self.operation = operation
            self.term = term
        }

        public enum Operation: String, CaseIterable, Codable, Sendable {
            case contains
            case doesNotContain

            public var title: String {
                switch self {
                case .contains: return "Contains"
                case .doesNotContain: return "Does not contain"
                }
            }
        }
    }
}

public enum DownloadFilterEvaluation: Equatable, Sendable {
    case included
    case skipped(reason: String)

    public var isIncluded: Bool {
        if case .included = self { return true }
        return false
    }

    public var skipReason: String? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

private enum AnyDownloadFilterRule {
    case duration(DownloadFilterSettings.DurationRule)
    case title(DownloadFilterSettings.TextRule)
    case description(DownloadFilterSettings.TextRule)

    var behavior: DownloadFilterSettings.RuleBehavior {
        switch self {
        case .duration(let rule): return rule.behavior
        case .title(let rule): return rule.behavior
        case .description(let rule): return rule.behavior
        }
    }

    var reason: String {
        switch self {
        case .duration(let rule):
            return "Duration \(rule.comparison.title.lowercased()) \(rule.minutes) min"
        case .title(let rule):
            return "Title \(rule.operation.title.lowercased()) \"\(rule.term)\""
        case .description(let rule):
            return "Description \(rule.operation.title.lowercased()) \"\(rule.term)\""
        }
    }

    var failureReason: String {
        switch self {
        case .duration(let rule):
            return "Not \(rule.comparison.title.lowercased()) \(rule.minutes) min"
        case .title(let rule):
            return "Title does not match \"\(rule.term)\""
        case .description(let rule):
            return "Description does not match \"\(rule.term)\""
        }
    }

    func matches(_ episode: Episode) -> Bool {
        switch self {
        case .duration(let rule):
            guard let seconds = episode.durationSeconds else { return false }
            let minutes = seconds / 60
            switch rule.comparison {
            case .longerThan: return minutes > Double(rule.minutes)
            case .shorterThan: return minutes < Double(rule.minutes)
            }
        case .title(let rule):
            return matchesText(episode.title, rule: rule)
        case .description(let rule):
            return matchesText(episode.description ?? "", rule: rule)
        }
    }

    private func matchesText(_ value: String, rule: DownloadFilterSettings.TextRule) -> Bool {
        let haystack = value.localizedLowercase
        let needle = rule.term.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return true }
        let contains = haystack.contains(needle)
        switch rule.operation {
        case .contains: return contains
        case .doesNotContain: return !contains
        }
    }
}
