import SwiftUI

// AI CONTEXT — Views/EpisodeBadges.swift. Small reusable badge components for
// episode rows/detail (VIDEO pill, explicit marker, etc.), with iOS 26 glass
// effect variants. Pure presentation; shared across episode lists, preview,
// queue, and detail pages.

// MARK: - Video Badge (small)
//
// TV-icon pill shown centred below episode artwork for video episodes.

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

// MARK: - Video Badge Large
//
// "Video" text pill — large counterpart to VideoBadge.

struct VideoBadgeLarge: View {
    var body: some View {
        let label = Text("Video")
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

// MARK: - Explicit Pill (large)
//
// "Explicit" text pill shown centred below episode artwork for explicit episodes.

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

// MARK: - Explicit Pill Small
//
// "E in a square" icon pill — small counterpart to ExplicitPill, styled like the iTunes explicit badge.

struct ExplicitPillSmall: View {
    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 11, height: 11)
            Text("E")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    var body: some View {
        if #available(iOS 26, *) {
            badge.glassEffect(in: Capsule())
        } else {
            badge.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
