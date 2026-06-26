import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/SettingsView.swift ("App Settings" page). Global
// settings Form, sections in order: Startup (Open-at-launch menu picker →
// AppSettings.launchScreen: Player / Subscriptions / Discover; drives RootView
// cold-launch routing, see FEATURES.md §15.0 / §18), Release Radar (sensitivity stepper +
// Notification Settings link — the global notifications toggle now lives on
// NotificationSettingsView as the master switch — plus a warning row + "Open iOS
// Settings" deep link shown when UIApplication.backgroundRefreshStatus != .available,
// since iOS then grants no off-app feed checks; re-checked on scenePhase) and a Feed
// Refresh Schedule link (FeedRefreshScheduleView — a per-active-subscription table of
// when/why Release Radar watches each feed), Auto Archive (run-now button +
// global default pickers for Played/Inactive/EpisodeLimit applied to new
// subscriptions only — Inactive uses download-date clock, not publish date;
// Episode Limit counts only .queued/.downloaded episodes, not .failed), Downloading
// (Downloads link + WiFi/cellular toggles), Controls (keep screen awake,
// lock screen scrubbing, skip back/forward duration sheets), Default Playback
// (global defaults for new + non-subscribed feeds via the shared
// PlaybackControlsCard + start/end skip steppers; writes
// AppSettings.defaultPlaybackPreference, never touches existing subs), Subscriptions
// (manage podcasts, add RSS, OPML import/export — Listening History moved to
// the Menu sheet, OPML imports consume AppState.OPMLImportSummary so successful
// imports can show the same count toast as Welcome/Podcasts, NavRules: one path
// per page), Storage
// (downloaded episode count; byte total is calculated by SettingsStorageUsage
// off-main and returned as one Int64 to keep Swift 6 concurrency checks clean),
// About (acknowledgements, version — tapping the
// version 5× unlocks the hidden Diagnostics section for this session only).
// All section footer copy here must stay in sync with FEATURES.md §15.
// Visual style: iOS 26 uses "defined glass" — native Form glass sections over a
// subtle dark base (black.opacity(0.5)) with a faint white.opacity(0.05) tint on
// each section card so edges read clearly, 36 pt listSectionSpacing between
// sections. iOS 17–25: dark page (scrollContentBackground hidden over black),
// each section a white.opacity(0.08) card. Both with .tint(.purple) and a purple
// SettingsRowLabel glyph on every control row — matching the Default Playback
// card (PlaybackControlsCard is passed fill: white.opacity(0.08) here) and the
// linked sub-screens (NotificationSettings / AddFeed / DiagnosticLog /
// Acknowledgements), which share the same recipe.
// Listening History rows in this file use 54 pt CachedArtworkImage thumbnails,
// sharing source bytes with the rest of the app while keeping a distinct
// memory variant sized for history cards.
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

    // Background App Refresh status warning (research Tier 1 #2) — surfaced in the
    // Release Radar section when iOS won't let Autohop check feeds in the background.
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundRefreshOff = false

    var body: some View {
        Form {
            startupSection
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
        .listSectionSpacing(36)
        .onAppear { refreshBackgroundRefreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshBackgroundRefreshStatus() }
        }
        .scrollContentBackground(formScrollBackground)
        .background(formPageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
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
                let summary = await appState.importOPML(from: url)
                if summary.imported > 0 {
                    appState.onboardingToast = "Imported \(summary.imported) show\(summary.imported == 1 ? "" : "s") — welcome aboard."
                }
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

    /// Reads the system Background App Refresh authorisation. `.denied` (user turned
    /// it off) or `.restricted` (Screen Time / MDM) both mean iOS won't grant
    /// off-app feed checks, so the Release Radar warning is shown.
    private func refreshBackgroundRefreshStatus() {
        backgroundRefreshOff = UIApplication.shared.backgroundRefreshStatus != .available
    }

    // MARK: - Section styling

    // iOS 26: "defined glass" — the native Form glass sections were washing out
    // against a fully clear page, so each section card gets a faint white tint
    // (lifting it off the backdrop into a readable rounded card) and the page
    // sits on a subtle dark base so the card edges have something to contrast
    // against. iOS 17–25: flat white.opacity(0.08) cards on solid black.
    private var cardBackground: Color {
        if #available(iOS 26, *) { return Color.white.opacity(0.05) }
        return Color.white.opacity(0.08)
    }

    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }

    private var formPageBackground: Color {
        if #available(iOS 26, *) { return Color.black.opacity(0.5) }
        return .black
    }

    // Purple leading icon + primary-coloured title for every toggle, link, stepper
    // and value row. Thin wrapper over the shared SettingsRowLabel (defined in
    // PlaybackControlsCard.swift) so the whole settings flow uses one glyph style.
    private func rowLabel(_ title: String, systemImage: String) -> some View {
        SettingsRowLabel(title: title, systemImage: systemImage)
    }

    // MARK: - Sections

    @ViewBuilder
    private var startupSection: some View {
        Section {
            Picker(selection: launchScreenBinding) {
                ForEach(LaunchScreen.allCases) { screen in
                    Text(screen.displayName).tag(screen)
                }
            } label: {
                rowLabel("Open at launch", systemImage: "house")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Startup")
        } footer: {
            Text("Choose which screen Autohop opens to each time you launch it — the Player, your Subscriptions, or Discover. New users still see a quick welcome first.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var pollingSection: some View {
        Section {
            if backgroundRefreshOff {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Background App Refresh is off", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("With it off, Autohop can only catch new episodes while you're listening or when you open the app — not on its own in the background. Turn it on so feeds keep updating. (Swiping Autohop closed in the App Switcher also stops background checks.)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
            Stepper(value: pollBinding, in: 1...60, step: 1) {
                LabeledContent {
                    Text("\(appState.settingsStore.appSettings.podcastPollMinutes) min")
                        .foregroundStyle(.secondary)
                } label: {
                    rowLabel("Radar sensitivity", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            NavigationLink {
                NotificationSettingsView()
            } label: {
                rowLabel("Notification Settings", systemImage: "bell.badge")
            }
            NavigationLink {
                FeedRefreshScheduleView()
            } label: {
                rowLabel("Feed Refresh Schedule", systemImage: "calendar.badge.clock")
            }
        } header: {
            Text("Release Radar")
        } footer: {
            Text("Autohop learns each podcast's release schedule and starts watching its feed just before a new episode is expected. Radar sensitivity is how often the feed is checked while a drop is imminent — lower means new episodes appear faster.\n\nChecks are tiny (the feed is only downloaded when it has actually changed), so even 1 minute is light on battery and data. Notification Settings controls which podcasts notify you when a new episode arrives.")
        }
        .listRowBackground(cardBackground)
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

            Picker(selection: defaultAfterPlayedBinding) {
                ForEach(AutoArchiveSettings.AfterPlayed.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                rowLabel("Played Episodes", systemImage: "checkmark.circle")
            }
            .pickerStyle(.menu)

            Picker(selection: defaultAfterInactiveBinding) {
                ForEach(AutoArchiveSettings.AfterInactive.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                rowLabel("Inactive Episodes", systemImage: "clock.arrow.circlepath")
            }
            .pickerStyle(.menu)

            Picker(selection: defaultEpisodeLimitBinding) {
                ForEach(AutoArchiveSettings.EpisodeLimit.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                rowLabel("Episode Limit", systemImage: "square.stack")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Auto Archive")
        } footer: {
            Text("Auto Archive normally runs on its own (at most every 30 minutes). These defaults apply to every new podcast you subscribe to — existing podcasts keep their own settings.\n\nPlayed Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives downloaded-but-unplayed episodes that haven't been played within the set time of being downloaded. Episode Limit keeps only the most recently published episodes.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var downloadingSection: some View {
        Section {
            NavigationLink {
                DownloadsView()
            } label: {
                rowLabel("Downloads", systemImage: "arrow.down.circle")
            }
            Toggle(isOn: wifiBinding) {
                rowLabel("Download over WiFi", systemImage: "wifi")
            }
            Toggle(isOn: cellularBinding) {
                rowLabel("Download over cellular", systemImage: "cellularbars")
            }
        } header: {
            Text("Downloading")
        } footer: {
            Text("New episodes download automatically so the queue always plays from files on your device. Downloads use Wi-Fi only by default — turn on cellular to also download over mobile data.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle(isOn: keepScreenAwakeBinding) {
                rowLabel("Keep Screen Awake", systemImage: "sun.max")
            }
            Toggle(isOn: lockScreenScrubbingBinding) {
                rowLabel("Lock Screen Scrubbing", systemImage: "lock.iphone")
            }
            Toggle(isOn: queueBadgeBinding) {
                rowLabel("Queue Badge", systemImage: "app.badge")
            }
            Button {
                openSkipEditor(.back)
            } label: {
                LabeledContent {
                    Text("\(Int(appState.settingsStore.appSettings.skipBackSeconds))s")
                        .foregroundStyle(.secondary)
                } label: {
                    rowLabel("Skip back", systemImage: "gobackward")
                }
            }
            .buttonStyle(.plain)

            Button {
                openSkipEditor(.forward)
            } label: {
                LabeledContent {
                    Text("\(Int(appState.settingsStore.appSettings.skipForwardSeconds))s")
                        .foregroundStyle(.secondary)
                } label: {
                    rowLabel("Skip forward", systemImage: "goforward")
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Controls")
        } footer: {
            Text("Keep Screen Awake applies only while an episode is actively playing on the full-screen player. Disable Lock Screen Scrubbing to prevent accidental seeks when your phone is in your pocket. Queue Badge shows a number on the Autohop app icon counting how many downloaded episodes are ready to play.\n\nSkip durations also apply to the Lock Screen and Control Centre buttons.")
        }
        .listRowBackground(cardBackground)
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
                onVocalChange: { appState.updateDefaultVocalBoost($0) },
                fill: cardBackground,
                // Drop the card's own glass surface so it inherits the section row
                // background below and matches every other section on the page.
                usesHostBackground: true
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(cardBackground)
        } header: {
            Text("Default Playback")
        } footer: {
            Text("These defaults apply to every new subscription and to playback of feeds you haven't subscribed to. Changing them never affects podcasts you've already subscribed to — adjust those from each podcast's own settings.\n\nVocal Boost lifts speech above music and background sound; Trim Silence removes quiet gaps (audio episodes only).")
        }

        Section {
            Stepper(value: defaultStartSkipBinding, in: 0...300, step: 5) {
                LabeledContent {
                    Text(skipLabel(preference.startSkipSeconds))
                        .foregroundStyle(.secondary)
                } label: {
                    rowLabel("Start skip", systemImage: "forward.end")
                }
            }

            Stepper(value: defaultEndSkipBinding, in: 0...300, step: 5) {
                LabeledContent {
                    Text(skipLabel(preference.endSkipSeconds))
                        .foregroundStyle(.secondary)
                } label: {
                    rowLabel("End skip", systemImage: "backward.end")
                }
            }
        } header: {
            Text("Default Episode Trim")
        } footer: {
            Text("Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var syncSection: some View {
        Section {
            Toggle(isOn: iCloudSyncBinding) {
                rowLabel("iCloud Sync", systemImage: "icloud")
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Private by default — your subscriptions, played state and stats stay on this device unless you turn on iCloud Sync.\n\nWhen enabled, your listening syncs across your devices signed into the same iCloud account.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Toggle(isOn: diagnosticLoggingBinding) {
                rowLabel("Enable Diagnostic Log", systemImage: "waveform.path.ecg")
            }
            if appState.settingsStore.appSettings.diagnosticLoggingEnabled {
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    rowLabel("View Diagnostic Log", systemImage: "doc.text.magnifyingglass")
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The diagnostic log records app events to help diagnose playback issues. Disable when not needed to preserve battery and storage.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section("Subscriptions") {
            // Subscriptions is the home page beneath the Menu sheet — close the
            // sheet to reveal it as a full page rather than pushing a duplicate
            // PodcastsView inside the sheet (NavRules: one path per page).
            Button {
                NotificationCenter.default.post(name: .autohopOpenSubscriptions, object: nil)
            } label: {
                HStack {
                    rowLabel("Manage podcasts", systemImage: "square.stack")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                AddFeedView()
            } label: {
                rowLabel("Add RSS Feed", systemImage: "dot.radiowaves.up.forward")
            }

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
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var acknowledgementsSection: some View {
        Section {
            NavigationLink {
                AcknowledgementsView()
            } label: {
                rowLabel("Open Source Acknowledgements", systemImage: "doc.plaintext")
            }
            // Version row — tap 5 times to unlock developer tools for this session.
            HStack {
                rowLabel("Version", systemImage: "info.circle")
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
        .listRowBackground(cardBackground)
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
            LabeledContent {
                Text("\(downloadedEpisodes.count)")
                    .foregroundStyle(.secondary)
            } label: {
                rowLabel("Downloaded episodes", systemImage: "tray.full")
            }
            LabeledContent {
                if let bytes = totalDownloadedBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            } label: {
                rowLabel("Total size", systemImage: "internaldrive")
            }
            NavigationLink {
                DownloadsView()
            } label: {
                rowLabel("Manage Downloads", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("To free up space, archive episodes or tighten a podcast's Episode Limit in its Auto Archive settings.")
        }
        .listRowBackground(cardBackground)
        .onAppear {
            Task.detached(priority: .utility) {
                let bytes = SettingsStorageUsage.downloadedBytes()
                await MainActor.run { totalDownloadedBytes = bytes }
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

    private var launchScreenBinding: Binding<LaunchScreen> {
        Binding(
            get: { appState.settingsStore.appSettings.launchScreen },
            set: { appState.settingsStore.appSettings.launchScreen = $0 }
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

    private var defaultAfterPlayedBinding: Binding<AutoArchiveSettings.AfterPlayed> {
        Binding(
            get: { appState.settingsStore.appSettings.defaultAutoArchiveSettings.afterPlayed },
            set: { appState.settingsStore.appSettings.defaultAutoArchiveSettings.afterPlayed = $0 }
        )
    }

    private var defaultAfterInactiveBinding: Binding<AutoArchiveSettings.AfterInactive> {
        Binding(
            get: { appState.settingsStore.appSettings.defaultAutoArchiveSettings.afterInactive },
            set: { appState.settingsStore.appSettings.defaultAutoArchiveSettings.afterInactive = $0 }
        )
    }

    private var defaultEpisodeLimitBinding: Binding<AutoArchiveSettings.EpisodeLimit> {
        Binding(
            get: { appState.settingsStore.appSettings.defaultAutoArchiveSettings.episodeLimit },
            set: { appState.settingsStore.appSettings.defaultAutoArchiveSettings.episodeLimit = $0 }
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
        .tint(.purple)
        .preferredColorScheme(.dark)
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
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                HistoryStatView(
                    title: "Listening Time",
                    value: formattedDuration(appState.listeningHistoryStore.totalListeningSeconds)
                )
                HistoryStatView(
                    title: "Episodes",
                    value: "\(appState.completedEpisodeCount)"
                )
            }

            if groupedEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Listening History" : "No Results",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(searchText.isEmpty
                        ? "Episodes you've listened to will show up here, newest first."
                        : "Try a different search.")
                )
                .frame(maxHeight: .infinity)
            } else {
                historyList
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Listening History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .preferredColorScheme(.dark)
        .tint(.purple)
        .miniPlayerBar()
    }

    /// The grouped history list on a single glass card (mirrors PodcastDetailView's
    /// episode list). Rows are clear so the one glass surface shows behind them.
    private var historyList: some View {
        List {
            ForEach(groupedEntries, id: \.0) { title, entries in
                Section {
                    ForEach(entries) { entry in
                        let episode = appState.subscriptionStore.episode(
                            subscriptionID: entry.subscriptionID, episodeID: entry.episodeID
                        )
                        let isCurrent = appState.currentPlayerEpisode?.id == entry.episodeID

                        ListeningHistoryRow(entry: entry)
                            .listRowBackground(isCurrent ? Color.purple.opacity(0.08) : Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let episode, !isCurrent {
                                    Button {
                                        Task {
                                            if episode.downloadState != .downloaded {
                                                await appState.downloadEpisodeForQueue(episode)
                                            }
                                            if let updated = appState.subscriptionStore.episode(
                                                subscriptionID: episode.subscriptionID, episodeID: episode.id
                                            ) {
                                                await appState.playEpisode(updated)
                                            }
                                        }
                                    } label: { Label("Play", systemImage: "play.fill") }
                                    .tint(.green)

                                    Button {
                                        Task {
                                            if episode.downloadState != .downloaded {
                                                await appState.downloadEpisodeForQueue(episode)
                                            }
                                            appState.playEpisodeNext(episode)
                                        }
                                    } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                    .tint(.blue)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let episode, !isCurrent {
                                    if episode.playedState == .archived || episode.playedState == .played {
                                        Button {
                                            appState.unarchiveEpisode(episode)
                                        } label: { Label("Unarchive", systemImage: "arrow.uturn.backward.circle") }
                                        .tint(.purple)
                                    } else {
                                        Button {
                                            Task { await appState.archiveEpisode(episode) }
                                        } label: { Label("Archive", systemImage: "archivebox") }
                                        .tint(.purple)
                                    }

                                    Button {
                                        Task {
                                            if episode.downloadState != .downloaded {
                                                await appState.downloadEpisodeForQueue(episode)
                                            }
                                            appState.playEpisodeLast(episode)
                                        }
                                    } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
                                    .tint(.orange)
                                }
                            }
                    }
                } header: {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .glassCard(cornerRadius: 16)
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
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 12)
    }
}

private enum SettingsStorageUsage {
    static func downloadedBytes() -> Int64 {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return 0
        }

        let downloadsDir = appSupport.appendingPathComponent("Autohop/Downloads", isDirectory: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: downloadsDir,
            includingPropertiesForKeys: Array(keys)
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resources = try? fileURL.resourceValues(forKeys: keys),
                  resources.isRegularFile == true,
                  let size = resources.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

private struct ListeningHistoryRow: View {
    let entry: ListeningHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: entry.artworkURL, targetSize: CGSize(width: 54, height: 54)) {
                ZStack {
                    LinearGradient(
                        colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 9))

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
