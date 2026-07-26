import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVMainTabView.swift
// Phase 2 (tvOS proposal §7 item 1) + Phase 4 (§9 item 1): the
// Home/Queue/Library/Search sidebar-adaptable TabView shell, shown once
// TVAppModel.rootState == .ready. `.search` is built OUTSIDE the ForEach
// with the dedicated `Tab(value:role: .search)` initializer — it gets
// tvOS's native search-role treatment (system search field placement, etc.),
// which the title/systemImage-based `Tab(_:systemImage:value:)` used by the
// other three does not provide.
// NAVIGATIONSTACK FOOTGUN (fixed 2026-07-04, found in Kevin's first Simulator
// run): do NOT wrap every tab's content in its own NavigationStack under
// `.sidebarAdaptable` — only wrap a tab that actually pushes to another
// screen. Home and Queue are flat (no push destination), so nesting a second
// navigation container inside them fought the TabView's own sidebar chrome:
// the sidebar auto-collapsed into a small pill after a few seconds and could
// not be reliably re-expanded from the Simulator. Only Library gets a
// NavigationStack (for its grid → episode-list push), and it already
// provides its own internally (TVLibraryView). Home/Queue show their own
// plain heading text instead of relying on `.navigationTitle`, which has no
// effect outside a navigation container.
struct TVMainTabView: View {
    let model: TVAppModel
    @State private var router = TVRouter()
    /// Cover visibility is a PURE navigation concern, deliberately decoupled
    /// from whether the model is playing (audio keeps going in the background
    /// after the user dismisses — UIBackgroundModes: audio). Do not derive
    /// this from `playbackModel.currentEpisode != nil`: that stays set across
    /// dismissal and across auto-advance, so tying visibility to it would
    /// either fail to show a fresh play or force the cover back open when the
    /// user had deliberately backed out of it.
    @State private var isPlayerVisible = false

    var body: some View {
        TabView(selection: $router.selectedTab) {
            ForEach(TVTab.allCases.filter { $0 != .search }) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    destination(for: tab)
                }
            }
            Tab(value: TVTab.search, role: .search) {
                TVSearchView(model: model)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Phone design tokens on TV (TVTheme.swift, 2026-07-11): Accent-Purple
        // for focus/controls + the ambient brand-purple wash behind every tab.
        .tint(.purple)
        .background(TVBrandBackground())
        .fullScreenCover(isPresented: $isPlayerVisible) {
            TVPlayerView(playbackModel: model.playbackModel) {
                model.playbackModel.dismissedCover()
                isPlayerVisible = false
            }
        }
    }

    @ViewBuilder
    private func destination(for tab: TVTab) -> some View {
        switch tab {
        case .home:
            TVHomeView(model: model, onPlay: play)
        case .queue:
            TVQueueView(model: model, onPlay: play)
        case .library:
            TVLibraryView(model: model, router: router, onPlay: play)
        case .search:
            // Never reached — `.search` is built directly in `body` with the
            // dedicated search-role Tab initializer, not via this switch.
            TVSearchView(model: model)
        case .diagnostics:
            TVDiagnosticsView(model: model)
        }
    }

    private func play(_ episode: Episode) {
        model.beginPlayback(episode)
        isPlayerVisible = true
    }
}
