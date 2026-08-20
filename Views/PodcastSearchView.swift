import SwiftUI

// AI CONTEXT — Views/PodcastSearchView.swift (dedicated "Search" page pushed
// from Discover). Search uses independent storefront-aware Apple providers for
// shows and episodes, rendered as visibly separate sections. An All / My
// Library scope keeps the local path synchronous and network-independent.
// Publisher/creator groups come only from cleaned exact author metadata; this
// surface must not infer hosts or guests. Do not collapse
// these back into one flat list: a show is a subscribable RSS identity, while
// an Apple episode must first reconcile to the RSS-owned episode by GUID (exact
// normalized title is the narrow fallback) before EpisodeDetailView opens.
// Search uses a 400 ms debounce; idle state shows
// Recently Viewed (browse subscriptions, browseDate != nil, newest first) and
// an Enter RSS URL link to AddFeedView. Opening a result creates/refreshes an
// invisible BROWSE subscription (30-day retention clock resets per visit) so
// the preview's episode list is fully interactive — play/queue/archive —
// before subscribing. Opening a result navigates to PodcastDetailView, which
// renders both the preview and subscribed states (Subscribe⇄Unsubscribe);
// Inactive podcasts are still real subscriptions and route to Settings/manual
// Refresh instead of the browse preview.
// Lifecycle rules: PAGES.md "Browse Subscription Lifecycle" + FEATURES.md §2.
// Search and Recently Viewed rows use 44 pt CachedArtworkImage thumbnails so
// catalog/browse art participates in the same shared downsampled cache.
// NAVIGATION CONTRACT: Search and show-detail pages append typed AppRoute
// values to RootView's one NavigationPath. Do not reintroduce closure-only or
// local-item destinations here: the mini-player must be able to clear the root
// path from every search descendant, and Back must always reveal Search rather
// than an orphaned local destination. Search requests focus after its push
// transition so the first tap on Discover's search control opens the keyboard.
// MARK: - Dedicated Search page

struct PodcastSearchView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case library = "My Library"
        var id: Self { self }
    }

    @StateObject private var viewModel = PodcastSearchViewModel()
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var query = ""
    @State private var scope: Scope = .all
    @FocusState private var isSearchFieldFocused: Bool
    let countryCode: String

    private var recentlyViewed: [Subscription] {
        subscriptionStore.subscriptions
            .filter { $0.browseDate != nil }
            .sorted { ($0.browseDate ?? .distantPast) > ($1.browseDate ?? .distantPast) }
    }

    private var localResults: PodcastLibrarySearchResults {
        PodcastLibrarySearch.search(subscriptionStore.subscriptions, query: query)
    }

    private var localCreatorGroups: [PodcastCreatorGroup] {
        PodcastLibrarySearch.creatorGroups(from: subscriptionStore.subscriptions, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    idleState
                } else {
                    searchResults
                }
            }
        }
        .task {
            // This page owns a real TextField, so focus is deterministic on
            // iOS 17 and does not depend on UISearchController installation.
            await Task.yield()
            isSearchFieldFocused = true
        }
        .onChange(of: query) { _, new in
            if scope == .all {
                viewModel.queryChanged(new, countryCode: countryCode)
            }
        }
        .onChange(of: scope) { _, newScope in
            if newScope == .all {
                viewModel.queryChanged(query, countryCode: countryCode)
            } else {
                viewModel.cancelSearch()
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // AI CONTEXT — A visible search action provides one pointer and
                // keyboard focus target. Do not add an invisible Cmd-F button:
                // that would create a duplicate accessibility/focus destination.
                Button {
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Focus search field")
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Shows, episodes, publishers…", text: $query)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
                                NavigationLink(value: podcastSearchRoute(
                                    for: directoryResult(sub),
                                    in: subscriptionStore
                                )) {
                                    recentlyViewedRow(sub)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                                if sub.id != recentlyViewed.last?.id {
                                    Divider().padding(.leading, 76)
                                }
                            }
                        }
                        .glassCard(cornerRadius: 16)
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

    // MARK: Separated results

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Picker("Search scope", selection: $scope) {
                    ForEach(Scope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                showsSection
                episodesSection
                creatorsSection

                NavigationLink { AddFeedView() } label: {
                    Label("Can't find it? Enter an RSS URL", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
            .adaptiveContentWidth(.list)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var showsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            resultSectionHeader("Shows", systemImage: "dot.radiowaves.left.and.right")
            if scope == .library {
                let results = localResults.shows.map(directoryResult)
                if results.isEmpty {
                    sectionMessage("No matching shows in My Library", systemImage: "waveform.slash")
                } else {
                    showResultsRail(results)
                }
            } else {
                switch viewModel.showsPhase {
                case .idle, .loading:
                    sectionLoading("Searching shows…")
                case .empty:
                    sectionMessage("No matching shows", systemImage: "waveform.slash")
                case .failed:
                    sectionMessage("Shows are temporarily unavailable", systemImage: "exclamationmark.triangle")
                case .results(let results):
                    showResultsRail(results)
                }
            }
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            resultSectionHeader("Episodes", systemImage: "list.bullet.rectangle.portrait")
            if scope == .library {
                let results = localResults.episodes
                if results.isEmpty {
                    sectionMessage("No matching episodes in My Library", systemImage: "text.magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { episode in
                            NavigationLink {
                                EpisodeDetailView(
                                    subscriptionID: episode.subscriptionID,
                                    episodeID: episode.id
                                )
                            } label: {
                                libraryEpisodeResultRow(episode)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            if episode.id != results.last?.id { Divider().padding(.leading, 72) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 16)
                    .padding(.horizontal, 12)
                }
            } else {
                switch viewModel.episodesPhase {
                case .idle, .loading:
                    sectionLoading("Searching episodes…")
                case .empty:
                    sectionMessage("No matching episodes", systemImage: "text.magnifyingglass")
                case .failed:
                    sectionMessage("Episodes are temporarily unavailable", systemImage: "exclamationmark.triangle")
                case .results(let results):
                LazyVStack(spacing: 0) {
                    ForEach(results) { episode in
                        NavigationLink {
                            PodcastEpisodeSearchDestination(result: episode)
                        } label: {
                            episodeResultRow(episode)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        if episode.id != results.last?.id { Divider().padding(.leading, 72) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 16)
                .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var creatorsSection: some View {
        let groups = scope == .library ? localCreatorGroups : remoteCreatorGroups
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                resultSectionHeader("Publishers & Creators", systemImage: "person.2")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(groups.prefix(12)) { group in
                            NavigationLink {
                                PodcastCreatorResultsView(group: group)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("\(group.shows.count) \(group.shows.count == 1 ? "show" : "shows")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minWidth: 150, maxWidth: 230, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassCard(cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var remoteCreatorGroups: [PodcastCreatorGroup] {
        guard case .results(let shows) = viewModel.showsPhase else { return [] }
        return PodcastCreatorGrouping.groups(from: shows, query: query)
    }

    /// Card width follows the current scroll viewport: compact phones see one
    /// comfortably readable card plus a hint of the next, while larger phones
    /// and iPad avoid both cramped titles and comically wide cards.
    private func showResultsRail(_ results: [PodcastSearchResult]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(results) { result in
                    NavigationLink(value: podcastSearchRoute(
                        for: result,
                        in: subscriptionStore
                    )) {
                        showResultRow(result)
                            .containerRelativeFrame(.horizontal) { available, _ in
                                min(max(available * 0.84, 300), 440)
                            }
                            .glassCard(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func resultSectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20)
    }

    private func sectionLoading(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 12)
    }

    private func sectionMessage(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, 12)
    }

    private func showResultRow(_ result: PodcastSearchResult) -> some View {
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 92)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func episodeResultRow(_ result: PodcastEpisodeSearchResult) -> some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: result.artworkURL, targetSize: CGSize(width: 48, height: 48)) {
                artworkPlaceholder(size: 15)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(result.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let date = result.releaseDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let duration = result.duration, duration > 0 {
                        if result.releaseDate != nil { Text("•") }
                        Text(formatEpisodeDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func libraryEpisodeResultRow(_ result: PodcastLibraryEpisodeSearchResult) -> some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: result.artworkURL, targetSize: CGSize(width: 48, height: 48)) {
                artworkPlaceholder(size: 15)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(result.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let date = result.releaseDate { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                    if let duration = result.duration, duration > 0 {
                        if result.releaseDate != nil { Text("•") }
                        Text(formatEpisodeDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func directoryResult(_ subscription: Subscription) -> PodcastSearchResult {
        PodcastSearchResult(
            id: subscription.feedURL.absoluteString.hashValue,
            title: subscription.title,
            author: subscription.author ?? "",
            feedURL: subscription.feedURL,
            artworkURL: subscription.artworkURL,
            episodeCount: subscription.episodes.count,
            genre: subscription.categories.first ?? ""
        )
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

    private func formatEpisodeDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr" }
        return "\(minutes) min"
    }
}

private struct PodcastCreatorResultsView: View {
    let group: PodcastCreatorGroup
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(group.shows) { show in
                    NavigationLink(value: podcastSearchRoute(
                        for: show,
                        in: subscriptionStore
                    )) {
                        HStack(spacing: 14) {
                            CachedArtworkImage(url: show.artworkURL, targetSize: CGSize(width: 64, height: 64)) {
                                Image(systemName: "waveform")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.purple.opacity(0.25))
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(show.title).font(.headline).lineLimit(2)
                                if !show.genre.isEmpty {
                                    Text(show.genre).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(16)
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

/// Resolves a show search hit to a stable root route. Real subscriptions use
/// their durable UUID; browse-only and remote results retain the Apple result
/// so PodcastDetailView can refresh/create the existing preview by feed URL.
@MainActor
private func podcastSearchRoute(
    for result: PodcastSearchResult,
    in subscriptionStore: SubscriptionStore
) -> AppRoute {
    if let subscription = subscriptionStore.subscriptions.first(where: {
        $0.feedURL == result.feedURL && $0.browseDate == nil
    }) {
        return .podcast(subscriptionID: subscription.id)
    }
    return .podcastPreview(result)
}


/// Bridges an Apple episode search hit to Autohop's RSS-owned Episode Detail
/// page. Apple and RSS identifiers are separate namespaces, so reconciliation
/// uses Apple's episode GUID when present and only falls back to an exact,
/// normalized episode-title match. It never invents an episode identity from a
/// track ID or fuzzy prose match.
private struct PodcastEpisodeSearchDestination: View {
    private enum Phase {
        case loading
        case found(subscriptionID: UUID, episodeID: UUID)
        case unavailable
    }

    let result: PodcastEpisodeSearchResult
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @StateObject private var previewModel: PodcastPreviewViewModel
    @State private var phase: Phase = .loading

    init(result: PodcastEpisodeSearchResult) {
        self.result = result
        _previewModel = StateObject(wrappedValue: PodcastPreviewViewModel(feedURL: result.feedURL))
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Opening episode…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .found(let subscriptionID, let episodeID):
                EpisodeDetailView(subscriptionID: subscriptionID, episodeID: episodeID)
            case .unavailable:
                ContentUnavailableView {
                    Label("Episode Unavailable", systemImage: "waveform.slash")
                } description: {
                    Text("This Apple result could not be matched safely to an episode in the podcast's RSS feed.")
                } actions: {
                    NavigationLink {
                        if let subscription = subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL }) {
                            PodcastDetailView(subscriptionID: subscription.id)
                        } else {
                            PodcastDetailView(result: result.parentPodcast)
                        }
                    } label: {
                        Text("Open Podcast")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolveEpisode() }
    }

    @MainActor
    private func resolveEpisode() async {
        if let existing = subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL }),
           let episode = PodcastEpisodeReconciliation.matchingEpisode(result: result, in: existing) {
            phase = .found(subscriptionID: existing.id, episodeID: episode.id)
            return
        }

        if let existing = subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL }) {
            // Use the established refresh/merge path so RSS values preserve
            // local playback, archive and download state correctly.
            await appState.refreshSubscription(existing)
            if let refreshed = subscriptionStore.subscription(id: existing.id),
               let episode = PodcastEpisodeReconciliation.matchingEpisode(result: result, in: refreshed) {
                phase = .found(subscriptionID: refreshed.id, episodeID: episode.id)
            } else {
                phase = .unavailable
            }
            return
        }

        await previewModel.load()
        guard let feed = previewModel.loadedFeed else {
            phase = .unavailable
            return
        }

        let subscription: Subscription
        if subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL }) == nil {
            do {
                subscription = try subscriptionStore.addPreviewSubscription(parsedFeed: feed, feedURL: result.feedURL)
            } catch {
                guard let existing = subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL }) else {
                    phase = .unavailable
                    return
                }
                subscription = existing
            }
        } else {
            guard let existing = subscriptionStore.subscriptions.first(where: { $0.feedURL == result.feedURL }) else {
                phase = .unavailable
                return
            }
            subscription = existing
        }

        guard let episode = PodcastEpisodeReconciliation.matchingEpisode(result: result, in: subscription) else {
            phase = .unavailable
            return
        }
        phase = .found(subscriptionID: subscription.id, episodeID: episode.id)
    }

}
