import SwiftUI

// AI CONTEXT — Views/PodcastDetailView.swift
// Single "Podcast Detail" page, the merge of the old PodcastPreviewView and
// SubscriptionEpisodesView. Works for every podcast state:
//   • a search result not yet subscribed (init(result:))
//   • a browse-only preview subscription (init(browseSubscription:))
//   • a real subscription (init(subscriptionID:)), including Inactive podcasts
//     whose auto feed refresh is paused
// Layout: responsive Header-SubscriptionPage. Containers below 600 points use
// the space-efficient iPhone composition: artwork at top-leading with title,
// badges, description and metadata beside it. Wide iPad/Mac containers use a
// centred stacked hero because they can afford that height without starving
// the episode list. The explicit width policy avoids `ViewThatFits` choosing a
// tall layout merely because a long podcast title has a large ideal width.
// The HTML-stripped description uses a deterministic expandable control rather
// than nested geometry probes, so resizing does not create measurement churn.
// Header content remains capped by the page's shared readable-width policy.
// Structure: artwork · title · VideoPillLarge/ExplicitPillLarge · expandable
// description · author/categories ·
// subscribeRow (Subscribe⇄Unsubscribe button, plus a per-podcast new-episode
// notification bell shown beside it for real subscriptions, bound to
// Subscription.notificationsEnabled)
// · "Episodes" list of ListRow-EpisodeRow (badges as top-trailing overlay per
// DESIGN.md) pushing EpisodeDetailView, with leading (Play / Play Next) and
// trailing (far-right Download/Archive · Play Last) swipes — NO share swipe.
// Episode runtime/remaining labels use episodeListTimeLabel(_:) across every
// device size; positive values below one minute must be rendered in seconds.
// The trailing FAR-RIGHT button follows the download state: a DOWNLOADED episode
// shows Archive (purple, archivebox); an un-downloaded episode on a subscribed +
// ACTIVE feed shows Download (teal, arrow.down.circle) which downloads into the Up
// Next queue at its priority-sorted position (no play). On non-subscribed previews
// or Inactive subscriptions (Download must not appear there) the far-right button
// falls back to the original Archive/Unarchive. Unarchive is otherwise only on the
// Episode Detail page. For an
// real subscription, not-downloaded rows that Download Feed Filters currently exclude
// show the grey Skipped status pill while swipe/manual actions still work. The
// feed-refresh button sits on the "Episodes" heading row
// (small purple circular glass button, matching the Subscriptions page) and the
// toolbar shows Show Settings. Inactive subscriptions are still real
// subscriptions: they show Subscribed/Unsubscribe, Settings, notifications, and
// manual Refresh Feed; only automatic/feed-all refresh skips them. The share
// button and mini-player bar are always present. First-open search previews
// create a browse subscription after feed load; failures are logged as
// podcast.previewCreateFailed instead of being silently swallowed. Episode rows pass 44 pt target
// sizes into CachedArtworkImage and lazily prefetch artwork around the visible
// row window (next 12, previous 3) using ArtworkImageCache.prefetch; distant
// prefetches are cancelled so long feeds with many distinct episode images do
// not compete with on-screen artwork loads.
// BACK CONTRACT (2026-08-29): the custom Back control always calls the ambient
// SwiftUI dismiss action. Podcast Detail can be a child of Subscriptions,
// Discover/Search/chart pages, or RootView itself; dismiss removes exactly that
// nearest destination, whereas mutating RootView's outer path skips its parent.
// TAP-CRASH HISTORY: intermittent (~50%) crashes when tapping an episode row to
// push EpisodeDetailView had TWO independent causes. (1) duplicate ForEach IDs —
// fixed at the source in updateEpisodes plus the defensive dedupe below;
// (2) the REAL persistent one, fixed July 2026: EpisodeDetailView's description
// card (HTMLDescriptionText in PlayerView.swift) ran the WebKit-backed
// NSAttributedString HTML importer synchronously inside `body` during the push
// transition — illegal during layout and intermittently fatal. It now parses in
// `.task`. If this crash ever resurfaces, look for NEW in-body HTML imports, not
// for ID duplicates.

struct PodcastDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator
    /// Progress ticks publish on this dedicated model (not AppState) — reading
    /// appState.downloadProgress in body would render stale.
    @EnvironmentObject private var downloadProgressModel: DownloadProgressModel
    @Environment(\.displayScale) private var displayScale

    // Identity — at most one of these is set per entry point.
    private let searchResult: PodcastSearchResult?
    private let directSubscriptionID: UUID?

    @StateObject private var viewModel: PodcastPreviewViewModel
    @State private var isSubscribing = false
    @State private var isRefreshing = false
    @State private var isLoadingOlderEpisodes = false
    @State private var episodeToShare: Episode?
    @State private var showPodcastShare = false
    @State private var showExpandedArtwork = false
    @State private var showUnsubscribeConfirm = false
    /// Whether the header show-description is expanded to its full untruncated text.
    @State private var descriptionExpanded = false
    /// The episode whose row is tap-expanded to show its full title + description.
    @State private var expandedEpisodeID: UUID?
    @State private var prefetchedArtworkURLs: Set<URL> = []
    /// Header/feed-URL fallback captured from the subscription so the page stays
    /// populated (and re-subscribable) after the user taps Unsubscribe.
    @State private var snapshot: PodcastSearchResult?
    @State private var contentWidth: CGFloat = 390

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
           let sub = subscriptionStore.subscription(id: directSubscriptionID) {
            return sub
        }
        if let url = feedURL {
            return subscriptionStore.subscriptions.first { $0.feedURL == url }
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
            if let sub = subscriptionStore.subscriptions.first(where: { $0.feedURL == url }) {
                if sub.browseDate != nil {
                    // Returning visitor to a browse-only preview: reset the 30-day
                    // clock and refresh episodes so new content appears.
                    subscriptionStore.refreshBrowseDate(subscriptionID: sub.id)
                    await appState.refreshSubscription(sub)
                }
            } else if searchResult != nil {
                // First visit to a search result: fetch the feed, create the preview.
                await viewModel.load()
                if let feed = viewModel.loadedFeed {
                    do {
                        try subscriptionStore.addPreviewSubscription(
                            parsedFeed: feed,
                            feedURL: url
                        )
                    } catch {
                        AppLogger.shared.warning("podcast.previewCreateFailed", "Could not create podcast preview", metadata: [
                            "feedHost": url.host ?? "unknown",
                            "error": String(describing: error)
                        ])
                    }
                }
            }
        }
        .onAppear {
            // Teach episode swipe actions — but only once the user has a real
            // subscription, so it never competes with the Subscribe button on a
            // brand-new user's first preview.
            if onboardingCoordinator.realSubscriptionCount > 0 { onboardingCoordinator.requestTip(.swipeActions) }
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
        .sheet(isPresented: $showPodcastShare) {
            if let subscription {
                PodcastShareSheet(subscription: subscription)
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(subscription?.title ?? "this podcast")?",
            isPresented: $showUnsubscribeConfirm,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                if let id = subscription?.id {
                    subscriptionStore.remove(subscriptionID: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationBackButton()
        }

        if isRealSubscription {
            // Feed refresh lives above the episode list (see `episodesHeader`), to
            // match the Subscriptions page. The toolbar keeps Share + Settings.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPodcastShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .responsiveToolbarSymbol()
            }
                .disabled(subscription == nil)
                .accessibilityLabel("Share Podcast")
            }

            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    if let id = subscription?.id {
                        SubscriptionSettingsView(subscriptionID: id)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .responsiveToolbarSymbol()
                }
                .accessibilityLabel("Show Settings")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPodcastShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .responsiveToolbarSymbol()
            }
                .disabled(subscription == nil)
                .accessibilityLabel("Share Podcast")
            }
        }
    }

    // MARK: - Main content

    private var content: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                header(containerWidth: max(0, proxy.size.width - 40))
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
                    .episodeListPageWidth()
                    .padding(.bottom, 18)
            }
            .environment(\.adaptiveViewportWidth, proxy.size.width)
            .onAppear { contentWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in contentWidth = width }
        }
        .adaptiveContentWidth(.list)
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
        .responsiveListSizing()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .glassCard(cornerRadius: 16)
    }

    // MARK: - Header

    private func header(containerWidth: CGFloat) -> some View {
        let sub = subscription
        let fallback = searchResult ?? snapshot
        let artworkURL: URL? = sub?.artworkURL ?? fallback?.artworkURL
        let title: String = sub?.title ?? fallback?.title ?? ""
        let author: String? = sub?.author ?? (fallback?.author.isEmpty == false ? fallback?.author : nil)
        let description: String? = sub?.description
        let categories: [String] = sub?.categories ?? (fallback?.genre).map { $0.isEmpty ? [] : [$0] } ?? []
        let showVideo: Bool = sub?.newestEpisode?.mediaKind == .video
        let showExplicit: Bool = sub?.isExplicit == true

        let cleanedDescription = description.map(stripHTML)

        let wideMetrics = AdaptiveEditorialMetrics(containerWidth: containerWidth)
        let usesWideHero = wideMetrics.usesCenteredPodcastHeader
        let compactArtworkSize: CGFloat = containerWidth < 320 ? 108 : 128
        let wideArtworkSize = min(wideMetrics.scaled(144), 188)

        return VStack(alignment: .leading, spacing: 16) {
            if usesWideHero {
                VStack(spacing: wideMetrics.scaled(12)) {
                    headerArtwork(url: artworkURL, size: wideArtworkSize)
                    headerIdentity(
                        title: title,
                        showVideo: showVideo,
                        showExplicit: showExplicit,
                        centered: true
                    )
                    if let desc = cleanedDescription, !desc.isEmpty {
                        headerDescription(desc, centered: true)
                    }
                    headerMetadata(author: author, categories: categories, centered: true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: containerWidth < 320 ? 12 : 16) {
                    headerArtwork(url: artworkURL, size: compactArtworkSize)

                    VStack(alignment: .leading, spacing: 8) {
                        headerIdentity(
                            title: title,
                            showVideo: showVideo,
                            showExplicit: showExplicit,
                            centered: false
                        )
                        if let desc = cleanedDescription, !desc.isEmpty {
                            headerDescription(desc, centered: false)
                        }
                        headerMetadata(author: author, categories: categories, centered: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            subscribeRow
        }
        .frame(maxWidth: .infinity)
        // One presentation owner remains outside both responsive compositions,
        // preventing two conditional artwork branches from owning one sheet.
        .sheet(isPresented: $showExpandedArtwork) {
            ExpandedArtworkSheet(url: artworkURL)
        }
    }

    private func headerArtwork(url: URL?, size: CGFloat) -> some View {
        CachedArtworkImage(url: url, targetSize: CGSize(width: size, height: size)) {
            ZStack {
                LinearGradient(
                    colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { showExpandedArtwork = true }
    }

    @ViewBuilder
    private func headerIdentity(
        title: String,
        showVideo: Bool,
        showExplicit: Bool,
        centered: Bool
    ) -> some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: contentWidth)
        VStack(alignment: centered ? .center : .leading, spacing: metrics.scaled(8)) {
            Text(title)
                .font(.system(size: metrics.detailTitleFontSize, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            if showVideo || showExplicit {
                HStack(spacing: 6) {
                    if showVideo { VideoPillLarge() }
                    if showExplicit { ExplicitPillLarge() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func headerDescription(_ description: String, centered: Bool) -> some View {
        let canExpand = description.count > 180
        let metrics = AdaptiveEditorialMetrics(containerWidth: contentWidth)

        return VStack(alignment: centered ? .center : .leading, spacing: metrics.scaled(6)) {
            Text(description)
                .font(.system(size: metrics.detailDescriptionFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 3)
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)

            if canExpand {
                Button(descriptionExpanded ? "Show Less" : "Show More") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        descriptionExpanded.toggle()
                    }
                }
                .font(.system(size: metrics.detailDescriptionFontSize, weight: .semibold))
                .foregroundStyle(Color.purple)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func headerMetadata(author: String?, categories: [String], centered: Bool) -> some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: contentWidth)
        return VStack(alignment: centered ? .center : .leading, spacing: metrics.scaled(2)) {
            if let author {
                Text(author)
                    .font(.system(size: metrics.detailPublisherFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if !categories.isEmpty {
                Text(categories.joined(separator: ", "))
                    .font(.system(size: metrics.detailDescriptionFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    @ViewBuilder
    private var subscribeButton: some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: contentWidth)
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
                        .font(.system(size: metrics.primaryButtonFontSize, weight: .semibold))
                } else {
                    Label("Subscribe", systemImage: "plus.circle.fill")
                        .font(.system(size: metrics.primaryButtonFontSize, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: metrics.primaryButtonHeight)

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

    /// New-episode notification toggle, shown beside the Subscribe button for a
    /// real subscription, including Inactive shows. Bound to
    /// `Subscription.notificationsEnabled`.
    @ViewBuilder
    private var bellButton: some View {
        if let sub = subscription, isRealSubscription {
            let enabled = sub.notificationsEnabled
            let metrics = AdaptiveEditorialMetrics(containerWidth: contentWidth)
            Button {
                subscriptionStore.updateNotificationsEnabled(subscriptionID: sub.id, enabled: !enabled)
            } label: {
                let icon = Image(systemName: enabled ? "bell.fill" : "bell.slash")
                    .font(.system(size: metrics.primaryButtonFontSize))
                    .foregroundStyle(enabled ? Color.purple : .secondary)
                    .frame(width: metrics.primaryButtonHeight, height: metrics.primaryButtonHeight)

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
        HStack(spacing: AdaptiveEditorialMetrics(containerWidth: contentWidth).scaled(12)) {
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
                        playbackCoordinator.currentEpisode?.id == episode.id
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
        let metrics = AdaptiveListRowMetrics(containerWidth: contentWidth)
        let artworkSize = metrics.artworkSize
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: metrics.rowSpacing) {
                CachedArtworkImage(url: episode.artworkURL ?? sub.artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
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
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.system(size: metrics.primaryFontSize, weight: .semibold))
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
                            .font(.system(size: metrics.secondaryFontSize))
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
                        EpisodeStatusPill(kind: statusKind(for: episode, sub: sub))
                    }
                    .font(.system(size: metrics.secondaryFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if episode.downloadState == .downloading,
               let progress = downloadProgressModel.progress[episode.id] {
                ProgressView(value: progress, total: 1.0)
                    .tint(.purple)
                    .animation(.linear(duration: 0.3), value: progress)
                    .padding(.leading, artworkSize + metrics.rowSpacing)
                    .padding(.top, 6)
            }

        }
        .padding(.vertical, metrics.verticalPadding)
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
        let isCurrentlyPlaying = playbackCoordinator.currentEpisode?.id == episode.id
        if !isCurrentlyPlaying {
            Button {
                Task {
                    if episode.downloadState != .downloaded {
                        await appState.downloadEpisodeForQueue(episode)
                    }
                    if let updated = subscriptionStore.episode(subscriptionID: sub.id, episodeID: episode.id) {
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
        let isCurrentlyPlaying = playbackCoordinator.currentEpisode?.id == episode.id
        if !isCurrentlyPlaying {
            // Far-right (edge) button. Global rules: a DOWNLOADED episode always offers
            // Archive; an un-downloaded episode on a subscribed + ACTIVE feed offers
            // Download (teal). For non-subscribed previews or Inactive subscriptions
            // (where Download must not appear) it falls back to the original
            // Archive/Unarchive so those rows keep an archive control.
            if episode.downloadState == .downloaded {
                Button {
                    Task { await appState.archiveEpisode(episode) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.purple)
            } else if isRealSubscription, !sub.excludeFromAutoFeedRefresh {
                Button {
                    Task { await appState.downloadEpisodeForQueue(episode) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.teal)
            } else if episode.playedState == .archived || episode.playedState == .played {
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
                    subscriptionStore.activateAndMoveToTop(subscriptionID: existing.id)
                }
            } else if let url = feedURL {
                // No subscription at all — fetch the feed (if needed) and add it.
                let feed: ParsedFeed
                if let loaded = viewModel.loadedFeed {
                    feed = loaded
                } else {
                    feed = try await EpisodeFeedLoader().fetch(feedURL: url, limit: 50)
                }
                _ = try subscriptionStore.add(parsedFeed: feed, feedURL: url)
            }
        } catch SubscriptionStoreError.duplicateFeed {
            // Already subscribed — nothing to do.
        } catch {}
    }

    // MARK: - Helpers

    private func statusKind(for episode: Episode, sub: Subscription) -> EpisodeStatusKind {
        switch episode.playedState {
        case .playing:
            return playbackCoordinator.currentEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
        case .played:   return .played
        case .archived: return episode.wasCompleted ? .played : .archived
        case .unplayed:
            let position = appState.effectivePlaybackTime(for: episode)
            if position > 0 { return .partiallyPlayed }
            if episode.downloadState == .notDownloaded,
               sub.downloadFilterSettings.evaluation(for: episode).isIncluded == false {
                return .skipped
            }
            return episode.downloadState == .downloaded ? .queued : .unplayed
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        episodeListTimeLabel(seconds)
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
