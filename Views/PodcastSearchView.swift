import SwiftUI

// AI CONTEXT — Views/PodcastSearchView.swift ("Podcast Search" sheet + the
// "Podcast Preview" page inside it). Search the iTunes catalog (400 ms
// debounce via PodcastSearchViewModel/PodcastSearchService); idle state shows
// Recently Viewed (browse subscriptions, browseDate != nil, newest first) and
// an Enter RSS URL link to AddFeedView. Opening a result creates/refreshes an
// invisible BROWSE subscription (30-day retention clock resets per visit) so
// the preview's episode list is fully interactive — play/queue/archive —
// before subscribing. Subscribe activates the browse subscription and moves
// it to the top of the Priority Stack; already-subscribed results redirect to
// the existing episode page instead of showing the preview. Lifecycle rules:
// PAGES.md "Browse Subscription Lifecycle" + FEATURES.md §2.
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Search result → check for active sub first; otherwise go to preview.
            .navigationDestination(for: PodcastSearchResult.self) { result in
                if let activeSub = appState.subscriptionStore.subscriptions.first(where: {
                    $0.feedURL == result.feedURL && !$0.excludeFromAutoFeedRefresh
                }) {
                    SubscriptionEpisodesView(subscriptionID: activeSub.id)
                } else {
                    PodcastPreviewView(result: result)
                }
            }
            // Recently viewed row → subscription ID routes to preview or active view.
            .navigationDestination(for: UUID.self) { subscriptionID in
                if let sub = appState.subscriptionStore.subscriptions.first(where: { $0.id == subscriptionID }) {
                    if sub.excludeFromAutoFeedRefresh {
                        PodcastPreviewView(browseSubscription: sub)
                    } else {
                        SubscriptionEpisodesView(subscriptionID: subscriptionID)
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

                        LazyVStack(spacing: 0) {
                            ForEach(recentlyViewed) { sub in
                                NavigationLink(value: sub.id) {
                                    recentlyViewedRow(sub)
                                }
                                .listRowBackground(Color.white.opacity(0.08))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                                Divider().padding(.leading, 76)
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
            CachedArtworkImage(url: sub.artworkURL) {
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

    private func formatBrowseDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Viewed today" }
        if calendar.isDateInYesterday(date) { return "Viewed yesterday" }
        return "Viewed " + date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Podcast Preview (header + episode list)

// AI CONTEXT — PodcastPreviewView ("Podcast Preview" page inside the Search
// sheet). Renders a podcast before subscription: auto-creates the invisible
// browse subscription on open, shows up to 50 episodes (Load Older Episodes →
// EpisodeFeedLoader full fetch), fully interactive rows identical to the
// subscribed episode list. Subscribe button activates the browse subscription
// and inserts it at the top of the Priority Stack.
struct PodcastPreviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let result: PodcastSearchResult

    @StateObject private var viewModel: PodcastPreviewViewModel
    @State private var isSubscribing = false
    @State private var isLoadingOlderEpisodes = false
    @State private var episodeToShare: Episode?
    @State private var showExpandedArtwork = false

    /// Standard init from search results.
    init(result: PodcastSearchResult) {
        self.result = result
        _viewModel = StateObject(wrappedValue: PodcastPreviewViewModel(feedURL: result.feedURL))
    }

    /// Convenience init from a browse-history subscription (Recently Viewed).
    init(browseSubscription sub: Subscription) {
        self.result = PodcastSearchResult(
            id: abs(sub.id.hashValue),
            title: sub.title,
            author: sub.author ?? "",
            feedURL: sub.feedURL,
            artworkURL: sub.artworkURL,
            episodeCount: sub.episodes.count,
            genre: sub.categories.first ?? ""
        )
        _viewModel = StateObject(wrappedValue: PodcastPreviewViewModel(feedURL: sub.feedURL))
    }

    // The subscription for this feed, if any (active OR inactive / browse).
    private var subscription: Subscription? {
        appState.subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL })
    }

    var body: some View {
        Group {
            if subscription != nil {
                content
            } else {
                // Feed still loading, no subscription created yet.
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let existingSub = appState.subscriptionStore.subscriptions
                .first(where: { $0.feedURL == result.feedURL })

            if let sub = existingSub {
                if sub.browseDate != nil {
                    // Returning visitor to a browse-only preview:
                    // reset the 30-day clock and refresh episodes so new content appears.
                    appState.subscriptionStore.refreshBrowseDate(subscriptionID: sub.id)
                    await appState.refreshSubscription(sub)
                }
                // Active subscription: nothing to do (redirected at search level, but safe to land here).
            } else {
                // First visit: fetch the feed then create the preview subscription.
                await viewModel.load()
                if let feed = viewModel.loadedFeed {
                    try? appState.subscriptionStore.addPreviewSubscription(
                        parsedFeed: feed,
                        feedURL: result.feedURL
                    )
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left.circle.fill")
                    }
                    ReturnToPlayerButton()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    episodeToShare = subscription?.latestEpisode
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(subscription?.latestEpisode == nil)
            }
        }
        .sheet(item: $episodeToShare) { ep in
            EpisodeShareSheet(episode: ep, subscription: subscription)
        }
    }

    // MARK: - Main content

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewHeader
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

    private var previewHeader: some View {
        let sub = subscription
        let artworkURL: URL? = sub?.artworkURL ?? result.artworkURL
        let title: String = sub?.title ?? result.title
        let author: String? = sub?.author ?? (result.author.isEmpty ? nil : result.author)
        let description: String? = sub?.description
        let categories: [String] = sub?.categories ?? []
        let isExplicit: Bool? = sub?.isExplicit
        let isVideo: Bool = sub?.latestEpisode?.mediaKind == .video

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

                if isVideo || isExplicit == true {
                    HStack(spacing: 6) {
                        if isVideo { VideoBadge() }
                        if isExplicit == true { ExplicitPill() }
                    }
                }

                if let desc = description.map(stripHTMLPreview), !desc.isEmpty {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let a = author {
                        Text(a).fontWeight(.bold).lineLimit(1)
                    }
                    if author != nil, !categories.isEmpty { Text("·") }
                    if !categories.isEmpty {
                        Text(categories.joined(separator: ", ")).fontWeight(.bold).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
        }
        .frame(maxWidth: .infinity)
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
                        episodeRow(episode, artworkURL: sub.artworkURL)
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
            // Subscription not yet created (feed still loading).
            HStack {
                Spacer()
                ProgressView("Loading episodes…")
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Episode row

    private func episodeRow(_ episode: Episode, artworkURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .center, spacing: 4) {
                    CachedArtworkImage(url: episode.artworkURL ?? artworkURL) {
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

                    if episode.mediaKind == .video || episode.isExplicit == true {
                        VStack(spacing: 3) {
                            if episode.mediaKind == .video { VideoBadge() }
                            if episode.isExplicit == true { ExplicitPill() }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let desc = episode.description.map(stripHTMLPreview), !desc.isEmpty {
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
        do {
            if let existing = subscription {
                if existing.excludeFromAutoFeedRefresh {
                    // Browse / inactive → activate and move to top of Priority Stack.
                    appState.subscriptionStore.activateAndMoveToTop(subscriptionID: existing.id)
                }
            } else {
                // No subscription at all (rare — feed still loading when tapped).
                let feed: ParsedFeed
                if let loaded = viewModel.loadedFeed {
                    feed = loaded
                } else {
                    feed = try await EpisodeFeedLoader().fetch(feedURL: result.feedURL, limit: 50)
                }
                _ = try appState.subscriptionStore.add(parsedFeed: feed, feedURL: result.feedURL)
            }
        } catch SubscriptionStoreError.duplicateFeed {
            // Already subscribed — nothing to do.
        } catch { }
        isSubscribing = false
    }

    // MARK: - Helpers

    private func statusKind(for episode: Episode) -> EpisodeStatusKind {
        switch episode.playedState {
        case .playing:
            return appState.currentPlayerEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
        case .played:   return .played
        case .archived: return .archived
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

// MARK: - HTML stripping (regex-only — safe in SwiftUI view updates)

private func stripHTMLPreview(_ html: String) -> String {
    let withoutTags = html.replacingOccurrences(
        of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression
    )
    return decodeHTMLEntitiesPreview(withoutTags)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func decodeHTMLEntitiesPreview(_ text: String) -> String {
    var result = text
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
    for (entity, replacement) in namedHTMLEntitiesPreview {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
}

private let namedHTMLEntitiesPreview: [(String, String)] = [
    ("&amp;",   "&"),  ("&lt;",    "<"),  ("&gt;",    ">"),
    ("&quot;",  "\""), ("&apos;",  "'"),  ("&nbsp;",  " "),
    ("&mdash;", "—"),  ("&ndash;", "–"),  ("&rsquo;", "\u{2019}"),
    ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
    ("&hellip;","\u{2026}"), ("&bull;",  "\u{2022}"), ("&copy;",  "\u{00A9}"),
    ("&reg;",   "\u{00AE}"), ("&trade;", "\u{2122}"), ("&euro;",  "\u{20AC}"),
    ("&pound;", "\u{00A3}"), ("&yen;",   "\u{00A5}"), ("&cent;",  "\u{00A2}"),
]
