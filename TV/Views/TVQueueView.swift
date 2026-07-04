import SwiftUI
import AutohopCore

// AI CONTEXT — TV/Views/TVQueueView.swift
// Phase 2 (tvOS proposal §7 item 3): the full streaming Priority Stack as a
// dedicated, focusable tab — "the queue IS Autohop's identity." Read-only:
// rows are large focusable cards, no swipe actions (tvOS has no swipe), no
// Play Next/Play Last pin indicator yet (see QueueModel.streamableQueue's
// header — pins are local per-device iPhone state with no sync today, so a
// TV install genuinely has none to show; add the indicator if pins ever sync).
// Tapping a row plays via `onPlay` (Phase 3, §8).
struct TVQueueView: View {
    let model: TVAppModel
    let onPlay: (Episode) -> Void

    var body: some View {
        // Heading lives INSIDE the ScrollView (display-bug fix 2026-07-04:
        // a heading outside the scroll container sat fixed at the top while
        // scrolled rows visually slid behind it on tvOS). It scrolls away
        // with the content, like Home's. Plain Text, not `.navigationTitle` —
        // this tab has no NavigationStack (see TVMainTabView's header).
        Group {
            if model.upNextEpisodes.isEmpty {
                ContentUnavailableView(
                    "Up Next is empty",
                    systemImage: "square.stack",
                    description: Text("As episodes publish, they line up here in Priority Stack order.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Text("Up Next")
                            .font(.largeTitle.bold())
                            .padding(.bottom, 8)
                        ForEach(model.upNextEpisodes) { episode in
                            TVQueueRow(
                                episode: episode,
                                podcastTitle: model.subscription(for: episode)?.title,
                                onPlay: { onPlay(episode) }
                            )
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 48)
                }
            }
        }
    }
}

/// TVCard-QueueRow pattern (DESIGN.md): large artwork + title/podcast/remaining,
/// full-width focusable row — the tvOS analog of the iPhone's
/// "ListRow-Up Next Episode Row" pattern.
struct TVQueueRow: View {
    let episode: Episode
    let podcastTitle: String?
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 24) {
                TVArtworkImage(url: episode.artworkURL, cornerRadius: 12)
                    .frame(width: 140, height: 140)
                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let podcastTitle {
                        Text(podcastTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let duration = episode.durationSeconds {
                        Text(formattedDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.card)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
