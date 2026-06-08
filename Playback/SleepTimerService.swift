import Combine
import Foundation

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

    // MARK: - Callbacks (wired by AppState)

    /// Called with a 0-1 volume scalar during the 5-second fade before sleep. Called with 1.0
    /// when the timer is cancelled or a new episode starts (volume reset).
    var onFadeVolume: ((Float) -> Void)?

    /// Called when the timer fires and playback should pause.
    var onPause: (() -> Void)?

    // MARK: - Constants

    private let fadeDuration: TimeInterval = 5
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

    // MARK: - Tick (called every 0.5 s by AppState's onTimeUpdate)

    /// Advances the countdown by 0.5 s. Applies a linear volume fade in the final 5 seconds.
    /// Returns true if the timer just fired (playback should pause via the `onPause` callback).
    @discardableResult
    func tick() -> Bool {
        guard timeRemaining >= 0 else { return false }

        timeRemaining -= 0.5

        // Linear fade in the final `fadeDuration` seconds.
        if timeRemaining < fadeDuration {
            let fraction = Float(max(0, timeRemaining / fadeDuration))
            onFadeVolume?(fraction)
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

    // MARK: - Episode finished (called by AppState.handleEpisodeFinished)

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

    // MARK: - Auto-restart (called by AppState when playback starts or resumes)

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
