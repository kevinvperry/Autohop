import SwiftUI

struct AddFeedView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = FeedPreviewViewModel()
    @Environment(\.dismiss) private var dismiss

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

            Section("Preview") {
                previewContent
            }

            if let message = viewModel.saveMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Add RSS Feed")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
                    ReturnToPlayerButton()
                }
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
