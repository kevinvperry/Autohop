//
//  PlaybackCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 11 exclusive state owner for iOS playback. It owns the playback engine,
//  loaded episode, playing flag, dedicated 2 Hz PlaybackClock, user-facing
//  playback message, Sleep Timer/Schedule services, prompt anchor, Play Instant
//  state machine storage, episode generation token, and idempotent installation
//  of playback-engine callbacks whose effects remain inside playback/history.
//  Interruption/resume/route restoration use typed subscription/preference
//  collaborators. Chapter presentation is observed through the weak
//  PlaybackChapterPresenting boundary rather than AppState-owned providers.
//  AppState does not install engine or presentation callbacks.
//
//  AppState remains a compatibility command façade for SwiftUI and CarPlay.
//  Existing command bodies execute against this state owner. Stage 14 moves
//  callback ownership here one coherent group at a time. Every
//  episode-scoped async operation must capture `generation` and verify it before
//  applying chapters, completion, restoration, or delayed UI state.
//  The media-position callback delegates time accounting to
//  HistoryStatsCoordinator; never restore a fixed-per-callback Stats credit,
//  because AVPlayer callback frequency scales with playback rate.
//
//  This type does not own queue ordering, downloads, history/Stats, sync,
//  Auto Archive, or feed refresh. Stage 14 also places read-only chapter/video
//  presentation projections here. PlaybackChapterWorkflow computes those
//  projections; this coordinator does not mutate chapter, subscription, or
//  queue domains.
//

import AVFoundation
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    private struct TickStageTiming {
        var name: String
        var durationMs: Double
    }

    private struct TickDiagnostics {
        var occurredAt: Date
        var episode: String
        var podcast: String
        var currentTime: Int
        var totalMs: Double
        var dominantStage: String
        var dominantStageMs: Double
        var stages: [TickStageTiming]
        var positionSaved: Bool
        var statsCredited: Bool

        var metadata: [String: String] {
            [
                "episode": episode,
                "podcast": podcast,
                "currentTime": "\(currentTime)",
                "totalMs": String(format: "%.1f", totalMs),
                "dominantStage": dominantStage,
                "dominantStageMs": String(format: "%.1f", dominantStageMs),
                "stageMs": stages
                    .map { "\($0.name)=\(Int($0.durationMs.rounded()))" }
                    .joined(separator: ","),
                "positionSaved": "\(positionSaved)",
                "statsCredited": "\(statsCredited)"
            ]
        }
    }

    private struct TickSummary {
        var samples = 0
        var slowSamples = 0
        var totalMs = 0.0
        var maxMs = 0.0
        var maxStage = "none"

        mutating func record(_ diagnostics: TickDiagnostics, thresholdMs: Double) {
            samples += 1
            totalMs += diagnostics.totalMs
            if diagnostics.totalMs >= thresholdMs { slowSamples += 1 }
            if diagnostics.totalMs > maxMs {
                maxMs = diagnostics.totalMs
                maxStage = diagnostics.dominantStage
            }
        }

        mutating func reset() {
            samples = 0
            slowSamples = 0
            totalMs = 0
            maxMs = 0
            maxStage = "none"
        }

        var metadata: [String: String] {
            [
                "samples": "\(samples)",
                "slowSamples": "\(slowSamples)",
                "averageMs": samples > 0
                    ? String(format: "%.1f", totalMs / Double(samples))
                    : "0.0",
                "maxMs": String(format: "%.1f", maxMs),
                "maxStage": maxStage
            ]
        }
    }

    struct PlayInstantCandidate: Equatable {
        let episodeID: UUID
        let subscriptionID: UUID
        let queuedAt: Date
        let expiresAt: Date
    }

    struct InterruptedSession {
        let episodeID: UUID
        let subscriptionID: UUID
        var position: TimeInterval
    }

    var engine: PlaybackControlling
    let clock: PlaybackClock
    let sleepTimerService: SleepTimerService
    let sleepScheduleService: SleepScheduleService

    @Published var currentEpisode: Episode? {
        didSet {
            if oldValue?.id != currentEpisode?.id {
                generation &+= 1
            }
        }
    }
    @Published var isPlaying = false {
        didSet {
            if isPlaying, !oldValue {
                playInstantPlaybackBecameActive?()
            }
        }
    }
    @Published var message: String?

    private(set) var generation: UInt64 = 0
    var sleepSchedulePromptAnchorTime: TimeInterval = 0
    var hasHandledLaunchPlayback = false
    var playInstantQueue: [PlayInstantCandidate] = []
    var interruptedSession: InterruptedSession?
    var activePlayInstantEpisodeID: UUID?
    var playInstantTransitionTask: Task<Void, Never>?
    var playInstantExpiryTask: Task<Void, Never>?
    var playInstantWarningPlayer: AVAudioPlayer?
    var playInstantPlaybackBecameActive: (() -> Void)?
    private var statisticsCallbacksInstalled = false
    private var sessionCallbacksInstalled = false
    private var sleepCallbacksInstalled = false
    private var timeUpdateCallbackInstalled = false
    private var completionCallbackInstalled = false
    private var remoteCommandCallbacksInstalled = false
    private var sleepScheduleFadeTask: Task<Void, Never>?
    private var positionSaveCounter = 0
    private var lastTickDiagnostics: TickDiagnostics?
    private var tickSummary = TickSummary()
    private let tickSlowThresholdMs = 120.0
    // AI CONTEXT — At the 2 Hz engine callback this is a ten-minute healthy-path
    // summary. Slow ticks still log immediately, and the latest in-memory timing
    // remains available to main-thread/resource diagnostics between summaries.
    private let tickSummarySampleInterval = 1_200
    private weak var chapterPresentation: (any PlaybackChapterPresenting)?

    var currentChapter: Chapter? { chapterPresentation?.currentChapter }
    var supportsChapters: Bool {
        chapterPresentation?.supportsChapters ?? false
    }
    var activeChapters: [Chapter] {
        chapterPresentation?.activeChapters ?? []
    }
    var chapterEpisode: Episode? { chapterPresentation?.chapterEpisode }
    var previousChapterTarget: TimeInterval? {
        chapterPresentation?.previousTarget
    }
    var nextChapterTarget: TimeInterval? {
        chapterPresentation?.nextTarget
    }
    var videoPlayer: AVPlayer? { engine.videoPlayer }

    init(
        engine: PlaybackControlling,
        clock: PlaybackClock? = nil,
        sleepTimerService: SleepTimerService? = nil,
        sleepScheduleService: SleepScheduleService? = nil
    ) {
        self.engine = engine
        self.clock = clock ?? PlaybackClock()
        self.sleepTimerService = sleepTimerService ?? SleepTimerService()
        self.sleepScheduleService = sleepScheduleService ?? SleepScheduleService()
    }

    @discardableResult
    func beginEpisodeGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    func isCurrent(generation expected: UInt64, episodeID: UUID) -> Bool {
        generation == expected && currentEpisode?.id == episodeID
    }

    /// Connects the read-only chapter projection owner. Weak storage prevents a
    /// playback/chapter cycle; AppState strongly owns the workflow graph.
    func observeChapters(_ presentation: any PlaybackChapterPresenting) {
        chapterPresentation = presentation
    }

    /// Installs playback events that only credit listening statistics.
    ///
    /// AI CONTEXT — Engines may emit these closures outside MainActor. Each
    /// callback enters MainActor before reading the current episode or mutating
    /// HistoryStatsCoordinator. Installation is idempotent because startup can
    /// be requested by more than one scene. Subscription identity is resolved
    /// at delivery time, matching the former AppState behavior.
    func installStatisticsCallbacks(
        historyStatsCoordinator: HistoryStatsCoordinator
    ) {
        guard !statisticsCallbacksInstalled else { return }
        statisticsCallbacksInstalled = true

        engine.onManualSkipForward = { [weak self, weak historyStatsCoordinator] seconds in
            Task { @MainActor in
                guard let self, let historyStatsCoordinator else { return }
                historyStatsCoordinator.recordManualSkipForward(
                    seconds,
                    subscriptionID: self.currentEpisode?.subscriptionID
                )
            }
        }
        engine.onAutoSkip = { [weak self, weak historyStatsCoordinator] seconds in
            Task { @MainActor in
                guard let self, let historyStatsCoordinator else { return }
                historyStatsCoordinator.recordAutoSkip(
                    seconds,
                    subscriptionID: self.currentEpisode?.subscriptionID
                )
            }
        }
        engine.onTrimSilenceSaved = { [weak self, weak historyStatsCoordinator] seconds in
            Task { @MainActor in
                guard let self, let historyStatsCoordinator else { return }
                historyStatsCoordinator.recordTrimSilenceSaved(
                    seconds,
                    subscriptionID: self.currentEpisode?.subscriptionID
                )
            }
        }
    }

    /// Owns playback-session callbacks emitted by audio interruption and route
    /// restoration events.
    ///
    /// AI CONTEXT — SubscriptionStore and PlaybackPreferenceWorkflow are typed
    /// read-only/presentation collaborators. Callback installation is
    /// idempotent and every engine event enters MainActor before state mutation.
    func installSessionCallbacks(
        subscriptionStore: SubscriptionStore,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        logger: AppLogger
    ) {
        guard !sessionCallbacksInstalled else { return }
        sessionCallbacksInstalled = true

        engine.onPlaybackInterrupted = {
            [weak self, weak subscriptionStore, weak preferenceWorkflow] in
            Task { @MainActor in
                guard let self,
                      let subscriptionStore,
                      let preferenceWorkflow else {
                    return
                }
                self.isPlaying = false
                guard let episode = self.currentEpisode,
                      let currentSubscription =
                        subscriptionStore.subscription(
                            id: episode.subscriptionID
                        ) else {
                    return
                }
                NowPlayingService.shared.updateTime(
                    currentTime: self.clock.time,
                    isPlaying: false,
                    speed: preferenceWorkflow.effectiveSpeed(
                        for: currentSubscription
                    )
                )
            }
        }

        engine.onPlaybackResumed = {
            [weak self, weak subscriptionStore, weak preferenceWorkflow] in
            Task { @MainActor in
                guard let self,
                      let subscriptionStore,
                      let preferenceWorkflow else {
                    return
                }
                self.isPlaying = true
                guard let episode = self.currentEpisode,
                      let currentSubscription =
                        subscriptionStore.subscription(
                            id: episode.subscriptionID
                        ) else {
                    return
                }
                let speed = preferenceWorkflow.effectiveSpeed(
                    for: currentSubscription
                )
                self.engine.updatePlaybackSpeed(speed)
                logger.info(
                    "player.resumedAfterInterruption",
                    "Playback resumed after interruption",
                    metadata: [
                        "episode": episode.title,
                        "speed": PlaybackPreference.speedLabel(speed)
                    ]
                )
                NowPlayingService.shared.updateTime(
                    currentTime: self.clock.time,
                    isPlaying: true,
                    speed: speed
                )
            }
        }

        // A restored output route reclaims Autohop's audio session before the
        // complete Now Playing card is reconstructed. This prevents a subsequent
        // headset transport press from falling through to another media app.
        if let routeAwareEngine = engine as? PlaybackEngine {
            routeAwareEngine.onRouteRestored = { [weak preferenceWorkflow] in
                Task { @MainActor in
                    preferenceWorkflow?.reassertNowPlayingCard(
                        reason: "routeRestored"
                    )
                }
            }
        }
    }

    /// Installs and owns Sleep Timer and Sleep Schedule service callbacks.
    ///
    /// AI CONTEXT — PlaybackCoordinator owns both services, the playback engine,
    /// playing state, clock, prompt anchor, and cancellable schedule fade.
    /// Named workflows supply seek, checkpoint, and speed policy. The Still
    /// Listening handler captures this owner weakly.
    func installSleepCallbacks(
        subscriptionStore: SubscriptionStore,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        seekWorkflow: PlaybackSeekWorkflow,
        checkpointWorkflow: PlaybackCheckpointWorkflow,
        logger: AppLogger
    ) {
        guard !sleepCallbacksInstalled else { return }
        sleepCallbacksInstalled = true

        sleepTimerService.onPause = {
            [
                weak self,
                weak subscriptionStore,
                weak preferenceWorkflow,
                weak checkpointWorkflow
            ] in
            Task { @MainActor in
                guard let self,
                      let subscriptionStore,
                      let preferenceWorkflow,
                      let checkpointWorkflow,
                      self.isPlaying else {
                    return
                }
                self.engine.pause()
                self.isPlaying = false
                checkpointWorkflow.checkpoint(reason: "sleepTimer.pause")
                if let episode = self.currentEpisode,
                   let currentSubscription =
                    subscriptionStore.subscription(
                        id: episode.subscriptionID
                    ) {
                    NowPlayingService.shared.updateTime(
                        currentTime: self.clock.time,
                        isPlaying: false,
                        speed: preferenceWorkflow.effectiveSpeed(
                            for: currentSubscription
                        )
                    )
                }
                logger.info("sleepTimer.fired", "Sleep timer paused playback")
            }
        }
        sleepTimerService.onFadeVolume = { [weak self] volume in
            self?.engine.setVolume(volume)
        }

        sleepScheduleService.onPrompt = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sleepSchedulePromptAnchorTime = self.clock.time
                NotificationService.shared.postSleepSchedulePrompt()
                logger.info(
                    "sleepSchedule.prompt",
                    "Sleep Schedule asking if still listening (playback continues)",
                    metadata: [
                        "anchorTime": "\(Int(self.sleepSchedulePromptAnchorTime))"
                    ]
                )
            }
        }
        sleepScheduleService.onPromptDismissed = {
            NotificationService.shared.clearSleepSchedulePrompt()
        }
        NotificationService.shared.setStillListeningHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.sleepScheduleService.isPrompting else {
                    return
                }
                self.sleepScheduleService.userResponded()
                logger.info(
                    "sleepSchedule.stillListening",
                    "User confirmed still listening via lock-screen notification"
                )
            }
        }
        sleepScheduleService.onAsleep = {
            [
                weak self,
                weak subscriptionStore,
                weak preferenceWorkflow,
                weak seekWorkflow,
                weak checkpointWorkflow
            ] atEpisodeBoundary in
            Task { @MainActor in
                guard let self,
                      let subscriptionStore,
                      let preferenceWorkflow,
                      let seekWorkflow,
                      let checkpointWorkflow,
                      self.isPlaying else {
                    return
                }
                self.sleepScheduleFadeTask?.cancel()
                self.sleepScheduleFadeTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let tickSeconds = 0.5
                    var remaining = SleepTimerService.gradualFadeDuration
                    while remaining > 0 {
                        guard !Task.isCancelled else { return }
                        self.engine.setVolume(
                            SleepTimerService.gradualFadeVolume(
                                remaining: remaining
                            )
                        )
                        try? await Task.sleep(for: .milliseconds(500))
                        remaining -= tickSeconds
                    }
                    guard !Task.isCancelled else { return }
                    self.engine.setVolume(0)
                    self.engine.pause()
                    self.isPlaying = false
                    self.engine.setVolume(1)

                    let rewindTarget = atEpisodeBoundary
                        ? 0
                        : self.sleepSchedulePromptAnchorTime
                    seekWorkflow.seek(to: rewindTarget)
                    checkpointWorkflow.checkpoint(
                        reason: "sleepSchedule.asleep"
                    )
                    if let episode = self.currentEpisode,
                       let currentSubscription =
                        subscriptionStore.subscription(
                            id: episode.subscriptionID
                        ) {
                        NowPlayingService.shared.updateTime(
                            currentTime: rewindTarget,
                            isPlaying: false,
                            speed: preferenceWorkflow.effectiveSpeed(
                                for: currentSubscription
                            )
                        )
                    }
                    logger.info(
                        "sleepSchedule.asleep",
                        "No response to prompt — faded out and rewound to prompt point",
                        metadata: [
                            "atEpisodeBoundary": "\(atEpisodeBoundary)",
                            "fadeSeconds": "\(Int(SleepTimerService.gradualFadeDuration))",
                            "rewindTarget": "\(Int(rewindTarget))"
                        ]
                    )
                    self.sleepScheduleFadeTask = nil
                }
            }
        }
    }

    /// Installs the engine's 2 Hz time callback and owns its complete pipeline.
    ///
    /// AI CONTEXT — This is the only routine writer of PlaybackClock. It ticks
    /// both sleep services, updates Now Playing, credits history/Stats, requests
    /// a durable position save every 20 callbacks (~10 seconds), and maintains
    /// slow-tick diagnostics. Typed collaborators provide subscription/speed
    /// policy and the position-store write owned outside playback.
    func installTimeUpdateCallback(
        subscriptionStore: SubscriptionStore,
        preferenceWorkflow: PlaybackPreferenceWorkflow,
        historyStatsCoordinator: HistoryStatsCoordinator,
        mediaWorkflow: PlaybackMediaWorkflow,
        logger: AppLogger
    ) {
        guard !timeUpdateCallbackInstalled else { return }
        timeUpdateCallbackInstalled = true

        engine.onTimeUpdate = {
            [
                weak self,
                weak subscriptionStore,
                weak preferenceWorkflow,
                weak historyStatsCoordinator,
                weak mediaWorkflow
            ] time in
            Task { @MainActor in
                guard let self,
                      let subscriptionStore,
                      let preferenceWorkflow,
                      let historyStatsCoordinator,
                      let mediaWorkflow else {
                    return
                }
                let tickStartedAt = CFAbsoluteTimeGetCurrent()
                var stages: [TickStageTiming] = []
                var positionSaved = false
                var statsCredited = false
                var tickEpisode: Episode?
                var tickSubscription: Subscription?

                func measure(_ name: String, _ work: () -> Void) {
                    let startedAt = CFAbsoluteTimeGetCurrent()
                    work()
                    stages.append(TickStageTiming(
                        name: name,
                        durationMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    ))
                }

                measure("timeState") {
                    self.clock.time = time
                    tickEpisode = self.currentEpisode
                    if let episode = tickEpisode {
                        tickSubscription = subscriptionStore.subscription(
                            id: episode.subscriptionID
                        )
                    }
                }
                measure("sleepTimers") {
                    self.sleepTimerService.tick()
                    if self.sleepTimerService.isActive {
                        self.sleepScheduleService.suspendForSession()
                    }
                    self.sleepScheduleService.tick(isPlaying: self.isPlaying)
                }
                measure("nowPlaying") {
                    if let tickSubscription {
                        NowPlayingService.shared.updateTime(
                            currentTime: time,
                            isPlaying: self.isPlaying,
                            speed: preferenceWorkflow.effectiveSpeed(
                                for: tickSubscription
                            )
                        )
                    }
                }
                // History persistence can occasionally take hundreds of
                // milliseconds. Queue it behind the latency-sensitive playback
                // tick so clock/Now Playing updates and audio controls are not
                // held hostage by storage or CloudKit bookkeeping.
                let historyIsPlaying = self.isPlaying
                let historyEffectiveSpeed = tickSubscription.map {
                    preferenceWorkflow.effectiveSpeed(for: $0)
                } ?? 1.0
                Task { @MainActor in
                    historyStatsCoordinator.recordPlaybackProgress(
                        at: time,
                        isPlaying: historyIsPlaying,
                        episode: tickEpisode,
                        subscription: tickSubscription,
                        effectiveSpeed: historyEffectiveSpeed
                    )
                }
                measure("positionSave") {
                    self.positionSaveCounter += 1
                    if self.positionSaveCounter % 20 == 0 {
                        mediaWorkflow.saveCurrentPosition()
                        positionSaved = true
                    }
                }
                // HistoryStatsCoordinator derives both heard-media and elapsed
                // wall time from the same natural media-position delta. A fixed
                // 0.5 credit here over-counted AVPlayer listening at >1x speed.
                statsCredited = historyIsPlaying && tickEpisode != nil && tickSubscription != nil
                self.recordTickDiagnostics(
                    startedAt: tickStartedAt,
                    playbackTime: time,
                    episode: tickEpisode,
                    subscription: tickSubscription,
                    stages: stages,
                    positionSaved: positionSaved,
                    statsCredited: statsCredited,
                    logger: logger
                )
            }
        }
    }

    /// Installs the engine completion callback and captures the episode
    /// generation at delivery.
    ///
    /// AI CONTEXT — Natural EOF originates in the playback engine, so callback
    /// ownership and generation sampling belong here. The supplied async command
    /// is deliberately a high-level cross-domain workflow: completion also
    /// mutates history, downloads, queue, Sleep Timer/Schedule, and Play Instant.
    /// Those effects stay in the named EpisodeCompletionWorkflow.
    func installCompletionCallback(
        completionWorkflow: EpisodeCompletionWorkflow
    ) {
        guard !completionCallbackInstalled else { return }
        completionCallbackInstalled = true

        engine.onEpisodeFinished = {
            [weak self, weak completionWorkflow] episode in
            Task { @MainActor in
                guard let self, let completionWorkflow else { return }
                await completionWorkflow.handle(
                    episode,
                    expectedGeneration: self.generation
                )
            }
        }
    }

    /// Installs lock-screen, headset, and CarPlay transport callbacks.
    ///
    /// AI CONTEXT — NowPlayingService is a playback platform adapter, so its
    /// callback graph belongs beside the engine rather than in AppState.
    /// Commands enter MainActor and invoke named workflows. Backward seeking is
    /// resolved against the authoritative PlaybackClock here.
    func installRemoteCommandCallbacks(
        settings: AppSettings,
        transportWorkflow: PlaybackTransportWorkflow,
        seekWorkflow: PlaybackSeekWorkflow,
        completionWorkflow: EpisodeCompletionWorkflow,
        playInstantWorkflow: PlayInstantWorkflow,
        preferenceWorkflow: PlaybackPreferenceWorkflow
    ) {
        guard !remoteCommandCallbacksInstalled else { return }
        remoteCommandCallbacksInstalled = true

        NowPlayingService.shared.configure(
            onPlayPause: { [weak transportWorkflow] in
                Task { @MainActor [weak transportWorkflow] in
                    await transportWorkflow?.togglePlayPause()
                }
            },
            onSeek: { [weak seekWorkflow] target in
                Task { @MainActor [weak seekWorkflow] in
                    seekWorkflow?.seek(to: target)
                }
            },
            onSkipForward: { [weak seekWorkflow] seconds in
                Task { @MainActor [weak seekWorkflow] in
                    seekWorkflow?.skipForward(seconds: seconds)
                }
            },
            onSkipBackward: { [weak self, weak seekWorkflow] seconds in
                Task { @MainActor in
                    guard let self, let seekWorkflow else { return }
                    seekWorkflow.seek(to: max(0, self.clock.time - seconds))
                }
            },
            onNextTrack: {
                [
                    weak self,
                    weak completionWorkflow,
                    weak playInstantWorkflow
                ] in
                Task { @MainActor in
                    guard let self,
                          let completionWorkflow,
                          let playInstantWorkflow,
                          let episode = self.currentEpisode else {
                        return
                    }
                    if self.activePlayInstantEpisodeID != nil
                        || self.playInstantTransitionTask != nil {
                        playInstantWorkflow.cancel(
                            reason: "manualNextTrack"
                        )
                    }
                    await completionWorkflow.handle(episode)
                }
            },
            onPlaybackRateChange: { [weak preferenceWorkflow] rate in
                Task { @MainActor [weak preferenceWorkflow] in
                    preferenceWorkflow?.setPlaybackSpeedForCurrentEpisode(
                        Double(rate)
                    )
                }
            }
        )
        NowPlayingService.shared.updateSkipIntervals(
            forward: settings.skipForwardSeconds,
            backward: settings.skipBackSeconds
        )
        NowPlayingService.shared.refreshScrubbingCommand(
            enabled: settings.lockScreenScrubbingEnabled
        )
    }

    func resetTimeUpdatePersistenceCadence() {
        positionSaveCounter = 0
    }

    var lastTickResourceMetadata: [String: String] {
        guard let diagnostics = lastTickDiagnostics else { return [:] }
        return [
            "lastPlaybackTickAgeMs": String(
                format: "%.0f",
                Date().timeIntervalSince(diagnostics.occurredAt) * 1000
            ),
            "lastPlaybackTickTotalMs": String(format: "%.1f", diagnostics.totalMs),
            "lastPlaybackTickDominantStage": diagnostics.dominantStage,
            "lastPlaybackTickDominantStageMs": String(
                format: "%.1f",
                diagnostics.dominantStageMs
            ),
            "lastPlaybackTickPositionSaved": "\(diagnostics.positionSaved)",
            "lastPlaybackTickStatsCredited": "\(diagnostics.statsCredited)"
        ]
    }

    private func recordTickDiagnostics(
        startedAt: CFAbsoluteTime,
        playbackTime: TimeInterval,
        episode: Episode?,
        subscription: Subscription?,
        stages: [TickStageTiming],
        positionSaved: Bool,
        statsCredited: Bool,
        logger: AppLogger
    ) {
        let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        let dominant = stages.max { $0.durationMs < $1.durationMs }
        let diagnostics = TickDiagnostics(
            occurredAt: Date(),
            episode: episode?.title ?? "none",
            podcast: subscription?.title ?? "none",
            currentTime: Int(playbackTime),
            totalMs: totalMs,
            dominantStage: dominant?.name ?? "none",
            dominantStageMs: dominant?.durationMs ?? 0,
            stages: stages,
            positionSaved: positionSaved,
            statsCredited: statsCredited
        )
        lastTickDiagnostics = diagnostics
        tickSummary.record(diagnostics, thresholdMs: tickSlowThresholdMs)
        if totalMs >= tickSlowThresholdMs {
            logger.warning(
                "playback.tickSlow",
                "Playback tick was slow on the main actor",
                metadata: diagnostics.metadata
            )
        }
        if tickSummary.samples >= tickSummarySampleInterval {
            var metadata = tickSummary.metadata
            metadata.merge([
                "episode": diagnostics.episode,
                "podcast": diagnostics.podcast,
                "currentTime": "\(diagnostics.currentTime)",
                "thresholdMs": String(format: "%.1f", tickSlowThresholdMs)
            ]) { _, new in new }
            logger.info(
                "playback.tickSummary",
                "Playback tick timing summary",
                metadata: metadata
            )
            tickSummary.reset()
        }
    }
}
