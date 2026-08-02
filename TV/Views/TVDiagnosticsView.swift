import SwiftUI
import AutohopCore

// AI CONTEXT — Phase 5 TV Settings/Diagnostics surface. This is intentionally
// factual and compact: projection health, build identity and a redacted log
// export. It never claims a silent push guarantees execution.
struct TVDiagnosticsView: View {
    let model: TVAppModel
    @State private var exportStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings & Diagnostics").font(.largeTitle.bold())
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
                diagnosticRow("iCloud & Up Next", value: model.syncStatus.label)
                diagnosticRow("Queue rows", value: "\(model.queueRows.count)")
                diagnosticRow("Waiting for legacy details", value: "\(model.queueRows.filter { !$0.isPlayable }.count)")
                ForEach(model.unresolvedQueueDiagnostics, id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                diagnosticRow("Library podcasts", value: "\(model.libraryTiles.count)")
                diagnosticRow("Subscriptions awaiting details", value: "\(model.pendingMaterializationDiagnostics.count)")
                ForEach(model.pendingMaterializationDiagnostics, id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                diagnosticRow(
                    "Current playback",
                    value: model.playbackModel.currentEpisode?.title ?? "None"
                )
                diagnosticRow(
                    "Playback state",
                    value: String(describing: model.playbackModel.playbackState)
                )
                diagnosticRow(
                    "Playback position",
                    value: "\(Int(model.playbackModel.currentTime)) sec"
                )
                diagnosticRow(
                    "Playback speed",
                    value: String(format: "%.2f×", model.playbackModel.currentSpeed)
                )
                diagnosticRow(
                    "Player rate",
                    value: String(format: "%.2f×", Double(model.playbackModel.avPlayer?.rate ?? 0.0))
                )
                diagnosticRow(
                    "History uploads pending",
                    value: "\(model.subscriptionStore.pendingListeningHistoryUploadCount())"
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
