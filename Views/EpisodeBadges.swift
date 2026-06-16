import SwiftUI

// AI CONTEXT — Views/EpisodeBadges.swift. Small reusable badge components for
// episode rows/detail (VIDEO pill, explicit marker, etc.), with iOS 26 glass
// effect variants. Pure presentation; shared across episode lists, preview,
// queue, and detail pages.

// MARK: - Video Pill (small)
//
// TV-icon pill shown in the top-trailing overlay of episode rows for video episodes.

struct VideoPillSmall: View {
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

// MARK: - Video Pill (large)
//
// "Video" text pill — large counterpart to VideoPillSmall, used in detail headers.

struct VideoPillLarge: View {
    var body: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "tv.fill")
            Text("Video")
        }
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
// "Explicit" text pill used in detail headers for explicit shows/episodes.

struct ExplicitPillLarge: View {
    var body: some View {
        let label = HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 11, height: 11)
                Text("E")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black)
            }
            Text("Explicit")
        }
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
// "E in a square" icon pill — small counterpart to ExplicitPillLarge, styled like the iTunes explicit badge.

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
