import SwiftUI
import UIKit
import ImageIO

// AI CONTEXT — Views/CachedArtworkImage.swift. App-wide podcast/episode artwork
// pipeline: CachedArtworkImage is the SwiftUI wrapper; ArtworkImageCache is the
// shared actor behind UI thumbnails, episode share cards, notification artwork,
// and Now Playing artwork. Prefer this over AsyncImage for podcast/episode art.
// The cache stores original source bytes once on disk, keeps downsampled display
// variants in a 32 MB NSCache, validates remote responses (2xx image/*, <=5 MB),
// negative-caches failures for 5 minutes, and prunes disk metadata/files at
// 250 MB or 90 days LRU. Disk cache files are marked available-after-first-unlock
// so CarPlay can render cached artwork while locked; CarPlay callers still use a
// placeholder if disk/network/decode work is unavailable. Callers should pass
// targetSize for fixed artwork so ImageIO can decode near display size instead of
// holding full podcast covers in memory. Priority levels are visible/prefetch/
// background: visible requests can cancel lower-priority prefetch work;
// PodcastDetailView prefetches the next few episode row thumbnails and cancels
// stale off-screen prefetches.
struct CachedArtworkImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var targetSize: CGSize?
    var loadPriority: ArtworkLoadPriority = .visible
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
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
            let loadedImage = await ArtworkImageCache.shared.image(
                for: url,
                targetSize: targetSize,
                scale: displayScale,
                priority: loadPriority
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
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

enum ArtworkLoadPriority: Int, Sendable {
    case background = 0
    case prefetch = 1
    case visible = 2

    var taskPriority: TaskPriority {
        switch self {
        case .visible: return .userInitiated
        case .prefetch: return .utility
        case .background: return .background
        }
    }
}

actor ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL?
    private let session: URLSession
    private let maxImageResponseBytes = 5 * 1024 * 1024
    private let failureRetryDelay: TimeInterval = 5 * 60
    private let maxDiskCacheBytes = 250 * 1024 * 1024
    private let maxDiskCacheAge: TimeInterval = 90 * 24 * 60 * 60
    private let metadataFileName = "_metadata.json"

    // Deduplicates concurrent requests for the same URL/variant — all waiters
    // share one Task unless a visible request upgrades lower-priority prefetch.
    private struct InFlightRequest {
        let id: UUID
        let priority: ArtworkLoadPriority
        let task: Task<UIImage?, Never>
    }

    private struct InFlightDataRequest {
        let id: UUID
        let priority: ArtworkLoadPriority
        let task: Task<Data?, Never>
    }

    private var inFlight: [String: InFlightRequest] = [:]
    private var sourceDataInFlight: [String: InFlightDataRequest] = [:]
    private var prefetchKeys: Set<String> = []
    private var failedUntil: [URL: Date] = [:]
    private var diskMetadata: [String: DiskCacheEntry] = [:]
    private var isPruningDiskCache = false

    private struct DiskCacheEntry: Codable {
        var key: String
        var originalURL: String
        var byteSize: Int
        var createdAt: Date
        var lastAccessedAt: Date
    }

    private init() {
        cacheDirectory = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Autohop/Artwork", isDirectory: true)

        if let cacheDirectory {
            try? LockedDeviceFileAccess.createDirectory(cacheDirectory, fileManager: fileManager)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
        memoryCache.totalCostLimit = 32 * 1024 * 1024
        diskMetadata = Self.loadDiskMetadata(in: cacheDirectory, fileName: metadataFileName)
    }

    /// AI CONTEXT — emergency/scene-background memory release. Disk originals stay
    /// intact, so visible images can be cheaply reconstructed; only decoded bitmaps
    /// and speculative prefetch work are discarded. Visible loads are not cancelled.
    func trimMemory(reason: String) {
        let speculative = inFlight.filter { $0.value.priority != .visible }
        for (key, request) in speculative {
            request.task.cancel()
            inFlight.removeValue(forKey: key)
            prefetchKeys.remove(key)
        }
        memoryCache.removeAllObjects()
        failedUntil = failedUntil.filter { $0.value > Date() }
        AppLogger.shared.info("artwork.memoryTrim", "Released decoded artwork cache and speculative loads", metadata: [
            "reason": reason,
            "cancelledLoads": "\(speculative.count)",
            "visibleLoadsRemaining": "\(inFlight.count)",
            "sourceLoadsRemaining": "\(sourceDataInFlight.count)"
        ])
    }

    func image(
        for url: URL,
        targetSize: CGSize? = nil,
        scale: CGFloat = 1,
        priority: ArtworkLoadPriority = .visible
    ) async -> UIImage? {
        let variant = ArtworkImageVariant(targetSize: targetSize, scale: scale)
        let requestKey = cacheKey(for: url, variant: variant)
        let memoryKey = requestKey as NSString

        // 1. Memory cache — synchronous, no actor suspension needed.
        if let cached = memoryCache.object(forKey: memoryKey) {
            return cached
        }

        // 2. Deduplicate: if a load is already in progress for this URL,
        //    await its result instead of starting a second one.
        if let existing = inFlight[requestKey] {
            if priority.rawValue > existing.priority.rawValue {
                existing.task.cancel()
                inFlight.removeValue(forKey: requestKey)
                prefetchKeys.remove(requestKey)
            } else {
                return await existing.task.value
            }
        }

        let request = startLoad(url: url, variant: variant, requestKey: requestKey, priority: priority)
        let result = await request.task.value
        clearInFlight(requestKey: requestKey, id: request.id)
        return result
    }

    func sourceData(for url: URL, priority: ArtworkLoadPriority = .background) async -> Data? {
        let sourceKey = sourceCacheKey(for: url)

        if let fileURL = fileURL(for: url) {
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: fileURL)
            }.value

            guard !Task.isCancelled else { return nil }
            if let data {
                LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: fileURL)
                recordDiskAccess(url: url)
                failedUntil.removeValue(forKey: url)
                return data
            }
        }

        if let existing = sourceDataInFlight[sourceKey] {
            if priority.rawValue > existing.priority.rawValue {
                existing.task.cancel()
                sourceDataInFlight.removeValue(forKey: sourceKey)
            } else {
                return await existing.task.value
            }
        }

        let request = startSourceDataLoad(url: url, sourceKey: sourceKey, priority: priority)
        let data = await request.task.value
        clearSourceDataInFlight(sourceKey: sourceKey, id: request.id)
        return data
    }

    func prefetch(urls: [URL], targetSize: CGSize, scale: CGFloat = 1) {
        for url in urls {
            let variant = ArtworkImageVariant(targetSize: targetSize, scale: scale)
            let requestKey = cacheKey(for: url, variant: variant)
            let memoryKey = requestKey as NSString

            guard memoryCache.object(forKey: memoryKey) == nil,
                  inFlight[requestKey] == nil,
                  shouldAttemptNetworkLoad(for: url) else { continue }

            let request = startLoad(url: url, variant: variant, requestKey: requestKey, priority: .prefetch)
            prefetchKeys.insert(requestKey)
            Task {
                _ = await request.task.value
                self.clearInFlight(requestKey: requestKey, id: request.id)
            }
        }
    }

    func cancelPrefetch(urls: [URL], targetSize: CGSize, scale: CGFloat = 1) {
        for url in urls {
            let variant = ArtworkImageVariant(targetSize: targetSize, scale: scale)
            let requestKey = cacheKey(for: url, variant: variant)
            guard prefetchKeys.contains(requestKey),
                  let request = inFlight[requestKey],
                  request.priority == .prefetch else { continue }

            request.task.cancel()
            inFlight.removeValue(forKey: requestKey)
            prefetchKeys.remove(requestKey)
        }
    }

    private func startLoad(
        url: URL,
        variant: ArtworkImageVariant,
        requestKey: String,
        priority: ArtworkLoadPriority
    ) -> InFlightRequest {
        let id = UUID()
        let task = Task<UIImage?, Never>(priority: priority.taskPriority) {
            await load(url: url, variant: variant, requestKey: requestKey, priority: priority)
        }
        let request = InFlightRequest(id: id, priority: priority, task: task)
        inFlight[requestKey] = request
        return request
    }

    private func clearInFlight(requestKey: String, id: UUID) {
        guard inFlight[requestKey]?.id == id else { return }
        inFlight.removeValue(forKey: requestKey)
        prefetchKeys.remove(requestKey)
    }

    private func startSourceDataLoad(
        url: URL,
        sourceKey: String,
        priority: ArtworkLoadPriority
    ) -> InFlightDataRequest {
        let id = UUID()
        let task = Task<Data?, Never>(priority: priority.taskPriority) {
            await loadSourceData(url: url)
        }
        let request = InFlightDataRequest(id: id, priority: priority, task: task)
        sourceDataInFlight[sourceKey] = request
        return request
    }

    private func clearSourceDataInFlight(sourceKey: String, id: UUID) {
        guard sourceDataInFlight[sourceKey]?.id == id else { return }
        sourceDataInFlight.removeValue(forKey: sourceKey)
    }

    // Runs disk I/O and network fetch on background threads so the actor
    // is never blocked by slow storage or network operations.
    private func load(
        url: URL,
        variant: ArtworkImageVariant,
        requestKey: String,
        priority: ArtworkLoadPriority
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let memoryKey = requestKey as NSString

        guard let data = await sourceData(for: url, priority: priority) else { return nil }
        guard !Task.isCancelled else { return nil }

        // Decode image on a background thread — JPEG/PNG decompression
        // can be expensive and should not run on the actor's executor.
        let image = await Task.detached(priority: .utility) {
            Self.image(from: data, variant: variant)
        }.value

        guard !Task.isCancelled else { return nil }
        guard let image else {
            rememberFailure(for: url)
            return nil
        }

        memoryCache.setObject(image, forKey: memoryKey, cost: Self.memoryCost(for: image))
        failedUntil.removeValue(forKey: url)
        return image
    }

    private func loadSourceData(url: URL) async -> Data? {
        guard shouldAttemptNetworkLoad(for: url) else { return nil }
        guard !Task.isCancelled else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard !Task.isCancelled else { return nil }
            guard isAcceptableImageResponse(response, data: data) else {
                rememberFailure(for: url)
                return nil
            }

            failedUntil.removeValue(forKey: url)

            if let fileURL = fileURL(for: url) {
                let didWrite = await Task.detached(priority: .background) {
                    (try? LockedDeviceFileAccess.writeDataAtomically(data, to: fileURL)) != nil
                }.value
                if didWrite {
                    recordDiskWrite(url: url, byteSize: data.count)
                    pruneDiskCacheIfNeeded()
                }
            }

            return data
        } catch {
            rememberFailure(for: url)
            return nil
        }
    }

    private func shouldAttemptNetworkLoad(for url: URL) -> Bool {
        guard let retryAfter = failedUntil[url] else { return true }
        if retryAfter > Date() {
            return false
        }
        failedUntil.removeValue(forKey: url)
        return true
    }

    private func isAcceptableImageResponse(_ response: URLResponse, data: Data) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }

        if data.count > maxImageResponseBytes {
            return false
        }

        if response.expectedContentLength > Int64(maxImageResponseBytes) {
            return false
        }

        if let mime = response.mimeType?.lowercased(),
           !mime.hasPrefix("image/") {
            return false
        }

        return true
    }

    private func rememberFailure(for url: URL) {
        failedUntil[url] = Date().addingTimeInterval(failureRetryDelay)
    }

    private func fileURL(for url: URL) -> URL? {
        cacheDirectory?.appendingPathComponent(sourceCacheKey(for: url), isDirectory: false)
    }

    private func metadataURL() -> URL? {
        cacheDirectory?.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    private func cacheKey(for url: URL, variant: ArtworkImageVariant) -> String {
        "\(sourceCacheKey(for: url))-\(variant.cacheSuffix)"
    }

    private func sourceCacheKey(for url: URL) -> String {
        var hash: UInt64 = 5381
        for byte in url.absoluteString.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return "\(String(hash, radix: 16)).\(ext)"
    }

    private func recordDiskAccess(url: URL) {
        let key = sourceCacheKey(for: url)
        let now = Date()

        if diskMetadata[key] != nil {
            diskMetadata[key]?.lastAccessedAt = now
        } else if let fileURL = fileURL(for: url),
                  let byteSize = Self.fileByteSize(at: fileURL) {
            diskMetadata[key] = DiskCacheEntry(
                key: key,
                originalURL: url.absoluteString,
                byteSize: byteSize,
                createdAt: now,
                lastAccessedAt: now
            )
        }
        saveDiskMetadata()
    }

    private func recordDiskWrite(url: URL, byteSize: Int) {
        let key = sourceCacheKey(for: url)
        let now = Date()
        diskMetadata[key] = DiskCacheEntry(
            key: key,
            originalURL: url.absoluteString,
            byteSize: byteSize,
            createdAt: diskMetadata[key]?.createdAt ?? now,
            lastAccessedAt: now
        )
        saveDiskMetadata()
    }

    private func pruneDiskCacheIfNeeded() {
        guard !isPruningDiskCache, let cacheDirectory else { return }
        isPruningDiskCache = true
        defer { isPruningDiskCache = false }

        let now = Date()
        var changed = false

        for (key, entry) in diskMetadata {
            let fileURL = cacheDirectory.appendingPathComponent(key, isDirectory: false)
            let isExpired = now.timeIntervalSince(entry.lastAccessedAt) > maxDiskCacheAge
            if isExpired || !fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
                diskMetadata.removeValue(forKey: key)
                changed = true
            } else if let byteSize = Self.fileByteSize(at: fileURL),
                      byteSize != entry.byteSize {
                var updatedEntry = entry
                updatedEntry.byteSize = byteSize
                diskMetadata[key] = updatedEntry
                changed = true
            }
        }

        var totalBytes = diskMetadata.values.reduce(0) { $0 + $1.byteSize }
        if totalBytes > maxDiskCacheBytes {
            let removableEntries = diskMetadata.values
                .sorted { $0.lastAccessedAt < $1.lastAccessedAt }

            for entry in removableEntries where totalBytes > maxDiskCacheBytes {
                let fileURL = cacheDirectory.appendingPathComponent(entry.key, isDirectory: false)
                try? fileManager.removeItem(at: fileURL)
                diskMetadata.removeValue(forKey: entry.key)
                totalBytes -= entry.byteSize
                changed = true
            }
        }

        if changed {
            saveDiskMetadata()
        }
    }

    private func saveDiskMetadata() {
        guard let metadataURL = metadataURL() else { return }
        do {
            let data = try JSONEncoder().encode(diskMetadata)
            try LockedDeviceFileAccess.writeDataAtomically(data, to: metadataURL)
        } catch {
            // Cache metadata is best-effort; stale entries self-heal on later access/prune.
        }
    }

    private static func loadDiskMetadata(in cacheDirectory: URL?, fileName: String) -> [String: DiskCacheEntry] {
        guard let cacheDirectory else { return [:] }
        let metadataURL = cacheDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: DiskCacheEntry].self, from: data)
        else { return [:] }
        return metadata
    }

    private static func fileByteSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else { return nil }
        return fileSize
    }

    private static func image(from data: Data, variant: ArtworkImageVariant) -> UIImage? {
        guard let maxPixelSize = variant.maxPixelSize else {
            return UIImage(data: data)
        }

        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage, scale: variant.scale, orientation: .up)
    }

    private static func memoryCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

private struct ArtworkImageVariant: Sendable {
    let maxPixelSize: Int?
    let scale: CGFloat

    init(targetSize: CGSize?, scale: CGFloat) {
        self.scale = scale
        guard let targetSize else {
            self.maxPixelSize = nil
            return
        }
        let maxPointSize = max(targetSize.width, targetSize.height)
        guard maxPointSize > 0, scale > 0 else {
            self.maxPixelSize = nil
            return
        }
        self.maxPixelSize = max(1, Int(ceil(maxPointSize * scale)))
    }

    var cacheSuffix: String {
        guard let maxPixelSize else { return "source" }
        return "\(maxPixelSize)p"
    }
}
