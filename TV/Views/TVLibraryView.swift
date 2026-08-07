import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVLibraryView.swift
// Phase 2 (tvOS proposal §7 item 4): subscription grid → episode list. Grid
// order matches priority rank to reinforce the same mental model as the
// iPhone Priority Stack page. Pushes by subscriptionID (not the Subscription
// value) via TVRouter.libraryPath so the destination always resolves the
// live subscription — see TVRouter's header.
struct TVLibraryView: View {
    let model: TVAppModel
    @Bindable var router: TVRouter
    let onPlay: (Episode) -> Void

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 40)]

    var body: some View {
        NavigationStack(path: $router.libraryPath) {
            Group {
                if model.libraryModel.tiles.isEmpty {
                    ContentUnavailableView(
                        "No library yet",
                        systemImage: "square.stack",
                        description: Text("Subscribe to podcasts in Autohop on your iPhone and turn on iCloud Sync in Settings → Sync.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            // Heading INSIDE the scroll (display-bug fix
                            // 2026-07-04: `.navigationTitle` rendered as a
                            // fixed title that scrolled grid content slid
                            // BEHIND on tvOS; an in-scroll heading scrolls
                            // away with the content, matching Home).
                            Text("Library")
                                .font(.largeTitle.bold())
                            LazyVGrid(columns: columns, spacing: 40) {
                                ForEach(model.libraryModel.tiles) { podcast in
                                    if podcast.isMaterializing {
                                        TVSubscriptionCard(podcast: podcast)
                                            .overlay(alignment: .bottomLeading) {
                                                Label("Syncing details…", systemImage: "arrow.triangle.2.circlepath")
                                                    .font(.caption.weight(.semibold))
                                                    .padding(10)
                                                    .background(.black.opacity(0.72), in: Capsule())
                                                    .padding(10)
                                            }
                                            .opacity(0.8)
                                    } else {
                                        NavigationLink(value: podcast.id) {
                                            TVSubscriptionCard(podcast: podcast)
                                        }
                                        .buttonStyle(.card)
                                        .tvFocusHighlight(cornerRadius: 18)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.vertical, 60)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { subscriptionID in
                TVEpisodeListView(
                    model: model,
                    subscriptionID: subscriptionID,
                    onPlay: onPlay
                )
            }
        }
    }
}

/// TVCard-Podcast pattern (DESIGN.md): square artwork + title, priority-ordered
/// grid — the tvOS analog of the iPhone Priority Stack subscription row. Pure
/// label content; the parent wraps it in `NavigationLink(value: subscription.id)`
/// since pushes go by UUID (Subscription itself isn't Hashable — see
/// TVRouter's header).
struct TVSubscriptionCard: View {
    let podcast: TVPodcastTileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVArtworkImage(url: podcast.artworkURL, targetPixels: 520)
                .aspectRatio(1, contentMode: .fit)
            Text(podcast.title)
                .font(.headline)
                .lineLimit(2)
        }
    }
}
