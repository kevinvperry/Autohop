import SwiftUI

@main
struct AutohopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState: AppState

    init() {
        let state = AppState.bootstrap()
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
