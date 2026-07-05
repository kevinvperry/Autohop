import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVArtworkImage.swift
// Phase 2 (tvOS proposal §7): a minimal artwork loader for the TV target.
// Deliberately NOT a port of Views/CachedArtworkImage.swift — that file lives
// in the iOS app target's Views/ directory, which AutohopTV does not compile
// (TV sources are TV/ + the AutohopCore library product only), and its
// UIImage/CGImage downsampling pipeline is iOS-cache-specific. This is a thin
// AsyncImage wrapper with a placeholder; it has NO memory/disk cache of its
// own. PERF FOLLOW-UP (tracked, not urgent for Phase 2's read-only lists):
// if TV scrolling shows artwork jank at scale, give this an NSCache keyed by
// URL, mirroring the iPhone ArtworkImageCache pattern — TV/ is free to add
// that without touching iOS code.
struct TVArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 12
    /// Minimum pixel size requested for iTunes/mzstatic-hosted art (they encode
    /// the size in the URL — a 300×300 feed variant looks soft blown up on a 4K
    /// panel). Rows pass the default; the large hero/player artwork passes more.
    /// Non-resizable URLs are unaffected. See AutohopCore.ArtworkURL.
    var targetPixels: Int = 600

    private var resolvedURL: URL? { ArtworkURL.upscaled(url, toMinimumPixels: targetPixels) }

    var body: some View {
        AsyncImage(url: resolvedURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.08))
            .overlay(
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
    }
}
