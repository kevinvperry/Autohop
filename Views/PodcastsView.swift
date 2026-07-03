import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/PodcastsView.swift ("Subscriptions" page — the app's
// home page, see PAGES.md). Ranked list of real subscriptions (browse
// subscriptions filtered out; Inactive subscriptions remain visible at the
// bottom with the orange pill); drag-to-reorder in Reorder mode rewrites
// priorityRank for the whole list. Each row shows artwork, the show title and
// the show's (channel-level) description clamped to 2 lines — styled to match
// PodcastDetailView's episode-row title/description (subheadline-semibold /
// caption-secondary) — plus a metadata line "Updated: <relative age>"
// (mins/hours → "Yesterday" → "2…6 days ago" → exact date; no episode length) and a
// colour-coded status pill for the podcast's latest episode (pills hide in
// Reorder mode so they never fight the drag grips). Pill logic: archived
// episodes show Played (not Archived) when Episode.wasCompleted is true, so
// auto-archive doesn't erase the "you finished this" signal; not-downloaded
// latest episodes excluded by Download Filters show the grey Skipped pill
// instead of the inline Download button. Toolbar: hamburger menu
// (MenuSheetView) leading, + (pushes DiscoverView as a full page via
// navigationDestination — parent of Podcast Search) trailing; Reorder and
// refresh-all live on the action row under the heading. MiniPlayerBar docks
// at the bottom except during reorder. Rows navigate to PodcastDetailView.
// Priority-list artwork uses 44 pt CachedArtworkImage thumbnails; feed refresh
// updates Subscription.artworkURL so changed podcast art can flow into this cache.
// FIRST-RUN: when there are no real subscriptions, emptySubscriptionsView teaches
// the Priority Stack model and offers Find shows (Discover), Import subscriptions
// (in-place OPML fileImporter → AppState.importOPML), and Starter Packs
// (StarterPacksView). The non-empty list shows the dismissible
// GettingStartedChecklist at the top; onMove records the "reorder" onboarding step
// (GettingStartedChecklist.reorderedKey) and requests the priorityStack coach mark.
struct PodcastsView: View {
    @EnvironmentObject private var appState: AppState
    /// Progress ticks publish on this dedicated model (not AppState) — reading
    /// appState.downloadProgress in body would render stale.
    @EnvironmentObject private var downloadProgressModel: DownloadProgressModel
    @State private var editMode: EditMode = .inactive
    @State private var isRefreshingAll = false
    @State private var showMenu = false
    @State private var showDiscover = false
    @State private var showOPMLImporter = false
    @State private var showStarterPacks = false

    /// Subscriptions visible in the Priority Sort list.
    /// Browse-only subscriptions (browseDate != nil) are invisible here —
    /// they only become visible once the user explicitly presses Subscribe.
    private var visibleSubscriptions: [Subscription] {
        appState.subscriptionStore.subscriptions.filter { $0.browseDate == nil }
    }

    var body: some View {
        Group {
            if visibleSubscriptions.isEmpty {
                emptySubscriptionsView
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    GettingStartedChecklist()
                        .padding(.horizontal, 20)
                        .padding(.top, 14)

                    // Action row — page actions live here, below the heading,
                    // so the title bar stays pure navigation (NavRules).
                    HStack {
                        Button {
                            withAnimation {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        } label: {
                            let reorderLabel = Label(
                                editMode == .active ? "Done" : "Reorder",
                                systemImage: editMode == .active ? "checkmark" : "arrow.up.arrow.down"
                            )
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)

                            // iOS glass; purple-tinted while in the active "Done" state.
                            if #available(iOS 26, *) {
                                if editMode == .active {
                                    reorderLabel.glassEffect(.regular.tint(.purple), in: Capsule())
                                } else {
                                    reorderLabel.glassEffect(in: Capsule())
                                }
                            } else {
                                reorderLabel.background(
                                    editMode == .active ? Color.purple.opacity(0.85) : Color.clear,
                                    in: Capsule()
                                )
                                .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)

                        if editMode == .active {
                            Text("drag to set priority")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 4)
                        }

                        Spacer()

                        if editMode != .active {
                            Button {
                                refreshAll()
                            } label: {
                                let refreshIcon = Group {
                                    if isRefreshingAll {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.purple)
                                    }
                                }
                                .frame(width: 30, height: 30)

                                // Circular iOS glass button.
                                if #available(iOS 26, *) {
                                    refreshIcon.glassEffect(in: Circle())
                                } else {
                                    refreshIcon.background(.ultraThinMaterial, in: Circle())
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isRefreshingAll)
                            .accessibilityLabel("Refresh all feeds")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                    priorityListCard
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showMenu = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDiscover = true
                } label: {
                    Label("Add Podcast", systemImage: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hidden during reorder so the drag operation gets the full list.
            if editMode != .active {
                MiniPlayerBar()
            }
        }
        .onAppear {
            if !visibleSubscriptions.isEmpty { appState.requestTip(.priorityStack) }
        }
        .sheet(isPresented: $showMenu) { MenuSheetView() }
        .navigationDestination(isPresented: $showDiscover) { DiscoverView() }
        .fileImporter(
            isPresented: $showOPMLImporter,
            allowedContentTypes: [.xml, .plainText, UTType(filenameExtension: "opml") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                let summary = await appState.importOPML(from: url)
                if summary.imported > 0 {
                    appState.onboardingToast = "Imported \(summary.imported) show\(summary.imported == 1 ? "" : "s") — welcome aboard."
                }
            }
        }
        .sheet(isPresented: $showStarterPacks) { StarterPacksView() }
    }

    /// First-run empty state for a brand-new user (ONBOARDING_PLAN.md Phase 1b).
    /// Teaches the Priority Stack model and offers the two ways to fill it:
    /// find shows in Discover, or import an existing subscription list.
    private var emptySubscriptionsView: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.16))
                    .frame(width: 104, height: 104)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.purple)
            }

            VStack(spacing: 8) {
                Text("Your Priority Stack is empty")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Add the shows you love. Autohop plays the newest episode from each, top to bottom — drag to set the order once you've subscribed.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(white: 0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)

            VStack(spacing: 10) {
                Button { showDiscover = true } label: {
                    emptyStateButtonLabel("Find shows", filled: true)
                }
                .buttonStyle(.plain)

                Button { showOPMLImporter = true } label: {
                    emptyStateButtonLabel("Import subscriptions", filled: false)
                }
                .buttonStyle(.plain)

                Button { showStarterPacks = true } label: {
                    Text("Not sure where to start?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.purple)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyStateButtonLabel(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(filled ? .white : .purple)
            .padding(.horizontal, 28)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(filled ? Color.purple : Color.purple.opacity(0.14))
            )
    }

    private func refreshAll() {
        isRefreshingAll = true
        Task {
            await appState.refreshAllSubscriptions(includeBackoffFeeds: true)
            isRefreshingAll = false
        }
    }

    /// The Priority Stack list inside an iOS-glass card, matching the bell button
    /// and toolbar capsule (same treatment as PodcastDetailView's episode list).
    @ViewBuilder
    private var priorityListCard: some View {
        let list = List {
            ForEach(visibleSubscriptions) { subscription in
                let isPlaying = subscription.latestEpisode.map { appState.currentPlayerEpisode?.id == $0.id } ?? false
                NavigationLink {
                    PodcastDetailView(subscriptionID: subscription.id)
                } label: {
                    subscriptionRow(subscription)
                }
                // Idle rows are clear so the card's glass shows through; the
                // playing row keeps the faint purple tint.
                .listRowBackground(isPlaying ? Color.purple.opacity(0.08) : Color.clear)
                .moveDisabled(editMode != .active)
            }
            .onMove { from, to in
                guard editMode == .active else { return }
                appState.subscriptionStore.reorder(from: from, to: to)
                // Onboarding: mark the "reorder your Priority Stack" step done.
                UserDefaults.standard.set(true, forKey: GettingStartedChecklist.reorderedKey)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)

        Group {
            if #available(iOS 26, *) {
                list.glassEffect(in: RoundedRectangle(cornerRadius: 16))
            } else {
                list.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func subscriptionRow(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Top band: artwork + titles
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .center, spacing: 4) {
                    artwork(url: sub.artworkURL)
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Title + show (channel-level) description, styled to match the
                    // episode rows on PodcastDetailView (subheadline-semibold title,
                    // caption-secondary description).
                    Text(sub.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        // Reserve room on the right so the title never runs under
                        // the floating video/explicit pills.
                        .padding(.trailing, 30)

                    if let description = sub.description.map(stripHTML), !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }

            // Bottom band: rank pill (under artwork) + metadata row (under titles)
            if let episode = sub.latestEpisode {
                HStack(alignment: .center, spacing: 12) {
                    // Rank pill — centred under the artwork; min width 44pt so it
                    // stays aligned with the artwork above for single-digit numbers,
                    // but expands naturally for two- or three-digit numbers.
                    rankPill(sub.priorityRank)
                        .frame(minWidth: 44, alignment: .center)

                    // Metadata: "Updated: <relative date>" · Spacer · status pill
                    HStack(spacing: 4) {
                        if let date = episode.publishedAt {
                            Text("Updated: \(latestEpisodeRelativeLabel(date))")
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        // Pills hide in Reorder mode so the row's right edge
                        // belongs to the drag grips (NavRules).
                        if editMode != .active {
                            if sub.excludeFromAutoFeedRefresh {
                                EpisodeStatusPill(kind: .inactive)
                            } else if episode.playedState == .played {
                                EpisodeStatusPill(kind: .played)
                            } else if episode.playedState == .archived {
                                // Completed episodes keep Played even after
                                // auto-archive removes them from the queue.
                                EpisodeStatusPill(kind: episode.wasCompleted ? .played : .archived)
                            } else if statusKind(for: episode, sub: sub) == .skipped {
                                EpisodeStatusPill(kind: .skipped)
                            } else if episode.downloadState == .notDownloaded || episode.downloadState == .failed {
                                Button("Download") {
                                    Task { await appState.downloadLatestEpisode(for: sub) }
                                }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                EpisodeStatusPill(kind: statusKind(for: episode, sub: sub))
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                // A little extra separation between the status-pill row and the
                // titles above.
                .padding(.top, 3)

                if episode.downloadState == .downloading,
                   let progress = downloadProgressModel.progress[episode.id] {
                    ProgressView(value: progress, total: 1.0)
                        .tint(.purple)
                        .animation(.linear(duration: 0.3), value: progress)
                        .padding(.leading, 56)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topTrailing) {
            if let episode = sub.latestEpisode,
               episode.mediaKind == .video || episode.isExplicit == true {
                HStack(spacing: 3) {
                    if episode.mediaKind == .video { VideoPillSmall() }
                    if episode.isExplicit == true { ExplicitPillSmall() }
                }
                // Push the pills out over the trailing nav-arrow column so they sit
                // above the chevron rather than overlapping the headline.
                .offset(x: 18)
            }
        }
    }

    private func statusKind(for episode: Episode, sub: Subscription) -> EpisodeStatusKind {
        switch episode.playedState {
        case .playing:
            // Only the episode actively loaded in the player is "Now Playing".
            // Any other episode with .playing state was started but not finished.
            return appState.currentPlayerEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
        case .played:   return .played
        case .archived: return episode.wasCompleted ? .played : .archived
        case .unplayed:
            let position = appState.effectivePlaybackTime(for: episode)
            if position > 0 { return .partiallyPlayed }
            if episode.downloadState == .notDownloaded,
               sub.downloadFilterSettings.evaluation(for: episode).isIncluded == false {
                return .skipped
            }
            return episode.downloadState == .downloaded ? .queued : .unplayed
        }
    }

    @ViewBuilder
    private func rankPill(_ rank: Int) -> some View {
        let label = Text("\(rank)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .glassEffect(in: Capsule())
        } else {
            label
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Relative age of the most recent episode for the "Latest episode:" metadata
    /// line: mins → hours → "Yesterday" → "2…6 days ago" → an abbreviated exact date
    /// (year shown only when it isn't the current year). Days are counted by calendar
    /// day (not elapsed seconds) so "Yesterday"/"N days ago" match the wall clock.
    private func latestEpisodeRelativeLabel(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "\(mins) min\(mins == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let dayDiff = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if dayDiff == 1 { return "Yesterday" }
        if (2...6).contains(dayDiff) { return "\(dayDiff) days ago" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func artwork(url: URL?) -> some View {
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

// `EpisodeStatusKind` and `EpisodeStatusPill` are shared in Views/EpisodeBadges.swift.

// Show-description cleanup for the subscription-list rows. Mirrors the file-private
// helpers in PodcastDetailView / SubscriptionSettingsView (same tag-strip + entity
// decode). NOTE: this is now the THIRD copy — a shared HTMLText util is warranted.
private func stripHTML(_ html: String) -> String {
    let withoutTags = html.replacingOccurrences(
        of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression
    )
    return decodeHTMLEntities(withoutTags)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func decodeHTMLEntities(_ text: String) -> String {
    var result = text
    // Numeric decimal (&#NNN;) and hex (&#xHHH;) character references.
    for pattern in [#"&#(\d+);"#, #"&#x([0-9a-fA-F]+);"#] {
        let radix = pattern.contains("x") ? 16 : 10
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let mutable = NSMutableString(string: result)
        var offset = 0
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let numRange = Range(match.range(at: 1), in: result),
                  let codePoint = UInt32(result[numRange], radix: radix),
                  let scalar = Unicode.Scalar(codePoint) else { continue }
            let replacement = String(scalar)
            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            mutable.replaceCharacters(in: adjustedRange, with: replacement)
            offset += replacement.count - match.range.length
        }
        result = mutable as String
    }
    // Named entities — same table as PodcastDetailView so descriptions decode
    // identically between the list and the detail page.
    let named: [(String, String)] = [
        ("&amp;",   "&"),  ("&lt;",    "<"),  ("&gt;",    ">"),
        ("&quot;",  "\""), ("&apos;",  "'"),  ("&nbsp;",  " "),
        ("&mdash;", "—"),  ("&ndash;", "–"),  ("&rsquo;", "\u{2019}"),
        ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ("&hellip;","\u{2026}"), ("&bull;",  "\u{2022}"), ("&copy;",  "\u{00A9}"),
        ("&reg;",   "\u{00AE}"), ("&trade;", "\u{2122}"), ("&euro;",  "\u{20AC}"),
        ("&pound;", "\u{00A3}"), ("&yen;",   "\u{00A5}"), ("&cent;",  "\u{00A2}"),
    ]
    for (entity, replacement) in named {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
}
