import CarPlay
import UIKit

// ============================================================================
// AI CONTEXT - CarPlay/CarPlayArtworkProvider.swift
//
// PURPOSE: Non-SwiftUI artwork adapter for CarPlay templates. CarPlay list rows
// need display-ready UIImages, while Autohop's existing artwork pipeline lives in
// ArtworkImageCache behind the SwiftUI CachedArtworkImage wrapper. This provider
// bridges those worlds and always supplies a placeholder immediately so artwork
// failures, cache misses, locked-device reads, or slow network responses never
// block the CarPlay queue UI.
//
// CURRENT SCOPE: Phase 6 locked-device hardening. The provider sizes images for
// CarPlay list rows using CPListItem.maximumImageSize, returns a placeholder for
// missing/failed/protected/slow artwork, and relies on ArtworkImageCache disk
// files being available after first unlock. It does not initiate downloads or
// mutate app state.
// ============================================================================

@MainActor
final class CarPlayArtworkProvider {
    private let placeholder: UIImage

    init() {
        let size = CPListItem.maximumImageSize
        let side = max(48, min(size.width, size.height))
        placeholder = Self.makePlaceholder(size: CGSize(width: side, height: side))
    }

    func placeholderImage() -> UIImage {
        placeholder
    }

    func image(for url: URL?) async -> UIImage {
        guard let url else { return placeholder }
        let size = CPListItem.maximumImageSize
        let targetSize = CGSize(width: max(48, size.width), height: max(48, size.height))
        return await ArtworkImageCache.shared.image(
            for: url,
            targetSize: targetSize,
            scale: UIScreen.main.scale,
            priority: .visible
        ) ?? placeholder
    }

    private static func makePlaceholder(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: size.width * 0.18).fill()

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: size.width * 0.42, weight: .semibold)
            let symbol = UIImage(systemName: "waveform", withConfiguration: symbolConfig)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            let symbolSize = symbol?.size ?? .zero
            let symbolOrigin = CGPoint(
                x: (size.width - symbolSize.width) / 2,
                y: (size.height - symbolSize.height) / 2
            )
            symbol?.draw(in: CGRect(origin: symbolOrigin, size: symbolSize))

            UIColor.white.withAlphaComponent(0.12).setStroke()
            UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: size.width * 0.18)
                .stroke()
            _ = context
        }
    }
}
