import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        Form {
            pollingSection
            autoArchiveSection
            downloadingSection
            controlsSection
            subscriptionsSection
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
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
                    ReturnToPlayerButton()
                }
            }
        }
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
            Toggle("New episode notifications", isOn: notifyBinding)
        } header: {
            Text("Release Radar")
        } footer: {
            Text("Autohop learns each podcast's release schedule and starts watching its feed just before a new episode is expected. Radar sensitivity is how often the feed is checked while a drop is imminent — lower means new episodes appear faster. Checks are tiny (the feed is only downloaded when it has actually changed), so even 1 minute is light on battery and data.")
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
            Text("Manually checks every subscription using its Auto Archive setting.")
        }
    }

    @ViewBuilder
    private var downloadingSection: some View {
        Section("Downloading") {
            NavigationLink("Downloads") { DownloadsView() }
            Toggle("Download over WiFi", isOn: wifiBinding)
            Toggle("Download over cellular", isOn: cellularBinding)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle("Keep Screen Awake", isOn: keepScreenAwakeBinding)
            Toggle("Lock Screen Scrubbing", isOn: lockScreenScrubbingBinding)
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
            Text("Keeps the device awake only while an episode is actively playing on the full-screen player. Disable Lock Screen Scrubbing to prevent accidental seeks when your phone is in your pocket.")
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
            NavigationLink("Listening History") { ListeningHistoryView() }

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
        Section("Storage") {
            let downloadCount = appState.subscriptionStore.subscriptions
                .compactMap(\.latestEpisode)
                .filter { $0.downloadState == .downloaded }
                .count
            LabeledContent("Downloaded episodes", value: "\(downloadCount)")
        }
    }

    // MARK: - Bindings

    private var pollBinding: Binding<Int> {
        Binding(
            get: { appState.settingsStore.appSettings.podcastPollMinutes },
            set: { appState.settingsStore.appSettings.podcastPollMinutes = $0 }
        )
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.notifyNewEpisodes },
            set: { appState.settingsStore.appSettings.notifyNewEpisodes = $0 }
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

    private var diagnosticLoggingBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsStore.appSettings.diagnosticLoggingEnabled },
            set: { appState.settingsStore.appSettings.diagnosticLoggingEnabled = $0 }
        )
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ReturnToPlayerButton()
            }
        }
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

private func formattedLongDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let days = totalSeconds / 86400
    let hours = (totalSeconds % 86400) / 3600
    let minutes = (totalSeconds % 3600) / 60

    if days > 0 {
        if hours > 0 { return "\(days)d \(hours)h" }
        return "\(days)d"
    }
    if hours > 0 {
        if minutes > 0 { return "\(hours)h \(minutes)m" }
        return "\(hours)h"
    }
    if minutes > 0 { return "\(minutes)m" }
    return "\(totalSeconds % 60)s"
}

// MARK: - StatsView

struct StatsView: View {
    @EnvironmentObject private var appState: AppState

    private var stats: PlaybackStats { appState.playbackStatsStore.stats }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Since \(stats.startedAt.formatted(date: .abbreviated, time: .omitted)) you've listened for")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(formattedLongDuration(stats.totalListeningSeconds))
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.purple)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("TIME SAVED BY") {
                StatRow(
                    icon: "arrow.uturn.forward",
                    label: "Skipping",
                    value: formattedLongDuration(stats.timeSavedManualSkip)
                )
                StatRow(
                    icon: "gauge.with.needle",
                    label: "Variable Speed",
                    value: formattedLongDuration(stats.timeSavedVariableSpeed)
                )
                StatRow(
                    icon: "scissors",
                    label: "Trim Silence",
                    value: formattedLongDuration(stats.timeSavedTrimSilence)
                )
                StatRow(
                    icon: "forward.end",
                    label: "Auto Skipping",
                    value: formattedLongDuration(stats.timeSavedAutoSkip)
                )
            }

            Section {
                HStack {
                    Text("Total")
                        .font(.body.weight(.semibold))
                    Spacer()
                    Text(formattedLongDuration(stats.totalTimeSaved))
                        .font(.body.weight(.bold))
                        .foregroundStyle(.purple)
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ReturnToPlayerButton()
            }
        }
    }
}

private struct StatRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
