import SwiftUI
import AutohopCore

// AI CONTEXT — User-facing tvOS Settings followed by a deliberately secondary
// developer diagnostics area. Everyday controls and understandable library /
// iCloud health belong first; implementation counters, build provenance and
// the Xcode-retrieved redacted export belong last. It never claims a silent
// push guarantees execution.
struct TVDiagnosticsView: View {
    private enum FocusTarget: Hashable {
        case discoverPlaybackSpeed
    }

    let model: TVAppModel
    @State private var exportStatus: String?
    @State private var isPreparingExport = false
    @State private var topShelfRefreshStatus: String?
    // AI CONTEXT — Health inspection touches App Group files, the log summary
    // and Mach memory counters. Cache it while navigating so focus movement is
    // presentation-only; explicit actions refresh the snapshot.
    @State private var cachedSnapshot: TVDiagnosticsSnapshot?
    @FocusState private var focusedTarget: FocusTarget?
    @AppStorage(TVDiscoverPlaybackSettings.key)
    private var discoverPlaybackSpeed = TVDiscoverPlaybackSettings.defaultSpeed

    var body: some View {
        let snapshot = cachedSnapshot ?? model.diagnosticsSnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Text("Settings").font(.largeTitle.bold())
                HStack(spacing: 24) {
                    Label("Discover Playback Speed", systemImage: "gauge.with.needle")
                        .font(.headline)
                    Spacer()
                    Menu {
                        ForEach(PlaybackPreference.speedOptions, id: \.self) { speed in
                            Button {
                                discoverPlaybackSpeed = speed
                            } label: {
                                if abs(discoverPlaybackSpeed - speed) < 0.001 {
                                    Label(PlaybackPreference.speedLabel(speed), systemImage: "checkmark")
                                } else {
                                    Text(PlaybackPreference.speedLabel(speed))
                                }
                            }
                        }
                    } label: {
                        Label(
                            PlaybackPreference.speedLabel(discoverPlaybackSpeed),
                            systemImage: "chevron.up.chevron.down"
                        )
                        .frame(minWidth: 150)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTarget, equals: .discoverPlaybackSpeed)
                }
                .padding(20)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .focusSection()
                Text("Used when an episode is started from Discover. Subscription episodes continue to use their podcast-specific speed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                settingsHeading("iCloud & Subscriptions")
                diagnosticRow("iCloud & Up Next", value: snapshot.syncLabel)
                diagnosticRow("Up Next episodes", value: "\(snapshot.queueRowCount)")
                diagnosticRow("Podcasts", value: "\(snapshot.libraryPodcastCount)")
                Button {
                    Task {
                        await model.primeLibraryFromCloudSoon(reason: "tv.manualRetry")
                        cachedSnapshot = model.diagnosticsSnapshot
                    }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                Text("Autohop keeps your Apple TV in step through your private iCloud account. New changes may take a short time to arrive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                settingsHeading("Now Playing")
                diagnosticRow("Episode", value: snapshot.playbackTitle)
                diagnosticRow("Status", value: snapshot.playbackState)
                diagnosticRow("Position", value: friendlyDuration(TimeInterval(snapshot.playbackPositionSeconds)))
                diagnosticRow("Speed", value: String(format: "%.2f×", snapshot.configuredSpeed))

                settingsHeading("Apple TV Home Screen")
                diagnosticRow("Top Shelf publisher", value: snapshot.topShelf.publisher.phase)
                diagnosticRow("Eligible episodes", value: "\(snapshot.topShelf.publisher.candidateItems)")
                diagnosticRow("Artwork from TV cache", value: "\(snapshot.topShelf.publisher.artworkDiskCacheItems)")
                diagnosticRow("Artwork downloaded", value: "\(snapshot.topShelf.publisher.artworkNetworkItems)")
                diagnosticRow("Artwork placeholders", value: "\(snapshot.topShelf.publisher.artworkPlaceholderItems)")
                diagnosticRow("Shared App Group", value: snapshot.topShelf.appGroupAvailable ? "Available" : "Unavailable")
                diagnosticRow("Container root write probe", value: snapshot.topShelf.containerRootProbe)
                diagnosticRow("Library/Caches write probe", value: snapshot.topShelf.libraryCachesProbe)
                if let retry = snapshot.topShelf.publisher.retryAfterSeconds {
                    diagnosticRow("Automatic retry", value: friendlyDuration(TimeInterval(retry)))
                }
                diagnosticRow("Suppressed repeat attempts", value: "\(snapshot.topShelf.publisher.suppressedRequests)")
                diagnosticRow("Dynamic snapshot", value: topShelfManifestLabel(snapshot.topShelf))
                diagnosticRow("Top Shelf extension", value: topShelfExtensionLabel(snapshot.topShelf))
                if let error = snapshot.topShelf.publisher.lastErrorCode {
                    diagnosticRow("Last publication error", value: error)
                }
                Button {
                    topShelfRefreshStatus = "Refreshing…"
                    Task {
                        await model.refreshTopShelfDiagnostics()
                        cachedSnapshot = model.diagnosticsSnapshot
                        topShelfRefreshStatus = "Refresh requested. Return to the Home Screen and focus Autohop."
                    }
                } label: {
                    Label("Refresh Top Shelf Now", systemImage: "rectangle.topthird.inset.filled")
                }
                .buttonStyle(.bordered)
                if let topShelfRefreshStatus {
                    Text(topShelfRefreshStatus).font(.callout).foregroundStyle(.secondary)
                }
                Text("Dynamic content requires Autohop in the Apple TV top row. These checks distinguish publication, shared-storage and extension failures without recording episode titles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                settingsHeading("About")
                diagnosticRow("Autohop for Apple TV", value: shortVersionIdentity)
                Text("Your subscriptions and Priority Stack are managed in Autohop on iPhone. Apple TV is designed for comfortable browsing, listening and watching on the big screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 12)
                settingsHeading("Developer Diagnostics")
                diagnosticRow("Launch state", value: snapshot.rootState)
                diagnosticRow("App uptime", value: friendlyDuration(TimeInterval(snapshot.appUptimeSeconds)))
                diagnosticRow("Memory footprint", value: snapshot.memoryFootprintMegabytes.map { "\($0) MB" } ?? "Unavailable")
                diagnosticRow("Thermal state", value: snapshot.thermalState)
                diagnosticRow("Main-thread hangs", value: "\(snapshot.mainThreadHangCount)")
                diagnosticRow("Longest main-thread hang", value: "\(snapshot.maximumMainThreadHangMilliseconds) ms")
                diagnosticRow("Suspension gaps excluded", value: "\(snapshot.inactiveWatchdogGapCount)")
                diagnosticRow("Waiting for legacy details", value: "\(snapshot.unresolvedQueue.count)")
                ForEach(snapshot.unresolvedQueue, id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                diagnosticRow("Subscriptions awaiting details", value: "\(snapshot.pendingMaterialization.count)")
                ForEach(snapshot.pendingMaterialization, id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                diagnosticRow(
                    "Player rate",
                    value: String(format: "%.2f×", snapshot.playerRate)
                )
                diagnosticRow(
                    "History uploads pending",
                    value: "\(snapshot.pendingHistoryUploads)"
                )
                diagnosticRow("Build identity", value: versionIdentity)
                Label("Redacted diagnostic logging is active", systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("The technical export below is intended for troubleshooting with the developer and must be retrieved from the Apple TV app container using Xcode.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await prepareDiagnosticExport() }
                } label: {
                    Label(
                        isPreparingExport ? "Preparing Diagnostic Export…" : "Prepare Full Diagnostic Export",
                        systemImage: "doc.badge.gearshape"
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(isPreparingExport)
                if let exportStatus {
                    Text(exportStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        // AI CONTEXT — The speed menu is the first actionable user setting.
        // Explicit initial focus prevents tvOS from skipping the Menu and
        // selecting the later "Check for Updates" button instead.
        .defaultFocus($focusedTarget, .discoverPlaybackSpeed)
        .onAppear { cachedSnapshot = model.diagnosticsSnapshot }
    }

    /// tvOS has no general-purpose share sheet. Create a redacted, stitched
    /// export beside AppLogger's live file — the exact directory already proven
    /// writable by this process — so it can be retrieved with Xcode's Devices
    /// and Simulators → Download Container command. The source log remains
    /// capped/rotated and nothing is uploaded.
    // AI CONTEXT — Log stitching/redaction can process roughly 10 MB across
    // the current and rotated files. It must never execute on MainActor: a
    // physical build proved the former synchronous button froze tvOS for 46 s.
    // Capture small UI/model values first, perform all file work on a detached
    // utility task, then publish only the result back to SwiftUI.
    @MainActor
    private func prepareDiagnosticExport() async {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        exportStatus = "Preparing a privacy-safe report…"
        let startedAt = ContinuousClock.now
        let snapshot = model.diagnosticsSnapshot
        do {
            let destination = try await Task.detached(priority: .utility) {
                var destination = try AppLogger.shared.writeRedactedExportBesideLiveLog()
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? destination.setResourceValues(values)
                return destination
            }.value
            let elapsed = startedAt.duration(to: .now)
            let elapsedMilliseconds = Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            let byteCount = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            exportStatus = "Export ready in Library/Caches/Autohop"
            AppLogger.shared.info(
                "tv.diagnostics.exportPrepared",
                "Redacted Apple TV diagnostic export prepared",
                metadata: [
                    "location": "Library/Caches/Autohop",
                    "topShelfPublisher": snapshot.topShelf.publisher.phase,
                    "topShelfExtension": snapshot.topShelf.extensionOutcome,
                    "memoryMB": snapshot.memoryFootprintMegabytes.map(String.init) ?? "unknown",
                    "mainThreadHangs": "\(snapshot.mainThreadHangCount)",
                    "durationMs": "\(elapsedMilliseconds)",
                    "sizeBytes": "\(byteCount)",
                    "execution": "utilityDetached"
                ],
                alwaysPersist: true
            )
        } catch {
            exportStatus = "Could not prepare export: \(error.localizedDescription)"
            AppLogger.shared.error(
                "tv.diagnostics.exportFailed",
                "Could not prepare redacted Apple TV diagnostic export",
                metadata: ["error": String(describing: error)],
                alwaysPersist: true
            )
        }
        isPreparingExport = false
    }

    private func topShelfManifestLabel(_ health: TVTopShelfHealthDiagnostics) -> String {
        var components = [health.manifestState]
        if let generation = health.manifestGeneration { components.append("generation \(generation)") }
        if health.manifestItems > 0 { components.append("\(health.manifestItems) episodes") }
        if let age = health.manifestAgeSeconds { components.append("\(age)s old") }
        return components.joined(separator: " · ")
    }

    private func topShelfExtensionLabel(_ health: TVTopShelfHealthDiagnostics) -> String {
        var components = [health.extensionOutcome]
        if let age = health.extensionAgeSeconds { components.append("\(age)s ago") }
        if let duration = health.extensionLoadMilliseconds { components.append("\(duration)ms") }
        return components.joined(separator: " · ")
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Text(value).foregroundStyle(.secondary) }
            .padding(20)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            // Read-only rows are deliberate focus stops. Without them tvOS
            // jumps between buttons separated by several screens of content.
            .focusable()
    }

    private func settingsHeading(_ title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.top, 38)
            .padding(.bottom, 4)
    }

    private func friendlyDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "Not started" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private var shortVersionIdentity: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private var versionIdentity: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · \(info["GitCommitSHA"] as? String ?? "unknown") · \(info["BuildTimestampUTC"] as? String ?? "unknown")"
    }
}
