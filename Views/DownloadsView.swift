import SwiftUI

// AI CONTEXT — Views/DownloadsView.swift (Downloads).
// ROW GEOMETRY: Centre artwork beside the full text column. Titles/publisher/
// metadata never share a horizontal band with status or transfer controls. Place
// media/status badges in a bottom band, not a competing trailing column; archived
// re-download controls follow the same rule. Keep swipe handlers unchanged.
// Native List sections are required for standard swipeActions: leading Play /
// Play Next, trailing Archive / Play Last, no full swipe. Do not move rows back
// into a ScrollView/LazyVStack, which cannot host native row swipes.
// GeometryReader supplies actual container width to AdaptiveListRowMetrics for
// artwork/decode targets, titles, secondary text, badges and vertical spacing.
// Keep transfer progress, Pause/Resume/Retry and archived Re-download controls;
// archive is swipe-only. AppState owns file/transfer/model changes. Historical
// entries without a live episode cannot offer playback; playing rows have no
// destructive/requeue swipes, matching the existing podcast-list convention.
// DownloadEpisodeSwipeActions re-resolves stable IDs after downloads and requires
// downloaded state before play/requeue. Playback progress remains store-driven.
struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloadCoordinator: DownloadCoordinator
    @EnvironmentObject private var downloadActivityStore: DownloadActivityStore
    @EnvironmentObject private var historyStore: ListeningHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geometry in
            List {
                section(title: "Downloading", emptyText: "No active downloads",
                        activities: downloadActivityStore.activeActivities)
                section(title: "Downloaded on Device", emptyText: "No completed downloads",
                        activities: downloadCoordinator.downloadedActivities)
                archivedSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .responsiveListSizing()
            .episodeListPageWidth()
            .environment(\.adaptiveViewportWidth, geometry.size.width)
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
        .onboardingTip(.downloads)
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

    private var archivedSection: some View {
        Section {
            if recentlyArchivedEntries.isEmpty {
                Text("No archived episodes yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentlyArchivedEntries) { entry in
                    ArchivedEpisodeRow(entry: entry)
                        .modifier(DownloadEpisodeSwipeActions(subscriptionID: entry.subscriptionID,
                                                              episodeID: entry.episodeID))
                }
            }
        } header: {
            Text("Recently Archived").font(.title3.weight(.bold)).textCase(nil)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

    private func section(title: String, emptyText: String,
                         activities: [DownloadActivity]) -> some View {
        Section {
            if activities.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                ForEach(activities) { activity in
                    DownloadActivityRow(activity: activity)
                        .modifier(DownloadEpisodeSwipeActions(subscriptionID: activity.subscriptionID,
                                                              episodeID: activity.episodeID,
                                                              activity: activity))
                }
            }
        } header: {
            Text(title).font(.title3.weight(.bold)).textCase(nil)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

}

// MARK: - Archived Episode Row

private struct ArchivedEpisodeRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    let entry: ListeningHistoryEntry

    @State private var isRedownloading = false

    private var metrics: AdaptiveListRowMetrics {
        AdaptiveListRowMetrics(containerWidth: viewportWidth)
    }

    var body: some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        let artworkSize = metrics.artworkSize
        HStack(alignment: .center, spacing: metrics.rowSpacing) {
            // Artwork uses the same adaptive target size as other episode lists.
            VStack(alignment: .center, spacing: 4) {
                CachedArtworkImage(url: entry.artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
                    placeholderArtwork
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

            }

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.episodeTitle)
                    .font(.system(size: metrics.primaryFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.podcastTitle)
                    .font(.system(size: metrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(archivedMetadata)
                    .font(.system(size: metrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if archivedEpisode?.mediaKind == .video { VideoPillSmall() }
                    if archivedEpisode?.isExplicit == true { ExplicitPillSmall() }
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
                .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.vertical, metrics.verticalPadding)
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

    private var metrics: AdaptiveListRowMetrics {
        AdaptiveListRowMetrics(containerWidth: viewportWidth)
    }

    var body: some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        let artworkSize = metrics.artworkSize
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: metrics.rowSpacing) {
                CachedArtworkImage(url: artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
                    placeholderArtwork
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.episodeTitle)
                        .font(.system(size: metrics.primaryFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(activity.podcastTitle)
                        .font(.system(size: metrics.secondaryFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metadataText)
                        .font(.system(size: metrics.secondaryFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        mediaPill
                        if episode?.isExplicit == true { ExplicitPillSmall() }
                        Spacer(minLength: 8)
                        statusPill
                    }
                    .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Progress/error content aligns with the adaptive text-column inset.
            if activity.status == .downloading
                || activity.status == .waitingToRetry
                || activity.status == .paused {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: activity.progress, total: 1)
                        .tint(.purple)

                    HStack {
                        Text(progressText)
                            .font(.system(size: metrics.secondaryFontSize).monospacedDigit())
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
                        .font(.system(size: metrics.secondaryFontSize))
                        .foregroundStyle(.red)
                        .lineLimit(1)

                    Spacer()

                    controls
                }
                .padding(.leading, artworkSize + metrics.rowSpacing)
            }
        }
        .padding(.vertical, metrics.verticalPadding)
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
            .font(.system(size: metrics.secondaryFontSize - 1, weight: .bold))
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
            .font(.system(size: metrics.secondaryFontSize, weight: .bold))
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


            case .waitingToRetry:
                Button {
                    Task { await appState.resumeDownload(activity) }
                } label: {
                    Label("Retry Now", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)


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


            case .completed:
                EmptyView()
            }
        }
        .fixedSize()
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

// AI CONTEXT — Native Downloads swipe behaviour. Use stable IDs and resolve live
// episodes again after download; never queue a failed download or stale snapshot.
// Activity archival must use archiveDownload so active transfers are cancelled
// and activity/file/model state stays consistent. Full swipes are disabled.
private struct DownloadEpisodeSwipeActions: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    let subscriptionID: UUID
    let episodeID: UUID
    var activity: DownloadActivity? = nil
    @State private var isBusy = false

    private var episode: Episode? {
        subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID)
    }
    private var isPlaying: Bool { playbackCoordinator.currentEpisode?.id == episodeID }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if episode != nil, !isPlaying {
                    Button { perform(.play) } label: { Label("Play", systemImage: "play.fill") }
                        .tint(.green).disabled(isBusy)
                    Button { perform(.next) } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(.blue).disabled(isBusy)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !isPlaying {
                    if activity != nil || episode != nil {
                        Button { perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                            .tint(.purple).disabled(isBusy)
                    }
                    if episode != nil {
                        Button { perform(.last) } label: {
                            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        .tint(.orange).disabled(isBusy)
                    }
                }
            }
    }

    private enum Action { case play, next, last, archive }
    private func perform(_ action: Action) {
        guard !isBusy, !isPlaying else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            if action == .archive {
                if let activity { await appState.archiveDownload(activity) }
                else if let episode { await appState.archiveEpisode(episode) }
                return
            }
            guard let episode else { return }
            if episode.downloadState != .downloaded {
                await appState.downloadEpisodeForQueue(episode)
            }
            guard let current = subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID),
                  current.downloadState == .downloaded, !isPlaying else { return }
            switch action {
            case .play: await appState.playEpisode(current)
            case .next: appState.playEpisodeNext(current)
            case .last: appState.playEpisodeLast(current)
            case .archive: break
            }
        }
    }
}
