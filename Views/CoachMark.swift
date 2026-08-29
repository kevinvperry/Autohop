import SwiftUI

// AI CONTEXT — Views/CoachMark.swift (onboarding coach marks / tips).
// A high-contrast, page-scoped tip system (ONBOARDING_PLAN.md Phase 5).
// `OnboardingTip` defines each tip's copy and per-tip "seen" persistence
// (UserDefaults `tip.<case>.seen`). OnboardingCoordinator owns the policy — one
// visible at a time, never re-shown after an explicit dismissal, capped per
// session. Every requesting page must use onboardingTip(_:when:), whose
// disappearance cancels (but does not mark seen) its tip so guidance can never
// leak into unrelated navigation destinations. CoachMarkOverlay renders the
// active tip as a deliberately non-Autohop white card. It scrolls only when short
// viewports or large Dynamic Type make the whole card taller than the space
// offered by RootView; this keeps both the copy and dismissal action reachable
// without introducing fragile control-specific anchor coordinates. Everything
// a tip teaches also lives permanently in Menu → Support, so dismissing loses
// nothing.

enum OnboardingTip: String, CaseIterable {
    case discover
    case priorityStack
    case swipeActions
    case playerPanels
    case upNext
    case stats
    case downloads
    case sleepSchedule
    case settings
    case subscriptionAutomation
    case feedFilters

    var title: String {
        switch self {
        case .discover: return "Find shows that fit you"
        case .priorityStack: return "This is your Priority Stack"
        case .swipeActions:  return "Swipe for quick actions"
        case .playerPanels:  return "Three swipes, one player"
        case .upNext:        return "Up Next builds itself"
        case .stats:         return "Your listening, explained"
        case .downloads:     return "Ready even when offline"
        case .sleepSchedule: return "Drift off without losing your place"
        case .settings:      return "Autohop handles the housekeeping"
        case .subscriptionAutomation: return "Tune each show separately"
        case .feedFilters: return "Choose what Autohop downloads"
        }
    }

    var message: String {
        switch self {
        case .discover:
            return "Browse charts by country and category, or search for a specific podcast. Open a show to preview it before subscribing."
        case .priorityStack:
            return "Autohop plays the newest episode from each show, top to bottom. Tap Priority and drag to set what comes first."
        case .swipeActions:
            return "Swipe any episode to Play Next or Play Last, or to Archive it. No menus needed."
        case .playerPanels:
            return "Swipe between Playing, Details and Chapters. Sound Controls sets speed, Trim Silence, Vocal Boost and Shared Listening; each show remembers its own choices."
        case .upNext:
            return "Downloaded episodes are ordered automatically from your Priority Stack. Swipe a row to play, move or archive it; pinned choices override the automatic order."
        case .stats:
            return "Switch between this or last week, month and year, or Lifetime. Tap a Top Show to reveal its completion, saved-time and listening detail."
        case .downloads:
            return "See active transfers, episodes stored on this device and recently archived items. Downloads stay on this device so playback works offline."
        case .sleepSchedule:
            return "Set it once and Autohop fades playback out when you stop responding at night, then rewinds to where you dozed off."
        case .settings:
            return "Auto Archive tidies older episodes, Release Radar learns when shows publish, and private iCloud Sync keeps your library and listening state aligned."
        case .subscriptionAutomation:
            return "Set playback and download rules for this show. Play Instant can interrupt for a new favourite, while Auto Archive controls what is kept."
        case .feedFilters:
            return "These rules affect automatic downloads only—manual Play and Download actions still work. Include rules choose wanted episodes; Exclude rules always reject a match. Use All or Any to combine enabled Include rules, then Preview Matches before relying on them."
        }
    }

    var icon: String {
        switch self {
        case .discover: return "safari.fill"
        case .priorityStack: return "square.stack.3d.up"
        case .swipeActions:  return "hand.draw"
        case .playerPanels:  return "rectangle.3.group"
        case .upNext:        return "text.line.first.and.arrowtriangle.forward"
        case .stats:         return "chart.bar.xaxis"
        case .downloads:     return "arrow.down.circle.fill"
        case .sleepSchedule: return "moon.zzz.fill"
        case .settings:      return "gearshape.2.fill"
        case .subscriptionAutomation: return "bolt.fill"
        case .feedFilters: return "line.3.horizontal.decrease.circle.fill"
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: tip.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.black))

                Text("QUICK TIP")
                    .font(.caption.weight(.black))
                    .tracking(1.4)
                    .foregroundStyle(.black.opacity(0.62))

                Spacer(minLength: 12)

                Button { onboardingCoordinator.dismissActiveTip() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tip")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tip.title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(.black)
                Text(tip.message)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.black.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { onboardingCoordinator.dismissActiveTip() } label: {
                Text("Got it — close tip")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.black, lineWidth: 2))
        )
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
    }
}

private struct OnboardingTipScopeModifier: ViewModifier {
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator
    let tip: OnboardingTip
    let isEligible: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { requestIfEligible() }
            .onChange(of: isEligible) { _, _ in requestIfEligible() }
            .onDisappear { onboardingCoordinator.cancelActiveTip(tip) }
    }

    private func requestIfEligible() {
        if isEligible {
            onboardingCoordinator.requestTip(tip)
        } else {
            onboardingCoordinator.cancelActiveTip(tip)
        }
    }
}

extension View {
    /// Owns a contextual onboarding tip for exactly this view's visible lifetime.
    func onboardingTip(_ tip: OnboardingTip, when isEligible: Bool = true) -> some View {
        modifier(OnboardingTipScopeModifier(tip: tip, isEligible: isEligible))
    }
}
