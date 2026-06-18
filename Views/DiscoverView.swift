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
// preview (invisible 30-day browse subscription) and subscribed states — see
// PAGES.md "Browse Subscription Lifecycle"). Chart cards use CachedArtworkImage
// with an explicit square target size so the shared artwork cache decodes covers
// at card scale instead of retaining full-resolution storefront art in memory.
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
    @State private var resolvingPodcastID: String?
    @State private var showUnavailableAlert = false
    @State private var heroIndex = 0
    @State private var spotlightAIndex = 0
    @State private var spotlightBIndex = 0

    /// Auto-advance cadence for the hero cards.
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private enum Route: Hashable {
        case preview(PodcastSearchResult)
        case episodes(UUID)
    }

    /// Ordered Discover feed item: a genre rail or one of the two country
    /// spotlight heroes. Spotlight A sits before Health & Fitness; B at the end.
    private enum FeedSection: Identifiable {
        case rail(DiscoverViewModel.GenreRail)
        case spotlightA(DiscoverViewModel.CountrySpotlight)
        case spotlightB(DiscoverViewModel.CountrySpotlight)

        var id: String {
            switch self {
            case .rail(let r): return "rail-\(r.id)"
            case .spotlightA(let s): return "spotlightA-\(s.country.code)"
            case .spotlightB(let s): return "spotlightB-\(s.country.code)"
            }
        }
    }

    /// Builds the rail list with the spotlight heroes inserted. Spotlight A goes
    /// immediately before the Health & Fitness rail (so it lands between Sports
    /// and Health & Fitness); if that rail is absent it falls in after Sports,
    /// otherwise at the end of the rails. Spotlight B always closes the feed.
    private var feedSections: [FeedSection] {
        var result: [FeedSection] = []
        for rail in viewModel.rails {
            if rail.genre.id == 1512, let a = viewModel.spotlightA {   // Health & Fitness
                result.append(.spotlightA(a))
            }
            result.append(.rail(rail))
        }
        let hasSpotlightA = result.contains { if case .spotlightA = $0 { return true }; return false }
        if let a = viewModel.spotlightA, !hasSpotlightA {
            if let sportsIdx = result.firstIndex(where: {
                if case .rail(let r) = $0 { return r.genre.id == 1545 }; return false   // Sports
            }) {
                result.insert(.spotlightA(a), at: sportsIdx + 1)
            } else {
                result.append(.spotlightA(a))
            }
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
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
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
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
        .task(id: country.code) {
            await viewModel.load(country: country.code)
        }
        .sheet(isPresented: $showSearch) { PodcastSearchView() }
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
                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 16) {
                        searchShortcut
                            .padding(.horizontal, 20)
                            .padding(.top, 4)

                        if !viewModel.heroPodcasts.isEmpty {
                            heroSection
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
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search podcasts")
    }

    // MARK: - Hero (Top 8 paging cards)

    private var heroSection: some View {
        heroCarousel(title: "Top Podcasts · \(country.name)",
                     podcasts: viewModel.heroPodcasts,
                     index: $heroIndex,
                     resolveCountry: country.code)
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
    private func heroCarousel(title: String, podcasts: [ChartPodcast], index: Binding<Int>, resolveCountry: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
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
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color.purple.opacity(0.22), Color.white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        )
                        .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 1))
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
                            .background(Color.purple.opacity(0.82), in: Capsule())

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
                HStack(alignment: .top, spacing: 14) {
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
                        .background(Color.black.opacity(0.55), in: Capsule())
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
            // Same routing rule as search results: active subscriptions go to
            // their episode page, everything else to the browse preview.
            if let activeSub = appState.subscriptionStore.subscriptions.first(where: {
                $0.feedURL == result.feedURL && !$0.excludeFromAutoFeedRefresh
            }) {
                pendingRoute = .episodes(activeSub.id)
            } else {
                pendingRoute = .preview(result)
            }
        }
    }
}
