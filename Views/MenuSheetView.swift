import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/MenuSheetView.swift ("Menu" sheet, hamburger ☰ on the
// Subscriptions toolbar). The single gateway to the secondary pages —
// Discover (top item, presented as its own sheet), Downloads, Listening
// History, Stats, App Settings — plus the Import OPML action (NavRules: one
// path per page; Find Podcasts lives behind + only).
struct MenuSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showDiscover = false
    @State private var showOPMLImporter = false
    @State private var isImporting = false
    @State private var appearTime: Date?

    private let logger = AppLogger.shared

    var body: some View {
        NavigationStack {
            List {
                Button {
                    showDiscover = true
                } label: {
                    Label("Discover", systemImage: "safari")
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
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDiscover) { DiscoverView() }
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

}
