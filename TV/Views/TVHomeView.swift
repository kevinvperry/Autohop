import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVHomeView.swift
// Phase 2 (tvOS proposal §7 item 2): Home's shelf grammar (PC HomeView, §2.1).
// One mutually-exclusive hero (active Now Playing/Watching OR historical
// Continue Listening), followed by the Up Next shelf. Home deliberately has
// no second in-content title: TVMainTabView owns the persistent system Home
// chrome. While playback is loaded, its episode is removed only from Home's
// rendered Up Next projection; the phone-authored queue remains unchanged.
// The Latest
// shelf was REMOVED 2026-07-11 (Kevin: irrelevant on TV — Up Next is the
// point; the space goes to queue metadata instead).
// Continue Listening / "Continue Watching" (video): driven by the SYNCED
// listening-history record (TVAppModel.continueListening →
// mostRecentInProgressListeningEntry). REWORKED 2026-07-11: renders from the
// ENTRY's denormalized fields (title/podcast/artwork/duration/position), so
// the phone's true current episode shows even before its catalog materializes
// locally — the Resume affordance appears only once `episode` resolves (see
// TVContinueListening + computeContinueListening's header for the two stale-
// hero root causes this fixed). The header label switches to "Continue
// Watching" when the hero's mediaKind == .video. History lands fast via the
// launch/foreground prime (CloudSyncEngine.fetchAllHistoryNow) and the view
// re-renders on onRemoteHistoryChanged (SYNC_DESIGN.md, 2026-07-05). Phase 3
// (§8): tapping Continue Listening or any card calls `onPlay`, which
// TVMainTabView wires to `TVAppModel.beginPlayback` + presenting TVPlayerView.
struct TVHomeView: View {
    let model: TVAppModel
    let onPlay: (Episode) -> Void
    let onReopenPlayer: () -> Void
    @State private var descriptionItem: TVEpisodeDescriptionItem?

    var body: some View {
        let visibleQueueRows = homeQueueRows
        ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                if model.playbackModel.currentEpisode != nil {
                    nowPlayingSection
                } else if let continueItem = model.continueListeningModel.item {
                    continueListeningSection(continueItem)
                }
                if !visibleQueueRows.isEmpty {
                    queueList(title: "Up Next", rows: visibleQueueRows)
                }
                if model.playbackModel.currentEpisode == nil,
                   model.continueListeningModel.item == nil,
                   visibleQueueRows.isEmpty {
                    ContentUnavailableView(
                        "Nothing to play yet",
                        systemImage: "play.slash",
                        description: Text("Episodes appear here once your subscriptions have synced.")
                    )
                }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 60)
        }
        .tvEpisodeDescriptionSheet(
            item: $descriptionItem,
            resolveEpisode: { await model.episodeWithResolvedDescription($0) }
        )
    }

    /// Home is a presentation projection, not a second queue authority. Keep
    /// the active item in the authoritative phone-authored snapshot, but avoid
    /// showing the same episode immediately below its Now Playing hero here.
    /// Use every stable identity available because legacy queue rows may have
    /// been reconstructed from a different object instance than playback.
    private var homeQueueRows: [TVQueueRowModel] {
        guard let current = model.playbackModel.currentEpisode else {
            return model.queueModel.rows
        }
        let currentKey = PlaybackPositionStore.key(for: current)
        return model.queueModel.rows.filter { row in
            if let episode = row.episode,
               model.playbackModel.isCurrentEpisode(episode) {
                return false
            }
            return row.id != currentKey
        }
    }

    // MARK: - Current playback

    /// A stable, in-layout return path replaces the former floating overlay.
    /// It participates in Home's normal focus order and never obscures shelves.
    private var nowPlayingSection: some View {
        let playback = model.playbackModel
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(playback.currentEpisode?.mediaKind == .video ? "Now Watching" : "Now Playing")
            HStack(spacing: 20) {
                Button(action: onReopenPlayer) {
                    HStack(spacing: 20) {
                        TVArtworkImage(
                            url: playback.currentEpisode?.artworkURL,
                            cornerRadius: 12,
                            targetPixels: 440
                        )
                        .frame(width: 150, height: 150)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(playback.currentEpisode?.title ?? "Current episode")
                                .font(.title3.bold())
                                .lineLimit(2)
                            Text(playback.currentSubscriptionTitle)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Label(
                                playback.currentEpisode?.mediaKind == .video
                                    ? "Return to video"
                                    : "Open player",
                                systemImage: playback.currentEpisode?.mediaKind == .video
                                    ? "play.rectangle.fill"
                                    : "waveform"
                            )
                            .font(.headline)
                            .foregroundStyle(TVTheme.focusAccent)
                        }
                        Spacer()
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.card)
                .tvFocusHighlight(cornerRadius: 20)
                .contextMenu {
                    if let episode = playback.currentEpisode {
                        Button {
                            showDescription(
                                episode,
                                podcastTitle: playback.currentSubscriptionTitle
                            )
                        } label: {
                            Label("Episode Description", systemImage: "text.page")
                        }
                    }
                }

                Button {
                    playback.togglePlayPause()
                } label: {
                    Label(
                        playback.isPlaying ? "Pause" : "Play",
                        systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.headline)
                    .frame(minWidth: 150, minHeight: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(TVTheme.brandPurple)

                if let episode = playback.currentEpisode {
                    Button(role: .destructive) {
                        model.archiveEpisode(episode)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                            .font(.headline)
                            .frame(minWidth: 150, minHeight: 110)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .focusSection()
    }

    // MARK: - Continue Listening (TVCard-Hero pattern, DESIGN.md)

    @ViewBuilder
    private func continueListeningSection(_ item: TVContinueListening) -> some View {
        let entry = item.entry
        let isVideo = item.episode?.mediaKind == .video
        let positionSeconds = entry.lastPositionSeconds
        let duration = entry.durationSeconds ?? item.episode?.durationSeconds
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(isVideo ? "Continue Watching" : "Continue Listening")
            Button {
                if let episode = item.episode { onPlay(episode) }
            } label: {
                HStack(spacing: 20) {
                    TVArtworkImage(
                        url: item.episode?.artworkURL ?? entry.artworkURL,
                        cornerRadius: 12,
                        targetPixels: 440
                    )
                    .frame(width: 150, height: 150)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.episodeTitle)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text(entry.podcastTitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        // Cross-device resume position bar (synced via the
                        // listening-history record — the same value playback
                        // resumes from).
                        if positionSeconds > 0, let duration, duration > 0 {
                            ProgressView(value: min(positionSeconds / duration, 1.0))
                                .tint(.purple)
                                .frame(maxWidth: 360)
                            Text("\(remainingLabel(duration - positionSeconds)) left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if item.episode != nil {
                            Label("Resume", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        } else {
                            // Entry synced but its catalog hasn't materialized
                            // locally yet — same placeholder posture as the
                            // queue projection's bounded detail-recovery state.
                            Label("Loading episode details…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Brand-purple tinted card (2026-07-11 theme pass) — material
                // base with a purple wash, echoing the phone's purple accent
                // semantics for the primary/active surface.
                .background {
                    RoundedRectangle(cornerRadius: 20).fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: 20).fill(Color.purple.opacity(0.12))
                }
            }
            .buttonStyle(.card)
            .tvFocusHighlight(cornerRadius: 20)
            .disabled(item.episode == nil)
            .contextMenu {
                if let episode = item.episode {
                    Button {
                        showDescription(episode, podcastTitle: entry.podcastTitle)
                    } label: {
                        Label("Episode Description", systemImage: "text.page")
                    }
                    Button(role: .destructive) {
                        model.archiveEpisode(episode)
                    } label: {
                        Label("Archive Episode", systemImage: "archivebox")
                    }
                }
            }
        }
        .focusSection()
    }

    private func remainingLabel(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - Shelves and lists

    private func shelf(title: String, episodes: [Episode]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(episodes.prefix(25)) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            podcastTitle: model.subscription(for: episode)?.title,
                            onPlay: { onPlay(episode) },
                            onShowDescription: {
                                showDescription(
                                    episode,
                                    podcastTitle: model.subscription(for: episode)?.title
                                )
                            },
                            onArchive: { model.archiveEpisode(episode) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .focusSection()
        }
    }

    /// Queue rows, rather than only resolved Episode values, keep legacy phone
    /// snapshots visible on Home while targeted detail recovery runs. This
    /// prevents video/unresolved entries disappearing from Home even though
    /// their authoritative position is already visible in Up Next.
    /// Home deliberately uses the exact same focusable list-row component as
    /// the dedicated Up Next page. This removes the former artwork-card shelf
    /// dialect and makes title, duration, video and archive behaviour match.
    private func queueList(title: String, rows: [TVQueueRowModel]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title)
            LazyVStack(spacing: 24) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TVQueueRow(
                        row: row,
                        detailLoadFailed: model.queueEnrichmentFailed(for: row),
                        allowsPlayNext: index > 0,
                        onPlay: { if let episode = row.episode { onPlay(episode) } },
                        onPlayNext: {
                            Task { await model.requestPlayNext(row) }
                        },
                        onUnpin: {
                            Task { await model.requestUnpin(row) }
                        },
                        onShowDescription: {
                            if let episode = row.episode {
                                showDescription(episode, podcastTitle: row.podcastTitle)
                            }
                        },
                        onArchive: { if let episode = row.episode { model.archiveEpisode(episode) } }
                    )
                    .task { model.enrichQueueRowIfNeeded(row) }
                }
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
    let onShowDescription: () -> Void
    let onArchive: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                    TVArtworkImage(url: episode.artworkURL, targetPixels: 520)
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
        .tvFocusHighlight(cornerRadius: 18)
        .contextMenu {
            Button(action: onShowDescription) {
                Label("Episode Description", systemImage: "text.page")
            }
            Button(role: .destructive, action: onArchive) {
                Label("Archive Episode", systemImage: "archivebox")
            }
        }
    }
}

private extension TVHomeView {
    func showDescription(_ episode: Episode, podcastTitle: String?) {
        descriptionItem = TVEpisodeDescriptionItem(
            episode: episode,
            podcastTitle: podcastTitle
        )
    }
}
