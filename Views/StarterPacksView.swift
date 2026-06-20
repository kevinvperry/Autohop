import SwiftUI

// AI CONTEXT — Views/StarterPacksView.swift (onboarding starter packs).
// First-run "not sure where to start?" helper (ONBOARDING_PLAN.md Phase 7,
// selection = option 1: chart-derived). Each pack is a genre's current Top-N
// from Apple's public charts (PodcastChartsService), scoped to the user's storefront —
// zero maintenance, always fresh, regionally correct. "Add these shows" resolves
// each entry's RSS feed and subscribes to all via AppState.subscribeToFeedURLs.
// Presented as a sheet from the empty Subscriptions state and the Discover
// first-run banner.

@MainActor
final class StarterPacksViewModel: ObservableObject {
    struct Pack: Identifiable {
        let genre: ChartGenre
        let podcasts: [ChartPodcast]
        var id: Int { genre.id }
    }

    @Published var packs: [Pack] = []
    @Published var isLoading = true
    @Published var failed = false

    private let charts = PodcastChartsService()
    // A scannable subset of genres for first impressions (not all rails).
    private let genres: [ChartGenre] = [
        ChartGenre(id: 1303, name: "Comedy"),
        ChartGenre(id: 1489, name: "News"),
        ChartGenre(id: 1488, name: "True Crime"),
        ChartGenre(id: 1321, name: "Business"),
        ChartGenre(id: 1318, name: "Technology"),
        ChartGenre(id: 1545, name: "Sports"),
    ]

    func load(country: String) async {
        isLoading = true
        failed = false
        var loaded: [Pack] = []
        for genre in genres {
            if let list = try? await charts.topPodcasts(country: country, genre: genre, limit: 6),
               !list.isEmpty {
                loaded.append(Pack(genre: genre, podcasts: Array(list.prefix(6))))
            }
        }
        packs = loaded
        failed = loaded.isEmpty
        isLoading = false
    }

    /// Resolves every show in a pack to its RSS feed URL (Apple-exclusive shows
    /// with no public feed are silently dropped).
    func feedURLs(for pack: Pack, country: String) async -> [URL] {
        var urls: [URL] = []
        for podcast in pack.podcasts {
            if let result = try? await charts.resolveFeed(for: podcast, country: country) {
                urls.append(result.feedURL)
            }
        }
        return urls
    }
}

struct StarterPacksView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("discoverCountryCode") private var storedCountryCode = ""
    @StateObject private var viewModel = StarterPacksViewModel()
    @State private var addingPackID: Int?
    @State private var addedPackIDs: Set<Int> = []

    private var country: String {
        if !storedCountryCode.isEmpty { return storedCountryCode }
        return Locale.current.region?.identifier.lowercased() ?? "us"
    }

    private var pageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    loadingView
                } else if viewModel.failed {
                    failedView
                } else {
                    packsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("Starter Packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(addedPackIDs.isEmpty ? "Cancel" : "Done") { dismiss() }
                        .foregroundStyle(.purple)
                }
            }
            .preferredColorScheme(.dark)
        }
        .task { await viewModel.load(country: country) }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.purple)
            Text("Finding great shows…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(white: 0.6))
        }
    }

    private var failedView: some View {
        ContentUnavailableView(
            "Couldn't load starter packs",
            systemImage: "wifi.slash",
            description: Text("Check your connection, or tap Find shows to search instead.")
        )
    }

    private var packsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not sure where to start?")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Pick a few and we'll set you up instantly. You can change anything later.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(white: 0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)

                ForEach(viewModel.packs) { pack in
                    packCard(pack)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func packCard(_ pack: StarterPacksViewModel.Pack) -> some View {
        let isAdded = addedPackIDs.contains(pack.id)
        let isAdding = addingPackID == pack.id

        let content = VStack(alignment: .leading, spacing: 12) {
            Text(pack.genre.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                ForEach(pack.podcasts) { podcast in
                    CachedArtworkImage(url: podcast.artworkURL, targetSize: CGSize(width: 48, height: 48)) {
                        RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.14))
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }

            Button { addPack(pack) } label: {
                HStack(spacing: 7) {
                    if isAdding {
                        ProgressView().controlSize(.small).tint(.white)
                    } else if isAdded {
                        Image(systemName: "checkmark")
                    }
                    Text(isAdded ? "Added" : "Add these shows")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(isAdded ? Color.green.opacity(0.4) : Color.purple))
            }
            .buttonStyle(.plain)
            .disabled(isAdding || isAdded)
        }
        .padding(16)

        if #available(iOS 26, *) {
            content.glassCard(cornerRadius: 16)
        } else {
            content.background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        }
    }

    private func addPack(_ pack: StarterPacksViewModel.Pack) {
        addingPackID = pack.id
        Task {
            let urls = await viewModel.feedURLs(for: pack, country: country)
            _ = await appState.subscribeToFeedURLs(urls)
            addedPackIDs.insert(pack.id)
            addingPackID = nil
        }
    }
}
