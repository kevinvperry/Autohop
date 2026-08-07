import SwiftUI
import UIKit

// AI CONTEXT — Views/SubscriptionSettingsView.swift ("Podcast Settings" page,
// gear icon from a podcast's episode list). Per-podcast configuration, all
// persisted on the Subscription via SubscriptionStore. Sections: Podcast
// (editable title, numeric priority rank, read-only author; the rank editor's
// range counts active real subscriptions only and is disabled while a real
// subscription is Inactive, so hidden browse/Inactive rows cannot distort its
// index and the hidden return rank can restore cleanly), Playback (speed
// 1.0–2.5x, Stereo/Mono Audio, Vocal Boost, per-subscription -3...+3 dB
// Volume Adjustment, Trim Silence, start/end skip — live-applied via
// AppState if this podcast is playing; rendered subscription/current-episode
// state is observed directly from SubscriptionStore and PlaybackCoordinator,
// while AppState remains the cross-domain command façade. Episode trim uses the shared stable
// EpisodeTrimControlRow, which drafts taps locally and coalesces one store/live-
// engine update after the user pauses, avoiding Form flicker and playback-time
// UI stalls. Durations use the shared minute/second formatter and place the
// longer text below the row title for narrow-phone readability. The dark
// two trim controls are hosted in one glassCard with the same padding, divider,
// clear Form row, and zero outer insets as the neighbouring Automation card.
// This avoids separate rectangular Form glass surfaces around custom rows.
// Speed/Trim/Vocal card is the
// shared Views/PlaybackControlsCard, also used by SettingsView's global
// Default Playback panel), Download Feed Filters (per-feed auto-download
// eligibility), Automation (per-podcast notifications, exclude from auto feed
// refresh, and automatic-download-only Play Instant with explicit sparse-use
// guidance), Auto Archive (three rules), Chapter Filter (uses the actively playing
// episode when it belongs to this podcast, otherwise newest; position-based and
// live-applied through AppState), Feed (URL with clipboard copy action), Danger
// (unsubscribe with confirmation). This file also hosts DownloadFiltersView, a pushed
// per-subscription page for auto-download eligibility rules
// (duration/title/description, include/exclude, All/Any, live read-only
// 50-episode feed preview with greyed skipped rows);
// since July 2026 these filters roam via iCloud Sync with the other per-podcast
// settings (struct-level LWW on the SubscriptionState record). Play Instant is
// stored in the same synced automation payload: only a newly auto-downloaded,
// filter-eligible episode can interrupt active playback; manual downloads cannot.
// Version 1.3 footer copy is also a website claim source: keep filter-aware
// Auto Archive, live chapter changes, and Download Feed Filter integration
// aligned with FEATURES.md and kevmarl-site/support.html.
// AUTO ARCHIVE RULES: Inactive Episodes includes a per-podcast 30-minute option
// for frequently replaced hourly bulletins. Rule 2 only archives episodes with a
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
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @State private var showDeleteConfirm = false
    @State private var isRefreshing = false
    @State private var showTitleEditor = false
    @State private var showPriorityEditor = false
    @State private var draftTitle = ""
    @State private var draftPriorityRank = 1
    @State private var showPodcastShare = false
    @State private var copiedFeedURL: URL?
    @Environment(\.dismiss) private var dismiss

    private var subscription: Subscription? {
        subscriptionStore.subscription(id: subscriptionID)
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
                    downloadFeedFiltersSection(sub)
                    playbackSection(sub)
                    automationSection(sub)
                    if let episode = chapterSettingsEpisode(for: sub) {
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
                    showPodcastShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(subscription == nil)
                .accessibilityLabel("Share Podcast")
            }
        }
        .miniPlayerBar()
        .sheet(isPresented: $showPodcastShare) {
            if let subscription {
                PodcastShareSheet(subscription: subscription)
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(subscription?.title ?? "this podcast")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                subscriptionStore.remove(subscriptionID: subscriptionID)
                dismiss()
            }
        } message: {
            Text("Your settings for this podcast will be deleted. Downloaded episodes are not removed.")
        }
        .sheet(isPresented: $showTitleEditor) {
            EditTitleSheet(title: $draftTitle) {
                subscriptionStore.updateTitle(subscriptionID: subscriptionID, title: draftTitle)
                showTitleEditor = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPriorityEditor) {
            EditPrioritySheet(
                priorityRank: $draftPriorityRank,
                maxRank: max(
                    subscriptionStore.subscriptions.filter {
                        $0.browseDate == nil && !$0.excludeFromAutoFeedRefresh
                    }.count,
                    1
                )
            ) {
                subscriptionStore.updatePriorityRank(
                    subscriptionID: subscriptionID,
                    priorityRank: draftPriorityRank
                )
                showPriorityEditor = false
            }
            .presentationDetents([.medium, .large])
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
            Text("Volume Adjustment balances podcasts that are quieter or louder than the rest of your library without changing device volume. Vocal Boost improves speech clarity, while Trim Silence removes quiet gaps (audio episodes only).")
        }

        Section {
            // AI CONTEXT — Podcast Settings uses the same one-card construction as
            // Automation. Do not split these back into independently glass-backed
            // Form rows: custom row glass resolves at a different shade on iOS 26.
            VStack(spacing: 0) {
                EpisodeTrimControlRow(
                    title: "Start skip",
                    systemImage: "forward.end",
                    persistedSeconds: sub.playbackPreference.startSkipSeconds,
                    onCommit: {
                        appState.updateEpisodeTrim(for: sub.id, startSkipSeconds: $0)
                    }
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Color(white: 0.20)).padding(.leading, 60)

                EpisodeTrimControlRow(
                    title: "End skip",
                    systemImage: "backward.end",
                    persistedSeconds: sub.playbackPreference.endSkipSeconds,
                    onCommit: {
                        appState.updateEpisodeTrim(for: sub.id, endSkipSeconds: $0)
                    }
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .glassCard(cornerRadius: 12)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Episode Trim")
        } footer: {
            Text("Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically.")
        }
    }

    // MARK: - Sound Controls Card

    @ViewBuilder
    private func soundControlsCard(_ sub: Subscription) -> some View {
        PlaybackControlsCard(
            preference: sub.playbackPreference,
            onSpeedChange: { appState.updatePlaybackSpeed(for: sub.id, speed: $0) },
            onTrimChange: { appState.updateTrimSilence(for: sub.id, amount: $0) },
            onVocalChange: { appState.updateVocalBoost(for: sub.id, level: $0) },
            onChannelModeChange: { appState.updateAudioChannelMode(for: sub.id, mode: $0) },
            onVolumeAdjustmentChange: { appState.updateVolumeAdjustment(for: sub.id, adjustment: $0) },
            showsVolumeAdjustment: true,
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

                Divider().background(Color(white: 0.20)).padding(.leading, 60)

                // AI CONTEXT — Play Instant is a per-podcast automation, not an
                // archive rule. It shares this glass card with the other passive
                // background behaviours to preserve settings-page hierarchy.
                Toggle(isOn: playInstantBinding(sub)) {
                    SettingsRowLabel(title: "Play Instant", systemImage: "bolt.fill")
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
            Text("Notifications also require the master switch in Settings → Release Radar → Notification Settings. Excluded podcasts keep their episodes, move to the bottom of the Priority Stack, and are skipped by automatic and Refresh All checks. You can still refresh one explicitly from its podcast page.\n\nPlay Instant interrupts something already playing when a new episode from this podcast finishes downloading automatically. If playback or its audio route is temporarily unavailable, the episode waits safely for up to 30 minutes and triggers when playback resumes. It never starts unexpectedly through the phone speaker. A clear warning sounds first; after the Instant episode finishes, Autohop returns to the interrupted episode. Manual downloads never trigger it.")
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
            Text("Played Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives downloaded-but-unplayed episodes that haven't been played within the set time of being downloaded. The 30 Minutes option is useful for frequently replaced hourly news bulletins. Episode Limit rotates automatic downloads to keep the newest selected number; manually downloaded and manually positioned Up Next episodes are protected. Changing the limit does not download older episodes. Automatic downloading still follows this podcast's Download Feed Filters.\n\nAuto Archive runs at most every 25 minutes.")
        }
        .listRowBackground(sectionRowBackground)
    }

    @ViewBuilder
    private func chapterSection(_ sub: Subscription, episode: Episode) -> some View {
        Section {
            ForEach(episode.chapters.sorted { $0.position < $1.position }) { chapter in
                let isPlaying = playbackCoordinator.currentChapter?.position == chapter.position && playbackCoordinator.currentEpisode?.id == episode.id
                let allowed = sub.chapterFilter.allows(position: chapter.position)

                Button {
                    guard !isPlaying else { return }
                    appState.toggleChapter(subscriptionID: sub.id, position: chapter.position)
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
            Text("Skips are position-based and apply to future episodes of this podcast. Changes apply to active playback immediately; while this podcast is playing, its current chapter is protected here from accidental deselection.")
        }
        .listRowBackground(sectionRowBackground)
    }

    /// Keep labels/playing protection tied to the episode producing audio. The
    /// previous newest-only list could show unrelated positions for an older
    /// playing episode from the same subscription.
    private func chapterSettingsEpisode(for subscription: Subscription) -> Episode? {
        if let playing = playbackCoordinator.currentEpisode,
           playing.subscriptionID == subscription.id,
           !playing.chapters.isEmpty {
            return playing
        }
        guard let newest = subscription.newestEpisode, !newest.chapters.isEmpty else { return nil }
        return newest
    }

    @ViewBuilder
    private func feedSection(_ sub: Subscription) -> some View {
        Section {
            LabeledContent {
                Text(sub.feedURL.absoluteString)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } label: {
                SettingsRowLabel(title: "URL", systemImage: "link")
            }

            Button {
                UIPasteboard.general.string = sub.feedURL.absoluteString
                copiedFeedURL = sub.feedURL

                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard copiedFeedURL == sub.feedURL else { return }
                    copiedFeedURL = nil
                }
            } label: {
                SettingsRowLabel(
                    title: copiedFeedURL == sub.feedURL ? "Copied" : "Copy Link",
                    systemImage: copiedFeedURL == sub.feedURL ? "checkmark" : "doc.on.doc"
                )
            }
            .accessibilityLabel(copiedFeedURL == sub.feedURL ? "Feed link copied" : "Copy feed link")
            .accessibilityHint("Copies the RSS feed URL to the clipboard")
        } header: {
            Text("Feed")
        } footer: {
            Text("This is the publisher's RSS address used to discover episodes. Copy Link places the complete address on the clipboard.")
        }
        .listRowBackground(sectionRowBackground)
    }

    @ViewBuilder
    private func downloadFeedFiltersSection(_ sub: Subscription) -> some View {
        Section {
            NavigationLink {
                DownloadFiltersView(subscriptionID: sub.id)
            } label: {
                SettingsRowLabel(title: "Filter Rules", systemImage: "line.3.horizontal.decrease.circle")
            }
        } header: {
            Text("Download Feed Filters")
        } footer: {
            Text("Control which new episodes Autohop downloads automatically from this podcast's feed. Duration, title, and description rules can skip episodes you do not want; manual actions still work. Skipped episodes do not train Release Radar or count as drifting, and the rules sync when iCloud Sync is enabled.")
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
                subscriptionStore.updateNotificationsEnabled(subscriptionID: sub.id, enabled: enabled)
            }
        )
    }

    private func afterPlayedBinding(_ sub: Subscription) -> Binding<AutoArchiveSettings.AfterPlayed> {
        Binding(
            get: { sub.autoArchiveSettings.afterPlayed },
            set: { value in
                var s = sub.autoArchiveSettings; s.afterPlayed = value
                subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: s)
            }
        )
    }

    private func playInstantBinding(_ sub: Subscription) -> Binding<Bool> {
        Binding(
            get: { sub.autoArchiveSettings.playInstantEnabled },
            set: { enabled in
                var settings = sub.autoArchiveSettings
                settings.playInstantEnabled = enabled
                subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: settings)
            }
        )
    }

    private func afterInactiveBinding(_ sub: Subscription) -> Binding<AutoArchiveSettings.AfterInactive> {
        Binding(
            get: { sub.autoArchiveSettings.afterInactive },
            set: { value in
                var s = sub.autoArchiveSettings; s.afterInactive = value
                subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: s)
            }
        )
    }

    private func episodeLimitBinding(_ sub: Subscription) -> Binding<AutoArchiveSettings.EpisodeLimit> {
        Binding(
            get: { sub.autoArchiveSettings.episodeLimit },
            set: { value in
                var s = sub.autoArchiveSettings; s.episodeLimit = value
                subscriptionStore.updateAutoArchiveSettings(subscriptionID: sub.id, settings: s)
            }
        )
    }

    private func autoFeedRefreshExclusionBinding(_ sub: Subscription) -> Binding<Bool> {
        Binding(
            get: { sub.excludeFromAutoFeedRefresh },
            set: { excluded in
                subscriptionStore.updateExcludeFromAutoFeedRefresh(
                    subscriptionID: sub.id,
                    excluded: excluded
                )
            }
        )
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
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var previewState: PreviewState = .idle

    private var subscription: Subscription? {
        subscriptionStore.subscription(id: subscriptionID)
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
        .navigationTitle("Download Feed Filters")
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
                subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            }
            addRuleButton("Add Duration Rule", systemImage: "plus.circle") {
                var settings = sub.downloadFilterSettings
                settings.durationEnabled = true
                settings.durationRules.append(.init())
                subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
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
                subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            },
            delete: { offsets in
                var settings = sub.downloadFilterSettings
                settings.titleRules.remove(atOffsets: offsets)
                subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
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
                subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
            },
            delete: { offsets in
                var settings = sub.downloadFilterSettings
                settings.descriptionRules.remove(atOffsets: offsets)
                subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: settings)
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
            get: { subscriptionStore.subscription(id: sub.id)?.downloadFilterSettings ?? sub.downloadFilterSettings },
            set: { subscriptionStore.updateDownloadFilterSettings(subscriptionID: sub.id, settings: $0) }
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
// actions. The fourth action mirrors PodcastDetailView's far-right trailing
// swipe: downloaded -> Archive; not-downloaded on an active real subscription ->
// Download; preview/inactive rows fall back to Archive/Unarchive. Reached from
// episode lists (subscribed or preview).
struct EpisodeDetailView: View {
    let subscriptionID: UUID
    let episodeID: UUID
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    /// Progress ticks publish on this dedicated model (not AppState) — reading
    /// appState.downloadProgress in body would render stale.
    @EnvironmentObject private var downloadProgressModel: DownloadProgressModel
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var showExpandedArtwork = false

    private var subscription: Subscription? {
        subscriptionStore.subscription(id: subscriptionID)
    }

    private var episode: Episode? {
        subscriptionStore.episode(subscriptionID: subscriptionID, episodeID: episodeID)
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
            .adaptiveContentWidth(.list)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func actionButtons(ep: Episode, sub: Subscription) -> some View {
        let isDownloading = ep.downloadState == .downloading

        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 10) {
                swipeStyleButton(
                    label: "Play", icon: "play.fill", color: .green,
                    disabled: isDownloading
                ) {
                    Task {
                        if ep.downloadState != .downloaded { await appState.downloadEpisodeForQueue(ep) }
                        if let updated = subscriptionStore.episode(subscriptionID: sub.id, episodeID: ep.id) {
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

                episodePrimaryActionButton(ep: ep, sub: sub, isDownloading: isDownloading)

            }

            if isDownloading, let progress = downloadProgressModel.progress[ep.id] {
                ProgressView(value: progress, total: 1.0)
                    .tint(.purple)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
    }

    @ViewBuilder
    private func episodePrimaryActionButton(ep: Episode, sub: Subscription, isDownloading: Bool) -> some View {
        if ep.downloadState == .downloaded {
            swipeStyleButton(
                label: "Archive", icon: "archivebox", color: .purple,
                disabled: isDownloading
            ) {
                Task { await appState.archiveEpisode(ep) }
            }
        } else if sub.browseDate == nil, !sub.excludeFromAutoFeedRefresh {
            swipeStyleButton(
                label: "Download", icon: "arrow.down.circle", color: .teal,
                disabled: isDownloading
            ) {
                Task { await appState.downloadEpisodeForQueue(ep) }
            }
        } else if ep.playedState == .archived || ep.playedState == .played {
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            if let date = ep.publishedAt {
                metaCard("Published", relativePublishedDateLabel(date))
                metaCard("Released", relativeReleasedLabel(date))
                metaCard("Distributed", releasedWeekdayLabel(date))
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
