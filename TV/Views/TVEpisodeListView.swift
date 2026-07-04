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
    let subscription: Subscription?
    let onPlay: (Episode) -> Void

    var body: some View {
        // No `.navigationTitle` (display-bug fix 2026-07-04: the fixed title
        // overlapped scrolled content on tvOS) — the in-scroll header below
        // already shows the podcast title/artwork; Menu still pops the stack.
        Group {
            if let subscription {
                content(for: subscription)
            } else {
                ContentUnavailableView("Podcast Not Found", systemImage: "questionmark.circle")
            }
        }
    }

    @ViewBuilder
    private func content(for subscription: Subscription) -> some View {
        ZStack(alignment: .top) {
            TVArtworkImage(url: subscription.artworkURL, cornerRadius: 0)
                .blur(radius: 60)
                .opacity(0.35)
                .ignoresSafeArea()
                .frame(height: 500)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header(subscription)
                    episodeList(subscription)
                }
                .padding(.horizontal, 64)
                .padding(.vertical, 48)
            }
        }
    }

    private func header(_ subscription: Subscription) -> some View {
        HStack(spacing: 24) {
            TVArtworkImage(url: subscription.artworkURL, cornerRadius: 16)
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 8) {
                Text(subscription.title)
                    .font(.title.bold())
                if let author = subscription.author {
                    Text(author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func episodeList(_ subscription: Subscription) -> some View {
        let episodes = subscription.episodes.isEmpty
            ? subscription.latestEpisode.map { [$0] } ?? []
            : subscription.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }

        return LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(episodes) { episode in
                TVEpisodeRow(episode: episode, onPlay: { onPlay(episode) })
            }
        }
    }
}

/// TVRow-Episode pattern (DESIGN.md): title + relative date + a text status
/// pill (played/archived/new). No swipe actions — tvOS has no swipe gesture.
/// Tapping plays via `onPlay` (Phase 3, §8); a focus-driven context menu for
/// secondary actions is a later-phase option if needed.
struct TVEpisodeRow: View {
    let episode: Episode
    let onPlay: () -> Void

    var body: some View {
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.card)
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
