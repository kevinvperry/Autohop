// AI CONTEXT — Navigation compatibility, 20 September 2026 (AddFeedView.swift).
// PURPOSE: Prevent duplicate native/custom Back controls reported on iOS 27.
// COLLABORATOR: RootView.swift owns appNavigationBackButton: native Back on iOS
// 27+, branded ambient dismiss on older systems. Do not add a second leading Back
// or mutate the outer path; preserve the nearest parent and existing mini-player.
// EVIDENCE: Docs/IOS27_NAVIGATION_BACK_AUDIT.md and NavigationChromeTests.

import SwiftUI

// AI CONTEXT — Add RSS Feed, Version 1.7. Replay-style guided glass cards.
// Keep manual URL entry, RSS preview and SubscriptionStore.add as the only save
// path. Editing the address invalidates the old preview; disable edits during
// loading so a preview cannot be saved against a different feed URL. No automatic
// clipboard reads or subscriptions on preview. Keep both entry paths and mini-player.
// Hide Preview for blank/whitespace input; retain the loading indicator during fetch.
struct AddFeedView: View {
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @StateObject private var viewModel = FeedPreviewViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressFocused: Bool

    private var loading: Bool { viewModel.state == .loading }

    var body: some View {
        Form {
            card("Bring your podcast along", icon: "dot.radiowaves.left.and.right") {
                Text("Have a podcast feed link? Add it directly to your subscriptions.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Paste the link, check the podcast, then subscribe.")
                    .font(.subheadline.weight(.medium))
            }
            card("1. Add the feed link", icon: "link") {
                Text("Use the RSS link from the podcast’s website or publisher.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("https://example.com/feed.xml", text: $viewModel.feedURLText, axis: .vertical)
                    .textFieldStyle(.plain).font(.body).foregroundStyle(.white)
                    .keyboardType(.URL).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(1...5).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44).padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.purple.opacity(0.45)))
                    .accessibilityLabel("RSS feed link")
                    .focused($addressFocused).disabled(loading)
                    .onChange(of: viewModel.feedURLText) { _, _ in viewModel.clearPreview() }
                if loading || !viewModel.feedURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        addressFocused = false
                        Task { await viewModel.previewFeed() }
                    } label: {
                        HStack {
                            if loading { ProgressView().tint(.white) }
                            Text(loading ? "Checking podcast…" : "Preview Podcast")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                }
                DisclosureGroup("What is an RSS link?") {
                    Text("It is a special link that lists a podcast’s episodes. Look for ‘RSS’ or ‘Subscribe’ on the podcast’s website, or ask the publisher.\n\nA normal website address or Apple Podcasts page is usually not an RSS feed.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            card("2. Check your podcast", icon: "checkmark.circle") { previewContent }
        }
        .responsiveListSizing()
        .listSectionSpacing(AdaptiveLayoutMetrics.settingsSectionSpacing)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .tint(.purple).preferredColorScheme(.dark)
        .navigationTitle("Add RSS Feed")
        .responsiveInlineNavigationTitle("Add RSS Feed")
        .miniPlayerBar()
        .appNavigationBackButton()
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: icon)
                    .font(.headline).foregroundStyle(.white)
                    .labelStyle(SettingsCardLabelStyle())
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .glassCard(cornerRadius: 12)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var previewContent: some View {
        switch viewModel.state {
        case .idle:
            Text("Your podcast will appear here after you preview the link. Nothing is added until you tap Subscribe.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .loading:
            Text("Reading the feed. This may take a moment.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .failed(let message):
            Label("We couldn’t read this feed", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            Text("Check the link and your internet connection, then try Preview Podcast again.")
                .font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("Error details") { Text(message).font(.caption).textSelection(.enabled) }
        case .loaded(let feed):
            CachedArtworkImage(url: feed.artworkURL, targetSize: CGSize(width: 100, height: 100)) {
                Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.purple)
            }
            .frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(feed.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let author = feed.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
            if let episode = feed.latestEpisode {
                Divider()
                Text("Latest episode").font(.caption).foregroundStyle(.secondary)
                Text(episode.title).font(.subheadline.weight(.medium))
                if !episode.chapters.isEmpty {
                    Text("\(episode.chapters.count) chapters available").font(.caption).foregroundStyle(.secondary)
                }
                if let audioURL = episode.audioURL {
                    DisclosureGroup("Episode link") {
                        Text(audioURL.absoluteString).font(.caption).textSelection(.enabled)
                    }
                }
            }
            Button { saveSubscription(feed) } label: {
                Label("Subscribe", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            if let message = viewModel.saveMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        }
    }

    private func saveSubscription(_ feed: ParsedFeed) {
        guard let feedURL = viewModel.feedURL else {
            viewModel.saveMessage = "Enter a valid RSS link before subscribing."
            return
        }
        do {
            _ = try subscriptionStore.add(parsedFeed: feed, feedURL: feedURL)
            dismiss()
        } catch { viewModel.saveMessage = error.localizedDescription }
    }
}

private struct SettingsCardLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.foregroundStyle(.purple)
            configuration.title
        }
    }
}
