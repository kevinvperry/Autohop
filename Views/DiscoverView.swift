import SwiftUI

// AI CONTEXT — Views/DiscoverView.swift ("Discover" sheet — opened by the +
// button on the Subscriptions toolbar AND the top Menu item; parent page of
// Podcast Search, which is now reachable only through the search shortcut
// here). Browse-and-explore page for finding
// new podcasts: a Top-8 hero of big sideways-paging chart cards, horizontal
// per-genre rails (PodcastChartsService / DiscoverViewModel), plus two
// secondary "Top Podcasts · <Country>" spotlight heroes woven into the rail
// list — spotlight A before Health & Fitness, spotlight B at the end — each a
// fixed Top-8 storefront (US/UK/AU, resolved by DiscoverViewModel
// .spotlightCountries so they never duplicate the user's selected country or
// each other). A storefront
// country picker (defaults to Locale.current.region, falls back to US,
// persisted in @AppStorage), and a search-field-shaped shortcut that presents
// the unchanged PodcastSearchView sheet. Tapping any chart entry resolves the
// RSS feed URL via the iTunes Lookup API, then routes exactly like search
// results: every entry routes to PodcastDetailView, which renders both the
// preview (invisible 30-day browse subscription) and subscribed states. Inactive
// podcasts are still real subscriptions and route to their owned detail page,
// not the preview — see PAGES.md "Browse Subscription Lifecycle". Chart cards use CachedArtworkImage
// with an explicit square target size so the shared artwork cache decodes covers
// at card scale instead of retaining full-resolution storefront art in memory.
// FIRST-RUN: while the user has no real subscriptions (appState.realSubscriptionCount
// == 0) a starterPacksBanner sits above the rails and presents StarterPacksView.
// TOP EPISODES: the Top Episodes hero header has a "See All" button that pushes
// TopEpisodesView (the Top-50 child page) via AppRoute-style pendingRoute.
// TOP PODCASTS: the FIRST "Top Podcasts · <selected country>" hero (the mid-feed
// podcastHero — NOT the fixed-country spotlight heroes) likewise has a "See All"
// → TopPodcastsView (Top-50 child page). heroCarousel takes an optional
// seeAllRoute; only the podcastHero passes one, so spotlights stay link-free.
// PERF: the feed is a LazyVStack and each genre rail a LazyHStack, so the ~10
// image-heavy rails + hero carousels build only as they scroll into view
// (was a plain VStack/HStack, which laid everything out eagerly and stuttered).
struct DiscoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = DiscoverViewModel()
    @AppStorage("discoverCountryCode") private var storedCountryCode = ""
    /// Drives the push to Podcast Detail on the ambient stack. Set after the
    /// async feed resolve completes (Discover is a pushed page, not a sheet, so
    /// it no longer owns a NavigationStack/path of its own).
    @State private var pendingRoute: Route?
    @State private var showSearch = false
    @State private var showStarterPacks = false
    @State private var resolvingPodcastID: String?
    @State private var showUnavailableAlert = false
    @State private var episodeHeroIndex = 0   // top hero — Top Episodes
    @State private var podcastHeroIndex = 0   // mid-feed hero — Top Podcasts
    @State private var spotlightAIndex = 0
    @State private var spotlightBIndex = 0
    @State private var resolvingEpisodeID: String?

    /// Auto-advance cadence for the hero cards.
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private enum Route: Hashable {
        case preview(PodcastSearchResult)
        case episodes(UUID)
        case topEpisodes
        case topPodcasts
    }

    /// Ordered Discover feed item: a genre rail or one of the two country
    /// spotlight heroes. Spotlight A sits before Health & Fitness; B at the end.
    private enum FeedSection: Identifiable {
        case rail(DiscoverViewModel.GenreRail)
        case podcastHero                              // Top Podcasts — appears after rail 3
        case spotlightA(DiscoverViewModel.CountrySpotlight)   // after rail 6
        case spotlightB(DiscoverViewModel.CountrySpotlight)   // end of feed

        var id: String {
            switch self {
            case .rail(let r):      return "rail-\(r.id)"
            case .podcastHero:      return "podcastHero"
            case .spotlightA(let s): return "spotlightA-\(s.country.code)"
            case .spotlightB(let s): return "spotlightB-\(s.country.code)"
            }
        }
    }

    /// Builds the rail feed with three heroes woven in at fixed positions:
    /// podcast hero after rail 3, spotlight A after rail 6, spotlight B at end.
    private var feedSections: [FeedSection] {
        var result: [FeedSection] = []
        var railCount = 0
        var addedSpotlightA = false

        for rail in viewModel.rails {
            result.append(.rail(rail))
            railCount += 1

            if railCount == 3, !viewModel.heroPodcasts.isEmpty {
                result.append(.podcastHero)
            }
            if railCount == 6, let a = viewModel.spotlightA {
                result.append(.spotlightA(a))
                addedSpotlightA = true
            }
        }

        // Fallbacks when fewer rails loaded than the insertion thresholds.
        if railCount < 3, !viewModel.heroPodcasts.isEmpty {
            result.append(.podcastHero)
        }
        if !addedSpotlightA, let a = viewModel.spotlightA {
            result.append(.spotlightA(a))
        }
        if let b = viewModel.spotlightB {
            result.append(.spotlightB(b))
        }
        return result
    }

    private var country: ChartCountry {
        storedCountryCode.isEmpty ? .deviceDefault : .named(storedCountryCode)
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                ProgressView("Loading charts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Charts Unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.reload(country: country.code) }
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                chartsContent
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                countryMenu
            }
        }
        .navigationDestination(item: $pendingRoute) { route in
            switch route {
            case .preview(let result):
                PodcastDetailView(result: result)
            case .episodes(let subscriptionID):
                PodcastDetailView(subscriptionID: subscriptionID)
            case .topEpisodes:
                TopEpisodesView(viewModel: viewModel, country: country)
            case .topPodcasts:
                TopPodcastsView(viewModel: viewModel, country: country)
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
        .task(id: country.code) {
            await viewModel.load(country: country.code)
        }
        .sheet(isPresented: $showSearch) { PodcastSearchView() }
        .sheet(isPresented: $showStarterPacks) { StarterPacksView() }
        .alert("Not Available", isPresented: $showUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This show doesn't have a public RSS feed, so it can't be played in Autohop.")
        }
    }

    // MARK: - Page body

    private var chartsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack so the ~10 image-heavy genre rails + hero carousels
                // build only as they scroll into view (was a plain VStack, which
                // laid them all out eagerly and stuttered the vertical scroll).
                LazyVStack(alignment: .leading, spacing: 48) {
                    VStack(alignment: .leading, spacing: 16) {
                        searchShortcut
                            .padding(.horizontal, 20)
                            .padding(.top, 4)

                        if appState.realSubscriptionCount == 0 {
                            starterPacksBanner
                                .padding(.horizontal, 20)
                        }

                        if !viewModel.topEpisodes.isEmpty {
                            episodeHeroSection
                        }

                        if !viewModel.rails.isEmpty {
                            categoryChips(proxy: proxy)
                        }
                    }

                    ForEach(feedSections) { section in
                        switch section {
                        case .rail(let rail):
                            genreRail(rail)
                                .id("rail-\(rail.id)")
                        case .podcastHero:
                            heroCarousel(title: "Top Podcasts · \(country.name)",
                                         podcasts: viewModel.heroPodcasts,
                                         index: $podcastHeroIndex,
                                         resolveCountry: country.code,
                                         seeAllRoute: .topPodcasts)
                        case .spotlightA(let spotlight):
                            spotlightHero(spotlight, index: $spotlightAIndex)
                        case .spotlightB(let spotlight):
                            spotlightHero(spotlight, index: $spotlightBIndex)
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 8)
            }
            .refreshable {
                await viewModel.reload(country: country.code)
            }
        }
    }

    // MARK: - Country picker

    private var countryMenu: some View {
        Menu {
            ForEach(ChartCountry.featured) { c in
                countryButton(c)
            }
            Divider()
            ForEach(ChartCountry.all) { c in
                countryButton(c)
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(country.flag) \(country.name)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Charts country: \(country.name)")
    }

    private func countryButton(_ c: ChartCountry) -> some View {
        Button {
            storedCountryCode = c.code
        } label: {
            if c.code == country.code {
                Label("\(c.flag) \(c.name)", systemImage: "checkmark")
            } else {
                Text("\(c.flag) \(c.name)")
            }
        }
    }

    // MARK: - Search shortcut

    /// First-run nudge (shown only while the user has no real subscriptions):
    /// a one-tap route into chart-derived starter packs. ONBOARDING_PLAN.md Phase 6/7.
    private var starterPacksBanner: some View {
        Button { showStarterPacks = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.purple))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New here? Try a starter pack")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Subscribe to a curated set in one tap.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.62))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.purple.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.purple.opacity(0.3), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var searchShortcut: some View {
        Button {
            showSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Search podcasts…")
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search podcasts")
    }

    // MARK: - Episode hero (top slot — Top 8 Episodes)

    private var episodeHeroSection: some View {
        episodeHeroCarousel(title: "Top Episodes · \(country.name)",
                            episodes: viewModel.topEpisodes,
                            index: $episodeHeroIndex)
    }

    private func episodeHeroCarousel(title: String, episodes: [ChartEpisode], index: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    pendingRoute = .topEpisodes
                } label: {
                    HStack(spacing: 2) {
                        Text("See All")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            TabView(selection: index) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { idx, episode in
                    heroEpisodeCard(episode)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .frame(height: 320)
            .onReceive(heroTimer) { _ in
                let count = episodes.count
                guard count > 1, resolvingEpisodeID == nil else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    index.wrappedValue = (index.wrappedValue + 1) % count
                }
            }
        }
    }

    private func heroEpisodeCard(_ episode: ChartEpisode) -> some View {
        Button {
            openEpisode(episode)
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.08, blue: 0.42).opacity(0.95),
                             Color.black.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                // Ghosted rank numeral — matches the podcast hero treatment.
                Text("\(episode.rank)")
                    .font(.system(size: 230, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.07))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 18, y: -34)
                    .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 14) {
                    chartArtwork(episode.artworkURL, size: 148, cornerRadius: 18,
                                 placeholderIconSize: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(episode.rank)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .glassCapsule(highlighted: true)

                        Text(episode.title)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)

                        Text(episode.showName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let date = episode.releaseDate {
                            Text(relativePublishedLabel(date))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)

                if resolvingEpisodeID == episode.id {
                    resolvingOverlay
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 284)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(resolvingEpisodeID != nil)
    }

    private func openEpisode(_ episode: ChartEpisode) {
        guard resolvingEpisodeID == nil else { return }
        guard episode.collectionId != nil else {
            showUnavailableAlert = true
            return
        }
        resolvingEpisodeID = episode.id
        Task {
            defer { resolvingEpisodeID = nil }
            guard let result = await viewModel.resolveEpisodePodcast(episode, country: country.code) else {
                showUnavailableAlert = true
                return
            }
            if let activeSub = appState.subscriptionStore.subscriptions.first(where: {
                $0.feedURL == result.feedURL && $0.browseDate == nil
            }) {
                pendingRoute = .episodes(activeSub.id)
            } else {
                pendingRoute = .preview(result)
            }
        }
    }

    /// A secondary country spotlight hero (Top 8 for a fixed storefront),
    /// mirroring the top hero's design.
    private func spotlightHero(_ spotlight: DiscoverViewModel.CountrySpotlight, index: Binding<Int>) -> some View {
        heroCarousel(title: "Top Podcasts · \(spotlight.country.name)",
                     podcasts: spotlight.podcasts,
                     index: index,
                     resolveCountry: spotlight.country.code)
    }

    /// Shared paging hero carousel used by both the top hero and the country
    /// spotlights. Each instance keeps its own selection index and auto-advances
    /// on the shared cadence (paused while a tap is resolving a feed).
    private func heroCarousel(title: String, podcasts: [ChartPodcast], index: Binding<Int>, resolveCountry: String, seeAllRoute: Route? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.bold))
                // "See All" only on the first Top Podcasts hero (podcastHero) — the
                // fixed-country spotlight heroes call this without a route, so they
                // render the title alone, exactly as before.
                if let seeAllRoute {
                    Spacer()
                    Button {
                        pendingRoute = seeAllRoute
                    } label: {
                        HStack(spacing: 2) {
                            Text("See All")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            TabView(selection: index) {
                ForEach(Array(podcasts.enumerated()), id: \.element.id) { idx, podcast in
                    heroCard(podcast, resolveCountry: resolveCountry)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)   // clear the page dots
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .frame(height: 320)
            .onReceive(heroTimer) { _ in
                let count = podcasts.count
                guard count > 1, resolvingPodcastID == nil else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    index.wrappedValue = (index.wrappedValue + 1) % count
                }
            }
        }
    }

    // MARK: - Category shortcut chips

    private static let genreSymbols: [Int: String] = [
        1303: "face.smiling",            // Comedy
        1489: "newspaper",               // News
        1488: "magnifyingglass",         // True Crime
        1324: "person.2",                // Society & Culture
        1321: "chart.line.uptrend.xyaxis", // Business
        1545: "figure.run",              // Sports
        1512: "heart",                   // Health & Fitness
        1318: "cpu",                     // Technology
        1533: "atom",                    // Science
        1309: "tv",                      // TV & Film
    ]

    private func categoryChips(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.rails) { rail in
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo("rail-\(rail.id)", anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.genreSymbols[rail.genre.id] ?? "waveform")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.purple)
                            Text(rail.genre.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassCapsule(highlighted: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func heroCard(_ podcast: ChartPodcast, resolveCountry: String) -> some View {
        Button {
            open(podcast, country: resolveCountry)
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color.purple.opacity(0.45), Color.black.opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                // Oversized ghosted rank numeral behind the artwork.
                Text("\(podcast.rank)")
                    .font(.system(size: 230, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.07))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 18, y: -34)
                    .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 14) {
                    chartArtwork(podcast.artworkURL, size: 148, cornerRadius: 18, placeholderIconSize: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(podcast.rank)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .glassCapsule(highlighted: true)

                        Text(podcast.title)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)

                        if !podcast.artist.isEmpty {
                            Text(podcast.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !podcast.genreName.isEmpty {
                            Text(podcast.genreName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)

                if resolvingPodcastID == podcast.id {
                    resolvingOverlay
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 284)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Genre rails

    private func genreRail(_ rail: DiscoverViewModel.GenreRail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rail.genre.name)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(rail.podcasts) { podcast in
                        railTile(podcast)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func railTile(_ podcast: ChartPodcast) -> some View {
        Button {
            open(podcast, country: country.code)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    chartArtwork(podcast.artworkURL, size: 124, cornerRadius: 14, placeholderIconSize: 26)

                    Text("\(podcast.rank)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .glassCapsule()
                        .padding(6)

                    if resolvingPodcastID == podcast.id {
                        resolvingOverlay
                            .frame(width: 124, height: 124)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }

                Text(podcast.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text(podcast.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 124)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared pieces

    private func chartArtwork(_ url: URL?, size: CGFloat, cornerRadius: CGFloat, placeholderIconSize: CGFloat) -> some View {
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

    // MARK: - Open a chart entry

    private func open(_ podcast: ChartPodcast, country: String) {
        guard resolvingPodcastID == nil else { return }
        resolvingPodcastID = podcast.id
        Task {
            defer { resolvingPodcastID = nil }
            guard let result = await viewModel.resolve(podcast, country: country) else {
                showUnavailableAlert = true
                return
            }
            // Same routing rule as search results: real subscriptions go to
            // their episode page, everything else to the browse preview.
            if let activeSub = appState.subscriptionStore.subscriptions.first(where: {
                $0.feedURL == result.feedURL && $0.browseDate == nil
            }) {
                pendingRoute = .episodes(activeSub.id)
            } else {
                pendingRoute = .preview(result)
            }
        }
    }
}
