import SwiftUI

// AI CONTEXT — Views/PodcastDetailView.swift
// Single "Podcast Detail" page, the merge of the old PodcastPreviewView and
// SubscriptionEpisodesView. Works for every podcast state:
//   • a search result not yet subscribed (init(result:))
//   • a browse-only preview subscription (init(browseSubscription:))
//   • a real subscription (init(subscriptionID:)), including Inactive podcasts
//     whose auto feed refresh is paused
// Layout: centred Header-SubscriptionPage (artwork · title · VideoPillLarge/
// ExplicitPillLarge · expandable "…more" description · author/categories) ·
// subscribeRow (Subscribe⇄Unsubscribe button, plus a per-podcast new-episode
// notification bell shown beside it for real subscriptions, bound to
// Subscription.notificationsEnabled)
// · "Episodes" list of ListRow-EpisodeRow (badges as top-trailing overlay per
// DESIGN.md) pushing EpisodeDetailView, with the standard leading (Play / Play
// Next) and trailing (Archive / Play Last) swipes — NO share swipe. For an
// real subscription the feed-refresh button sits on the "Episodes" heading row
// (small purple circular glass button, matching the Subscriptions page) and the
// toolbar shows Show Settings. Inactive subscriptions are still real
// subscriptions: they show Subscribed/Unsubscribe, Settings, notifications, and
// manual Refresh Feed; only automatic/feed-all refresh skips them. The share
// button and mini-player bar are always present. Episode rows pass 44 pt target
// sizes into CachedArtworkImage and lazily prefetch artwork around the visible
// row window (next 12, previous 3) using ArtworkImageCache.prefetch; distant
// prefetches are cancelled so long feeds with many distinct episode images do
// not compete with on-screen artwork loads.

struct PodcastDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

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
    /// Whether the header show-description is expanded to its full untruncated text.
    @State private var descriptionExpanded = false
    /// True only when the show-description is long enough to be truncated at 3
    /// lines — drives whether the "…more" toggle is shown at all.
    @State private var descriptionTruncated = false
    /// The episode whose row is tap-expanded to show its full title + description.
    @State private var expandedEpisodeID: UUID?
    @State private var prefetchedArtworkURLs: Set<URL> = []
    /// Header/feed-URL fallback captured from the subscription so the page stays
    /// populated (and re-subscribable) after the user taps Unsubscribe.
    @State private var snapshot: PodcastSearchResult?

    private let rowArtworkSize = CGSize(width: 44, height: 44)
    private let artworkPrefetchForwardCount = 12
    private let artworkPrefetchBackCount = 3

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

    /// From an existing real subscription ID, including Inactive subscriptions.
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

    /// True for a real subscription. Inactive/excluded shows still count; only
    /// browse previews have `browseDate != nil` and behave as not-yet-subscribed.
    private var isRealSubscription: Bool {
        guard let subscription else { return false }
        return subscription.browseDate == nil
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
        .onAppear {
            // Teach episode swipe actions — but only once the user has a real
            // subscription, so it never competes with the Subscribe button on a
            // brand-new user's first preview.
            if appState.realSubscriptionCount > 0 { appState.requestTip(.swipeActions) }
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

        if isRealSubscription {
            // Feed refresh lives above the episode list (see `episodesHeader`), to
            // match the Subscriptions page. The toolbar keeps Share + Settings.
            ToolbarItem(placement: .topBarTrailing) {
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

                Spacer()

                // Feed refresh — small purple circular glass button above the
                // episode list, matching the Subscriptions page. Real
                // subscriptions only, including Inactive; browse previews aren't
                // refreshed here.
                if isRealSubscription {
                    refreshButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            episodeListCard
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
    }

    /// Small purple circular refresh button shown on the Episodes heading row,
    /// styled to match the Subscriptions page's refresh-all control.
    private var refreshButton: some View {
        Button {
            guard let subscription, !isRefreshing else { return }
            isRefreshing = true
            Task {
                await appState.refreshSubscription(subscription)
                isRefreshing = false
            }
        } label: {
            let refreshIcon = Group {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }
            .frame(width: 30, height: 30)

            if #available(iOS 26, *) {
                refreshIcon.glassEffect(in: Circle())
            } else {
                refreshIcon.background(.ultraThinMaterial, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh Feed")
    }

    /// The Episodes list inside an iOS-glass card, matching the bell button and
    /// toolbar capsule.
    @ViewBuilder
    private var episodeListCard: some View {
        List {
            episodeContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .glassCard(cornerRadius: 16)
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

        return VStack(alignment: .leading, spacing: 16) {
            // Top band: artwork on the left, title + pills stacked to its right.
            HStack(alignment: .top, spacing: 16) {
                CachedArtworkImage(url: artworkURL, targetSize: CGSize(width: 128, height: 128)) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .onTapGesture { showExpandedArtwork = true }
                .sheet(isPresented: $showExpandedArtwork) {
                    ExpandedArtworkSheet(url: artworkURL)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Video / Explicit pills below the title.
                    if showVideo || showExplicit {
                        HStack(spacing: 6) {
                            if showVideo { VideoPillLarge() }
                            if showExplicit { ExplicitPillLarge() }
                        }
                    }

                    // Description sits in the right column beside the artwork, with
                    // an inline purple "…more"/"…less" toggle.
                    if let desc = description.map(stripHTML), !desc.isEmpty {
                        Group {
                            if descriptionExpanded {
                                // Full text with an inline "…less" toggle.
                                Text(desc)
                                    .foregroundColor(.secondary)
                                + Text("  …less")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.purple)
                            } else {
                                // Truncated to 3 lines. The inline "…more" is only
                                // overlaid when the text actually overflows.
                                Text(desc)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .overlay(alignment: .bottomTrailing) {
                                        if descriptionTruncated {
                                            Text("…more")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(Color.purple)
                                                .padding(.leading, 28)
                                                .background(Color.black)
                                        }
                                    }
                            }
                        }
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(descriptionTruncationProbe(desc))
                        .onPreferenceChange(DescriptionTruncationKey.self) { descriptionTruncated = $0 }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard descriptionTruncated else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                descriptionExpanded.toggle()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 2) {
                if let author {
                    Text(author)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if !categories.isEmpty {
                    Text(categories.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)

            subscribeRow
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var subscribeButton: some View {
        Button {
            if isRealSubscription {
                showUnsubscribeConfirm = true
            } else {
                Task { await subscribe() }
            }
        } label: {
            let content = Group {
                if isSubscribing {
                    ProgressView().tint(.white)
                } else if isRealSubscription {
                    Label("Subscribed", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                } else {
                    Label("Subscribe", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)

            // Purple-tinted iOS glass to match the glass bell/toolbar capsule.
            if #available(iOS 26, *) {
                content.glassEffect(.regular.tint(.purple), in: RoundedRectangle(cornerRadius: 13))
            } else {
                content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
                    .background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .buttonStyle(.plain)
        .disabled(isSubscribing)
    }

    /// Hidden probe that reports whether `desc` overflows 3 lines at the current
    /// width, by comparing the 3-line-limited height to the full height.
    private func descriptionTruncationProbe(_ desc: String) -> some View {
        Text(desc)
            .font(.footnote)
            .lineLimit(3)
            .background(
                GeometryReader { limited in
                    Text(desc)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { full in
                                Color.clear.preference(
                                    key: DescriptionTruncationKey.self,
                                    value: full.size.height > limited.size.height + 1
                                )
                            }
                        )
                        .hidden()
                }
            )
            .hidden()
    }

    /// New-episode notification toggle, shown beside the Subscribe button for a
    /// real subscription, including Inactive shows. Bound to
    /// `Subscription.notificationsEnabled`.
    @ViewBuilder
    private var bellButton: some View {
        if let sub = subscription, isRealSubscription {
            let enabled = sub.notificationsEnabled
            Button {
                appState.subscriptionStore.updateNotificationsEnabled(subscriptionID: sub.id, enabled: !enabled)
            } label: {
                let icon = Image(systemName: enabled ? "bell.fill" : "bell.slash")
                    .font(.subheadline)
                    .foregroundStyle(enabled ? Color.purple : .secondary)
                    .frame(width: 46, height: 46)

                // Match the toolbar capsule / Video-Explicit pills: real iOS glass.
                if #available(iOS 26, *) {
                    icon.glassEffect(in: RoundedRectangle(cornerRadius: 13))
                } else {
                    icon.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(enabled ? "Disable new-episode notifications" : "Enable new-episode notifications")
        }
    }

    /// Subscribe button plus the notification bell, laid out side by side.
    private var subscribeRow: some View {
        HStack(spacing: 12) {
            subscribeButton
            bellButton
        }
    }

    // MARK: - Episode list

    @ViewBuilder
    private var episodeContent: some View {
        if let sub = subscription {
            let rawEpisodes: [Episode] = sub.episodes.isEmpty
                ? sub.latestEpisode.map { [$0] } ?? []
                : sub.episodes
            // Defensive: ForEach over duplicate Identifiable ids crashes on tap.
            // updateEpisodes now prevents duplicates at the source, but episodes
            // persisted before that fix may still contain them, so guarantee
            // uniqueness here too.
            var seenIDs = Set<UUID>()
            let episodes = rawEpisodes.filter { seenIDs.insert($0.id).inserted }

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
                    // Idle rows are clear so the card's glass shows through; the
                    // playing row keeps the faint purple tint.
                    .listRowBackground(
                        appState.currentPlayerEpisode?.id == episode.id
                            ? Color.purple.opacity(0.08)
                            : Color.clear
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        leadingSwipe(episode: episode, sub: sub)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        trailingSwipe(episode: episode, sub: sub)
                    }
                    .onAppear {
                        prefetchEpisodeArtwork(around: episode, episodes: episodes, fallbackURL: sub.artworkURL)
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
                    .listRowBackground(Color.clear)
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
        let isExpanded = expandedEpisodeID == episode.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CachedArtworkImage(url: episode.artworkURL ?? sub.artworkURL, targetSize: CGSize(width: 44, height: 44)) {
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
                        .lineLimit(isExpanded ? nil : 2)
                        // Reserve room on the right so the title never runs under
                        // the floating video/explicit pills.
                        .padding(.trailing, 30)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                expandedEpisodeID = isExpanded ? nil : episode.id
                            }
                        }

                    // Episode description: first 3 lines always visible; tap the
                    // title to expand to the full text.
                    if let desc = episode.description.map(stripHTML), !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 3)
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
                    .padding(.top, 3)
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
                    if episode.mediaKind == .video { VideoPillSmall() }
                    if episode.isExplicit == true { ExplicitPillSmall() }
                }
                // Push the pills out over the trailing nav-arrow column so they sit
                // above the chevron rather than overlapping the headline.
                .offset(x: 18)
            }
        }
    }

    private func prefetchEpisodeArtwork(around episode: Episode, episodes: [Episode], fallbackURL: URL?) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }

        let forwardRange = (index + 1)..<min(episodes.count, index + 1 + artworkPrefetchForwardCount)
        let prefetchURLs = uniqueArtworkURLs(from: forwardRange.map { episodes[$0] }, fallbackURL: fallbackURL)
        let newURLs = prefetchURLs.filter { prefetchedArtworkURLs.insert($0).inserted }

        if !newURLs.isEmpty {
            let scale = displayScale
            let size = rowArtworkSize
            Task {
                await ArtworkImageCache.shared.prefetch(urls: newURLs, targetSize: size, scale: scale)
            }
        }

        cancelDistantArtworkPrefetches(around: index, episodes: episodes, fallbackURL: fallbackURL)
    }

    private func cancelDistantArtworkPrefetches(around index: Int, episodes: [Episode], fallbackURL: URL?) {
        let start = max(0, index - artworkPrefetchBackCount)
        let end = min(episodes.count, index + 1 + artworkPrefetchForwardCount)
        let keepURLs = Set(uniqueArtworkURLs(from: (start..<end).map { episodes[$0] }, fallbackURL: fallbackURL))
        let staleURLs = prefetchedArtworkURLs.subtracting(keepURLs)
        guard !staleURLs.isEmpty else { return }

        prefetchedArtworkURLs.subtract(staleURLs)
        let scale = displayScale
        let size = rowArtworkSize
        Task {
            await ArtworkImageCache.shared.cancelPrefetch(urls: Array(staleURLs), targetSize: size, scale: scale)
        }
    }

    private func uniqueArtworkURLs(from episodes: [Episode], fallbackURL: URL?) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        for episode in episodes {
            guard let url = episode.artworkURL ?? fallbackURL,
                  seen.insert(url).inserted else { continue }
            urls.append(url)
        }
        return urls
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
                if existing.browseDate != nil {
                    // Browse preview → activate and move to top of Priority Stack.
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
        let total = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func formatPublishedDate(_ date: Date) -> String {
        relativePublishedLabel(date)   // shared tiered formatter (EpisodeBadges.swift)
    }
}

// `EpisodeStatusKind` and `EpisodeStatusPill` are shared in Views/EpisodeBadges.swift.

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

/// Reports whether the show-description overflows its 3-line limit.
private struct DescriptionTruncationKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
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
