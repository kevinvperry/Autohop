import SwiftUI

// AI CONTEXT — Views/AdaptiveLayout.swift
// Central vocabulary for viewport-responsive iOS layout. Views must classify
// the space offered by their container, never a device model or size class.
// Keep every width threshold and readable-content maximum here so future iPad,
// Mac and resizable-window tuning changes one source of truth. These helpers do
// not enable a new device family or change navigation; they are safe foundations
// for the phased resizability project documented in Docs/. Editorial metrics
// preserve the established iPhone proportions while allowing shelves, heroes
// and ranked lists to grow deliberately on iPad and resizable Mac windows.

enum AdaptiveLayoutBand: String, CaseIterable, Equatable {
    case narrow
    case standard
    case wide
    case expansive

    static func classify(width: CGFloat) -> Self {
        switch width {
        case ..<340: return .narrow
        case ..<500: return .standard
        case ..<700: return .wide
        default:     return .expansive
        }
    }
}

enum AdaptiveContentStyle {
    case prose
    case form
    case list
    case editorial

    var maximumWidth: CGFloat {
        switch self {
        case .prose, .form: return 720
        case .list:         return 900
        case .editorial:    return 1_100
        }
    }
}

enum AdaptiveLayoutMetrics {
    static func horizontalGutter(for width: CGFloat) -> CGFloat {
        switch AdaptiveLayoutBand.classify(width: width) {
        case .narrow:    return 12
        case .standard:  return 16
        case .wide:      return 20
        case .expansive: return 28
        }
    }

    static func metadataColumns(for width: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: width < 340 ? 132 : 150), spacing: 8)]
    }

    static func choiceColumns(for width: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: width < 340 ? 82 : 96), spacing: 10)]
    }
}

/// Shared measurements for image-led editorial surfaces. Construct this from
/// the width offered by the page's immediate container, not UIScreen bounds.
/// The readable width cap prevents artwork and cards from becoming needlessly
/// large on expansive windows while still revealing more complete shelf cards.
struct AdaptiveEditorialMetrics: Equatable {
    let availableWidth: CGFloat
    let band: AdaptiveLayoutBand

    init(containerWidth: CGFloat) {
        let safeWidth = max(containerWidth, 0)
        availableWidth = min(safeWidth, AdaptiveContentStyle.editorial.maximumWidth)
        band = AdaptiveLayoutBand.classify(width: availableWidth)
    }

    var horizontalGutter: CGFloat {
        AdaptiveLayoutMetrics.horizontalGutter(for: availableWidth)
    }

    var shelfArtworkSize: CGFloat {
        switch band {
        case .narrow:    return 112
        case .standard:  return 124
        case .wide:      return 136
        case .expansive: return 152
        }
    }

    var shelfSpacing: CGFloat {
        switch band {
        case .narrow:    return 12
        case .standard:  return 14
        case .wide:      return 16
        case .expansive: return 18
        }
    }

    var heroArtworkSize: CGFloat {
        switch band {
        case .narrow:    return 132
        case .standard:  return 148
        case .wide:      return 164
        case .expansive: return 180
        }
    }

    var featureArtworkSize: CGFloat {
        switch band {
        case .narrow:    return 120
        case .standard:  return 140
        case .wide:      return 156
        case .expansive: return 176
        }
    }

    var compactArtworkSize: CGFloat {
        switch band {
        case .narrow:    return 76
        case .standard:  return 84
        case .wide:      return 92
        case .expansive: return 100
        }
    }

    /// Height for the card itself. The aspect ratio governs normal phone sizes;
    /// the clamp prevents a single hero from consuming an entire wide viewport.
    var heroCardHeight: CGFloat {
        let cardWidth = max(availableWidth - (horizontalGutter * 2), 0)
        return min(max(cardWidth / 1.38, 230), band == .expansive ? 360 : 300)
    }

    /// Includes clearance for the page-control dots beneath a hero card.
    var heroCarouselHeight: CGFloat { heroCardHeight + 36 }

    var featureCardHeight: CGFloat {
        let cardWidth = max(availableWidth - (horizontalGutter * 2), 0)
        return min(max(cardWidth / 1.65, 200), band == .expansive ? 340 : 260)
    }
}

private struct AdaptiveContentWidthModifier: ViewModifier {
    let style: AdaptiveContentStyle

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: style.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    /// Caps the inner reading measure while leaving its parent background,
    /// safe-area treatment and scroll container free to fill the viewport.
    func adaptiveContentWidth(_ style: AdaptiveContentStyle) -> some View {
        modifier(AdaptiveContentWidthModifier(style: style))
    }
}
