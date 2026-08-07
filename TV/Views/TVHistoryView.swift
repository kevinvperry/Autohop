import SwiftUI
import AutohopCore

// AI CONTEXT — Cross-device archive history. Rows come from the last 50
// `.archived` ListeningHistoryEntry records already merged through private
// iCloud. The denormalized history entry always renders; replay is enabled
// when TVEpisodeResolver can materialize a safe streamable Episode.
struct TVHistoryView: View {
    let model: TVAppModel
    let onPlay: (Episode) -> Void
    @FocusState private var focusedItemID: String?
    @State private var descriptionItem: TVEpisodeDescriptionItem?

    var body: some View {
        Group {
            if model.historyModel.items.isEmpty {
                ContentUnavailableView(
                    "No archived episodes yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("The last 50 episodes archived across your devices will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Text("History")
                            .font(.largeTitle.bold())
                            .padding(.bottom, 8)
                        ForEach(model.historyModel.items) { item in
                            TVHistoryRow(
                                item: item,
                                onReplay: {
                                    if let episode = item.episode { onPlay(episode) }
                                },
                                onShowDescription: {
                                    if let episode = item.episode {
                                        descriptionItem = TVEpisodeDescriptionItem(
                                            episode: episode,
                                            podcastTitle: item.entry.podcastTitle
                                        )
                                    }
                                }
                            )
                            .focused($focusedItemID, equals: item.id)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
                }
            }
        }
        .onAppear { restoreFocus() }
        .onChange(of: model.historyModel.items.map(\.id)) { _, _ in restoreFocus() }
        .tvEpisodeDescriptionSheet(item: $descriptionItem)
    }

    private func restoreFocus() {
        let ids = model.historyModel.items.map(\.id)
        guard !ids.isEmpty else { focusedItemID = nil; return }
        if let focusedItemID, ids.contains(focusedItemID) { return }
        focusedItemID = model.historyModel.items.first(where: { $0.episode != nil })?.id ?? ids[0]
    }
}

private struct TVHistoryRow: View {
    let item: TVHistoryItem
    let onReplay: () -> Void
    let onShowDescription: () -> Void

    var body: some View {
        Button(action: onReplay) {
            HStack(spacing: 24) {
                TVArtworkImage(
                    url: item.episode?.artworkURL ?? item.entry.artworkURL,
                    cornerRadius: 12,
                    targetPixels: 360
                )
                .frame(width: 140, height: 140)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.entry.episodeTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(item.entry.podcastTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text(item.entry.lastListenedAt, format: .relative(presentation: .named))
                        if item.entry.mediaKind == .video {
                            Label("Video", systemImage: "play.rectangle.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    if item.episode != nil {
                        Label("Play again", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TVTheme.focusAccent)
                    } else {
                        Label("Playback details unavailable", systemImage: "exclamationmark.triangle")
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
        .tvFocusHighlight(cornerRadius: 16)
        .disabled(item.episode == nil)
        .contextMenu {
            if item.episode != nil {
                Button(action: onShowDescription) {
                    Label("Episode Description", systemImage: "text.page")
                }
            }
        }
    }
}
