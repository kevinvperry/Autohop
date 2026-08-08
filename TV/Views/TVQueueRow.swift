import SwiftUI
import AutohopCore

// AI CONTEXT — Canonical Up Next row for the tvOS Home page. Home is now the
// sole queue surface: priority occupies a fixed leading column, artwork is the
// second column, and title/publisher/duration share one aligned text column.
struct TVQueueRow: View {
    let row: TVQueueRowModel
    let detailLoadFailed: Bool
    let allowsPlayNext: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onUnpin: () -> Void
    let onShowDescription: () -> Void
    let onArchive: () -> Void
    @FocusState private var focusedElement: TVEpisodeRowFocus?

    private var episode: Episode? { row.episode }

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onPlay) {
                HStack(spacing: 24) {
                    Text("\(row.position)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .center)
                    TVArtworkImage(url: row.artworkURL, cornerRadius: 12, targetPixels: 360)
                        .frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(row.title)
                            .font(.headline)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            if let pinState = row.pinState {
                                Image(systemName: "pin.fill")
                                    .foregroundStyle(pinState == .playNext ? Color.blue : Color.orange)
                                    .accessibilityLabel(pinState == .playNext ? "Pinned to play next" : "Pinned to play last")
                            }
                            Text(row.podcastTitle).lineLimit(1)
                            if let duration = row.durationSeconds {
                                Text("•")
                                Text(formattedDuration(duration))
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        if row.mediaKind == .video {
                            Label("Video", systemImage: "play.rectangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if episode == nil {
                            Label(
                                modelLabel,
                                systemImage: detailLoadFailed
                                    ? "exclamationmark.triangle"
                                    : "arrow.triangle.2.circlepath"
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
            .tvFocusHighlight(cornerRadius: 16)
            .disabled(episode == nil)
            .focused($focusedElement, equals: .content)

            if episode != nil {
                TVEpisodeActionsMenu(
                    onPlayNext: !row.isPinned && allowsPlayNext ? onPlayNext : nil,
                    onUnpin: row.isPinned ? onUnpin : nil,
                    onShowDescription: onShowDescription,
                    onArchive: onArchive,
                    isVisible: focusedElement != nil
                )
                .focused($focusedElement, equals: .menu)
            }
        }
        .contextMenu {
            if episode != nil {
                Button(action: onShowDescription) {
                    Label("Episode Description", systemImage: "text.page")
                }
                if row.isPinned {
                    Button(action: onUnpin) {
                        Label("Unpin", systemImage: "pin.slash.fill")
                    }
                    .tint(.teal)
                } else if allowsPlayNext {
                    Button(action: onPlayNext) {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                Button(role: .destructive, action: onArchive) {
                    Label("Archive Episode", systemImage: "archivebox")
                }
            }
        }
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

/// One compact secondary-action affordance shared by every tvOS episode list.
/// It appears only while its row has focus, matching the ten-foot convention
/// established by Apple's TV app and Pocket Casts without permanently spending
/// horizontal space on destructive or queue-management buttons.
struct TVEpisodeActionsMenu: View {
    let onPlayNext: (() -> Void)?
    let onUnpin: (() -> Void)?
    let onShowDescription: (() -> Void)?
    let onArchive: (() -> Void)?
    let isVisible: Bool

    @ViewBuilder
    var body: some View {
        if isVisible {
            Menu {
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
                if let onShowDescription {
                    Button(action: onShowDescription) {
                        Label("Episode Description", systemImage: "text.page")
                    }
                }
                if let onArchive {
                    Button(role: .destructive, action: onArchive) {
                        Label("Archive Episode", systemImage: "archivebox")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2.bold())
                    .frame(width: 68, height: 92)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Episode actions")
        }
    }
}

enum TVEpisodeRowFocus: Hashable {
    case content
    case menu
}
