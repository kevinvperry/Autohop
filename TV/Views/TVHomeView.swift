import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVHomeView.swift
// Phase 2 (tvOS proposal §7 item 2): Home's shelf grammar (PC HomeView, §2.1).
// Two sections in order: Continue Listening hero, Up Next shelf. The Latest
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                // Plain heading, not `.navigationTitle` — this tab has no
                // NavigationStack of its own (see TVMainTabView's header on
                // why nesting one under .sidebarAdaptable broke the sidebar).
                Text("Home")
                    .font(.largeTitle.bold())
                if case .updating = model.syncStatus {
                    Text(model.syncStatus.label).font(.callout).foregroundStyle(.secondary)
                }
                if let continueItem = model.continueListening {
                    continueListeningSection(continueItem)
                }
                if !model.queueRows.isEmpty {
                    queueShelf(title: "Up Next", rows: model.queueRows)
                }
                if model.continueListening == nil && model.queueRows.isEmpty {
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
                HStack(spacing: 24) {
                    TVArtworkImage(
                        url: item.episode?.artworkURL ?? entry.artworkURL,
                        cornerRadius: 16,
                        targetPixels: 800
                    )
                    .frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.episodeTitle)
                            .font(.title2.bold())
                            .lineLimit(2)
                        Text(entry.podcastTitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        // Cross-device resume position bar (synced via the
                        // listening-history record — the same value playback
                        // resumes from).
                        if positionSeconds > 0, let duration, duration > 0 {
                            ProgressView(value: min(positionSeconds / duration, 1.0))
                                .tint(.purple)
                                .frame(maxWidth: 420)
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
                .padding(24)
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
            .disabled(item.episode == nil)
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

    /// Queue rows, rather than only resolved Episode values, keep legacy phone
    /// snapshots visible on Home while targeted detail recovery runs. This
    /// prevents video/unresolved entries disappearing from Home even though
    /// their authoritative position is already visible in Up Next.
    private func queueShelf(title: String, rows: [TVQueueRowModel]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(rows.prefix(25)) { row in
                        Button {
                            if let episode = row.episode { onPlay(episode) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                TVArtworkImage(url: row.artworkURL, targetPixels: 520)
                                    .frame(width: 280, height: 280)
                                Text(row.title).font(.headline).lineLimit(2)
                                    .frame(width: 280, alignment: .leading)
                                Text(row.podcastTitle).font(.subheadline)
                                    .foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 280, alignment: .leading)
                                if !row.isPlayable {
                                    Label(
                                        model.queueEnrichmentFailed(for: row) ? "Details unavailable" : "Loading details…",
                                        systemImage: model.queueEnrichmentFailed(for: row) ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.card)
                        .disabled(!row.isPlayable)
                        .task { model.enrichQueueRowIfNeeded(row) }
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
    }
}
