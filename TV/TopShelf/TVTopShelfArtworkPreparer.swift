import Foundation
import ImageIO
import UIKit
import AutohopCore

// AI CONTEXT — Main-tvOS-app-only Top Shelf artwork renderer. Network and
// ImageIO work happen outside the extension. Output uses Apple's narrower
// poster geometry so four cards fit the 1920-wide Top Shelf. Every card owns a
// purple Autohop backdrop because dynamic TVServices content replaces (rather
// than layers over) the app's static Top Shelf fallback image. Publisher art
// can have hostile aspect ratios, so source thumbnails are capped at 4096 px.

struct TVTopShelfPreparedArtwork: Sendable {
    enum Source: String, Sendable { case tvDiskCache, network, placeholder }
    let filename1x: String
    let filename2x: String
    let data1x: Data
    let data2x: Data
    let source: Source
}

enum TVTopShelfArtworkPreparer {
    static func prepare(sourceURL: URL?, stableID: String) async -> TVTopShelfPreparedArtwork {
        let sourceData: Data?
        let source: TVTopShelfPreparedArtwork.Source
        if let sourceURL {
            if let cached = cachedTVArtwork(sourceURL) {
                sourceData = cached
                source = .tvDiskCache
            } else if let fetched = await fetch(sourceURL) {
                sourceData = fetched
                source = .network
            } else {
                sourceData = nil
                source = .placeholder
            }
        } else {
            sourceData = nil
            source = .placeholder
        }
        async let oneX = render(sourceData: sourceData, width: 404, height: 608)
        async let twoX = render(sourceData: sourceData, width: 808, height: 1_216)
        return await .init(
            filename1x: stableID + "@1x.jpg",
            filename2x: stableID + "@2x.jpg",
            data1x: oneX,
            data2x: twoX,
            source: source
        )
    }

    private static func cachedTVArtwork(_ url: URL) -> Data? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("Autohop/TVArtwork", isDirectory: true)
        let candidates = [url, ArtworkURL.upscaled(url, toMinimumPixels: 600), ArtworkURL.upscaled(url, toMinimumPixels: 1_216)]
            .compactMap { $0 }
        for candidate in candidates {
            let hash = candidate.absoluteString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            let file = directory.appendingPathComponent(String(hash, radix: 16) + ".img")
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe) { return data }
        }
        return nil
    }

    private static func fetch(_ url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: ArtworkURL.upscaled(url, toMinimumPixels: 1_216) ?? url)
        request.timeoutInterval = 15
        request.setValue(PodcastUserAgent.value, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= 12 * 1_024 * 1_024,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }

    private static func render(sourceData: Data?, width: Int, height: Int) async -> Data {
        await Task.detached(priority: .utility) {
            if let sourceData,
               let image = brandedPoster(data: sourceData, width: width, height: height),
               let jpeg = image.jpegData(compressionQuality: 0.86),
               jpeg.count <= 2 * 1_024 * 1_024 {
                return jpeg
            }
            return placeholder(width: width, height: height).jpegData(compressionQuality: 0.9) ?? Data()
        }.value
    }

    private static func brandedPoster(data: Data, width: Int, height: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let maxDimension = max(sourceWidth, sourceHeight)
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(
                4_096,
                Int(CGFloat(max(width, height)) * maxDimension / min(sourceWidth, sourceHeight))
            )
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        let image = UIImage(cgImage: cgImage)
        return brandedCanvas(width: width, height: height) { canvas in
            let inset = CGFloat(width) * 0.055
            let side = CGFloat(width) - inset * 2
            let destination = CGRect(x: inset, y: (CGFloat(height) - side) / 2, width: side, height: side)
            let scale = max(side / image.size.width, side / image.size.height)
            let rendered = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            canvas.cgContext.saveGState()
            UIBezierPath(roundedRect: destination, cornerRadius: CGFloat(width) * 0.055).addClip()
            image.draw(in: CGRect(x: destination.midX - rendered.width / 2, y: destination.midY - rendered.height / 2, width: rendered.width, height: rendered.height))
            canvas.cgContext.restoreGState()
        }
    }

    private static func placeholder(width: Int, height: Int) -> UIImage {
        brandedCanvas(width: width, height: height) { context in
            let symbol = UIImage(systemName: "waveform")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            let side = CGFloat(width) * 0.42
            symbol?.draw(in: CGRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))
        }
    }

    private static func brandedCanvas(width: Int, height: Int, drawing: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        // AI CONTEXT — These arguments are required output PIXELS, not UIKit
        // points. The default tvOS renderer inherits a 2x display scale, which
        // silently doubled 404×608 into 808×1216 and made Top Shelf cards too
        // wide. A scale of 1 produces the exact TVServices poster contracts;
        // the caller explicitly requests the separate 2x variant.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            let colors = [UIColor(red: 0.38, green: 0.16, blue: 0.82, alpha: 1).cgColor,
                          UIColor(red: 0.08, green: 0.01, blue: 0.18, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            drawing(context)
        }
    }
}
