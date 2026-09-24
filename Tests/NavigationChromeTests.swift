// AI CONTEXT — NavigationChromeTests, 20 September 2026.
// PURPOSE: Host real SwiftUI pages to check one Back control and nearest-parent
// dismissal across iOS 26/27, including explicit modal roots and native pages.
// COLLABORATORS: RootView Back policy, UIKit navigation items, live app environment.
// Sleep Schedule scenarios use an isolated SettingsStoring implementation; opening
// and leaving must preserve the full settings snapshot, including disabled values.
// Capture scroll positions and accessibility text layouts for visual inspection.
// LIMITS: Unavailable-data routes do not prove populated flows. These checks do
// not exercise physical gestures, every editor, overnight audio or notifications.
// EVIDENCE: Docs/IOS27_NAVIGATION_BACK_AUDIT.md; Docs/SLEEP_SCHEDULE_DESIGN_AUDIT.md.

import SwiftUI
import UIKit
import XCTest
@testable import Autohop

/// Inspect real rendered navigation items, then dismiss one destination. These
/// tests cover the compatibility policy on whichever iOS runtime runs the suite.
@MainActor
final class NavigationChromeTests: XCTestCase {
    // AI CONTEXT — Render the production mini-player surface over recognisable
    // rows through the home-indicator area, including a sheet presentation.
    // Inspect colour continuity above/below progress as well as coverage: a
    // material-only safe-area patch covers rows but mismatches the glass bar.
    // This isolates backing geometry without starting audio or altering library state.
    func testMiniPlayerBackingCoversBottomSafeArea() async throws {
        for _ in 0..<100 {
            if DesktopFocus.window?.windowScene != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let original = try XCTUnwrap(DesktopFocus.window)
        let scene = try XCTUnwrap(original.windowScene)
        for sheet in [false, true] {
            let host = UIHostingController(rootView: MiniPlayerBackingProbe(sheet: sheet))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1))
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "Mini player backing \(sheet ? "sheet" : "page") \(UIDevice.current.systemVersion)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(window.safeAreaInsets.bottom, 0)
            window.isHidden = true
            window.rootViewController = nil
        }
        original.makeKeyAndVisible()
    }

    func testDiscoverHasOneBackControlAndPreservesItsParent() async throws {
        try await check(AnyView(DiscoverView()), name: "Discover", capture: true)
    }

    func testSleepSchedulePresentationPreservesSavedConfiguration() async throws {
        for (name, enabled, start, end, duration, textSize) in [
            ("Sleep Off", false, 21 * 60, 6 * 60, 20, DynamicTypeSize.large),
            ("Sleep Overnight", true, 21 * 60, 6 * 60, 20, DynamicTypeSize.large),
            ("Sleep Daytime", true, 9 * 60, 17 * 60, 60, DynamicTypeSize.large),
            ("Sleep All Day Episode End Large Text", true, 0, 0, 0, DynamicTypeSize.accessibility3)
        ] {
            let store = NavigationSleepSettingsStore()
            store.appSettings.sleepScheduleEnabled = enabled
            store.appSettings.sleepScheduleStartMinutes = start
            store.appSettings.sleepScheduleEndMinutes = end
            store.appSettings.sleepScheduleDurationMinutes = duration
            let original = store.appSettings
            let model = SettingsViewModel(settingsStore: store)
            try await check(AnyView(SleepScheduleView()
                .environmentObject(model).dynamicTypeSize(textSize)),
                name: name, capture: true, captureBottom: true)
            XCTAssertEqual(store.appSettings, original, "Opening or leaving \(name) must not reset saved settings")
        }
    }

    func testOtherPushedPagesHaveOneBackControl() async throws {
        let missingID = UUID()
        let charts = DiscoverViewModel()
        let pages: [(String, AnyView)] = [
            ("Top Episodes", AnyView(TopEpisodesView(viewModel: charts, country: .deviceDefault))),
            ("Top Podcasts", AnyView(TopPodcastsView(viewModel: charts, country: .deviceDefault))),
            ("Podcast Detail unavailable", AnyView(PodcastDetailView(subscriptionID: missingID))),
            ("Podcast Settings unavailable", AnyView(SubscriptionSettingsView(subscriptionID: missingID))),
            ("Episode Detail unavailable", AnyView(EpisodeDetailView(subscriptionID: missingID, episodeID: UUID()))),
            ("Download Filters unavailable", AnyView(DownloadFiltersView(subscriptionID: missingID))),
            ("Podcast Replay unavailable", AnyView(PodcastReplayView(subscriptionID: missingID))),
            ("Add RSS Feed", AnyView(AddFeedView())),
            ("Settings", AnyView(SettingsView())),
            ("Feed Refresh Schedule", AnyView(FeedRefreshScheduleView())),
            ("Auto Archive Activity", AnyView(AutoArchiveActivityView())),
            ("Acknowledgements", AnyView(AcknowledgementsView())),
            ("Diagnostic Log", AnyView(DiagnosticLogView())),
            ("Downloads", AnyView(DownloadsView())),
            ("Sleep Schedule", AnyView(SleepScheduleView())),
            ("Keyboard Shortcuts", AnyView(DesktopShortcutsView()))
        ]
        for (name, page) in pages { try await check(page, name: name) }
    }

    func testNativeBackPagesDoNotAcquireACustomButton() async throws {
        for (name, page) in [
            ("Search", AnyView(PodcastSearchView(countryCode: "au"))),
            ("Stats", AnyView(StatsView())),
            ("Listening History", AnyView(ListeningHistoryView())),
            ("Notification Settings", AnyView(NotificationSettingsView())),
            ("Support", AnyView(SupportView())),
            ("Release Radar Data unavailable", AnyView(SubscriptionRadarDiagnosticsView(subscriptionID: UUID())))
        ] { try await check(page, name: name, nativeOnly: true) }
    }

    func testSubscriptionsRetainsItsMenuWithoutAnExtraBackButton() async throws {
        try await check(AnyView(PodcastsView()), name: "Subscriptions", customLeading: true)
    }

    func testModalRootsRetainTheirDismissControl() async throws {
        let id = UUID()
        for (name, page) in [
            ("Modal Podcast Detail", AnyView(PodcastDetailView(subscriptionID: id, isPresentationRoot: true))),
            ("Modal Podcast Settings", AnyView(SubscriptionSettingsView(subscriptionID: id, isPresentationRoot: true)))
        ] {
            try await check(page, name: name, customLeading: true, modal: true)
        }
    }

    private func check(_ page: AnyView, name: String, customLeading: Bool = false,
                       modal: Bool = false, capture: Bool = false, nativeOnly: Bool = false, captureBottom: Bool = false) async throws {
        for _ in 0..<100 {
            if AppState.shared != nil, DesktopFocus.window?.windowScene != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let app = try XCTUnwrap(AppState.shared)
        let originalWindow = try XCTUnwrap(DesktopFocus.window)
        let scene = try XCTUnwrap(originalWindow.windowScene)
        let host = UIHostingController(rootView:
            NavigationChromeProbe(destination: page, modal: modal).appEnvironment(app))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow.makeKeyAndVisible()
        }
        let expectedDepth = modal ? 1 : 3
        for _ in 0..<100 {
            if navigation(in: host)?.viewControllers.count == expectedDepth { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let nav = try XCTUnwrap(navigation(in: host), name)
        try await Task.sleep(for: .milliseconds(500))
        let item = try XCTUnwrap(nav.topViewController?.navigationItem, name)
        let expectsCustom: Bool
        if #available(iOS 27, *) { expectsCustom = customLeading } else { expectsCustom = !nativeOnly }
        XCTAssertEqual(item.hidesBackButton, expectsCustom, name)
        // SwiftUI's modern toolbar uses leading groups rather than legacy
        // leftBarButtonItems. Count the representation actually installed.
        let leadingItems = item.leadingItemGroups.isEmpty
            ? (item.leftBarButtonItems ?? [])
            : item.leadingItemGroups.flatMap(\.barButtonItems)
        XCTAssertEqual(leadingItems.count, expectsCustom ? 1 : 0, name)
        XCTAssertEqual(nav.viewControllers.count, expectedDepth, name)
        if capture {
            func snapshot(_ position: String) {
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "\(name) \(position) \(UIDevice.current.systemVersion)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            snapshot("top")
            if captureBottom {
                func scrollViews(_ view: UIView) -> [UIScrollView] {
                    (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                if let scroll = scrollViews(nav.view).max(by: { $0.contentSize.height < $1.contentSize.height }) {
                    // Form estimates unrendered row heights. Advance repeatedly
                    // so large-text cards are measured before capturing the end.
                    for step in 0..<6 {
                        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                        try await Task.sleep(for: .milliseconds(200))
                        if step == 0 { snapshot("middle") }
                    }
                    snapshot("bottom")
                }
            }
        }
        let context = try XCTUnwrap(DesktopFocus.context(in: nav.topViewController), name)
        context.back?()
        try await Task.sleep(for: .milliseconds(700))
        if modal {
            XCTAssertNil(host.presentedViewController, "\(name): dismiss the presentation")
        } else {
            XCTAssertEqual(nav.viewControllers.count, 2, "\(name): retain the immediate parent")
        }
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let presented = controller.presentedViewController { return navigation(in: presented) }
        if let nav = controller as? UINavigationController { return nav }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }
}

private struct NavigationChromeProbe: View {
    let destination: AnyView
    let modal: Bool
    @State private var path: [Int] = []
    @State private var presented = false

    var body: some View {
        NavigationStack(path: $path) {
            Text("Root")
                .navigationDestination(for: Int.self) { value in
                    if value == 1 {
                        Text("Parent").navigationTitle("Parent")
                    } else {
                        destination
                    }
                }
        }
        .sheet(isPresented: $presented) { NavigationStack { destination } }
        .task {
            if modal { presented = true } else { path = [1, 2] }
        }
    }
}

private final class NavigationSleepSettingsStore: SettingsStoring {
    var appSettings: AppSettings = .default
}

private struct MiniPlayerBackingProbe: View {
    let sheet: Bool
    @State private var presented = false

    private var page: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<60) { index in
                    Text("Underlying page row \(index)")
                        .font(.title.bold()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(index.isMultiple(of: 2) ? Color.black : Color.gray)
                }
            }
        }
        .background(.black)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Text("Mini player • Playback controls")
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 76)
                Rectangle().fill(.purple).frame(height: 3)
            }
            .modifier(PersistentMiniPlayerSurface())
        }
        .preferredColorScheme(.dark)
    }

    var body: some View {
        Group {
            if sheet {
                Color.black.sheet(isPresented: $presented) { page }
                    .task { presented = true }
            } else { page }
        }
    }
}
