import SwiftUI
import UserNotifications

// AI CONTEXT — Views/NotificationSettingsView.swift ("Notification Settings"
// page). Reached from the Release Radar section of SettingsView. Top: master
// "New episode notifications" toggle (AppSettings.notifyNewEpisodes) with
// Enable All / Disable All buttons. Below: one row per subscription (artwork ·
// title · toggle) bound to Subscription.notificationsEnabled. If iOS
// notification permission is denied, a banner with a deep link to the app's
// system settings page is shown. Notifications fire only when BOTH the master
// toggle and a podcast's toggle are on (gated in
// NewEpisodeNotificationWorkflow).
// Subscription rows observe SubscriptionStore directly; AppState remains only
// for settings and notification commands that cross domain boundaries.
// A "Listening Recaps" row presents RecapSettingsView (also at the bottom of this
// file) as a sheet — the opt-in weekly/monthly/yearly stats-summary notifications.
// Subscription rows use 44 pt CachedArtworkImage thumbnails, sharing the same
// downsampled cache used by Priority, Queue, Downloads, and Stats.
struct NotificationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var permissionDenied = false
    @State private var showRecaps = false

    private var cardBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return Color.white.opacity(0.08)
    }

    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }

    private var formPageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    private var subscriptions: [Subscription] {
        subscriptionStore.subscriptions
            .filter { $0.browseDate == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Form {
            if permissionDenied {
                permissionSection
            }
            masterSection
            recapsSection
            podcastsSection
        }
        .listSectionSpacing(28)
        .scrollContentBackground(formScrollBackground)
        .background(formPageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Notification Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerBar()
        .task { await refreshPermissionStatus() }
        .onChange(of: scenePhase) { _, phase in
            // Re-check after the user returns from the iOS Settings app.
            if phase == .active {
                Task { await refreshPermissionStatus() }
            }
        }
        .sheet(isPresented: $showRecaps) { RecapSettingsView() }
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
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var masterSection: some View {
        Section {
            Toggle(isOn: masterBinding) {
                SettingsRowLabel(title: "New episode notifications", systemImage: "bell.badge")
            }
        } footer: {
            Text("The master switch for new-episode notifications. A podcast only notifies when this and its own toggle below are both on.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var recapsSection: some View {
        Section {
            Button {
                showRecaps = true
            } label: {
                HStack {
                    SettingsRowLabel(title: "Listening Recaps", systemImage: "chart.bar.doc.horizontal")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            Text("Opt in to weekly, monthly, or yearly summaries of your listening.")
        }
        .listRowBackground(cardBackground)
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
        .listRowBackground(cardBackground)
    }

    // MARK: - Bindings & actions

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.notifyNewEpisodes },
            set: { enabled in
                settingsViewModel.appSettings.notifyNewEpisodes = enabled
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
                subscriptionStore.updateNotificationsEnabled(
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
            subscriptionStore.updateNotificationsEnabled(
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
                CachedArtworkImage(url: subscription.artworkURL, targetSize: CGSize(width: 44, height: 44)) {
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

// AI CONTEXT — RecapSettingsView ("Listening Recaps" sheet). Opt-in toggles for
// the weekly / monthly / yearly stats-summary notifications (AppSettings.recap*
// Enabled; weekly ON for fresh installs, monthly/yearly OFF). Presented as a sheet from the Stats page toolbar
// and from Notification Settings. Each toggle change persists the flag, requests
// notification permission on first opt-in (reusing NotificationService.request
// Permission), and reconciles the schedule via NotificationService.scheduleRecaps
// (idempotent recurring calendar notifications — see that method). onAppear also
// reschedules to self-heal after a reinstall. Mechanism B: the notifications are
// evergreen teasers; tapping one deep-links into the matching Stats "Last" view.
struct RecapSettingsView: View {
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionDenied = false

    private var cardBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return Color.white.opacity(0.08)
    }
    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }
    private var formPageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    var body: some View {
        NavigationStack {
            Form {
                if permissionDenied { permissionSection }

                Section {
                    Toggle(isOn: recapBinding(\.recapWeeklyEnabled)) {
                        SettingsRowLabel(title: "Weekly recap", systemImage: "calendar")
                    }
                    Toggle(isOn: recapBinding(\.recapMonthlyEnabled)) {
                        SettingsRowLabel(title: "Monthly recap", systemImage: "calendar.badge.clock")
                    }
                    Toggle(isOn: recapBinding(\.recapYearlyEnabled)) {
                        SettingsRowLabel(title: "Yearly recap", systemImage: "sparkles")
                    }
                } header: {
                    Text("Send me a recap")
                } footer: {
                    Text("Get a friendly summary of your listening when a week, month, or year wraps up — delivered around 9am. Tap a recap to open your stats for that period.\n\nCalculated on your device. Your listening never leaves your phone. Weekly is on for new users; monthly and yearly are optional.")
                }
                .listRowBackground(cardBackground)
            }
            .listSectionSpacing(28)
            .scrollContentBackground(formScrollBackground)
            .background(formPageBackground.ignoresSafeArea())
            .tint(.purple)
            .preferredColorScheme(.dark)
            .navigationTitle("Listening Recaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
            .task { await refreshPermissionStatus() }
            .onAppear { reschedule() }   // self-heal (e.g. after a reinstall)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshPermissionStatus() } }
            }
        }
        .preferredColorScheme(.dark)
    }

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
            Text("Until notifications are allowed in iOS Settings, recaps won't be delivered.")
        }
        .listRowBackground(cardBackground)
    }

    private func recapBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings[keyPath: keyPath] },
            set: { newValue in
                settingsViewModel.appSettings[keyPath: keyPath] = newValue
                if newValue {
                    NotificationService.shared.requestPermission()
                    Task { await refreshPermissionStatus() }
                }
                reschedule()
            }
        )
    }

    private func reschedule() {
        let s = settingsViewModel.appSettings
        NotificationService.shared.scheduleRecaps(
            weekly: s.recapWeeklyEnabled,
            monthly: s.recapMonthlyEnabled,
            yearly: s.recapYearlyEnabled
        )
    }

    private func refreshPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { permissionDenied = settings.authorizationStatus == .denied }
    }
}
