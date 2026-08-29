import SwiftUI

// AI CONTEXT — Views/GettingStartedChecklist.swift (onboarding momentum card).
// A dismissible checklist shown at the top of the Priority Stack (PodcastsView)
// for new users (ONBOARDING_PLAN.md Phase 7). Reads first-run flags for its
// completion state: subscribe + play from AppSettings, reorder from the
// UserDefaults signal set in PodcastsView.onMove. Auto-hides once all three are
// done or the user dismisses it (AppSettings.dismissedGettingStarted). Renders
// nothing when not applicable. Its footer carries the one-time lean-defaults
// expectation note (Phase 7 / §5-E). This is a dedicated onboarding surface,
// so it uses the same white/black visual language and prominent close control
// as CoachMarkOverlay. While visible it supersedes—and marks seen—the redundant
// Priority Stack coach mark, guaranteeing one teaching card on Subscriptions.
struct GettingStartedChecklist: View {
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    static let reorderedKey = "onboarding.reorderedPriority"

    private var subscribed: Bool { settingsViewModel.appSettings.hasSubscribedFirstShow }
    private var played: Bool { settingsViewModel.appSettings.hasPlayedFirstEpisode }
    private var reordered: Bool { UserDefaults.standard.bool(forKey: Self.reorderedKey) }
    private var allDone: Bool { subscribed && played && reordered }
    private var dismissed: Bool { settingsViewModel.appSettings.dismissedGettingStarted }

    static func shouldShow(settings: AppSettings) -> Bool {
        let reordered = UserDefaults.standard.bool(forKey: reorderedKey)
        let allDone = settings.hasSubscribedFirstShow
            && settings.hasPlayedFirstEpisode
            && reordered
        return !settings.dismissedGettingStarted && !allDone
    }

    var body: some View {
        if !dismissed && !allDone {
            card
                .onAppear {
                    // The checklist already teaches Priority Stack reordering;
                    // never stack a second card carrying the same lesson.
                    OnboardingTip.priorityStack.markSeen()
                }
        }
    }

    @ViewBuilder private var card: some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Getting started")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                Spacer()
                Button {
                    settingsViewModel.appSettings.dismissedGettingStarted = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close getting started")
            }

            row("Subscribe to your first show", done: subscribed)
            row("Play an episode", done: played)
            row("Reorder your Priority Stack", done: reordered)

            Text("Autohop keeps the latest episode and tidies older ones to save space — change this per show in its settings.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.black.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(16)
        content
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.black, lineWidth: 2))
            )
            .shadow(color: .black.opacity(0.42), radius: 18, y: 7)
    }

    private func row(_ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(done ? .green : Color.black.opacity(0.48))
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(done ? Color.black.opacity(0.52) : .black)
                .strikethrough(done, color: Color.black.opacity(0.45))
            Spacer()
        }
    }
}
