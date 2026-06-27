import SwiftUI

// AI CONTEXT — Views/QueueSheetView.swift ("Queue" sheet — the canonical
// design-system reference page per DESIGN.md). Shows Up Next + the priority-
// ordered downloaded queue from appState.downloadedQueue (overrides applied).
// Chrome (NavRules): centered title, SheetCloseButton ✕ top-right, pull-to-
// refresh for feed refresh. Swipe actions (allowsFullSwipe FALSE by design):
// leading Play / Play Next, trailing Archive / Play Last. Pin badges mark
// Play Next (blue) / Play Last (orange) overrides.
// EXPANDED ROW: tapping an episode title toggles expandedEpisodeID, unclamping
// the title and revealing the full plain-text description, plus two small purple
// circular glass buttons at the bottom-right (matching PodcastDetailView.refreshButton):
//   • list.bullet — navigates to PodcastDetailView for that subscription
//   • gearshape   — navigates to SubscriptionSettingsView for that subscription
// Both call their respective callbacks (onOpenPodcastDetail / onOpenPodcastSettings);
// the presenter (PlayerView) dismisses this Queue sheet and presents the target
// view in its place ("replace the queue") using the staged-ID pattern so the
// new sheet isn't presented during the Queue sheet's dismissal animation.
// ACTION ANIMATIONS: the List carries `.animation(value: downloadedQueue.map(\.id))`
// so any order/membership change glides rows to their new slots. performMove
// (Play Next/Last) fires a light haptic, pops the row + flashes a directional
// arrow badge (blue up / orange down) at the leading edge, then commits the
// reorder so the row visibly travels to the top/bottom. performArchive fires a
// success haptic, slides the row trailing while shrinking/fading it as an
// archive-box badge fades in, then commits the archive so the gap closes.
// performUnpin returns a row to its natural slot. Per-row transient state lives
// in rowOffsets(CGSize)/rowOpacities/rowScales/archivingIDs/moveIndicators;
// move/archiveHapticTrigger drive .sensoryFeedback. Rows use 44 pt
// CachedArtworkImage thumbnails, matching the Priority/Downloads/Stats cache
// variant for reuse during repeated queue opens.
struct QueueSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var appearTime: Date?
    // Per-row transient transforms driving the action animations.
    @State private var rowOffsets: [UUID: CGSize] = [:]
    @State private var rowOpacities: [UUID: Double] = [:]
    @State private var rowScales: [UUID: CGFloat] = [:]
    // Rows currently playing the archive "file into a box" animation.
    @State private var archivingIDs: Set<UUID> = []
    // Transient directional cue shown while a row moves to the top/bottom.
    @State private var moveIndicators: [UUID: RowMoveDirection] = [:]
    // Bumped to fire the matching haptic via .sensoryFeedback.
    @State private var moveHapticTrigger = 0
    @State private var archiveHapticTrigger = 0
    @State private var expandedEpisodeID: UUID? = nil

    /// Tapped-gear shortcut from an expanded row. The presenter (PlayerView) uses
    /// this to dismiss the Queue sheet and open that podcast's Settings in its
    /// place ("replace the queue"). Optional so previews/other callers still work.
    var onOpenPodcastSettings: ((UUID) -> Void)? = nil
    /// Tapped-podcast shortcut from an expanded row. The presenter (PlayerView)
    /// dismisses the Queue sheet and opens that podcast's Detail page in its place.
    var onOpenPodcastDetail: ((UUID) -> Void)? = nil

    private let logger = AppLogger.shared

    var body: some View {
        NavigationStack {
            Group {
                if appState.downloadedQueue.isEmpty {
                    ContentUnavailableView(
                        "Your queue builds itself",
                        systemImage: "square.stack",
                        description: Text("As you subscribe and episodes download, they line up here in priority order — newest first, ready to play.")
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

                                if isExpanded {
                                    if let raw = episode.description {
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
                                    // Bottom-right shortcuts: podcast list button + settings gear.
                                    // Both are small purple circular glass buttons matching
                                    // PodcastDetailView.refreshButton. Shown only for real subs.
                                    if sub != nil {
                                        HStack {
                                            Spacer()
                                            Button {
                                                onOpenPodcastDetail?(episode.subscriptionID)
                                            } label: {
                                                let icon = Image(systemName: "list.bullet")
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(.purple)
                                                    .frame(width: 30, height: 30)
                                                if #available(iOS 26, *) {
                                                    icon.glassEffect(in: Circle())
                                                } else {
                                                    icon.background(.ultraThinMaterial, in: Circle())
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Go to podcast")
                                            Button {
                                                onOpenPodcastSettings?(episode.subscriptionID)
                                            } label: {
                                                let gearIcon = Image(systemName: "gearshape")
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(.purple)
                                                    .frame(width: 30, height: 30)
                                                if #available(iOS 26, *) {
                                                    gearIcon.glassEffect(in: Circle())
                                                } else {
                                                    gearIcon.background(.ultraThinMaterial, in: Circle())
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Podcast settings")
                                        }
                                        .padding(.top, 8)
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
                            .scaleEffect(rowScales[episode.id] ?? 1)
                            .offset(rowOffsets[episode.id] ?? .zero)
                            .opacity(rowOpacities[episode.id] ?? 1)
                            // Action cues composite on top at full opacity even as the
                            // row content fades (archive) — the move arrow rides at the
                            // leading edge, the archive box at the trailing edge.
                            .overlay(alignment: .leading) {
                                if let dir = moveIndicators[episode.id] {
                                    moveBadge(dir)
                                }
                            }
                            .overlay(alignment: .trailing) {
                                if archivingIDs.contains(episode.id) {
                                    archiveBadge()
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
                                    performMove(episode, direction: .up)
                                } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    performArchive(episode)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.purple)

                                if pinnedNext || pinnedLast {
                                    Button {
                                        performUnpin(episode)
                                    } label: {
                                        Label("Unpin", systemImage: "pin.slash.fill")
                                    }
                                    .tint(.teal)
                                }

                                Button {
                                    performMove(episode, direction: .down)
                                } label: {
                                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Animate structural changes (row moves to top/bottom, archive
                    // gap-close) whenever the queue order/membership changes. `.smooth`
                    // is a no-bounce spring tuned for fluid position changes.
                    .animation(.smooth(duration: 0.45), value: appState.downloadedQueue.map(\.id))
                    .sensoryFeedback(.impact(weight: .light), trigger: moveHapticTrigger)
                    .sensoryFeedback(.success, trigger: archiveHapticTrigger)
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
        let s = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatPublishedDate(_ date: Date) -> String {
        relativePublishedLabel(date)   // shared tiered formatter (EpisodeBadges.swift)
    }

    private enum RowMoveDirection: Equatable { case up, down }

    // MARK: - Action animations

    /// Play Next / Play Last. Fires a light haptic, pops + flashes a directional
    /// arrow on the row, then commits the reorder — the List's `.animation(value:)`
    /// glides the row to its new top/bottom slot.
    private func performMove(_ episode: Episode, direction: RowMoveDirection) {
        let id = episode.id
        moveHapticTrigger += 1
        // Immediate feedback as the swipe closes: gentle lift + directional cue.
        withAnimation(.smooth(duration: 0.2)) {
            moveIndicators[id] = direction
            rowScales[id] = 1.03
        }
        // Defer the actual reorder until the swipe-action row has finished closing.
        // Committing while the row is still offset made the List reshuffle the
        // neighbours before this row settled — so an adjacent episode appeared to
        // jump over it. With the swipe closed first, the List's .smooth
        // value-animation glides this row cleanly from its resting position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            switch direction {
            case .up:   appState.playEpisodeNext(episode)
            case .down: appState.playEpisodeLast(episode)
            }
            withAnimation(.smooth(duration: 0.4)) { rowScales[id] = 1.0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(.easeOut(duration: 0.25)) { moveIndicators[id] = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            rowScales.removeValue(forKey: id)
        }
    }

    /// Archive. Fires a success haptic, slides the row toward the trailing edge
    /// while shrinking + fading it as an archive box fades in, then commits the
    /// archive — the List's `.animation(value:)` closes the gap behind it.
    private func performArchive(_ episode: Episode) {
        let id = episode.id
        archiveHapticTrigger += 1
        withAnimation(.easeIn(duration: 0.3)) {
            _ = archivingIDs.insert(id)
            rowOffsets[id] = CGSize(width: 60, height: 0)
            rowScales[id] = 0.8
            rowOpacities[id] = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            Task { await appState.archiveEpisodeAndPlayNext(episode) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            archivingIDs.remove(id)
            rowOffsets.removeValue(forKey: id)
            rowScales.removeValue(forKey: id)
            rowOpacities.removeValue(forKey: id)
        }
    }

    /// Unpin. Removing the override returns the row to its natural priority slot;
    /// the List's `.animation(value:)` glides it there. Light haptic for feedback.
    private func performUnpin(_ episode: Episode) {
        moveHapticTrigger += 1
        appState.unpinEpisode(episode)
    }

    // MARK: - Action cue badges

    @ViewBuilder
    private func moveBadge(_ direction: RowMoveDirection) -> some View {
        let isUp = direction == .up
        Image(systemName: isUp ? "arrow.up.to.line" : "arrow.down.to.line")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.white)
            .padding(6)
            .background(Circle().fill(isUp ? Color.blue : Color.orange))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(.leading, 2)
            .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func archiveBadge() -> some View {
        Image(systemName: "archivebox.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(Circle().fill(Color.purple))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .padding(.trailing, 8)
            .transition(.scale.combined(with: .opacity))
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
