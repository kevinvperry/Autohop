import SwiftUI

// AI CONTEXT — Views/SleepScheduleView.swift ("Sleep Schedule" page, from the
// Menu sheet). Configures the recurring nightly sleep timer
// (SleepScheduleService): on/off toggle, start/end time pickers (window may
// span midnight), and a duration picker — presets 10/15/20/40/60 min plus an
// End of Episode mode (stored as 0 minutes). All values persist to
// AppSettings.sleepSchedule*; AppState re-syncs SleepScheduleService whenever
// settings change. Pure UI — no schedule logic lives here.
struct SleepScheduleView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private static let durationPresets = [10, 15, 20, 40, 60]

    var body: some View {
        Form {
            Section {
                Toggle("Sleep Schedule", isOn: enabledBinding)
            } footer: {
                Text("Every night during the active hours, playback pauses after the chosen duration and asks if you're still listening. Press play anywhere — lock screen, earbuds or in the app — to keep going. No response and Autohop assumes you're asleep, stopping at the spot you last heard.")
            }

            if appState.settingsStore.appSettings.sleepScheduleEnabled {
                Section("Active Hours") {
                    DatePicker("Start", selection: startTimeBinding, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: endTimeBinding, displayedComponents: .hourAndMinute)
                }

                Section {
                    ForEach(Self.durationPresets, id: \.self) { minutes in
                        durationRow(title: "\(minutes) minutes", minutes: minutes)
                    }
                    durationRow(title: "End of Episode", minutes: 0)
                } header: {
                    Text("Ask Every")
                } footer: {
                    Text("How long playback runs before the \u{201C}Are you still listening?\u{201D} prompt. End of Episode asks at each episode boundary instead. Setting the regular Sleep Timer overrides the schedule for that session.")
                }
            }
        }
        .listSectionSpacing(28)
        .navigationTitle("Sleep Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
            }
        }
        .miniPlayerBar()
    }

    // MARK: - Duration row

    private func durationRow(title: String, minutes: Int) -> some View {
        Button {
            appState.settingsStore.appSettings.sleepScheduleDurationMinutes = minutes
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if appState.settingsStore.appSettings.sleepScheduleDurationMinutes == minutes {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.sleepScheduleEnabled },
            set: { appState.settingsStore.appSettings.sleepScheduleEnabled = $0 }
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
                let minutes = appState.settingsStore.appSettings[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                appState.settingsStore.appSettings[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }
}
