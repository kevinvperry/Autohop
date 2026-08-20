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

    /// Scales non-text artwork, symbols and spacing in lockstep with the
    /// editorial typography. Standard preserves the established iPhone design.
    var contentScale: CGFloat {
        switch band {
        case .narrow:    return 0.92
        case .standard:  return 1
        case .wide:      return 1.15
        case .expansive: return 1.3
        }
    }

    func scaled(_ value: CGFloat) -> CGFloat { value * contentScale }

    var pageSectionSpacing: CGFloat { scaled(60) }
    var introSectionSpacing: CGFloat { scaled(16) }
    var pageTopPadding: CGFloat { scaled(8) }

    var bannerTitleFont: Font { band == .expansive ? .title3.bold() : (band == .wide ? .headline.bold() : .subheadline.bold()) }
    var bannerDetailFont: Font { band == .expansive ? .body.weight(.medium) : (band == .wide ? .subheadline.weight(.medium) : .caption.weight(.medium)) }
    var searchFont: Font { band == .expansive ? .title3 : (band == .wide ? .body : .subheadline) }
    var sectionTitleFont: Font { band == .expansive ? .title.bold() : (band == .wide ? .title2.bold() : .title3.bold()) }
    var seeAllFont: Font { band == .expansive ? .title3.weight(.semibold) : (band == .wide ? .body.weight(.semibold) : .subheadline.weight(.semibold)) }
    var seeAllSymbolFont: Font { band == .expansive ? .body.bold() : (band == .wide ? .subheadline.bold() : .caption2.bold()) }

    var chipFont: Font { band == .expansive ? .title3.weight(.semibold) : (band == .wide ? .body.weight(.semibold) : .subheadline.weight(.semibold)) }
    var chipSymbolFont: Font { band == .expansive ? .body.weight(.semibold) : (band == .wide ? .subheadline.weight(.semibold) : .caption.weight(.semibold)) }
    var railHeadingFont: Font { sectionTitleFont }
    var railHeadingSymbolFont: Font { band == .expansive ? .title.bold() : (band == .wide ? .title2.weight(.semibold) : .title3.weight(.semibold)) }
    var shelfTitleFont: Font { band == .expansive ? .body.weight(.semibold) : (band == .wide ? .subheadline.weight(.semibold) : .caption.weight(.semibold)) }
    var shelfMetadataFont: Font { band == .expansive ? .subheadline : (band == .wide ? .caption : .caption2) }
    var shelfRankFont: Font { band == .expansive ? .subheadline.bold() : (band == .wide ? .caption.bold() : .caption2.bold()) }

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
        case .wide:      return min(max(heroCardHeight - 40, 196), 236)
        case .expansive: return min(max(heroCardHeight - 44, 260), 316)
        }
    }

    var featureArtworkSize: CGFloat {
        switch band {
        case .narrow:    return 120
        case .standard:  return 140
        case .wide:      return min(max(featureCardHeight - 40, 190), 220)
        case .expansive: return min(max(featureCardHeight - 44, 250), 296)
        }
    }

    var heroContentSpacing: CGFloat { band == .expansive ? 22 : (band == .wide ? 18 : 14) }
    var heroTextSpacing: CGFloat { band == .expansive ? 8 : (band == .wide ? 6 : 4) }
    var heroContentPadding: CGFloat { band == .expansive ? 22 : (band == .wide ? 20 : 18) }
    var heroRankFont: Font { band == .expansive ? .title3.bold() : (band == .wide ? .headline.bold() : .caption.bold()) }
    var heroTitleFont: Font { band == .expansive ? .title.bold() : (band == .wide ? .title2.bold() : .headline.bold()) }
    var heroMetadataFont: Font { band == .expansive ? .title3 : (band == .wide ? .body : .caption) }
    var heroDetailFont: Font { band == .expansive ? .body.weight(.semibold) : (band == .wide ? .subheadline.weight(.semibold) : .caption2.weight(.semibold)) }
    var heroTitleLineLimit: Int { band == .expansive ? 4 : 3 }

    var heroPlaceholderIconSize: CGFloat { scaled(36) }
    var heroArtworkCornerRadius: CGFloat { scaled(18) }
    var heroCardCornerRadius: CGFloat { scaled(22) }
    var heroGhostRankSize: CGFloat { scaled(230) }
    var heroGhostRankOffset: CGSize { CGSize(width: scaled(18), height: -scaled(34)) }
    var heroRankHorizontalPadding: CGFloat { scaled(9) }
    var heroRankVerticalPadding: CGFloat { scaled(4) }
    var carouselDotClearance: CGFloat { scaled(36) }

    var featureContentSpacing: CGFloat { band == .expansive ? 22 : (band == .wide ? 18 : 16) }
    var featureTextSpacing: CGFloat { band == .expansive ? 8 : (band == .wide ? 7 : 6) }
    var featureContentPadding: CGFloat { band == .expansive ? 24 : (band == .wide ? 22 : 20) }
    var featureRankFont: Font { band == .expansive ? .title3.bold() : (band == .wide ? .headline.bold() : .caption.bold()) }
    var featureTitleFont: Font { band == .expansive || band == .wide ? .title.bold() : .title3.bold() }
    var featureMetadataFont: Font { band == .expansive ? .title3 : (band == .wide ? .headline : .subheadline) }
    var featureDetailFont: Font { band == .expansive ? .body.weight(.semibold) : (band == .wide ? .subheadline.weight(.semibold) : .caption.weight(.semibold)) }
    var featureTitleLineLimit: Int { band == .expansive ? 3 : 2 }

    var compactArtworkSize: CGFloat {
        switch band {
        case .narrow:    return 76
        case .standard:  return 84
        case .wide:      return 92
        case .expansive: return 100
        }
    }

    var shelfCornerRadius: CGFloat { scaled(14) }
    var shelfPlaceholderIconSize: CGFloat { scaled(26) }
    var shelfTextSpacing: CGFloat { scaled(6) }
    var shelfRankHorizontalPadding: CGFloat { scaled(7) }
    var shelfRankVerticalPadding: CGFloat { scaled(3) }
    var shelfRankInset: CGFloat { scaled(6) }
    var seeAllTileSymbolSize: CGFloat { scaled(30) }

    /// Height for the card itself. The aspect ratio governs normal phone sizes;
    /// the clamp prevents a single hero from consuming an entire wide viewport.
    var heroCardHeight: CGFloat {
        let cardWidth = max(availableWidth - (horizontalGutter * 2), 0)
        return min(max(cardWidth / 1.38, 230), band == .expansive ? 360 : 300)
    }

    /// Includes clearance for the page-control dots beneath a hero card.
    var heroCarouselHeight: CGFloat { heroCardHeight + carouselDotClearance }

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

// AI CONTEXT — Navigation-heavy modal surfaces need different presentation
// ownership from compact controls. iPhone keeps the familiar sheet gesture;
// regular-width iPad and Mac windows receive a full navigation canvas so pages
// pushed from Menu or Up Next do not inherit an undersized form-sheet frame.
// Do not use this for small confirmation, picker or share sheets.
private struct AdaptiveNavigationPresentationModifier<Presented: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let presentedContent: () -> Presented

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content.fullScreenCover(
                isPresented: $isPresented,
                onDismiss: onDismiss,
                content: presentedContent
            )
        } else {
            content.sheet(
                isPresented: $isPresented,
                onDismiss: onDismiss,
                content: presentedContent
            )
        }
    }
}

private struct AdaptiveItemNavigationPresentationModifier<Item: Identifiable, Presented: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let presentedContent: (Item) -> Presented

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content.fullScreenCover(
                item: $item,
                onDismiss: onDismiss,
                content: presentedContent
            )
        } else {
            content.sheet(
                item: $item,
                onDismiss: onDismiss,
                content: presentedContent
            )
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

    /// Presents page-like navigation at an appropriate scale: a sheet on
    /// compact iPhone layouts and a full canvas on regular-width iPad/Mac.
    func adaptiveNavigationPresentation<Presented: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Presented
    ) -> some View {
        modifier(AdaptiveNavigationPresentationModifier(
            isPresented: isPresented,
            onDismiss: onDismiss,
            presentedContent: content
        ))
    }

    /// Identifiable-item counterpart used by page routes whose destination is
    /// not known until the user selects an episode or podcast.
    func adaptiveNavigationPresentation<Item: Identifiable, Presented: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Presented
    ) -> some View {
        modifier(AdaptiveItemNavigationPresentationModifier(
            item: item,
            onDismiss: onDismiss,
            presentedContent: content
        ))
    }
}
