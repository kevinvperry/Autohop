import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVHomeView.swift
// Phase 2 (tvOS proposal §7 item 2): Home's shelf grammar (PC HomeView, §2.1).
// Three sections in order: Continue Listening hero, Up Next shelf (the
// streaming Priority Stack — QueueModel.streamableQueue, via
// TVAppModel.upNextEpisodes), Latest shelf (newest episode per subscription).
// KNOWN SIMPLIFICATION (documented, not an oversight): Continue Listening
// identifies an in-progress episode via Episode.playedState == .playing (this
// DOES sync across devices — EpisodeSyncState.playedState is a synced field),
// but has no resume-position bar yet. Actual position roams inside the
// listening-history record (SYNC_DESIGN.md), and there is no core-level
// history reader TV can reach yet (ListeningHistoryStore lives in the iOS app
// target). Wire a real position bar when Phase 0 item 5 (LibraryModel) or a
// dedicated history-core exposure lands. Phase 3 (§8): tapping Continue
// Listening or any card calls `onPlay`, which TVMainTabView wires to
// `TVAppModel.beginPlayback` + presenting TVPlayerView.
struct TVHomeView: View {
    let model: TVAppModel
    let onPlay: (Episode) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                // Plain heading, not `.navigationTitle` — this tab has no
                // NavigationStack of its own (see TVMainTabView's header on
                // why nesting one under .sidebarAdaptable broke the sidebar).
                Text("Home")
                    .font(.largeTitle.bold())
                if let continueItem = model.continueListening {
                    continueListeningSection(continueItem.episode, positionSeconds: continueItem.positionSeconds)
                }
                if !model.upNextEpisodes.isEmpty {
                    shelf(title: "Up Next", episodes: model.upNextEpisodes)
                }
                if !model.latestEpisodes.isEmpty {
                    shelf(title: "Latest", episodes: model.latestEpisodes)
                }
                if model.continueListening == nil && model.upNextEpisodes.isEmpty && model.latestEpisodes.isEmpty {
                    ContentUnavailableView(
                        "Nothing to play yet",
                        systemImage: "play.slash",
                        description: Text("Episodes appear here once your subscriptions have synced.")
                    )
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 48)
        }
    }

    // MARK: - Continue Listening (TVCard-Hero pattern, DESIGN.md)

    @ViewBuilder
    private func continueListeningSection(_ episode: Episode, positionSeconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Continue Listening")
            Button {
                onPlay(episode)
            } label: {
                HStack(spacing: 24) {
                    TVArtworkImage(url: episode.artworkURL, cornerRadius: 16)
                        .frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(episode.title)
                            .font(.title2.bold())
                            .lineLimit(2)
                        if let podcast = model.subscription(for: episode)?.title {
                            Text(podcast)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        // Cross-device resume position bar (synced via the
                        // listening-history record — the same value playback
                        // resumes from).
                        if positionSeconds > 0, let duration = episode.durationSeconds, duration > 0 {
                            ProgressView(value: min(positionSeconds / duration, 1.0))
                                .tint(.purple)
                                .frame(maxWidth: 420)
                            Text("\(remainingLabel(duration - positionSeconds)) left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Label("Resume", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.card)
        }
        .focusSection()
    }

    private func remainingLabel(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - Horizontal shelves (TVShelf-Standard pattern, DESIGN.md)

    private func shelf(title: String, episodes: [Episode]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(episodes.prefix(25)) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            podcastTitle: model.subscription(for: episode)?.title,
                            onPlay: { onPlay(episode) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .focusSection()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.semibold))
    }
}

/// TVCard-Episode pattern (DESIGN.md): artwork-forward card for horizontal
/// shelves — chromeless button (no custom scale hack; standard tvOS focus
/// effect via `.buttonStyle(.card)`, matching PC's ChromelessButtonStyle intent).
struct TVEpisodeCard: View {
    let episode: Episode
    let podcastTitle: String?
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                TVArtworkImage(url: episode.artworkURL)
                    .frame(width: 280, height: 280)
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(width: 280, alignment: .leading)
                if let podcastTitle {
                    Text(podcastTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 280, alignment: .leading)
                }
            }
        }
        .buttonStyle(.card)
    }
}
