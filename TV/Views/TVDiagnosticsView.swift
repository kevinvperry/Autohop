import SwiftUI
import AutohopCore

// AI CONTEXT — Phase 5 TV Settings/Diagnostics surface. This is intentionally
// factual and compact: projection health, build identity and a redacted log
// export. It never claims a silent push guarantees execution.
struct TVDiagnosticsView: View {
    let model: TVAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings & Diagnostics").font(.largeTitle.bold())
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
