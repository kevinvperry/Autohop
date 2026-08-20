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
// PERF-1: MiniPlayerBar's progress bar + remaining-time readout observe the
// @EnvironmentObject PlaybackClock (playbackClock.time), NOT
// appState.currentPlayerTime — AppState no longer publishes the 2 Hz tick, so
// reading the proxy in body would render stale time.
// Stage 13 observation is narrow: MiniPlayerBar reads PlaybackCoordinator and
// SubscriptionStore directly, while onboarding chrome reads
// OnboardingCoordinator. RootView retains AppState only for high-level routing,
// settings-backed launch decisions, and cross-domain user commands.
//
// ONBOARDING / LAUNCH ROUTING (ONBOARDING_PLAN.md; FEATURES.md §18): on cold
// start the .task decides the initial navigationPath while the splash is up —
// a brand-new user (onboardingCoordinator.isFirstRunNoSubscriptions) gets WelcomeView as a
// fullScreenCover; otherwise the user's Open-at-launch preference
// (AppSettings.launchScreen) routes to Player (root) / Subscriptions / Discover.
// RootView also hosts the onboarding chrome layered into its ZStack (above pages,
// BELOW sheets + splash): CoachMarkOverlay (onboardingCoordinator.activeTip),
// the onboarding toast overlay, plus the FirstSubscribeCard .sheet (keyed by
// FirstSubscribeContext from AppRoutingCoordinator's typed onboarding output).
// RootView retains its local NavigationPath; AppRoutingCoordinator selects typed
// launch/menu/notification commands and translates legacy notifications.
// handleWelcome records hasCompletedWelcome and routes per the user's choice.
// WIDGET STAGE 3: typed deep-link commands preserve the permanent Player root.
// Episode identities are resolved against the live store before appending an
// EpisodeDetail route; stale identities are logged and ignored. Up Next resets
// to Player then asks PlayerView to present its one existing sheet.
// LISTENING RECAPS: a launch .task re-arms the opt-in recap notifications from
// saved settings (NotificationService.scheduleRecaps, idempotent) so they
// survive relaunch/reinstall even if the user never reopens the Recaps screen.
// Notification taps are routed through .autohopOpenStats and open Stats directly
// on the matching Last Week / Last Month / Last Year view.
enum AppRoute: Hashable {
    case podcasts
    case stats(ListeningRecapPeriod?)
    case sleepSchedule
    case discover
    /// Search and show-preview routes belong to the root path. Keeping these
    /// values out of Discover's local destination state lets Back and the
    /// mini-player reliably unwind the same NavigationStack.
    case podcastSearch(countryCode: String)
    case podcast(subscriptionID: UUID)
    case podcastPreview(PodcastSearchResult)
    case episode(subscriptionID: UUID, episodeID: UUID)
}

extension Notification.Name {
    static let autohopReturnToPlayer = Notification.Name("autohopReturnToPlayer")
    /// Posted by the Menu to push Discover as a full page on the main stack
    /// (rather than inside the Menu sheet).
    static let autohopOpenDiscover = Notification.Name("autohopOpenDiscover")
    /// Posted by NotificationService when a Listening Recap notification is tapped.
    /// `object` is an optional ListeningRecapPeriod; nil opens the default Stats page.
    static let autohopOpenStats = Notification.Name("autohopOpenStats")
    /// Posted by Settings → Manage podcasts. Subscriptions (PodcastsView) is the
    /// app home page sitting beneath the Menu sheet, so this just dismisses the
    /// Menu to reveal it as a full page — never a duplicate pushed inside the sheet.
    static let autohopOpenSubscriptions = Notification.Name("autohopOpenSubscriptions")
    /// Temporary compatibility output posted alongside OnboardingCoordinator's
    /// typed first-subscription event for any observer not migrated yet.
    static let autohopFirstSubscription = Notification.Name("autohopFirstSubscription")
    /// Internal typed-route adapter: PlayerView owns the single Up Next sheet.
    static let autohopOpenUpNext = Notification.Name("autohopOpenUpNext")
}

// Root navigation actions are injected into every pushed page. Optional
// defaults keep previews and isolated views functional, while production pages
// avoid relying on NotificationCenter or a descendant presentation's dismiss
// semantics to manipulate RootView's one NavigationPath.
private struct ReturnToPlayerActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct RootBackActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var returnToPlayerAction: (() -> Void)? {
        get { self[ReturnToPlayerActionKey.self] }
        set { self[ReturnToPlayerActionKey.self] = newValue }
    }

    var rootBackAction: (() -> Void)? {
        get { self[RootBackActionKey.self] }
        set { self[RootBackActionKey.self] = newValue }
    }
}

/// Standard close control for informational sheets (NavRules-SheetClose).
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
        }
        // AI CONTEXT — Escape closes informational sheets when an iPad hardware
        // keyboard is attached. The visible button remains the sole focus target.
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
    }
}

/// Persistent now-playing bar docked at the bottom of every pushed page.
/// Tapping the bar pops the navigation stack to reveal the always-alive
/// PlayerView; the trailing button toggles playback in place. Renders
/// nothing when no episode is loaded.
struct MiniPlayerBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    /// 2 Hz playback tick (PERF-1): the progress bar / remaining-time readout observe
    /// this dedicated clock so AppState no longer publishes on every 0.5 s update.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Environment(\.returnToPlayerAction) private var returnToPlayerAction

    var body: some View {
        if let episode = playbackCoordinator.currentEpisode {
            let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
            let duration = episode.durationSeconds ?? 0
            let progress = duration > 0 ? min(1, max(0, playbackClock.time / duration)) : 0

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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 5) {
                                if let showTitle = subscription?.title {
                                    Text(showTitle).lineLimit(1)
                                }
                                if duration > 0 {
                                    if subscription?.title != nil { Text("•") }
                                    remainingTime(duration)
                                }
                            }
                            if duration > 0 {
                                remainingTime(duration)
                            } else if let showTitle = subscription?.title {
                                Text(showTitle).lineLimit(1)
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color(white: 0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    Button {
                        Task { await appState.togglePlayPause() }
                    } label: {
                        Group {
                            if playbackCoordinator.isPlaying {
                                MiniPlayerWaveformIcon()
                                    .transition(
                                        .asymmetric(
                                            insertion: .scale(scale: 0.72)
                                                .combined(with: .opacity),
                                            removal: .opacity
                                        )
                                    )
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 1)
                                    .transition(
                                        .scale(scale: 0.72)
                                            .combined(with: .opacity)
                                    )
                            }
                        }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .modifier(MiniPlayerGlassControlStyle())
                            .animation(
                                .smooth(duration: 0.24),
                                value: playbackCoordinator.isPlaying
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playbackCoordinator.isPlaying ? "Pause" : "Play")
                    .accessibilityHint(
                        playbackCoordinator.isPlaying
                            ? "Double-tap to pause playback"
                            : "Double-tap to resume playback"
                    )
                }
                .frame(maxWidth: AdaptiveContentStyle.list.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(
                Color(red: 0.10, green: 0.10, blue: 0.13)
                    .ignoresSafeArea(edges: .bottom)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                AppLogger.shared.info(
                    "navigation.returnToPlayerRequested",
                    "Mini-player requested the permanent player root"
                )
                if let returnToPlayerAction {
                    returnToPlayerAction()
                } else {
                    // Preview/legacy fallback only. RootView injects the direct
                    // action in the running app.
                    NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
                }
            }
            .accessibilityLabel("Return to Player")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func remainingTime(_ duration: TimeInterval) -> some View {
        Text("-\(formatRemaining(max(0, duration - playbackClock.time)))")
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

/// Compact live playback mark for the Mini-Player. A TimelineView avoids owning
/// a repeating Timer and automatically pauses its updates when Reduce Motion is
/// enabled. The button remains semantically a Pause action while this is visible.
private struct MiniPlayerWaveformIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let restingHeights: [CGFloat] = [8, 13, 18, 13, 8]

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 15.0,
                paused: reduceMotion
            )
        ) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(restingHeights.indices, id: \.self) { index in
                    let wave = (
                        sin(time * 5.4 + Double(index) * 1.18) + 1
                    ) / 2
                    let scale = reduceMotion
                        ? 0.72
                        : 0.48 + CGFloat(wave) * 0.52
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white,
                                    Color.purple.opacity(0.82)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: 3,
                            height: max(4, restingHeights[index] * scale)
                        )
                }
            }
            .frame(width: 26, height: 22)
        }
        .accessibilityHidden(true)
    }
}

/// One glass shell for both Mini-Player states so Play and the live waveform
/// morph inside a stable, modern iOS control rather than changing button chrome.
private struct MiniPlayerGlassControlStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(
                    .regular.tint(Color.purple.opacity(0.22)),
                    in: Circle()
                )
                .shadow(
                    color: Color.purple.opacity(0.18),
                    radius: 8,
                    y: 3
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.13), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.24), radius: 7, y: 3)
        }
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
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @State private var showLaunchView = true
    @State private var showWelcome = false
    @State private var firstSubscribeContext: FirstSubscribeContext?
    @State private var navigationPath = NavigationPath()
    @State private var handledExplicitLaunchRoute = false

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
                        case .stats(let recapPeriod):
                            StatsView(initialRecapPeriod: recapPeriod)
                        case .sleepSchedule:
                            SleepScheduleView()
                        case .discover:
                            DiscoverView()
                        case .podcastSearch(let countryCode):
                            PodcastSearchView(countryCode: countryCode)
                        case .podcast(let subscriptionID):
                            PodcastDetailView(subscriptionID: subscriptionID)
                        case .podcastPreview(let result):
                            PodcastDetailView(result: result)
                        case .episode(let subscriptionID, let episodeID):
                            EpisodeDetailView(
                                subscriptionID: subscriptionID,
                                episodeID: episodeID
                            )
                        }
                    }
            }
            .environment(\.returnToPlayerAction) {
                returnToPlayer()
            }
            .environment(\.rootBackAction) {
                popRootNavigation()
            }

            // Onboarding coach marks float above pages but below sheets and the
            // launch splash (so they never clash with Welcome / the first-subscribe
            // card). Triggered by views via OnboardingCoordinator.requestTip(_:).
            CoachMarkOverlay()
                .allowsHitTesting(onboardingCoordinator.activeTip != nil)

            if let toast = onboardingCoordinator.toast {
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
                    withAnimation { onboardingCoordinator.toast = nil }
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
            NotificationService.shared.setListeningRecapHandler { period in
                NotificationCenter.default.post(name: .autohopOpenStats, object: period)
            }
        }
        .task {
            // Re-arm Listening Recap notifications from saved settings at launch
            // (idempotent), so an opted-in user's recaps survive relaunch/reinstall
            // even if they never reopen the Recaps screen.
            let s = settingsViewModel.appSettings
            NotificationService.shared.scheduleRecaps(
                weekly: s.recapWeeklyEnabled,
                monthly: s.recapMonthlyEnabled,
                yearly: s.recapYearlyEnabled
            )
        }
        .task {
            // Stage 5: typed launch selection, while RootView deliberately keeps
            // ownership of its local NavigationPath.
            if let widgetCommand =
                appState.routingCoordinator.consumePendingWidgetCommand() {
                handleRouteCommand(widgetCommand)
            } else if !handledExplicitLaunchRoute,
               let command = appState.routingCoordinator.launchCommand(
                    isFirstRun: onboardingCoordinator.isFirstRunNoSubscriptions,
                    launchScreen: settingsViewModel.appSettings.launchScreen
               ) {
                handleRouteCommand(command)
            }
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.35)) {
                showLaunchView = false
            }
        }
        .onReceive(appState.routingCoordinator.commands) { command in
            handleRouteCommand(command)
            appState.routingCoordinator.acknowledgeWidgetCommand(command)
        }
    }

    private func handleRouteCommand(_ command: AppRouteCommand) {
        switch command {
        case .returnToPlayer:
            returnToPlayer()
        case .openUpNext:
            navigationPath = NavigationPath()
            NotificationCenter.default.post(name: .autohopOpenUpNext, object: nil)
        case .openEpisode(let identity):
            guard let episode = resolveEpisode(identity) else {
                AppLogger.shared.warning(
                    "widget.routeEpisodeMissing",
                    "Widget episode route no longer resolves",
                    metadata: [
                        "subscriptionID": identity.subscriptionID.uuidString
                    ],
                    alwaysPersist: true
                )
                return
            }
            handledExplicitLaunchRoute = true
            showWelcome = false
            navigationPath = NavigationPath()
            navigationPath.append(AppRoute.podcasts)
            navigationPath.append(AppRoute.episode(
                subscriptionID: identity.subscriptionID,
                episodeID: episode.id
            ))
        case .openDiscover:
            handledExplicitLaunchRoute = true
            showWelcome = false
            if navigationPath.isEmpty {
                navigationPath.append(AppRoute.podcasts)
            }
            navigationPath.append(AppRoute.discover)
        case .openStats(let recapPeriod):
            openStats(recapPeriod: recapPeriod)
        case .openSubscriptions:
            handledExplicitLaunchRoute = true
            showWelcome = false
            navigationPath = NavigationPath()
            navigationPath.append(AppRoute.podcasts)
        case .presentWelcome:
            showWelcome = true
        case .presentFirstSubscription(let subscriptionID):
            firstSubscribeContext = FirstSubscribeContext(id: subscriptionID)
        }
    }

    private func returnToPlayer() {
        AppLogger.shared.info(
            "navigation.returnToPlayer",
            "Returning to the permanent player root",
            metadata: ["pathDepth": String(navigationPath.count)]
        )
        navigationPath = NavigationPath()
    }

    private func popRootNavigation() {
        guard !navigationPath.isEmpty else { return }
        AppLogger.shared.info(
            "navigation.rootBack",
            "Popping one page from the root navigation path",
            metadata: ["pathDepthBefore": String(navigationPath.count)]
        )
        navigationPath.removeLast()
    }

    private func resolveEpisode(
        _ identity: WidgetEpisodeIdentity
    ) -> Episode? {
        guard let subscription = appState.subscriptionStore.subscription(
            id: identity.subscriptionID
        ) else { return nil }
        let candidates = subscription.episodes.isEmpty
            ? subscription.latestEpisode.map { [$0] } ?? []
            : subscription.episodes
        return candidates.first {
            PlaybackPositionStore.key(for: $0) == identity.episodeKey
        }
    }

    private func openStats(recapPeriod: ListeningRecapPeriod?) {
        handledExplicitLaunchRoute = true
        showWelcome = false
        firstSubscribeContext = nil
        navigationPath = NavigationPath()
        navigationPath.append(AppRoute.stats(recapPeriod))
    }

    /// Maps a Welcome choice to a route, recording that Welcome is done so it
    /// never reappears. Find shows lands on Discover (with Subscriptions behind
    /// it); Import and Skip land on the Subscriptions page.
    private func handleWelcome(_ outcome: WelcomeOutcome) {
        settingsViewModel.appSettings.hasCompletedWelcome = true
        showWelcome = false
        handleRouteCommand(appState.routingCoordinator.welcomeCompleted(outcome))
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

                Text("Loading Up Next")
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
