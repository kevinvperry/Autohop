import SwiftUI

// AI CONTEXT — Views/PodcastsView.swift ("Priority List" page — the app's
// home page, see PAGES.md). Ranked list of active subscriptions (browse
// subscriptions filtered out); drag-to-reorder in Reorder mode rewrites
// priorityRank for the whole list. Each row shows artwork, title, and a
// colour-coded status pill for the podcast's latest episode. Toolbar: Return
// to Player, hamburger menu (MenuSheetView), Reorder toggle, refresh-all,
// + (PodcastSearchView sheet). Rows navigate to SubscriptionEpisodesView.
struct PodcastsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editMode: EditMode = .inactive
    @State private var isRefreshingAll = false
    @State private var showMenu = false
    @State private var showSearch = false

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
                    // Section heading — matches Downloads page style
                    HStack(spacing: 6) {
                        Text("Priority Sort")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if !visibleSubscriptions.isEmpty {
                        Button {
                            refreshAll()
                        } label: {
                            if isRefreshingAll {
                                ProgressView()
                            } else {
                                Label("Refresh All", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isRefreshingAll)
                    }

                    Button {
                        showSearch = true
                    } label: {
                        Label("Add Podcast", systemImage: "plus")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if !visibleSubscriptions.isEmpty {
                    HStack(spacing: 8) {
                        ReturnToPlayerButton()

                        Button {
                            showMenu = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }

                        Button(editMode == .active ? "Done" : "Reorder") {
                            withAnimation {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showMenu) { MenuSheetView() }
        .sheet(isPresented: $showSearch) { PodcastSearchView() }
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

                        if sub.excludeFromAutoFeedRefresh {
                            EpisodeStatusPill(kind: .inactive)
                        } else if episode.playedState == .played {
                            EpisodeStatusPill(kind: .played)
                        } else if episode.playedState == .archived {
                            let position = appState.effectivePlaybackTime(for: episode)
                            let completed = episode.durationSeconds.map { position >= $0 * 0.95 } ?? false
                            EpisodeStatusPill(kind: completed ? .played : .archived)
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
        case .archived: return .archived
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
