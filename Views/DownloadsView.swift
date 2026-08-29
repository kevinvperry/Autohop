import SwiftUI

// AI CONTEXT — Views/DownloadsView.swift ("Downloads" page). Sections driven
// by DownloadActivityStore: active downloads (progress, pause/resume/cancel),
// failed (retry), and downloaded/recently archived episodes with file sizes
// and delete actions routed through AppState (which owns file + model state).
// Rows use CachedArtworkImage with a 44 pt target so this activity-heavy page
// shares the app-wide downsampled artwork cache rather than decoding full covers.
// LAYOUT GOTCHAS: the pause/resume/archive `controls` are `.fixedSize()` because
// they share a row with the progress text — without it a long "NN% • X MB of Y GB"
// compresses the buttons ("Re-sume" wraps mid-word). Media/explicit pills are
// INLINE next to the podcast title, not a top-trailing overlay (the overlay
// version floated over the Downloading/Paused status pill). Progress publishes
// are coalesced in AppState.onProgressUpdate (≥1% steps) so several concurrent
// downloads don't re-invalidate this page multiple times per second (scroll jank).
// The page-level stack uses adaptivePageContent; keep that modifier on the inner
// custom-scroll content so system chrome/backgrounds remain full width and the
// outer gutter follows the live container rather than assuming a phone screen.
struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloadCoordinator: DownloadCoordinator
    @EnvironmentObject private var downloadActivityStore: DownloadActivityStore
    @EnvironmentObject private var historyStore: ListeningHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(
                    title: "Downloading",
                    emptyText: "No active downloads",
                    activities: downloadActivityStore.activeActivities
                )

                section(
                    title: "Downloaded on Device",
                    emptyText: "No completed downloads",
                    activities: downloadCoordinator.downloadedActivities
                )

                archivedSection
            }
            .padding(.vertical, 18)
            .episodeListPageWidth()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Downloads")
        .responsiveInlineNavigationTitle("Downloads")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationBackButton()
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
        .onAppear {
            let activities = downloadActivityStore.activeActivities
            AppLogger.shared.info(
                "download.pageAppeared",
                "Downloads page appeared",
                metadata: [
                    "activeRows": "\(activities.count)",
                    "downloading": "\(activities.filter { $0.status == .downloading }.count)",
                    "waitingToRetry": "\(activities.filter { $0.status == .waitingToRetry }.count)",
                    "failed": "\(activities.filter { $0.status == .failed }.count)"
                ]
            )
        }
    }

    // MARK: - Recently Archived

    private var recentlyArchivedEntries: [ListeningHistoryEntry] {
        historyStore.entries
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
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    let entry: ListeningHistoryEntry

    @State private var isRedownloading = false

    var body: some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        let artworkSize = metrics.artworkSize
        HStack(alignment: .top, spacing: metrics.rowSpacing) {
            // Artwork column — 44×44 image + badges centred below
            VStack(alignment: .center, spacing: 4) {
                CachedArtworkImage(url: entry.artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
                    placeholderArtwork
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

            }

            // Text stack — Text-PodcastTitle / Text-EpisodeTitle / Text-MetadataRow
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(entry.episodeTitle)
                    .font(.system(size: metrics.primaryFontSize, weight: .bold))
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
        subscriptionStore.episode(subscriptionID: entry.subscriptionID, episodeID: entry.episodeID)
    }

    private var archivedMetadata: String {
        let dateStr = relativePublishedLabel(entry.lastListenedAt)
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
        guard let subscription = subscriptionStore.subscription(id: entry.subscriptionID),
              let episode = subscription.episodes.first(where: { $0.id == entry.episodeID })
        else { return }
        await appState.downloadEpisodeForQueue(episode)
    }
}

// MARK: - Download Activity Row

private struct DownloadActivityRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    let activity: DownloadActivity

    var body: some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        let artworkSize = metrics.artworkSize
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: metrics.rowSpacing) {
                // Artwork column — 44×44 image + badges centred below
                VStack(alignment: .center, spacing: 4) {
                    CachedArtworkImage(url: artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
                        placeholderArtwork
                    }
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

                }

                // Text stack — Text-PodcastTitle / Text-EpisodeTitle / Text-MetadataRow
                VStack(alignment: .leading, spacing: 2) {
                    // Media/explicit pills live INLINE here (not a top-trailing
                    // overlay): the overlay badges floated over the Downloading/Paused
                    // status pill and clipped at the card edge. The inline Audio/Video
                    // pill also already carried the media kind, so the overlay video
                    // badge was redundant.
                    HStack(spacing: 6) {
                        Text(activity.podcastTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        mediaPill
                        if episode?.isExplicit == true { ExplicitPillSmall() }
                    }

                    Text(activity.episodeTitle)
                            .font(.system(size: metrics.primaryFontSize, weight: .bold))
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
            if activity.status == .downloading
                || activity.status == .waitingToRetry
                || activity.status == .paused {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: activity.progress, total: 1)
                        .tint(.purple)

                    HStack {
                        Text(progressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        controls
                    }
                }
                .padding(.leading, artworkSize + metrics.rowSpacing)
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
            ?? subscriptionStore.subscription(id: activity.subscriptionID)?.artworkURL
    }

    private var episode: Episode? {
        subscriptionStore.episode(subscriptionID: activity.subscriptionID, episodeID: activity.episodeID)
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
        // fixedSize: the buttons share a row with the progress/error text; without it
        // a long "21% • 571 MB of 2.67 GB" compresses the buttons and wraps "Resume"
        // mid-word. Buttons keep their intrinsic size; the text truncates instead.
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

            case .waitingToRetry:
                Button {
                    Task { await appState.resumeDownload(activity) }
                } label: {
                    Label("Retry Now", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                archiveButton

            case .paused, .failed:
                Button {
                    Task { await appState.resumeDownload(activity) }
                } label: {
                    Label(
                        activity.status == .failed ? "Retry Now" : "Resume",
                        systemImage: activity.status == .failed
                            ? "arrow.clockwise" : "play.fill"
                    )
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                archiveButton

            case .completed:
                archiveButton
            }
        }
        .fixedSize()
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
        case .waitingToRetry: return "Waiting to retry"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .completed: return "Complete"
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .downloading: return .purple
        case .waitingToRetry: return .orange
        case .paused: return .orange
        case .failed: return .red
        case .completed: return .green
        }
    }

    private var metadataText: String {
        let date = relativePublishedLabel(activity.updatedAt)
        let size = byteText(activity.expectedBytes)
        return "\(size) • \(date)"
    }

    private var progressText: String {
        let written = byteText(activity.writtenBytes)
        let expected = byteText(activity.expectedBytes)
        let percent = Int((activity.progress * 100).rounded())
        var components = ["\(percent)%", "\(written) of \(expected)"]
        if activity.status == .downloading,
           let speed = activity.bytesPerSecond, speed > 0 {
            components.append("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
        }
        if activity.status == .downloading,
           let remaining = activity.estimatedRemainingSeconds,
           remaining.isFinite, remaining > 0 {
            components.append("about \(remainingText(remaining)) left")
        }
        return components.joined(separator: " • ")
    }

    private func remainingText(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, seconds)) ?? "calculating"
    }

    private func byteText(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
