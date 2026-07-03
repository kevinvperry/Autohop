import Foundation

// AI CONTEXT — PlaybackCore/PlaybackSessionPolicy.swift
// Phase 0 item 4 of Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md, delivered as a
// POLICY extraction: every playback DECISION that was previously inlined in
// AppState's orchestration (effective preference incl. browse-feed + Shared
// Listening overrides, resume-vs-start-skip resolution, speed cycling /
// normalization, chapter prev/next navigation) now lives here, pure and
// platform-neutral, so tvOS/watch playback makes identical decisions.
// AppState's methods delegate the decisions and keep EFFECT EXECUTION (engine
// calls, NowPlaying, sleep services, stats/history credits, store writes) —
// it remains the iOS composition root. The proposal's fuller ambition (moving
// the session STATE — currentPlayerEpisode/isPlaying — behind a core object)
// is deliberately deferred: those are @Published on AppState and observed by
// ~24 views, so relocating them is an invalidation-semantics change that needs
// Kevin's app-target compile checkpoints and view-by-view migration, not a
// blind batch edit. See the proposal STATUS header for the running plan.
// SEMANTICS ARE CONTRACTS: each function is an exact port of historical
// AppState behavior and is pinned by Tests/PlaybackSessionPolicyTests.swift —
// a change here changes playback behavior on every surface.
public enum PlaybackSessionPolicy {

    // MARK: - Effective preference

    /// The preference playback must actually use for a subscription.
    /// - Browse-only (non-subscribed) feeds always follow the live global
    ///   default — they never carry user-customised settings of their own.
    /// - Shared Listening (when `sharedListeningSpeed` is non-nil) overrides
    ///   speed and forces Trim Silence off; per-subscription settings are
    ///   untouched and resume when the mode ends.
    public static func effectivePreference(
        subscriptionPreference: PlaybackPreference,
        isBrowseFeed: Bool,
        defaultPreference: PlaybackPreference,
        sharedListeningSpeed: Double?
    ) -> PlaybackPreference {
        var preference = isBrowseFeed ? defaultPreference : subscriptionPreference
        if let sharedListeningSpeed {
            preference.speed = sharedListeningSpeed
            preference.trimSilence = .off
        }
        return preference
    }

    // MARK: - Start resolution (resume vs start-skip)

    public struct StartResolution: Equatable {
        /// Non-nil when the engine must seek after `play()` (a mid-episode
        /// resume overrides the start-skip offset).
        public var seekTarget: TimeInterval?
        /// What the UI/Now Playing/history should report as the position at
        /// start — never 0 when a start-skip applies, so surfaces don't flash
        /// 0:00 until the first tick.
        public var reportedStartTime: TimeInterval
        /// True when this counts as a fresh "episode started" for stats
        /// (resuming a partially played episode is not a new start).
        public var isFreshStart: Bool
    }

    /// Exact port of the historical startPlayback rule: a resume time beyond
    /// the start-skip wins and seeks; otherwise playback begins at the
    /// start-skip offset (the engine already applied it) and counts as fresh.
    public static func startResolution(
        resumeTime: TimeInterval,
        startSkipSeconds: TimeInterval
    ) -> StartResolution {
        if resumeTime > startSkipSeconds {
            return StartResolution(seekTarget: resumeTime, reportedStartTime: resumeTime, isFreshStart: false)
        }
        return StartResolution(seekTarget: nil, reportedStartTime: startSkipSeconds, isFreshStart: true)
    }

    // MARK: - Speed selection

    /// The next speed in the cycle after `current` (± 0.01 tolerance when
    /// locating the current option; unknown speeds cycle from the first
    /// option), wrapping to the start. nil only when `options` is empty.
    public static func cycledSpeed(
        after current: Double,
        options: [Double] = PlaybackPreference.speedOptions
    ) -> Double? {
        guard !options.isEmpty else { return nil }
        let currentIndex = options.firstIndex { abs($0 - current) < 0.01 } ?? options.startIndex
        let nextIndex = options.index(after: currentIndex)
        return nextIndex == options.endIndex ? options[options.startIndex] : options[nextIndex]
    }

    /// The option closest to a requested speed (e.g. a lock-screen playback-
    /// rate command that may not match Autohop's 0.1 steps). Falls back to the
    /// request itself only when `options` is empty.
    public static func normalizedSpeed(
        closestTo requested: Double,
        options: [Double] = PlaybackPreference.speedOptions
    ) -> Double {
        options.min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }

    // MARK: - Chapter navigation

    /// Start time of the chapter before `current` within the ACTIVE (filter-
    /// applied) chapter list; nil at the first chapter or when `current` isn't
    /// in the list. Identity is by chapter `position`, matching the historical
    /// AppState navigation.
    public static func previousChapterStart(from current: Chapter, in activeChapters: [Chapter]) -> TimeInterval? {
        guard let index = activeChapters.firstIndex(where: { $0.position == current.position }),
              index > 0
        else { return nil }
        return activeChapters[index - 1].startSeconds
    }

    /// Start time of the chapter after `current` within the active list; nil
    /// at the last chapter or when `current` isn't in the list.
    public static func nextChapterStart(from current: Chapter, in activeChapters: [Chapter]) -> TimeInterval? {
        guard let index = activeChapters.firstIndex(where: { $0.position == current.position }),
              index < activeChapters.count - 1
        else { return nil }
        return activeChapters[index + 1].startSeconds
    }
}
