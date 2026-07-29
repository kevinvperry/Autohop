import SwiftUI

// AI CONTEXT — Views/AdaptiveLayout.swift
// Central vocabulary for viewport-responsive iOS layout. Views must classify
// the space offered by their container, never a device model or size class.
// Keep every width threshold and readable-content maximum here so future iPad,
// Mac and resizable-window tuning changes one source of truth. These helpers do
// not enable a new device family or change navigation; they are safe foundations
// for the phased resizability project documented in Docs/.

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
