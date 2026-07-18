//
//  PlaybackCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 11 exclusive state owner for iOS playback. It owns the playback engine,
//  loaded episode, playing flag, dedicated 2 Hz PlaybackClock, user-facing
//  playback message, Sleep Timer/Schedule services, prompt anchor, Play Instant
//  state machine storage, and episode generation token.
//
//  AppState remains a compatibility command façade for SwiftUI and CarPlay.
//  Existing command bodies execute against this state owner. Stage 12 retains
//  responsibility for moving process/lifecycle callback wiring out of AppState.
//  Every
//  episode-scoped async operation must capture `generation` and verify it before
//  applying chapters, completion, restoration, or delayed UI state.
//
//  This type does not own queue ordering, downloads, history/Stats, sync,
//  Auto Archive, or feed refresh.
//

import AVFoundation
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    struct PlayInstantCandidate: Equatable {
        let episodeID: UUID
        let subscriptionID: UUID
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
            onCurrentEpisodeChanged?()
        }
    }
    @Published var isPlaying = false
    @Published var message: String?

    private(set) var generation: UInt64 = 0
    var sleepSchedulePromptAnchorTime: TimeInterval = 0
    var playInstantQueue: [PlayInstantCandidate] = []
    var interruptedSession: InterruptedSession?
    var activePlayInstantEpisodeID: UUID?
    var playInstantTransitionTask: Task<Void, Never>?
    var playInstantWarningPlayer: AVAudioPlayer?
    var onCurrentEpisodeChanged: (() -> Void)?

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
}
