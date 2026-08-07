import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVMainTabView.swift
// Home/Library/Discover/History/Settings sidebar-adaptable TabView shell,
// shown once TVAppModel.rootState == .ready. Search now lives inside Discover
// so the app has one coherent public-catalogue destination.
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
// effect outside a navigation container. Up Next is fully integrated into
// Home and intentionally has no duplicate tab.
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
    @State private var isPreparingPlayback = false

    var body: some View {
        TabView(selection: $router.selectedTab) {
            ForEach(TVTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    destination(for: tab)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Home's system tab pill is the sole page heading. Keep the tab chrome
        // visible while shelves scroll vertically or horizontally so users do
        // not lose their location or the route back to the sidebar.
        .toolbarVisibility(.visible, for: .tabBar)
        // Phone design tokens on TV (TVTheme.swift, 2026-07-11): Accent-Purple
        // for focus/controls + the ambient brand-purple wash behind every tab.
        .tint(.purple)
        .background(TVBrandBackground())
        .overlay(alignment: .topTrailing) {
            TVCloudSyncBadge(status: model.syncStatus)
                .padding(.top, 20)
                .padding(.trailing, 28)
        }
        .overlay {
            if isPreparingPlayback {
                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing playback…")
                        .font(.headline)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .allowsHitTesting(false)
            }
        }
        .fullScreenCover(isPresented: $isPlayerVisible) {
            TVPlayerView(
                playbackModel: model.playbackModel,
                onArchive: {
                    if let episode = model.playbackModel.currentEpisode {
                        model.archiveEpisode(episode)
                    }
                    isPlayerVisible = false
                },
                onExit: {
                    model.playbackModel.dismissedCover()
                    isPlayerVisible = false
                }
            )
        }
    }

    @ViewBuilder
    private func destination(for tab: TVTab) -> some View {
        switch tab {
        case .home:
            TVHomeView(
                model: model,
                onPlay: { play($0) },
                onReopenPlayer: { isPlayerVisible = true }
            )
        case .library:
            TVLibraryView(model: model, router: router, onPlay: { play($0) })
        case .history:
            TVHistoryView(model: model) { episode in
                play(episode, restartFromBeginning: true)
            }
        case .discover:
            TVDiscoverView { episode, subscription in
                playDiscover(episode, subscription: subscription)
            }
        case .diagnostics:
            TVDiagnosticsView(model: model)
        }
    }

    private func play(_ episode: Episode, restartFromBeginning: Bool = false) {
        if model.playbackModel.isCurrentEpisode(episode), !restartFromBeginning {
            isPlayerVisible = true
            return
        }
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        Task { @MainActor in
            await model.beginPlayback(episode, restartFromBeginning: restartFromBeginning)
            isPreparingPlayback = false
            // Present AVKit only after media classification, item readiness and
            // the resume seek complete. Physical tvOS otherwise retains the
            // cover's interim audio-only hierarchy until it is dismissed and
            // reopened around the same player.
            if model.playbackModel.currentEpisode != nil,
               model.playbackModel.errorMessage == nil {
                isPlayerVisible = true
            }
        }
    }

    private func playDiscover(_ episode: Episode, subscription: Subscription) {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        Task { @MainActor in
            await model.beginDiscoverPlayback(episode, subscription: subscription)
            isPreparingPlayback = false
            if model.playbackModel.currentEpisode != nil,
               model.playbackModel.errorMessage == nil {
                isPlayerVisible = true
            }
        }
    }
}
