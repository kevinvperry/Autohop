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
// Also shows the launch splash overlay briefly on cold start.
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
                    CachedArtworkImage(url: subscription?.artworkURL) {
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

struct RootView: View {
    @State private var showLaunchView = true
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

            if showLaunchView {
                LaunchLoadingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
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
