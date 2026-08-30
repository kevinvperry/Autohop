import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/SettingsView.swift ("App Settings" page). Global
// settings Form. Startup (Open-at-launch menu picker →
// AppSettings.launchScreen: Player / Subscriptions / Discover; drives RootView
// cold-launch routing, see FEATURES.md §15.0 / §18), Release Radar (fully automatic adaptive scheduling +
// Notification Settings link — its new-episode toggle is the default for future
// subscriptions only; existing podcasts keep their own setting — plus a warning row + "Open iOS
// Settings" deep link shown when UIApplication.backgroundRefreshStatus != .available,
// since iOS then grants no off-app feed checks; re-checked on scenePhase) and a Feed
// Refresh Schedule link (FeedRefreshScheduleView — a per-active-subscription table of
// when/why Release Radar watches each feed), Auto Archive (run-now button,
// durable Auto Archive Activity audit-page link +
// global default pickers for Played/Inactive/EpisodeLimit applied to new
// subscriptions only — Inactive uses download-date clock, not publish date;
// its specialist 30-minute bulletin value is intentionally available only in
// Podcast Settings, not as an all-new-subscriptions global default;
// Episode Limit counts only .queued/.downloaded episodes, not .failed), Downloading
// (Downloads link + WiFi/cellular toggles), Controls (keep screen awake,
// lock screen scrubbing, Up Next badge, skip back/forward duration sheets), Default Playback
// (global defaults for new + non-subscribed feeds via the shared
// PlaybackControlsCard (including the Stereo/Mono default for future subscriptions)
// + shared, locally drafted start/end trim controls; their
// 350 ms coalescing prevents an atomic settings-file write and Form rebuild per
// tap, uses minute/second labels, and writes AppSettings.defaultPlaybackPreference
// without touching existing subs. Each trim row receives cardBackground directly
// so its custom content uses the same menu-card surface as every sibling section),
// Subscriptions
// (manage podcasts, add RSS, OPML import/export — Listening History moved to
// the Menu sheet, OPML imports consume AppState.OPMLImportSummary so successful
// imports can show the same count toast as Welcome/Podcasts, NavRules: one path
// per page), Storage
// (downloaded episode count; byte total is calculated by SettingsStorageUsage
// off-main and returned as one Int64 to keep Swift 6 concurrency checks clean),
// Contact (website support + iOS-family Join TestFlight Beta external links),
// About (acknowledgements, version — tapping the
// version 5× unlocks the hidden Diagnostics section for this session only).
// Listening History is an episode-list surface and therefore formats compact
// runtime metadata through episodeListTimeLabel(_:), including the final minute.
// Diagnostics uses a master normal-tier switch plus a subordinate Detailed
// Refresh Trace toggle; normal mode retains foreground/background cycle and wake
// summaries, while detailed mode adds high-volume per-feed Release Radar traces.
// All section footer copy here must stay in sync with FEATURES.md §15 and the
// website Support page. Copy describes best-effort iOS background opportunities
// accurately. There is no Relay, Autohop account, or paid Pro tier — those
// prototypes were removed; never reintroduce copy implying any of them exist.
// Visual style: iOS 26 uses "defined glass" — native Form glass sections over a
// subtle dark base (black.opacity(0.5)) with a faint white.opacity(0.05) tint on
// each section card so edges read clearly, 48 pt listSectionSpacing between
// sections. iOS 17–25: dark page (scrollContentBackground hidden over black),
// each section a white.opacity(0.08) card. Both with .tint(.purple) and a purple
// SettingsRowLabel glyph on every control row — matching the Default Playback
// card (PlaybackControlsCard is passed fill: white.opacity(0.08) here) and the
// linked sub-screens (NotificationSettings / AddFeed / DiagnosticLog /
// Acknowledgements), which share the same recipe.
// Listening History rows in this file use 54 pt CachedArtworkImage thumbnails,
// sharing source bytes with the rest of the app while keeping a distinct
// memory variant sized for history cards.
// Stage 14: all rendered global settings and bindings observe/write through
// SettingsViewModel. AppState remains only for high-level commands whose effects
// span playback, sync, notifications, diagnostics, or persistence domains.
// EXPANSIVE NAVIGATION: full-width iPad/Mac windows retain this one Form as the
// right pane and add a fixed SettingsShortcutSidebar on the left. Shortcuts
// scroll to stable major-section IDs; never fork the settings into replacement
// detail pages. Compact/narrow multitasking remains the original single column.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var importCoordinator: SubscriptionImportCoordinator
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator
    @EnvironmentObject private var queueCoordinator: QueueCoordinator
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.adaptiveViewportWidth) private var viewportWidth

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
    @State private var activeShortcut: SettingsShortcut = .general
    @State private var requestedFormSection: Int?
    @State private var formScrollRequestID = UUID()

    private enum SettingsShortcut: String, Hashable {
        case general, releaseRadar, automation, downloads, playback
        case podcasts, sync, storage, diagnostics, support, about
    }

    private var shortcutItems: [SettingsShortcutItem<SettingsShortcut>] {
        var items: [SettingsShortcutItem<SettingsShortcut>] = [
            .init(id: .general, title: "Startup", systemImage: "house"),
            .init(id: .releaseRadar, title: "Release Radar", systemImage: "dot.radiowaves.left.and.right"),
            .init(id: .automation, title: "Auto Archive", systemImage: "archivebox"),
            .init(id: .downloads, title: "Downloading", systemImage: "arrow.down.circle"),
            .init(id: .playback, title: "Controls", systemImage: "waveform"),
            .init(id: .podcasts, title: "Subscriptions", systemImage: "square.stack"),
            .init(id: .sync, title: "Sync", systemImage: "icloud"),
            .init(id: .storage, title: "Storage", systemImage: "internaldrive")
        ]
        if developerModeUnlocked {
            items.append(.init(id: .diagnostics, title: "Diagnostics", systemImage: "waveform.path.ecg"))
        }
        items.append(contentsOf: [
            .init(id: .support, title: "Contact", systemImage: "envelope"),
            .init(id: .about, title: "About", systemImage: "info.circle")
        ])
        return items
    }

    var body: some View {
        Group {
            if AdaptiveEditorialMetrics(containerWidth: viewportWidth).usesSettingsShortcutSidebar {
                HStack(spacing: 0) {
                    SettingsShortcutSidebar(
                        items: shortcutItems,
                        selection: $activeShortcut,
                        navigate: { shortcut in
                            requestedFormSection = formSection(for: shortcut)
                            formScrollRequestID = UUID()
                        }
                    )
                    Divider().overlay(Color.white.opacity(0.08))
                    settingsForm
                        .frame(maxWidth: .infinity)
                        .background(formPageBackground)
                }
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                settingsForm
            }
        }
        .onAppear { refreshBackgroundRefreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshBackgroundRefreshStatus() }
        }
        .scrollContentBackground(formScrollBackground)
        .background(settingsWorkspaceBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Settings")
        .responsiveInlineNavigationTitle("Settings")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationBackButton()
            }
        }
        .miniPlayerBar()
        .onboardingTip(.settings)
        .fileImporter(
            isPresented: $showOPMLImporter,
            allowedContentTypes: [.xml, .plainText, UTType(filenameExtension: "opml") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            guard let url = (try? result.get())?.first else { return }
            isImporting = true
            Task {
                let summary = await importCoordinator.importOPML(from: url)
                if summary.imported > 0 {
                    onboardingCoordinator.toast = "Imported \(summary.imported) show\(summary.imported == 1 ? "" : "s") — welcome aboard."
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var settingsForm: some View {
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
            contactSection
            acknowledgementsSection
        }
        .responsiveListSizing()
        .listSectionSpacing(AdaptiveLayoutMetrics.settingsSectionSpacing)
        .background(
            FormSectionScrollController(
                section: requestedFormSection,
                requestID: formScrollRequestID,
                onVisibleSectionChanged: { section in
                    activeShortcut = shortcut(forFormSection: section)
                }
            )
        )
    }

    /// AI CONTEXT — REGRESSION HAZARD (hand-maintained index map).
    /// These are POSITIONAL indexes into `settingsForm`'s Section list, not IDs.
    /// FormSectionScrollController scrolls by section index, so the mapping must
    /// match the emission order of `settingsForm` exactly:
    ///   0 startup · 1 polling · 2 autoArchive · 3 downloading · 4 controls
    ///   5+6 defaultPlaybackSection (TWO Sections: Default Playback + Default
    ///       Episode Trim — it has no shortcut of its own, hence the gap)
    ///   7 subscriptions · 8 sync · 9 storage · 10 diagnostics (conditional)
    ///   then contact/about, shifted by developerModeUnlocked.
    /// Adding, removing, splitting, or reordering ANY Section in `settingsForm`
    /// silently sends every sidebar shortcut below it to the wrong place — the
    /// compiler cannot catch this. Update this table in the same edit, and keep
    /// the conditional `diagnosticsSection` offset arithmetic correct.
    /// Native Form section indexes include the two Default Playback sections,
    /// even though they intentionally have no shortcut of their own.
    private func formSection(for shortcut: SettingsShortcut) -> Int {
        switch shortcut {
        case .general: return 0
        case .releaseRadar: return 1
        case .automation: return 2
        case .downloads: return 3
        case .playback: return 4
        case .podcasts: return 7
        case .sync: return 8
        case .storage: return 9
        case .diagnostics: return 10
        case .support: return developerModeUnlocked ? 11 : 10
        case .about: return developerModeUnlocked ? 12 : 11
        }
    }

    /// Mirrors formSection(for:) for manual-scroll highlighting. Sections 5
    /// and 6 are both part of Default Playback and therefore keep Playback
    /// selected while either is the reader's top visible section.
    private func shortcut(forFormSection section: Int) -> SettingsShortcut {
        switch section {
        case 0: return .general
        case 1: return .releaseRadar
        case 2: return .automation
        case 3: return .downloads
        case 4...6: return .playback
        case 7: return .podcasts
        case 8: return .sync
        case 9: return .storage
        case 10 where developerModeUnlocked: return .diagnostics
        case 10: return .support
        case 11 where developerModeUnlocked: return .support
        default: return .about
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

    private var formPageBackground: Color { .black }

    private var settingsWorkspaceBackground: Color { .black }

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
            .id(SettingsShortcut.general)
            .pickerStyle(.menu)
        } header: {
            shortcutHeader("Startup", id: .general)
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
            NavigationLink {
                NotificationSettingsView()
            } label: {
                rowLabel("Notification Settings", systemImage: "bell.badge")
            }
            .id(SettingsShortcut.releaseRadar)
            NavigationLink {
                FeedRefreshScheduleView()
            } label: {
                rowLabel("Feed Refresh Schedule", systemImage: "calendar.badge.clock")
            }
        } header: {
            shortcutHeader("Release Radar", id: .releaseRadar)
        } footer: {
            Text("Autohop automatically adapts each podcast's refresh timing to its learned release schedule, recent empty checks, deferred backlog, network conditions, battery mode and device temperature.\n\nNotification Settings controls which podcasts notify you after Autohop discovers a new episode.")
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
            .id(SettingsShortcut.automation)
            .disabled(isRunningAutoArchive)

            NavigationLink {
                AutoArchiveActivityView()
            } label: {
                rowLabel("Auto Archive Activity", systemImage: "list.bullet.clipboard")
            }

            Picker(selection: defaultAfterPlayedBinding) {
                ForEach(AutoArchiveSettings.AfterPlayed.allCases, id: \.self) { v in
                    Text(v.title).tag(v)
                }
            } label: {
                rowLabel("Played Episodes", systemImage: "checkmark.circle")
            }
            .pickerStyle(.menu)

            Picker(selection: defaultAfterInactiveBinding) {
                ForEach(AutoArchiveSettings.AfterInactive.allCases.filter { $0 != .minutes30 }, id: \.self) { v in
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
            shortcutHeader("Auto Archive", id: .automation)
        } footer: {
            Text("Auto Archive normally runs on its own (at most every 25 minutes). Auto Archive Activity explains every automatic decision. These defaults apply to every new podcast you subscribe to — existing podcasts keep their own settings.\n\nPlayed Episodes archives each episode after it finishes playing (or after a delay). Inactive Episodes archives downloaded-but-unplayed episodes that haven't been played within the set time of being downloaded. Episode Limit rotates automatic downloads while protecting manually downloaded and manually positioned Up Next episodes.")
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
            .id(SettingsShortcut.downloads)
            Toggle(isOn: wifiBinding) {
                rowLabel("Download over WiFi", systemImage: "wifi")
            }
            Toggle(isOn: cellularBinding) {
                rowLabel("Download over cellular", systemImage: "cellularbars")
            }
        } header: {
            shortcutHeader("Downloading", id: .downloads)
        } footer: {
            Text("New episodes download automatically so Up Next plays from files already on your device. Downloads use Wi-Fi and cellular by default — turn either network type off here if you want to restrict automatic downloads. Feed checks and transfer starts in the background remain subject to execution time granted by iOS.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle(isOn: keepScreenAwakeBinding) {
                rowLabel("Keep Screen Awake", systemImage: "sun.max")
            }
            .id(SettingsShortcut.playback)
            Toggle(isOn: lockScreenScrubbingBinding) {
                rowLabel("Lock Screen Scrubbing", systemImage: "lock.iphone")
            }
            Toggle(isOn: queueBadgeBinding) {
                rowLabel("Up Next Badge", systemImage: "app.badge")
            }
            Button {
                openSkipEditor(.back)
            } label: {
                LabeledContent {
                    Text("\(Int(settingsViewModel.appSettings.skipBackSeconds))s")
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
                    Text("\(Int(settingsViewModel.appSettings.skipForwardSeconds))s")
                        .foregroundStyle(.secondary)
                } label: {
                    rowLabel("Skip forward", systemImage: "goforward")
                }
            }
            .buttonStyle(.plain)
        } header: {
            shortcutHeader("Controls", id: .playback)
        } footer: {
            Text("Keep Screen Awake applies only while an episode is actively playing on the full-screen player. Disable Lock Screen Scrubbing to prevent accidental seeks when your phone is in your pocket. Up Next Badge shows a number on the Autohop app icon counting how many downloaded episodes are ready to play.\n\nSkip durations also apply to the Lock Screen and Control Centre buttons.")
        }
        .listRowBackground(cardBackground)
    }

    // Default playback settings for NEW subscriptions and non-subscribed (browse)
    // feed playback. Mirrors the per-podcast Playback section in
    // SubscriptionSettingsView; editing here never changes existing subscriptions.
    @ViewBuilder
    private var defaultPlaybackSection: some View {
        let preference = settingsViewModel.appSettings.defaultPlaybackPreference

        Section {
            PlaybackControlsCard(
                preference: preference,
                onSpeedChange: { appState.updateDefaultPlaybackSpeed($0) },
                onTrimChange: { appState.updateDefaultTrimSilence($0) },
                onVocalChange: { appState.updateDefaultVocalBoost($0) },
                onChannelModeChange: { appState.updateDefaultAudioChannelMode($0) },
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
            Text("These defaults apply to every new subscription and to playback of feeds you haven't subscribed to. Changing them never affects podcasts you've already subscribed to — adjust those from each podcast's own settings.\n\nMono Audio centres presenters that were mixed toward the left or right. Vocal Boost lifts speech above music and background sound; Trim Silence removes quiet gaps. Audio processing options apply to audio episodes only.")
        }

        Section {
            EpisodeTrimControlRow(
                title: "Start skip",
                systemImage: "forward.end",
                persistedSeconds: preference.startSkipSeconds,
                onCommit: { appState.updateDefaultEpisodeTrim(startSkipSeconds: $0) }
            )
            .listRowBackground(cardBackground)

            EpisodeTrimControlRow(
                title: "End skip",
                systemImage: "backward.end",
                persistedSeconds: preference.endSkipSeconds,
                onCommit: { appState.updateDefaultEpisodeTrim(endSkipSeconds: $0) }
            )
            .listRowBackground(cardBackground)
        } header: {
            Text("Default Episode Trim")
        } footer: {
            Text("Start and end skip are measured in real file time, independent of playback speed — use them to jump intros and outros automatically.")
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        Section {
            Toggle(isOn: iCloudSyncBinding) {
                rowLabel("iCloud Sync", systemImage: "icloud")
            }
            .id(SettingsShortcut.sync)
        } header: {
            shortcutHeader("Sync", id: .sync)
        } footer: {
            Text("On for new installs so your subscriptions, playback position, per-podcast settings, Up Next order, history and stats can stay current across your devices. Existing installs keep their previous choice.\n\nSync uses your private iCloud database across iPhones signed into the same iCloud account. You can turn it off at any time; downloaded media and global app settings remain on each device.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Toggle(isOn: diagnosticLoggingBinding) {
                rowLabel("Enable Diagnostic Log", systemImage: "waveform.path.ecg")
            }
            .id(SettingsShortcut.diagnostics)
            if settingsViewModel.appSettings.diagnosticLoggingEnabled {
                Toggle(isOn: verboseDiagnosticLoggingBinding) {
                    rowLabel("Detailed Refresh Trace", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    rowLabel("View Diagnostic Log", systemImage: "doc.text.magnifyingglass")
                }
            }
        } header: {
            shortcutHeader("Diagnostics", id: .diagnostics)
        } footer: {
            Text("Normal diagnostics retain refresh-cycle summaries, background wakes, backlog, downloads, failures and playback recovery with low routine overhead. Detailed Refresh Trace adds per-feed decisions for short Release Radar investigations and creates a larger log. Disable diagnostics when testing is complete.")
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section {
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
            .id(SettingsShortcut.podcasts)
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
                        if let progress = importCoordinator.progress {
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
                if let data = importCoordinator.exportOPML() {
                    opmlDocument = OPMLDocument(data)
                    showOPMLExporter = true
                }
            } label: {
                Label("Export OPML", systemImage: "square.and.arrow.up")
            }
            .disabled(subscriptionStore.subscriptions.isEmpty)
        } header: {
            shortcutHeader("Subscriptions", id: .podcasts)
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var contactSection: some View {
        Section {
            Button {
                if let url = URL(string: "https://kevmarl.com/contact") {
                    openURL(url)
                }
            } label: {
                rowLabel("Get in Touch", systemImage: "envelope")
            }
            .id(SettingsShortcut.support)

            Button {
                if let url = URL(string: "https://testflight.apple.com/join/KnjwQz1C") {
                    openURL(url)
                }
            } label: {
                HStack {
                    rowLabel("Join TestFlight Beta", systemImage: "paperplane.fill")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Opens the Autohop beta in TestFlight")
        } header: {
            shortcutHeader("Contact", id: .support)
        } footer: {
            Text("Have a question, found a bug, or want to share feedback? Get in touch, or join the TestFlight beta to try prerelease Autohop builds.")
        }
        .listRowBackground(cardBackground)
    }

    private var acknowledgementsSection: some View {
        Section {
            NavigationLink {
                AcknowledgementsView()
            } label: {
                rowLabel("Open Source Acknowledgements", systemImage: "doc.plaintext")
            }
            .id(SettingsShortcut.about)
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
            shortcutHeader("About", id: .about)
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
            // AI CONTEXT — COST: this flattens EVERY episode of EVERY
            // subscription (4,000+ on a large library) and allocates two arrays
            // on each `settingsForm` body pass, i.e. on every SubscriptionStore
            // objectWillChange and every toggle tap on this page — not just when
            // the Storage section is on screen. It is a known main-actor cost,
            // deliberately left simple. If this page ever feels sluggish, count
            // with `reduce(0)` instead of materialising arrays, or cache it in
            // @State beside `totalDownloadedBytes` (which is already computed
            // off-main). Do not "optimise" by moving the filter into the store.
            let downloadedEpisodes = subscriptionStore.subscriptions
                .flatMap(\.episodes)
                .filter { $0.downloadState == .downloaded }
            LabeledContent {
                Text("\(downloadedEpisodes.count)")
                    .foregroundStyle(.secondary)
            } label: {
                rowLabel("Downloaded episodes", systemImage: "tray.full")
            }
            .id(SettingsShortcut.storage)
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
            shortcutHeader("Storage", id: .storage)
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

    private func shortcutHeader(_ title: String, id: SettingsShortcut) -> some View {
        Text(title)
    }

    // MARK: - Bindings

    private var cellularBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.downloadOverCellular },
            set: { settingsViewModel.appSettings.downloadOverCellular = $0 }
        )
    }

    private var wifiBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.downloadOverWifi },
            set: { settingsViewModel.appSettings.downloadOverWifi = $0 }
        )
    }

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.iCloudSyncEnabled },
            set: { settingsViewModel.appSettings.iCloudSyncEnabled = $0 }
        )
    }

    private var launchScreenBinding: Binding<LaunchScreen> {
        Binding(
            get: { settingsViewModel.appSettings.launchScreen },
            set: { settingsViewModel.appSettings.launchScreen = $0 }
        )
    }

    private var keepScreenAwakeBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.keepScreenAwakeDuringPlayback },
            set: { settingsViewModel.appSettings.keepScreenAwakeDuringPlayback = $0 }
        )
    }

    private var lockScreenScrubbingBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.lockScreenScrubbingEnabled },
            set: { appState.updateLockScreenScrubbing(enabled: $0) }
        )
    }

    private var queueBadgeBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.showQueueBadge },
            set: {
                settingsViewModel.appSettings.showQueueBadge = $0
                let count = $0 ? queueCoordinator.episodes.count : 0
                NotificationService.shared.updateBadge(count: count)
            }
        )
    }

    private var diagnosticLoggingBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.appSettings.diagnosticLoggingEnabled },
            set: { settingsViewModel.appSettings.diagnosticLoggingEnabled = $0 }
        )
    }

    private var verboseDiagnosticLoggingBinding: Binding<Bool> {
        Binding(
            get: {
                settingsViewModel.appSettings.verboseDiagnosticLoggingEnabled
            },
            set: {
                settingsViewModel.appSettings.verboseDiagnosticLoggingEnabled = $0
            }
        )
    }

    private var defaultAfterPlayedBinding: Binding<AutoArchiveSettings.AfterPlayed> {
        Binding(
            get: { settingsViewModel.appSettings.defaultAutoArchiveSettings.afterPlayed },
            set: { settingsViewModel.appSettings.defaultAutoArchiveSettings.afterPlayed = $0 }
        )
    }

    private var defaultAfterInactiveBinding: Binding<AutoArchiveSettings.AfterInactive> {
        Binding(
            get: { settingsViewModel.appSettings.defaultAutoArchiveSettings.afterInactive },
            set: { settingsViewModel.appSettings.defaultAutoArchiveSettings.afterInactive = $0 }
        )
    }

    private var defaultEpisodeLimitBinding: Binding<AutoArchiveSettings.EpisodeLimit> {
        Binding(
            get: { settingsViewModel.appSettings.defaultAutoArchiveSettings.episodeLimit },
            set: { settingsViewModel.appSettings.defaultAutoArchiveSettings.episodeLimit = $0 }
        )
    }

    private func openSkipEditor(_ control: SkipControl) {
        draftSkipSeconds = switch control {
        case .back:
            settingsViewModel.appSettings.skipBackSeconds
        case .forward:
            settingsViewModel.appSettings.skipForwardSeconds
        }
        editingSkipControl = control
    }

    private func saveSkipControl(_ control: SkipControl) {
        let roundedSeconds = max(5, min(120, (draftSkipSeconds / 5).rounded() * 5))
        switch control {
        case .back:
            settingsViewModel.appSettings.skipBackSeconds = roundedSeconds
        case .forward:
            settingsViewModel.appSettings.skipForwardSeconds = roundedSeconds
        }
        NowPlayingService.shared.updateSkipIntervals(
            forward: settingsViewModel.appSettings.skipForwardSeconds,
            backward: settingsViewModel.appSettings.skipBackSeconds
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
            .responsiveInlineNavigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .responsiveToolbarLabel()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle, action: onSave)
                        .fontWeight(.semibold)
                        .responsiveToolbarLabel()
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
// Header cards: total listening time and finished-episode count. Swipe actions
// mirror PodcastDetailView exactly: Play / Play Next lead; the far-right trailing
// action is Download for not-yet-downloaded episodes on active real subscriptions
// (otherwise Archive/Unarchive), followed by Play Last. Active downloads render
// the shared purple linear progress bar below the row. Rows deliberately reuse
// `ListRow-EpisodeRow` geometry: 44pt artwork, subheadline-semibold episode title,
// caption podcast/metadata text, and the shared historical EpisodeStatusPill.
struct ListeningHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @EnvironmentObject private var historyStatsCoordinator: HistoryStatsCoordinator
    @EnvironmentObject private var historyStore: ListeningHistoryStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    /// Dedicated progress publisher keeps download ticks separate from AppState's
    /// broad UI state, matching PodcastDetailView and the other episode lists.
    @EnvironmentObject private var downloadProgressModel: DownloadProgressModel
    @State private var searchText = ""

    // When no search is active, read the pre-computed cache from AppState so this view
    // doesn't regroup 500 entries on every playback tick. Regrouping only runs when the
    // user is actively typing in the search bar.
    private var groupedEntries: [(String, [ListeningHistoryEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return historyStatsCoordinator.historyGroups }
        let filtered = historyStore.entries.filter {
            ($0.listenedSeconds >= 60 || $0.lastPositionSeconds >= 60)
                && ($0.episodeTitle.lowercased().contains(query)
                    || $0.podcastTitle.lowercased().contains(query))
        }
        return groupByDate(filtered)
    }

    private func groupByDate(_ entries: [ListeningHistoryEntry]) -> [(String, [ListeningHistoryEntry])] {
        // Day-bucket header shared with the "Published" meta-card so History reads
        // Today / Yesterday / "N Days Ago" (2–6) / abbreviated date (year only when not
        // this year) — consistent with the app's relative date style.
        let grouped = Dictionary(grouping: entries) { entry -> String in
            relativePublishedDateLabel(entry.lastListenedAt)
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
                    value: formattedDuration(historyStore.totalListeningSeconds)
                )
                HistoryStatView(
                    title: "Episodes",
                    value: "\(historyStatsCoordinator.completedEpisodeCount)"
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
        .episodeListPageWidth()
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Listening History")
        .responsiveInlineNavigationTitle("Listening History")
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
                        let episode = subscriptionStore.episode(
                            subscriptionID: entry.subscriptionID, episodeID: entry.episodeID
                        )
                        let isCurrent = playbackCoordinator.currentEpisode?.id == entry.episodeID

                        ListeningHistoryRow(
                            entry: entry,
                            episode: episode,
                            isCurrent: isCurrent,
                            downloadProgress: episode.flatMap { downloadProgressModel.progress[$0.id] }
                        )
                            .listRowBackground(isCurrent ? Color.purple.opacity(0.08) : Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let episode, !isCurrent { historyLeadingSwipe(episode: episode) }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let episode,
                                   let subscription = subscriptionStore.subscription(id: episode.subscriptionID),
                                   !isCurrent {
                                    historyTrailingSwipe(episode: episode, subscription: subscription)
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
        .responsiveListSizing()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .glassCard(cornerRadius: 16)
    }

    /// AI CONTEXT — Canonical `SwipeActions-EpisodeRow` leading edge. Keep this
    /// behavior in lockstep with PodcastDetailView.leadingSwipe: manual actions
    /// bypass Download Feed Filters and await any required download first.
    @ViewBuilder
    private func historyLeadingSwipe(episode: Episode) -> some View {
        Button {
            Task {
                if episode.downloadState != .downloaded {
                    await appState.downloadEpisodeForQueue(episode)
                }
                if let updated = subscriptionStore.episode(
                    subscriptionID: episode.subscriptionID,
                    episodeID: episode.id
                ) {
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

    /// AI CONTEXT — Canonical trailing edge. Declaration order intentionally
    /// matches Podcast Detail so the state-driven primary action is farthest from
    /// the row edge and Play Last retains the same orange position/behavior.
    @ViewBuilder
    private func historyTrailingSwipe(episode: Episode, subscription: Subscription) -> some View {
        historyPrimaryTrailingSwipe(episode: episode, subscription: subscription)

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
    }

    @ViewBuilder
    private func historyPrimaryTrailingSwipe(episode: Episode, subscription: Subscription) -> some View {
        if episode.downloadState == .downloaded {
            Button {
                Task { await appState.archiveEpisode(episode) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.purple)
        } else if subscription.browseDate == nil, !subscription.excludeFromAutoFeedRefresh {
            Button {
                Task { await appState.downloadEpisodeForQueue(episode) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(.teal)
        } else if episode.playedState == .archived || episode.playedState == .played {
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
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    let entry: ListeningHistoryEntry
    /// Nil when the retained history record can no longer resolve to a current
    /// library episode; such rows remain readable but cannot show live progress.
    let episode: Episode?
    let isCurrent: Bool
    let downloadProgress: Double?

    var body: some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        let artworkSize = metrics.artworkSize
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: metrics.rowSpacing) {
                CachedArtworkImage(url: entry.artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.episodeTitle)
                        .font(.system(size: metrics.primaryFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(entry.podcastTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(eventMetadata)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 8)
                        EpisodeStatusPill(kind: historicalStatusKind)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if episode?.downloadState == .downloading, let downloadProgress {
                ProgressView(value: downloadProgress, total: 1.0)
                    .tint(.purple)
                    .animation(.linear(duration: 0.3), value: downloadProgress)
                    .padding(.leading, artworkSize + metrics.rowSpacing)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, metrics.verticalPadding)
    }

    /// AI CONTEXT — History pills describe the outcome recorded by this entry,
    /// not a later live library mutation. Only unresolved entries consult the
    /// active player so "Playing" can replace "Paused" while currently audible.
    private var historicalStatusKind: EpisodeStatusKind {
        switch entry.status {
        case .played:
            return .played
        case .archived:
            return .archived
        case .listened:
            return isCurrent ? .nowPlaying : .partiallyPlayed
        }
    }

    /// The single persisted event timestamp is `lastListenedAt`; terminal
    /// mutations stamp it at the exact completion/archive action. Legacy entries
    /// without CompletionKind use their stored status for an honest fallback.
    private var eventMetadata: String {
        let action: String
        switch entry.completionKind {
        case .finishedNaturally, .markedPlayed:
            action = "Completed"
        case .manuallyArchived:
            action = "Manually Archived"
        case .autoArchived:
            action = "Auto Archived"
        case nil:
            switch entry.status {
            case .played: action = "Completed"
            case .archived: action = "Archived"
            case .listened: action = "Last listened"
            }
        }
        let timestamp = entry.lastListenedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(action) • \(timestamp)"
    }
}

private func formattedDuration(_ seconds: TimeInterval) -> String {
    episodeListTimeLabel(seconds)
}
