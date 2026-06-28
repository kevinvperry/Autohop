import SwiftUI

// AI CONTEXT — App/AutohopApp.swift
// SwiftUI entry point. It intentionally does NOT bootstrap AppState in
// AutohopApp.init: a CarPlay-only cold launch must be able to reach
// CarPlaySceneDelegate.didConnect and set an immediate Loading template before
// the heavier app model is created. The iPhone WindowGroup uses
// AutohopRootBootstrapView to reuse or bootstrap AppState only when the phone UI
// actually appears, then injects it as an EnvironmentObject under RootView and
// wires scene-phase transitions:
//  - on launch: resume playback position if an episode was mid-play
//    (startPlaybackOnLaunchIfNeeded)
//  - on foreground: run the auto-archive pass if 30 min have elapsed
//  - on background/inactive: flush playback position + listening stats to disk
//    (these are write-throttled in memory, so leaving foreground must force-save).
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
}
