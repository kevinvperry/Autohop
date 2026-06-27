import Foundation

// ============================================================================
// AI CONTEXT - CarPlay/CarPlayActionRouter.swift
//
// PURPOSE: Testable action adapter for CarPlay controls. CarPlayCoordinator owns
// CarPlay template navigation; this value owns the small behavior decisions that
// should be verified without a live CarPlay runtime.
//
// CURRENT SCOPE: Real-hardware CarPlay behavior adapter. Keep this as a thin
// wrapper over AppState. It must not introduce separate CarPlay
// queue/playback/settings state and must not start downloads, feed refresh,
// search, browsing, notifications, or sleep flows.
// ============================================================================

@MainActor
struct CarPlayActionRouter {
    let appState: AppState

    func play(_ episode: Episode) async {
        await appState.playEpisode(episode)
    }

    func playNext(_ episode: Episode) async {
        if appState.currentPlayerEpisode == nil {
            await appState.playEpisode(episode)
        } else {
            appState.playEpisodeNext(episode)
        }
    }

    func playLast(_ episode: Episode) {
        appState.playEpisodeLast(episode)
    }

    func archive(_ episode: Episode) async {
        if appState.episodeIsCurrent(episode) {
            await appState.archiveEpisodeAndPlayNext(episode)
        } else {
            await appState.archiveEpisode(episode)
        }
    }

    func archiveCurrent() async {
        await appState.archiveCurrentEpisodeAndPlayNext()
    }

    func cyclePlaybackSpeed() {
        appState.cyclePlaybackSpeedForCurrentEpisode()
    }

    func setSharedListening(active: Bool) {
        appState.setSharedListening(active: active)
    }

    func selectSharedListeningSpeed(_ speed: Double) {
        if !appState.sharedListeningActive {
            appState.setSharedListening(active: true)
        }
        appState.updateSharedListeningSpeed(speed)
    }
}
