import SwiftUI
import AutohopCore

// AI CONTEXT — Phase 5 TV Settings/Diagnostics surface. This is intentionally
// factual and compact: projection health, build identity and a redacted log
// export. It never claims a silent push guarantees execution.
struct TVDiagnosticsView: View {
    let model: TVAppModel
    @State private var exportStatus: String?
    @AppStorage(TVDiscoverPlaybackSettings.key)
    private var discoverPlaybackSpeed = TVDiscoverPlaybackSettings.defaultSpeed

    var body: some View {
        let snapshot = model.diagnosticsSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings & Diagnostics").font(.largeTitle.bold())
                HStack {
                    Label("Discover Playback Speed", systemImage: "gauge.with.needle")
                        .font(.headline)
                    Spacer()
                    Picker("Discover Playback Speed", selection: $discoverPlaybackSpeed) {
                        ForEach(PlaybackPreference.speedOptions, id: \.self) { speed in
                            Text(PlaybackPreference.speedLabel(speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
                .padding(20)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                Text("Used when an episode is started from Discover. Library episodes continue to use their podcast-specific speed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    prepareDiagnosticExport()
                } label: {
                    Label("Prepare Full Diagnostic Export", systemImage: "doc.badge.gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                if let exportStatus {
                    Text(exportStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                diagnosticRow("iCloud & Up Next", value: snapshot.syncLabel)
                diagnosticRow("Queue rows", value: "\(snapshot.queueRowCount)")
                diagnosticRow("Waiting for legacy details", value: "\(snapshot.unresolvedQueue.count)")
                ForEach(snapshot.unresolvedQueue, id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                diagnosticRow("Library podcasts", value: "\(snapshot.libraryPodcastCount)")
                diagnosticRow("Subscriptions awaiting details", value: "\(snapshot.pendingMaterialization.count)")
                ForEach(snapshot.pendingMaterialization, id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                diagnosticRow(
                    "Current playback",
                    value: snapshot.playbackTitle
                )
                diagnosticRow(
                    "Playback state",
                    value: snapshot.playbackState
                )
                diagnosticRow(
                    "Playback position",
                    value: "\(snapshot.playbackPositionSeconds) sec"
                )
                diagnosticRow(
                    "Playback speed",
                    value: String(format: "%.2f×", snapshot.configuredSpeed)
                )
                diagnosticRow(
                    "Player rate",
                    value: String(format: "%.2f×", snapshot.playerRate)
                )
                diagnosticRow(
                    "History uploads pending",
                    value: "\(snapshot.pendingHistoryUploads)"
                )
                diagnosticRow("Version", value: versionIdentity)
                Button {
                    Task { await model.primeLibraryFromCloudSoon(reason: "tv.manualRetry") }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                Label("Redacted diagnostic log is being collected", systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Apple TV checks for the phone-authored queue through iCloud. Push notifications are wake hints and may be delayed by the system.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
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

    private var versionIdentity: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · \(info["GitCommitSHA"] as? String ?? "unknown") · \(info["BuildTimestampUTC"] as? String ?? "unknown")"
    }
}
