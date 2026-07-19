import SwiftUI

// AI CONTEXT — App/AutohopApp.swift
// SwiftUI entry point. It intentionally does NOT bootstrap AppState in
// AutohopApp.init: a CarPlay-only cold launch must be able to reach
// CarPlaySceneDelegate.didConnect and set an immediate Loading template before
// the heavier app model is created. The iPhone WindowGroup uses
// AutohopRootBootstrapView to reuse or bootstrap AppState only when the phone UI
// actually appears, then injects it as an EnvironmentObject under RootView.
// Stage 13 also injects domain coordinators, stores, and independently
// publishing sleep services so migrated page families
// observe only their mutable owner while retaining AppState for shared intents —
// alongside appState.playbackClock (PERF-1: the dedicated 2 Hz playback-time
// observable that only PlayerView's scrubber and MiniPlayerBar observe) — and
// wires scene-phase transitions:
//  - on launch: resume playback position if an episode was mid-play
//    (startPlaybackOnLaunchIfNeeded)
//  - on foreground: offer AutoArchiveCoordinator its persisted 25-minute gate
//  - on background/inactive: flush playback position, subscription-order
//    transactions, and listening stats to disk
//    (these are write-throttled in memory, so leaving foreground must force-save),
//    then flushDeferredSyncPushes so slow-lane (history/stats) CloudKit changes
//    held on the sync engine's ~60 s coalescing debounce upload before suspension.
@main
struct AutohopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AutohopRootBootstrapView(appDelegate: appDelegate)
        }
    }
}

private struct AutohopRootBootstrapView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState?

    let appDelegate: AppDelegate

    var body: some View {
        Group {
            if let appState {
                RootView()
                    .environmentObject(appState)
                    // 2 Hz playback tick — observed only by the scrubber/mini-player
                    // surfaces (PERF-1), so the tick no longer wakes AppState observers.
                    .environmentObject(appState.playbackClock)
                    // Per-episode download progress — observed only by the
                    // episode-row/first-subscribe surfaces that render it, so
                    // progress ticks no longer wake AppState observers.
                    .environmentObject(appState.downloadProgressModel)
                    .environmentObject(appState.settingsCoordinator)
                    // Stage 13 narrow observables. Page families can consume
                    // their domain owner directly without broad AppState wakes.
                    .environmentObject(appState.playbackCoordinator)
                    // Sleep countdown/prompt services publish independently of
                    // PlaybackCoordinator; inject them directly so Player and
                    // Sleep Schedule avoid AppState invalidation bridges.
                    .environmentObject(appState.sleepTimerService)
                    .environmentObject(appState.sleepScheduleService)
                    .environmentObject(appState.queueCoordinator)
                    .environmentObject(appState.downloadCoordinator)
                    .environmentObject(appState.historyStatsCoordinator)
                    .environmentObject(appState.onboardingCoordinator)
                    .environmentObject(appState.autoArchiveCoordinator)
                    .environmentObject(appState.subscriptionImportCoordinator)
                    .environmentObject(appState.subscriptionStore)
                    .environmentObject(appState.listeningHistoryStore)
                    .environmentObject(appState.listeningStatsStore)
                    .environmentObject(appState.autoArchiveActivityStore)
                    .environmentObject(appState.downloadActivityStore)
                    .task {
                        await appState.startPlaybackOnLaunchIfNeeded()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        appState.handleScenePhaseChange(
                            phaseName: scenePhaseLabel(phase),
                            isActive: phase == .active,
                            isBackground: phase == .background
                        )
                        if phase == .active {
                            // "Audio hijack" fix (2026-07-12): a loaded episode's
                            // Now Playing slot claim can go stale while the app
                            // was backgrounded — re-push the card so AirPods/
                            // lock-screen transport lands here, not Apple Music.
                            appState.reassertNowPlayingCard(reason: "scene.active")
                            Task { await appState.runAutoArchiveIfNeeded(reason: "app.foreground") }
                            // Retry auto-downloads whose BG-wake intent never
                            // started (persisted in AutoDownloadIntentStore).
                            Task { await appState.drainAutoDownloadIntents(reason: "foreground") }
                        } else {
                            appState.preparePlaybackHistoryAndStatsCheckpoint()
                            Task { @MainActor in
                                // Subscription saves are asynchronous. Finish the
                                // SQLite transaction first so the following sync
                                // scan sees the atomic order generation.
                                _ = await appState.subscriptionStore.flushPendingSaves()
                                appState.flushDeferredSyncPushes(
                                    reason: phase == .background ? "scene.background" : "scene.inactive"
                                )
                            }
                        }
                    }
            } else {
                ProgressView()
                    .task {
                        let state = AppState.sharedOrBootstrap()
                        appDelegate.appState = state
                        appState = state
                    }
            }
        }
    }

    private func scenePhaseLabel(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
