import SwiftUI

// AI CONTEXT — Views/QueueSheetView.swift ("Queue" sheet — the canonical
// design-system reference page per DESIGN.md). Shows Up Next + the priority-
// ordered downloaded queue from appState.downloadedQueue (overrides applied).
// Chrome (NavRules): centered title, SheetCloseButton ✕ top-right, pull-to-
// refresh for feed refresh. Swipe actions (allowsFullSwipe FALSE by design):
// leading Play / Play Next, trailing Archive / Play Last. Pin badges mark
// Play Next (blue) / Play Last (orange) overrides. Row offset/opacity state
// animates removals. Rows use 44 pt CachedArtworkImage thumbnails, matching the
// Priority/Downloads/Stats cache variant for reuse during repeated queue opens.
struct QueueSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var appearTime: Date?
    @State private var rowOffsets: [UUID: CGFloat] = [:]
    @State private var rowOpacities: [UUID: Double] = [:]
    @State private var expandedEpisodeID: UUID? = nil

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

                            let isExpanded = expandedEpisodeID == episode.id
                            VStack(alignment: .leading, spacing: 0) {
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
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sub?.title ?? "Unknown Podcast")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(episode.title)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                            .lineLimit(isExpanded ? nil : 2)
                                            .onTapGesture {
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                                    expandedEpisodeID = isExpanded ? nil : episode.id
                                                }
                                            }
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

                                if isExpanded, let raw = episode.description {
                                    let plain = HTMLDescriptionText.plainText(from: raw)
                                    if !plain.isEmpty {
                                        Text(sentenceParagraphs(plain))
                                            .font(.caption)
                                            .fontWeight(.regular)
                                            .foregroundStyle(.primary)
                                            .lineLimit(15)
                                            .padding(.top, 8)
                                            // indent to artwork left edge: index (20) + HStack spacing (12)
                                            .padding(.leading, 32)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if episode.mediaKind == .video || episode.isExplicit == true {
                                    HStack(spacing: 3) {
                                        if episode.mediaKind == .video { VideoPillSmall() }
                                        if episode.isExplicit == true { ExplicitPillSmall() }
                                    }
                                }
                            }
                            .offset(y: rowOffsets[episode.id] ?? 0)
                            .opacity(rowOpacities[episode.id] ?? 1)
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
                                    animateRow(id: episode.id, direction: .up)
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

                                if pinnedNext || pinnedLast {
                                    Button {
                                        animateRow(id: episode.id, direction: .down)
                                        appState.unpinEpisode(episode)
                                    } label: {
                                        Label("Unpin", systemImage: "pin.slash.fill")
                                    }
                                    .tint(.teal)
                                }

                                Button {
                                    animateRow(id: episode.id, direction: .down)
                                    appState.playEpisodeLast(episode)
                                } label: {
                                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await refreshQueue()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.regularMaterial)
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

    private func refreshQueue() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await appState.refreshAllSubscriptions(includeBackoffFeeds: true)
        await appState.runAutoArchiveIfNeeded(reason: "queue.manualRefresh", force: true)
        isRefreshing = false
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

    private enum RowMoveDirection { case up, down }

    private func animateRow(id: UUID, direction: RowMoveDirection) {
        let targetOffset: CGFloat = direction == .up ? -10 : 10
        rowOffsets[id] = 0
        rowOpacities[id] = 1
        withAnimation(.easeIn(duration: 0.18)) {
            rowOffsets[id] = targetOffset
            rowOpacities[id] = 0.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                rowOffsets[id] = 0
                rowOpacities[id] = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            rowOffsets.removeValue(forKey: id)
            rowOpacities.removeValue(forKey: id)
        }
    }

    private func sentenceParagraphs(_ text: String) -> String {
        // Split on sentence-ending punctuation followed by whitespace, then
        // rejoin with a paragraph gap so each sentence starts on its own line.
        let pattern = #"([.?!…]+)\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func artwork(url: URL?, pinnedNext: Bool, pinnedLast: Bool) -> some View {
        CachedArtworkImage(url: url, targetSize: CGSize(width: 44, height: 44)) {
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
