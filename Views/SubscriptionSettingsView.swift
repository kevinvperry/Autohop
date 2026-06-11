import SwiftUI

// AI CONTEXT — Views/SubscriptionSettingsView.swift ("Podcast Settings" page,
// gear icon from a podcast's episode list). Per-podcast configuration, all
// persisted on the Subscription via SubscriptionStore. Sections: Podcast
// (editable title, numeric priority rank, read-only author), Playback (speed
// 1.0–2.5x, Vocal Boost, Trim Silence, start/end skip — live-applied via
// AppState if this podcast is playing), Automation (per-podcast notifications,
// exclude from auto feed refresh), Auto Archive (three rules), Chapter Filter
// (only when latest episode has chapters; position-based), Feed (read-only
// URL), Danger (unsubscribe with confirmation). Footer copy must stay in sync
// with FEATURES.md §10. stripHTML/decodeHTMLEntities below clean feed-supplied
// description text for display.
private func stripHTML(_ html: String) -> String {
    // Strip tags, then decode entities.
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
    // Numeric decimal entities &#NNN;
    if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
        let nsResult = NSMutableString(string: result)
        var offset = 0
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let numRange = Range(match.range(at: 1), in: result),
                  let codePoint = UInt32(result[numRange]),
                  let scalar = Unicode.Scalar(codePoint) else { continue }
            let replacement = String(scalar)
            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            nsResult.replaceCharacters(in: adjustedRange, with: replacement)
            offset += replacement.count - match.range.length
        }
        result = nsResult as String
    }
    // Numeric hex entities &#xHHH;
    if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
        let nsResult = NSMutableString(string: result)
        var offset = 0
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let numRange = Range(match.range(at: 1), in: result),
                  let codePoint = UInt32(result[numRange], radix: 16),
                  let scalar = Unicode.Scalar(codePoint) else { continue }
            let replacement = String(scalar)
            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            nsResult.replaceCharacters(in: adjustedRange, with: replacement)
            offset += replacement.count - match.range.length
        }
        result = nsResult as String
    }
    // Named entities
    for (entity, replacement) in namedHTMLEntities {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
}

private let namedHTMLEntities: [(String, String)] = [
    ("&amp;",   "&"),  ("&lt;",    "<"),  ("&gt;",    ">"),
    ("&quot;",  "\""), ("&apos;",  "'"),  ("&nbsp;",  " "),
    ("&mdash;", "—"),  ("&ndash;", "–"),  ("&rsquo;", "\u{2019}"),
    ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
    ("&hellip;","\u{2026}"), ("&bull;",  "\u{2022}"), ("&copy;",  "\u{00A9}"),
    ("&reg;",   "\u{00AE}"), ("&trade;", "\u{2122}"), ("&euro;",  "\u{20AC}"),
    ("&pound;", "\u{00A3}"), ("&yen;",   "\u{00A5}"), ("&cent;",  "\u{00A2}"),
]

struct SubscriptionSettingsView: View {
    let subscriptionID: UUID
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirm = false
    @State private var isRefreshing = false
    @State private var showTitleEditor = false
    @State private var showPriorityEditor = false
    @State private var draftTitle = ""
    @State private var draftPriorityRank = 1
    @State private var episodeToShare: Episode?
    @Environment(\.dismiss) private var dismiss

    private var subscription: Subscription? {
        appState.subscriptionStore.subscription(id: subscriptionID)
    }

    var body: some View {
        Group {
            if let sub = subscription {
                Form {
                    podcastSection(sub)
                    playbackSection(sub)
                    automationSection(sub)
                    if let episode = sub.latestEpisode, !episode.chapters.isEmpty {
                        chapterSection(sub, episode: episode)
                    }
                    feedSection(sub)
                    dangerSection(sub)
                }
            } else {
                ContentUnavailableView(
                    "Subscription Not Found",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
        }
        .navigationTitle(subscription?.title ?? "Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
                    ReturnToPlayerButton()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let subscription else { return }
                    isRefreshing = true
                    Task {
                        await appState.refreshSubscription(subscription)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(subscription == nil || isRefreshing)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    episodeToShare = subscription?.latestEpisode
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(subscription?.latestEpisode == nil)
            }
        }
        .sheet(item: $episodeToShare) { ep in
            EpisodeShareSheet(episode: ep, subscription: subscription)
        }
        .confirmationDialog(
            "Unsubscribe from \(subscription?.title ?? "this podcast")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                appState.subscriptionStore.remove(subscriptionID: subscriptionID)
                dismiss()
            }
        } message: {
            Text("Your settings for this podcast will be deleted. Downloaded episodes are not removed.")
        }
        .sheet(isPresented: $showTitleEditor) {
            EditTitleSheet(title: $draftTitle) {
                appState.subscriptionStore.updateTitle(subscriptionID: subscriptionID, title: draftTitle)
                showTitleEditor = false
            }
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $showPriorityEditor) {
            EditPrioritySheet(
                priorityRank: $draftPriorityRank,
                maxRank: max(appState.subscriptionStore.subscriptions.count, 1)
            ) {
                appState.subscriptionStore.updatePriorityRank(
                    subscriptionID: subscriptionID,
                    priorityRank: draftPriorityRank
                )
                showPriorityEditor = false
            }
            .presentationDetents([.height(230)])
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func podcastSection(_ sub: Subscription) -> some View {
        Section("Podcast") {
            Button {
                draftTitle = sub.title
                showTitleEditor = true
            } label: {
                LabeledContent("Title") {
                    Text(sub.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Button {
                draftPriorityRank = sub.priorityRank
                showPriorityEditor = true
            } label: {
                LabeledContent("Priority rank") {
                    Text("#\(sub.priorityRank)")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if let author = sub.author {
                LabeledContent("Author", value: author)
            }
        }
    }

    @ViewBuilder
    private func playbackSection(_ sub: Subscription) -> some View {
        Section {
            Picker("Playback speed", selection: speedBinding(sub)) {
                ForEach(PlaybackPreference.speedOptions, id: \.self) { speed in
                    Text(speed == PlaybackPreference.default.speed ? "\(PlaybackPreference.speedLabel(speed)) (default)" : PlaybackPreference.speedLabel(speed)).tag(speed)
                }
            }

            Picker("Vocal Boost", selection: vocalBoostBinding(sub)) {
                ForEach(VocalBoostLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }

            Picker("Trim Silence", selection: trimSilenceBinding(sub)) {
                ForEach(TrimSilenceAmount.allCases, id: \.self) { amount in
                    Text(amount.title).tag(amount)
                }
            }

            Stepper(value: startSkipBinding(sub), in: 0...300, step: 5) {
                LabeledContent("Start skip") {
                    Text(skipLabel(sub.playbackPreference.startSkipSeconds))
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: endSkipBinding(sub), in: 0...300, step: 5) {
                LabeledContent("End skip") {
                    Text(skipLabel(sub.playbackPreference.endSkipSeconds))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("These settings apply to every episode of this podcast. Vocal Boost lifts speech above music and background sound — Strong targets a −14 LUFS loudness goal for the clearest spoken audio. Trim Silence removes quiet gaps (audio episodes only). Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically.")
        }
    }

    @ViewBuilder
    private func automationSection(_ sub: Subscription) -> some View {
        Section {
            Toggle("New episode notifications", isOn: notificationsBinding(sub))
            Toggle("Exclude from Auto Feed Refresh", isOn: autoFeedRefreshExclusionBinding(sub))
        } header: {
            Text("Automation")
        } footer: {
            Text("Notifications also require the global toggle in Settings → Release Radar. Excluded podcasts keep their episodes but are no longer checked for new ones — useful for completed shows.")
        }

        Section {
            Picker("Played Episodes", selection: afterPlayedBinding(sub)) {
                ForEach(AutoArchiveSettings.AfterPlayed.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            }
            Picker("Inactive Episodes", selection: afterInactiveBinding(sub)) {
                ForEach(AutoArchiveSettings.AfterInactive.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            }
            Picker("Episode Limit", selection: episodeLimitBinding(sub)) {
                ForEach(AutoArchiveSettings.EpisodeLimit.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            }
        } header: {
            Text("Auto Archive")
        } footer: {
            Text("Played Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives unplayed episodes that haven't been touched in the set time. Episode Limit keeps only the most recently published episodes, archiving older ones — the newest episode always downloads regardless. Auto Archive runs at most every 30 minutes.")
        }
    }

    @ViewBuilder
    private func chapterSection(_ sub: Subscription, episode: Episode) -> some View {
        Section {
            ForEach(episode.chapters.sorted { $0.position < $1.position }) { chapter in
                let isPlaying = appState.currentChapter?.position == chapter.position && appState.currentPlayerEpisode?.id == episode.id
                let allowed = sub.chapterFilter.allows(position: chapter.position)

                Button {
                    guard !isPlaying else { return }
                    appState.subscriptionStore.toggleChapter(
                        subscriptionID: sub.id,
                        position: chapter.position
                    )
                } label: {
                    HStack {
                        Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(allowed ? .purple : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title)
                                .foregroundStyle(allowed ? .primary : .secondary)
                            Text("Position \(chapter.position)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isPlaying {
                            Spacer()
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.purple)
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPlaying)
            }
        } header: {
            Text("Chapter filter")
        } footer: {
            Text("Skips are position-based and apply to all future episodes of this podcast.")
        }
    }

    @ViewBuilder
    private func feedSection(_ sub: Subscription) -> some View {
        Section("Feed") {
            LabeledContent("URL", value: sub.feedURL.absoluteString)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func dangerSection(_ sub: Subscription) -> some View {
        Section {
            Button("Unsubscribe", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    // MARK: - Bindings

    private func speedBinding(_ sub: Subscription) -> Binding<Double> {
        Binding(
            get: { sub.playbackPreference.speed },
            set: { newSpeed in
                var pref = sub.playbackPreference
                pref.speed = newSpeed
                appState.subscriptionStore.updatePlaybackPreference(
                    subscriptionID: sub.id,
                    preference: pref
                )
            }
        )
    }

    private func vocalBoostBinding(_ sub: Subscription) -> Binding<VocalBoostLevel> {
        Binding(
            get: { sub.playbackPreference.vocalBoostLevel },
            set: { level in
                appState.updateVocalBoost(for: sub.id, level: level)
            }
        )
    }

    private func notificationsBinding(_ sub: Subscription) -> Binding<Bool> {
        Binding(
            get: { sub.notificationsEnabled },
            set: { enabled in
                appState.subscriptionStore.updateNotificationsEnabled(subscriptionID: sub.id, enabled: enabled)
            }
        )
    }

    private func afterPlayedBinding(_ sub: Subscription) -> Binding<AutoArchiveSettings.AfterPlayed> {
        Binding(
            get: { sub.autoArchiveSettings.afterPlayed },
            set: { value in
                var s = sub.autoArchiveSettings; s.afterPlayed = value
                appState.subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: s)
            }
        )
    }

    private func afterInactiveBinding(_ sub: Subscription) -> Binding<AutoArchiveSettings.AfterInactive> {
        Binding(
            get: { sub.autoArchiveSettings.afterInactive },
            set: { value in
                var s = sub.autoArchiveSettings; s.afterInactive = value
                appState.subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: s)
            }
        )
    }

    private func episodeLimitBinding(_ sub: Subscription) -> Binding<AutoArchiveSettings.EpisodeLimit> {
        Binding(
            get: { sub.autoArchiveSettings.episodeLimit },
            set: { value in
                var s = sub.autoArchiveSettings; s.episodeLimit = value
                appState.subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: s)
            }
        )
    }

    private func autoFeedRefreshExclusionBinding(_ sub: Subscription) -> Binding<Bool> {
        Binding(
            get: { sub.excludeFromAutoFeedRefresh },
            set: { excluded in
                appState.subscriptionStore.updateExcludeFromAutoFeedRefresh(
                    subscriptionID: sub.id,
                    excluded: excluded
                )
            }
        )
    }

    private func startSkipBinding(_ sub: Subscription) -> Binding<TimeInterval> {
        Binding(
            get: { sub.playbackPreference.startSkipSeconds },
            set: { newVal in
                var pref = sub.playbackPreference
                pref.startSkipSeconds = newVal
                appState.subscriptionStore.updatePlaybackPreference(
                    subscriptionID: sub.id,
                    preference: pref
                )
            }
        )
    }

    private func endSkipBinding(_ sub: Subscription) -> Binding<TimeInterval> {
        Binding(
            get: { sub.playbackPreference.endSkipSeconds },
            set: { newVal in
                var pref = sub.playbackPreference
                pref.endSkipSeconds = newVal
                appState.subscriptionStore.updatePlaybackPreference(
                    subscriptionID: sub.id,
                    preference: pref
                )
            }
        )
    }

    private func trimSilenceBinding(_ sub: Subscription) -> Binding<TrimSilenceAmount> {
        Binding(
            get: { sub.playbackPreference.trimSilence },
            set: { amount in
                appState.updateTrimSilence(for: sub.id, amount: amount)
            }
        )
    }

    private func skipLabel(_ seconds: TimeInterval) -> String {
        seconds == 0 ? "Off" : "\(Int(seconds))s"
    }
}

private enum EpisodeStatusKind {
    case unplayed, queued, partiallyPlayed, nowPlaying, played, archived, inactive

    var label: String {
        switch self {
        case .unplayed:        return "Unplayed"
        case .queued:          return "Queued"
        case .partiallyPlayed: return "Paused"
        case .nowPlaying:      return "Playing"
        case .played:          return "Played"
        case .archived:        return "Archived"
        case .inactive:        return "Inactive"
        }
    }

    var color: Color {
        switch self {
        case .unplayed:        return Color.gray
        case .queued:          return Color.teal
        case .partiallyPlayed: return Color.yellow
        case .nowPlaying:      return Color.green
        case .played:          return Color.blue
        case .archived:        return Color.purple
        case .inactive:        return Color.orange
        }
    }
}

private struct EpisodeStatusPill: View {
    let kind: EpisodeStatusKind

    var body: some View {
        let label = Text(kind.label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .background(kind.color.opacity(0.45), in: Capsule())
                .glassEffect(in: Capsule())
        } else {
            label
                .background(kind.color.opacity(0.82), in: Capsule())
        }
    }
}

private struct EditTitleSheet: View {
    @Binding var title: String
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Show title", text: $title)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle("Edit Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                        .disabled(!canSave)
                }
            }
        }
    }
}

private struct EditPrioritySheet: View {
    @Binding var priorityRank: Int
    @Environment(\.dismiss) private var dismiss
    let maxRank: Int
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $priorityRank, in: 1...maxRank, step: 1) {
                        LabeledContent("Priority rank", value: "#\(priorityRank)")
                    }
                } footer: {
                    Text("Changing this rank immediately reorders the podcast list.")
                }
            }
            .navigationTitle("Edit Priority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                }
            }
        }
    }
}

struct SubscriptionEpisodesView: View {
    let subscriptionID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var isLoadingOlderEpisodes = false
    @State private var episodeToShare: Episode?
    @State private var showExpandedArtwork = false

    private var subscription: Subscription? {
        appState.subscriptionStore.subscription(id: subscriptionID)
    }

    private var episodes: [Episode] {
        guard let subscription else { return [] }
        return subscription.episodes.isEmpty
            ? subscription.latestEpisode.map { [$0] } ?? []
            : subscription.episodes
    }

    var body: some View {
        Group {
            if let sub = subscription {
                VStack(alignment: .leading, spacing: 12) {
                    showHeader(sub)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    HStack(spacing: 6) {
                        Text("Episodes")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                        Image(systemName: "waveform")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)

                    List {
                        if episodes.isEmpty {
                            ContentUnavailableView(
                                "No Episodes",
                                systemImage: "waveform",
                                description: Text("No episodes were found in this feed.")
                            )
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(episodes) { episode in
                                NavigationLink {
                                    EpisodeDetailView(subscriptionID: sub.id, episodeID: episode.id)
                                } label: {
                                    episodeRow(episode, sub: sub)
                                }
                                .listRowBackground(
                                    appState.currentPlayerEpisode?.id == episode.id
                                        ? Color.purple.opacity(0.08)
                                        : Color.white.opacity(0.08)
                                )
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    let isCurrentlyPlaying = appState.currentPlayerEpisode?.id == episode.id
                                    if !isCurrentlyPlaying {
                                        Button {
                                            Task {
                                                if episode.downloadState != .downloaded {
                                                    await appState.downloadEpisodeForQueue(episode)
                                                }
                                                if let updated = appState.subscriptionStore.episode(subscriptionID: sub.id, episodeID: episode.id) {
                                                    await appState.playEpisode(updated)
                                                }
                                            }
                                        } label: {
                                            Label("Play", systemImage: "play.fill")
                                        }
                                        .tint(.green)

                                        Button {
                                            Task {
                                                if episode.downloadState != .downloaded {
                                                    await appState.downloadEpisodeForQueue(episode)
                                                }
                                                appState.playEpisodeNext(episode)
                                            }
                                        } label: {
                                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        .tint(.blue)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    let isCurrentlyPlaying = appState.currentPlayerEpisode?.id == episode.id
                                    if !isCurrentlyPlaying {
                                        if episode.playedState == .archived || episode.playedState == .played {
                                            Button {
                                                appState.unarchiveEpisode(episode)
                                            } label: {
                                                Label("Unarchive", systemImage: "arrow.uturn.backward.circle")
                                            }
                                            .tint(.purple)
                                        } else {
                                            Button {
                                                Task { await appState.archiveEpisode(episode) }
                                            } label: {
                                                Label("Archive", systemImage: "archivebox")
                                            }
                                            .tint(.purple)
                                        }

                                        Button {
                                            Task {
                                                if episode.downloadState != .downloaded {
                                                    await appState.downloadEpisodeForQueue(episode)
                                                }
                                                appState.playEpisodeLast(episode)
                                            }
                                        } label: {
                                            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                        }
                                        .tint(.orange)

                                        Button {
                                            episodeToShare = episode
                                        } label: {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        .tint(.indigo)
                                    }
                                }
                            }

                            if episodes.count >= 50 {
                                Button {
                                    guard !isLoadingOlderEpisodes else { return }
                                    isLoadingOlderEpisodes = true
                                    Task {
                                        await appState.loadFullEpisodeHistory(for: sub)
                                        isLoadingOlderEpisodes = false
                                    }
                                } label: {
                                    HStack {
                                        Spacer()
                                        if isLoadingOlderEpisodes {
                                            ProgressView()
                                        } else {
                                            Label("Load Older Episodes", systemImage: "clock.arrow.circlepath")
                                        }
                                        Spacer()
                                    }
                                }
                                .listRowBackground(Color.white.opacity(0.08))
                                .disabled(isLoadingOlderEpisodes)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
            } else {
                ContentUnavailableView(
                    "Subscription Not Found",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
                    ReturnToPlayerButton()
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    guard let subscription, !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await appState.refreshSubscription(subscription)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh Feed", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(subscription == nil || isRefreshing)

                Button {
                    episodeToShare = subscription?.latestEpisode
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(subscription?.latestEpisode == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SubscriptionSettingsView(subscriptionID: subscriptionID)
                } label: {
                    Label("Show Settings", systemImage: "gearshape")
                }
                .disabled(subscription == nil)
            }
        }
        .sheet(item: $episodeToShare) { ep in
            EpisodeShareSheet(episode: ep, subscription: subscription)
        }
    }

    private func showHeader(_ sub: Subscription) -> some View {
        VStack(spacing: 12) {
            CachedArtworkImage(url: sub.artworkURL) {
                ZStack {
                    LinearGradient(
                        colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .onTapGesture { showExpandedArtwork = true }
            .sheet(isPresented: $showExpandedArtwork) {
                ExpandedArtworkSheet(url: sub.artworkURL)
            }

            VStack(spacing: 4) {
                Text(sub.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                // Video / Explicit pills centred below the title
                let showVideo = sub.latestEpisode?.mediaKind == .video
                let showExplicit = sub.isExplicit == true
                if showVideo || showExplicit {
                    HStack(spacing: 6) {
                        if showVideo { VideoBadgeLarge() }
                        if showExplicit { ExplicitPill() }
                    }
                }

                if let description = sub.description.map(stripHTML), !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let author = sub.author {
                        Text(author)
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                    if sub.author != nil, !sub.categories.isEmpty {
                        Text("·")
                    }
                    if !sub.categories.isEmpty {
                        Text(sub.categories.joined(separator: ", "))
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func episodeRow(_ episode: Episode, sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .center, spacing: 4) {
                    CachedArtworkImage(url: episode.artworkURL ?? sub.artworkURL) {
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
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let desc = episode.description.map(stripHTML), !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    HStack(spacing: 4) {
                        if let date = episode.publishedAt {
                            Text(formatPublishedDate(date))
                                .lineLimit(1)
                        }
                        if let duration = episode.durationSeconds {
                            let elapsed = appState.effectivePlaybackTime(for: episode)
                            let remaining = elapsed > 0 ? max(0, duration - elapsed) : duration
                            let isPartial = elapsed > 0
                            Text("•")
                            Text(isPartial ? "\(formatDuration(remaining)) left remaining" : formatDuration(duration))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        EpisodeStatusPill(kind: statusKind(for: episode))
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if episode.downloadState == .downloading,
               let progress = appState.downloadProgress[episode.id] {
                ProgressView(value: progress, total: 1.0)
                    .tint(.purple)
                    .animation(.linear(duration: 0.3), value: progress)
                    .padding(.leading, 56)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topTrailing) {
            if episode.mediaKind == .video || episode.isExplicit == true {
                HStack(spacing: 3) {
                    if episode.mediaKind == .video { VideoBadge() }
                    if episode.isExplicit == true { ExplicitPillSmall() }
                }
            }
        }
    }

    private func statusKind(for episode: Episode) -> EpisodeStatusKind {
        switch episode.playedState {
        case .playing:
            return appState.currentPlayerEpisode?.id == episode.id ? .nowPlaying : .partiallyPlayed
        case .played:   return .played
        case .archived: return .archived
        case .unplayed:
            let position = appState.effectivePlaybackTime(for: episode)
            if position > 0 { return .partiallyPlayed }
            return episode.downloadState == .downloaded ? .queued : .unplayed
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func formatPublishedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct EpisodeDetailView: View {
    let subscriptionID: UUID
    let episodeID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var showExpandedArtwork = false

    private var subscription: Subscription? {
        appState.subscriptionStore.subscription(id: subscriptionID)
    }

    private var episode: Episode? {
        appState.subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID)
    }

    var body: some View {
        Group {
            if let sub = subscription, let ep = episode {
                pageContent(sub: sub, ep: ep)
            } else {
                ContentUnavailableView("Episode Not Found", systemImage: "waveform")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
                    ReturnToPlayerButton()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(episode == nil)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let ep = episode {
                EpisodeShareSheet(episode: ep, subscription: subscription)
            }
        }
    }

    @ViewBuilder
    private func pageContent(sub: Subscription, ep: Episode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Centred header — artwork · title · pills · show name
                VStack(spacing: 12) {
                    CachedArtworkImage(url: ep.artworkURL ?? sub.artworkURL) { placeholderArtwork }
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                        .onTapGesture { showExpandedArtwork = true }
                        .sheet(isPresented: $showExpandedArtwork) {
                            ExpandedArtworkSheet(url: ep.artworkURL ?? sub.artworkURL)
                        }

                    VStack(spacing: 6) {
                        Text(ep.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)

                        let showVideo = ep.mediaKind == .video
                        let showExplicit = ep.isExplicit == true
                        if showVideo || showExplicit {
                            HStack(spacing: 6) {
                                if showVideo { VideoBadgeLarge() }
                                if showExplicit { ExplicitPill() }
                            }
                        }

                        Text(sub.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if !sub.categories.isEmpty {
                            Text(sub.categories.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                actionButtons(ep: ep, sub: sub)

                if let description = ep.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                        HTMLDescriptionText(
                            html: description,
                            fontSize: 15,
                            color: Color(white: 0.78),
                            linkColor: .purple,
                            showsFirstImage: false
                        )
                        .padding(14)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                }

                metaGrid(sub: sub, ep: ep)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func actionButtons(ep: Episode, sub: Subscription) -> some View {
        let isDownloading = ep.downloadState == .downloading
        let isArchivedOrPlayed = ep.playedState == .archived || ep.playedState == .played

        VStack(spacing: 10) {
            HStack(spacing: 0) {
                swipeStyleButton(
                    label: "Play", icon: "play.fill", color: .green,
                    disabled: isDownloading
                ) {
                    Task {
                        if ep.downloadState != .downloaded { await appState.downloadEpisodeForQueue(ep) }
                        if let updated = appState.subscriptionStore.episode(subscriptionID: sub.id, episodeID: ep.id) {
                            await appState.playEpisode(updated)
                        }
                    }
                }

                swipeStyleButton(
                    label: "Play Next", icon: "text.line.first.and.arrowtriangle.forward", color: .blue,
                    disabled: isDownloading
                ) {
                    Task {
                        if ep.downloadState != .downloaded { await appState.downloadEpisodeForQueue(ep) }
                        appState.playEpisodeNext(ep)
                    }
                }

                swipeStyleButton(
                    label: "Play Last", icon: "text.line.last.and.arrowtriangle.forward", color: .orange,
                    disabled: isDownloading
                ) {
                    Task {
                        if ep.downloadState != .downloaded { await appState.downloadEpisodeForQueue(ep) }
                        appState.playEpisodeLast(ep)
                    }
                }

                if isArchivedOrPlayed {
                    swipeStyleButton(
                        label: "Unarchive", icon: "arrow.uturn.backward.circle", color: .purple,
                        disabled: isDownloading
                    ) {
                        appState.unarchiveEpisode(ep)
                    }
                } else {
                    swipeStyleButton(
                        label: "Archive", icon: "archivebox", color: .purple,
                        disabled: isDownloading
                    ) {
                        Task { await appState.archiveEpisode(ep) }
                    }
                }

            }

            if isDownloading, let progress = appState.downloadProgress[ep.id] {
                ProgressView(value: progress, total: 1.0)
                    .tint(.purple)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
    }

    private func swipeStyleButton(
        label: String,
        icon: String,
        color: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(color)
                    Image(systemName: icon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    @ViewBuilder
    private func metaGrid(sub: Subscription, ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let date = ep.publishedAt {
                    metaCard("Published", date.formatted(date: .abbreviated, time: .omitted))
                }
                if let duration = ep.durationSeconds {
                    metaCard("Duration", formatDuration(duration))
                }
                if let size = ep.fileSizeBytes {
                    metaCard("File Size", formatFileSize(size))
                }
                metaCard("Classification", ep.isExplicit == true ? "Explicit" : "Clean")
                metaCard("File Status", fileStatusText(for: ep))
                metaCard("Priority Rank", ordinalString(sub.priorityRank))
            }
        }
    }

    private func metaCard(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Color(white: 0.33))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func fileStatusText(for ep: Episode) -> String {
        if ep.playedState == .played { return "Played" }
        if ep.playedState == .archived { return "Archived" }
        switch ep.downloadState {
        case .notDownloaded: return "Not Downloaded"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .downloaded: return ep.playedState == .playing ? "Now Playing" : "Downloaded"
        case .failed: return "Download Failed"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000
            ? String(format: "%.1f GB", mb / 1000)
            : String(format: "%.0f MB", mb)
    }

    private func ordinalString(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}
