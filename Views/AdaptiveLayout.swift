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

/// Applies both a readable-width cap and an outer gutter derived from the
/// width proposed by the parent. A custom Layout is required here because
/// `containerRelativeFrame` can report a zero horizontal length when attached
/// to content inside a vertical ScrollView, collapsing an otherwise valid page.
/// The proposal-driven layout avoids geometry state and remains live-resizable.
/// Use this on the inner content of custom scrolling pages; native List/Form
/// surfaces still need a section-level design.
private struct AdaptivePageLayout: Layout {
    let style: AdaptiveContentStyle

    private func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        let safeWidth = max(availableWidth, 0)
        let gutter = AdaptiveLayoutMetrics.horizontalGutter(for: safeWidth)
        return min(style.maximumWidth, max(safeWidth - (gutter * 2), 0))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }

        guard let availableWidth = proposal.width, availableWidth > 0 else {
            // A missing proposal must preserve content rather than turn the
            // page into a zero-width layout. The parent can constrain this
            // fallback during its next layout pass.
            return subview.sizeThatFits(proposal)
        }

        let width = contentWidth(for: availableWidth)
        let contentSize = subview.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
        return CGSize(width: availableWidth, height: contentSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }

        let width = contentWidth(for: bounds.width)
        let contentSize = subview.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
        subview.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: ProposedViewSize(width: width, height: contentSize.height)
        )
    }
}

private struct AdaptivePageContentModifier: ViewModifier {
    let style: AdaptiveContentStyle

    func body(content: Content) -> some View {
        AdaptivePageLayout(style: style) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Caps the inner reading measure while leaving its parent background,
    /// safe-area treatment and scroll container free to fill the viewport.
    func adaptiveContentWidth(_ style: AdaptiveContentStyle) -> some View {
        modifier(AdaptiveContentWidthModifier(style: style))
    }

    /// Centres page-level custom content, caps its readable measure and keeps
    /// its outer gutter proportional to the current container. Do not apply
    /// this to the outer native List/Form because doing so narrows system
    /// backgrounds, separators and scrolling chrome.
    func adaptivePageContent(_ style: AdaptiveContentStyle) -> some View {
        modifier(AdaptivePageContentModifier(style: style))
    }
}
