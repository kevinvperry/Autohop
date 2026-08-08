import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVEpisodeListView.swift
// Phase 2 (tvOS proposal §7 item 4): podcast header + episode list, pushed
// from TVLibraryView. Blurred-artwork backdrop (PC BlurredCoverBackground
// intent) behind a plain header — no custom material hacks, matching §7 item
// 5's "Liquid Glass comes from the components." Shows played/archived state
// via a simple text pill (EpisodeBadges.swift's pill views live in the iOS
// Views/ target and aren't reachable here). `subscription` is nil when the
// pushed id no longer resolves (e.g. unsubscribed on the phone while this
// page was open) — shown as a plain "not found" state rather than crashing.
struct TVEpisodeListView: View {
    let model: TVAppModel
    let subscriptionID: UUID
    let onPlay: (Episode) -> Void
    @State private var descriptionItem: TVEpisodeDescriptionItem?

    var body: some View {
        // No `.navigationTitle` (display-bug fix 2026-07-04: the fixed title
        // overlapped scrolled content on tvOS) — the in-scroll header below
        // already shows the podcast title/artwork; Menu still pops the stack.
        Group {
            if let podcast = model.libraryModel.tiles.first(where: { $0.id == subscriptionID }) {
                content(for: podcast)
            } else {
                ContentUnavailableView("Podcast Not Found", systemImage: "questionmark.circle")
            }
        }
        .task { await model.loadEpisodeDetails(subscriptionID: subscriptionID) }
        .tvEpisodeDescriptionSheet(
            item: $descriptionItem,
            resolveEpisode: { await model.episodeWithResolvedDescription($0) }
        )
    }

    @ViewBuilder
    private func content(for podcast: TVPodcastTileModel) -> some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header(podcast)
                    episodeList
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 60)
            }
        }
    }

    private func header(_ podcast: TVPodcastTileModel) -> some View {
        HStack(spacing: 24) {
            TVArtworkImage(url: podcast.artworkURL, cornerRadius: 16, targetPixels: 440)
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 8) {
                Text(podcast.title)
                    .font(.title.bold())
                if let author = podcast.author {
                    Text(author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var episodeList: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(model.libraryModel.episodeRows(subscriptionID: subscriptionID)) { row in
                let queueRow = queueRow(for: row.episode)
                TVEpisodeRow(
                    episode: row.episode,
                    onPlay: { onPlay(row.episode) },
                    onPlayNext: playNextAction(for: queueRow),
                    onUnpin: unpinAction(for: queueRow),
                    onShowDescription: {
                        descriptionItem = TVEpisodeDescriptionItem(
                            episode: row.episode,
                            podcastTitle: model.libraryModel.tiles.first(where: { $0.id == subscriptionID })?.title
                        )
                    },
                    onArchive: { model.archiveEpisode(row.episode) }
                )
            }
        }
    }

    /// Library episodes can participate in the same queue commands as Home
    /// only when they already have an authoritative phone-authored queue row.
    /// Never synthesize queue identity from title alone.
    private func queueRow(for episode: Episode) -> TVQueueRowModel? {
        let episodeKey = PlaybackPositionStore.key(for: episode)
        return model.queueModel.rows.first { row in
            if row.id == episodeKey { return true }
            guard let rowEpisode = row.episode else { return false }
            return PlaybackPositionStore.key(for: rowEpisode) == episodeKey
        }
    }

    private func playNextAction(for row: TVQueueRowModel?) -> (() -> Void)? {
        guard let row,
              !row.isPinned,
              model.queueModel.rows.first?.id != row.id else { return nil }
        return { Task { await model.requestPlayNext(row) } }
    }

    private func unpinAction(for row: TVQueueRowModel?) -> (() -> Void)? {
        guard let row, row.isPinned else { return nil }
        return { Task { await model.requestUnpin(row) } }
    }
}

/// TVRow-Episode pattern (DESIGN.md): title + relative date + a text status
/// pill (played/archived/new). No swipe actions — tvOS has no swipe gesture.
/// Tapping plays via `onPlay` (Phase 3, §8); a focus-driven context menu for
/// secondary actions is a later-phase option if needed.
struct TVEpisodeRow: View {
    let episode: Episode
    let onPlay: () -> Void
    let onPlayNext: (() -> Void)?
    let onUnpin: (() -> Void)?
    let onShowDescription: () -> Void
    let onArchive: () -> Void
    @FocusState private var focusedElement: TVEpisodeRowFocus?

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onPlay) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title)
                            .font(.headline)
                            .lineLimit(2)
                        if let publishedAt = episode.publishedAt {
                            Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    statusPill
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.card)
            .tvFocusHighlight(cornerRadius: 14)
            .focused($focusedElement, equals: .content)

            TVEpisodeActionsMenu(
                onPlay: onPlay,
                onPlayNext: onPlayNext,
                onUnpin: onUnpin,
                onShowDescription: onShowDescription,
                onArchive: onArchive,
                isVisible: focusedElement != nil
            )
            .focused($focusedElement, equals: .menu)
        }
        .contextMenu {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            if let onPlayNext {
                Button(action: onPlayNext) {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
            if let onUnpin {
                Button(action: onUnpin) {
                    Label("Unpin", systemImage: "pin.slash.fill")
                }
            }
            Button(action: onShowDescription) {
                Label("Episode Description", systemImage: "text.page")
            }
            Button(role: .destructive, action: onArchive) {
                Label("Archive Episode", systemImage: "archivebox")
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch episode.playedState {
        case .played:
            Text("Played").font(.caption).foregroundStyle(.secondary)
        case .archived:
            Text("Archived").font(.caption).foregroundStyle(.secondary)
        case .playing:
            Text("In Progress").font(.caption).foregroundStyle(.purple)
        case .unplayed:
            EmptyView()
        }
    }
}
