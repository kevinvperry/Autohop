import SwiftUI

// AI CONTEXT — Views/TopEpisodesView.swift ("Top Episodes" page — child of
// Discover, reached via the "See All" button on the Top Episodes hero header).
// An expanded, editorial Top-50 list of Apple Podcasts chart episodes for the
// currently selected Discover country. The shared toolbar country picker writes
// Discover's AppStorage selection and reloads this visible chart. Data comes from the shared
// DiscoverViewModel.top50Episodes (service.topEpisodes limit 50, release-date
// enriched, cached per country); loaded lazily on appear via loadTop50. LAYOUT:
// a large feature card every 7th entry (ranks 1, 8, 15, 22, 29, 36, 43 —
// (rank - 1) % 7 == 0) and the rest render as compact ranked rows, so big
// artwork breaks up the scroll. Each entry shows episode artwork (CachedArtworkImage,
// placeholder when absent — Apple supplies one image per chart episode), episode
// title, show name, and a relative publish label (relativePublishedLabel, e.g.
// "4 hours ago"). Tapping resolves the parent podcast's feed (reusing
// viewModel.resolveEpisodePodcast) and pushes PodcastDetailView on the ambient
// stack via pendingRoute — same routing rule as Discover (real subscription,
// including Inactive, → episodes; else browse preview). NavRules: pushed page,
// brand back chevron top-left,
// MiniPlayerBar docked. Mirrors heroEpisodeCard styling from DiscoverView.swift.
// RESPONSIVE: the outer ScrollView remains full width while its centred inner
// stack uses the same AdaptiveEditorialMetrics vocabulary as Discover. Feature
// height, artwork sizes and gutters derive from the immediate container width;
// do not add device-family branches or independent breakpoints here.
struct TopEpisodesView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let country: ChartCountry
    @AppStorage("discoverCountryCode") private var storedCountryCode = ""

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRoute: DetailRoute?
    @State private var resolvingEpisodeID: String?
    @State private var showUnavailableAlert = false

    private enum DetailRoute: Hashable {
        case preview(PodcastSearchResult)
        case episodes(UUID)
    }

    private var selectedCountry: ChartCountry {
        storedCountryCode.isEmpty ? country : .named(storedCountryCode)
    }

    var body: some View {
        Group {
            switch viewModel.top50Phase {
            case .loading:
                ProgressView("Loading episodes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Episodes Unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.reloadTop50(country: selectedCountry.code) }
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                listContent
            }
        }
        .navigationTitle("Top Episodes")
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
        .task(id: selectedCountry.code) {
            await viewModel.loadTop50(country: selectedCountry.code)
        }
        .refreshable {
            await viewModel.reloadTop50(country: selectedCountry.code)
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
                Text("Apple Podcasts · \(selectedCountry.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.horizontalGutter)
                    .padding(.top, 4)

                ForEach(viewModel.top50Episodes) { episode in
                    // Large feature card every 7th entry (ranks 1, 8, 15, 22, 29, 36, 43).
                    if (episode.rank - 1) % 7 == 0 {
                        featureCard(episode, metrics: metrics)
                            .padding(.horizontal, metrics.horizontalGutter)
                            .padding(.top, episode.rank == 1 ? 4 : 24)
                            .padding(.bottom, 14)
                    } else {
                        compactRow(episode, metrics: metrics)
                            .padding(.horizontal, metrics.horizontalGutter)
                    }
                }

                Spacer(minLength: 24)
                }
                .padding(.top, 8)
                .frame(maxWidth: metrics.availableWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Feature card (one per tier of ten)

    private func featureCard(_ episode: ChartEpisode, metrics: AdaptiveEditorialMetrics) -> some View {
        Button {
            openEpisode(episode)
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.08, blue: 0.42).opacity(0.95),
                             Color.black.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                Text("\(episode.rank)")
                    .font(.system(size: 220, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.07))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 18, y: -22)
                    .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 16) {
                    artwork(episode.artworkURL, size: metrics.featureArtworkSize, cornerRadius: 18, placeholderIconSize: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        rankCapsule(episode.rank)

                        Text(episode.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)

                        Text(episode.showName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let date = episode.releaseDate {
                            Text(relativePublishedLabel(date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)

                if resolvingEpisodeID == episode.id {
                    resolvingOverlay
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.featureCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(resolvingEpisodeID != nil)
    }

    // MARK: - Compact ranked row

    private func compactRow(_ episode: ChartEpisode, metrics: AdaptiveEditorialMetrics) -> some View {
        Button {
            openEpisode(episode)
        } label: {
            HStack(spacing: 14) {
                Text("\(episode.rank)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)

                ZStack {
                    artwork(episode.artworkURL, size: metrics.compactArtworkSize, cornerRadius: 13, placeholderIconSize: 24)
                    if resolvingEpisodeID == episode.id {
                        resolvingOverlay
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .frame(width: metrics.compactArtworkSize, height: metrics.compactArtworkSize)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(episode.showName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let date = episode.releaseDate {
                        Text(relativePublishedLabel(date))
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
        .disabled(resolvingEpisodeID != nil)
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

    // MARK: - Open an episode

    private func openEpisode(_ episode: ChartEpisode) {
        guard resolvingEpisodeID == nil else { return }
        guard episode.collectionId != nil else {
            showUnavailableAlert = true
            return
        }
        resolvingEpisodeID = episode.id
        Task {
            defer { resolvingEpisodeID = nil }
            guard let result = await viewModel.resolveEpisodePodcast(episode, country: selectedCountry.code) else {
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
