import SwiftUI
import UIKit
import ImageIO
import AutohopCore

// AI CONTEXT — TV/Views/TVArtworkImage.swift
// Phase 2 (tvOS proposal §7): the TV target's artwork loader. Deliberately NOT
// a port of Views/CachedArtworkImage.swift — that file is iOS-app-target-only
// (TV compiles TV/ + the AutohopCore library product) — but since 2026-07-11
// it follows the same architecture: fetch → CGImageSource DOWNSAMPLE to the
// display size → NSCache. REWRITTEN 2026-07-11 (Kevin's round 6: "incredibly
// slow to navigate" + "white dots make images look snowy"), replacing the
// original thin AsyncImage wrapper. Two defects in that wrapper, one fix each:
// 1. SLOW: AsyncImage has no cache of its own beyond URLCache, and tvOS's
//    focus-engine navigation recreates card views constantly — every focus
//    move could refetch and re-decode full-size images. TVArtworkLoader now
//    memory-caches the FINAL decoded UIImage (NSCache, cost = bytes) with
//    in-flight task dedup, so a focus pass over already-seen shelves is pure
//    cache hits.
// 2. SNOWY: the round-6 targetPixels bump (600→1000/1600) handed the GPU
//    1000 px+ textures to scale into ~280 pt slots with no mipmap filtering —
//    the white-dot "snow" is classic downscale aliasing sparkle. Images are
//    now downsampled ONCE, off-main, via CGImageSourceCreateThumbnailAtIndex
//    (area-averaged, antialiased) to exactly targetPixels, so what the GPU
//    gets is already display-sized: crisp AND smooth. targetPixels therefore
//    returned to sane display-density values (default 600) — the crispness
//    problem was never fetch size, it was unfiltered scaling.
struct TVArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 12
    /// Decoded/display pixel size (and the minimum size requested from
    /// iTunes/mzstatic size-in-URL art — see AutohopCore.ArtworkURL). ~2×
    /// the point size of the slot is right for the 4K composite: rows/cards
    /// use the 600 default, the player hero passes more.
    var targetPixels: Int = 600

    @State private var image: UIImage?

    private var resolvedURL: URL? { ArtworkURL.upscaled(url, toMinimumPixels: targetPixels) }

    var body: some View {
        // CONTAINMENT FIX (2026-07-11, Kevin's round 9 screenshot: a video
        // episode's wide 16:9 frame in the Home hero's square 220 pt slot
        // OVERFLOWED the frame and painted over the metadata text next to
        // it). `scaledToFill` deliberately renders beyond the proposed size
        // on aspect mismatch, and the previous ZStack let that oversized
        // image dictate layout. `Color.clear` pins the view to exactly the
        // size the CALLER proposes; the image lives in an overlay (which
        // cannot affect layout) and the clip cuts the fill's overflow.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: resolvedURL) {
            guard let resolvedURL else {
                image = nil
                return
            }
            // Synchronous cache probe first so recycled LazyH/VStack cells
            // show instantly with no placeholder flash.
            if let cached = TVArtworkLoader.shared.cachedImage(url: resolvedURL, targetPixels: targetPixels) {
                image = cached
                return
            }
            image = await TVArtworkLoader.shared.image(url: resolvedURL, targetPixels: targetPixels)
        }
    }

    // Artwork-Placeholder token (DESIGN.md, ported 2026-07-11): purple-to-black
    // gradient + waveform, matching the iPhone's placeholder.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LinearGradient(
                colors: [TVTheme.brandPurple.opacity(0.55), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
    }
}

/// Memory-cached, downsampling artwork fetcher for the TV target — see the
/// file header for why this exists. Main-actor confined (cache + in-flight
/// bookkeeping); the network fetch and CGImageSource decode run off-main in a
/// detached task.
@MainActor
final class TVArtworkLoader {
    static let shared = TVArtworkLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]

    private init() {
        // ~150 MB of decoded artwork (cost = bytes). Generous for a shelf UI;
        // NSCache still evicts under system memory pressure regardless.
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    private static func key(_ url: URL, _ targetPixels: Int) -> NSString {
        "\(url.absoluteString)#\(targetPixels)" as NSString
    }

    /// Non-suspending cache probe, for zero-flash rendering of recycled cells.
    func cachedImage(url: URL, targetPixels: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, targetPixels))
    }

    func image(url: URL, targetPixels: Int) async -> UIImage? {
        let key = Self.key(url, targetPixels)
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // tv.perf probe (2026-07-11 diagnostics): fetch+decode run OFF-main,
            // so they can't hang the focus engine directly — but a flood of
            // these lines during navigation means cache misses are churning
            // (view identity or key problem), which is its own smoking gun.
            let startedAt = CFAbsoluteTimeGetCurrent()
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            let image = Self.downsampledImage(data: data, maxPixels: targetPixels)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            if elapsedMs >= 400 {
                AppLogger.shared.info("tv.perf", "Artwork fetch+decode was slow (off-main)", metadata: [
                    "stage": "artworkLoad",
                    "ms": String(format: "%.0f", elapsedMs),
                    "px": "\(targetPixels)"
                ], alwaysPersist: true)
            }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// Area-averaged downsample via ImageIO — decodes directly to the target
    /// size without ever materializing the full-resolution bitmap (the
    /// standard CGImageSourceCreateThumbnailAtIndex technique, same as the
    /// iOS CachedArtworkImage pipeline).
    private nonisolated static func downsampledImage(data: Data, maxPixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
