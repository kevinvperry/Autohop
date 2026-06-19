import SwiftUI

// AI CONTEXT — Views/RootView.swift
// Navigation root. KEY ARCHITECTURE: PlayerView is the PERMANENT root of the
// NavigationStack — it is never torn down, so AVFoundation state survives all
// navigation; every other page (starting with PodcastsView via AppRoute) is
// pushed on top. The .autohopReturnToPlayer notification pops the path to
// reveal the player from anywhere (posted by MiniPlayerBar on pushed pages).
// Shared nav chrome lives here: MiniPlayerBar (+ .miniPlayerBar() modifier)
// and SheetCloseButton. NavRules: pushed page = back chevron top-left,
// informational sheet = ✕ top-right, editing sheet = Cancel/Save.
// Also shows the launch splash overlay briefly on cold start. MiniPlayerBar
// artwork uses a 40 pt CachedArtworkImage target so the always-visible chrome
// reuses the shared artwork cache without decoding full covers.
//
// ONBOARDING / LAUNCH ROUTING (ONBOARDING_PLAN.md; FEATURES.md §18): on cold
// start the .task decides the initial navigationPath while the splash is up —
// a brand-new user (appState.isFirstRunNoSubscriptions) gets WelcomeView as a
// fullScreenCover; otherwise the user's Open-at-launch preference
// (AppSettings.launchScreen) routes to Player (root) / Subscriptions / Discover.
// RootView also hosts the onboarding chrome layered into its ZStack (above pages,
// BELOW sheets + splash): CoachMarkOverlay (appState.activeTip), the
// onboardingToast overlay, plus the FirstSubscribeCard .sheet (keyed by
// FirstSubscribeContext on the .autohopFirstSubscription notification). handleWelcome
// records hasCompletedWelcome and routes per the user's Welcome choice.
enum AppRoute: Hashable {
    case podcasts
    case sleepSchedule
    case discover
}

extension Notification.Name {
    static let autohopReturnToPlayer = Notification.Name("autohopReturnToPlayer")
    /// Posted by the Menu to push Discover as a full page on the main stack
    /// (rather than inside the Menu sheet).
    static let autohopOpenDiscover = Notification.Name("autohopOpenDiscover")
    /// Posted by Settings → Manage podcasts. Subscriptions (PodcastsView) is the
    /// app home page sitting beneath the Menu sheet, so this just dismisses the
    /// Menu to reveal it as a full page — never a duplicate pushed inside the sheet.
    static let autohopOpenSubscriptions = Notification.Name("autohopOpenSubscriptions")
    /// Posted by AppState when the user's first ever real subscription is added
    /// via a single deliberate Subscribe (not a bulk OPML import). `object` is the
    /// new Subscription's `id` (UUID). Drives the first-run "You're all set"
    /// moment (ONBOARDING_PLAN.md Phase 3); harmless if no one is listening yet.
    static let autohopFirstSubscription = Notification.Name("autohopFirstSubscription")
}

/// Standard close control for informational sheets (NavRules-SheetClose).
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
        }
        .accessibilityLabel("Close")
    }
}

/// Persistent now-playing bar docked at the bottom of every pushed page.
/// Tapping the bar pops the navigation stack to reveal the always-alive
/// PlayerView; the trailing button toggles playback in place. Renders
/// nothing when no episode is loaded.
struct MiniPlayerBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let episode = appState.currentPlayerEpisode {
            let subscription = appState.subscriptionStore.subscription(id: episode.subscriptionID)
            let duration = episode.durationSeconds ?? 0
            let progress = duration > 0 ? min(1, max(0, appState.currentPlayerTime / duration)) : 0

            // Edge-to-edge: opaque full-width bar so page content never shows
            // through or scrolls visibly beneath it.
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color(white: 0.25))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.purple)
                                .frame(width: geo.size.width * progress)
                        }
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    CachedArtworkImage(url: subscription?.artworkURL, targetSize: CGSize(width: 40, height: 40)) {
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay(
                                Image(systemName: "waveform")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.purple.opacity(0.7))
                            )
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let showTitle = subscription?.title {
                                Text(showTitle)
                                    .lineLimit(1)
                            }
                            if duration > 0 {
                                if subscription?.title != nil { Text("•") }
                                Text("-\(formatRemaining(max(0, duration - appState.currentPlayerTime)))")
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await appState.togglePlayPause() }
                    } label: {
                        let playIcon = Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())

                        // Centred play/pause icon in a round iOS glass button.
                        if #available(iOS 26, *) {
                            playIcon.glassEffect(in: Circle())
                        } else {
                            playIcon.background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(appState.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(
                Color(red: 0.10, green: 0.10, blue: 0.13)
                    .ignoresSafeArea(edges: .bottom)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
            }
            .accessibilityLabel("Return to Player")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

extension View {
    /// Docks the MiniPlayerBar at the bottom of a pushed page.
    func miniPlayerBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}

/// Identifiable wrapper so the first-subscribe card can be presented via
/// `.sheet(item:)` keyed on the new subscription's id.
private struct FirstSubscribeContext: Identifiable { let id: UUID }

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showLaunchView = true
    @State private var showWelcome = false
    @State private var firstSubscribeContext: FirstSubscribeContext?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        ZStack {
            // PlayerView stays alive for the entire app lifetime so AVFoundation is never torn down.
            NavigationStack(path: $navigationPath) {
                PlayerView()
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .podcasts:
                            PodcastsView()
                        case .sleepSchedule:
                            SleepScheduleView()
                        case .discover:
                            DiscoverView()
                        }
                    }
            }

            // Onboarding coach marks float above pages but below sheets and the
            // launch splash (so they never clash with Welcome / the first-subscribe
            // card). Triggered by views via appState.requestTip(_:).
            CoachMarkOverlay()
                .allowsHitTesting(appState.activeTip != nil)

            if let toast = appState.onboardingToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color(red: 0.12, green: 0.12, blue: 0.15)))
                        .overlay(Capsule().stroke(Color.purple.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.bottom, 90)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(2.8))
                    withAnimation { appState.onboardingToast = nil }
                }
            }

            if showLaunchView {
                LaunchLoadingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView { outcome in handleWelcome(outcome) }
        }
        .sheet(item: $firstSubscribeContext) { context in
            FirstSubscribeCard(subscriptionID: context.id)
        }
        .task {
            // First-run routing (ONBOARDING_PLAN.md Phase 2). Decided while the
            // splash is still up so the Welcome cover (same purple background)
            // is already in place when the splash fades.
            if appState.isFirstRunNoSubscriptions {
                showWelcome = true
            } else {
                // Honour the user's chosen launch screen (App Settings → Startup).
                // Discover/Subscriptions are pushed above the always-alive Player
                // root, so the back chevron unwinds Discover → Subscriptions → Player.
                switch appState.settingsStore.appSettings.launchScreen {
                case .player:
                    break
                case .subscriptions:
                    navigationPath.append(AppRoute.podcasts)
                case .discover:
                    navigationPath.append(AppRoute.podcasts)
                    navigationPath.append(AppRoute.discover)
                }
            }
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.35)) {
                showLaunchView = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopReturnToPlayer)) { _ in
            navigationPath = NavigationPath()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopOpenDiscover)) { _ in
            navigationPath.append(AppRoute.discover)
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopFirstSubscription)) { note in
            // Posted by AppState on the user's first deliberate subscribe. Present
            // the "You're all set" card (ONBOARDING_PLAN.md Phase 3).
            if let id = note.object as? UUID {
                firstSubscribeContext = FirstSubscribeContext(id: id)
            }
        }
    }

    /// Maps a Welcome choice to a route, recording that Welcome is done so it
    /// never reappears. Find shows lands on Discover (with Subscriptions behind
    /// it); Import and Skip land on the Subscriptions page.
    private func handleWelcome(_ outcome: WelcomeOutcome) {
        appState.settingsStore.appSettings.hasCompletedWelcome = true
        showWelcome = false
        switch outcome {
        case .findShows:
            navigationPath.append(AppRoute.podcasts)
            navigationPath.append(AppRoute.discover)
        case .importedSubscriptions, .skip:
            navigationPath.append(AppRoute.podcasts)
        }
    }
}

struct LaunchLoadingView: View {
    @State private var isAnimating = false

    private let purpleBars: [(height: CGFloat, color: Color)] = [
        (52, Color(red: 0.66, green: 0.62, blue: 0.91)),
        (116, Color(red: 0.77, green: 0.74, blue: 0.94)),
        (80, Color(red: 0.69, green: 0.66, blue: 0.93)),
        (36, Color(red: 0.60, green: 0.56, blue: 0.89))
    ]

    private let greenBars: [(height: CGFloat, color: Color)] = [
        (44, Color(red: 0.11, green: 0.73, blue: 0.33)),
        (116, Color(red: 0.15, green: 0.82, blue: 0.38)),
        (72, Color(red: 0.11, green: 0.73, blue: 0.33)),
        (30, Color(red: 0.09, green: 0.66, blue: 0.29).opacity(0.75))
    ]

    var body: some View {
        ZStack {
            Color(red: 0.176, green: 0.149, blue: 0.502)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    waveformGroup(purpleBars, phaseOffset: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.24))
                        .scaleEffect(isAnimating ? 1.06 : 0.96)

                    waveformGroup(greenBars, phaseOffset: 0.18)
                }
                .frame(height: 132)

                Text("Autohop")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Loading your queue")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private func waveformGroup(_ bars: [(height: CGFloat, color: Color)], phaseOffset: Double) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(bar.color)
                    .frame(width: 24, height: bar.height)
                    .scaleEffect(y: isAnimating ? 1 + CGFloat(index % 2 == 0 ? 0.12 : -0.08) : 1 - CGFloat(index % 2 == 0 ? 0.08 : -0.12))
                    .animation(
                        .easeInOut(duration: 0.76 + Double(index) * 0.08)
                            .repeatForever(autoreverses: true)
                            .delay(phaseOffset + Double(index) * 0.05),
                        value: isAnimating
                    )
            }
        }
    }
}
