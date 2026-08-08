import SwiftUI
import Observation
import AutohopCore

// AI CONTEXT — TV/Views/TVDiscoverView.swift
// Browse-only tvOS Discover navigation. Apple chart identities are resolved to
// publisher RSS before an episode becomes playable. No route can subscribe,
// reprioritise, archive, or mutate Up Next. One owned NavigationStack and
// generation-scoped loaders prevent stale detail tasks updating a popped view.

struct TVDiscoverView: View {
    let onPlay: (Episode, Subscription) -> Void
    @State private var discoverModel = TVDiscoverModel()
    @State private var path: [TVDiscoverRoute] = []
    private let repository = TVDiscoverRepository()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch discoverModel.phase {
                case .idle, .loading:
                    ProgressView("Loading Discover…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    unavailable(message) { discoverModel.reload() }
                case .loaded:
                    landing
                }
            }
            .navigationDestination(for: TVDiscoverRoute.self, destination: destination)
        }
        .task { discoverModel.loadIfNeeded() }
        .onChange(of: path) { oldValue, newValue in
            AppLogger.shared.info("tv.discover.navigation", "Discover route changed", metadata: [
                "fromDepth": "\(oldValue.count)", "toDepth": "\(newValue.count)",
                "action": newValue.count < oldValue.count ? "back" : "forward"
            ], alwaysPersist: true)
        }
    }

    private var landing: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 72) {
                HStack(spacing: 24) {
                    NavigationLink(value: TVDiscoverRoute.search) {
                        Label("Search Shows", systemImage: "magnifyingglass")
                            .font(.title3.bold()).frame(minWidth: 330, alignment: .leading)
                    }.buttonStyle(.borderedProminent)
                    Spacer()
                    Menu {
                        ForEach(discoverModel.storefronts) { storefront in
                            Button("\(storefront.flag) \(storefront.name)") { discoverModel.selectStorefront(storefront) }
                        }
                    } label: {
                        Label("\(discoverModel.selectedStorefront.flag) \(discoverModel.selectedStorefront.name)", systemImage: "globe")
                    }
                }.padding(.horizontal, 72)

                episodeShelf("Top Episodes", discoverModel.landing.topEpisodes)
                if !discoverModel.landing.newAndNotable.isEmpty { showShelf("New & Notable", discoverModel.landing.newAndNotable) }
                showShelf("Top Podcasts in \(discoverModel.selectedStorefront.name)", discoverModel.landing.topShows)
                categoryChips
                ForEach(discoverModel.landing.categoryShelves) { showShelf($0.category.name, $0.shows) }
            }.padding(.vertical, 42)
        }.refreshable { discoverModel.reload() }
    }

    private func episodeShelf(_ title: String, _ episodes: [PodcastChartEpisode]) -> some View {
        shelf(title) {
            ForEach(episodes) { episode in
                NavigationLink(value: TVDiscoverRoute.episode(episode)) {
                    TVDiscoverFeaturedEpisodeCard(
                        episode: episode,
                        countryCode: discoverModel.selectedStorefront.code,
                        repository: repository
                    )
                }
                    .buttonStyle(.card).tvFocusHighlight()
            }
        }
    }

    private func showShelf(_ title: String, _ shows: [PodcastChartShow]) -> some View {
        shelf(title) {
            ForEach(shows) { show in
                NavigationLink(value: TVDiscoverRoute.show(show)) {
                    TVDiscoverShowCard(
                        show: show,
                        countryCode: discoverModel.selectedStorefront.code,
                        repository: repository
                    )
                }
                    .buttonStyle(.card).tvFocusHighlight()
            }
        }
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold()).padding(.horizontal, 72)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 28) { content() }
                    .padding(.horizontal, 72).padding(.vertical, 14)
            }
        }
        .padding(.vertical, 8)
    }

    private var categoryChips: some View {
        shelf("Browse Categories") {
            ForEach(discoverModel.landing.categories) { category in
                NavigationLink(value: TVDiscoverRoute.category(category)) {
                    Text(category.name).font(.headline).padding(.horizontal, 24).frame(height: 68)
                }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private func destination(_ route: TVDiscoverRoute) -> some View {
        switch route {
        case .search:
            TVSearchView(countryCode: discoverModel.selectedStorefront.code) { path.append(.searchShow($0)) }
        case .show(let show):
            TVDiscoverShowDetail(
                source: .chart(show), countryCode: discoverModel.selectedStorefront.code,
                repository: repository, onPlay: onPlay
            )
        case .searchShow(let show):
            TVDiscoverShowDetail(
                source: .search(show), countryCode: discoverModel.selectedStorefront.code,
                repository: repository, onPlay: onPlay
            )
        case .episode(let episode):
            TVDiscoverChartEpisodeDetail(
                chartEpisode: episode, countryCode: discoverModel.selectedStorefront.code,
                repository: repository, onPlay: onPlay
            )
        case .category(let category):
            TVDiscoverCategoryView(
                category: category, countryCode: discoverModel.selectedStorefront.code,
                initialShows: discoverModel.landing.categoryShelves.first(where: { $0.category.id == category.id })?.shows ?? [],
                repository: repository, onPlay: onPlay
            )
        }
    }

    private func unavailable(_ message: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView("Discover Unavailable", systemImage: "wifi.exclamationmark", description: Text(message))
            .overlay(alignment: .bottom) { Button("Try Again", systemImage: "arrow.clockwise", action: retry).padding(.bottom, 80) }
    }
}

private enum TVDiscoverShowSource { case chart(PodcastChartShow), search(PodcastSearchResult) }

@MainActor @Observable private final class TVDiscoverDetailModel {
    enum Phase { case loading, show(TVDiscoverResolvedShow), episode(TVDiscoverResolvedShow, Episode), failed(String) }
    var phase: Phase = .loading
    private var task: Task<Void, Never>?
    func loadShow(source: TVDiscoverShowSource, country: String, repository: TVDiscoverRepository) {
        task?.cancel(); phase = .loading
        task = Task {
            do {
                let value: TVDiscoverResolvedShow
                switch source {
                case .chart(let show): value = try await repository.show(countryCode: country, id: show.id)
                case .search(let show): value = try await repository.show(catalogue: show)
                }
                guard !Task.isCancelled else { return }; phase = .show(value)
                AppLogger.shared.info("tv.discover.showResolved", "Discover show feed resolved", metadata: ["episodes": "\(value.episodes.count)", "title": value.subscription.title], alwaysPersist: true)
            } catch { fail(error) }
        }
    }
    func loadEpisode(_ episode: PodcastChartEpisode, country: String, repository: TVDiscoverRepository) {
        task?.cancel(); phase = .loading
        task = Task {
            do {
                let (show, value) = try await repository.episode(countryCode: country, chartEpisode: episode)
                guard !Task.isCancelled else { return }; phase = .episode(show, value)
                AppLogger.shared.info("tv.discover.episodeResolved", "Discover episode resolved", metadata: ["episodeID": value.id.uuidString, "title": value.title], alwaysPersist: true)
            } catch { fail(error) }
        }
    }
    private func fail(_ error: Error) {
        guard !Task.isCancelled else { return }
        phase = .failed("This publisher feed could not provide playable episode details.")
        AppLogger.shared.warning("tv.discover.resolutionFailed", "Discover RSS resolution failed", metadata: ["error": String(describing: type(of: error))], alwaysPersist: true)
    }
}

private struct TVDiscoverShowDetail: View {
    let source: TVDiscoverShowSource; let countryCode: String; let repository: TVDiscoverRepository
    let onPlay: (Episode, Subscription) -> Void
    @State private var model = TVDiscoverDetailModel()
    var body: some View {
        Group {
            switch model.phase {
            case .loading: ProgressView("Loading episodes…")
            case .failed(let message): ContentUnavailableView("Episodes Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
            case .show(let show): showBody(show)
            case .episode(let show, _): showBody(show)
            }
        }.task { model.loadShow(source: source, country: countryCode, repository: repository) }
    }
    private func showBody(_ show: TVDiscoverResolvedShow) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 36) {
                    TVArtworkImage(url: show.subscription.artworkURL, targetPixels: 560).frame(width: 280, height: 280)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(show.subscription.title).font(.largeTitle.bold())
                        Text(show.subscription.author ?? show.catalogue.author).font(.title2).foregroundStyle(.secondary)
                        let description = TVEpisodeDescriptionText.plainText(from: show.subscription.description)
                        if !description.isEmpty {
                            Text(description).font(.callout).lineLimit(4).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Episodes").font(.title.bold())
                ForEach(show.episodes) { episode in
                    NavigationLink {
                        TVDiscoverEpisodeDetail(episode: episode, subscription: show.subscription, onPlay: onPlay)
                    } label: { TVDiscoverEpisodeRow(episode: episode) }
                    .buttonStyle(.card)
                }
            }.padding(70)
        }
    }
}

private struct TVDiscoverChartEpisodeDetail: View {
    let chartEpisode: PodcastChartEpisode; let countryCode: String; let repository: TVDiscoverRepository
    let onPlay: (Episode, Subscription) -> Void
    @State private var model = TVDiscoverDetailModel()
    var body: some View {
        Group {
            switch model.phase {
            case .loading: ProgressView("Loading episode details…")
            case .failed(let message): ContentUnavailableView("Episode Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
            case .episode(let show, let episode): TVDiscoverEpisodeDetail(episode: episode, subscription: show.subscription, onPlay: onPlay)
            case .show: EmptyView()
            }
        }.task { model.loadEpisode(chartEpisode, country: countryCode, repository: repository) }
    }
}

private struct TVDiscoverEpisodeDetail: View {
    let episode: Episode; let subscription: Subscription; let onPlay: (Episode, Subscription) -> Void
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 52) {
                TVArtworkImage(url: episode.artworkURL ?? subscription.artworkURL, targetPixels: 720).frame(width: 400, height: 400)
                VStack(alignment: .leading, spacing: 22) {
                    Text(episode.title).font(.largeTitle.bold())
                    Text(subscription.title).font(.title2).foregroundStyle(.secondary)
                    Button("Play", systemImage: "play.fill") {
                        AppLogger.shared.info("tv.discover.playRequested", "Discover play selected", metadata: ["episodeID": episode.id.uuidString], alwaysPersist: true)
                        onPlay(episode, subscription)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    let description = TVEpisodeDescriptionText.plainText(from: episode.description)
                    if !description.isEmpty {
                        Text(description).font(.callout).lineSpacing(3)
                    }
                }
            }.padding(80)
        }
    }
}

private struct TVDiscoverCategoryView: View {
    let category: PodcastChartCategory; let countryCode: String; let initialShows: [PodcastChartShow]
    let repository: TVDiscoverRepository; let onPlay: (Episode, Subscription) -> Void
    @State private var shows: [PodcastChartShow] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            if let error { ContentUnavailableView("Category Unavailable", systemImage: "wifi.exclamationmark", description: Text(error)) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 38)], spacing: 42) {
                ForEach(shows.isEmpty ? initialShows : shows) { show in
                    NavigationLink {
                        TVDiscoverShowDetail(source: .chart(show), countryCode: countryCode, repository: repository, onPlay: onPlay)
                    } label: {
                        TVDiscoverShowCard(show: show, countryCode: countryCode, repository: repository)
                    }
                    .buttonStyle(.card).tvFocusHighlight()
                }
            }.padding(64)
        }.navigationTitle(category.name).task {
            do { shows = try await repository.category(countryCode: countryCode, id: category.id) }
            catch { self.error = "This category could not be loaded." }
        }
    }
}

private struct TVDiscoverShowCard: View {
    let show: PodcastChartShow
    let countryCode: String
    let repository: TVDiscoverRepository
    @State private var isVideo = false

    var body: some View {
        TVArtworkImage(url: show.artworkURL, targetPixels: 640)
            .frame(width: 290, height: 290)
            .overlay(alignment: .topTrailing) { if isVideo { TVDiscoverVideoPill() } }
            .task(id: show.id) {
                isVideo = await repository.isVideoShow(countryCode: countryCode, id: show.id)
            }
            .accessibilityLabel("\(show.title), \(show.publisher)")
    }
}
/// Pocket-Casts-inspired horizontal episode card used only for Top Episodes.
/// Unlike show shelves, ranking an episode needs visible title/show/date
/// context; artwork-only cards made different episodes from one show
/// indistinguishable.
private struct TVDiscoverFeaturedEpisodeCard: View {
    let episode: PodcastChartEpisode
    let countryCode: String
    let repository: TVDiscoverRepository
    @State private var isVideo = false

    var body: some View {
        HStack(spacing: 22) {
            TVArtworkImage(url: episode.artworkURL, targetPixels: 440)
                .frame(width: 184, height: 184)
                .overlay(alignment: .topTrailing) {
                    if isVideo { TVDiscoverVideoPill(compact: true) }
                }
            VStack(alignment: .leading, spacing: 9) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(episode.showTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let releaseDate = episode.releaseDate {
                    Text(releaseDate, format: .dateTime.day().month(.abbreviated).year())
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 560, alignment: .leading)
        }
        .padding(18)
        .frame(width: 820, height: 220, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
        .task(id: episode.id) {
            isVideo = await repository.isVideoEpisode(countryCode: countryCode, episode: episode)
        }
        .accessibilityLabel("\(episode.title), \(episode.showTitle)")
    }
}

private struct TVDiscoverVideoPill: View {
    var compact = false

    var body: some View {
        Label("Video", systemImage: "play.rectangle.fill")
            .font(.caption.bold())
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .foregroundStyle(.white)
            .background(.purple.opacity(0.92), in: Capsule())
            .padding(compact ? 8 : 12)
    }
}
private struct TVDiscoverEpisodeRow: View {
    let episode: Episode
    var body: some View { HStack(spacing: 24) {
        TVArtworkImage(url: episode.artworkURL, targetPixels: 240).frame(width: 130, height: 130)
        VStack(alignment: .leading, spacing: 8) { Text(episode.title).font(.title3.bold()); if let date = episode.publishedAt { Text(date, style: .date).foregroundStyle(.secondary) } }
        Spacer(); Image(systemName: "chevron.right")
    }.padding(18) }
}
