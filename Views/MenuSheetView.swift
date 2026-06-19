import SwiftUI

// AI CONTEXT — Views/MenuSheetView.swift ("Menu" sheet, hamburger ☰ on the
// Subscriptions toolbar). The single gateway to the secondary pages —
// Discover (top item — dismisses the Menu, then posts .autohopOpenDiscover so
// RootView pushes DiscoverView as a full page on the main stack), Downloads, Listening
// History, Stats, Sleep Schedule, App Settings, and Support (last item — the
// in-app User Guide, SupportView, which mirrors the website Support page).
// NavRules: one path per page; Find Podcasts lives behind + only; OPML import
// lives in Settings → Subscriptions.
struct MenuSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var appearTime: Date?

    private let logger = AppLogger.shared

    var body: some View {
        NavigationStack {
            List {
                Button {
                    // Discover opens as a full page on the main stack, not inside
                    // this sheet — dismiss, then ask RootView to push it.
                    dismiss()
                    NotificationCenter.default.post(name: .autohopOpenDiscover, object: nil)
                } label: {
                    Label("Discover", systemImage: "safari")
                        .foregroundStyle(.primary)
                }
                .listRowBackground(Color.white.opacity(0.07))

                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .listRowBackground(Color.white.opacity(0.07))

                NavigationLink {
                    ListeningHistoryView()
                } label: {
                    Label("Listening History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .listRowBackground(Color.white.opacity(0.07))

                NavigationLink {
                    StatsView()
                } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
                .listRowBackground(Color.white.opacity(0.07))

                NavigationLink {
                    SleepScheduleView()
                } label: {
                    Label("Sleep Schedule", systemImage: "moon.zzz")
                }
                .listRowBackground(Color.white.opacity(0.07))

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .listRowBackground(Color.white.opacity(0.07))

                NavigationLink {
                    SupportView()
                } label: {
                    Label("Support", systemImage: "questionmark.circle")
                }
                .listRowBackground(Color.white.opacity(0.07))
            }
            .scrollContentBackground(.hidden)
            .tint(.primary)
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .presentationBackground(.regularMaterial)
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
        .onReceive(NotificationCenter.default.publisher(for: .autohopOpenSubscriptions)) { _ in
            // Settings → Manage podcasts: close the Menu (Settings is pushed
            // inside it) to reveal the Subscriptions page beneath.
            dismiss()
        }
    }

}
