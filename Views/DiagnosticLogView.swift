// AI CONTEXT — Navigation compatibility, 20 September 2026 (DiagnosticLogView.swift).
// PURPOSE: Prevent duplicate native/custom Back controls reported on iOS 27.
// COLLABORATOR: RootView.swift owns appNavigationBackButton: native Back on iOS
// 27+, branded ambient dismiss on older systems. Do not add a second leading Back
// or mutate the outer path; preserve the nearest parent and existing mini-player.
// EVIDENCE: Docs/IOS27_NAVIGATION_BACK_AUDIT.md and NavigationChromeTests.

import SwiftUI

// MINI-PLAYER CONTRACT (2026-09-06): This pushed diagnostic destination owns
// miniPlayerBar. Preserve it when changing the log viewer or its toolbar actions.

// AI CONTEXT — Views/DiagnosticLogView.swift ("Diagnostic Log" page, hidden
// dev/support tool unlocked via Settings → About → tap version 5×). Renders
// AppLogger's log file lines with share/clear actions. No feature logic. The
// log's inner monospaced line stack uses adaptivePageContent so its readable
// width and outer gutter respond to the offered container; the ScrollView and
// page background remain full width.
struct DiagnosticLogView: View {
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var logLines: [String] = []
    // AI: File reads and redaction stay off MainActor; reject stale results.
    @State private var refreshID = UUID()
    @State private var exportError: String?
    @State private var readingLog = false
    @State private var exportURL: URL?
    @State private var showClearConfirmation = false

    private var pageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    var body: some View {
        VStack(spacing: 0) {
            if logLines.isEmpty {
                ContentUnavailableView(
                    "No log entries yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("The app will start recording actions as you use it.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(
                                    size: AdaptiveListRowMetrics(containerWidth: viewportWidth).secondaryFontSize,
                                    design: .monospaced
                                ))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 16)
                    .adaptivePageContent(.list)
                }
            }
        }
        .background(pageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Diagnostic Log")
        .responsiveInlineNavigationTitle("Diagnostic Log")
        .miniPlayerBar()
        .appNavigationBackButton()
        .toolbar {

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .responsiveToolbarSymbol()
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                            .responsiveToolbarSymbol()
                    }
                }

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logLines.isEmpty)
            }
        }
        .alert("Could not prepare diagnostic export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
        .confirmationDialog("Clear diagnostic log?", isPresented: $showClearConfirmation) {
            Button("Delete Log History", role: .destructive) {
                logger.clear()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the current diagnostic log and starts a fresh one for the next build or test run.")
        }
        .onAppear(perform: refresh)
        .onChange(of: logger.lastUpdated) { _, _ in
            loadLog()
        }
    }

    private func loadLog() {
        guard !readingLog else { return }
        readingLog = true
        Task {
            let lines = await Task.detached(priority: .utility) { AppLogger.shared.recentLines(limit: 500) }.value
            logLines = lines
            readingLog = false
        }
    }

    /// Reload the visible lines AND regenerate the redacted export file. Kept off the
    /// per-write `lastUpdated` path (only onAppear / the refresh button / after clear)
    /// so the now-larger log isn't re-read and re-redacted on the main thread on every
    /// log line while this view is open.
    private func refresh() {
        loadLog()
        let id = UUID()
        refreshID = id
        exportURL = nil
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("autohop-diagnostic-redacted.log")
                    try AppLogger.shared.writeRedactedExport(to: url)
                    return url
                }.value
                guard refreshID == id else { return }
                exportURL = url
            } catch {
                guard refreshID == id else { return }
                exportError = error.localizedDescription
            }
        }
    }
}
