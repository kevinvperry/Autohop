import SwiftUI

// AI CONTEXT — Views/CoachMark.swift (onboarding coach marks / tips).
// A small, deliberately non-annoying tip system (ONBOARDING_PLAN.md Phase 5).
// `OnboardingTip` defines each tip's copy and per-tip "seen" persistence
// (UserDefaults `tip.<case>.seen`). OnboardingCoordinator owns the policy — one
// visible at a time, never re-shown after "Got it", capped per session. AppState
// retains requestTip/dismissActiveTip compatibility façades. Views call
// `onboardingCoordinator.requestTip(_:)` on first arrival at
// their surface; `CoachMarkOverlay` (mounted once in RootView, behind sheets)
// renders the active tip as a bottom card. The overlay scrolls only when short
// viewports or large Dynamic Type make the whole card taller than the space
// offered by RootView; this keeps both the copy and dismissal action reachable
// without introducing fragile control-specific anchor coordinates. Everything
// a tip teaches also lives permanently in Menu → Support, so dismissing loses
// nothing.

enum OnboardingTip: String, CaseIterable {
    case priorityStack
    case swipeActions
    case playerPanels
    case speed
    case sleepSchedule

    var title: String {
        switch self {
        case .priorityStack: return "This is your Priority Stack"
        case .swipeActions:  return "Swipe for quick actions"
        case .playerPanels:  return "Three swipes, one player"
        case .speed:         return "Find your speed"
        case .sleepSchedule: return "Drift off without losing your place"
        }
    }

    var message: String {
        switch self {
        case .priorityStack:
            return "Autohop plays the newest episode from each show, top to bottom. Tap Priority and drag to set what comes first."
        case .swipeActions:
            return "Swipe any episode to Play Next or Play Last, or to Archive it. No menus needed."
        case .playerPanels:
            return "Swipe across to see episode details and chapters. Everything stays in one place while you listen."
        case .speed:
            return "Tap the sound controls to set your speed and trim silences. Each show remembers its own settings."
        case .sleepSchedule:
            return "Set it once and Autohop fades playback out when you stop responding at night, then rewinds to where you dozed off."
        }
    }

    var icon: String {
        switch self {
        case .priorityStack: return "square.stack.3d.up"
        case .swipeActions:  return "hand.draw"
        case .playerPanels:  return "rectangle.3.group"
        case .speed:         return "speedometer"
        case .sleepSchedule: return "moon.zzz.fill"
        }
    }

    private var seenKey: String { "tip.\(rawValue).seen" }
    var isSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }
    func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }
}

/// Mounted once in RootView (behind sheets). Renders the current `activeTip` as
/// a dismissible bottom card; renders nothing when there is no active tip.
struct CoachMarkOverlay: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator

    var body: some View {
        if let tip = onboardingCoordinator.activeTip {
            ScrollView(.vertical) {
                VStack {
                    Spacer(minLength: 16)
                    card(tip)
                        .adaptiveContentWidth(.prose)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // A viewport-relative minimum keeps an ordinary coach mark at
                // the bottom. When accessibility text makes the card taller,
                // the content grows naturally and the ScrollView makes the
                // complete card—including “Got it”—reachable.
                .containerRelativeFrame(.vertical, alignment: .bottom)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: onboardingCoordinator.activeTip)
        }
    }

    private func card(_ tip: OnboardingTip) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tip.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.purple))

            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text(tip.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(white: 0.7))
                    .fixedSize(horizontal: false, vertical: true)

                Button { onboardingCoordinator.dismissActiveTip() } label: {
                    Text("Got it")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.purple)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.15))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.purple.opacity(0.35), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
