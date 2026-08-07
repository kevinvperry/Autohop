import Combine
import Foundation

// AI CONTEXT — Playback/SleepTimerService.swift (MIT — original Autohop code;
// feature set informed by Pocket Casts but independently authored, see NOTICE).
// Owned by PlaybackCoordinator; driven by PlaybackEngine's 0.5 s time tick via
// tick(). Two modes: fixed duration (with +5 min extend) and end-of-N-episodes
// (the playback completion workflow calls episodeFinished()). Fires onFadeVolume
// with a 0–1 scalar over the last 30 s (smooth fade → PlaybackEngine.setVolume),
// then onPause. If the user resumes within 5 minutes of the timer firing
// (autoRestartWindow), the previous mode restarts automatically.

/// Manages sleep timer state for Autohop.
///
/// Supports two modes:
///   - `.duration`: counts down a fixed number of seconds, then pauses playback.
///   - `.endOfEpisode`: pauses after N episodes finish naturally.
///
/// The service is driven by the playback engine's 0.5 s `onTimeUpdate` tick
/// (via `tick()`). All methods must be called on the main actor.
@MainActor
final class SleepTimerService: ObservableObject {

    // MARK: - Mode

    enum Mode {
        case duration(TimeInterval)
        case endOfEpisode(count: Int)
    }

    // MARK: - Published state

    /// Seconds remaining in duration mode. -1 when inactive.
    @Published private(set) var timeRemaining: TimeInterval = -1

    /// Episodes remaining before sleep. 0 when inactive.
    @Published private(set) var episodesRemaining: Int = 0

    var isActive: Bool { timeRemaining >= 0 || episodesRemaining > 0 }
    var isDurationMode: Bool { timeRemaining >= 0 }
    var isEpisodeMode: Bool { episodesRemaining > 0 }

    // MARK: - Auto-restart state

    /// When the timer last fired (either mode). Used to gate the 5-minute auto-restart window.
    private(set) var firedAt: Date?

    /// The mode that was active when the timer last fired. Used to auto-restart.
    private(set) var lastMode: Mode?

    // MARK: - Callbacks (wired by PlaybackCoordinator)

    /// Called with a 0-1 volume scalar during the 30-second fade before sleep. Called with 1.0
    /// when the timer is cancelled or a new episode starts (volume reset).
    var onFadeVolume: ((Float) -> Void)?

    /// Called when the timer fires and playback should pause.
    var onPause: (() -> Void)?

    // MARK: - Constants

    /// Shared by the manual timer and recurring Sleep Schedule so both sleep
    /// experiences use the same deliberately gradual envelope.
    static let gradualFadeDuration: TimeInterval = 30
    private let autoRestartWindow: TimeInterval = 5 * 60   // 5 minutes

    // MARK: - Actions

    func start(mode: Mode) {
        lastMode = mode
        firedAt = nil
        switch mode {
        case .duration(let seconds):
            timeRemaining = max(0, seconds)
            episodesRemaining = 0
        case .endOfEpisode(let count):
            timeRemaining = -1
            episodesRemaining = max(1, count)
        }
        // Snap volume back to full in case we're starting fresh mid-fade.
        onFadeVolume?(1.0)
    }

    /// Cancel the timer. Pass `userInitiated: false` for system-side cancellation that
    /// should preserve auto-restart eligibility (e.g. a route-change pause).
    func cancel(userInitiated: Bool = true) {
        timeRemaining = -1
        episodesRemaining = 0
        onFadeVolume?(1.0)
        if userInitiated {
            firedAt = nil
            lastMode = nil
        }
    }

    /// Extend the active duration countdown by `minutes`. No-op in episode mode.
    func extend(by minutes: Double) {
        guard timeRemaining >= 0 else { return }
        timeRemaining += minutes * 60
        // If we're extending mid-fade, snap volume back to full so the user can hear audio.
        onFadeVolume?(1.0)
    }

    // MARK: - Tick (called by PlaybackCoordinator's 0.5 s time pipeline)

    /// Converts remaining fade time into a smoothstep volume scalar. Smoothstep
    /// avoids an audible corner at either end while remaining monotonic and
    /// reaching true silence at the deadline.
    static func gradualFadeVolume(remaining: TimeInterval) -> Float {
        let normalized = max(0, min(1, remaining / gradualFadeDuration))
        return Float(normalized * normalized * (3 - (2 * normalized)))
    }

    /// Advances the countdown by 0.5 s. Applies a smooth volume fade in the
    /// final 30 seconds.
    /// Returns true if the timer just fired (playback should pause via the `onPause` callback).
    @discardableResult
    func tick() -> Bool {
        guard timeRemaining >= 0 else { return false }

        timeRemaining -= 0.5

        if timeRemaining < Self.gradualFadeDuration {
            onFadeVolume?(Self.gradualFadeVolume(remaining: timeRemaining))
        }

        if timeRemaining <= 0 {
            timeRemaining = -1
            firedAt = Date()
            onFadeVolume?(0)
            onPause?()
            return true
        }
        return false
    }

    // MARK: - Episode finished (called by EpisodeCompletionWorkflow)

    /// Notifies the service that an episode finished naturally.
    /// Returns true if the timer has now expired and playback should **not** advance.
    @discardableResult
    func episodeFinished() -> Bool {
        guard episodesRemaining > 0 else { return false }
        episodesRemaining -= 1
        if episodesRemaining == 0 {
            firedAt = Date()
            onPause?()  // volume is already at 1.0 in this mode — no fade
            return true
        }
        return false
    }

    // MARK: - Auto-restart (called by playback start/transport workflows)

    /// If the timer fired recently and the user has resumed playback within the
    /// auto-restart window, restarts the timer with the same mode.
    /// Returns true if the timer was restarted.
    @discardableResult
    func checkAutoRestart() -> Bool {
        guard let fired = firedAt,
              let mode = lastMode,
              Date().timeIntervalSince(fired) < autoRestartWindow,
              !isActive
        else { return false }
        start(mode: mode)
        return true
    }
}
