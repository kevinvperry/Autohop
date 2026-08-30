import SwiftUI

// AI CONTEXT — Views/MenuSheetView.swift ("Menu" sheet, hamburger ☰ on the
// Subscriptions toolbar). The single gateway to the secondary pages —
// Discover (top item — dismisses the Menu, then posts .autohopOpenDiscover so
// RootView pushes DiscoverView as a full page on the main stack), Stats, Sleep
// Schedule, Listening History, Downloads, App Settings, and Support (last item —
// the in-app User Guide, SupportView, which mirrors the website Support page).
// The root Menu reserves its lower region for MenuMiniPlayer: a richer fixed
// transport card shown only while an episode is loaded. It observes the shared
// PlaybackClock (never creates a timer), uses configured skip intervals and
// opens the permanent Player when its non-control surface is tapped. Pushed
// Menu destinations replace the root, so the card is root-only by construction.
// Its openPlayer action uses RootView's canonical return action, which first
// selects the Player's Playing pane and then dismisses navigation; never make
// this card reveal whichever Details/Chapters pane happened to be selected.
// Skip controls intentionally have no independent dark fill: they inherit the
// card's shared purple-glass surface, while Play/Pause remains the sole solid
// purple transport emphasis. The three transports form one centred cluster
// with deliberate finger-clearance between adjacent targets. Extra bottom
// breathing room lifts the card above the sheet edge.
// Root Menu background and rows deliberately reuse the native grouped palette
// seen on Sleep Schedule: systemGroupedBackground outside, and
// secondarySystemGroupedBackground for the menu group.
// The Menu also dismisses when a Listening Recap notification posts
// .autohopOpenStats, so the app-level Stats route is visible immediately.
// Menu-hosted destinations render CoachMarkOverlay above this sheet's own
// NavigationStack. RootView's overlay is below presented sheets and cannot show
// tips requested by Stats, Downloads, Sleep Schedule or Settings.
// NavRules: one path per page; Find Podcasts lives behind + only; OPML import
// lives in Settings → Subscriptions.
struct MenuSheetView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var queueCoordinator: QueueCoordinator
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @EnvironmentObject private var playbackClock: PlaybackClock
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.returnToPlayerAction) private var returnToPlayerAction

    @State private var appearTime: Date?

    private let logger = AppLogger.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                Button {
                    // Discover opens as a full page on the main stack, not inside
                    // this sheet — dismiss, then ask RootView to push it.
                    dismiss()
                    NotificationCenter.default.post(name: .autohopOpenDiscover, object: nil)
                } label: {
                    // Button labels tint the whole label, so style the icon and
                    // text separately to match the NavigationLink rows below
                    // (accent-coloured icon, primary text) rather than an all-white label.
                    Label {
                        Text("Discover")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "safari")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .listRowBackground(menuRowBackground)

                NavigationLink {
                    StatsView()
                } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
                .listRowBackground(menuRowBackground)

                NavigationLink {
                    SleepScheduleView()
                } label: {
                    Label("Sleep Schedule", systemImage: "moon.zzz")
                }
                .listRowBackground(menuRowBackground)

                NavigationLink {
                    ListeningHistoryView()
                } label: {
                    Label("Listening History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .listRowBackground(menuRowBackground)

                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .listRowBackground(menuRowBackground)

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .listRowBackground(menuRowBackground)

                NavigationLink {
                    SupportView()
                } label: {
                    Label("Support", systemImage: "questionmark.circle")
                }
                .listRowBackground(menuRowBackground)
                }
                .responsiveListSizing()
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)

                MenuMiniPlayer(
                    openPlayer: openPlayer,
                    skipBack: skipBack,
                    togglePlayback: {
                        Task { await appState.togglePlayPause() }
                    },
                    skipForward: skipForward
                )
            }
            .background(menuPageBackground.ignoresSafeArea())
            .tint(.primary)
            .navigationTitle("Menu")
            .responsiveInlineNavigationTitle("Menu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .presentationBackground(menuPageBackground)
        .preferredColorScheme(.dark)
        .overlay {
            CoachMarkOverlay()
        }
        .onAppear {
            let t = Date()
            appearTime = t
            logger.info("nav.appear", "MenuSheetView appeared", metadata: [
                "queueCount": "\(queueCoordinator.episodes.count)"
            ])
            ResourceMonitor.shared.logSnapshot(reason: "nav.menuAppear")
        }
        .onDisappear {
            let durationMs = appearTime.map { Int(Date().timeIntervalSince($0) * 1000) }
            logger.info("nav.disappear", "MenuSheetView dismissed", metadata: [
                "visibleMs": durationMs.map(String.init) ?? "unknown"
            ])
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopReturnToPlayer)) { _ in
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopOpenSubscriptions)) { _ in
            // Settings → Manage podcasts: close the Menu (Settings is pushed
            // inside it) to reveal the Subscriptions page beneath.
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopOpenStats)) { _ in
            dismiss()
        }
    }

    private var menuPageBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var menuRowBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func openPlayer() {
        logger.info("navigation.menuMiniPlayerOpened", "Menu Mini Player opened the main Player")
        dismiss()
        if let returnToPlayerAction {
            returnToPlayerAction()
        } else {
            NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
        }
    }

    private func skipBack() {
        let interval = settingsViewModel.appSettings.skipBackSeconds
        logger.info("player.menuMiniSkipBack", "Menu Mini Player skipped backward", metadata: [
            "seconds": "\(Int(interval))"
        ])
        appState.seek(to: max(0, playbackClock.time - interval))
    }

    private func skipForward() {
        guard let episode = playbackCoordinator.currentEpisode else { return }
        let interval = settingsViewModel.appSettings.skipForwardSeconds
        logger.info("player.menuMiniSkipForward", "Menu Mini Player skipped forward", metadata: [
            "seconds": "\(Int(interval))"
        ])
        if let duration = episode.durationSeconds,
           playbackClock.time + interval >= duration {
            Task { await appState.playNextEpisode(excluding: [episode.id]) }
        } else {
            appState.skipForward(seconds: interval)
        }
    }

}

private struct MenuMiniPlayer: View {
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @EnvironmentObject private var playbackClock: PlaybackClock
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.adaptiveViewportWidth) private var viewportWidth

    let openPlayer: () -> Void
    let skipBack: () -> Void
    let togglePlayback: () -> Void
    let skipForward: () -> Void

    var body: some View {
        if let episode = playbackCoordinator.currentEpisode {
            let metrics = AdaptiveEditorialMetrics(containerWidth: viewportWidth)
            let subscription = subscriptionStore.subscription(id: episode.subscriptionID)
            let duration = max(0, episode.durationSeconds ?? 0)
            let progress = duration > 0 ? min(1, max(0, playbackClock.time / duration)) : 0

            VStack(alignment: .leading, spacing: metrics.scaled(14)) {
                HStack(spacing: metrics.scaled(14)) {
                    CachedArtworkImage(
                        url: episode.artworkURL ?? subscription?.artworkURL,
                        targetSize: CGSize(
                            width: metrics.menuPlayerArtworkSize,
                            height: metrics.menuPlayerArtworkSize
                        )
                    ) {
                        RoundedRectangle(cornerRadius: metrics.scaled(12))
                            .fill(Color.white.opacity(0.07))
                            .overlay {
                                Image(systemName: "waveform")
                                    .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
                                    .foregroundStyle(.purple)
                            }
                    }
                    .frame(width: metrics.menuPlayerArtworkSize, height: metrics.menuPlayerArtworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(12)))

                    VStack(alignment: .leading, spacing: metrics.scaled(4)) {
                        Text(episode.title)
                            .font(.system(size: metrics.detailPublisherFontSize, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subscription?.title ?? "Autohop")
                            .font(.system(size: metrics.detailDescriptionFontSize, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.52))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: metrics.scaled(7)) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Color.purple)
                                    .frame(width: geometry.size.width * progress)
                            }
                    }
                    .frame(height: metrics.scaled(5))

                    HStack {
                        Text(formatTime(playbackClock.time))
                        Spacer()
                        Text("−\(formatTime(max(0, duration - playbackClock.time)))")
                    }
                    .font(.system(size: metrics.detailDescriptionFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .monospacedDigit()
                }

                HStack(spacing: metrics.scaled(12)) {
                    transportButton(
                        label: "Skip back \(Int(settingsViewModel.appSettings.skipBackSeconds)) seconds",
                        highlighted: false,
                        action: skipBack
                    ) {
                        MenuSkipIntervalIcon(
                            direction: .backward,
                            seconds: settingsViewModel.appSettings.skipBackSeconds,
                            size: metrics.menuPlayerControlSize
                        )
                    }

                    transportButton(
                        label: playbackCoordinator.isPlaying ? "Pause" : "Play",
                        highlighted: true,
                        action: togglePlayback
                    ) {
                        Image(systemName: playbackCoordinator.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: metrics.scaled(23), weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: playbackCoordinator.isPlaying ? 0 : 1)
                            .frame(width: metrics.menuPlayerControlSize, height: metrics.menuPlayerControlSize)
                    }

                    transportButton(
                        label: "Skip forward \(Int(settingsViewModel.appSettings.skipForwardSeconds)) seconds",
                        highlighted: false,
                        action: skipForward
                    ) {
                        MenuSkipIntervalIcon(
                            direction: .forward,
                            seconds: settingsViewModel.appSettings.skipForwardSeconds,
                            size: metrics.menuPlayerControlSize
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(metrics.scaled(18))
            .frame(maxWidth: metrics.menuPlayerMaximumWidth)
            .modifier(MenuMiniPlayerSurface())
            .contentShape(RoundedRectangle(cornerRadius: 28))
            .onTapGesture(perform: openPlayer)
            .padding(.horizontal, metrics.horizontalGutter)
            .padding(.top, metrics.scaled(10))
            .padding(.bottom, metrics.scaled(34))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    private func transportButton<Label: View>(
        label: String,
        highlighted: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Label
    ) -> some View {
        Button(action: action) {
            if highlighted {
                content()
                    .modifier(MenuMiniPlayerPrimaryControlSurface())
            } else {
                content()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let safe = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let hours = safe / 3_600
        let minutes = (safe % 3_600) / 60
        let remainder = safe % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

private struct MenuSkipIntervalIcon: View {
    enum Direction { case backward, forward }

    let direction: Direction
    let seconds: TimeInterval
    let size: CGFloat

    var body: some View {
        let value = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        ZStack {
            Image(systemName: direction == .backward ? "gobackward" : "goforward")
                .font(.system(size: size * 0.62, weight: .regular))
            Text("\(value)")
                .font(.system(size: value >= 100 ? size * 0.18 : size * 0.23, weight: .medium, design: .rounded))
                .monospacedDigit()
                .offset(y: size * 0.045)
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
    }
}

private struct MenuMiniPlayerSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(.purple.opacity(0.12)), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.purple.opacity(0.22), lineWidth: 1) }
        }
    }
}

private struct MenuMiniPlayerPrimaryControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = Circle()
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(.purple), in: shape)
        } else {
            content
                .background(Color.purple, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.75) }
        }
    }
}
