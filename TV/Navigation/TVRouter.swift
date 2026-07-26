import Foundation
import Observation

// AI CONTEXT — TV/Navigation/TVRouter.swift
// Phase 2 (tvOS proposal §7 item 1) + Phase 4 (§9 item 1, search tab): the
// typed tab enum + router object for the Home/Queue/Library/Search
// sidebar-adaptable TabView (PC MainTabView/MainTabRouter shape, §2.1 there).
// `.search` is NOT built with `Tab(title:systemImage:value:)` like the other
// three — it uses the dedicated `Tab(value:role: .search)` initializer
// (TVMainTabView special-cases it), so `title`/`systemImage` below are unused
// for `.search` but kept for `CaseIterable`-driven switches elsewhere. The
// router also owns per-tab NavigationPath so Library's push-to-episode-list
// survives tab switches without resetting (a common tvOS TabView footgun —
// losing the pushed detail when the user glances at another tab and comes back).
enum TVTab: String, CaseIterable, Identifiable {
    case home
    case queue
    case library
    case search
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .queue: return "Up Next"
        case .library: return "Library"
        case .search: return "Search"
        case .diagnostics: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .queue: return "square.stack"
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
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
