import SwiftUI

// AI CONTEXT — TV/Views/TVTheme.swift (added 2026-07-11, Kevin's round 7:
// "introduce more styling and colour scheme/design elements from the phone
// app"). The TV ports of the iPhone design tokens (DESIGN.md):
//   • Accent-Purple  → `.tint(.purple)` applied at the TVMainTabView root.
//   • brand purple   → the launch-splash background colour (RootView.swift's
//     LaunchLoadingView / TVLaunchLoadingView), used here as a subtle ambient
//     gradient behind every tab so the app reads as Autohop rather than a
//     stock black tvOS shell.
//   • Artwork-Placeholder → purple-to-black gradient + waveform (TVArtworkImage).
//   • Artwork-Player → purple radial glow behind the player's audio artwork
//     (TVPlayerView).
// Keep these values in step with the iPhone originals if they ever change.
enum TVTheme {
    /// The brand purple — identical to the launch splash background on both
    /// platforms (Color(red: 0.176, green: 0.149, blue: 0.502)).
    static let brandPurple = Color(red: 0.176, green: 0.149, blue: 0.502)
    /// High-contrast focus tint. The focused card uses a bright magenta edge
    /// plus a restrained purple fill so selection remains obvious across
    /// televisions with very different brightness and HDR settings.
    static let focusAccent = Color(red: 0.91, green: 0.20, blue: 0.98)
}

/// Ambient brand background for the tab shell: brand purple washing down into
/// black. Deliberately restrained (10-foot UI, dark room) — enough to carry
/// the identity without fighting artwork.
struct TVBrandBackground: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: TVTheme.brandPurple.opacity(0.42), location: 0),
                .init(color: TVTheme.brandPurple.opacity(0.16), location: 0.35),
                .init(color: .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// AI CONTEXT — FOCUS CONTRACT
// Standard tvOS `.buttonStyle(.card)` still owns directional focus, press
// behaviour and accessibility. This modifier adds only a cheap, deterministic
// visual state: no blur, geometry reader or continuously animated effect.
// Keeping selection feedback separate from navigation prevents artwork and
// material rendering from delaying Siri Remote focus updates.
private struct TVFocusHighlight: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isFocused ? TVTheme.brandPurple.opacity(0.48) : .clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isFocused ? TVTheme.focusAccent : Color.white.opacity(0.10),
                        lineWidth: isFocused ? 5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: isFocused ? TVTheme.focusAccent.opacity(0.42) : .clear,
                radius: isFocused ? 16 : 0
            )
            .animation(.easeOut(duration: 0.10), value: isFocused)
    }
}

extension View {
    /// Adds Autohop's unmistakable selected-tile treatment without replacing
    /// the native tvOS focus engine or its accessibility behaviour.
    func tvFocusHighlight(cornerRadius: CGFloat = 18) -> some View {
        modifier(TVFocusHighlight(cornerRadius: cornerRadius))
    }
}

// AI CONTEXT — TV OVERFLOWING HEADING CONTRACT
// A ten-foot interface cannot rely on truncation for the currently playing
// episode title. This view measures the rendered single-line title and moves it
// only when it genuinely exceeds the available width. The motion pauses at
// both readable endpoints, travels at a constant points-per-second rate, and
// reverses instead of snapping. Reduce Motion falls back to a wrapped title.
struct TVMarqueeText: View {
    let text: String
    var font: Font = .title2.bold()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    var body: some View {
        Group {
            if reduceMotion {
                Text(text)
                    .font(font)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                GeometryReader { geometry in
                    Text(text)
                        .font(font)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                        .background {
                            GeometryReader { textGeometry in
                                Color.clear
                                    .onAppear { textWidth = textGeometry.size.width }
                                    .onChange(of: textGeometry.size.width) { _, value in
                                        textWidth = value
                                    }
                            }
                        }
                        .onAppear { containerWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, value in
                            containerWidth = value
                        }
                }
                .clipped()
            }
        }
        .frame(height: reduceMotion ? 92 : 58)
        .accessibilityLabel(text)
        .task(id: MarqueeRunID(text: text, overflow: overflow, reduceMotion: reduceMotion)) {
            offset = 0
            guard !reduceMotion, overflow > 1 else { return }

            // The title remains still before its first movement, then pauses
            // again with the final words fully visible. Returning at the same
            // speed avoids the distracting jump produced by a looping ticker.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                let travelDuration = min(14.0, max(3.0, Double(overflow / 46)))
                withAnimation(.linear(duration: travelDuration)) {
                    offset = -overflow
                }
                try? await Task.sleep(for: .seconds(travelDuration + 1.8))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: travelDuration)) {
                    offset = 0
                }
                try? await Task.sleep(for: .seconds(travelDuration))
            }
        }
    }

    private struct MarqueeRunID: Hashable {
        let text: String
        let overflow: CGFloat
        let reduceMotion: Bool
    }
}
