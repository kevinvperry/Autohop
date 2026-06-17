import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/SettingsView.swift ("App Settings" page). Global
// settings Form, sections in order: Release Radar (sensitivity stepper +
// Notification Settings link — the global notifications toggle now lives on
// NotificationSettingsView as the master switch), Auto Archive (run-now button), Downloading
// (Downloads link + WiFi/cellular toggles), Controls (keep screen awake,
// lock screen scrubbing, skip back/forward duration sheets), Default Playback
// (global defaults for new + non-subscribed feeds via the shared
// PlaybackControlsCard + start/end skip steppers; writes
// AppSettings.defaultPlaybackPreference, never touches existing subs), Subscriptions
// (manage podcasts, add RSS, OPML import/export — Listening History moved to
// the Menu sheet, NavRules: one path per page), Storage
// (downloaded episode count), About (acknowledgements, version — tapping the
// version 5× unlocks the hidden Diagnostics section for this session only).
// All section footer copy here must stay in sync with FEATURES.md §15.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showOPMLImporter = false
    @State private var showOPMLExporter = false
    @State private var opmlDocument: OPMLDocument?
    @State private var isImporting = false
    @State private var isRunningAutoArchive = false
    @State private var editingSkipControl: SkipControl?
    @State private var draftSkipSeconds: TimeInterval = 15

    // Developer tools gate — unlocked by tapping the version number 5 times.
    // Resets on next app launch. Not persisted.
    @State private var developerTapCount = 0
    @State private var developerModeUnlocked = false
    @State private var totalDownloadedBytes: Int64? = nil

    var body: some View {
        Form {
            pollingSection
            autoArchiveSection
            downloadingSection
            controlsSection
            defaultPlaybackSection
            subscriptionsSection
            syncSection
            storageSection
            if developerModeUnlocked {
                diagnosticsSection
            }
            acknowledgementsSection
        }
        .listSectionSpacing(28)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
            }
        }
        .miniPlayerBar()
        .fileImporter(
            isPresented: $showOPMLImporter,
            allowedContentTypes: [.xml, .plainText, UTType(filenameExtension: "opml") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            guard let url = (try? result.get())?.first else { return }
            isImporting = true
            Task {
                await appState.importOPML(from: url)
                isImporting = false
            }
        }
        .fileExporter(
            isPresented: $showOPMLExporter,
            document: opmlDocument,
            contentType: .xml,
            defaultFilename: "autohop-subscriptions.opml"
        ) { _ in
            opmlDocument = nil
        }
        .sheet(item: $editingSkipControl) { control in
            SkipDurationEditSheet(
                title: control.title,
                seconds: $draftSkipSeconds,
                saveTitle: "Save",
                onCancel: { editingSkipControl = nil },
                onSave: { saveSkipControl(control) }
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var pollingSection: some View {
        Section {
            Stepper(value: pollBinding, in: 1...60, step: 1) {
                LabeledContent("Radar sensitivity") {
                    Text("\(appState.settingsStore.appSettings.podcastPollMinutes) min")
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink("Notification Settings") { NotificationSettingsView() }
        } header: {
            Text("Release Radar")
        } footer: {
            Text("Autohop learns each podcast's release schedule and starts watching its feed just before a new episode is expected. Radar sensitivity is how often the feed is checked while a drop is imminent — lower means new episodes appear faster. Checks are tiny (the feed is only downloaded when it has actually changed), so even 1 minute is light on battery and data. Notification Settings controls which podcasts notify you when a new episode arrives.")
        }
    }

    @ViewBuilder
    private var autoArchiveSection: some View {
        Section {
            Button {
                isRunningAutoArchive = true
                Task {
                    await appState.runAutoArchiveIfNeeded(reason: "settings.manual", force: true)
                    isRunningAutoArchive = false
                }
            } label: {
                if isRunningAutoArchive {
                    HStack {
                        Text("Running Auto Archive…")
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Label("Run Auto Archive Now", systemImage: "archivebox")
                }
            }
            .disabled(isRunningAutoArchive)
        } header: {
            Text("Auto Archive")
        } footer: {
            Text("Auto Archive normally runs on its own (at most every 30 minutes). This forces an immediate pass over every podcast using its own Auto Archive rules.")
        }
    }

    @ViewBuilder
    private var downloadingSection: some View {
        Section {
            NavigationLink("Downloads") { DownloadsView() }
            Toggle("Download over WiFi", isOn: wifiBinding)
            Toggle("Download over cellular", isOn: cellularBinding)
        } header: {
            Text("Downloading")
        } footer: {
            Text("New episodes download automatically so the queue always plays from files on your device. Turn off cellular to limit downloading to Wi-Fi.")
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle("Keep Screen Awake", isOn: keepScreenAwakeBinding)
            Toggle("Lock Screen Scrubbing", isOn: lockScreenScrubbingBinding)
            Toggle("Queue Badge", isOn: queueBadgeBinding)
            Button {
                openSkipEditor(.back)
            } label: {
                LabeledContent("Skip back", value: "\(Int(appState.settingsStore.appSettings.skipBackSeconds))s")
            }
            .buttonStyle(.plain)

            Button {
                openSkipEditor(.forward)
            } label: {
                LabeledContent("Skip forward", value: "\(Int(appState.settingsStore.appSettings.skipForwardSeconds))s")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Controls")
        } footer: {
            Text("Keep Screen Awake applies only while an episode is actively playing on the full-screen player. Disable Lock Screen Scrubbing to prevent accidental seeks when your phone is in your pocket. Queue Badge shows a number on the Autohop app icon counting how many downloaded episodes are ready to play. Skip durations also apply to the Lock Screen and Control Centre buttons.")
        }
    }

    // Default playback settings for NEW subscriptions and non-subscribed (browse)
    // feed playback. Mirrors the per-podcast Playback section in
    // SubscriptionSettingsView; editing here never changes existing subscriptions.
    @ViewBuilder
    private var defaultPlaybackSection: some View {
        let preference = appState.settingsStore.appSettings.defaultPlaybackPreference

        Section {
            PlaybackControlsCard(
                preference: preference,
                onSpeedChange: { appState.updateDefaultPlaybackSpeed($0) },
                onTrimChange: { appState.updateDefaultTrimSilence($0) },
                onVocalChange: { appState.updateDefaultVocalBoost($0) }
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Default Playback")
        } footer: {
            Text("These defaults apply to every new subscription and to playback of feeds you haven't subscribed to. Changing them never affects podcasts you've already subscribed to — adjust those from each podcast's own settings. Vocal Boost lifts speech above music and background sound; Trim Silence removes quiet gaps (audio episodes only).")
        }

        Section {
            Stepper(value: defaultStartSkipBinding, in: 0...300, step: 5) {
                LabeledContent("Start skip") {
                    Text(skipLabel(preference.startSkipSeconds))
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: defaultEndSkipBinding, in: 0...300, step: 5) {
                LabeledContent("End skip") {
                    Text(skipLabel(preference.endSkipSeconds))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Default Episode Trim")
        } footer: {
            Text("Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically.")
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        Section {
            Toggle("iCloud Sync", isOn: iCloudSyncBinding)
        } header: {
            Text("Sync")
        } footer: {
            Text("Private by default — your subscriptions, played state and stats stay on this device unless you turn on iCloud Sync. When enabled, your listening syncs across your devices signed into the same iCloud account.")
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Toggle("Enable Diagnostic Log", isOn: diagnosticLoggingBinding)
            if appState.settingsStore.appSettings.diagnosticLoggingEnabled {
                NavigationLink("View Diagnostic Log") { DiagnosticLogView() }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The diagnostic log records app events to help diagnose playback issues. Disable when not needed to preserve battery and storage.")
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section("Subscriptions") {
            NavigationLink("Manage podcasts") { PodcastsView() }
            NavigationLink("Add RSS Feed") { AddFeedView() }

            Button {
                showOPMLImporter = true
            } label: {
                if isImporting {
                    HStack {
                        if let progress = appState.opmlImportProgress {
                            Text("Importing \(progress.current) of \(progress.total)…")
                        } else {
                            Text("Importing…")
                        }
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Label("Import OPML", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(isImporting)

            Button {
                if let data = appState.exportOPML() {
                    opmlDocument = OPMLDocument(data)
                    showOPMLExporter = true
                }
            } label: {
                Label("Export OPML", systemImage: "square.and.arrow.up")
            }
            .disabled(appState.subscriptionStore.subscriptions.isEmpty)
        }
    }

    @ViewBuilder
    private var acknowledgementsSection: some View {
        Section {
            NavigationLink("Open Source Acknowledgements") {
                AcknowledgementsView()
            }
            // Version row — tap 5 times to unlock developer tools for this session.
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(developerModeUnlocked ? .purple : .secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                developerTapCount += 1
                if developerTapCount >= 5 {
                    developerModeUnlocked = true
                    developerTapCount = 0
                }
            }
        } header: {
            Text("About")
        } footer: {
            if developerModeUnlocked {
                Text("Developer tools unlocked.")
                    .foregroundStyle(.purple)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private var storageSection: some View {
        Section {
            let downloadedEpisodes = appState.subscriptionStore.subscriptions
                .flatMap(\.episodes)
                .filter { $0.downloadState == .downloaded }
            LabeledContent("Downloaded episodes", value: "\(downloadedEpisodes.count)")
            LabeledContent("Total size") {
                if let bytes = totalDownloadedBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            NavigationLink("Manage Downloads") { DownloadsView() }
        } header: {
            Text("Storage")
        } footer: {
            Text("To free up space, archive episodes or tighten a podcast's Episode Limit in its Auto Archive settings.")
        }
        .onAppear {
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                guard let appSupport = try? fm.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                ) else {
                    await MainActor.run { totalDownloadedBytes = 0 }
                    return
                }
                let downloadsDir = appSupport.appendingPathComponent("Autohop/Downloads", isDirectory: true)
                let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
                guard let enumerator = fm.enumerator(at: downloadsDir, includingPropertiesForKeys: keys) else {
                    await MainActor.run { totalDownloadedBytes = 0 }
                    return
                }
                var total: Int64 = 0
                for case let fileURL as URL in enumerator {
                    guard let res = try? fileURL.resourceValues(forKeys: Set(keys)),
                          res.isRegularFile == true,
                          let size = res.fileSize else { continue }
                    total += Int64(size)
                }
                await MainActor.run { totalDownloadedBytes = total }
            }
        }
    }

    // MARK: - Bindings

    private var pollBinding: Binding<Int> {
        Binding(
            get: { appState.settingsStore.appSettings.podcastPollMinutes },
            set: { appState.settingsStore.appSettings.podcastPollMinutes = $0 }
        )
    }

    private var cellularBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.downloadOverCellular },
            set: { appState.settingsStore.appSettings.downloadOverCellular = $0 }
        )
    }

    private var wifiBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.downloadOverWifi },
            set: { appState.settingsStore.appSettings.downloadOverWifi = $0 }
        )
    }

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.iCloudSyncEnabled },
            set: { appState.settingsStore.appSettings.iCloudSyncEnabled = $0 }
        )
    }

    private var keepScreenAwakeBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.keepScreenAwakeDuringPlayback },
            set: { appState.settingsStore.appSettings.keepScreenAwakeDuringPlayback = $0 }
        )
    }

    private var lockScreenScrubbingBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.lockScreenScrubbingEnabled },
            set: { appState.updateLockScreenScrubbing(enabled: $0) }
        )
    }

    private var queueBadgeBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.showQueueBadge },
            set: {
                appState.settingsStore.appSettings.showQueueBadge = $0
                let count = $0 ? appState.downloadedQueue.count : 0
                NotificationService.shared.updateBadge(count: count)
            }
        )
    }

    private var diagnosticLoggingBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.diagnosticLoggingEnabled },
            set: { appState.settingsStore.appSettings.diagnosticLoggingEnabled = $0 }
        )
    }

    private var defaultStartSkipBinding: Binding<TimeInterval> {
        Binding(
            get: { appState.settingsStore.appSettings.defaultPlaybackPreference.startSkipSeconds },
            set: { appState.updateDefaultStartSkip($0) }
        )
    }

    private var defaultEndSkipBinding: Binding<TimeInterval> {
        Binding(
            get: { appState.settingsStore.appSettings.defaultPlaybackPreference.endSkipSeconds },
            set: { appState.updateDefaultEndSkip($0) }
        )
    }

    private func skipLabel(_ seconds: TimeInterval) -> String {
        seconds == 0 ? "Off" : "\(Int(seconds))s"
    }

    private func openSkipEditor(_ control: SkipControl) {
        draftSkipSeconds = switch control {
        case .back:
            appState.settingsStore.appSettings.skipBackSeconds
        case .forward:
            appState.settingsStore.appSettings.skipForwardSeconds
        }
        editingSkipControl = control
    }

    private func saveSkipControl(_ control: SkipControl) {
        let roundedSeconds = max(5, min(120, (draftSkipSeconds / 5).rounded() * 5))
        switch control {
        case .back:
            appState.settingsStore.appSettings.skipBackSeconds = roundedSeconds
        case .forward:
            appState.settingsStore.appSettings.skipForwardSeconds = roundedSeconds
        }
        NowPlayingService.shared.updateSkipIntervals(
            forward: appState.settingsStore.appSettings.skipForwardSeconds,
            backward: appState.settingsStore.appSettings.skipBackSeconds
        )
        editingSkipControl = nil
    }

    private enum SkipControl: String, Identifiable {
        case back
        case forward

        var id: String { rawValue }

        var title: String {
            switch self {
            case .back:
                "Skip Back"
            case .forward:
                "Skip Forward"
            }
        }
    }
}

private struct SkipDurationEditSheet: View {
    let title: String
    @Binding var seconds: TimeInterval
    let saveTitle: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("\(Int(seconds))s")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                HStack(spacing: 28) {
                    Button {
                        adjust(by: -5)
                    } label: {
                        Image(systemName: "minus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 64, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(seconds <= 5)

                    Text("5 second steps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        adjust(by: 5)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 64, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(seconds >= 120)
                }

                Text("Choose any value from 5s to 120s.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle, action: onSave)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func adjust(by delta: TimeInterval) {
        seconds = max(5, min(120, seconds + delta))
    }
}

// AI CONTEXT — ListeningHistoryView ("Listening History" page, reached from
// Menu or App Settings → Subscriptions). Searchable log of ListeningHistoryStore
// entries grouped by date (Today/Yesterday/older); entries with < 60 s listened
// AND < 60 s position are hidden (the threshold rule lives here in the view).
// Header cards: total listening time and finished-episode count.
struct ListeningHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""

    // When no search is active, read the pre-computed cache from AppState so this view
    // doesn't regroup 500 entries on every playback tick. Regrouping only runs when the
    // user is actively typing in the search bar.
    private var groupedEntries: [(String, [ListeningHistoryEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appState.listeningHistoryGroups }
        let filtered = appState.listeningHistoryStore.entries.filter {
            ($0.listenedSeconds >= 60 || $0.lastPositionSeconds >= 60)
                && ($0.episodeTitle.lowercased().contains(query)
                    || $0.podcastTitle.lowercased().contains(query))
        }
        return groupByDate(filtered)
    }

    private func groupByDate(_ entries: [ListeningHistoryEntry]) -> [(String, [ListeningHistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry -> String in
            if calendar.isDateInToday(entry.lastListenedAt) { return "Today" }
            if calendar.isDateInYesterday(entry.lastListenedAt) { return "Yesterday" }
            return entry.lastListenedAt.formatted(date: .abbreviated, time: .omitted)
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.lastListenedAt > $1.lastListenedAt }) }
            .sorted { lhs, rhs in
                (lhs.1.first?.lastListenedAt ?? .distantPast) > (rhs.1.first?.lastListenedAt ?? .distantPast)
            }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    HistoryStatView(
                        title: "Listening Time",
                        value: formattedDuration(appState.listeningHistoryStore.totalListeningSeconds)
                    )
                    HistoryStatView(
                        title: "Episodes",
                        value: "\(appState.completedEpisodeCount)"
                    )
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            ForEach(groupedEntries, id: \.0) { title, entries in
                Section(title) {
                    ForEach(entries) { entry in
                        ListeningHistoryRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("Listening History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .miniPlayerBar()
    }
}

private struct HistoryStatView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ListeningHistoryRow: View {
    let entry: ListeningHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: entry.artworkURL) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemGroupedBackground))
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.podcastTitle.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.episodeTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 16) {
                    Label(entry.status.title, systemImage: statusIcon)
                    Text("•")
                    Text(formattedDuration(entry.listenedSeconds))
                    if let remaining = remainingText {
                        Text("•")
                        Text(remaining)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusIcon: String {
        switch entry.status {
        case .listened: return "waveform"
        case .played: return "checkmark.circle"
        case .archived: return "archivebox"
        }
    }

    private var remainingText: String? {
        guard entry.status == .listened,
              let duration = entry.durationSeconds,
              duration > entry.lastPositionSeconds
        else { return nil }
        return "\(formattedDuration(duration - entry.lastPositionSeconds)) left"
    }
}

private func formattedDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    if minutes > 0 {
        return "\(minutes)m"
    }
    return "\(seconds)s"
}

