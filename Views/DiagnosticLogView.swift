import SwiftUI

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
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill").responsiveToolbarBackSymbol() }.accessibilityLabel("Back")
            }

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
        logLines = logger.recentLines(limit: 500)
    }

    /// Reload the visible lines AND regenerate the redacted export file. Kept off the
    /// per-write `lastUpdated` path (only onAppear / the refresh button / after clear)
    /// so the now-larger log isn't re-read and re-redacted on the main thread on every
    /// log line while this view is open.
    private func refresh() {
        loadLog()
        exportURL = logger.redactedExportURL()
    }
}
