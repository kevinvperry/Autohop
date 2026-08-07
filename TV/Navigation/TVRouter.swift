import Foundation
import Observation

// AI CONTEXT — TV/Navigation/TVRouter.swift
// Phase 2 (tvOS proposal §7 item 1) + Phase 4 (§9 item 1, search tab): the
// typed tab enum + router object for the Home/Library/Discover/History/Settings
// sidebar-adaptable TabView. Search is a child route inside Discover. The
// router also owns per-tab NavigationPath so Library's push-to-episode-list
// survives tab switches without resetting (a common tvOS TabView footgun —
// losing the pushed detail when the user glances at another tab and comes back).
enum TVTab: String, CaseIterable, Identifiable {
    case home
    case library
    case history
    case discover
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .history: return "History"
        case .discover: return "Discover"
        case .diagnostics: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .library: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        case .discover: return "safari"
        case .diagnostics: return "gearshape"
        }
    }
}

@MainActor
@Observable
final class TVRouter {
    var selectedTab: TVTab = .home
    /// Library tab's push stack, by subscription UUID (not the Subscription
    /// value itself) — the destination view resolves the live subscription
    /// from TVAppModel on each render, so it never shows a stale snapshot if
    /// sync updates the podcast while its episode list is on screen.
    var libraryPath: [UUID] = []
}
