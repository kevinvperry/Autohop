import SwiftUI

// AI CONTEXT — Views/PodcastSearchView.swift ("Podcast Search" sheet + the
// "Podcast Preview" page inside it). Search the iTunes catalog (400 ms
// debounce via PodcastSearchViewModel/PodcastSearchService); idle state shows
// Recently Viewed (browse subscriptions, browseDate != nil, newest first) and
// an Enter RSS URL link to AddFeedView. Opening a result creates/refreshes an
// invisible BROWSE subscription (30-day retention clock resets per visit) so
// the preview's episode list is fully interactive — play/queue/archive —
// before subscribing. Opening a result navigates to PodcastDetailView, which
// renders both the preview and subscribed states (Subscribe⇄Unsubscribe).
// Lifecycle rules: PAGES.md "Browse Subscription Lifecycle" + FEATURES.md §2.
// Search and Recently Viewed rows use 44 pt CachedArtworkImage thumbnails so
// catalog/browse art participates in the same shared downsampled cache.
// MARK: - Search Sheet

struct PodcastSearchView: View {
    @StateObject private var viewModel = PodcastSearchViewModel()
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var recentlyViewed: [Subscription] {
        appState.subscriptionStore.subscriptions
            .filter { $0.browseDate != nil }
            .sorted { ($0.browseDate ?? .distantPast) > ($1.browseDate ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .idle:
                    idleState
                case .loading:
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .results(let results):
                    resultsList(results)
                case .empty:
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search podcasts…"
            )
            .onChange(of: query) { _, new in viewModel.queryChanged(new) }
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
            // Search result → check for active sub first; otherwise go to preview.
            .navigationDestination(for: PodcastSearchResult.self) { result in
                if let activeSub = appState.subscriptionStore.subscriptions.first(where: {
                    $0.feedURL == result.feedURL && !$0.excludeFromAutoFeedRefresh
                }) {
                    PodcastDetailView(subscriptionID: activeSub.id)
                } else {
                    PodcastDetailView(result: result)
                }
            }
            // Recently viewed row → subscription ID routes to preview or active view.
            .navigationDestination(for: UUID.self) { subscriptionID in
                if let sub = appState.subscriptionStore.subscriptions.first(where: { $0.id == subscriptionID }) {
                    if sub.excludeFromAutoFeedRefresh {
                        PodcastDetailView(browseSubscription: sub)
                    } else {
                        PodcastDetailView(subscriptionID: subscriptionID)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Idle state (+ Recently Viewed)

    private var idleState: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        Text("Search for a podcast")
                            .font(.title3.weight(.semibold))
                        Text("Find shows by title, author, or keyword.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)

                NavigationLink { AddFeedView() } label: {
                    Label("Enter RSS URL", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 24)

                if !recentlyViewed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recently Viewed")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 20)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(recentlyViewed) { sub in
                                NavigationLink(value: sub.id) {
                                    recentlyViewedRow(sub)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                                if sub.id != recentlyViewed.last?.id {
                                    Divider().padding(.leading, 76)
                                }
                            }
                        }
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 12)
                    }
                }

                Spacer(minLength: 32)
            }
        }
    }

    private func recentlyViewedRow(_ sub: Subscription) -> some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: sub.artworkURL, targetSize: CGSize(width: 44, height: 44)) {
                artworkPlaceholder(size: 15)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(sub.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let author = sub.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let date = sub.browseDate {
                    Text(formatBrowseDate(date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Results list

    private func resultsList(_ results: [PodcastSearchResult]) -> some View {
        List {
            ForEach(results) { result in
                NavigationLink(value: result) {
                    resultRow(result)
                }
                .listRowBackground(Color.white.opacity(0.08))
            }

            Section {
                NavigationLink { AddFeedView() } label: {
                    Label("Enter RSS URL", systemImage: "link")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func resultRow(_ result: PodcastSearchResult) -> some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: result.artworkURL, targetSize: CGSize(width: 44, height: 44)) {
                artworkPlaceholder(size: 15)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(result.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !result.genre.isEmpty {
                    Text(result.genre)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func artworkPlaceholder(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "waveform")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func formatBrowseDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Viewed today" }
        if calendar.isDateInYesterday(date) { return "Viewed yesterday" }
        return "Viewed " + date.formatted(date: .abbreviated, time: .omitted)
    }
}
