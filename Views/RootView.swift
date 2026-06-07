import SwiftUI

enum AppRoute: Hashable {
    case podcasts
}

extension Notification.Name {
    static let autohopReturnToPlayer = Notification.Name("autohopReturnToPlayer")
}

struct ReturnToPlayerButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
        } label: {
            Image(systemName: "play.circle.fill")
        }
        .accessibilityLabel("Return to Player")
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
