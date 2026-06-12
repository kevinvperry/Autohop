import SwiftUI

// AI CONTEXT — Views/DiagnosticLogView.swift ("Diagnostic Log" page, hidden
// dev/support tool unlocked via Settings → About → tap version 5×). Renders
// AppLogger's log file lines with share/clear actions. No feature logic.
struct DiagnosticLogView: View {
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var logLines: [String] = []
    @State private var showClearConfirmation = false

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
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Diagnostic Log")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    loadLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                ShareLink(item: logger.redactedExportURL()) {
                    Image(systemName: "square.and.arrow.up")
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
                loadLog()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the current diagnostic log and starts a fresh one for the next build or test run.")
        }
        .onAppear(perform: loadLog)
        .onChange(of: logger.lastUpdated) { _, _ in
            loadLog()
        }
    }

    private func loadLog() {
        logLines = logger.recentLines(limit: 500)
    }
}
