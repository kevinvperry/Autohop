// AI CONTEXT — Navigation compatibility, 20 September 2026 (SleepScheduleView.swift).
// PURPOSE: Prevent duplicate native/custom Back controls reported on iOS 27.
// COLLABORATOR: RootView.swift owns appNavigationBackButton: native Back on iOS
// 27+, branded ambient dismiss on older systems. Do not add a second leading Back
// or mutate the outer path; preserve the nearest parent and existing mini-player.
// EVIDENCE: Docs/IOS27_NAVIGATION_BACK_AUDIT.md and NavigationChromeTests.

import SwiftUI

// AI CONTEXT — Sleep Schedule presentation refresh, 20 September 2026.
// PURPOSE: Match Feed Filters/Podcast Replay glass cards without removing controls.
// COLLABORATORS: SettingsViewModel/AppSettings own immediate persistence;
// SleepScheduleService/PlaybackCoordinator own runtime behaviour. Reuse glassCard,
// adaptive Form sizing, page-owned onboarding and the existing mini-player.
// HELP: Playback continues under the chime; only an unanswered check-in triggers
// fade/pause/rewind. Summary describes saved configuration, not a live countdown.
// VALIDATION: Docs/SLEEP_SCHEDULE_DESIGN_AUDIT.md records rendering/navigation
// coverage and physical-device/audio limits. Keep this header and docs in sync.
// All controls still write through SettingsViewModel immediately; disabling
// preserves hours/duration, enabling requests notification permission. Keep all
// five intervals and End of Episode (0). Equal start/end means all day, not off.
// This view describes configuration, not live playback phase. The service owns
// countdowns, chimes, response handling, fade/rewind and manual-timer suspension.
struct SleepScheduleView: View {
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @State private var showHowItWorks = false

    private static let durationPresets = [10, 15, 20, 40, 60]
    private var settings: AppSettings { settingsViewModel.appSettings }

    var body: some View {
        Form {
            introduction
            if settings.sleepScheduleEnabled {
                activeHours
                checkInFrequency
                scheduleSummary
            }
            howItWorks
        }
        .responsiveListSizing()
        .listSectionSpacing(AdaptiveLayoutMetrics.settingsSectionSpacing)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .onboardingTip(.sleepSchedule)
        .navigationTitle("Sleep Schedule")
        .responsiveInlineNavigationTitle("Sleep Schedule")
        .appNavigationBackButton()
        .miniPlayerBar()
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.purple)
                        .accessibilityHidden(true)
                    Spacer()
                    Text(settings.sleepScheduleEnabled ? "On" : "Off")
                        .font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.purple.opacity(0.16), in: Capsule())
                        .accessibilityLabel(settings.sleepScheduleEnabled ? "Schedule on" : "Schedule off")
                }
                Text("Drift off.\nKeep your place.")
                    .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose your listening hours and how often Autohop checks if you’re still awake. If you fall asleep, it fades out and saves your place.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: enabledBinding) {
                    Label {
                        Text("Sleep Schedule").fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "bed.double.fill").foregroundStyle(.purple)
                    }
                    .font(.body)
                }
                .accessibilityIdentifier("sleepSchedule.enabled")
                Text(settings.sleepScheduleEnabled
                     ? "Changes save automatically. Your schedule repeats every day."
                     : "Off — your saved hours and check-in interval are kept for next time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.35), lineWidth: 1))
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    private var activeHours: some View {
        card("Active Hours", icon: "moon.stars", explanation: "Choose when Sleep Schedule can check in. It only counts time while you’re playing a podcast.") {
            timePicker("Start", selection: startTimeBinding, identifier: "sleepSchedule.start")
            Divider()
            timePicker("End", selection: endTimeBinding, identifier: "sleepSchedule.end")
            Text(windowDescription)
                .font(.subheadline).foregroundStyle(.purple)
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.sleepScheduleStartMinutes == settings.sleepScheduleEndMinutes
                 ? "Uses this device’s local time. With matching start and end times, the schedule is available whenever you listen."
                 : "Uses this device’s local time. When these hours end, check-ins stop and your podcast continues normally.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // A separate label and picker avoid horizontal compression at large text
    // sizes; retain the native time editor and the user's 12/24-hour preference.
    private func timePicker(_ title: String, selection: Binding<Date>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkInFrequency: some View {
        card("Ask Every", icon: "timer", explanation: "Choose how much playback you want between check-ins, or check in when an episode ends.") {
            VStack(spacing: 0) {
                ForEach(Self.durationPresets, id: \.self) { minutes in
                    durationRow(title: "\(minutes) minutes", minutes: minutes)
                    Divider()
                }
                durationRow(title: "End of Episode", minutes: 0)
            }
            Text("A soft chime plays for up to a minute while your podcast continues. Respond to start the next check-in cycle.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scheduleSummary: some View {
        card("Your Schedule", icon: "checkmark.circle", explanation: windowDescription) {
            Text(settings.sleepScheduleDurationMinutes <= 0
                 ? "Check in at each episode boundary while you listen during these hours."
                 : "Check in after every \(settings.sleepScheduleDurationMinutes) minutes of playback during these hours.")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Label("Setting the regular Sleep Timer overrides this schedule for that listening session.", systemImage: "moon.zzz")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorks: some View {
        Section {
            DisclosureGroup(isExpanded: $showHowItWorks) {
                VStack(alignment: .leading, spacing: 16) {
                    explanation("Still awake?", text: "Tap Still Listening in the app or on the lock-screen notification. Playback controls, including play/pause, skip and seek, also count as a response.")
                    explanation("Fallen asleep?", text: "Without a response, playback fades out over 30 seconds, pauses and returns to where the chime began. At an episode boundary, it returns to the start of the next episode.")
                    explanation("Prefer a fixed cutoff?", text: "Use the regular Sleep Timer on the Player. It takes priority for that session without changing your saved schedule.")
                    explanation("Lock-screen prompts", text: "When you first turn this on, Autohop asks for notification permission. If notifications are off, you can still respond to the chime using playback controls or the in-app Still Listening button.")
                }.padding(.top, 12)
            } label: {
                Label("How Sleep Schedule Works", systemImage: "questionmark.circle")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .glassCard(cornerRadius: 12)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    private func explanation(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(_ title: String, icon: String, explanation: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(.purple) }
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Text(explanation).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    private var windowDescription: String {
        let start = settings.sleepScheduleStartMinutes
        let end = settings.sleepScheduleEndMinutes
        if start == end { return "All day — matching start and end times keep the schedule available for 24 hours." }
        let hours = "Every day, \(timeLabel(start)) to \(timeLabel(end))"
        return start > end ? hours + " the following day." : hours + "."
    }

    private func timeLabel(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                         second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func durationRow(title: String, minutes: Int) -> some View {
        let selected = settings.sleepScheduleDurationMinutes == minutes
        return Button {
            settingsViewModel.appSettings.sleepScheduleDurationMinutes = minutes
        } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.purple : Color.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        // Multiple controls share a Form row. Plain styling keeps each tap
        // scoped to its own interval instead of activating the entire row.
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("sleepSchedule.duration.\(minutes)")
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.sleepScheduleEnabled },
            set: { isOn in
                settingsViewModel.appSettings.sleepScheduleEnabled = isOn
                // Turning the schedule on is a user opt-in to its lock-screen
                // "still listening?" prompt, so request notification permission
                // now (no-op if already decided).
                if isOn { NotificationService.shared.requestPermission() }
            }
        )
    }

    private var startTimeBinding: Binding<Date> {
        minutesBinding(\.sleepScheduleStartMinutes)
    }

    private var endTimeBinding: Binding<Date> {
        minutesBinding(\.sleepScheduleEndMinutes)
    }

    /// Bridges a minutes-from-midnight Int setting to a Date for DatePicker.
    private func minutesBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = settingsViewModel.appSettings[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                settingsViewModel.appSettings[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }
}
