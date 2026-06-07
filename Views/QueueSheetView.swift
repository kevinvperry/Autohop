import SwiftUI

struct QueueSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var appearTime: Date?

    private let logger = AppLogger.shared

    var body: some View {
        NavigationStack {
            Group {
                if appState.downloadedQueue.isEmpty {
                    ContentUnavailableView(
                        "Queue is Empty",
                        systemImage: "tray",
                        description: Text("Download an episode to start listening.")
                    )
                } else {
                    List {
                        ForEach(Array(appState.downloadedQueue.enumerated()), id: \.element.id) { index, episode in
                            let sub = appState.subscriptionStore.subscription(id: episode.subscriptionID)
                            let isCurrent = appState.currentPlayerEpisode?.id == episode.id

                            let pinnedNext = appState.isQueuePinnedNext(episode)
                            let pinnedLast = appState.isQueuePinnedLast(episode)

                            HStack(spacing: 12) {
                                if isCurrent {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.purple)
                                        .frame(width: 20)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, alignment: .center)
                                }

                                VStack(alignment: .center, spacing: 4) {
                                    artwork(url: sub?.artworkURL, pinnedNext: pinnedNext, pinnedLast: pinnedLast)
                                    if episode.mediaKind == .video || episode.isExplicit == true {
                                        VStack(spacing: 3) {
                                            if episode.mediaKind == .video { VideoBadge() }
                                            if episode.isExplicit == true { ExplicitPill() }
                                        }
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub?.title ?? "Unknown Podcast")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(episode.title)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                    HStack(spacing: 4) {
                                        if let date = episode.publishedAt {
                                            Text(formatPublishedDate(date))
                                                .lineLimit(1)
                                        }
                                        if let remaining = remainingTime(for: episode) {
                                            Text("•")
                                            Text(remaining)
                                                .lineLimit(1)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    if pinnedNext || pinnedLast {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(pinnedNext ? Color.blue : Color.orange)
                                    }
                                    if let dur = episode.durationSeconds {
                                        Text(formatDuration(dur))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .listRowBackground(isCurrent ? Color.purple.opacity(0.08) : Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    dismiss()
                                    Task { await appState.playEpisode(episode) }
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                }
                                .tint(.green)

                                Button {
                                    appState.playEpisodeNext(episode)
                                } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    Task {
                                        await appState.archiveEpisodeAndPlayNext(episode)
                                    }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.purple)

                                Button {
                                    appState.playEpisodeLast(episode)
                                } label: {
                                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        DownloadShortcutButton(isActive: hasActiveDownloads)
                    }
                    .accessibilityLabel("Downloads")
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        refreshQueue()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh feeds")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            let t = Date()
            appearTime = t
            logger.info("nav.appear", "QueueSheetView appeared", metadata: [
                "queueCount": "\(appState.downloadedQueue.count)"
            ])
            ResourceMonitor.shared.logSnapshot(reason: "nav.queueAppear")
        }
        .onDisappear {
            let durationMs = appearTime.map { Int(Date().timeIntervalSince($0) * 1000) }
            logger.info("nav.disappear", "QueueSheetView dismissed", metadata: [
                "visibleMs": durationMs.map(String.init) ?? "unknown"
            ])
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopReturnToPlayer)) { _ in
            dismiss()
        }
    }

    private var hasActiveDownloads: Bool {
        !appState.downloadActivityStore.activeActivities.isEmpty
    }

    private func refreshQueue() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await appState.refreshAllSubscriptions(includeBackoffFeeds: true)
            await appState.runAutoArchiveIfNeeded(reason: "queue.manualRefresh", force: true)
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func remainingTime(for episode: Episode) -> String? {
        let elapsed = appState.effectivePlaybackTime(for: episode)
        guard elapsed > 0, let duration = episode.durationSeconds, duration > 0 else { return nil }
        let remaining = max(0, duration - elapsed)
        guard remaining > 0 else { return nil }
        return "\(formatDuration(remaining)) left remaining"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatPublishedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func artwork(url: URL?, pinnedNext: Bool, pinnedLast: Bool) -> some View {
        CachedArtworkImage(url: url) {
            placeholderArtwork
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
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
}

private struct DownloadShortcutButton: View {
    let isActive: Bool
    // Drives the repeating pulse via a standard SwiftUI animation rather than
    // TimelineView(.animation), which runs at 60 Hz unconditionally and creates
    // an AttributeGraph cycle when combined with an explicit .animation modifier.
    @State private var pulsing = false

    var body: some View {
        Image(systemName: isActive ? "arrow.down.circle.fill" : "arrow.down.circle")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isActive ? Color.purple : Color.primary)
            .scaleEffect(pulsing ? 1.0 : 0.85)
            .onAppear {
                if isActive { startPulse() }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    startPulse()
                } else {
                    withAnimation(.default) { pulsing = false }
                }
            }
    }

    private func startPulse() {
        // Kick off from a known state so the animation always starts cleanly.
        pulsing = false
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
