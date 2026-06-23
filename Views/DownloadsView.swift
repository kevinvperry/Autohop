import SwiftUI

// AI CONTEXT — Views/DownloadsView.swift ("Downloads" page). Sections driven
// by DownloadActivityStore: active downloads (progress, pause/resume/cancel),
// failed (retry), and downloaded/recently archived episodes with file sizes
// and delete actions routed through AppState (which owns file + model state).
// Rows use CachedArtworkImage with a 44 pt target so this activity-heavy page
// shares the app-wide downsampled artwork cache rather than decoding full covers.
struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(
                    title: "Downloading",
                    emptyText: "No active downloads",
                    activities: appState.downloadActivityStore.activeActivities
                )

                section(
                    title: "Downloaded on Device",
                    emptyText: "No completed downloads",
                    activities: appState.downloadedActivities
                )

                archivedSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
    }

    // MARK: - Recently Archived

    private var recentlyArchivedEntries: [ListeningHistoryEntry] {
        appState.listeningHistoryStore.entries
            .filter { $0.status == .archived }
    }

    @ViewBuilder
    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Archived")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if recentlyArchivedEntries.isEmpty {
                Text("No archived episodes yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassCard(cornerRadius: 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(recentlyArchivedEntries) { entry in
                        ArchivedEpisodeRow(entry: entry)
                            .environmentObject(appState)

                        if entry.id != recentlyArchivedEntries.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                                .padding(.leading, 70)
                        }
                    }
                }
                .glassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Shared section builder

    @ViewBuilder
    private func section(
        title: String,
        emptyText: String,
        activities: [DownloadActivity]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if activities.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassCard(cornerRadius: 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(activities) { activity in
                        DownloadActivityRow(activity: activity)
                            .environmentObject(appState)

                        if activity.id != activities.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                                .padding(.leading, 70)
                        }
                    }
                }
                .glassCard(cornerRadius: 16)
            }
        }
    }
}

// MARK: - Archived Episode Row

private struct ArchivedEpisodeRow: View {
    @EnvironmentObject private var appState: AppState
    let entry: ListeningHistoryEntry

    @State private var isRedownloading = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Artwork column — 44×44 image + badges centred below
            VStack(alignment: .center, spacing: 4) {
                CachedArtworkImage(url: entry.artworkURL, targetSize: CGSize(width: 44, height: 44)) {
                    placeholderArtwork
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9))

            }

            // Text stack — Text-PodcastTitle / Text-EpisodeTitle / Text-MetadataRow
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(entry.episodeTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(archivedMetadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Re-download button — icon-only, bordered, purple (Button-ToolbarAction size)
            Button {
                isRedownloading = true
                Task {
                    await redownload()
                    isRedownloading = false
                }
            } label: {
                if isRedownloading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Re-download", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.purple)
            .disabled(isRedownloading)
        }
        .padding(14)
        .overlay(alignment: .topTrailing) {
            if archivedEpisode?.mediaKind == .video || archivedEpisode?.isExplicit == true {
                HStack(spacing: 3) {
                    if archivedEpisode?.mediaKind == .video { VideoPillSmall() }
                    if archivedEpisode?.isExplicit == true { ExplicitPillSmall() }
                }
            }
        }
    }

    private var archivedEpisode: Episode? {
        appState.subscriptionStore.episode(subscriptionID: entry.subscriptionID, episodeID: entry.episodeID)
    }

    private var archivedMetadata: String {
        let dateStr = entry.lastListenedAt.formatted(date: .abbreviated, time: .shortened)
        if let pct = entry.completionPercent {
            let pctStr = "\(Int((pct * 100).rounded()))%"
            return "Archived \(dateStr) · Listened \(pctStr)"
        }
        return "Archived \(dateStr)"
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

    private func redownload() async {
        guard let subscription = appState.subscriptionStore.subscription(id: entry.subscriptionID),
              let episode = subscription.episodes.first(where: { $0.id == entry.episodeID })
        else { return }
        await appState.downloadEpisodeForQueue(episode)
    }
}

// MARK: - Download Activity Row

private struct DownloadActivityRow: View {
    @EnvironmentObject private var appState: AppState
    let activity: DownloadActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Artwork column — 44×44 image + badges centred below
                VStack(alignment: .center, spacing: 4) {
                    CachedArtworkImage(url: artworkURL, targetSize: CGSize(width: 44, height: 44)) {
                        placeholderArtwork
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                }

                // Text stack — Text-PodcastTitle / Text-EpisodeTitle / Text-MetadataRow
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activity.podcastTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if activity.status != .completed { mediaPill }
                    }

                    Text(activity.episodeTitle)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if activity.status == .completed {
                    archiveButton
                } else {
                    statusPill
                }
            }

            // Progress / error row — indented past artwork (14 padding + 44 artwork + 12 spacing)
            if activity.status == .downloading || activity.status == .paused {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: activity.progress, total: 1)
                        .tint(.purple)

                    HStack {
                        Text(progressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        controls
                    }
                }
                .padding(.leading, 56)
            } else if activity.status == .failed {
                HStack {
                    Text(activity.errorMessage ?? "Download failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)

                    Spacer()

                    controls
                }
                .padding(.leading, 56)
            }
        }
        .padding(14)
        .overlay(alignment: .topTrailing) {
            if activity.mediaKind == .video || episode?.isExplicit == true {
                HStack(spacing: 3) {
                    if activity.mediaKind == .video { VideoPillSmall() }
                    if episode?.isExplicit == true { ExplicitPillSmall() }
                }
            }
        }
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: activity.mediaKind == .video ? "play.rectangle.fill" : "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var artworkURL: URL? {
        activity.artworkURL
            ?? appState.subscriptionStore.subscription(id: activity.subscriptionID)?.artworkURL
    }

    private var episode: Episode? {
        appState.subscriptionStore.episode(subscriptionID: activity.subscriptionID, episodeID: activity.episodeID)
    }

    @ViewBuilder
    private var mediaPill: some View {
        let label = Text(activity.mediaKind == .video ? "Video" : "Audio")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)

        if #available(iOS 26, *) {
            label
                .background(Color.purple.opacity(0.45), in: Capsule())
                .glassEffect(in: Capsule())
        } else {
            label
                .foregroundStyle(Color.purple)
                .background(Color.purple.opacity(0.18), in: Capsule())
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let label = Text(statusText)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .background(statusColor.opacity(0.45), in: Capsule())
                .glassEffect(in: Capsule())
        } else {
            label
                .foregroundStyle(statusColor)
                .background(statusColor.opacity(0.2), in: Capsule())
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            switch activity.status {
            case .downloading:
                Button {
                    appState.pauseDownload(activity)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                archiveButton

            case .paused, .failed:
                Button {
                    Task { await appState.resumeDownload(activity) }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                archiveButton

            case .completed:
                archiveButton
            }
        }
    }

    private var archiveButton: some View {
        Button {
            Task { await appState.archiveDownload(activity) }
        } label: {
            Label("Archive", systemImage: "archivebox")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.purple)
    }

    private var statusText: String {
        switch activity.status {
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .completed: return "Complete"
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .downloading: return .purple
        case .paused: return .orange
        case .failed: return .red
        case .completed: return .green
        }
    }

    private var metadataText: String {
        let date = activity.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let size = byteText(activity.expectedBytes)
        return "\(size) • \(date)"
    }

    private var progressText: String {
        let written = byteText(activity.writtenBytes)
        let expected = byteText(activity.expectedBytes)
        let percent = Int((activity.progress * 100).rounded())
        return "\(percent)% • \(written) of \(expected)"
    }

    private func byteText(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
