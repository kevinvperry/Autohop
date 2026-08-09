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
    @FocusState private var focusedTarget: FocusTarget?
    @AppStorage(TVDiscoverPlaybackSettings.key)
    private var discoverPlaybackSpeed = TVDiscoverPlaybackSettings.defaultSpeed

    var body: some View {
        let snapshot = model.diagnosticsSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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
                Text("Used when an episode is started from Discover. Library episodes continue to use their podcast-specific speed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                settingsHeading("iCloud & Library")
                diagnosticRow("iCloud & Up Next", value: snapshot.syncLabel)
                diagnosticRow("Up Next episodes", value: "\(snapshot.queueRowCount)")
                diagnosticRow("Podcasts", value: "\(snapshot.libraryPodcastCount)")
                Button {
                    Task { await model.primeLibraryFromCloudSoon(reason: "tv.manualRetry") }
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

                settingsHeading("About")
                diagnosticRow("Autohop for Apple TV", value: shortVersionIdentity)
                Text("Your subscriptions and Priority Stack are managed in Autohop on iPhone. Apple TV is designed for comfortable browsing, listening and watching on the big screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 12)
                settingsHeading("Developer Diagnostics")
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
                    prepareDiagnosticExport()
                } label: {
                    Label("Prepare Full Diagnostic Export", systemImage: "doc.badge.gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
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
    }

    /// tvOS has no general-purpose share sheet. Create a redacted, stitched
    /// export beside AppLogger's live file — the exact directory already proven
    /// writable by this process — so it can be retrieved with Xcode's Devices
    /// and Simulators → Download Container command. The source log remains
    /// capped/rotated and nothing is uploaded.
    private func prepareDiagnosticExport() {
        do {
            var destination = try AppLogger.shared.writeRedactedExportBesideLiveLog()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? destination.setResourceValues(values)
            exportStatus = "Export ready in Library/Caches/Autohop"
            AppLogger.shared.info(
                "tv.diagnostics.exportPrepared",
                "Redacted Apple TV diagnostic export prepared",
                metadata: ["location": "Library/Caches/Autohop"],
                alwaysPersist: true
            )
        } catch {
            exportStatus = "Could not prepare export: \(error.localizedDescription)"
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Text(value).foregroundStyle(.secondary) }
            .padding(20)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
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
