import AVFoundation
import Combine
import Foundation

// AI CONTEXT — Playback/SleepScheduleService.swift (MIT — original Autohop
// code). "Sleep Schedule": the recurring nightly counterpart to the one-shot
// SleepTimerService. Owned by AppState; configured from AppSettings
// (sleepSchedule* fields) and driven by PlaybackEngine's 0.5 s onTimeUpdate
// tick via tick(). When playback starts inside the nightly window the service
// arms a cycle: after the configured duration (or at episode end in
// end-of-episode mode) it fires onPrompt (AppState pauses playback) and plays
// a gentle 60 s chime sequence through SleepScheduleChimePlayer. Any play
// command while prompting counts as "yes" (AppState calls userResponded() and
// resumes; the cycle restarts). If the chime finishes with no response, the
// user is assumed asleep: onAsleep fires and the session ends — playback is
// already paused at the prompt point, so the morning resume position is
// exactly where the prompt fired. A manual SleepTimerService activation
// suspends the schedule for the rest of the session (suspendForSession,
// called by AppState's tick). All methods must be called on the main actor.
@MainActor
final class SleepScheduleService: ObservableObject {

    // MARK: - Configuration (mirrors AppSettings.sleepSchedule* fields)

    struct Config: Equatable {
        var enabled: Bool
        /// Window start/end as minutes from midnight (e.g. 21:00 = 1260). The
        /// window may span midnight. Equal start and end = always in window.
        var startMinutes: Int
        var endMinutes: Int
        /// Minutes of playback between prompts. 0 = prompt at end of episode.
        var durationMinutes: Int

        var isEndOfEpisodeMode: Bool { durationMinutes <= 0 }
    }

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        /// Counting down playback seconds until the next prompt.
        case counting(remaining: TimeInterval)
        /// End-of-episode mode: waiting for the current episode to finish.
        case armedForEpisodeEnd
        /// Paused, chime playing, waiting up to 60 s for a "yes".
        case prompting(atEpisodeBoundary: Bool)
    }

    @Published private(set) var phase: Phase = .idle

    /// True while the "Are you still listening?" prompt is active.
    var isPrompting: Bool {
        if case .prompting = phase { return true }
        return false
    }

    /// Manual Sleep Timer was used — schedule stands down until the next
    /// playback session starts inside the window.
    private(set) var suspendedForSession = false

    private(set) var config = Config(enabled: false, startMinutes: 21 * 60, endMinutes: 6 * 60, durationMinutes: 20)

    // MARK: - Callbacks (wired by AppState)

    /// Fired when the duration elapses: AppState should pause playback. The
    /// chime starts immediately after.
    var onPrompt: (() -> Void)?

    /// Fired when the grace period passes with no response. Parameter is true
    /// when the prompt fired at an episode boundary (nothing to resume into).
    var onAsleep: ((_ atEpisodeBoundary: Bool) -> Void)?

    // MARK: - Internals

    private let chimePlayer = SleepScheduleChimePlayer()
    private var graceBackupTask: Task<Void, Never>?
    private let graceBackupSeconds: TimeInterval = 75   // safety net behind the 60 s chime

    // MARK: - Configuration updates

    /// Applies new settings. If the schedule was just enabled mid-session and
    /// we're playing inside the window, arm immediately.
    func updateConfig(_ newConfig: Config, isPlaying: Bool) {
        guard newConfig != config else { return }
        config = newConfig
        if !config.enabled {
            reset()
            return
        }
        // Re-arm with the new duration unless mid-prompt.
        if isPrompting { return }
        if isPlaying, !suspendedForSession, isWithinWindow() {
            arm()
        } else if !isPlaying {
            phase = .idle
        }
    }

    // MARK: - Session lifecycle (called by AppState)

    /// A fresh playback session started (startPlayback succeeded). Clears any
    /// manual-timer suspension and arms if inside the window.
    func playbackStarted() {
        suspendedForSession = false
        cancelPromptArtifacts()
        guard config.enabled, isWithinWindow() else {
            phase = .idle
            return
        }
        arm()
    }

    /// Playback resumed after a pause (same session). Arms only if idle —
    /// an active countdown keeps its remaining time.
    func playbackResumed() {
        guard config.enabled, !suspendedForSession, isWithinWindow() else { return }
        if case .idle = phase { arm() }
    }

    /// The user set the manual Sleep Timer: stand down for this session.
    func suspendForSession() {
        guard !suspendedForSession else { return }
        suspendedForSession = true
        cancelPromptArtifacts()
        phase = .idle
    }

    /// Hard reset (schedule disabled, or playback session torn down).
    func reset() {
        suspendedForSession = false
        cancelPromptArtifacts()
        phase = .idle
    }

    // MARK: - Tick (called every 0.5 s by AppState's onTimeUpdate)

    func tick(isPlaying: Bool) {
        guard case .counting(let remaining) = phase, isPlaying else { return }
        let next = remaining - 0.5
        if next <= 0 {
            beginPrompt(atEpisodeBoundary: false)
        } else {
            phase = .counting(remaining: next)
        }
    }

    // MARK: - Episode boundary (called by AppState.handleEpisodeFinished)

    /// Returns true when the schedule wants to prompt instead of auto-advancing
    /// to the next episode (end-of-episode mode only).
    @discardableResult
    func episodeFinished() -> Bool {
        guard case .armedForEpisodeEnd = phase else { return false }
        beginPrompt(atEpisodeBoundary: true)
        return true
    }

    // MARK: - "Yes" response (called by AppState's resume paths)

    /// The user issued a play command while prompting. Stops the chime and
    /// re-arms a fresh cycle. Returns true if the prompt fired at an episode
    /// boundary (caller should advance to the next episode rather than resume).
    @discardableResult
    func userResponded() -> Bool {
        guard case .prompting(let atEpisodeBoundary) = phase else { return false }
        cancelPromptArtifacts()
        arm()
        return atEpisodeBoundary
    }

    // MARK: - Window maths

    /// True when `date` falls inside the configured nightly window. A window
    /// spanning midnight (start > end) is handled; start == end means the
    /// window is always active.
    func isWithinWindow(_ date: Date = Date()) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let start = config.startMinutes
        let end = config.endMinutes
        if start == end { return true }
        if start < end {
            return nowMinutes >= start && nowMinutes < end
        }
        // Spans midnight, e.g. 21:00–06:00.
        return nowMinutes >= start || nowMinutes < end
    }

    // MARK: - Private

    private func arm() {
        if config.isEndOfEpisodeMode {
            phase = .armedForEpisodeEnd
        } else {
            phase = .counting(remaining: TimeInterval(config.durationMinutes) * 60)
        }
    }

    private func beginPrompt(atEpisodeBoundary: Bool) {
        phase = .prompting(atEpisodeBoundary: atEpisodeBoundary)
        onPrompt?()
        chimePlayer.play { [weak self] in
            Task { @MainActor in self?.assumeAsleep() }
        }
        graceBackupTask?.cancel()
        graceBackupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.graceBackupSeconds ?? 75))
            guard !Task.isCancelled else { return }
            self?.assumeAsleep()
        }
    }

    private func assumeAsleep() {
        guard case .prompting(let atEpisodeBoundary) = phase else { return }
        cancelPromptArtifacts()
        // Session is over — playbackStarted() re-arms on the next session.
        phase = .idle
        onAsleep?(atEpisodeBoundary)
    }

    private func cancelPromptArtifacts() {
        chimePlayer.stop()
        graceBackupTask?.cancel()
        graceBackupTask = nil
    }
}

// MARK: - Chime player

/// Plays the 60-second "Are you still listening?" prompt audio: a gentle
/// two-note chime at 0 s, 20 s and 40 s with silence between, generated as a
/// single in-memory WAV so AVAudioPlayer keeps the audio session rendering for
/// the whole grace period (which also keeps the app from being suspended while
/// backgrounded). The completion fires when the full 60 s plays out with no
/// interruption — i.e. the user did not respond.
@MainActor
final class SleepScheduleChimePlayer: NSObject, AVAudioPlayerDelegate {

    private var player: AVAudioPlayer?
    private var onFinished: (() -> Void)?

    private static let sampleRate = 22050.0
    private static let totalSeconds = 60.0
    private static let chimeOffsets: [Double] = [0, 20, 40]

    func play(onFinished: @escaping () -> Void) {
        stop()
        self.onFinished = onFinished
        do {
            let player = try AVAudioPlayer(data: Self.chimeWAVData)
            player.delegate = self
            player.volume = 0.6
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // Audio failed — fall back to the service's backup grace task.
            self.player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        onFinished = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            let callback = self.onFinished
            self.player = nil
            self.onFinished = nil
            callback?()
        }
    }

    // MARK: - Generated audio

    /// 60 s mono 16-bit WAV: soft E5→C5 sine chime (≈1.6 s, exponential decay)
    /// repeated at each offset. Built once and cached.
    private static let chimeWAVData: Data = {
        let sampleRate = SleepScheduleChimePlayer.sampleRate
        let totalFrames = Int(SleepScheduleChimePlayer.totalSeconds * sampleRate)
        var samples = [Int16](repeating: 0, count: totalFrames)

        func addTone(frequency: Double, startSecond: Double, duration: Double, amplitude: Double) {
            let startFrame = Int(startSecond * sampleRate)
            let frames = Int(duration * sampleRate)
            for i in 0..<frames {
                let frame = startFrame + i
                guard frame < totalFrames else { break }
                let t = Double(i) / sampleRate
                let envelope = exp(-3.2 * t) * min(1.0, t / 0.015)   // fast attack, gentle decay
                let value = sin(2 * .pi * frequency * t) * envelope * amplitude
                let mixed = Double(samples[frame]) + value * Double(Int16.max)
                samples[frame] = Int16(max(Double(Int16.min), min(Double(Int16.max), mixed)))
            }
        }

        for offset in SleepScheduleChimePlayer.chimeOffsets {
            addTone(frequency: 659.25, startSecond: offset, duration: 1.4, amplitude: 0.32)        // E5
            addTone(frequency: 523.25, startSecond: offset + 0.45, duration: 1.6, amplitude: 0.30) // C5
        }

        // Minimal PCM WAV container.
        var data = Data()
        let byteRate = UInt32(sampleRate) * 2
        let dataSize = UInt32(samples.count * 2)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(16)
        append16(1)                       // PCM
        append16(1)                       // mono
        append(UInt32(sampleRate))
        append(byteRate)
        append16(2)                       // block align
        append16(16)                      // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }()
}
