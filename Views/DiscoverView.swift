import SwiftUI

// AI CONTEXT — Views/DiscoverView.swift ("Discover" sheet — opened by the +
// button on the Subscriptions toolbar AND the top Menu item; parent page of
// Podcast Search, which is now reachable only through the search shortcut
// here). Browse-and-explore page for finding
// new podcasts: a Top-8 hero of big sideways-paging chart cards, horizontal
// per-genre rails (PodcastChartsService / DiscoverViewModel), a storefront
// country picker (defaults to Locale.current.region, falls back to US,
// persisted in @AppStorage), and a search-field-shaped shortcut that presents
// the unchanged PodcastSearchView sheet. Tapping any chart entry resolves the
// RSS feed URL via the iTunes Lookup API, then routes exactly like search
// results: active subscriptions go to SubscriptionEpisodesView, everything
// else to PodcastPreviewView (invisible 30-day browse subscription — see
// PAGES.md "Browse Subscription Lifecycle").
struct DiscoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = DiscoverViewModel()
    @AppStorage("discoverCountryCode") private var storedCountryCode = ""
    @State private var path = NavigationPath()
    @State private var showSearch = false
    @State private var resolvingPodcastID: String?
    @State private var showUnavailableAlert = false
    @State private var heroIndex = 0

    /// Auto-advance cadence for the hero cards.
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private enum Route: Hashable {
        case preview(PodcastSearchResult)
        case episodes(UUID)
    }

    private var country: ChartCountry {
        storedCountryCode.isEmpty ? .deviceDefault : .named(storedCountryCode)
    }

    var body: some View {
        NavigationStack(path: $path) {
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    countryMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .preview(let result):
                    PodcastPreviewView(result: result)
                case .episodes(let subscriptionID):
                    SubscriptionEpisodesView(subscriptionID: subscriptionID)
                }
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .autohopReturnToPlayer)) { _ in
            dismiss()
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

                    ForEach(viewModel.rails) { rail in
                        genreRail(rail)
                            .id("rail-\(rail.id)")
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Podcasts · \(country.name)")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)

            TabView(selection: $heroIndex) {
                ForEach(Array(viewModel.heroPodcasts.enumerated()), id: \.element.id) { index, podcast in
                    heroCard(podcast)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)   // clear the page dots
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .frame(height: 320)
            .onReceive(heroTimer) { _ in
                let count = viewModel.heroPodcasts.count
                guard count > 1, resolvingPodcastID == nil else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    heroIndex = (heroIndex + 1) % count
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

    private func heroCard(_ podcast: ChartPodcast) -> some View {
        Button {
            open(podcast)
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
            open(podcast)
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
        CachedArtworkImage(url: url) {
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

    private func open(_ podcast: ChartPodcast) {
        guard resolvingPodcastID == nil else { return }
        resolvingPodcastID = podcast.id
        Task {
            defer { resolvingPodcastID = nil }
            guard let result = await viewModel.resolve(podcast, country: country.code) else {
                showUnavailableAlert = true
                return
            }
            // Same routing rule as search results: active subscriptions go to
            // their episode page, everything else to the browse preview.
            if let activeSub = appState.subscriptionStore.subscriptions.first(where: {
                $0.feedURL == result.feedURL && !$0.excludeFromAutoFeedRefresh
            }) {
                path.append(Route.episodes(activeSub.id))
            } else {
                path.append(Route.preview(result))
            }
        }
    }
}
