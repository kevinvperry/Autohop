import SwiftUI
import UIKit

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
    static let episodeListHorizontalPadding: CGFloat = 20
    /// AI CONTEXT — System Settings and Podcast Settings use one deliberately
    /// generous section rhythm on every iOS-family width. Keep this independent
    /// of row padding: it separates menu groups without loosening their cards.
    static let settingsSectionSpacing: CGFloat = 48
    static let episodeListMaximumSurfaceWidth: CGFloat =
        AdaptiveContentStyle.list.maximumWidth - (episodeListHorizontalPadding * 2)

    static func episodeListSurfaceWidth(for availableWidth: CGFloat) -> CGFloat {
        min(
            episodeListMaximumSurfaceWidth,
            max(availableWidth - (episodeListHorizontalPadding * 2), 0)
        )
    }

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

    // Discover navigation chrome shares the editorial width bands instead of
    // remaining at UIKit's phone-sized inline defaults on iPad and Mac.
    var navigationTitleFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 17
        case .wide:              return 22
        case .expansive:         return 28
        }
    }

    var navigationControlFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 15
        case .wide:              return 18
        case .expansive:         return 21
        }
    }

    var navigationBackSymbolSize: CGFloat {
        switch band {
        case .narrow, .standard: return 20
        case .wide:              return 25
        case .expansive:         return 28
        }
    }

    /// Inline navigation bars provide a 44-point vertical control slot even in
    /// expansive iPad/Mac windows. Keep the hit target within that slot so the
    /// circular Back glyph is never clipped by the toolbar host.
    var navigationControlSize: CGFloat {
        switch band {
        case .narrow, .standard: return 36
        case .wide:              return 44
        case .expansive:         return 44
        }
    }

    /// Persistent player chrome grows enough to remain visually balanced on
    /// iPad and Mac without turning the utility bar into a second player page.
    var miniPlayerArtworkSize: CGFloat {
        switch band {
        case .narrow, .standard: return 40
        case .wide:              return 46
        case .expansive:         return 52
        }
    }

    var miniPlayerControlSize: CGFloat {
        switch band {
        case .narrow, .standard: return 44
        case .wide:              return 48
        case .expansive:         return 52
        }
    }

    /// Podcast detail headers prioritize episode-list height until the actual
    /// content column—not the physical device—offers 600 points. This keeps
    /// iPhone, narrow split view and future folding widths side-by-side while
    /// allowing full iPad/Mac columns to use the centred editorial hero.
    var usesCenteredPodcastHeader: Bool { availableWidth >= 600 }

    /// Settings shortcut rails require enough room for a fixed 240-point rail
    /// plus a readable Form. Narrow iPad multitasking remains single-column.
    var usesSettingsShortcutSidebar: Bool { band == .expansive }

    var detailTitleFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 22
        case .wide:              return 26
        case .expansive:         return 30
        }
    }

    var detailDescriptionFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 13
        case .wide:              return 15
        case .expansive:         return 17
        }
    }

    var detailPublisherFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 15
        case .wide:              return 17
        case .expansive:         return 19
        }
    }

    var primaryButtonFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 17
        case .wide:              return 19
        case .expansive:         return 21
        }
    }

    var primaryButtonHeight: CGFloat {
        switch band {
        case .narrow, .standard: return 46
        case .wide:              return 52
        case .expansive:         return 58
        }
    }

    var navigationChevronSize: CGFloat { navigationControlFontSize * 0.72 }

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

/// Shared density for every native List/Form and custom list-style row. Unlike
/// editorial cards, rows grow conservatively so iPad and Mac show more legible
/// content without losing the scanning advantage of a list.
struct AdaptiveListRowMetrics: Equatable {
    let band: AdaptiveLayoutBand

    init(containerWidth: CGFloat) {
        band = AdaptiveLayoutBand.classify(width: min(max(containerWidth, 0), AdaptiveContentStyle.list.maximumWidth))
    }

    var artworkSize: CGFloat {
        switch band {
        case .narrow, .standard: return 44
        case .wide:              return 52
        case .expansive:         return 60
        }
    }

    var minimumRowHeight: CGFloat {
        switch band {
        case .narrow, .standard: return 44
        case .wide:              return 54
        case .expansive:         return 62
        }
    }

    var rowSpacing: CGFloat {
        switch band {
        case .narrow, .standard: return 12
        case .wide:              return 14
        case .expansive:         return 16
        }
    }

    var primaryFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 15
        case .wide:              return 17
        case .expansive:         return 19
        }
    }

    var secondaryFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 12
        case .wide:              return 14
        case .expansive:         return 15
        }
    }

    var verticalPadding: CGFloat {
        switch band {
        case .narrow, .standard: return 6
        case .wide:              return 9
        case .expansive:         return 11
        }
    }

    /// Compact row-adjacent controls (rank markers, expanded-row shortcuts,
    /// refresh buttons) must grow with the row rather than remaining at their
    /// original 30-point phone geometry.
    var compactControlSize: CGFloat {
        switch band {
        case .narrow, .standard: return 30
        case .wide:              return 36
        case .expansive:         return 42
        }
    }

    var compactControlFontSize: CGFloat {
        switch band {
        case .narrow, .standard: return 13
        case .wide:              return 15
        case .expansive:         return 17
        }
    }

    var leadingMarkerWidth: CGFloat {
        switch band {
        case .narrow, .standard: return 20
        case .wide:              return 24
        case .expansive:         return 28
        }
    }
}

// AI CONTEXT — Expansive Settings pages use a fixed shortcut rail beside the
// existing scrolling Form. The generic identity keeps each page's section map
// type-safe; buttons retain focus after activation so keyboard users can make
// several jumps quickly, while Return activates the focused shortcut.
struct SettingsShortcutItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let systemImage: String
}

struct SettingsShortcutSidebar<ID: Hashable>: View {
    let items: [SettingsShortcutItem<ID>]
    @Binding var selection: ID
    let navigate: (ID) -> Void

    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    @FocusState private var focusedItem: ID?

    var body: some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: viewportWidth)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts")
                    .font(.system(size: metrics.detailPublisherFontSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                ForEach(items) { item in
                    Button {
                        selection = item.id
                        navigate(item.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
                                .frame(width: 28)
                            Text(item.title)
                                .font(.system(size: metrics.detailDescriptionFontSize, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selection == item.id ? .white : .secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: metrics.primaryButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selection == item.id ? Color.purple.opacity(0.28) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedItem, equals: item.id)
                    .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                }
            }
            .padding(16)
        }
        .frame(width: 240)
        .background(Color.black)
    }
}

/// Bridges expansive Settings shortcut commands to the native scrolling view
/// underlying SwiftUI `Form`. A Form virtualizes distant rows, so
/// `ScrollViewReader` cannot resolve a destination view that has not been
/// created yet. Native section indexes remain addressable regardless of row
/// realization and therefore make long-distance shortcuts deterministic.
struct FormSectionScrollController: UIViewRepresentable {
    let section: Int?
    let requestID: UUID

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let section, context.coordinator.lastRequestID != requestID else { return }
        context.coordinator.lastRequestID = requestID
        DispatchQueue.main.async {
            if !scroll(section: section, relativeTo: view) {
                // A newly presented Form may not have completed its UIKit list
                // layout during the first pass. One bounded retry avoids racing
                // presentation without creating a polling loop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    _ = scroll(section: section, relativeTo: view)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastRequestID: UUID?
    }

    @discardableResult
    private func scroll(section: Int, relativeTo marker: UIView) -> Bool {
        guard let window = marker.window else { return false }
        window.layoutIfNeeded()

        if let collection = bestFormScrollView(
            of: window,
            type: UICollectionView.self
        ), collection.numberOfSections > section,
           collection.numberOfItems(inSection: section) > 0 {
            collection.layoutIfNeeded()
            collection.scrollToItem(
                at: IndexPath(item: 0, section: section),
                // AI CONTEXT — Centre shortcut destinations rather than pinning
                // their first control to the navigation bar. Form headings are
                // supplementary views immediately above that control; `.top`
                // crops the heading and removes useful surrounding context.
                at: .centeredVertically,
                animated: true
            )
            return true
        }

        if let table = bestFormScrollView(
            of: window,
            type: UITableView.self
        ), table.numberOfSections > section,
           table.numberOfRows(inSection: section) > 0 {
            table.layoutIfNeeded()
            table.scrollToRow(
                at: IndexPath(row: 0, section: section),
                at: .middle,
                animated: true
            )
            return true
        }
        return false
    }

    /// Finds the actual Form surface rather than relying on the coordinate of
    /// this representable's invisible SwiftUI background. Background markers
    /// can legitimately bridge into UIKit with zero-sized frames. The Form is
    /// the visible, enabled native list with the greatest vertical content
    /// extent; the shortcut rail is a SwiftUI ScrollView and is not a candidate.
    private func bestFormScrollView<T: UIScrollView>(
        of root: UIView,
        type: T.Type
    ) -> T? {
        var matches: [T] = []
        func collect(_ view: UIView) {
            if let match = view as? T,
               !match.isHidden,
               match.alpha > 0,
               match.isScrollEnabled,
               match.bounds.width > 300,
               match.bounds.height > 200 {
                matches.append(match)
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        return matches.max {
            let lhsExtent = max($0.contentSize.height, $0.bounds.height)
            let rhsExtent = max($1.contentSize.height, $1.bounds.height)
            return lhsExtent < rhsExtent
        }
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

// AI CONTEXT — Responsive navigation chrome is shared by every iOS-family
// inline-title page. It measures the immediate presentation container, injects
// that width for toolbar descendants, and replaces UIKit's phone-sized
// principal title with the same banded scale used by Discover. Keep this
// container-driven: a regular size class alone cannot distinguish split-view
// iPad from a full-width Mac window.
private struct AdaptiveViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 390
}

extension EnvironmentValues {
    var adaptiveViewportWidth: CGFloat {
        get { self[AdaptiveViewportWidthKey.self] }
        set { self[AdaptiveViewportWidthKey.self] = newValue }
    }
}

private struct ResponsiveNavigationWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ResponsiveInlineNavigationTitleModifier: ViewModifier {
    let title: String
    @State private var width: CGFloat = 390

    private var metrics: AdaptiveEditorialMetrics {
        AdaptiveEditorialMetrics(containerWidth: width)
    }

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ResponsiveNavigationWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
                }
            }
            .onPreferenceChange(ResponsiveNavigationWidthPreferenceKey.self) { measuredWidth in
                guard measuredWidth.isFinite, measuredWidth > 0 else { return }
                width = measuredWidth
            }
            .environment(\.adaptiveViewportWidth, width)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.system(size: metrics.navigationTitleFontSize, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

private struct ResponsiveToolbarSymbolModifier: ViewModifier {
    @Environment(\.adaptiveViewportWidth) private var width

    func body(content: Content) -> some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: width)
        content
            // AI CONTEXT — Native toolbar capsules have less vertical drawing
            // room than their 44-point hit target. Utility glyphs such as Share
            // are taller than circular Back artwork and must use this bounded
            // font band to avoid clipping on iPad/Mac.
            .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
            .frame(width: metrics.navigationControlSize, height: metrics.navigationControlSize)
            .contentShape(Rectangle())
    }
}

private struct ResponsiveToolbarBackSymbolModifier: ViewModifier {
    @Environment(\.adaptiveViewportWidth) private var width

    func body(content: Content) -> some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: width)
        content
            .font(.system(size: metrics.navigationBackSymbolSize, weight: .semibold))
            .frame(width: metrics.navigationControlSize, height: metrics.navigationControlSize)
            .contentShape(Rectangle())
    }
}

private struct ResponsiveToolbarLabelModifier: ViewModifier {
    @Environment(\.adaptiveViewportWidth) private var width

    func body(content: Content) -> some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: width)
        content
            .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
            .frame(minHeight: metrics.navigationControlSize)
            .contentShape(Rectangle())
    }
}

private struct ResponsiveListSizingModifier: ViewModifier {
    @Environment(\.adaptiveViewportWidth) private var width

    func body(content: Content) -> some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: width)
        content
            .environment(\.defaultMinListRowHeight, metrics.minimumRowHeight)
            .font(.system(size: metrics.primaryFontSize))
    }
}

/// Canonical horizontal measure for vertical episode collections. Podcast
/// Detail established the visual baseline: 20-point phone gutters and an
/// inclusive 900-point outer width cap (860 points of list surface on expansive
/// windows). Keep the surrounding page/sheet background full width.
private struct EpisodeListPageWidthModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AdaptiveLayoutMetrics.episodeListHorizontalPadding)
            .frame(maxWidth: AdaptiveContentStyle.list.maximumWidth)
            .frame(maxWidth: .infinity, alignment: .center)
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

    /// Scales an inline page heading from the immediate container width while
    /// retaining the caller's navigationTitle for system semantics/history.
    func responsiveInlineNavigationTitle(_ title: String) -> some View {
        modifier(ResponsiveInlineNavigationTitleModifier(title: title))
    }

    /// Applies the shared large-screen toolbar symbol and bounded 44-point host
    /// frame. Use on icon-only Back/Close/Add/Menu controls, not text buttons.
    func responsiveToolbarSymbol() -> some View {
        modifier(ResponsiveToolbarSymbolModifier())
    }

    /// Circular Back artwork has compact intrinsic bounds and can use the
    /// larger navigation band without clipping tall native-toolbar glyphs.
    func responsiveToolbarBackSymbol() -> some View {
        modifier(ResponsiveToolbarBackSymbolModifier())
    }

    /// Text-and-symbol toolbar actions use the same width bands as page titles
    /// while retaining their natural horizontal size.
    func responsiveToolbarLabel() -> some View {
        modifier(ResponsiveToolbarLabelModifier())
    }

    /// Gives all native List/Form rows a consistent large-screen baseline.
    /// Individual image-led rows additionally read `AdaptiveListRowMetrics` to
    /// scale artwork and explicit primary/secondary typography.
    func responsiveListSizing() -> some View {
        modifier(ResponsiveListSizingModifier())
    }

    /// Applies Podcast Detail's canonical left/right episode-list padding and
    /// readable-width cap without narrowing the page background or navigation.
    func episodeListPageWidth() -> some View {
        modifier(EpisodeListPageWidthModifier())
    }
}
