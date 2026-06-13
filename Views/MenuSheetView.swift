import SwiftUI

// AI CONTEXT — Views/MenuSheetView.swift ("Menu" sheet, hamburger ☰ on the
// Subscriptions toolbar). The single gateway to the secondary pages —
// Discover (top item, presented as its own sheet), Downloads, Listening
// History, Stats, Sleep Schedule, App Settings, and Support (last item — the
// in-app User Guide, SupportView, which mirrors the website Support page).
// NavRules: one path per page; Find Podcasts lives behind + only; OPML import
// lives in Settings → Subscriptions.
struct MenuSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showDiscover = false
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

                NavigationLink {
                    SleepScheduleView()
                } label: {
                    Label("Sleep Schedule", systemImage: "moon.zzz")
                }

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }

                NavigationLink {
                    SupportView()
                } label: {
                    Label("Support", systemImage: "questionmark.circle")
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
    }

}
