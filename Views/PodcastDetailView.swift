import SwiftUI

// AI CONTEXT — Views/PodcastDetailView.swift
// Single "Podcast Detail" page, the merge of the old PodcastPreviewView and
// SubscriptionEpisodesView. Works for every podcast state:
//   • a search result not yet subscribed (init(result:))
//   • a browse-only preview subscription (init(browseSubscription:))
//   • an active subscription (init(subscriptionID:))
// Layout: centred Header-SubscriptionPage (artwork · title · VideoBadgeLarge/
// ExplicitPill · description · author/categories) · Subscribe⇄Unsubscribe button
// · "Episodes" list of ListRow-EpisodeRow (badges as top-trailing overlay per
// DESIGN.md) pushing EpisodeDetailView, with the standard leading (Play / Play
// Next) and trailing (Archive / Play Last) swipes — NO share swipe. Toolbar
// shows Refresh Feed + Show Settings only for an active subscription; the share
// button and mini-player bar are always present.

struct PodcastDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // Identity — at most one of these is set per entry point.
    private let searchResult: PodcastSearchResult?
    private let directSubscriptionID: UUID?

    @StateObject private var viewModel: PodcastPreviewViewModel
    @State private var isSubscribing = false
    @State private var isRefreshing = false
    @State private var isLoadingOlderEpisodes = false
    @State private var episodeToShare: Episode?
    @State private var showExpandedArtwork = false
    @State private var showUnsubscribeConfirm = false
    /// Header/feed-URL fallback captured from the subscription so the page stays
    /// populated (and re-subscribable) after the user taps Unsubscribe.
    @State private var snapshot: PodcastSearchResult?

    /// From a search result (may not be subscribed yet).
    init(result: PodcastSearchResult) {
        self.searchResult = result
        self.directSubscriptionID = nil
        _viewModel = StateObject(wrappedValue: PodcastPreviewViewModel(feedURL: result.feedURL))
    }

    /// From a browse-history subscription (Recently Viewed).
    init(browseSubscription sub: Subscription) {
        self.searchResult = PodcastSearchResult(
            id: abs(sub.id.hashValue),
            title: sub.title,
            author: sub.author ?? "",
            feedURL: sub.feedURL,
            artworkURL: sub.artworkURL,
            episodeCount: sub.episodes.count,
            genre: sub.categories.first ?? ""
        )
        self.directSubscriptionID = nil
        _viewModel = StateObject(wrappedValue: PodcastPreviewViewModel(feedURL: sub.feedURL))
    }

    /// From an existing subscription ID (active subscription).
    init(subscriptionID: UUID) {
        self.searchResult = nil
        self.directSubscriptionID = subscriptionID
        _viewModel = StateObject(wrappedValue: PodcastPreviewViewModel(feedURL: nil))
    }

    // MARK: - Derived state

    /// The subscription backing this feed, if any (active OR inactive / browse).
    private var subscription: Subscription? {
        if let directSubscriptionID,
           let sub = appState.subscriptionStore.subscription(id: directSubscriptionID) {
            return sub
        }
        if let url = feedURL {
            return appState.subscriptionStore.subscriptions.first { $0.feedURL == url }
        }
        return nil
    }

    /// Feed URL resolved from whichever identity / fallback we have.
    private var feedURL: URL? {
        searchResult?.feedURL ?? snapshot?.feedURL
    }

    /// True only for a real, active subscription (browse previews don't count).
    private var isActivelySubscribed: Bool {
        guard let subscription else { return false }
        return !subscription.excludeFromAutoFeedRefresh
    }

    var body: some View {
        Group {
            if subscription != nil || searchResult != nil || snapshot != nil {
                content
            } else {
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Capture a header/feed snapshot so the page survives Unsubscribe.
            if snapshot == nil, let sub = subscription {
                snapshot = PodcastSearchResult(
                    id: abs(sub.id.hashValue),
                    title: sub.title,
                    author: sub.author ?? "",
                    feedURL: sub.feedURL,
                    artworkURL: sub.artworkURL,
                    episodeCount: sub.episodes.count,
                    genre: sub.categories.first ?? ""
                )
            }

            guard let url = feedURL else { return }
            if let sub = appState.subscriptionStore.subscriptions.first(where: { $0.feedURL == url }) {
                if sub.browseDate != nil {
                    // Returning visitor to a browse-only preview: reset the 30-day
                    // clock and refresh episodes so new content appears.
                    appState.subscriptionStore.refreshBrowseDate(subscriptionID: sub.id)
                    await appState.refreshSubscription(sub)
                }
            } else if searchResult != nil {
                // First visit to a search result: fetch the feed, create the preview.
                await viewModel.load()
                if let feed = viewModel.loadedFeed {
                    try? appState.subscriptionStore.addPreviewSubscription(
                        parsedFeed: feed,
                        feedURL: url
                    )
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar { toolbarContent }
        .miniPlayerBar()
        .sheet(item: $episodeToShare) { ep in
            EpisodeShareSheet(episode: ep, subscription: subscription)
        }
        .confirmationDialog(
            "Unsubscribe from \(subscription?.title ?? "this podcast")?",
            isPresented: $showUnsubscribeConfirm,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                if let id = subscription?.id {
                    appState.subscriptionStore.remove(subscriptionID: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
        }

        if isActivelySubscribed {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    guard let subscription, !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await appState.refreshSubscription(subscription)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh Feed", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)

                Button {
                    episodeToShare = subscription?.latestEpisode
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(subscription?.latestEpisode == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    if let id = subscription?.id {
                        SubscriptionSettingsView(subscriptionID: id)
                    }
                } label: {
                    Label("Show Settings", systemImage: "gearshape")
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    episodeToShare = subscription?.latestEpisode
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(subscription?.latestEpisode == nil)
            }
        }
    }

    // MARK: - Main content

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)

            HStack(spacing: 6) {
                Text("Episodes")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            List {
                episodeContent
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Header

    private var header: some View {
        let sub = subscription
        let fallback = searchResult ?? snapshot
        let artworkURL: URL? = sub?.artworkURL ?? fallback?.artworkURL
        let title: String = sub?.title ?? fallback?.title ?? ""
        let author: String? = sub?.author ?? (fallback?.author.isEmpty == false ? fallback?.author : nil)
        let description: String? = sub?.description
        let categories: [String] = sub?.categories ?? (fallback?.genre).map { $0.isEmpty ? [] : [$0] } ?? []
        let showVideo: Bool = sub?.latestEpisode?.mediaKind == .video
        let showExplicit: Bool = sub?.isExplicit == true

        return VStack(spacing: 12) {
            CachedArtworkImage(url: artworkURL) {
                ZStack {
                    LinearGradient(
                        colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .onTapGesture { showExpandedArtwork = true }
            .sheet(isPresented: $showExpandedArtwork) {
                ExpandedArtworkSheet(url: artworkURL)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                // Video / Explicit pills centred between title and description.
                if showVideo || showExplicit {
                    HStack(spacing: 6) {
                        if showVideo { VideoBadgeLarge() }
                        if showExplicit { ExplicitPill() }
                    }
                }

                if let desc = description.map(stripHTML), !desc.isEmpty {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let author {
                        Text(author).fontWeight(.bold).lineLimit(1)
                    }
                    if author != nil, !categories.isEmpty { Text("·") }
                    if !categories.isEmpty {
                        Text(categories.joined(separator: ", ")).fontWeight(.bold).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            subscribeButton
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var subscribeButton: some View {
        Button {
            if isActivelySubscribed {
                showUnsubscribeConfirm = true
            } else {
                Task { await subscribe() }
            }
        } label: {
            Group {
                if isSubscribing {
                    ProgressView().tint(.white)
                } else if isActivelySubscribed {
                    Label("Unsubscribe", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                } else {
                    Label("Subscribe", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActivelySubscribed ? .gray : .purple)
        .disabled(isSubscribing)
    }

    // MARK: - Episode list

    @ViewBuilder
    private var episodeContent: some View {
        if let sub = subscription {
            let episodes: [Episode] = sub.episodes.isEmpty
                ? sub.latestEpisode.map { [$0] } ?? []
                : sub.episodes

            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "waveform",
                    description: Text("No episodes were found in this feed.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(episodes) { episode in
                    NavigationLink {
                        EpisodeDetailView(subscriptionID: sub.id, episodeID: episode.id)
                    } label: {
                        episodeRow(episode, sub: sub)
                    }
                    .listRowBackground(
                        appState.currentPlayerEpisode?.id == episode.id
                            ? Color.purple.opacity(0.08)
                            : Color.white.opacity(0.08)
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        leadingSwipe(episode: episode, sub: sub)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        trailingSwipe(episode: episode, sub: sub)
                    }
                }

                if episodes.count >= 50 {
                    Button {
                        guard !isLoadingOlderEpisodes else { return }
                        isLoadingOlderEpisodes = true
                        Task {
                            await appState.loadFullEpisodeHistory(for: sub)
                            isLoadingOlderEpisodes = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingOlderEpisodes {
                                ProgressView()
                            } else {
                                Label("Load Older Episodes", systemImage: "clock.arrow.circlepath")
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                    .disabled(isLoadingOlderEpisodes)
                }
            }
        } else {
            HStack {
                Spacer()
                ProgressView("Loading episodes…")
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Episode row (ListRow-EpisodeRow)

    private func episodeRow(_ episode: Episode, sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CachedArtworkImage(url: episode.artworkURL ?? sub.artworkURL) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let desc = episode.description.map(stripHTML), !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    HStack(spacing: 4) {
                        if let date = episode.publishedAt {
                            Text(formatPublishedDate(date)).lineLimit(1)
                        }
                        if let duration = episode.durationSeconds {
                            let elapsed = appState.effectivePlaybackTime(for: episode)
                            let remaining = elapsed > 0 ? max(0, duration - elapsed) : duration
                            let isPartial = elapsed > 0
                            Text("•")
                            Text(isPartial ? "\(formatDuration(remaining)) left remaining" : formatDuration(duration))
                                .monospacedDigit().lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        EpisodeStatusPill(kind: statusKind(for: episode))
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if episode.downloadState == .downloading,
               let progress = appState.downloadProgress[episode.id] {
                ProgressView(value: progress, total: 1.0)
                    .tint(.purple)
                    .animation(.linear(duration: 0.3), value: progress)
                    .padding(.leading, 56)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topTrailing) {
            if episode.mediaKind == .video || episode.isExplicit == true {
                HStack(spacing: 3) {
                    if episode.mediaKind == .video { VideoBadge() }
                    if episode.isExplicit == true { ExplicitPillSmall() }
                }
            }
        }
    }

    // MARK: - Swipe actions

    @ViewBuilder
    private func leadingSwipe(episode: Episode, sub: Subscription) -> some View {
        let isCurrentlyPlaying = appState.currentPlayerEpisode?.id == episode.id
        if !isCurrentlyPlaying {
            Button {
                Task {
                    if episode.downloadState != .downloaded {
                        await appState.downloadEpisodeForQueue(episode)
                    }
                    if let updated = appState.subscriptionStore.episode(subscriptionID: sub.id, episodeID: episode.id) {
                        await appState.playEpisode(updated)
                    }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .tint(.green)

            Button {
                Task {
                    if episode.downloadState != .downloaded {
                        await appState.downloadEpisodeForQueue(episode)
                    }
                    appState.playEpisodeNext(episode)
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func trailingSwipe(episode: Episode, sub: Subscription) -> some View {
        let isCurrentlyPlaying = appState.currentPlayerEpisode?.id == episode.id
        if !isCurrentlyPlaying {
            if episode.playedState == .archived || episode.playedState == .played {
                Button {
                    appState.unarchiveEpisode(episode)
                } label: {
                    Label("Unarchive", systemImage: "arrow.uturn.backward.circle")
                }
                .tint(.purple)
            } else {
                Button {
                    Task { await appState.archiveEpisode(episode) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.purple)
            }

            Button {
                Task {
                    if episode.downloadState != .downloaded {
                        await appState.downloadEpisodeForQueue(episode)
                    }
                    appState.playEpisodeLast(episode)
                }
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(.orange)
        }
    }

    // MARK: - Subscribe action

    private func subscribe() async {
        isSubscribing = true
        defer { isSubscribing = false }
        do {
            if let existing = subscription {
                if existing.excludeFromAutoFeedRefresh {
                    // Browse / inactive → activate and move to top of Priority Stack.
                    appState.subscriptionStore.activateAndMoveToTop(subscriptionID: existing.id)
                }
            } else if let url = feedURL {
                // No subscription at all — fetch the feed (if needed) and add it.
                let feed: ParsedFeed
                if let loaded = viewModel.loadedFeed {
                    feed = loaded
                } else {
                    feed = try await EpisodeFeedLoader().fetch(feedURL: url, limit: 50)
                }
                _ = try appState.subscriptionStore.add(parsedFeed: feed, feedURL: url)
            }
        } catch SubscriptionStoreError.duplicateFeed {
            // Already subscribed — nothing to do.
        } catch {}
    }

    // MARK: - Helpers

    private func statusKind(for episode: Episode) -> EpisodeStatusKind {
        switch episode.playedState {
        case .playing:
            return appState.currentPlayerEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
        case .played:   return .played
        case .archived: return episode.wasCompleted ? .played : .archived
        case .unplayed:
            let position = appState.effectivePlaybackTime(for: episode)
            if position > 0 { return .partiallyPlayed }
            return episode.downloadState == .downloaded ? .queued : .unplayed
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func formatPublishedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Status pill (file-private copy — matches SubscriptionSettingsView / PodcastsView)

private enum EpisodeStatusKind {
    case unplayed, queued, partiallyPlayed, nowPlaying, played, archived, inactive

    var label: String {
        switch self {
        case .unplayed:        return "Unplayed"
        case .queued:          return "Queued"
        case .partiallyPlayed: return "Paused"
        case .nowPlaying:      return "Playing"
        case .played:          return "Played"
        case .archived:        return "Archived"
        case .inactive:        return "Inactive"
        }
    }

    var color: Color {
        switch self {
        case .unplayed:        return Color.gray
        case .queued:          return Color.teal
        case .partiallyPlayed: return Color.yellow
        case .nowPlaying:      return Color.green
        case .played:          return Color.blue
        case .archived:        return Color.purple
        case .inactive:        return Color.orange
        }
    }
}

private struct EpisodeStatusPill: View {
    let kind: EpisodeStatusKind

    var body: some View {
        let label = Text(kind.label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .background(kind.color.opacity(0.45), in: Capsule())
                .glassEffect(in: Capsule())
        } else {
            label
                .background(kind.color.opacity(0.82), in: Capsule())
        }
    }
}

// MARK: - HTML stripping (file-private copy — matches SubscriptionSettingsView)

private func stripHTML(_ html: String) -> String {
    // Strip tags, then decode entities.
    let withoutTags = html.replacingOccurrences(
        of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression
    )
    return decodeHTMLEntities(withoutTags)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func decodeHTMLEntities(_ text: String) -> String {
    var result = text
    // Numeric decimal entities &#NNN;
    if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
        let nsResult = NSMutableString(string: result)
        var offset = 0
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let numRange = Range(match.range(at: 1), in: result),
                  let codePoint = UInt32(result[numRange]),
                  let scalar = Unicode.Scalar(codePoint) else { continue }
            let replacement = String(scalar)
            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            nsResult.replaceCharacters(in: adjustedRange, with: replacement)
            offset += replacement.count - match.range.length
        }
        result = nsResult as String
    }
    // Numeric hex entities &#xHHH;
    if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
        let nsResult = NSMutableString(string: result)
        var offset = 0
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let numRange = Range(match.range(at: 1), in: result),
                  let codePoint = UInt32(result[numRange], radix: 16),
                  let scalar = Unicode.Scalar(codePoint) else { continue }
            let replacement = String(scalar)
            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            nsResult.replaceCharacters(in: adjustedRange, with: replacement)
            offset += replacement.count - match.range.length
        }
        result = nsResult as String
    }
    // Named entities
    for (entity, replacement) in namedHTMLEntities {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
}

private let namedHTMLEntities: [(String, String)] = [
    ("&amp;",   "&"),  ("&lt;",    "<"),  ("&gt;",    ">"),
    ("&quot;",  "\""), ("&apos;",  "'"),  ("&nbsp;",  " "),
    ("&mdash;", "—"),  ("&ndash;", "–"),  ("&rsquo;", "\u{2019}"),
    ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
    ("&hellip;","\u{2026}"), ("&bull;",  "\u{2022}"), ("&copy;",  "\u{00A9}"),
    ("&reg;",   "\u{00AE}"), ("&trade;", "\u{2122}"), ("&euro;",  "\u{20AC}"),
    ("&pound;", "\u{00A3}"), ("&yen;",   "\u{00A5}"), ("&cent;",  "\u{00A2}"),
]
