import SwiftUI

// MARK: - Search Sheet

struct PodcastSearchView: View {
    @StateObject private var viewModel = PodcastSearchViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: PodcastSearchResult.self) { result in
                PodcastPreviewView(result: result)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Idle state

    private var idleState: some View {
        VStack(spacing: 20) {
            Spacer()
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
            Spacer()
            NavigationLink { AddFeedView() } label: {
                Label("Enter RSS URL", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
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
            CachedArtworkImage(url: result.artworkURL) {
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
}

// MARK: - Preview / Subscribe Sheet

struct PodcastPreviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let result: PodcastSearchResult

    @State private var isSubscribing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                CachedArtworkImage(url: result.artworkURL) {
                    previewPlaceholder
                }
                .frame(width: 130, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                .padding(.top, 32)

                VStack(spacing: 6) {
                    Text(result.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(result.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        if !result.genre.isEmpty {
                            Label(result.genre, systemImage: "tag")
                        }
                        if result.episodeCount > 0 {
                            Label("\(result.episodeCount) ep.", systemImage: "waveform")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button {
                        Task { await subscribe() }
                    } label: {
                        Group {
                            if isSubscribing {
                                ProgressView().tint(.white)
                            } else {
                                Label("Subscribe", systemImage: "plus.circle.fill")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(isSubscribing)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private var previewPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func subscribe() async {
        isSubscribing = true
        errorMessage = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: result.feedURL)
            let feed = try RSSParser().parse(data: data)
            _ = try appState.subscriptionStore.add(parsedFeed: feed, feedURL: result.feedURL)
            dismiss()
        } catch SubscriptionStoreError.duplicateFeed {
            errorMessage = "You're already subscribed to this podcast."
            isSubscribing = false
        } catch {
            errorMessage = "Couldn't load this feed. Try adding it by RSS URL instead."
            isSubscribing = false
        }
    }
}
