import SwiftUI

// AI CONTEXT — Views/SubscriptionSettingsView.swift ("Podcast Settings" page,
// gear icon from a podcast's episode list). Per-podcast configuration, all
// persisted on the Subscription via SubscriptionStore. Sections: Podcast
// (editable title, numeric priority rank, read-only author; rank editing is
// disabled while a real subscription is Inactive so its hidden return rank can
// restore cleanly), Playback (speed
// 1.0–2.5x, Vocal Boost, Trim Silence, start/end skip — live-applied via
// AppState if this podcast is playing; the dark Speed/Trim/Vocal card is the
// shared Views/PlaybackControlsCard, also used by SettingsView's global
// Default Playback panel), Automation (per-podcast notifications,
// exclude from auto feed refresh), Auto Archive (three rules), Chapter Filter
// (only when latest episode has chapters; position-based), Feed (read-only
// URL + Download Filters link + "Release Radar Data" link →
// SubscriptionRadarDiagnosticsView, a read-only screen showing the raw data and
// daily/weekly gate outcomes behind this feed's Radar classification),
// Danger (unsubscribe with confirmation). This
// file also hosts DownloadFiltersView, a pushed per-subscription page for local
// auto-download eligibility rules (duration/title/description, include/exclude,
// All/Any, live read-only 50-episode feed preview with greyed skipped rows).
// AUTO ARCHIVE RULES: Inactive Episodes (Rule 2) only archives episodes with a
// non-nil Episode.downloadedAt — episodes never downloaded are fully exempt.
// The footer copy describes download-date-based inactivity, not publish-date.
// Episode Limit (Rule 3) counts only .queued/.downloaded episodes — .failed
// episodes do not consume a slot. Keep footer copy in sync with FEATURES.md §10.
// Visual style matches App Settings: dark page
// (scrollContentBackground hidden over black), white.opacity(0.08) section
// cards, .tint(.purple), and purple SettingsRowLabel glyphs on control rows; the
// Playback card is passed fill: white.opacity(0.08) to match.
// stripHTML/decodeHTMLEntities below clean feed-supplied
// description text for display. The podcast's episode list lives in
// PodcastDetailView (reached by tapping a row); this file also hosts
// EpisodeDetailView, whose status pills treat archived episodes with
// Episode.wasCompleted as Played. (Visual style on iOS 26: every section's row
// background uses the same regular glassEffect surface as the Playback controls
// card via sectionRowBackground, so the whole page reads as one consistent glass
// treatment over a black.opacity(0.5) base, 36 pt section spacing; solid cards
// below iOS 26.)
// Settings/detail artwork uses explicit
// CachedArtworkImage targets (120 pt header/detail variants), sharing validated
// source bytes with episode lists while avoiding full-size cover decodes.
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

    // iOS 26: "defined glass" — a faint white tint lifts each native glass section
    // card off a subtle dark page base so edges read clearly (matches SettingsView).
    // iOS 17–25: flat white.opacity(0.08) cards on solid black.
    private var cardBackground: Color {
        if #available(iOS 26, *) { return Color.white.opacity(0.05) }
        return Color.white.opacity(0.08)
    }

    // Section row background. On iOS 26 every section uses the SAME regular-glass
    // surface the Playback controls card draws (glassEffect), so the whole page
    // reads as one consistent glass treatment rather than the Playback card
    // standing out. iOS 17–25 keeps the flat dark card fill.
    @ViewBuilder
    private var sectionRowBackground: some View {
        if #available(iOS 26, *) {
            Color.clear.glassEffect(in: Rectangle())
        } else {
            cardBackground
        }
    }

    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }

    private var formPageBackground: Color {
        if #available(iOS 26, *) { return Color.black.opacity(0.5) }
        return .black
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
        .listSectionSpacing(36)
        .scrollContentBackground(formScrollBackground)
        .background(formPageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle(subscription?.title ?? "Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
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
        .miniPlayerBar()
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
                LabeledContent {
                    Text(sub.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } label: {
                    SettingsRowLabel(title: "Title", systemImage: "textformat")
                }
            }
            .buttonStyle(.plain)

            Button {
                draftPriorityRank = sub.priorityRank
                showPriorityEditor = true
            } label: {
                LabeledContent {
                    Text("#\(sub.priorityRank)")
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(title: "Priority rank", systemImage: "number")
                }
            }
            .buttonStyle(.plain)
            .disabled(sub.excludeFromAutoFeedRefresh)

            if sub.excludeFromAutoFeedRefresh {
                Text("Turn off Exclude from Auto Feed Refresh to restore this podcast to its saved priority position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let author = sub.author {
                LabeledContent {
                    Text(author)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(title: "Author", systemImage: "person")
                }
            }
        }
        .listRowBackground(sectionRowBackground)
    }

    @ViewBuilder
    private func playbackSection(_ sub: Subscription) -> some View {
        Section {
            // Speed / Trim Silence / Vocal Boost — dark card matching AudioControlsSheetView
            soundControlsCard(sub)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } header: {
            Text("Playback")
        } footer: {
            Text("Vocal Boost lifts speech above music and background sound — Strong targets a −14 LUFS loudness goal for the clearest spoken audio. Trim Silence removes quiet gaps (audio episodes only).")
        }

        Section {
            Stepper(value: startSkipBinding(sub), in: 0...300, step: 5) {
                LabeledContent {
                    Text(skipLabel(sub.playbackPreference.startSkipSeconds))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(title: "Start skip", systemImage: "forward.end")
                }
            }

            Stepper(value: endSkipBinding(sub), in: 0...300, step: 5) {
                LabeledContent {
                    Text(skipLabel(sub.playbackPreference.endSkipSeconds))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(title: "End skip", systemImage: "backward.end")
                }
            }
        } header: {
            Text("Episode Trim")
        } footer: {
            Text("Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically.")
        }
        .listRowBackground(sectionRowBackground)
    }

    // MARK: - Sound Controls Card

    @ViewBuilder
    private func soundControlsCard(_ sub: Subscription) -> some View {
        PlaybackControlsCard(
            preference: sub.playbackPreference,
            onSpeedChange: { appState.updatePlaybackSpeed(for: sub.id, speed: $0) },
            onTrimChange: { appState.updateTrimSilence(for: sub.id, amount: $0) },
            onVocalChange: { appState.updateVocalBoost(for: sub.id, level: $0) },
            fill: cardBackground
        )
    }

    @ViewBuilder
    private func automationSection(_ sub: Subscription) -> some View {
        Section {
            // Rendered as one glass card (like the Playback controls card) rather
            // than two Form rows: the "Exclude…" row wraps to two lines, and a
            // per-row glassEffect renders a taller row at a visibly different shade.
            // A single shared glass surface keeps both rows identical.
            VStack(spacing: 0) {
                Toggle(isOn: notificationsBinding(sub)) {
                    SettingsRowLabel(title: "New episode notifications", systemImage: "bell.badge")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Color(white: 0.20)).padding(.leading, 60)

                Toggle(isOn: autoFeedRefreshExclusionBinding(sub)) {
                    SettingsRowLabel(title: "Exclude from Auto Feed Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .tint(.purple)
            .glassCard(cornerRadius: 12)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Automation")
        } footer: {
            Text("Notifications also require the master switch in Settings → Release Radar → Notification Settings. Excluded podcasts keep their episodes but are no longer checked for new ones — useful for completed shows.")
        }

        Section {
            Picker(selection: afterPlayedBinding(sub)) {
                ForEach(AutoArchiveSettings.AfterPlayed.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                SettingsRowLabel(title: "Played Episodes", systemImage: "checkmark.circle")
            }
            Picker(selection: afterInactiveBinding(sub)) {
                ForEach(AutoArchiveSettings.AfterInactive.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                SettingsRowLabel(title: "Inactive Episodes", systemImage: "clock")
            }
            Picker(selection: episodeLimitBinding(sub)) {
                ForEach(AutoArchiveSettings.EpisodeLimit.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                SettingsRowLabel(title: "Episode Limit", systemImage: "archivebox")
            }
        } header: {
            Text("Auto Archive")
        } footer: {
            Text("Played Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives downloaded-but-unplayed episodes that haven't been played within the set time of being downloaded. Episode Limit keeps only the most recently published episodes, archiving older ones — the newest episode always downloads regardless.\n\nAuto Archive runs at most every 30 minutes.")
        }
        .listRowBackground(sectionRowBackground)
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
        .listRowBackground(sectionRowBackground)
    }

    @ViewBuilder
    private func feedSection(_ sub: Subscription) -> some View {
        Section("Feed") {
            NavigationLink {
                DownloadFiltersView(subscriptionID: sub.id)
            } label: {
                SettingsRowLabel(title: "Download Filters", systemImage: "line.3.horizontal.decrease.circle")
            }

            NavigationLink {
                SubscriptionRadarDiagnosticsView(subscriptionID: sub.id)
            } label: {
                SettingsRowLabel(title: "Release Radar Data", systemImage: "stethoscope")
            }

            LabeledContent {
                Text(sub.feedURL.absoluteString)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } label: {
                SettingsRowLabel(title: "URL", systemImage: "link")
            }
        }
        .listRowBackground(sectionRowBackground)
    }

    @ViewBuilder
    private func dangerSection(_ sub: Subscription) -> some View {
        Section {
            Button("Unsubscribe", role: .destructive) {
                showDeleteConfirm = true
            }
        }
        .listRowBackground(sectionRowBackground)
    }

    // MARK: - Bindings

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

    private func skipLabel(_ seconds: TimeInterval) -> String {
        seconds == 0 ? "Off" : "\(Int(seconds))s"
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
        .tint(.purple)
        .preferredColorScheme(.dark)
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
        .tint(.purple)
        .preferredColorScheme(.dark)
    }
}

struct DownloadFiltersView: View {
    let subscriptionID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var previewState: PreviewState = .idle

    private var subscription: Subscription? {
        appState.subscriptionStore.subscription(id: subscriptionID)
    }

    var body: some View {
        Group {
            if let sub = subscription {
                Form {
                    summarySection(sub)
                    durationSection(sub)
                    titleSection(sub)
                    descriptionSection(sub)
                    previewSection(sub)
                }
            } else {
                ContentUnavailableView("Subscription Not Found", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .listSectionSpacing(36)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Download Filters")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
                    .accessibilityLabel("Back")
            }
        }
        .miniPlayerBar()
    }

    @ViewBuilder
    private func summarySection(_ sub: Subscription) -> some View {
        Section {
            Picker(selection: settingsBinding(sub).matchMode) {
                ForEach(DownloadFilterSettings.MatchMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SettingsRowLabel(title: "Match", systemImage: "switch.2")
            }
            .pickerStyle(.segmented)

            Text(summaryText(sub.downloadFilterSettings))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Rules")
        }
        .listRowBackground(sectionBackground)
    }

    @ViewBuilder
    private func durationSection(_ sub: Subscription) -> some View {
        let binding = settingsBinding(sub)
        Section {
            Toggle(isOn: binding.durationEnabled) {
                SettingsRowLabel(title: "Duration filters", systemImage: "clock")
            }
            ForEach(binding.durationRules) { $rule in
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Behavior", selection: $rule.behavior) {
                        ForEach(DownloadFilterSettings.RuleBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Picker("Comparison", selection: $rule.comparison) {
                            ForEach(DownloadFilterSettings.DurationRule.Comparison.allCases, id: \.self) { comparison in
                                Text(comparison.title).tag(comparison)
                            }
                        }
                        Stepper(value: $rule.minutes, in: 1...300, step: 1) {
                            Text("\(rule.minutes) min")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .onDelete { offsets in
                var settings = sub.downloadFilterSettings
                settings.durationRules.remove(atOffsets: offsets)
                appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            }
            addRuleButton("Add Duration Rule", systemImage: "plus.circle") {
                var settings = sub.downloadFilterSettings
                settings.durationEnabled = true
                settings.durationRules.append(.init())
                appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            }
        }
        .listRowBackground(sectionBackground)
    }

    @ViewBuilder
    private func titleSection(_ sub: Subscription) -> some View {
        textRuleSection(
            title: "Title",
            icon: "textformat",
            enabled: settingsBinding(sub).titleEnabled,
            rules: settingsBinding(sub).titleRules,
            add: {
                var settings = sub.downloadFilterSettings
                settings.titleEnabled = true
                settings.titleRules.append(.init(behavior: .include))
                appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            },
            delete: { offsets in
                var settings = sub.downloadFilterSettings
                settings.titleRules.remove(atOffsets: offsets)
                appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            }
        )
    }

    @ViewBuilder
    private func descriptionSection(_ sub: Subscription) -> some View {
        textRuleSection(
            title: "Description",
            icon: "text.alignleft",
            enabled: settingsBinding(sub).descriptionEnabled,
            rules: settingsBinding(sub).descriptionRules,
            add: {
                var settings = sub.downloadFilterSettings
                settings.descriptionEnabled = true
                settings.descriptionRules.append(.init(behavior: .exclude))
                appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            },
            delete: { offsets in
                var settings = sub.downloadFilterSettings
                settings.descriptionRules.remove(atOffsets: offsets)
                appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            }
        )
    }

    @ViewBuilder
    private func textRuleSection(
        title: String,
        icon: String,
        enabled: Binding<Bool>,
        rules: Binding<[DownloadFilterSettings.TextRule]>,
        add: @escaping () -> Void,
        delete: @escaping (IndexSet) -> Void
    ) -> some View {
        Section {
            Toggle(isOn: enabled) {
                SettingsRowLabel(title: "\(title) filters", systemImage: icon)
            }
            ForEach(rules) { $rule in
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Behavior", selection: $rule.behavior) {
                        ForEach(DownloadFilterSettings.RuleBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Match", selection: $rule.operation) {
                        ForEach(DownloadFilterSettings.TextRule.Operation.allCases, id: \.self) { operation in
                            Text(operation.title).tag(operation)
                        }
                    }
                    TextField("Text", text: $rule.term)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete(perform: delete)
            addRuleButton("Add \(title) Rule", systemImage: "plus.circle", action: add)
        }
        .listRowBackground(sectionBackground)
    }

    @ViewBuilder
    private func previewSection(_ sub: Subscription) -> some View {
        Section {
            Button {
                Task { await loadPreview(sub) }
            } label: {
                HStack {
                    Label("Preview Matches", systemImage: "eye")
                    Spacer()
                    if previewState.isLoading { ProgressView() }
                }
            }
            .disabled(previewState.isLoading)

            switch previewState {
            case .idle:
                EmptyView()
            case .loading:
                Text("Fetching latest feed...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Could not fetch the feed. Try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let rows):
                ForEach(rows) { row in
                    previewRow(row)
                }
            }
        } header: {
            Text("Preview")
        }
        .listRowBackground(sectionBackground)
    }

    private func previewRow(_ row: PreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.skipReason == nil ? .primary : .secondary)
                .lineLimit(2)
            HStack(spacing: 5) {
                if let publishedAt = row.publishedAt {
                    Text(relativePublishedLabel(publishedAt))
                }
                if let duration = row.durationSeconds {
                    if row.publishedAt != nil { Text("•") }
                    Text(formatDuration(duration)).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if let reason = row.skipReason {
                Text(reason)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.36).opacity(0.7), in: Capsule())
            }
        }
        .opacity(row.skipReason == nil ? 1 : 0.45)
    }

    private func addRuleButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }

    private func settingsBinding(_ sub: Subscription) -> Binding<DownloadFilterSettings> {
        Binding(
            get: { appState.subscriptionStore.subscription(id: sub.id)?.downloadFilterSettings ?? sub.downloadFilterSettings },
            set: { appState.subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: $0) }
        )
    }

    private func summaryText(_ settings: DownloadFilterSettings) -> String {
        guard settings.hasActiveFilters else {
            return "All filter groups are off, so Autohop downloads the next available episode."
        }
        return "Download episodes when \(settings.matchMode == .all ? "all" : "any") enabled include rules match. Exclude rules always skip matching episodes."
    }

    private func loadPreview(_ sub: Subscription) async {
        previewState = .loading
        do {
            let feed = try await EpisodeFeedLoader().fetch(feedURL: sub.feedURL, limit: 50)
            let rows = feed.episodes.compactMap { parsed -> PreviewRow? in
                guard let audioURL = parsed.audioURL else { return nil }
                var episode = Episode(subscriptionID: sub.id, guid: parsed.guid, title: parsed.title, audioURL: audioURL, mediaKind: parsed.mediaKind)
                episode.description = parsed.description
                episode.publishedAt = parsed.publishedAt
                episode.durationSeconds = parsed.durationSeconds
                let evaluation = sub.downloadFilterSettings.evaluation(for: episode)
                return PreviewRow(
                    title: parsed.title,
                    publishedAt: parsed.publishedAt,
                    durationSeconds: parsed.durationSeconds,
                    skipReason: evaluation.skipReason
                )
            }
            previewState = .loaded(rows)
        } catch {
            previewState = .failed
        }
    }

    private var sectionBackground: Color {
        if #available(iOS 26, *) { return Color.white.opacity(0.05) }
        return Color.white.opacity(0.08)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private enum PreviewState {
        case idle
        case loading
        case loaded([PreviewRow])
        case failed

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    private struct PreviewRow: Identifiable {
        let id = UUID()
        var title: String
        var publishedAt: Date?
        var durationSeconds: TimeInterval?
        var skipReason: String?
    }
}


// AI CONTEXT — EpisodeDetailView ("Episode Detail" page). Full single-episode
// view: description, chapter list with artwork, play/download/share/archive
// actions. Reached from episode lists (subscribed or preview).
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
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
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
        .miniPlayerBar()
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
                    CachedArtworkImage(url: ep.artworkURL ?? sub.artworkURL, targetSize: CGSize(width: 120, height: 120)) { placeholderArtwork }
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
                                if showVideo { VideoPillLarge() }
                                if showExplicit { ExplicitPillLarge() }
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
                        descriptionCard(description)
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

    /// Episode description rendered in a card that matches `PodcastDetailView`'s
    /// glass `episodeListCard` via the shared `glassCard(cornerRadius:)` modifier.
    private func descriptionCard(_ description: String) -> some View {
        HTMLDescriptionText(
            html: description,
            fontSize: 15,
            color: Color(white: 0.78),
            linkColor: .purple,
            showsFirstImage: false
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    @ViewBuilder
    private func metaGrid(sub: Subscription, ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            // Wrap the small glass cards in a GlassEffectContainer so they read
            // as one cohesive glass surface (iOS 26+); plain grid on the fallback.
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 8) {
                    metaGridContent(sub: sub, ep: ep)
                }
            } else {
                metaGridContent(sub: sub, ep: ep)
            }
        }
    }

    @ViewBuilder
    private func metaGridContent(sub: Subscription, ep: Episode) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            if let date = ep.publishedAt {
                metaCard("Published", relativePublishedDateLabel(date))
                metaCard("Released", relativeReleasedLabel(date))
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

    @ViewBuilder
    private func metaCard(_ key: String, _ value: String) -> some View {
        let content = VStack(alignment: .leading, spacing: 3) {
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

        if #available(iOS 26, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
                .background(Color(white: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
        }
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
        let total = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
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
