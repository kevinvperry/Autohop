import SwiftUI
import UIKit

struct CachedArtworkImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ArtworkImageCache.shared.image(for: url)
        }
    }
}

// MARK: - Expanded artwork sheet

struct ExpandedArtworkSheet: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedArtworkImage(url: url) {
                ZStack {
                    LinearGradient(
                        colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
    }
}

// MARK: - Artwork image cache

actor ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL?
    private let session: URLSession

    // Deduplicates concurrent requests for the same URL — all waiters share
    // one Task and receive the same result when it completes.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cacheDirectory = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Autohop/Artwork", isDirectory: true)

        if let cacheDirectory {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    func image(for url: URL) async -> UIImage? {
        // 1. Memory cache — synchronous, no actor suspension needed.
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }

        // 2. Deduplicate: if a load is already in progress for this URL,
        //    await its result instead of starting a second one.
        if let existing = inFlight[url] {
            return await existing.value
        }

        // 3. Start a new load task and register it so late arrivals can join.
        let task = Task<UIImage?, Never> {
            await load(url: url)
        }
        inFlight[url] = task
        let result = await task.value
        inFlight.removeValue(forKey: url)
        return result
    }

    // Runs disk I/O and network fetch on background threads so the actor
    // is never blocked by slow storage or network operations.
    private func load(url: URL) async -> UIImage? {
        let cacheKey = url as NSURL
        let fileURL = self.fileURL(for: url)

        // Disk read on a background thread — returns nil quickly if not cached.
        if let fileURL {
            let diskImage = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return UIImage(data: data)
            }.value

            if let diskImage {
                memoryCache.setObject(diskImage, forKey: cacheKey)
                return diskImage
            }
        }

        // Network fetch.
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }

            // Decode image on a background thread — JPEG/PNG decompression
            // can be expensive and should not run on the actor's executor.
            let image = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value

            guard let image else { return nil }

            memoryCache.setObject(image, forKey: cacheKey)

            if let fileURL {
                await Task.detached(priority: .background) {
                    try? data.write(to: fileURL, options: [.atomic])
                }.value
            }

            return image
        } catch {
            return nil
        }
    }

    private func fileURL(for url: URL) -> URL? {
        cacheDirectory?.appendingPathComponent(cacheKey(for: url), isDirectory: false)
    }

    private func cacheKey(for url: URL) -> String {
        var hash: UInt64 = 5381
        for byte in url.absoluteString.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return "\(String(hash, radix: 16)).\(ext)"
    }
}
