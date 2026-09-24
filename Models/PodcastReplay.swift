import Foundation

// AI CONTEXT — Shared Podcast Replay policy and convergent session journal.
// Settings live inside the already-synced AutoArchiveSettings payload. Only the
// session owner assigns release slots; all devices may resolve reservations and
// edit configuration. Merge joins monotonic outcomes/progress independently of
// configuration timestamps. Missing payload means disabled, never a reset command.
// Files/download state are local; reservations are logical queue membership.
// Calendar schedules use ISO-independent Calendar weekday numbers (Sun=1) and
// unique minutes after midnight in the stored time zone. Missing calendarSchedule
// preserves legacy everyDays recurrence. DST gaps move to the next valid time;
// repeated wall-clock times release once. Never merge old cadence cursors into
// a newly edited schedule; journal outcomes still converge across cadence edits.
// Binge mode seeds one episode, then keeps at most one unstarted successor.
// Durable per-release startedAt merges monotonically; resume cannot fan out.
// Capacity excludes ONE most-recently-started unresolved release in Binge only.
public struct PodcastReplay: Codable, Equatable, Sendable {
    public struct CalendarSchedule: Codable, Equatable, Sendable {
        public private(set) var weekdays: [Int]
        public private(set) var minutes: [Int]

        public init?(weekdays: [Int], minutes: [Int]) {
            let days = Set(weekdays.filter { (1...7).contains($0) }).sorted()
            let times = Set(minutes.filter { (0..<1440).contains($0) }).sorted()
            guard !days.isEmpty, !times.isEmpty else { return nil }
            self.weekdays = days; self.minutes = times
        }
        private enum CodingKeys: String, CodingKey { case weekdays, minutes }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let schedule = Self(weekdays: try values.decode([Int].self, forKey: .weekdays),
                                      minutes: try values.decode([Int].self, forKey: .minutes)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Replay requires at least one valid weekday and release time"))
            }
            self = schedule
        }
        /// Inclusive boundary supports a start date that falls on an unselected
        /// day. Iterating local days preserves wall-clock times through DST.
        public func nextDate(onOrAfter boundary: Date, timeZoneID: String) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
            let start = calendar.startOfDay(for: boundary)
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                      weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
                let candidates = minutes.compactMap { minute -> Date? in
                    guard let date = calendar.nextDate(after: day.addingTimeInterval(-1),
                        matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                        calendar.isDate(date, inSameDayAs: day), date >= boundary else { return nil }
                    return date
                }
                if let next = candidates.min() { return next }
            }
            return nil
        }
    }
    public struct Release: Codable, Equatable, Sendable {
        public var sequence: Int
        public var episode: Episode
        public var due: Date
        public var resolved: Bool = false
        public var resolvedAt: Date? = nil
        public var reservedAt: Date? = nil
        public var startedAt: Date? = nil
        public var pin: QueuePinState? = nil
        public var pinEditedAt: Date? = nil
        public var pinEditID: String? = nil
        public var key: String { episode.audioURL.absoluteString }
    }
    public var sessionID: UUID
    public var ownerID: String
    public var createdAt: Date
    public var editedAt: Date
    public var editID: UUID
    public var enabled: Bool = true
    public var start: Episode
    public var firstRelease: Date
    public var everyDays: Int
    public var calendarSchedule: CalendarSchedule? = nil
    public var bingeMode: Bool? = nil
    public var isBinge: Bool { bingeMode == true }
    public var timeZoneID: String
    public var notifyCaughtUp: Bool = true
    public var keptSchedule: Bool = false
    public var promptIssued: Bool = false
    public var releases: [Release] = []
    public var nextDue: Date
    public var progressVersion: Int = 0

    public init(start: Episode, firstRelease: Date, everyDays: Int, ownerID: String,
                timeZoneID: String = TimeZone.current.identifier, now: Date = Date()) {
        sessionID = UUID(); editID = UUID(); self.ownerID = ownerID
        createdAt = now; editedAt = now; self.start = Self.portable(start)
        self.firstRelease = firstRelease; nextDue = firstRelease
        self.everyDays = max(1, everyDays); self.timeZoneID = timeZoneID
    }
    public var outstanding: [Release] { releases.filter { !$0.resolved }.sorted { $0.sequence < $1.sequence } }
    public func contains(_ episode: Episode) -> Bool { outstanding.contains { $0.key == episode.audioURL.absoluteString } }
    public mutating func edit(now: Date = Date()) { editedAt = now; editID = UUID() }
    public static func portable(_ episode: Episode) -> Episode {
        var copy = episode
        copy.description = nil; copy.subtitle = nil; copy.chapters = []
        copy.localFileURL = nil; copy.localFileName = nil; copy.downloadState = .notDownloaded
        return copy
    }
    public static func merged(_ lhs: Self?, _ rhs: Self?) -> Self? {
        guard let lhs else { return rhs }; guard let rhs else { return lhs }
        if lhs.sessionID != rhs.sessionID {
            return (lhs.createdAt, lhs.sessionID.uuidString) > (rhs.createdAt, rhs.sessionID.uuidString) ? lhs : rhs
        }
        var result = (lhs.editedAt, lhs.editID.uuidString) > (rhs.editedAt, rhs.editID.uuidString) ? lhs : rhs
        var releases = Dictionary(lhs.releases.map { ($0.sequence, $0) }, uniquingKeysWith: { a, _ in a })
        for remote in rhs.releases {
            if var local = releases[remote.sequence] {
                // A single owner should never assign conflicting identities. A
                // deterministic tie-break keeps malformed/concurrent data convergent.
                if local.key == remote.key {
                    local.resolved = local.resolved || remote.resolved
                    if let started = remote.startedAt { local.startedAt = min(local.startedAt ?? started, started) }
                    if let remoteDate = remote.resolvedAt { local.resolvedAt = max(local.resolvedAt ?? remoteDate, remoteDate) }
                    if (remote.pinEditedAt ?? .distantPast, remote.pinEditID ?? "") > (local.pinEditedAt ?? .distantPast, local.pinEditID ?? "") {
                        local.pin = remote.pin; local.pinEditedAt = remote.pinEditedAt; local.pinEditID = remote.pinEditID
                    }
                }
                else { local = local.key < remote.key ? local : remote }
                releases[remote.sequence] = local
            } else { releases[remote.sequence] = remote }
        }
        result.releases = releases.values.sorted { $0.sequence < $1.sequence }
        result.keptSchedule = lhs.keptSchedule || rhs.keptSchedule
        result.promptIssued = lhs.promptIssued || rhs.promptIssued
        let progress = lhs.progressVersion > rhs.progressVersion ? lhs : rhs
        result.progressVersion = max(lhs.progressVersion, rhs.progressVersion)
        if lhs.firstRelease == rhs.firstRelease, lhs.everyDays == rhs.everyDays,
           lhs.calendarSchedule == rhs.calendarSchedule, lhs.isBinge == rhs.isBinge {
            result.nextDue = lhs.progressVersion == rhs.progressVersion ? max(lhs.nextDue, rhs.nextDue) : progress.nextDue
        }
        // Otherwise retain the configuration winner's nextDue. A later cursor
        // produced under the old cadence must not skip the newly selected slots.
        return result
    }
    public func nextDate(after date: Date) -> Date {
        if let calendarSchedule {
            return calendarSchedule.nextDate(onOrAfter: date.addingTimeInterval(1), timeZoneID: timeZoneID) ?? .distantFuture
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let anchor = calendar.dateComponents([.hour, .minute], from: firstRelease)
        let day = calendar.date(byAdding: .day, value: max(1, everyDays), to: calendar.startOfDay(for: date))!
        return calendar.nextDate(after: day.addingTimeInterval(-1), matching: anchor,
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first)!
    }
    public func candidates(in subscription: Subscription) -> [Episode] {
        let assigned = Set(releases.map(\.key))
        let anchor = releases.max(by: { $0.sequence < $1.sequence })?.episode ?? start
        let hasAssigned = !releases.isEmpty
        var seen = Set<String>()
        return subscription.episodes.filter { episode in
            let key = episode.audioURL.absoluteString
            guard !assigned.contains(key), seen.insert(key).inserted else { return false }
            if key == anchor.audioURL.absoluteString { return !hasAssigned }
            return Self.order(episode) > Self.order(anchor)
        }.sorted { Self.order($0) < Self.order($1) }
    }
    private static func order(_ episode: Episode) -> (Date, String) {
        (episode.publishedAt ?? .distantPast, episode.audioURL.absoluteString)
    }
    public func matchingCandidates(in subscription: Subscription) -> [Episode] {
        candidates(in: subscription).filter { subscription.downloadFilterSettings.evaluation(for: $0).isIncluded }
    }
    public func hasUnknownDuration(in subscription: Subscription) -> Bool {
        guard subscription.downloadFilterSettings.durationEnabled else { return false }
        var otherFilters = subscription.downloadFilterSettings
        otherFilters.durationEnabled = false
        return candidates(in: subscription).contains {
            $0.durationSeconds == nil && otherFilters.evaluation(for: $0).isIncluded
        }
    }
    public func caughtUp(in subscription: Subscription) -> Bool {
        !releases.isEmpty && outstanding.isEmpty && !hasUnknownDuration(in: subscription)
            && matchingCandidates(in: subscription).isEmpty
    }
    public func confirmedCaughtUp(in subscription: Subscription) -> Bool {
        guard caughtUp(in: subscription), let fetched = subscription.refreshStats.lastFetchedAt else { return false }
        return fetched >= (releases.compactMap(\.resolvedAt).max() ?? createdAt)
    }
    /// Historical progress must not seek a new Replay pass to the old end point.
    /// Once playback starts in this reservation, normal saved progress applies.
    public func resumeTime(for episode: Episode, savedTime: TimeInterval) -> TimeInterval {
        guard enabled, let release = outstanding.first(where: { $0.key == episode.audioURL.absoluteString }) else { return savedTime }
        return (episode.lastPlayedAt ?? .distantPast) < (release.reservedAt ?? createdAt) ? 0 : savedTime
    }
    /// A successful start is a durable event, not an instantaneous playing flag.
    /// Pauses, repeated starts and old history cannot author extra release slots.
    public mutating func recordStart(of episode: Episode, at date: Date) {
        guard enabled, let index = releases.firstIndex(where: { $0.key == episode.audioURL.absoluteString && !$0.resolved }),
              date >= (releases[index].reservedAt ?? createdAt), releases[index].startedAt == nil else { return }
        releases[index].startedAt = date
    }
    public var bingePlayingKey: String? {
        outstanding.filter { $0.startedAt != nil }.max {
            ($0.startedAt!, $0.sequence) < ($1.startedAt!, $1.sequence)
        }?.key
    }
    private mutating func reserveBinge(in subscription: Subscription, now: Date) {
        // Existing scheduled reservations survive a mode change. Do not add a
        // successor until those unstarted episodes have begun or been archived.
        guard !outstanding.contains(where: { $0.startedAt == nil }) else { return }
        let limit = subscription.autoArchiveSettings.episodeLimit.rawValue
        let assigned = Set(outstanding.map(\.key))
        let existing = subscription.episodes.filter {
            !assigned.contains($0.audioURL.absoluteString) && $0.playedState != .played && $0.playedState != .archived &&
            ($0.downloadState == .downloaded || $0.downloadState == .queued || $0.downloadState == .downloading)
        }
        let waiting = outstanding.count - (bingePlayingKey == nil ? 0 : 1) + existing.count
        var otherFilters = subscription.downloadFilterSettings; otherFilters.durationEnabled = false
        for episode in candidates(in: subscription) {
            if subscription.downloadFilterSettings.durationEnabled, episode.durationSeconds == nil,
               otherFilters.evaluation(for: episode).isIncluded { return }
            guard subscription.downloadFilterSettings.evaluation(for: episode).isIncluded else { continue }
            // Reuse a selected episode already downloaded/queued; adopting it
            // into Replay does not consume an additional capacity place.
            let adoptingExisting = existing.contains { $0.audioURL == episode.audioURL } ? 1 : 0
            guard limit == 0 || waiting - adoptingExisting < limit else { return }
            releases.append(Release(sequence: (releases.last?.sequence ?? -1) + 1,
                episode: Self.portable(episode), due: now, reservedAt: now))
            progressVersion += 1
            return
        }
    }
    /// Assign at most a bounded batch. Reservations themselves are the durable
    /// download outbox, so a crash cannot advance the cursor without retaining work.
    public mutating func reserve(in subscription: Subscription, now: Date, batchLimit: Int = 16) {
        guard enabled, !subscription.excludeFromAutoFeedRefresh else { return }
        if isBinge { reserveBinge(in: subscription, now: now); return }
        let limit = subscription.autoArchiveSettings.episodeLimit.rawValue
        let assigned = Set(outstanding.map(\.key))
        let existing = subscription.episodes.filter {
            !assigned.contains($0.audioURL.absoluteString) && $0.playedState != .played && $0.playedState != .archived &&
            ($0.downloadState == .downloaded || $0.downloadState == .queued || $0.downloadState == .downloading)
        }.count
        let capacity = limit == 0 ? batchLimit : max(0, limit - outstanding.count - existing)
        var remaining = min(capacity, batchLimit)
        var nonDurationFilters = subscription.downloadFilterSettings
        nonDurationFilters.durationEnabled = false
        for episode in candidates(in: subscription) {
            guard remaining > 0, nextDue <= now else { break }
            if subscription.downloadFilterSettings.durationEnabled, episode.durationSeconds == nil,
               nonDurationFilters.evaluation(for: episode).isIncluded { break }
            guard subscription.downloadFilterSettings.evaluation(for: episode).isIncluded else { continue }
            remaining -= 1
            releases.append(Release(sequence: (releases.last?.sequence ?? -1) + 1,
                                    episode: Self.portable(episode), due: nextDue, reservedAt: now))
            nextDue = nextDate(after: nextDue); progressVersion += 1
        }
        // Empty slots at the live frontier never create unlimited future debt.
        if caughtUp(in: subscription), nextDue <= now {
            while nextDue <= now { nextDue = nextDate(after: nextDue) }
            progressVersion += 1
        }
    }
}

public extension Subscription {
    /// Logical released queue entries retain local availability where present.
    /// Portable identities let a newly synced device display the same sequence
    /// before it has fetched the full catalogue or downloaded the media.
    var replayQueueEpisodes: [Episode] {
        guard let replay = autoArchiveSettings.replay else { return [] }
        return replay.outstanding.map { release in
            var episode = episodes.first { $0.audioURL == release.episode.audioURL } ?? release.episode
            episode.subscriptionID = id
            episode.playedState = .unplayed
            return episode
        }
    }
}
