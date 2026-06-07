import Foundation

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

