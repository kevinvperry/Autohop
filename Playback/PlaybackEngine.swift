// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Portions of this file are architecturally derived from Pocket Casts for iOS
// (https://github.com/Automattic/pocket-casts-ios), © Automattic, Inc.
// Used under the Mozilla Public License, v. 2.0.
//
// Specifically, the vocal boost signal chain — high-pass filter → dynamics processor
// → peak limiter, assembled from Apple system Audio Units — follows the architecture
// of EffectsPlayer.swift in the Pocket Casts iOS project. No Pocket Casts source code
// is copied verbatim; the derivation is architectural. The notice is included out of
// caution and transparency.

import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

// ============================================================================
// AI CONTEXT — Playback/PlaybackEngine.swift  (LICENSE: MPL-2.0, see header)
//
// PURPOSE: The audio/video playback core. PlaybackCoordinator owns callback
// installation and authoritative session state; named playback workflows invoke
// transport/preference operations through PlaybackControlling.
//
// TWO PLAYBACK PATHS — the central design decision of this file:
//  1. AVPlayer path ("standard"): all VIDEO episodes, and audio when Vocal
//     Boost, Trim Silence, Mono Audio, and Volume Adjustment are off. Speed via
//     AVPlayer.rate. It shares
//     the delayed route-loss pause logic with the engine path, but does not need
//     buffer-loop restarts.
//  2. AVAudioEngine path ("engine"): audio when Vocal Boost or Trim Silence is
//     active. A background buffer-read loop (engineReadQueue, bounded by an
//     8-slot semaphore) reads the local AVAudioFile, runs buffers through
//     SilenceDetector, and schedules them on AVAudioPlayerNode behind the
//     chain: time-pitch (speed) → high-pass 180 Hz → dynamics processor →
//     peak limiter (the Pocket Casts-derived vocal boost chain; stages are
//     bypassed per VocalBoostLevel). Changing a setting mid-play rebuilds the
//     path while preserving position.
// AVPLAYER RATE INVARIANT: Keep defaultRate equal to the effective podcast
// speed whenever the standard path is configured. AVKit presentation changes
// can call plain play(), which resumes at defaultRate rather than retaining a
// transient playImmediately(atRate:) value. StreamingPlaybackEngine follows
// the same invariant for tvOS, preserving cross-platform playback semantics.
// BUFFER BACKPRESSURE DIAGNOSTICS: an ordinary 4096-frame/48 kHz buffer spans
// ~85 ms, so waits are warned only above 250 ms (~3 buffers). The 2-second
// semaphore timeout remains the actual stuck-engine recovery boundary. Do not
// lower the warning below one buffer duration or overnight logs become noise.
//
// ALSO OWNS: AVAudioSession configuration (spoken-audio mode when boost on),
// interruption and route-change handling (AirPod removal must not auto-resume:
// pausedByRouteChange / wasPlayingBeforeInterruption guards; active engine-path
// route switches restart the buffer loop from the current position after a
// brief stabilization delay, including messy iOS `unknown` / `categoryChange`
// AirPods events, before the render watchdog has to recover silence),
// start/end skip (real file time, fires onAutoSkip), disabled-chapter skipping
// per ChapterFilter, and a render watchdog that detects a running-but-silent
// engine and recovers it. Route-change invariant: `.oldDeviceUnavailable`
// schedules a short confirmation delay before pausing, so AirPods/Speaker route
// storms do not immediately stop playback; a real built-in-speaker fallback
// still pauses and prevents auto-resume. `.newDeviceAvailable`, settled
// non-built-in route changes, and same-output category/unknown route churn may
// be coalesced for 400 ms so duplicate notifications cannot start competing
// restart/reassert work. Buffer timeout diagnostics carry buffer/route generations
// and engine/node state, making stale-loop and stopped-renderer failures separable.
// Route recovery restarts only the active AVAudioEngine buffer loop, debounced
// and delayed, from
// currentPlaybackTime(). Route-loss confirmation cancels stale restart timers;
// if a replacement route appears inside that window, the restart is rescheduled
// after the replacement route settles.
// Do not make headphone removal auto-resume while improving route recovery.
// SEEK-TO-END INVARIANT: PlaybackSeekWorkflow classifies a seek within 0.25 s
// of duration as completion and stops this engine before calling
// EpisodeCompletionWorkflow. Never
// start an AVAudioFile buffer loop at EOF: frame-position fallback would otherwise
// reset to zero and make the UI clock/end state diverge from audible playback.
// Chapters present at play() time drive skip filtering immediately; chapters
// that arrive LATER (external podcast:chapters fetched after playback starts,
// P7) are applied to the live session via
// updateChapters(_:filter:for:), which updates currentEpisode.chapters +
// currentFilter only while the same episode is still playing.
//
// INVARIANTS:
//  - Plays local files only (download-first); never streams.
//  - onTimeUpdate ticks ~0.5 s on both paths — PlaybackCoordinator derives
//    history/Stats, sleep services, Now Playing, and position persistence from
//    this single tick.
//  - Video Vocal Boost stays on AVPlayer via an audioMix; track lookup uses
//    async `loadTracks(withMediaType:)`, and live setting changes apply only if
//    the same player item + preference level are still current when loading
//    finishes.
//  - Engine-path time is tracked in FILE seconds via .dataRendered callbacks
//    (engineCurrentFileSeconds); trimmed frames mean engine time ≠ wall time.
//  - setVolume() is the sleep-timer fade hook on whichever path is active.
//  - PHASE 0 (tvOS proposal §4.2): the PlaybackControlling protocol MOVED
//    verbatim to PlaybackCore/PlaybackControlling.swift (AutohopCore) so other
//    platforms can compile against the seam; this engine is unchanged apart
//    from the new `capabilities` witness (.iOSFull). Do not re-declare the
//    protocol here.
// ============================================================================

final class PlaybackEngine: PlaybackControlling {
    private let chapterService: ChapterServicing
    private let queueService: QueueServicing
    private let logger = AppLogger.shared

    /// Full local-file engine: DSP effects + video + sleep timer; streaming
    /// stays off on iPhone until the Tier 1 "instant play" feature is built
    /// (PlaybackCapabilities.iOSFull, tvOS proposal §4.2 move 4).
    var capabilities: PlaybackCapabilities { .iOSFull }

    // MARK: - AVPlayer (standard path)

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var finishObserver: NSObjectProtocol?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var playerRateObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?

    // MARK: - AVAudioEngine (engine path: strong vocal boost and/or trim silence)

    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioTimePitch: AVAudioUnitTimePitch?
    // Dynamics chain (Pocket Casts-derived): high-pass → dynamics processor → peak limiter
    private var audioHighPass: AVAudioUnitEffect?
    private var audioDynamics: AVAudioUnitEffect?
    private var audioPeakLimiter: AVAudioUnitEffect?
    /// Final per-subscription gain stage. AVAudioUnitEQ.globalGain is expressed
    /// directly in dB and supports amplification without altering system volume.
    private var audioVolumeAdjustment: AVAudioUnitEQ?
    private var audioFile: AVAudioFile?
    private var engineTimer: DispatchSourceTimer?
    private var engineIsPlaying = false
    private var engineUsesEngine = false   // true whenever the engine path is active

    // Buffer read loop
    private let engineReadQueue = DispatchQueue(
        label: "au.com.autohop.engine.read",
        qos: .userInitiated
    )
    private var engineReadCancelled = false
    // Read by the buffer loop on its serial queue (same pattern as engineReadCancelled):
    // while paused the player node consumes nothing, so slot waits time out by design
    // and must not be treated as stalls.
    private var engineReadPaused = false
    private var engineReadFinished = false          // set on main thread after read loop exits
    /// Invalidates callbacks from a stopped/route-replaced buffer loop. Semaphore
    /// slots are always returned, but stale completions cannot advance playback
    /// time, finish the episode, or launch a competing recovery.
    private var engineBufferGeneration = 0
    private var engineBufferSemaphore = DispatchSemaphore(value: 0)
    private let maxEngineBufferSlots = 8

    // Accurate time tracking: updated via .dataRendered completion callbacks
    private var engineCurrentFileSeconds: TimeInterval = 0
    private var engineAnchorFileSeconds: TimeInterval = 0  // file position when current loop started

    // MARK: - Shared state

    private var durationSeconds: TimeInterval = 0
    private var pausedAtSeconds: TimeInterval = 0
    private var didFinishCurrentEpisode = false
    private var sessionObserversInstalled = false
    // Set while an oldDeviceUnavailable route loss is pending/confirmed; cleared
    // when a replacement output arrives or the user resumes manually. Prevents
    // interruptionEnded(.shouldResume) from auto-resuming after AirPod removal.
    private var pausedByRouteChange = false
    // Set at interruption start so .ended only resumes if audio was actually playing beforehand.
    // Guards against background services (feed refresh, downloads) briefly touching the audio
    // session and causing iOS to fire interruptionEnded(.shouldResume) when we weren't playing.
    private var wasPlayingBeforeInterruption = false

    // Render watchdog: track the last wall-clock time a .dataRendered callback fired so the
    // 0.5 s GCD timer can detect a "silent engine" (running but not rendering) and recover.
    private var lastRenderedAt: CFAbsoluteTime = 0
    private var resumedAt: CFAbsoluteTime = 0
    private var lastRecoveryAt: CFAbsoluteTime = 0
    private var engineRecoveryTask: Task<Void, Never>?
    private var lastRouteRestartAt: CFAbsoluteTime = 0
    private var routeLossPauseGeneration = 0
    private var routeRestartGeneration = 0
    private var routeRestartScheduled = false
    private var hasPendingRouteLossPause = false
    private var routeRestartDeferredByRouteLoss: (reason: String, output: String)?
    private var lastRouteEventFingerprint = ""
    private var lastRouteEventOutputIdentifier = ""
    private var lastRouteEventAt: CFAbsoluteTime = 0
    private var routeChangeCoalesceGeneration = 0
    private let routeChangeCoalesceDelay: TimeInterval = 0.25
    private let engineRenderStallThreshold: TimeInterval = 2.5
    private let engineReadFinishedEndTolerance: TimeInterval = 3.0
    private let routeLossPauseDelay: TimeInterval = 0.9
    private let routeRestartStabilizationDelay: TimeInterval = 0.75

    private(set) var currentEpisode: Episode?
    private var currentFilter: ChapterFilter?
    private var currentPreference: PlaybackPreference?

    var onEpisodeFinished: ((Episode) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackInterrupted: (() -> Void)?
    var onPlaybackResumed: (() -> Void)?
    /// Fired after a removed output device returns (e.g. AirPods reinserted).
    /// PlaybackCoordinator asks PlaybackPreferenceWorkflow to refresh the full
    /// Now Playing card so this app re-claims the
    /// system's now-playing slot BEFORE the user presses the AirPods stem —
    /// the 2026-07-12 "audio hijack" fix (a stem-press after reinsertion was
    /// sometimes falling through to Apple Music). See
    /// scheduleNowPlayingReassertAfterRouteRestore for the full mechanism.
    var onRouteRestored: (() -> Void)?
    var onManualSkipForward: ((TimeInterval) -> Void)?
    var onAutoSkip: ((TimeInterval) -> Void)?
    var onTrimSilenceSaved: ((TimeInterval) -> Void)?

    var isPlaying: Bool {
        engineIsPlaying || (player?.rate ?? 0 > 0)
    }

    var videoPlayer: AVPlayer? { player }

    // MARK: - Init

    init(chapterService: ChapterServicing, queueService: QueueServicing) {
        self.chapterService = chapterService
        self.queueService = queueService
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removePlayerObservers()
        player?.pause()
    }

    // MARK: - Play

    func play(_ episode: Episode, preference: PlaybackPreference, filter: ChapterFilter) async throws {
        try await startPlayback(episode: episode, preference: preference, filter: filter, resumeAt: nil)
    }

    /// Starts (or rebuilds) playback. `resumeAt` overrides the start position: it is `nil` for a
    /// fresh play() — in which case the start-skip preference applies and `onAutoSkip` fires — and
    /// set to the current position when a live trim/boost change forces a path rebuild, so the
    /// listener stays exactly where they were and start-skip is not re-applied.
    private func startPlayback(
        episode: Episode,
        preference: PlaybackPreference,
        filter: ChapterFilter,
        resumeAt: TimeInterval?
    ) async throws {
        guard let localFileURL = episode.localFileURL else {
            logger.error("playback.missingFile", "Episode has no local file URL", metadata: [
                "episode": episode.title
            ])
            throw PlaybackError.missingLocalFile
        }
        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            logger.error("playback.missingFile", "Local file does not exist", metadata: [
                "episode": episode.title,
                "file": localFileURL.lastPathComponent
            ])
            throw PlaybackError.missingLocalFile
        }

        configureAudioSession(vocalBoostLevel: preference.vocalBoostLevel)
        stop(resetEpisode: false)

        let startPosition = resumeAt ?? preference.startSkipSeconds

        // Audio episodes use the AVAudioEngine path whenever vocal boost (any level) or
        // trim silence is active — the dynamics chain requires engine-level processing.
        // Video always stays on AVPlayer (VideoPlayer view requires it).
        let useEngine = episode.mediaKind == .audio
            && (preference.vocalBoostLevel != .off
                || preference.trimSilence != .off
                || preference.audioChannelMode == .mono
                || preference.volumeAdjustment != 0)

        if useEngine {
            // AVAudioFile gives us duration synchronously — no await needed, which means
            // this entire branch runs on the caller's actor (main) with no thread hop.
            // That eliminates the data race between startEnginePlayback writing state
            // and the GCD timer reading it on the main thread.
            try startEnginePlayback(
                episode: episode,
                preference: preference,
                filter: filter,
                localFileURL: localFileURL,
                startPosition: startPosition,
                isStartSkip: resumeAt == nil
            )
        } else {
            let asset = AVURLAsset(url: localFileURL)
            let loadedDuration = try await asset.load(.duration).seconds
            let item = AVPlayerItem(asset: asset)
            let mix = await audioGainMix(for: asset, preference: preference)
            await MainActor.run {
                item.audioMix = mix
            }

            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            newPlayer.defaultRate = validPlayerRate(preference.speed)
            player = newPlayer

            currentEpisode = episode
            currentFilter = episode.chapters.isEmpty ? nil : filter
            currentPreference = preference
            durationSeconds = loadedDuration.isFinite && loadedDuration > 0 ? loadedDuration : episode.durationSeconds ?? 0
            pausedAtSeconds = startPosition
            didFinishCurrentEpisode = false

            // Only treat this as an auto start-skip on a fresh play, not a mid-play path rebuild.
            if resumeAt == nil && preference.startSkipSeconds > 0 {
                onAutoSkip?(preference.startSkipSeconds)
            }

            installPlayerObservers(for: item)
            if pausedAtSeconds > 0 {
                await newPlayer.seek(
                    to: CMTime(seconds: pausedAtSeconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            newPlayer.playImmediately(atRate: validPlayerRate(preference.speed))

            logger.info("playback.started", "AVPlayer playback started", metadata: [
                "backend": "AVPlayer",
                "episode": episode.title,
                "mediaKind": episode.mediaKind.rawValue,
                "speed": PlaybackPreference.speedLabel(preference.speed),
                "vocalBoost": preference.vocalBoostLevel.title,
                "trimSilence": preference.trimSilence.title,
                "audioChannelMode": preference.audioChannelMode.title,
                "resumeAt": resumeAt.map { "\(Int($0))" } ?? "startSkip"
            ])
        }
    }

    /// Rebuilds the active playback path from the current position when a live vocal-boost / trim-silence
    /// change flips an AUDIO episode between the AVPlayer and AVAudioEngine paths (the engine path is
    /// required for trim silence and the full vocal-boost chain). Video always stays on AVPlayer, so it
    /// returns `false` for video and the caller applies the in-path adjustment instead.
    /// Returns `true` when a rebuild was started (the new path is built with the updated preference, so
    /// the caller must not also apply an in-path update).
    @discardableResult
    private func reconcileAudioPathForLiveChange() -> Bool {
        guard let episode = currentEpisode,
              let preference = currentPreference,
              episode.mediaKind == .audio else { return false }

        let shouldUseEngine = preference.vocalBoostLevel != .off
            || preference.trimSilence != .off
            || preference.audioChannelMode == .mono
            || preference.volumeAdjustment != 0
        guard shouldUseEngine != engineUsesEngine else { return false }

        let resumeTime = currentPlaybackTime()
        let wasPlaying = isPlaying
        let filter = currentFilter ?? ChapterFilter()

        logger.info("playback.pathReconcile", "Rebuilding playback path for live setting change", metadata: [
            "episode": episode.title,
            "from": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "to": shouldUseEngine ? "AVAudioEngine" : "AVPlayer",
            "resumeAt": "\(Int(resumeTime))"
        ])

        Task { @MainActor in
            do {
                try await self.startPlayback(episode: episode, preference: preference, filter: filter, resumeAt: resumeTime)
                // startPlayback always begins playing; honour the prior pause state.
                if !wasPlaying { self.pause() }
            } catch {
                self.logger.error("playback.pathReconcileFailed", "Failed to rebuild playback path", metadata: [
                    "episode": episode.title,
                    "error": String(describing: error)
                ])
            }
        }
        return true
    }

    // MARK: - Pause / Resume

    func pause() {
        cancelPendingRouteLossPause(reason: "pause", output: currentOutputPortName())
        routeRestartDeferredByRouteLoss = nil
        cancelPendingRouteRestart()
        pausedAtSeconds = currentPlaybackTime()
        if engineUsesEngine {
            engineReadPaused = true
            audioPlayerNode?.pause()
            engineIsPlaying = false
        } else {
            player?.pause()
        }
        logger.info("playback.pause", "Playback paused", metadata: [
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "episode": currentEpisode?.title ?? "none",
            "seconds": "\(Int(pausedAtSeconds))"
        ])
    }

    /// Drops paused AVPlayer OR AVAudioEngine resources before suspension. The
    /// engine path retains an AVAudioFile, graph, units, and scheduled buffers;
    /// long background pauses previously kept those mappings resident.
    /// PlaybackCoordinator/PlaybackMediaWorkflow retain episode/position and
    /// reconstruct the backend on next resume.
    @discardableResult
    func releasePausedPlayerResourcesForBackground(reason: String) -> TimeInterval? {
        guard !isPlaying else { return nil }
        let seconds = currentPlaybackTime()
        let episode = currentEpisode
        cancelPendingRouteLossPause(reason: "backgroundRelease", output: currentOutputPortName())
        routeRestartDeferredByRouteLoss = nil
        cancelPendingRouteRestart()
        let releasedBackend: String
        if engineUsesEngine {
            releasedBackend = "AVAudioEngine"
            stopEnginePlayback()
        } else if let player {
            releasedBackend = "AVPlayer"
            player.pause()
            removePlayerObservers()
            player.replaceCurrentItem(with: nil)
            self.player = nil
        } else {
            return nil
        }
        pausedAtSeconds = seconds
        durationSeconds = 0
        didFinishCurrentEpisode = false
        currentEpisode = nil
        currentFilter = nil
        currentPreference = nil

        logger.info("playback.backgroundRelease", "Paused AVPlayer resources released for background", metadata: [
            "reason": reason,
            "backend": releasedBackend,
            "episode": episode?.title ?? "none",
            "mediaKind": episode?.mediaKind.rawValue ?? "unknown",
            "seconds": String(format: "%.1f", seconds)
        ])
        return seconds
    }

    func resume() {
        _ = resume(notifyAfterRebuild: false)
    }

    @discardableResult
    private func resume(notifyAfterRebuild: Bool) -> Bool {
        guard currentEpisode != nil else { return false }
        let resumeStartedAt = CFAbsoluteTimeGetCurrent()
        var engineStartMs: Double = 0
        let fallbackRestartMs: Double = 0
        cancelPendingRouteLossPause(reason: "resume", output: currentOutputPortName())
        routeRestartDeferredByRouteLoss = nil
        pausedByRouteChange = false
        if engineUsesEngine {
            engineReadPaused = false
            // Route changes can stop AVAudioEngine silently. Restart it before resuming the
            // player node, otherwise the node plays but nothing gets rendered.
            if let engine = audioEngine, !engine.isRunning {
                do {
                    let stageStartedAt = CFAbsoluteTimeGetCurrent()
                    try engine.start()
                    engineStartMs = (CFAbsoluteTimeGetCurrent() - stageStartedAt) * 1000
                    logger.info("engine.restarted", "AVAudioEngine restarted after route change on resume", metadata: [
                        "episode": currentEpisode?.title ?? "none"
                    ])
                } catch {
                    // Reusing the stopped graph can fail repeatedly after a
                    // Core Audio route/interruption transition. Dispose and
                    // rebuild the full session + graph through one serialized
                    // recovery task instead of launching competing loop restarts.
                    logger.warning("engine.restartFailed", "AVAudioEngine restart failed on resume — doing full loop restart", metadata: [
                        "episode": currentEpisode?.title ?? "none",
                        "error": error.localizedDescription
                    ])
                    scheduleFullEngineRecovery(
                        reason: "resumeStartFailed",
                        error: error,
                        notifyResumed: notifyAfterRebuild
                    )
                    logResumeTiming(startedAt: resumeStartedAt, engineStartMs: engineStartMs, fallbackRestartMs: fallbackRestartMs, path: "fallback")
                    return false
                }
            }
            audioPlayerNode?.play()
            engineIsPlaying = true
            // Reset watchdog so the 2.5 s silence window starts fresh from this resume.
            let now = CFAbsoluteTimeGetCurrent()
            resumedAt = now
            lastRenderedAt = now
        } else {
            let rate = validPlayerRate(currentPreference?.speed ?? 1.0)
            player?.defaultRate = rate
            player?.playImmediately(atRate: rate)
        }
        logger.info("playback.resume", "Playback resumed", metadata: [
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "episode": currentEpisode?.title ?? "none",
            "speed": PlaybackPreference.speedLabel(currentPreference?.speed ?? 1.0)
        ])
        logResumeTiming(startedAt: resumeStartedAt, engineStartMs: engineStartMs, fallbackRestartMs: fallbackRestartMs, path: engineUsesEngine ? "engine" : "player")
        return true
    }

    /// Main-thread hang instrumentation for the synchronous resume path. Always
    /// records slow resumes; fast resumes are sampled by the normal event volume.
    private func logResumeTiming(startedAt: CFAbsoluteTime, engineStartMs: Double, fallbackRestartMs: Double, path: String) {
        let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        guard totalMs >= 100 else { return }
        logger.info("playback.resumeTiming", "Measured synchronous playback resume stages", metadata: [
            "path": path,
            "totalMs": String(format: "%.1f", totalMs),
            "engineStartMs": String(format: "%.1f", engineStartMs),
            "fallbackRestartMs": String(format: "%.1f", fallbackRestartMs),
            "episode": currentEpisode?.title ?? "none"
        ])
    }

    func skipForward(seconds: TimeInterval) {
        onManualSkipForward?(seconds)
        seekBy(seconds)
    }
    func skipBackward(seconds: TimeInterval) { seekBy(-seconds) }

    // MARK: - Seek

    func seek(to seconds: TimeInterval) {
        guard currentEpisode != nil else { return }
        let target = max(0, min(seconds, durationSeconds))
        let wasPlaying = isPlaying

        if engineUsesEngine {
            audioPlayerNode?.stop()
            stopEngineBufferLoop()
            startEngineBufferLoop(from: target, shouldPlay: wasPlaying)
            pausedAtSeconds = target
            onTimeUpdate?(target)
            logger.info("playback.seek", "Playback seek requested", metadata: [
                "backend": "AVAudioEngine",
                "episode": currentEpisode?.title ?? "none",
                "seconds": "\(Int(target))"
            ])
            return
        }

        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            guard let self else { return }
            self.pausedAtSeconds = target
            self.onTimeUpdate?(target)
            if wasPlaying {
                let rate = self.validPlayerRate(self.currentPreference?.speed ?? 1.0)
                self.player?.defaultRate = rate
                self.player?.playImmediately(atRate: rate)
            }
        }
        logger.info("playback.seek", "Playback seek requested", metadata: [
            "backend": "AVPlayer",
            "episode": currentEpisode?.title ?? "none",
            "seconds": "\(Int(target))"
        ])
    }

    // MARK: - Speed / Vocal Boost / Trim Silence

    func updatePlaybackSpeed(_ speed: Double) {
        currentPreference?.speed = speed
        if engineUsesEngine {
            // AVAudioUnitTimePitch.rate is a live Audio Unit parameter — it takes effect on
            // the next render cycle. No buffer loop restart needed or wanted.
            audioTimePitch?.rate = Float(speed)
        } else {
            let rate = validPlayerRate(speed)
            player?.defaultRate = rate
            if player?.rate != 0 {
                player?.rate = rate
            }
        }
        logger.info("playback.speed", "Playback speed updated", metadata: [
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "episode": currentEpisode?.title ?? "none",
            "speed": PlaybackPreference.speedLabel(speed)
        ])
    }

    /// AVPlayer's plain `play()` resumes at `defaultRate`. AVKit can call it
    /// while changing presentation mode, so keep the persistent and live rates
    /// aligned instead of relying only on transient `playImmediately(atRate:)`.
    private func validPlayerRate(_ speed: Double) -> Float {
        let rate = Float(speed)
        return rate.isFinite && rate > 0 ? rate : 1
    }

    func updateVocalBoost(_ level: VocalBoostLevel) {
        currentPreference?.vocalBoostLevel = level
        configureAudioSession(vocalBoostLevel: level)
        // For audio, enabling/disabling boost may flip the AVPlayer↔AVAudioEngine path; if so the
        // rebuild applies the new level itself and we must not also adjust the current path.
        if reconcileAudioPathForLiveChange() { return }
        if engineUsesEngine {
            configureVocalBoostChain(level: level)
        } else if let item = player?.currentItem,
                  let asset = item.asset as? AVURLAsset {
            // Video stays on AVPlayer: apply boost as an audioMix gain (no engine chain available).
            Task { [weak self, weak item] in
                guard let self, let item else { return }
                guard let preference = self.currentPreference else { return }
                let mix = await self.audioGainMix(for: asset, preference: preference)
                await MainActor.run { [weak self, weak item] in
                    guard let self, let item,
                          self.player?.currentItem === item,
                          self.currentPreference?.vocalBoostLevel == level else { return }
                    item.audioMix = mix
                }
            }
        }
        logger.info("playback.vocalBoost", "Vocal Boost preference updated", metadata: [
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "episode": currentEpisode?.title ?? "none",
            "level": level.title
        ])
    }

    func updateTrimSilence(_ amount: TrimSilenceAmount) {
        guard currentPreference?.trimSilence != amount else { return }
        currentPreference?.trimSilence = amount

        // Toggling trim silence on/off flips an audio episode between the AVPlayer and engine paths;
        // the rebuild starts the correct path from the current position. If no switch is needed we
        // fall through to the in-place buffer-loop restart below.
        if reconcileAudioPathForLiveChange() { return }

        guard engineUsesEngine else { return }
        // Restart the buffer loop so the new silence setting takes effect immediately.
        let time = currentPlaybackTime()
        let wasPlaying = isPlaying
        audioPlayerNode?.stop()
        stopEngineBufferLoop()
        startEngineBufferLoop(from: time, shouldPlay: wasPlaying)
        logger.info("playback.trimSilence", "Trim Silence updated mid-playback", metadata: [
            "episode": currentEpisode?.title ?? "none",
            "amount": amount.title
        ])
    }

    /// Applies a live Stereo/Mono preference. Audio episodes switch to the
    /// AVAudioEngine path when Mono is enabled; when already on that path the
    /// buffer loop restarts at the current position so no stale stereo buffers
    /// remain scheduled. Video deliberately stays on AVPlayer.
    func updateAudioChannelMode(_ mode: AudioChannelMode) {
        guard currentPreference?.audioChannelMode != mode else { return }
        currentPreference?.audioChannelMode = mode
        if reconcileAudioPathForLiveChange() { return }
        guard engineUsesEngine else { return }
        let time = currentPlaybackTime()
        let wasPlaying = isPlaying
        audioPlayerNode?.stop()
        stopEngineBufferLoop()
        startEngineBufferLoop(from: time, shouldPlay: wasPlaying)
        logger.info("playback.audioChannelMode", "Audio channel mode updated mid-playback", metadata: [
            "episode": currentEpisode?.title ?? "none",
            "mode": mode.title
        ])
    }

    /// Applies the podcast's -3...+3 dB gain independently of system volume.
    /// A non-zero adjustment forces audio onto AVAudioEngine so positive gain is
    /// real amplification; live changes then update the final EQ stage in place.
    func updateVolumeAdjustment(_ adjustment: Int) {
        let clamped = PlaybackPreference.clampedVolumeAdjustment(adjustment)
        guard currentPreference?.volumeAdjustment != clamped else { return }
        currentPreference?.volumeAdjustment = clamped
        if reconcileAudioPathForLiveChange() { return }
        if engineUsesEngine {
            configureVolumeAdjustment(clamped)
        } else if let item = player?.currentItem,
                  let asset = item.asset as? AVURLAsset,
                  let preference = currentPreference {
            Task { [weak self, weak item] in
                guard let self, let item else { return }
                let mix = await self.audioGainMix(for: asset, preference: preference)
                await MainActor.run { [weak self, weak item] in
                    guard let self, let item,
                          self.player?.currentItem === item,
                          self.currentPreference?.volumeAdjustment == clamped else { return }
                    item.audioMix = mix
                }
            }
        }
        logger.info("playback.volumeAdjustment", "Subscription volume adjustment updated", metadata: [
            "episode": currentEpisode?.title ?? "none",
            "adjustmentDB": "\(clamped)",
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer"
        ])
    }

    /// AI CONTEXT — Live settings bridge for episode trim. Updating end skip
    /// changes the finish threshold read by handleEndSkipIfNeeded immediately;
    /// start skip is stored for consistency but deliberately does not seek a
    /// session that has already started.
    func updateEpisodeTrim(startSkipSeconds: TimeInterval, endSkipSeconds: TimeInterval) {
        currentPreference?.startSkipSeconds = max(0, startSkipSeconds)
        currentPreference?.endSkipSeconds = max(0, endSkipSeconds)
        logger.info("playback.episodeTrim", "Episode trim preference updated", metadata: [
            "episode": currentEpisode?.title ?? "none",
            "startSeconds": "\(Int(max(0, startSkipSeconds)))",
            "endSeconds": "\(Int(max(0, endSkipSeconds)))"
        ])
    }

    func updateChapters(_ chapters: [Chapter], filter: ChapterFilter, for episodeID: UUID) {
        guard var episode = currentEpisode, episode.id == episodeID else { return }
        episode.chapters = chapters
        currentEpisode = episode
        currentFilter = chapters.isEmpty ? nil : filter
        logger.info("playback.chaptersUpdated", "External chapters applied mid-playback", metadata: [
            "episode": episode.title,
            "count": "\(chapters.count)"
        ])
    }

    /// AI CONTEXT — live chapter-filter bridge. Re-evaluate immediately so the
    /// persisted UI state and audible playback cannot diverge until a later tick.
    func updateChapterFilter(_ filter: ChapterFilter, for episodeID: UUID) {
        guard currentEpisode?.id == episodeID else { return }
        currentFilter = currentEpisode?.chapters.isEmpty == false ? filter : nil
        logger.info("playback.chapterFilterUpdated", "Live chapter filter applied", metadata: [
            "episode": currentEpisode?.title ?? "none",
            "skippedPositions": filter.skippedPositions.sorted().map(String.init).joined(separator: ",")
        ])
        skipDisabledChapterIfNeeded(at: currentPlaybackTime())
    }

    // MARK: - Volume

    func setVolume(_ volume: Float) {
        let v = min(1, max(0, volume))
        player?.volume = v
        audioPlayerNode?.volume = v
    }

    // MARK: - Stop

    func stop() { stop(resetEpisode: true) }

    private func stop(resetEpisode: Bool) {
        if resetEpisode {
            engineRecoveryTask?.cancel()
            engineRecoveryTask = nil
        }
        cancelPendingRouteLossPause(reason: "stop", output: currentOutputPortName())
        routeRestartDeferredByRouteLoss = nil
        cancelPendingRouteRestart()
        logger.info("playback.stop", "Playback stopped", metadata: [
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "episode": currentEpisode?.title ?? "none"
        ])
        removePlayerObservers()
        player?.pause()
        player = nil
        stopEnginePlayback()
        durationSeconds = 0
        pausedAtSeconds = 0
        didFinishCurrentEpisode = false
        if resetEpisode {
            currentEpisode = nil
            currentFilter = nil
            currentPreference = nil
        }
    }

    // MARK: - AVPlayer observers

    private func installPlayerObservers(for item: AVPlayerItem) {
        removePlayerObservers()
        let observedPlayer = player
        timeObserver = observedPlayer?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.tickTime()
        }
        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finishCurrentEpisode()
        }
        timeControlStatusObservation = observedPlayer?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player === player else { return }
                self.logAVPlayerStateChange(reason: "timeControlStatus")
            }
        }
        playerRateObservation = observedPlayer?.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player === player else { return }
                self.logAVPlayerStateChange(reason: "rate")
            }
        }
        playerItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.logAVPlayerStateChange(reason: "itemStatus")
            }
        }
    }

    private func removePlayerObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = finishObserver {
            NotificationCenter.default.removeObserver(observer)
            finishObserver = nil
        }
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        playerRateObservation?.invalidate()
        playerRateObservation = nil
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
    }

    // MARK: - AVAudioEngine setup

    private func startEnginePlayback(
        episode: Episode,
        preference: PlaybackPreference,
        filter: ChapterFilter,
        localFileURL: URL,
        startPosition: TimeInterval,
        isStartSkip: Bool
    ) throws {
        let file = try AVAudioFile(forReading: localFileURL)
        let fileDuration = Double(file.length) / file.processingFormat.sampleRate

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        // kAudioUnitSubType_AUiPodTimeOther: Apple's speech-optimised time-stretch algorithm.
        var timePitchDesc = AudioComponentDescription()
        timePitchDesc.componentType = kAudioUnitType_FormatConverter
        timePitchDesc.componentSubType = kAudioUnitSubType_AUiPodTimeOther
        timePitchDesc.componentManufacturer = kAudioUnitManufacturer_Apple
        let timePitch = AVAudioUnitTimePitch(audioComponentDescription: timePitchDesc)
        timePitch.rate = Float(preference.speed)
        timePitch.pitch = 0
        timePitch.overlap = 8

        // Dynamics chain — same architecture as Pocket Casts:
        // 1. High-pass filter: removes low-frequency rumble below 180 Hz
        // 2. Dynamics processor: compresses dynamic range so quiet voices are lifted
        // 3. Peak limiter: applies large pre-gain without clipping
        let highPass = makeAudioUnit(type: kAudioUnitType_Effect, subType: kAudioUnitSubType_HighPassFilter)
        let dynamics = makeAudioUnit(type: kAudioUnitType_Effect, subType: kAudioUnitSubType_DynamicsProcessor)
        let limiter  = makeAudioUnit(type: kAudioUnitType_Effect, subType: kAudioUnitSubType_PeakLimiter)
        let volumeAdjustment = AVAudioUnitEQ(numberOfBands: 0)

        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(highPass)
        engine.attach(dynamics)
        engine.attach(limiter)
        engine.attach(volumeAdjustment)

        let format = file.processingFormat
        // Graph: node → timePitch → highPass → dynamics → limiter → mainMixer
        engine.connect(node,      to: timePitch, format: format)
        engine.connect(timePitch, to: highPass,  format: format)
        engine.connect(highPass,  to: dynamics,  format: format)
        engine.connect(dynamics,  to: limiter,   format: format)
        engine.connect(limiter,   to: volumeAdjustment, format: format)
        engine.connect(volumeAdjustment, to: engine.mainMixerNode, format: format)

        audioEngine = engine
        audioPlayerNode = node
        audioTimePitch = timePitch
        audioHighPass = highPass
        audioDynamics = dynamics
        audioPeakLimiter = limiter
        audioVolumeAdjustment = volumeAdjustment

        configureVocalBoostChain(level: preference.vocalBoostLevel)
        configureVolumeAdjustment(preference.volumeAdjustment)
        audioFile = file
        engineUsesEngine = true
        currentEpisode = episode
        currentFilter = episode.chapters.isEmpty ? nil : filter
        currentPreference = preference
        durationSeconds = fileDuration.isFinite && fileDuration > 0
            ? fileDuration
            : episode.durationSeconds ?? 0
        pausedAtSeconds = startPosition
        didFinishCurrentEpisode = false

        // Only treat this as an auto start-skip on a fresh play, not a mid-play path rebuild.
        if isStartSkip && preference.startSkipSeconds > 0 {
            onAutoSkip?(preference.startSkipSeconds)
        }

        try engine.start()
        let now = CFAbsoluteTimeGetCurrent()
        resumedAt = now
        lastRenderedAt = now
        startEngineBufferLoop(from: pausedAtSeconds, shouldPlay: true)
        startEngineTimer()

        logger.info("playback.started", "AVAudioEngine playback started", metadata: [
            "backend": "AVAudioEngine",
            "episode": episode.title,
            "speed": PlaybackPreference.speedLabel(preference.speed),
            "vocalBoost": preference.vocalBoostLevel.title,
            "trimSilence": preference.trimSilence.title,
            "audioChannelMode": preference.audioChannelMode.title
        ])
    }

    // MARK: - Buffer read loop

    private func startEngineBufferLoop(from startSeconds: TimeInterval, shouldPlay: Bool) {
        guard let file = audioFile, let node = audioPlayerNode else { return }
        engineBufferGeneration += 1
        let generation = engineBufferGeneration

        // Seed the file-seconds tracker immediately so the scrubber shows the correct
        // start/seek position before any buffers have rendered.
        engineCurrentFileSeconds = startSeconds
        engineAnchorFileSeconds = startSeconds
        engineReadFinished = false

        let sem = DispatchSemaphore(value: maxEngineBufferSlots)
        engineBufferSemaphore = sem

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let trimAmount = currentPreference?.trimSilence ?? .off
        // Capture with the other loop policy before crossing to the serial read
        // queue. Live changes restart this generation with a new immutable value.
        let channelMode = currentPreference?.audioChannelMode ?? .stereo
        let startFrame = AVAudioFramePosition(max(0, startSeconds) * sampleRate)

        pausedAtSeconds = startSeconds
        engineIsPlaying = shouldPlay
        engineReadPaused = !shouldPlay
        if shouldPlay { node.play() }

        // NOTE: engineReadCancelled is reset to false INSIDE the async block so it only
        // clears AFTER the previous loop iteration has actually exited on the serial queue.
        // Resetting it here (synchronously) would race with the old loop still checking it.
        engineReadQueue.async { [weak self] in
            guard let self else { return }
            guard self.engineBufferGeneration == generation else { return }

            // Reset cancellation flag now that any previous loop has exited.
            self.engineReadCancelled = false

            // All AVAudioFile access happens exclusively on this queue.
            if startFrame > 0 && startFrame < file.length {
                file.framePosition = startFrame
            } else {
                file.framePosition = 0
            }

            let bufferFrameCount: AVAudioFrameCount = 4096
            var detector = SilenceDetector(amount: trimAmount)
            var needsFadeIn = true   // apply a 0→1 ramp to the very first scheduled buffer

            while !self.engineReadCancelled, self.engineBufferGeneration == generation {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: bufferFrameCount
                ) else { break }

                do {
                    try file.read(into: buffer)
                } catch {
                    // AVAudioFile.read(into:) throws at EOF by bridging a nil NSError*. Depending on
                    // the toolchain this surfaces either as an empty-domain NSError or as
                    // `Foundation._GenericObjCError`, both with code 0. Treat it as EOF only when we
                    // are actually at the end of the file — a generic error mid-file is a real failure
                    // and must still be logged as such.
                    let nsError = error as NSError
                    let isGenericNilError = nsError.code == 0 &&
                        (nsError.domain.isEmpty || nsError.domain == "Foundation._GenericObjCError")
                    let atEndOfFile = file.framePosition >= file.length
                    if isGenericNilError && atEndOfFile {
                        self.logger.info("engine.readEOF", "AVAudioFile reached end of file")
                    } else {
                        self.logger.error("engine.readFailed", "AVAudioFile read failed", metadata: [
                            "error": error.localizedDescription,
                            "domain": nsError.domain,
                            "code": String(nsError.code),
                            "framePosition": String(file.framePosition),
                            "fileLength": String(file.length)
                        ])
                    }
                    break
                }

                guard buffer.frameLength > 0 else {
                    // EOF — flush any gap buffers still in the detector. The trailing gap
                    // is re-emitted verbatim so framesRemoved is 0, but route it through the
                    // same accounting for completeness.
                    let flushed = detector.flush()
                    self.reportTrimSilenceSaved(frames: flushed.framesRemoved, sampleRate: sampleRate)
                    for buf in flushed.buffers {
                        if self.engineReadCancelled { break }
                        if channelMode == .mono { Self.foldStereoBufferToMono(buf) }
                        sem.wait()
                        if self.engineReadCancelled { sem.signal(); break }
                        node.scheduleBuffer(buf, completionCallbackType: .dataRendered) { _ in
                            sem.signal()
                        }
                    }

                    // Sentinel: 1 silent frame with .dataPlayedBack so finishCurrentEpisode
                    // fires exactly when the last real audio sample has been heard.
                    if !self.engineReadCancelled {
                        if let sentinel = AVAudioPCMBuffer(
                            pcmFormat: file.processingFormat,
                            frameCapacity: 1
                        ) {
                            sentinel.frameLength = 1
                            node.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                                DispatchQueue.main.async {
                                    guard let self, self.engineBufferGeneration == generation else { return }
                                    self.finishCurrentEpisode()
                                }
                            }
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.engineBufferGeneration == generation else { return }
                        self.engineReadFinished = true
                    }
                    return
                }

                // The file position AFTER reading this chunk = end of this chunk in the file.
                // We report it via the completion callback so the scrubber reflects the actual
                // rendered position rather than a wall-clock estimate.
                let chunkEndSeconds = Double(file.framePosition) / sampleRate

                let processed = detector.process(
                    buffer: buffer,
                    currentFrame: file.framePosition,
                    totalFrames: totalFrames,
                    sampleRate: sampleRate
                )
                let outputBuffers = processed.buffers

                // Accumulate the silence actually saved. SilenceDetector reports the NET
                // frames removed by this call (0 while a gap is still being accumulated, 0
                // when a gap is too short and re-inserted, and the dropped frames net of the
                // kept join buffers for a real gap). Summing that — instead of inferring from
                // the per-buffer input/output delta — is the fix for the over-count in
                // ASSESSMENT.md B2.
                self.reportTrimSilenceSaved(frames: processed.framesRemoved, sampleRate: sampleRate)

                for (i, buf) in outputBuffers.enumerated() {
                    if self.engineReadCancelled { break }

                    if channelMode == .mono {
                        Self.foldStereoBufferToMono(buf)
                    }

                    // Fade-in the very first buffer after every play/seek to eliminate
                    // the click/pop that occurs when audio starts or resumes abruptly.
                    if needsFadeIn && i == 0 {
                        applyFadeRamp(to: buf, fadeIn: true)
                        needsFadeIn = false
                    }

                    var semWaitStart = CFAbsoluteTimeGetCurrent()
                    // Wait up to 2 s for a buffer slot. If the engine has stopped rendering
                    // (e.g. lost audio route mid-playback), .dataRendered callbacks stop firing
                    // and the semaphore never signals — without a timeout this loop hangs forever.
                    var semResult = sem.wait(timeout: .now() + 2.0)
                    // While paused the node consumes nothing, so timeouts are expected.
                    // Keep waiting quietly — logging stalls or breaking here would spam
                    // the log every 2 s and silently drop this chunk's audio.
                    var pausedDuringWait = false
                    while semResult == .timedOut, self.engineReadPaused, !self.engineReadCancelled {
                        pausedDuringWait = true
                        semWaitStart = CFAbsoluteTimeGetCurrent()
                        semResult = sem.wait(timeout: .now() + 2.0)
                    }
                    let semWaitMs = Int((CFAbsoluteTimeGetCurrent() - semWaitStart) * 1000)
                    // AI CONTEXT — A 4096-frame buffer at 48 kHz lasts ~85 ms, so
                    // the former 80 ms warning threshold classified normal one-buffer
                    // backpressure as a stall. Warn only after 250 ms (~3 buffers);
                    // the existing 2 s timeout remains the recovery boundary.
                    if semWaitMs > 250, !pausedDuringWait, !self.hasPendingRouteLossPause {
                        self.logger.warning("engine.bufferStall", "Audio buffer loop stalled waiting for slot", metadata: [
                            "stallMs": "\(semWaitMs)",
                            "positionSecs": String(format: "%.1f", chunkEndSeconds),
                            "bufferGeneration": "\(generation)",
                            "currentBufferGeneration": "\(self.engineBufferGeneration)",
                            "routeRestartGeneration": "\(self.routeRestartGeneration)",
                            "audioEngineRunning": "\(self.audioEngine?.isRunning ?? false)",
                            "audioPlayerNodePlaying": "\(node.isPlaying)"
                        ])
                    }
                    if semResult == .timedOut {
                        // Stop requested while waiting: exit quietly, no recovery needed.
                        if self.engineReadCancelled { break }
                        // Engine is not consuming buffers. Break out and request recovery.
                        self.logger.warning("engine.bufferStall.timeout", "Buffer slot timeout — engine appears stuck, requesting restart", metadata: [
                            "positionSecs": String(format: "%.1f", chunkEndSeconds),
                            "bufferGeneration": "\(generation)",
                            "currentBufferGeneration": "\(self.engineBufferGeneration)",
                            "routeRestartGeneration": "\(self.routeRestartGeneration)",
                            "routeRestartScheduled": "\(self.routeRestartScheduled)",
                            "routeLossPending": "\(self.hasPendingRouteLossPause)",
                            "audioEngineRunning": "\(self.audioEngine?.isRunning ?? false)",
                            "audioPlayerNodePlaying": "\(node.isPlaying)"
                        ])
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  self.engineBufferGeneration == generation,
                                  !self.routeRestartScheduled,
                                  !self.hasPendingRouteLossPause else { return }
                            self.recoverSilentEngine(reason: "bufferStall")
                        }
                        break
                    }
                    if self.engineReadCancelled { sem.signal(); break }
                    node.scheduleBuffer(buf, completionCallbackType: .dataRendered) { [weak self] _ in
                        sem.signal()
                        DispatchQueue.main.async {
                            guard let self, self.engineBufferGeneration == generation else { return }
                            self.lastRenderedAt = CFAbsoluteTimeGetCurrent()
                            self.engineCurrentFileSeconds = chunkEndSeconds
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.engineBufferGeneration == generation else { return }
                self.engineReadFinished = true
            }
        }
    }

    /// AI CONTEXT — In-place stereo fold-down used only on the serial engine
    /// read queue. Averaging L+R prevents clipping and copies the centred signal
    /// back to both channels, so headphones and stereo speakers both hear the
    /// same content. Native mono files and unsupported/interleaved formats no-op.
    /// Copy with Swift's typed buffer operation; do not restore deprecated
    /// `cblas_scopy`, which opts this target into Accelerate's legacy LP64 API.
    private static func foldStereoBufferToMono(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.channelCount >= 2,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }
        let count = vDSP_Length(buffer.frameLength)
        vDSP_vadd(channels[0], 1, channels[1], 1, channels[0], 1, count)
        var half: Float = 0.5
        vDSP_vsmul(channels[0], 1, &half, channels[0], 1, count)
        channels[1].update(from: channels[0], count: Int(buffer.frameLength))
    }

    /// Convert net trimmed frames (as reported by SilenceDetector) to seconds and add
    /// them to the Stats "Trim Silence" time-saved category on the main actor. Called
    /// from the background read loop; reading `onTrimSilenceSaved` here matches the
    /// existing pattern (the closure is set once at setup).
    private func reportTrimSilenceSaved(frames: AVAudioFrameCount, sampleRate: Double) {
        guard frames > 0, sampleRate > 0 else { return }
        let savedSeconds = Double(frames) / sampleRate
        let cb = onTrimSilenceSaved
        DispatchQueue.main.async { cb?(savedSeconds) }
    }

    private func stopEngineBufferLoop() {
        engineBufferGeneration += 1
        engineReadCancelled = true
        // Unblock any semaphore.wait() in the read loop.
        for _ in 0..<(maxEngineBufferSlots + 2) { engineBufferSemaphore.signal() }
    }

    // MARK: - AVAudioEngine teardown

    private func stopEnginePlayback() {
        cancelPendingRouteRestart()
        stopEngineBufferLoop()
        engineTimer?.cancel()
        engineTimer = nil
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil
        audioPlayerNode = nil
        audioTimePitch = nil
        audioHighPass = nil
        audioDynamics = nil
        audioPeakLimiter = nil
        audioVolumeAdjustment = nil
        audioFile = nil
        engineIsPlaying = false
        engineReadPaused = false
        engineUsesEngine = false
        engineReadFinished = false
        engineCurrentFileSeconds = 0
        engineAnchorFileSeconds = 0
        lastRenderedAt = 0
        resumedAt = 0
    }

    private func engineLastRenderedAge(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> TimeInterval? {
        guard lastRenderedAt > 0 else { return nil }
        return now - max(lastRenderedAt, resumedAt)
    }

    private func engineLikelyProducingAudio(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard engineUsesEngine, engineIsPlaying else { return false }
        return audioEngine?.isRunning == true
            && audioPlayerNode?.isPlaying == true
            && (engineLastRenderedAge(now: now).map { $0 < engineRenderStallThreshold } ?? false)
    }

    private func engineSecondsFromEnd(at position: TimeInterval) -> TimeInterval? {
        guard durationSeconds > 0 else { return nil }
        return durationSeconds - position
    }

    private func enginePositionIsNearNaturalEnd(_ position: TimeInterval) -> Bool {
        guard let secondsFromEnd = engineSecondsFromEnd(at: position) else { return false }
        return secondsFromEnd <= engineReadFinishedEndTolerance
    }

    private func engineRecoveryMetadata(
        reason: String,
        position: TimeInterval,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> [String: String] {
        let lastRenderedAgeMs = engineLastRenderedAge(now: now).map { $0 * 1_000 }
        var metadata = [
            "reason": reason,
            "episode": currentEpisode?.title ?? "none",
            "positionSecs": String(format: "%.1f", position),
            "durationSecs": durationSeconds > 0 ? String(format: "%.1f", durationSeconds) : "unknown",
            "audioEngineRunning": "\(audioEngine?.isRunning ?? false)",
            "audioPlayerNodePlaying": "\(audioPlayerNode?.isPlaying ?? false)",
            "engineReadFinished": "\(engineReadFinished)",
            "engineReadPaused": "\(engineReadPaused)",
            "bufferGeneration": "\(engineBufferGeneration)",
            "routeRestartGeneration": "\(routeRestartGeneration)",
            "lastRenderedAgeMs": lastRenderedAgeMs.map { String(format: "%.0f", $0) } ?? "unknown",
            "playbackLikelyProducingAudio": "\(engineLikelyProducingAudio(now: now))"
        ]
        metadata["secondsFromEnd"] = engineSecondsFromEnd(at: position)
            .map { String(format: "%.1f", $0) } ?? "unknown"
        return metadata
    }

    @discardableResult
    private func finishReadFinishedEngineIfNearEnd(
        reason: String,
        position: TimeInterval,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard engineUsesEngine, engineIsPlaying, engineReadFinished else { return false }
        guard !engineLikelyProducingAudio(now: now) else { return false }
        guard enginePositionIsNearNaturalEnd(position) else { return false }

        logger.warning(
            "engine.readFinishedSilentFinish",
            "Engine read loop finished near EOF but output stopped; finishing episode",
            metadata: engineRecoveryMetadata(reason: reason, position: position, now: now)
        )
        finishCurrentEpisode()
        return true
    }

    /// Restart the buffer loop from the current position when the engine is running but silent.
    /// Guards against rapid repeated calls (at most once every 3 s).
    private func recoverSilentEngine(reason: String = "silentEngine") {
        guard engineUsesEngine, engineIsPlaying else { return }
        guard engineRecoveryTask == nil else {
            logger.info(
                "engine.silentRecoveryDeferred",
                "Silent-engine recovery deferred to serialized full graph recovery",
                metadata: ["reason": reason]
            )
            return
        }
        guard !routeRestartScheduled, !hasPendingRouteLossPause else {
            logger.info("engine.silentRecoveryDeferred", "Silent-engine recovery deferred to pending route coordination", metadata: [
                "reason": reason,
                "routeRestartScheduled": "\(routeRestartScheduled)",
                "routeLossPending": "\(hasPendingRouteLossPause)"
            ])
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let position = currentPlaybackTime()
        if finishReadFinishedEngineIfNearEnd(reason: reason, position: position, now: now) { return }
        guard now - lastRecoveryAt > 3.0 else { return }  // debounce rapid recovery attempts
        lastRecoveryAt = now

        let event = engineReadFinished ? "engine.readFinishedSilentRecover" : "engine.silentRecovery"
        logger.warning(
            event,
            "Engine silent — restarting buffer loop from current position",
            metadata: engineRecoveryMetadata(reason: reason, position: position, now: now)
        )

        audioPlayerNode?.stop()
        stopEngineBufferLoop()

        // Ensure the engine itself is running — route changes may have stopped it.
        if let engine = audioEngine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                logger.warning("engine.silentRecovery", "Engine restart failed during silent recovery", metadata: [
                    "error": error.localizedDescription
                ])
                scheduleFullEngineRecovery(
                    reason: "silentRecoveryStartFailed",
                    error: error,
                    notifyResumed: true
                )
                return
            }
        }

        startEngineBufferLoop(from: position, shouldPlay: true)
        resumedAt = now
        lastRenderedAt = now
    }

    /// One terminal recovery path for a stopped AVAudioEngine graph. Route,
    /// interruption, and render-watchdog handlers all converge here, so only
    /// one task may dispose/recreate the session and graph for the current
    /// episode generation.
    private func scheduleFullEngineRecovery(
        reason: String,
        error: Error,
        notifyResumed: Bool
    ) {
        guard engineRecoveryTask == nil,
              let episode = currentEpisode,
              let preference = currentPreference else {
            return
        }
        let episodeID = episode.id
        let position = currentPlaybackTime()
        let filter = currentFilter ?? ChapterFilter()
        cancelPendingRouteRestart()
        routeRestartDeferredByRouteLoss = nil
        logger.warning(
            "engine.fullRecoveryScheduled",
            "Scheduled serialized audio-session and engine-graph rebuild",
            metadata: [
                "reason": reason,
                "episode": episode.title,
                "positionSecs": String(format: "%.1f", position),
                "error": error.localizedDescription
            ]
        )

        engineRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.currentEpisode?.id == episodeID else {
                self?.engineRecoveryTask = nil
                return
            }
            defer { self.engineRecoveryTask = nil }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let session = AVAudioSession.sharedInstance()
            do {
                try? session.setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
                try await self.startPlayback(
                    episode: episode,
                    preference: preference,
                    filter: filter,
                    resumeAt: position
                )
                self.logger.info(
                    "engine.fullRecoveryCompleted",
                    "Rebuilt audio session and engine graph after restart failure",
                    metadata: [
                        "reason": reason,
                        "episode": episode.title,
                        "positionSecs": String(format: "%.1f", position),
                        "durationMs": String(
                            format: "%.1f",
                            (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
                        )
                    ]
                )
                if notifyResumed {
                    self.onPlaybackResumed?()
                }
            } catch {
                self.logger.error(
                    "engine.fullRecoveryFailed",
                    "Could not rebuild audio session and engine graph",
                    metadata: [
                        "reason": reason,
                        "episode": episode.title,
                        "positionSecs": String(format: "%.1f", position),
                        "error": String(describing: error)
                    ]
                )
            }
        }
    }

    private func startEngineTimer() {
        engineTimer?.cancel()
        engineTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tickTime() }
        timer.resume()
        engineTimer = timer
    }

    // MARK: - Dynamics chain (Vocal Boost)

    /// Configure the high-pass → dynamics → limiter chain based on the vocal boost level.
    /// All three units stay connected in the graph; unused stages are bypassed.
    /// Can be called live during playback — Audio Unit parameter changes are thread-safe.
    private func configureVocalBoostChain(level: VocalBoostLevel) {
        guard let hp = audioHighPass,
              let dyn = audioDynamics,
              let lim = audioPeakLimiter
        else { return }

        switch level {
        case .off:
            // Engine is active for trim silence — bypass all vocal boost processing.
            hp.bypass  = true
            dyn.bypass = true
            lim.bypass = true

        case .light:
            // Subtle: remove rumble + mild peak limiting (+4 dB). No dynamic compression.
            configureHighPass(hp, cutoff: 180)
            hp.bypass  = false
            dyn.bypass = true
            configureLimiter(lim, attackTime: 0.002, decayTime: 0.005, preGain: 4)
            lim.bypass = false

        case .standard:
            // Moderate: high-pass + dynamic compression + +8 dB limiter.
            configureHighPass(hp, cutoff: 180)
            hp.bypass = false
            configureDynamics(dyn)
            dyn.bypass = false
            configureLimiter(lim, attackTime: 0.002, decayTime: 0.005, preGain: 8)
            lim.bypass = false

        case .strong:
            // Maximum: full Pocket Casts chain with +11 dB pre-gain limiter.
            configureHighPass(hp, cutoff: 180)
            hp.bypass = false
            configureDynamics(dyn)
            dyn.bypass = false
            configureLimiter(lim, attackTime: 0.002, decayTime: 0.005, preGain: 11)
            lim.bypass = false
        }

        logger.info("playback.vocalBoostChain", "Dynamics chain configured", metadata: [
            "level": level.title,
            "highPassBypassed": "\(hp.bypass)",
            "dynamicsBypassed": "\(dyn.bypass)",
            "limiterBypassed": "\(lim.bypass)"
        ])
    }

    private func configureVolumeAdjustment(_ adjustment: Int) {
        let clamped = PlaybackPreference.clampedVolumeAdjustment(adjustment)
        audioVolumeAdjustment?.globalGain = Float(clamped)
    }

    private func configureHighPass(_ unit: AVAudioUnitEffect, cutoff: Float) {
        setParam(unit, param: kHipassParam_CutoffFrequency, value: cutoff)
        setParam(unit, param: kHipassParam_Resonance,       value: 0)
    }

    private func configureDynamics(_ unit: AVAudioUnitEffect) {
        // Pocket Casts settings — lifts quiet passages without over-compressing.
        setParam(unit, param: kDynamicsProcessorParam_Threshold,         value: -41)
        setParam(unit, param: kDynamicsProcessorParam_HeadRoom,          value: 40)
        setParam(unit, param: kDynamicsProcessorParam_ExpansionRatio,    value: 1)
        setParam(unit, param: kDynamicsProcessorParam_ExpansionThreshold, value: -100)
        setParam(unit, param: kDynamicsProcessorParam_AttackTime,        value: 0.05)
        setParam(unit, param: kDynamicsProcessorParam_ReleaseTime,       value: 0.2)
        setParam(unit, param: kDynamicsProcessorParam_OverallGain,       value: 0)
    }

    private func configureLimiter(_ unit: AVAudioUnitEffect,
                                   attackTime: Float, decayTime: Float, preGain: Float) {
        setParam(unit, param: kLimiterParam_AttackTime, value: attackTime)
        setParam(unit, param: kLimiterParam_DecayTime,  value: decayTime)
        setParam(unit, param: kLimiterParam_PreGain,    value: preGain)
    }

    private func setParam(_ unit: AVAudioUnitEffect,
                           param: AudioUnitParameterID, value: Float) {
        AudioUnitSetParameter(unit.audioUnit, param,
                              kAudioUnitScope_Global, 0, value, 0)
    }

    // MARK: - DSP helpers

    /// Apply a linear 0→1 (fade-in) or 1→0 (fade-out) ramp to all channels of `buffer`.
    /// Uses vDSP for SIMD-accelerated in-place multiply — same pattern as SilenceDetector.
    private func applyFadeRamp(to buffer: AVAudioPCMBuffer, fadeIn: Bool) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = vDSP_Length(buffer.frameLength)
        var ramp = [Float](repeating: 0, count: Int(n))
        if fadeIn {
            vDSP_vgen([0.0], [1.0], &ramp, 1, n)
        } else {
            vDSP_vgen([1.0], [0.0], &ramp, 1, n)
        }
        for c in 0..<Int(buffer.format.channelCount) {
            vDSP_vmul(channelData[c], 1, ramp, 1, channelData[c], 1, n)
        }
    }

    private func makeAudioUnit(type: OSType, subType: OSType) -> AVAudioUnitEffect {
        var desc = AudioComponentDescription()
        desc.componentType         = type
        desc.componentSubType      = subType
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    private func audioGainMix(for asset: AVURLAsset, preference: PlaybackPreference) async -> AVAudioMix? {
        let dbMultiplier = pow(10.0, Float(preference.volumeAdjustment) / 20.0)
        let outputGain = preference.vocalBoostLevel.outputGain * dbMultiplier
        guard abs(outputGain - 1.0) > 0.001 else { return nil }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            logger.warning("playback.vocalBoostMixFailed", "Could not load video audio tracks for Vocal Boost", metadata: [
                "level": preference.vocalBoostLevel.title,
                "error": String(describing: error)
            ])
            return nil
        }

        guard !audioTracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(outputGain, at: .zero)
            return params
        }
        return mix
    }

    // MARK: - Playback diagnostics

    func playbackDiagnosticMetadata(reason: String) -> [String: String] {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let now = CFAbsoluteTimeGetCurrent()
        var metadata: [String: String] = [
            "playbackDiagnosticReason": reason,
            "playbackBackend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "playbackEngineIsPlaying": "\(isPlaying)",
            "engineUsesEngine": "\(engineUsesEngine)",
            "engineEpisode": currentEpisode?.title ?? "none",
            "engineMediaKind": currentEpisode?.mediaKind.rawValue ?? "unknown",
            "enginePositionSecs": String(format: "%.1f", currentPlaybackTime()),
            "audioSessionCategory": session.category.rawValue,
            "audioSessionMode": session.mode.rawValue,
            "audioSessionOutput": output?.portName ?? "none",
            "audioSessionOutputType": output?.portType.rawValue ?? "none",
            "audioSessionOutputVolume": String(format: "%.2f", session.outputVolume),
            "audioSessionSecondarySilenced": "\(session.secondaryAudioShouldBeSilencedHint)",
            // Keep-alive diagnostics: if another app owns audio, iOS won't grant us the
            // background audio assertion even while our engine reports "playing".
            "audioSessionOtherAudioPlaying": "\(session.isOtherAudioPlaying)",
            "audioSessionSampleRate": String(format: "%.0f", session.sampleRate),
            "audioSessionIOBufferMs": String(format: "%.1f", session.ioBufferDuration * 1000)
        ]

        if engineUsesEngine {
            let lastRenderedAgeMs = engineLastRenderedAge(now: now).map { $0 * 1_000 }
            metadata.merge([
                "audioEngineRunning": "\(audioEngine?.isRunning ?? false)",
                "audioPlayerNodePlaying": "\(audioPlayerNode?.isPlaying ?? false)",
                "engineReadFinished": "\(engineReadFinished)",
                "engineReadPaused": "\(engineReadPaused)",
                "lastRenderedAgeMs": lastRenderedAgeMs.map { String(format: "%.0f", $0) } ?? "unknown",
                "playbackLikelyProducingAudio": "\(engineLikelyProducingAudio(now: now))"
            ]) { _, new in new }
        } else if let player {
            let currentTime = player.currentTime().seconds
            let likelyProducingAudio = player.rate > 0 && player.timeControlStatus == .playing
            metadata.merge([
                "avPlayerRate": String(format: "%.2f", player.rate),
                "avPlayerTimeControlStatus": timeControlStatusLabel(player.timeControlStatus),
                "avPlayerWaitingReason": player.reasonForWaitingToPlay?.rawValue ?? "none",
                "avPlayerItemStatus": player.currentItem.map { playerItemStatusLabel($0.status) } ?? "none",
                "avPlayerCurrentTimeSecs": String(format: "%.1f", currentTime.isFinite ? currentTime : pausedAtSeconds),
                "avPlayerItemError": player.currentItem?.error?.localizedDescription ?? "none",
                "avPlayerError": player.error?.localizedDescription ?? "none",
                "playbackLikelyProducingAudio": "\(likelyProducingAudio)"
            ]) { _, new in new }
        } else {
            metadata["playbackLikelyProducingAudio"] = "false"
            metadata["avPlayerRate"] = "none"
            metadata["avPlayerTimeControlStatus"] = "none"
        }

        return metadata
    }

    private func logAVPlayerStateChange(reason: String) {
        guard player != nil else { return }
        logger.info("playback.avPlayerState", "AVPlayer playback state changed", metadata: playbackDiagnosticMetadata(reason: reason))
    }

    private func timeControlStatusLabel(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waitingToPlayAtSpecifiedRate"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }

    private func playerItemStatusLabel(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Audio session

    private func configureAudioSession(vocalBoostLevel: VocalBoostLevel) {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = vocalBoostLevel.usesSpokenAudioMode ? .spokenAudio : .default
        do {
            try session.setCategory(.playback, mode: mode, options: [])
            try session.setActive(true)
        } catch {
            logger.warning("playback.audioSession", "Could not configure audio session", metadata: [
                "vocalBoost": vocalBoostLevel.title,
                "error": String(describing: error)
            ])
        }

        guard !sessionObserversInstalled else { return }
        sessionObserversInstalled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: session
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            var metadata = [
                "episode": currentEpisode?.title ?? "none",
                "positionSecs": String(format: "%.1f", currentPlaybackTime()),
                "wasPlaying": "\(wasPlayingBeforeInterruption)"
            ]
            metadata.merge(playbackDiagnosticMetadata(reason: "interruptionBegan")) { existing, _ in existing }

            if hasPendingRouteLossPause {
                logger.info(
                    "audio.interruptionDeferred",
                    "Audio interruption began during pending route-loss confirmation",
                    metadata: metadata
                )
                return
            }

            guard wasPlayingBeforeInterruption else {
                logger.info("audio.interruptionBeganIdle", "Audio session interrupted while playback was idle", metadata: metadata)
                return
            }

            logger.warning("audio.interruptionBegan", "Audio session interrupted", metadata: metadata)
            pause()
            onPlaybackInterrupted?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            )
            // Only resume if (a) iOS says to, (b) we were actually playing before the interruption,
            // and (c) the pause wasn't from a device removal. Without (b), background services
            // (feed refresh, downloads) that briefly touch the audio session can cause iOS to
            // fire interruptionEnded(.shouldResume) and restart playback the user had paused.
            if options.contains(.shouldResume), wasPlayingBeforeInterruption, !pausedByRouteChange {
                var metadata = [
                    "episode": currentEpisode?.title ?? "none",
                    "shouldResume": "\(options.contains(.shouldResume))",
                    "wasPlaying": "\(wasPlayingBeforeInterruption)",
                    "suppressedByRouteChange": "\(pausedByRouteChange)"
                ]
                metadata.merge(playbackDiagnosticMetadata(reason: "interruptionEndedResume")) { existing, _ in existing }
                logger.info("audio.interruptionEnded", "Audio session interruption ended, resuming playback", metadata: metadata)
                try? AVAudioSession.sharedInstance().setActive(true)
                if resume(notifyAfterRebuild: true) {
                    onPlaybackResumed?()
                }
            } else {
                var metadata = [
                    "episode": currentEpisode?.title ?? "none",
                    "shouldResume": "\(options.contains(.shouldResume))",
                    "wasPlaying": "\(wasPlayingBeforeInterruption)",
                    "suppressedByRouteChange": "\(pausedByRouteChange)"
                ]
                metadata.merge(playbackDiagnosticMetadata(reason: "interruptionEndedNoResume")) { existing, _ in existing }
                logger.info("audio.interruptionEnded", "Audio session interruption ended, no resume", metadata: metadata)
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        // AVAudioSession commonly emits old-device, new-device, category and
        // configuration notifications as one physical transition. Processing
        // each notification synchronously rebuilt/reasserted the graph several
        // times and occupied the main actor for ~800 ms per event. Keep only the
        // final settled notification in a short burst; genuine route loss still
        // has the separate 0.9 s confirmation window below.
        routeChangeCoalesceGeneration &+= 1
        let generation = routeChangeCoalesceGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + routeChangeCoalesceDelay
        ) { [weak self] in
            guard let self,
                  generation == self.routeChangeCoalesceGeneration else {
                return
            }
            self.processRouteChange(notification)
        }
    }

    private func processRouteChange(_ notification: Notification) {
        let operationStartedAt = CFAbsoluteTimeGetCurrent()
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        let routeReadStartedAt = CFAbsoluteTimeGetCurrent()
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let previousRoute = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let previousOutput = previousRoute?.outputs.first
        let newPort = output?.portName ?? "none"
        let newPortType = output?.portType.rawValue ?? "none"
        let previousPort = previousOutput?.portName ?? "none"
        let previousPortType = previousOutput?.portType.rawValue ?? "none"
        let reasonLabel = routeChangeReasonLabel(reason)
        let outputChanged = routeOutputIdentifier(output) != routeOutputIdentifier(previousOutput)
        let outputIdentifier = routeOutputIdentifier(output)
        let routeReadMs =
            (CFAbsoluteTimeGetCurrent() - routeReadStartedAt) * 1_000
        let routeFingerprint = "\(reason.rawValue)|\(outputIdentifier)|\(routeOutputIdentifier(previousOutput))"
        let routeEventNow = CFAbsoluteTimeGetCurrent()
        let isCoalescibleReason = reason == .unknown
            || reason == .categoryChange
            || reason == .routeConfigurationChange
        if isCoalescibleReason,
           !outputChanged,
           (routeFingerprint == lastRouteEventFingerprint
                || outputIdentifier == lastRouteEventOutputIdentifier),
           routeEventNow - lastRouteEventAt
                < routeRestartStabilizationDelay {
            logger.info(
                "audio.routeChangeCoalesced",
                "Coalesced duplicate same-output audio route notification",
                metadata: [
                    "reason": reasonLabel,
                    "newOutput": newPort,
                    "coalesceWindowMs": "\(Int(routeRestartStabilizationDelay * 1000))",
                    "bufferGeneration": "\(engineBufferGeneration)",
                    "routeRestartGeneration": "\(routeRestartGeneration)"
                ]
            )
            return
        }
        lastRouteEventFingerprint = routeFingerprint
        lastRouteEventOutputIdentifier = outputIdentifier
        lastRouteEventAt = routeEventNow

        let loggingStartedAt = CFAbsoluteTimeGetCurrent()
        let metadata = [
            "reason": reasonLabel,
            "newOutput": newPort,
            "newOutputType": newPortType,
            "previousOutput": previousPort,
            "previousOutputType": previousPortType,
            "outputChanged": "\(outputChanged)",
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "enginePlaying": "\(engineIsPlaying)",
            "pendingRouteLoss": "\(hasPendingRouteLossPause)",
            "episode": currentEpisode?.title ?? "none",
            "positionSecs": String(format: "%.1f", currentPlaybackTime()),
            "routeReadMs": String(format: "%.1f", routeReadMs)
        ]
        // Do not call playbackDiagnosticMetadata here. Its broad AVAudioSession
        // inspection previously sat directly in the route callback and could
        // block the main thread for hundreds of milliseconds. Focused route
        // fields above retain the evidence needed for this state transition.
        logger.warning("audio.routeChange", "Audio route changed", metadata: metadata)
        let loggingMs =
            (CFAbsoluteTimeGetCurrent() - loggingStartedAt) * 1_000

        let policyStartedAt = CFAbsoluteTimeGetCurrent()
        switch reason {
        case .oldDeviceUnavailable:
            if let output,
               AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: routeOutputIdentifier(output),
                previousOutputIdentifier:
                    previousOutput.map(routeOutputIdentifier),
                currentOutputIsBuiltIn:
                    routeOutputIsBuiltIn(output)
               ) {
                let wasRoutePaused = pausedByRouteChange
                let scheduledDeferredRestart = cancelPendingRouteLossPause(
                    reason: reasonLabel,
                    output: newPort,
                    scheduleDeferredRestart: true
                )
                pausedByRouteChange = false
                if !scheduledDeferredRestart {
                    scheduleEngineRestartAfterRouteSettles(reason: reasonLabel, output: newPort)
                }
                scheduleNowPlayingReassertAfterRouteRestore(
                    reason: reasonLabel, output: newPort, reactivateSession: wasRoutePaused
                )
            } else {
                scheduleRouteLossPause(reason: reasonLabel, output: newPort)
            }
        case .newDeviceAvailable, .routeConfigurationChange, .categoryChange, .override, .unknown:
            var scheduledDeferredRestart = false
            if let output,
               AudioRouteLossPolicy.replacementOutputIsConfirmed(
                currentOutputIdentifier: routeOutputIdentifier(output),
                previousOutputIdentifier:
                    previousOutput.map(routeOutputIdentifier),
                currentOutputIsBuiltIn: routeOutputIsBuiltIn(output),
                explicitNewDeviceSignal: reason == .newDeviceAvailable
               ) {
                let wasRoutePaused = pausedByRouteChange
                scheduledDeferredRestart = cancelPendingRouteLossPause(
                    reason: reasonLabel,
                    output: newPort,
                    scheduleDeferredRestart: true
                )
                pausedByRouteChange = false
                scheduleNowPlayingReassertAfterRouteRestore(
                    reason: reasonLabel, output: newPort, reactivateSession: wasRoutePaused
                )
            }
            if !scheduledDeferredRestart,
               outputChanged || reason == .newDeviceAvailable || hasPendingRouteLossPause {
                scheduleEngineRestartAfterRouteSettles(reason: reasonLabel, output: newPort)
            }
        default:
            break
        }
        let policyMs =
            (CFAbsoluteTimeGetCurrent() - policyStartedAt) * 1_000
        let operationMs =
            (CFAbsoluteTimeGetCurrent() - operationStartedAt) * 1_000
        if operationMs >= 100 {
            logger.warning(
                "ui.mainActorOperationSlow",
                "Audio route handling occupied the main thread",
                metadata: [
                    "operation": "audio.routeChange",
                    "durationMs": String(format: "%.1f", operationMs),
                    "reason": reasonLabel,
                    "outputChanged": "\(outputChanged)",
                    "backend": engineUsesEngine
                        ? "AVAudioEngine" : "AVPlayer",
                    "bufferGeneration": "\(engineBufferGeneration)",
                    "routeRestartGeneration": "\(routeRestartGeneration)",
                    "routeReadMs": String(format: "%.1f", routeReadMs),
                    "loggingMs": String(format: "%.1f", loggingMs),
                    "policyMs": String(format: "%.1f", policyMs)
                ]
            )
        }
    }

    private var routeReassertGeneration = 0

    /// AI CONTEXT — "Audio hijack" fix (2026-07-12, Kevin's report: removing
    /// AirPods to talk, reinserting, then pressing the stem sometimes resumed
    /// APPLE MUSIC instead of Autohop). Mechanism: an AirPods stem-press is
    /// routed by iOS to whichever app holds the now-playing slot; a
    /// route-loss pause can leave this app's audio session deactivated by the
    /// system, and by reinsertion time the slot claim is stale enough that
    /// the command falls through to the system default (Apple Music). Fix:
    /// when a removed output RETURNS, wait for the route to settle (same
    /// stabilization delay the engine restart uses, generation-guarded
    /// against route flapping), then (a) reactivate our audio session —
    /// but ONLY when our pause was route-loss-caused AND no other app is
    /// audibly playing; grabbing the session while Apple Music is deliberately
    /// playing would interrupt it, the exact hostility this fix removes —
    /// and (b) fire onRouteRestored so PlaybackCoordinator re-pushes the full
    /// Now Playing card. The other half of this incident is background
    /// TERMINATION while paused (MetricKit showed memory-pressure exits; a
    /// dead process can never receive the stem-press) — addressed separately
    /// by the relay memory-footprint work; this handles every still-alive case.
    private func scheduleNowPlayingReassertAfterRouteRestore(
        reason: String, output: String, reactivateSession: Bool
    ) {
        guard currentEpisode != nil else { return }
        routeReassertGeneration += 1
        let generation = routeReassertGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + routeRestartStabilizationDelay) { [weak self] in
            guard let self, self.routeReassertGeneration == generation else { return }
            guard self.currentEpisode != nil else { return }

            let session = AVAudioSession.sharedInstance()
            var sessionReactivated = false
            if reactivateSession, !self.isPlaying, !session.isOtherAudioPlaying {
                do {
                    try session.setActive(true)
                    sessionReactivated = true
                } catch {
                    self.logger.info("audio.routeReassertActivateFailed", "Could not reactivate audio session after route restore", metadata: [
                        "reason": reason,
                        "error": String(describing: error)
                    ])
                }
            }
            self.logger.info("audio.routeRestoredReassert", "Re-claiming Now Playing after output device returned", metadata: [
                "reason": reason,
                "newOutput": output,
                "sessionReactivated": "\(sessionReactivated)",
                "otherAudioPlaying": "\(session.isOtherAudioPlaying)",
                "isPlaying": "\(self.isPlaying)",
                "episode": self.currentEpisode?.title ?? "none"
            ])
            self.onRouteRestored?()
        }
    }

    private func scheduleRouteLossPause(reason: String, output: String) {
        cancelPendingRouteRestart()
        routeRestartDeferredByRouteLoss = nil
        routeLossPauseGeneration += 1
        let generation = routeLossPauseGeneration
        hasPendingRouteLossPause = true
        pausedByRouteChange = true

        guard isPlaying else {
            hasPendingRouteLossPause = false
            logger.info("audio.routeLossIdle", "Audio route loss while playback was idle", metadata: [
                "reason": reason,
                "newOutput": output,
                "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
                "episode": currentEpisode?.title ?? "none"
            ])
            return
        }

        logger.info("audio.routeLossPending", "Waiting briefly to confirm audio route loss", metadata: [
            "reason": reason,
            "newOutput": output,
            "episode": currentEpisode?.title ?? "none",
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "enginePlaying": "\(engineIsPlaying)",
            "delayMs": "\(Int(routeLossPauseDelay * 1000))"
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + routeLossPauseDelay) { [weak self] in
            guard let self,
                  self.hasPendingRouteLossPause,
                  self.routeLossPauseGeneration == generation
            else { return }

            self.hasPendingRouteLossPause = false
            self.routeRestartDeferredByRouteLoss = nil
            guard self.isPlaying else { return }

            self.logger.warning("audio.routeLossConfirmed", "Confirmed audio route loss; pausing playback", metadata: [
                "reason": reason,
                "newOutput": output,
                "backend": self.engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
                "episode": self.currentEpisode?.title ?? "none",
                "positionSecs": String(format: "%.1f", self.currentPlaybackTime())
            ])
            self.pause()
            self.onPlaybackInterrupted?()
        }
    }

    @discardableResult
    private func cancelPendingRouteLossPause(
        reason: String,
        output: String,
        scheduleDeferredRestart: Bool = false
    ) -> Bool {
        guard hasPendingRouteLossPause else { return false }
        hasPendingRouteLossPause = false
        routeLossPauseGeneration += 1
        let deferredRestart = routeRestartDeferredByRouteLoss
        routeRestartDeferredByRouteLoss = nil
        logger.info("audio.routeLossCancelled", "Cancelled pending audio route-loss pause", metadata: [
            "reason": reason,
            "newOutput": output,
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "hadDeferredRestart": "\(deferredRestart != nil)",
            "episode": currentEpisode?.title ?? "none"
        ])
        if scheduleDeferredRestart, let deferredRestart {
            scheduleEngineRestartAfterRouteSettles(
                reason: "\(deferredRestart.reason)->\(reason)",
                output: output
            )
            return true
        }
        return false
    }

    private func scheduleEngineRestartAfterRouteSettles(reason: String, output: String) {
        guard engineUsesEngine, engineIsPlaying else { return }
        guard !hasPendingRouteLossPause else {
            routeRestartDeferredByRouteLoss = (reason, output)
            logger.info("engine.routeRestartDeferred", "Route restart deferred while route loss is pending", metadata: [
                "reason": reason,
                "newOutput": output,
                "backend": "AVAudioEngine",
                "delayMs": "\(Int(routeRestartStabilizationDelay * 1000))",
                "episode": currentEpisode?.title ?? "none"
            ])
            return
        }

        routeRestartGeneration += 1
        let generation = routeRestartGeneration
        routeRestartScheduled = true
        logger.info("engine.routeRestartScheduled", "Scheduling engine restart after route settles", metadata: [
            "reason": reason,
            "newOutput": output,
            "episode": currentEpisode?.title ?? "none",
            "positionSecs": String(format: "%.1f", currentPlaybackTime()),
            "delayMs": "\(Int(routeRestartStabilizationDelay * 1000))"
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + routeRestartStabilizationDelay) { [weak self] in
            guard let self, self.routeRestartGeneration == generation else { return }
            self.routeRestartScheduled = false
            self.restartEngineAfterRouteChangeIfNeeded(reason: reason, output: output)
        }
    }

    private func cancelPendingRouteRestart() {
        routeRestartGeneration += 1
        routeRestartScheduled = false
    }

    private func routeOutputCanReplaceRemovedDevice(_ output: AVAudioSessionPortDescription) -> Bool {
        !routeOutputIsBuiltIn(output)
    }

    private func routeOutputIsBuiltIn(
        _ output: AVAudioSessionPortDescription
    ) -> Bool {
        output.portType == .builtInReceiver
            || output.portType == .builtInSpeaker
    }

    private func routeOutputIdentifier(_ output: AVAudioSessionPortDescription?) -> String {
        guard let output else { return "none" }
        return "\(output.portType.rawValue)|\(output.uid)|\(output.portName)"
    }

    private func currentOutputPortName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "none"
    }

    private func restartEngineAfterRouteChangeIfNeeded(reason: String, output: String) {
        guard engineUsesEngine, engineIsPlaying else { return }
        guard engineRecoveryTask == nil else {
            logger.info(
                "engine.routeRestartDeferred",
                "Route restart deferred to serialized full graph recovery",
                metadata: ["reason": reason, "newOutput": output]
            )
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let position = currentPlaybackTime()
        if finishReadFinishedEngineIfNearEnd(
            reason: "routeRestart.\(reason)",
            position: position,
            now: now
        ) { return }

        guard now - lastRouteRestartAt > 1.0 else {
            logger.info("engine.routeRestartSkipped", "Skipped route restart during debounce window", metadata: [
                "reason": reason,
                "newOutput": output,
                "episode": currentEpisode?.title ?? "none"
            ])
            return
        }
        lastRouteRestartAt = now

        logger.info("engine.routeRestart", "Restarting engine buffer loop after route change", metadata: [
            "reason": reason,
            "newOutput": output,
            "episode": currentEpisode?.title ?? "none",
            "positionSecs": String(format: "%.1f", position)
        ])

        audioPlayerNode?.stop()
        stopEngineBufferLoop()

        if let engine = audioEngine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                logger.warning("engine.routeRestartFailed", "Engine restart failed after route change", metadata: [
                    "reason": reason,
                    "newOutput": output,
                    "episode": currentEpisode?.title ?? "none",
                    "error": error.localizedDescription
                ])
                scheduleFullEngineRecovery(
                    reason: "routeRestartStartFailed.\(reason)",
                    error: error,
                    notifyResumed: true
                )
                return
            }
        }

        startEngineBufferLoop(from: position, shouldPlay: true)
        resumedAt = now
        lastRenderedAt = now
    }

    private func routeChangeReasonLabel(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown:               return "unknown"
        case .newDeviceAvailable:    return "newDeviceAvailable"
        case .oldDeviceUnavailable:  return "oldDeviceUnavailable"
        case .categoryChange:        return "categoryChange"
        case .override:              return "override"
        case .wakeFromSleep:         return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange:   return "routeConfigurationChange"
        @unknown default:            return "unknown(\(reason.rawValue))"
        }
    }

    // MARK: - Tick / time tracking

    private func tickTime() {
        guard currentEpisode != nil else { return }
        let seconds = currentPlaybackTime()
        onTimeUpdate?(seconds)
        skipDisabledChapterIfNeeded(at: seconds)
        // engineCurrentFileSeconds now tracks actual file position via .dataRendered callbacks,
        // so finishForNaturalEndIfNeeded is reliable for both paths. The sentinel buffer acts
        // as a backup in case the timer fires slightly late.
        finishForNaturalEndIfNeeded(at: seconds)

        // Render watchdog: if the engine is supposedly playing but no .dataRendered callback
        // has fired for 2.5 s since the last resume, the engine is silently stuck (e.g. after
        // a route change that stopped it without a proper notification). Recover immediately.
        if engineUsesEngine, engineIsPlaying {
            let now = CFAbsoluteTimeGetCurrent()
            let baseline = max(lastRenderedAt, resumedAt)
            if now - baseline > engineRenderStallThreshold {
                recoverSilentEngine(reason: "renderWatchdog")
            }
        }
    }

    private func currentPlaybackTime() -> TimeInterval {
        if engineUsesEngine {
            guard engineIsPlaying else { return pausedAtSeconds }
            let clamped = durationSeconds > 0
                ? min(durationSeconds, max(0, engineCurrentFileSeconds))
                : max(0, engineCurrentFileSeconds)
            pausedAtSeconds = clamped
            return clamped
        }

        let seconds = player?.currentTime().seconds ?? pausedAtSeconds
        guard seconds.isFinite else { return pausedAtSeconds }
        let clamped = durationSeconds > 0 ? min(durationSeconds, max(0, seconds)) : max(0, seconds)
        pausedAtSeconds = clamped
        return clamped
    }

    private func seekBy(_ delta: TimeInterval) {
        seek(to: currentPlaybackTime() + delta)
    }

    private func skipDisabledChapterIfNeeded(at seconds: TimeInterval) {
        guard let episode = currentEpisode,
              let filter = currentFilter,
              !finishForEndSkipIfNeeded(at: seconds, episode: episode),
              let chapter = chapterService.chapter(atTime: seconds, in: episode),
              !filter.allows(position: chapter.position)
        else { return }

        if let next = chapterService.nextActiveChapter(after: chapter.position, in: episode, filter: filter) {
            logger.info("playback.skipChapter", "Skipping disabled chapter", metadata: [
                "episode": episode.title,
                "chapter": chapter.title,
                "next": next.title
            ])
            seek(to: next.startSeconds)
        } else {
            let duration = episode.durationSeconds ?? (durationSeconds > 0 ? durationSeconds : nil)
            guard let duration else { return }
            logger.info("playback.skipChapter", "Skipping disabled final chapter", metadata: [
                "episode": episode.title,
                "chapter": chapter.title
            ])
            seek(to: duration)
        }
    }

    private func finishForEndSkipIfNeeded(at seconds: TimeInterval, episode: Episode) -> Bool {
        guard let preference = currentPreference,
              preference.endSkipSeconds > 0,
              let duration = episode.durationSeconds,
              seconds >= max(0, duration - preference.endSkipSeconds)
        else { return false }

        onAutoSkip?(preference.endSkipSeconds)
        finishCurrentEpisode()
        logger.info("playback.endSkip", "End skip reached", metadata: ["episode": episode.title])
        return true
    }

    private func finishForNaturalEndIfNeeded(at seconds: TimeInterval) {
        guard durationSeconds > 0, seconds >= durationSeconds - 0.25 else { return }
        finishCurrentEpisode()
    }

    private func finishCurrentEpisode() {
        guard !didFinishCurrentEpisode, let episode = currentEpisode else { return }
        didFinishCurrentEpisode = true
        if engineUsesEngine {
            audioPlayerNode?.stop()
            engineIsPlaying = false
        } else {
            player?.pause()
        }
        logger.info("playback.finished", "Playback reached end", metadata: [
            "backend": engineUsesEngine ? "AVAudioEngine" : "AVPlayer",
            "episode": episode.title
        ])
        onEpisodeFinished?(episode)
    }
}

enum PlaybackError: Error {
    case missingLocalFile
    case unplayableLocalFile
}
