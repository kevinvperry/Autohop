import SwiftUI

// AI CONTEXT — Views/GettingStartedChecklist.swift (onboarding momentum card).
// A dismissible checklist shown at the top of the Priority Stack (PodcastsView)
// for new users (ONBOARDING_PLAN.md Phase 7). Reads first-run flags for its
// completion state: subscribe + play from AppSettings, reorder from the
// UserDefaults signal set in PodcastsView.onMove. Auto-hides once all three are
// done or the user dismisses it (AppSettings.dismissedGettingStarted). Renders
// nothing when not applicable. Its footer carries the one-time lean-defaults
// expectation note (Phase 7 / §5-E).
struct GettingStartedChecklist: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    static let reorderedKey = "onboarding.reorderedPriority"

    private var subscribed: Bool { settingsViewModel.appSettings.hasSubscribedFirstShow }
    private var played: Bool { settingsViewModel.appSettings.hasPlayedFirstEpisode }
    private var reordered: Bool { UserDefaults.standard.bool(forKey: Self.reorderedKey) }
    private var allDone: Bool { subscribed && played && reordered }
    private var dismissed: Bool { settingsViewModel.appSettings.dismissedGettingStarted }

    var body: some View {
        if !dismissed && !allDone {
            card
        }
    }

    @ViewBuilder private var card: some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Getting started")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    settingsViewModel.appSettings.dismissedGettingStarted = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(white: 0.55))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            row("Subscribe to your first show", done: subscribed)
            row("Play an episode", done: played)
            row("Reorder your Priority Stack", done: reordered)

            Text("Autohop keeps the latest episode and tidies older ones to save space — change this per show in its settings.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(16)
        if #available(iOS 26, *) {
            content
                .glassCard(cornerRadius: 16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.purple.opacity(0.25), lineWidth: 1))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.purple.opacity(0.25), lineWidth: 1))
            )
        }
    }

    private func row(_ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(done ? .green : Color(white: 0.4))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(done ? Color(white: 0.55) : .white)
                .strikethrough(done, color: Color(white: 0.5))
            Spacer()
        }
    }
}
