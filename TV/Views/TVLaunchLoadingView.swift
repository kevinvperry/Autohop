import SwiftUI

// AI CONTEXT — TV/Views/TVLaunchLoadingView.swift (added 2026-07-11)
// Animated Autohop splash for the TV app's `.loading` root state — a direct
// port of the iPhone's LaunchLoadingView (Views/RootView.swift: same brand
// purple background, two waveform groups either side of a chevron, pulsing
// bar-scale animation), sized up ~2.2× for the 10-foot UI. One deliberate
// difference: the iPhone splash is a fixed ~1.2 s overlay, but the TV's
// loading state can legitimately last MINUTES on a first-ever CloudKit sync
// (see AutohopTVApp's FIRST-SYNC WAIT note), so this view also renders the
// TVAppModel's rotating `statusText` beneath the wordmark — replacing the old
// bare ProgressView + text, not adding a second status surface. Keep the bar
// heights/colors in step with the iPhone original if that ever changes.
struct TVLaunchLoadingView: View {
    let statusText: String
    @State private var isAnimating = false

    private let purpleBars: [(height: CGFloat, color: Color)] = [
        (114, Color(red: 0.66, green: 0.62, blue: 0.91)),
        (255, Color(red: 0.77, green: 0.74, blue: 0.94)),
        (176, Color(red: 0.69, green: 0.66, blue: 0.93)),
        (79, Color(red: 0.60, green: 0.56, blue: 0.89))
    ]

    private let greenBars: [(height: CGFloat, color: Color)] = [
        (97, Color(red: 0.11, green: 0.73, blue: 0.33)),
        (255, Color(red: 0.15, green: 0.82, blue: 0.38)),
        (158, Color(red: 0.11, green: 0.73, blue: 0.33)),
        (66, Color(red: 0.09, green: 0.66, blue: 0.29).opacity(0.75))
    ]

    var body: some View {
        ZStack {
            Color(red: 0.176, green: 0.149, blue: 0.502)
                .ignoresSafeArea()

            VStack(spacing: 44) {
                HStack(spacing: 30) {
                    waveformGroup(purpleBars, phaseOffset: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 74, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.24))
                        .scaleEffect(isAnimating ? 1.06 : 0.96)

                    waveformGroup(greenBars, phaseOffset: 0.18)
                }
                .frame(height: 290)

                Text("Autohop")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(statusText)
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                    // Status lines rotate every 7 s during a long first sync —
                    // crossfade them instead of hard-swapping.
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: statusText)
            }
            .padding(.horizontal, 64)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private func waveformGroup(_ bars: [(height: CGFloat, color: Color)], phaseOffset: Double) -> some View {
        HStack(spacing: 22) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(bar.color)
                    .frame(width: 53, height: bar.height)
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
