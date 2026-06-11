import SwiftUI
import UserNotifications

// AI CONTEXT — Views/NotificationSettingsView.swift ("Notification Settings"
// page). Reached from the Release Radar section of SettingsView. Top: master
// "New episode notifications" toggle (AppSettings.notifyNewEpisodes) with
// Enable All / Disable All buttons. Below: one row per subscription (artwork ·
// title · toggle) bound to Subscription.notificationsEnabled. If iOS
// notification permission is denied, a banner with a deep link to the app's
// system settings page is shown. Notifications fire only when BOTH the master
// toggle and a podcast's toggle are on (gated in AppState.notifyNewEpisodeIfAllowed).
struct NotificationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var permissionDenied = false

    private var subscriptions: [Subscription] {
        appState.subscriptionStore.subscriptions
            .filter { $0.browseDate == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Form {
            if permissionDenied {
                permissionSection
            }
            masterSection
            podcastsSection
        }
        .listSectionSpacing(28)
        .navigationTitle("Notification Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ReturnToPlayerButton()
            }
        }
        .task { await refreshPermissionStatus() }
        .onChange(of: scenePhase) { _, phase in
            // Re-check after the user returns from the iOS Settings app.
            if phase == .active {
                Task { await refreshPermissionStatus() }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var permissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Notifications are turned off for Autohop in iOS Settings", systemImage: "bell.slash.fill")
                    .font(.subheadline.weight(.semibold))
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Until notifications are allowed in iOS Settings, the toggles below will have no effect.")
        }
    }

    @ViewBuilder
    private var masterSection: some View {
        Section {
            Toggle("New episode notifications", isOn: masterBinding)
        } footer: {
            Text("The master switch for new-episode notifications. A podcast only notifies when this and its own toggle below are both on.")
        }
    }

    @ViewBuilder
    private var podcastsSection: some View {
        Section {
            ForEach(subscriptions) { subscription in
                NotificationPodcastRow(
                    subscription: subscription,
                    isOn: notificationsBinding(subscription)
                )
            }
        } header: {
            HStack {
                Text("Podcasts")
                Spacer()
                Button("Enable All") { setAll(true) }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                Button("Disable All") { setAll(false) }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
            }
        } footer: {
            if subscriptions.isEmpty {
                Text("Subscribe to a podcast to manage its notifications here.")
            }
        }
    }

    // MARK: - Bindings & actions

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.notifyNewEpisodes },
            set: { enabled in
                appState.settingsStore.appSettings.notifyNewEpisodes = enabled
                if enabled {
                    NotificationService.shared.requestPermission()
                    Task { await refreshPermissionStatus() }
                }
            }
        )
    }

    private func notificationsBinding(_ subscription: Subscription) -> Binding<Bool> {
        Binding(
            get: { subscription.notificationsEnabled },
            set: { enabled in
                appState.subscriptionStore.updateNotificationsEnabled(
                    subscriptionID: subscription.id,
                    enabled: enabled
                )
                if enabled {
                    NotificationService.shared.requestPermission()
                }
            }
        )
    }

    private func setAll(_ enabled: Bool) {
        for subscription in subscriptions where subscription.notificationsEnabled != enabled {
            appState.subscriptionStore.updateNotificationsEnabled(
                subscriptionID: subscription.id,
                enabled: enabled
            )
        }
        if enabled {
            NotificationService.shared.requestPermission()
        }
    }

    private func refreshPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            permissionDenied = settings.authorizationStatus == .denied
        }
    }
}

private struct NotificationPodcastRow: View {
    let subscription: Subscription
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                CachedArtworkImage(url: subscription.artworkURL) {
                    Image(systemName: "waveform")
                        .font(.body)
                        .foregroundStyle(.purple)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.tertiarySystemGroupedBackground))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(subscription.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
        }
    }
}
