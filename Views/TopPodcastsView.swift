import SwiftUI

// AI CONTEXT — Views/TopPodcastsView.swift ("Top Podcasts" page — child of
// Discover, reached via the "See All" button on the FIRST "Top Podcasts ·
// <selected country>" hero header, i.e. the mid-feed podcastHero, NOT the
// fixed-country spotlight heroes). An expanded, editorial Top-50 list of Apple
// Podcasts chart shows for the currently selected Discover country. Data comes
// from the shared DiscoverViewModel.top50Podcasts (service.topPodcasts limit 50,
// cached per country); loaded lazily on appear via loadTop50Podcasts. LAYOUT
// mirrors TopEpisodesView — a large feature card every 7th entry (ranks 1, 8, 15,
// 22, 29, 36, 43 — (rank - 1) % 7 == 0) and the rest compact ranked rows. Each
// entry shows ChartPodcast artwork, title, author (artist) and genre (genreName)
// — the podcast analogue of TopEpisodesView's title/show/release-date. Tapping
// resolves the show's RSS feed (viewModel.resolve) and pushes PodcastDetailView
// on the ambient stack via pendingRoute — same routing rule as Discover (real
// subscription, including Inactive, → episodes; else browse preview). NavRules:
// pushed page, brand back chevron top-left, MiniPlayerBar docked.
struct TopPodcastsView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let country: ChartCountry

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRoute: DetailRoute?
    @State private var resolvingPodcastID: String?
    @State private var showUnavailableAlert = false

    private enum DetailRoute: Hashable {
        case preview(PodcastSearchResult)
        case episodes(UUID)
    }

    var body: some View {
        Group {
            switch viewModel.top50PodcastsPhase {
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
                        Task { await viewModel.reloadTop50Podcasts(country: country.code) }
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                listContent
            }
        }
        .navigationTitle("Top Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
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
            await viewModel.loadTop50Podcasts(country: country.code)
        }
        .refreshable {
            await viewModel.reloadTop50Podcasts(country: country.code)
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
                Text("Apple Podcasts · \(country.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                ForEach(viewModel.top50Podcasts) { podcast in
                    // Large feature card every 7th entry (ranks 1, 8, 15, 22, 29, 36, 43).
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

                Spacer(minLength: 24)
            }
            .padding(.top, 8)
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
            .frame(height: 232)
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

    private func openPodcast(_ podcast: ChartPodcast) {
        guard resolvingPodcastID == nil else { return }
        resolvingPodcastID = podcast.id
        Task {
            defer { resolvingPodcastID = nil }
            guard let result = await viewModel.resolve(podcast, country: country.code) else {
                showUnavailableAlert = true
                return
            }
            // Same routing rule as Discover: real subscriptions open their
            // episode page, everything else the browse preview.
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
