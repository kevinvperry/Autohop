import SwiftUI

// AI CONTEXT — Views/PodcastsView.swift ("Subscriptions" page — the app's
// home page, see PAGES.md). Ranked list of active subscriptions (browse
// subscriptions filtered out); drag-to-reorder in Reorder mode rewrites
// priorityRank for the whole list. Each row shows artwork, title, and a
// colour-coded status pill for the podcast's latest episode (pills hide in
// Reorder mode so they never fight the drag grips). Pill logic: archived
// episodes show Played (not Archived) when Episode.wasCompleted is true, so
// auto-archive doesn't erase the "you finished this" signal. Toolbar: hamburger menu
// (MenuSheetView) leading, + (DiscoverView sheet — parent of Podcast Search)
// trailing; Reorder and
// refresh-all live on the action row under the heading. MiniPlayerBar docks
// at the bottom except during reorder. Rows navigate to SubscriptionEpisodesView.
struct PodcastsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editMode: EditMode = .inactive
    @State private var isRefreshingAll = false
    @State private var showMenu = false
    @State private var showDiscover = false

    /// Subscriptions visible in the Priority Sort list.
    /// Browse-only subscriptions (browseDate != nil) are invisible here —
    /// they only become visible once the user explicitly presses Subscribe.
    private var visibleSubscriptions: [Subscription] {
        appState.subscriptionStore.subscriptions.filter { $0.browseDate == nil }
    }

    var body: some View {
        Group {
            if visibleSubscriptions.isEmpty {
                ContentUnavailableView(
                    "No Podcasts",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Tap + to search for a podcast or add an RSS feed.")
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Action row — page actions live here, below the heading,
                    // so the title bar stays pure navigation (NavRules).
                    HStack {
                        Button {
                            withAnimation {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        } label: {
                            Label(
                                editMode == .active ? "Done" : "Reorder",
                                systemImage: editMode == .active ? "checkmark" : "arrow.up.arrow.down"
                            )
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                editMode == .active ? Color.purple : Color.white.opacity(0.1),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)

                        if editMode == .active {
                            Text("drag to set priority")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 4)
                        }

                        Spacer()

                        if editMode != .active {
                            Button {
                                refreshAll()
                            } label: {
                                if isRefreshingAll {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                            .disabled(isRefreshingAll)
                            .accessibilityLabel("Refresh all feeds")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                    List {
                        ForEach(visibleSubscriptions) { subscription in
                            let isPlaying = subscription.latestEpisode.map { appState.currentPlayerEpisode?.id == $0.id } ?? false
                            NavigationLink {
                                SubscriptionEpisodesView(subscriptionID: subscription.id)
                            } label: {
                                subscriptionRow(subscription)
                            }
                            .listRowBackground(isPlaying ? Color.purple.opacity(0.08) : Color.white.opacity(0.08))
                            .moveDisabled(editMode != .active)
                        }
                        .onMove { from, to in
                            guard editMode == .active else { return }
                            appState.subscriptionStore.reorder(from: from, to: to)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .environment(\.editMode, $editMode)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showMenu = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDiscover = true
                } label: {
                    Label("Add Podcast", systemImage: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hidden during reorder so the drag operation gets the full list.
            if editMode != .active {
                MiniPlayerBar()
            }
        }
        .sheet(isPresented: $showMenu) { MenuSheetView() }
        .sheet(isPresented: $showDiscover) { DiscoverView() }
    }

    private func refreshAll() {
        isRefreshingAll = true
        Task {
            await appState.refreshAllSubscriptions(includeBackoffFeeds: true)
            isRefreshingAll = false
        }
    }

    private func subscriptionRow(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Top band: artwork + titles
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .center, spacing: 4) {
                    artwork(url: sub.artworkURL)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(sub.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let episode = sub.latestEpisode {
                        Text(episode.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("No episode available")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }

            // Bottom band: rank pill (under artwork) + metadata row (under titles)
            if let episode = sub.latestEpisode {
                HStack(alignment: .center, spacing: 12) {
                    // Rank pill — centred under the artwork; min width 44pt so it
                    // stays aligned with the artwork above for single-digit numbers,
                    // but expands naturally for two- or three-digit numbers.
                    rankPill(sub.priorityRank)
                        .frame(minWidth: 44, alignment: .center)

                    // Metadata: date · duration/remaining · Spacer · status pill
                    HStack(spacing: 4) {
                        if let date = episode.publishedAt {
                            Text(formatPublishedDate(date))
                                .lineLimit(1)
                        }
                        if let duration = episode.durationSeconds {
                            let elapsed = appState.effectivePlaybackTime(for: episode)
                            let remaining = elapsed > 0 ? max(0, duration - elapsed) : duration
                            let isPartial = elapsed > 0
                            Text("•")
                            Text(isPartial ? "\(formatDuration(remaining)) left remaining" : formatDuration(duration))
                                .monospacedDigit()
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        // Pills hide in Reorder mode so the row's right edge
                        // belongs to the drag grips (NavRules).
                        if editMode != .active {
                            if sub.excludeFromAutoFeedRefresh {
                                EpisodeStatusPill(kind: .inactive)
                            } else if episode.playedState == .played {
                                EpisodeStatusPill(kind: .played)
                            } else if episode.playedState == .archived {
                                // Completed episodes keep Played even after
                                // auto-archive removes them from the queue.
                                EpisodeStatusPill(kind: episode.wasCompleted ? .played : .archived)
                            } else if episode.downloadState == .notDownloaded || episode.downloadState == .failed {
                                Button("Download") {
                                    Task { await appState.downloadLatestEpisode(for: sub) }
                                }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                EpisodeStatusPill(kind: statusKind(for: episode))
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                if episode.downloadState == .downloading,
                   let progress = appState.downloadProgress[episode.id] {
                    ProgressView(value: progress, total: 1.0)
                        .tint(.purple)
                        .animation(.linear(duration: 0.3), value: progress)
                        .padding(.leading, 56)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topTrailing) {
            if let episode = sub.latestEpisode,
               episode.mediaKind == .video || episode.isExplicit == true {
                HStack(spacing: 3) {
                    if episode.mediaKind == .video { VideoBadge() }
                    if episode.isExplicit == true { ExplicitPillSmall() }
                }
            }
        }
    }

    private func statusKind(for episode: Episode) -> EpisodeStatusKind {
        switch episode.playedState {
        case .playing:
            // Only the episode actively loaded in the player is "Now Playing".
            // Any other episode with .playing state was started but not finished.
            return appState.currentPlayerEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
        case .played:   return .played
        case .archived: return episode.wasCompleted ? .played : .archived
        case .unplayed:
            let position = appState.effectivePlaybackTime(for: episode)
            if position > 0 { return .partiallyPlayed }
            return episode.downloadState == .downloaded ? .queued : .unplayed
        }
    }

    @ViewBuilder
    private func rankPill(_ rank: Int) -> some View {
        let label = Text("\(rank)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .glassEffect(in: Capsule())
        } else {
            label
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatPublishedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func artwork(url: URL?) -> some View {
        CachedArtworkImage(url: url) {
            placeholderArtwork
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

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
