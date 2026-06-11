import Foundation

// AI CONTEXT — Settings/SettingsViewModel.swift
// Minimal legacy view model: mirrors AppSettings and forwards poll-minutes
// (Release Radar sensitivity) edits to SettingsStore. Most settings UI talks
// to AppState/SettingsStore directly; this remains for the sensitivity stepper.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var appSettings: AppSettings

    private let settingsStore: SettingsStoring

    init(settingsStore: SettingsStoring) {
        self.settingsStore = settingsStore
        self.appSettings = settingsStore.appSettings
    }

    func updatePollMinutes(_ minutes: Int) {
        appSettings.podcastPollMinutes = minutes
        settingsStore.appSettings = appSettings
    }
}

