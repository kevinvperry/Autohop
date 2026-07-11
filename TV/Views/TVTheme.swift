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
