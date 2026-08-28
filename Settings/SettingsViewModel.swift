import Combine
import Foundation

// AI CONTEXT — Settings/SettingsViewModel.swift
// Stage 14 observable owner for global AppSettings. SwiftUI observes this type
// directly instead of relying on AppState-wide invalidation. It preserves
// SettingsStoring protocol substitution: production SettingsStore supplies a
// live publisher, while simple test stores receive the protocol's initial
// snapshot and still persist every mutation made through this owner.
//
// INVARIANTS:
// - appSettings is the single UI-facing snapshot.
// - UI mutation writes through synchronously to SettingsStoring.
// - external concrete-store changes are accepted without write-back loops.
// - persistence format and SettingsStore save behavior are unchanged.
// - this type owns no playback, sync, notification, or lifecycle side effects;
//   AppState observes the typed settings stream only to invoke those workflows.
// - new-subscription playback, Auto Archive, and notification defaults are
//   exposed to SubscriptionStore through an
//   idempotent adapter installed here, not callback closures authored in
//   AppState.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var appSettings: AppSettings {
        didSet {
            guard !isApplyingStoreValue,
                  settingsStore.appSettings != appSettings
            else { return }
            settingsStore.appSettings = appSettings
        }
    }

    private let settingsStore: SettingsStoring
    private var isApplyingStoreValue = false
    private var cancellable: AnyCancellable?
    private var subscriptionDefaultsInstalled = false

    init(settingsStore: SettingsStoring) {
        self.settingsStore = settingsStore
        self.appSettings = settingsStore.appSettings
        self.cancellable = settingsStore.appSettingsPublisher
            .dropFirst()
            .sink { [weak self] settings in
                guard let self, self.appSettings != settings else { return }
                self.isApplyingStoreValue = true
                self.appSettings = settings
                self.isApplyingStoreValue = false
            }
    }

    func updatePollMinutes(_ minutes: Int) {
        appSettings.podcastPollMinutes = minutes
    }

    func installSubscriptionDefaults(on subscriptionStore: SubscriptionStore) {
        guard !subscriptionDefaultsInstalled else { return }
        subscriptionDefaultsInstalled = true
        subscriptionStore.defaultPlaybackPreferenceProvider = { [weak self] in
            self?.settingsStore.appSettings.defaultPlaybackPreference ?? .default
        }
        subscriptionStore.defaultAutoArchiveSettingsProvider = { [weak self] in
            self?.settingsStore.appSettings.defaultAutoArchiveSettings ?? .default
        }
        subscriptionStore.defaultNotificationsEnabledProvider = { [weak self] in
            self?.settingsStore.appSettings.notifyNewEpisodes ?? false
        }
    }
}
