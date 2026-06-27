import SwiftUI

// AI CONTEXT — App/AutohopApp.swift
// SwiftUI entry point. Reuses or bootstraps the AppState singleton, injects it
// as an EnvironmentObject under RootView, and wires scene-phase transitions:
//  - on launch: resume playback position if an episode was mid-play
//    (startPlaybackOnLaunchIfNeeded)
//  - on foreground: run the auto-archive pass if 30 min have elapsed
//  - on background/inactive: flush playback position + listening stats to disk
//    (these are write-throttled in memory, so leaving foreground must force-save).
@main
struct AutohopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState: AppState

    init() {
        let state = AppState.sharedOrBootstrap()
        _appState = StateObject(wrappedValue: state)
        appDelegate.appState = state
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
                .task {
                    await appState.startPlaybackOnLaunchIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    appState.setSceneActive(phase == .active)
                    if phase == .active {
                        Task { await appState.runAutoArchiveIfNeeded(reason: "app.foreground") }
                    } else {
                        appState.persistCurrentPlaybackPosition()
                        appState.listeningStatsStore.save()
                    }
                }
        }
    }
}
