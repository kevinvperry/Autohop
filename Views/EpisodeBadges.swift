import SwiftUI

// MARK: - Video Badge
//
// TV-icon pill shown centred below episode artwork for video episodes.
// Styled identically to Badge-RankPill: glassEffect on iOS 26+,
// ultraThinMaterial on older iOS, caption.bold white, h:8 v:5 padding.

struct VideoBadge: View {
    var body: some View {
        let icon = Image(systemName: "tv.fill")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            icon.glassEffect(in: Capsule())
        } else {
            icon.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Explicit Pill
//
// "Explicit" text pill shown centred below episode artwork for explicit episodes.
// Styled identically to Badge-RankPill: glassEffect on iOS 26+,
// ultraThinMaterial on older iOS, caption.bold white, h:8 v:5 padding.

struct ExplicitPill: View {
    var body: some View {
        let label = Text("Explicit")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label.glassEffect(in: Capsule())
        } else {
            label.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
