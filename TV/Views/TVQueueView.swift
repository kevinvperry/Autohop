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
    @FocusState private var focusedRowID: String?

    var body: some View {
        // Heading lives INSIDE the ScrollView (display-bug fix 2026-07-04:
        // a heading outside the scroll container sat fixed at the top while
        // scrolled rows visually slid behind it on tvOS). It scrolls away
        // with the content, like Home's. Plain Text, not `.navigationTitle` —
        // this tab has no NavigationStack (see TVMainTabView's header).
        Group {
            if model.queueRows.isEmpty {
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
                        // Render from the synced snapshot's items so the queue is
                        // stable during a cold sync; an item whose catalog hasn't
                        // materialized yet (episode == nil) shows a not-yet-
                        // playable placeholder row (churn fix 2026-07-05).
                        Text(model.syncStatus.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(model.queueRows) { row in
                            TVQueueRow(
                                row: row,
                                detailLoadFailed: model.queueEnrichmentFailed(for: row),
                                onPlay: { if let episode = row.episode { onPlay(episode) } }
                            )
                            .focused($focusedRowID, equals: row.id)
                            .task { model.enrichQueueRowIfNeeded(row) }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
                }
            }
        }
    }
}

/// TVCard-QueueRow pattern (DESIGN.md): large artwork + title/podcast/remaining,
/// full-width focusable row — the tvOS analog of the iPhone's
/// "ListRow-Up Next Episode Row" pattern.
struct TVQueueRow: View {
    let row: TVQueueRowModel
    let detailLoadFailed: Bool
    let onPlay: () -> Void

    /// nil until this item's catalog has materialized locally — until then the
    /// row is a non-playable placeholder showing the synced title + order.
    private var episode: Episode? { row.episode }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 24) {
                TVArtworkImage(url: row.artworkURL, cornerRadius: 12, targetPixels: 360)
                    .frame(width: 140, height: 140)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(row.position)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(row.title)
                    }
                        .font(.headline)
                        .lineLimit(2)
                    Text(row.podcastTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if row.mediaKind == .video {
                        Label("Video", systemImage: "play.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let episode, let duration = episode.durationSeconds {
                        Text(formattedDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if episode == nil {
                        Label(
                            modelLabel,
                            systemImage: modelLabel == "Episode details unavailable" ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath"
                        )
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.card)
        .disabled(episode == nil)
    }

    private var modelLabel: String {
        detailLoadFailed ? "Episode details unavailable" : "Loading episode details…"
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
