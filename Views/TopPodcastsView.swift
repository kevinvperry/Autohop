import SwiftUI

// AI CONTEXT — Views/TopPodcastsView.swift ("Top Podcasts" page — child of
// Discover, reached via the "See All" button on the FIRST "Top Podcasts ·
// <selected country>" hero header, i.e. the mid-feed podcastHero, NOT the
// fixed-country spotlight heroes), OR by tapping any category chip. An expanded,
// editorial chart list of Apple Podcasts shows for the selected Discover
// country, optionally filtered to one ChartGenre. The shared toolbar country
// picker writes Discover's AppStorage selection and reloads this visible chart.
// DEPTH IS ASYMMETRIC BY DESIGN: a CATEGORY page is Top 100 (legacy genre
// endpoint, verified to serve 100/200), while the OVERALL page stays Top 50
// because Marketing Tools v2 hard-caps that feed at 50. Titles reflect this —
// "Top 100 - <Category>" vs plain "Top Podcasts". Do not unify the two without
// first moving the overall chart off Marketing Tools.
// Overall and category data use
// separate lazy DiscoverViewModel slots; genre charts inherit the 12-hour
// country/genre cache, and a larger cached chart is an ordered superset that can
// satisfy the 15-entry rails. A category
// page renders the parent Discover rail's Top 15 immediately when available,
// then replaces/extends it with the canonical Top 100 result. LAYOUT
// mirrors TopEpisodesView — a large feature card every 7th entry
// ((rank - 1) % 7 == 0; depth-independent, so at 100 it runs 1, 8 … 92, 99)
// and the rest compact ranked rows. Each
// entry shows ChartPodcast artwork, title, author (artist) and genre (genreName)
// — the podcast analogue of TopEpisodesView's title/show/release-date. Tapping
// resolves the show's RSS feed (viewModel.resolve) and pushes PodcastDetailView
// on the ambient stack via pendingRoute — same routing rule as Discover (real
// subscription, including Inactive, → episodes; else browse preview). NavRules:
// pushed page, brand back chevron top-left, MiniPlayerBar docked. The inner
// editorial stack is centred and width-capped on expansive viewports while the
// outer ScrollView retains full-width scrolling chrome and background.
struct TopPodcastsView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let country: ChartCountry
    let genre: ChartGenre?
    @AppStorage("discoverCountryCode") private var storedCountryCode = ""

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRoute: DetailRoute?
    @State private var resolvingPodcastID: String?
    @State private var showUnavailableAlert = false

    private enum DetailRoute: Hashable {
        case preview(PodcastSearchResult)
        case episodes(UUID)
    }

    init(viewModel: DiscoverViewModel, country: ChartCountry, genre: ChartGenre? = nil) {
        self.viewModel = viewModel
        self.country = country
        self.genre = genre
    }

    private var phase: DiscoverViewModel.Phase {
        if genre != nil, !podcasts.isEmpty { return .loaded }
        return genre == nil ? viewModel.top50PodcastsPhase : viewModel.top50CategoryPhase
    }

    private var podcasts: [ChartPodcast] {
        guard let genre else { return viewModel.top50Podcasts }
        let fullChart = viewModel.loadedCategoryTop50(genre: genre, country: selectedCountry.code)
        if !fullChart.isEmpty {
            return fullChart
        }
        return viewModel.categoryPreview(genre: genre, country: selectedCountry.code)
    }

    private var isLoadingBeyondPreview: Bool {
        guard let genre, !podcasts.isEmpty,
              viewModel.loadedCategoryTop50(genre: genre, country: selectedCountry.code).isEmpty
        else { return false }
        if case .loading = viewModel.top50CategoryPhase { return true }
        return false
    }

    /// Uses the storefront-localised genre name so this page's title matches the
    /// Discover rail the user tapped ("Sport" in the AU store, "Sports" in the
    /// US store); falls back to the English name until the cached name map
    /// arrives. See ChartGenre.localizedName(from:).
    /// Category pages are Top 100; the overall chart stays "Top Podcasts"
    /// (Marketing Tools caps that feed at 50 — see
    /// `DiscoverViewModel.categoryChartLimit`).
    private var pageTitle: String {
        genre.map { "Top 100 - \($0.localizedName(from: viewModel.genreNames))" }
            ?? "Top Podcasts"
    }

    private var selectedCountry: ChartCountry {
        storedCountryCode.isEmpty ? country : .named(storedCountryCode)
    }

    private var taskID: String {
        "\(selectedCountry.code)-\(genre?.id ?? 0)"
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading podcasts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Podcasts Unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await reload() }
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                listContent
            }
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ChartCountryPicker(selectionCode: $storedCountryCode, fallback: country)
            }
        }
        .navigationDestination(item: $pendingRoute) { route in
            switch route {
            case .preview(let result):
                PodcastDetailView(result: result)
            case .episodes(let subscriptionID):
                PodcastDetailView(subscriptionID: subscriptionID)
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
        .task(id: taskID) {
            await load()
        }
        .refreshable {
            await reload()
        }
        .alert("Not Available", isPresented: $showUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This show doesn't have a public RSS feed, so it can't be played in Autohop.")
        }
    }

    // MARK: - List

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(genre.map { "Apple Podcasts · \($0.name) · \(selectedCountry.name)" }
                    ?? "Apple Podcasts · \(selectedCountry.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                ForEach(podcasts) { podcast in
                    // Large feature card every 7th entry. The formula is
                    // depth-independent and continues unchanged now that
                    // category pages run to 100: ranks 1, 8, 15, 22, 29, 36,
                    // 43, 50, 57, 64, 71, 78, 85, 92, 99.
                    if (podcast.rank - 1) % 7 == 0 {
                        featureCard(podcast)
                            .padding(.horizontal, 20)
                            .padding(.top, podcast.rank == 1 ? 4 : 24)
                            .padding(.bottom, 14)
                    } else {
                        compactRow(podcast)
                            .padding(.horizontal, 20)
                    }
                }

                if isLoadingBeyondPreview {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading the full Top 100…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }

                Spacer(minLength: 24)
            }
            .padding(.top, 8)
            .adaptiveContentWidth(.editorial)
        }
    }

    // MARK: - Feature card (one per tier of seven)

    private func featureCard(_ podcast: ChartPodcast) -> some View {
        Button {
            openPodcast(podcast)
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.08, blue: 0.42).opacity(0.95),
                             Color.black.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                Text("\(podcast.rank)")
                    .font(.system(size: 220, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.07))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 18, y: -22)
                    .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 16) {
                    artwork(podcast.artworkURL, size: 140, cornerRadius: 18, placeholderIconSize: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        rankCapsule(podcast.rank)

                        Text(podcast.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)

                        Text(podcast.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !podcast.genreName.isEmpty {
                            Text(podcast.genreName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)

                if resolvingPodcastID == podcast.id {
                    resolvingOverlay
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.65, contentMode: .fit)
            .frame(minHeight: 200, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(resolvingPodcastID != nil)
    }

    // MARK: - Compact ranked row

    private func compactRow(_ podcast: ChartPodcast) -> some View {
        Button {
            openPodcast(podcast)
        } label: {
            HStack(spacing: 14) {
                Text("\(podcast.rank)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)

                ZStack {
                    artwork(podcast.artworkURL, size: 84, cornerRadius: 13, placeholderIconSize: 24)
                    if resolvingPodcastID == podcast.id {
                        resolvingOverlay
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .frame(width: 84, height: 84)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(podcast.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(podcast.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !podcast.genreName.isEmpty {
                        Text(podcast.genreName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolvingPodcastID != nil)
    }

    // MARK: - Pieces

    private func rankCapsule(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }

    private func artwork(_ url: URL?, size: CGFloat, cornerRadius: CGFloat, placeholderIconSize: CGFloat) -> some View {
        CachedArtworkImage(url: url, targetSize: CGSize(width: size, height: size)) {
            ZStack {
                LinearGradient(
                    colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "waveform")
                    .font(.system(size: placeholderIconSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
            ProgressView().tint(.white)
        }
    }

    // MARK: - Open a podcast

    private func load() async {
        if let genre {
            await viewModel.loadTop50Category(country: selectedCountry.code, genre: genre)
        } else {
            await viewModel.loadTop50Podcasts(country: selectedCountry.code)
        }
    }

    private func reload() async {
        if let genre {
            await viewModel.reloadTop50Category(country: selectedCountry.code, genre: genre)
        } else {
            await viewModel.reloadTop50Podcasts(country: selectedCountry.code)
        }
    }

    private func openPodcast(_ podcast: ChartPodcast) {
        guard resolvingPodcastID == nil else { return }
        resolvingPodcastID = podcast.id
        Task {
            defer { resolvingPodcastID = nil }
            guard let result = await viewModel.resolve(podcast, country: selectedCountry.code) else {
                showUnavailableAlert = true
                return
            }
            // Same routing rule as Discover: real subscriptions open their
            // episode page, everything else the browse preview.
            if let activeSub = subscriptionStore.subscriptions.first(where: {
                $0.feedURL == result.feedURL && $0.browseDate == nil
            }) {
                pendingRoute = .episodes(activeSub.id)
            } else {
                pendingRoute = .preview(result)
            }
        }
    }
}
