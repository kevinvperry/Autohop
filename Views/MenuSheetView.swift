import SwiftUI
import UniformTypeIdentifiers

struct MenuSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showSearch = false
    @State private var showOPMLImporter = false
    @State private var isImporting = false
    @State private var appearTime: Date?

    private let logger = AppLogger.shared

    var body: some View {
        NavigationStack {
            List {
                Button {
                    dismiss()
                } label: {
                    Label("Subscriptions", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.primary)
                }

                Button {
                    showSearch = true
                } label: {
                    Label("Find Podcasts", systemImage: "magnifyingglass")
                        .foregroundStyle(.primary)
                }

                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

                NavigationLink {
                    ListeningHistoryView()
                } label: {
                    Label("Listening History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }

                NavigationLink {
                    StatsView()
                } label: {
                    Label("Stats", systemImage: "chart.bar")
                }

                Button {
                    showOPMLImporter = true
                } label: {
                    if isImporting {
                        Label {
                            HStack {
                                Text("Importing…")
                                Spacer()
                                ProgressView()
                            }
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    } else {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(isImporting)

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            .tint(.primary)
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        returnToPlayer()
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .accessibilityLabel("Return to Player")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showSearch) { PodcastSearchView() }
        .preferredColorScheme(.dark)
        .onAppear {
            let t = Date()
            appearTime = t
            logger.info("nav.appear", "MenuSheetView appeared", metadata: [
                "queueCount": "\(appState.downloadedQueue.count)"
            ])
            ResourceMonitor.shared.logSnapshot(reason: "nav.menuAppear")
        }
        .onDisappear {
            let durationMs = appearTime.map { Int(Date().timeIntervalSince($0) * 1000) }
            logger.info("nav.disappear", "MenuSheetView dismissed", metadata: [
                "visibleMs": durationMs.map(String.init) ?? "unknown"
            ])
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopReturnToPlayer)) { _ in
            dismiss()
        }
        .fileImporter(
            isPresented: $showOPMLImporter,
            allowedContentTypes: [.xml, .plainText],
            allowsMultipleSelection: false
        ) { result in
            guard let url = (try? result.get())?.first else { return }
            isImporting = true
            Task {
                _ = await appState.importOPML(from: url)
                isImporting = false
            }
        }
    }

    private func returnToPlayer() {
        NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
        dismiss()
    }
}
