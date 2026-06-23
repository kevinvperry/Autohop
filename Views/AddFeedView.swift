import SwiftUI

// AI CONTEXT — Views/AddFeedView.swift ("Add RSS Feed" page). Manual feed-URL
// entry fallback for podcasts not in the iTunes catalog. Uses
// FeedPreviewViewModel to fetch/preview the feed, then subscribes via
// AppState/SubscriptionStore. Reached from PodcastSearchView and App Settings.
struct AddFeedView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = FeedPreviewViewModel()
    @Environment(\.dismiss) private var dismiss

    private var cardBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return Color.white.opacity(0.08)
    }

    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }

    private var formPageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    var body: some View {
        Form {
            Section("RSS feed URL") {
                TextField("https://example.com/feed.xml", text: $viewModel.feedURLText)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Preview Feed") {
                    Task { await viewModel.previewFeed() }
                }
            }
            .listRowBackground(cardBackground)

            Section("Preview") {
                previewContent
            }
            .listRowBackground(cardBackground)

            if let message = viewModel.saveMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(cardBackground)
            }
        }
        .scrollContentBackground(formScrollBackground)
        .background(formPageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Add RSS Feed")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch viewModel.state {
        case .idle:
            Text("Enter a podcast RSS URL above and tap Preview Feed.")
                .foregroundStyle(.secondary)
                .font(.subheadline)

        case .loading:
            HStack {
                ProgressView()
                Text("Reading feed…")
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.subheadline)

        case .loaded(let feed):
            VStack(alignment: .leading, spacing: 10) {
                Text(feed.title)
                    .font(.headline)

                if let author = feed.author {
                    Text(author)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }

                if let episode = feed.latestEpisode {
                    Divider()

                    Text(episode.title)
                        .font(.subheadline.bold())

                    if let audioURL = episode.audioURL {
                        Text(audioURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !episode.chapters.isEmpty {
                        Text("\(episode.chapters.count) chapter\(episode.chapters.count == 1 ? "" : "s") detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Save Subscription") {
                    saveSubscription(feed)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    private func saveSubscription(_ feed: ParsedFeed) {
        guard let feedURL = viewModel.feedURL else {
            viewModel.saveMessage = "Enter a valid RSS URL before saving."
            return
        }

        do {
            _ = try appState.subscriptionStore.add(parsedFeed: feed, feedURL: feedURL)
            dismiss()
        } catch {
            viewModel.saveMessage = error.localizedDescription
        }
    }
}
