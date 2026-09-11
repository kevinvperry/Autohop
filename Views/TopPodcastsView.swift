import SwiftUI
import Combine

// CATEGORY CONTRACT (2026-09-06): Top 8 episode carousel precedes Top 100 shows.
// Reuse DiscoverEpisodeHeroCard and AdaptiveEditorialMetrics; show heroes start at
// rank 8 and repeat at 16 through 96. Overall chart cadence remains 1, 8, 15, etc.
// Episode loading/retry is independent of shows; country changes reset carousel state.

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
// starts categories with eight rotating episode heroes, followed by shows
// with feature cards at ranks 8, 16, … 96. Overall charts retain their cadence
// of ranks 1, 8, 15, … and the rest are compact ranked rows. Each
// entry shows ChartPodcast artwork, title, author (artist) and genre (genreName)
// — the podcast analogue of TopEpisodesView's title/show/release-date. Tapping
// resolves the show's RSS feed (viewModel.resolve) and pushes PodcastDetailView
// on the ambient stack via pendingRoute — same routing rule as Discover (real
// subscription, including Inactive, → episodes; else browse preview). NavRules:
// pushed page, brand back chevron top-left, MiniPlayerBar docked. RESPONSIVE:
// the outer ScrollView remains full width while its centred inner stack uses
// the shared AdaptiveEditorialMetrics vocabulary. Feature height, artwork sizes
// and gutters derive from the immediate container width; do not add device-
// family branches or independent breakpoints here.
struct TopPodcastsView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let country: ChartCountry
    let genre: ChartGenre?
    @AppStorage("discoverCountryCode") private var storedCountryCode = ""

    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRoute: DetailRoute?
    @State private var resolvingPodcastID: String?
    @State private var showUnavailableAlert = false

    @State private var categoryEpisodes: [ChartEpisode] = []
    @State private var episodeHeroIndex = 0
    @State private var episodesFailed = false
    @State private var episodesCountry: String?
    @State private var resolvingEpisodeID: String?
    @Environment(\.scenePhase) private var scenePhase
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
        .responsiveInlineNavigationTitle(pageTitle)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationBackButton()
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
            async let shows: Void = load()
            async let episodes: Void = loadCategoryEpisodes()
            _ = await (shows, episodes)
        }
        .refreshable {
            async let shows: Void = reload()
            async let episodes: Void = loadCategoryEpisodes()
            _ = await (shows, episodes)
        }
        .alert("Not Available", isPresented: $showUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This show doesn't have a public RSS feed, so it can't be played in Autohop.")
        }
    }

    // MARK: - List

    private var listContent: some View {
        GeometryReader { proxy in
            let metrics = AdaptiveEditorialMetrics(containerWidth: proxy.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                if genre != nil {
                    categoryEpisodeCarousel(metrics: metrics)
                    Text("Top 100 Shows")
                        .font(metrics.sectionTitleFont)
                        .padding(.horizontal, metrics.horizontalGutter)
                }

                Text(genre.map { "Apple Podcasts · \($0.name) · \(selectedCountry.name)" }
                    ?? "Apple Podcasts · \(selectedCountry.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.horizontalGutter)
                    .padding(.top, 4)

                ForEach(podcasts) { podcast in
                    if genre != nil ? podcast.rank % 8 == 0 : (podcast.rank - 1) % 7 == 0 {
                        featureCard(podcast, metrics: metrics)
                            .padding(.horizontal, metrics.horizontalGutter)
                            .padding(.top, podcast.rank == 1 ? 4 : 24)
                            .padding(.bottom, 14)
                    } else {
                        compactRow(podcast, metrics: metrics)
                            .padding(.horizontal, metrics.horizontalGutter)
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
                .frame(maxWidth: metrics.availableWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func categoryEpisodeCarousel(metrics: AdaptiveEditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            Text("Top 8 Episodes")
                .font(metrics.sectionTitleFont)
                .padding(.horizontal, metrics.horizontalGutter)
            if episodesCountry == selectedCountry.code, !categoryEpisodes.isEmpty {
                TabView(selection: $episodeHeroIndex) {
                    ForEach(Array(categoryEpisodes.enumerated()), id: \.element.id) { index, episode in
                        DiscoverEpisodeHeroCard(episode: episode, metrics: metrics,
                                                resolvingEpisodeID: resolvingEpisodeID,
                                                openEpisode: openEpisode)
                            .padding(.horizontal, metrics.horizontalGutter)
                            .padding(.bottom, metrics.carouselDotClearance)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .frame(height: metrics.heroCarouselHeight)
                .onReceive(heroTimer) { _ in
                    guard scenePhase == .active, pendingRoute == nil,
                          resolvingEpisodeID == nil, categoryEpisodes.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.45)) {
                        episodeHeroIndex = (episodeHeroIndex + 1) % categoryEpisodes.count
                    }
                }
            } else if episodesFailed {
                Button("Episodes unavailable — Retry") {
                    Task { await loadCategoryEpisodes() }
                }
                .padding(.horizontal, metrics.horizontalGutter)
            } else {
                ProgressView("Loading episodes…")
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.heroCarouselHeight)
            }
        }
    }

    private func loadCategoryEpisodes() async {
        guard let genre else { return }
        let country = selectedCountry.code
        episodesFailed = false
        categoryEpisodes = []
        episodeHeroIndex = 0
        do {
            let episodes = try await viewModel.categoryEpisodes(country: country, genre: genre)
            guard !Task.isCancelled, selectedCountry.code == country else { return }
            categoryEpisodes = episodes
            episodesCountry = country
        } catch {
            guard !Task.isCancelled, selectedCountry.code == country else { return }
            episodesFailed = true
        }
    }

    private func openEpisode(_ episode: ChartEpisode) {
        guard resolvingEpisodeID == nil else { return }
        resolvingEpisodeID = episode.id
        Task {
            defer { resolvingEpisodeID = nil }
            guard let result = await viewModel.resolveEpisodePodcast(episode, country: selectedCountry.code) else {
                showUnavailableAlert = true
                return
            }
            if let subscription = subscriptionStore.subscriptions.first(where: {
                $0.feedURL == result.feedURL && $0.browseDate == nil
            }) {
                pendingRoute = .episodes(subscription.id)
            } else {
                pendingRoute = .preview(result)
            }
        }
    }

    // MARK: - Feature card (one per tier of seven)

    private func featureCard(_ podcast: ChartPodcast, metrics: AdaptiveEditorialMetrics) -> some View {
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

                HStack(alignment: .center, spacing: metrics.featureContentSpacing) {
                    artwork(podcast.artworkURL, size: metrics.featureArtworkSize, cornerRadius: 18, placeholderIconSize: 34)

                    VStack(alignment: .leading, spacing: metrics.featureTextSpacing) {
                        rankCapsule(podcast.rank, font: metrics.featureRankFont)

                        Text(podcast.title)
                            .font(metrics.featureTitleFont)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(metrics.featureTitleLineLimit)

                        Text(podcast.artist)
                            .font(metrics.featureMetadataFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !podcast.genreName.isEmpty {
                            Text(podcast.genreName)
                                .font(metrics.featureDetailFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(metrics.featureContentPadding)

                if resolvingPodcastID == podcast.id {
                    resolvingOverlay
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.featureCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(resolvingPodcastID != nil)
    }

    // MARK: - Compact ranked row

    private func compactRow(_ podcast: ChartPodcast, metrics: AdaptiveEditorialMetrics) -> some View {
        Button {
            openPodcast(podcast)
        } label: {
            HStack(spacing: 14) {
                Text("\(podcast.rank)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)

                ZStack {
                    artwork(podcast.artworkURL, size: metrics.compactArtworkSize, cornerRadius: 13, placeholderIconSize: 24)
                    if resolvingPodcastID == podcast.id {
                        resolvingOverlay
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .frame(width: metrics.compactArtworkSize, height: metrics.compactArtworkSize)
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

    private func rankCapsule(_ rank: Int, font: Font = .caption.bold()) -> some View {
        Text("#\(rank)")
            .font(font)
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
