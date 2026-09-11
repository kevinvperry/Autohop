// AI CONTEXT — Tests/DesktopCommandTests.swift
// PURPOSE: Command-policy and live UIKit responder regression coverage.
// COLLABORATORS: DesktopMenuBuilder, DesktopFocus, AppDelegate, DesktopHostingController.
// INVARIANTS: Cover unique shortcuts/selectors, sender-independent validation, normal
// window fallback, modal/editing guards, contextual selection and real typed routing.
// PRESENTATION: Full Menu regression exercises compact and regular presentation
// inside DesktopHostingController without ambient app dependencies.
// LIMITS: Hosted test depends on app startup/navigation timing; a simulator pass
// is not a physical Mac menu/keyboard walkthrough. Use signed tests for CloudKit startup.

import SwiftUI
import XCTest
import UIKit
import Combine
@testable import Autohop

final class DesktopCommandTests: XCTestCase {
    func testShortcutsAreUniqueAndDoNotOverrideStandardEditing() {
        var keys = Set<String>()
        for command in DesktopCommand.allCases {
            guard let (key, flags) = command.key else { continue }
            XCTAssertTrue(keys.insert("\(flags.rawValue):\(key)").inserted, "Duplicate: \(command)")
            if flags == .command {
                XCTAssertFalse(["c", "v", "x", "a", "z", "q", "w", "h", "m"].contains(key))
            }
        }
    }

    func testMenuSpeedsMatchExistingPlaybackControls() {
        XCTAssertEqual(DesktopCommand.allCases.compactMap(\.speed), PlaybackPreference.speedOptions)
    }

    func testEmptyPlaybackDisablesTransportButAllowsNavigation() {
        let state = DesktopCommandAvailability()
        for command: DesktopCommand in [.playPause, .skipBack, .skipForward, .nextEpisode, .speed150, .audioControls] {
            XCTAssertFalse(state.allows(command), "\(command)")
        }
        XCTAssertTrue(state.allows(.search))
        XCTAssertTrue(state.allows(.settings))
        XCTAssertFalse(state.allows(.exportSubscriptions))
    }

    func testQueueCanStartWithoutLoadedEpisode() {
        var state = DesktopCommandAvailability()
        state.hasQueue = true
        XCTAssertTrue(state.allows(.playPause))
        XCTAssertFalse(state.allows(.nextEpisode))
    }

    func testEditingDoesNotConsumeTextNavigationOrFormSubmit() {
        var state = DesktopCommandAvailability()
        state.hasEpisode = true
        state.editing = true
        state.canGoBack = true
        state.hasPreviousChapter = true
        state.hasNextChapter = true
        for command: DesktopCommand in [.playPause, .skipBack, .skipForward, .nextEpisode, .previousChapter, .nextChapter, .back] {
            XCTAssertFalse(state.allows(command), "\(command)")
        }
    }

    func testModalCannotBeDiscardedByNavigation() {
        var state = DesktopCommandAvailability()
        state.modal = true
        state.hasEpisode = true
        state.hasShow = true
        state.hasRealShow = true
        state.hasSelectedEpisode = true
        for command in DesktopCommand.allCases where command.destination != nil {
            XCTAssertFalse(state.allows(command), "\(command)")
        }
        XCTAssertFalse(state.allows(.openShow))
        XCTAssertFalse(state.allows(.archive))
        XCTAssertTrue(state.allows(.playPause))
    }

    func testContextualCommandsDoNotFallBackToPlayingEpisode() {
        var state = DesktopCommandAvailability()
        state.hasEpisode = true
        for command: DesktopCommand in [.openShow, .showSettings, .toggleSubscription, .refreshShow, .download, .playNext, .playLast, .archive] {
            XCTAssertFalse(state.allows(command), "\(command)")
        }
        state.hasShow = true
        XCTAssertTrue(state.allows(.openShow))
        XCTAssertFalse(state.allows(.showSettings)) // Browse preview is not a real subscription.
        state.hasRealShow = true
        XCTAssertTrue(state.allows(.showSettings))
    }

    func testChapterAndBusyValidation() {
        var state = DesktopCommandAvailability()
        state.hasEpisode = true
        state.hasSubscriptions = true
        XCTAssertFalse(state.allows(.nextChapter))
        state.hasNextChapter = true
        XCTAssertTrue(state.allows(.nextChapter))
        state.transportBusy = true
        XCTAssertFalse(state.allows(.nextEpisode))
        XCTAssertFalse(state.allows(.nextChapter))
        state.libraryBusy = true
        XCTAssertFalse(state.allows(.refreshAll))
        state.importing = true
        XCTAssertFalse(state.allows(.importSubscriptions))
        XCTAssertFalse(state.allows(.exportSubscriptions))
    }

    @MainActor
    func testWindowRemainsAvailableWhileMenuTrackingClearsKeyStatus() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(DesktopFocus.commandWindow(in: [window]) === window)
        let overlay = UIWindow()
        overlay.rootViewController = UIViewController()
        overlay.windowLevel = .alert
        overlay.isHidden = false
        defer { overlay.isHidden = true }
        XCTAssertTrue(DesktopFocus.commandWindow(in: [overlay, window]) === window)
        window.isHidden = true
        XCTAssertNil(DesktopFocus.commandWindow(in: [overlay, window]))
    }

    @MainActor
    func testEveryCommandHasUniqueSelectorAndDelegateFallback() {
        let delegate = AppDelegate()
        XCTAssertEqual(Set(DesktopCommand.allCases.map(\.selector)).count, DesktopCommand.allCases.count)
        for command in DesktopCommand.allCases {
            XCTAssertEqual(DesktopCommand(selector: command.selector), command)
            XCTAssertTrue(delegate.responds(to: command.selector))
            XCTAssertFalse(delegate.canPerformAction(command.selector, withSender: nil), "No services before bootstrap")
        }
        XCTAssertNil(DesktopCommand(selector: #selector(UIResponder.copy(_:))))
    }

    @MainActor
    func testMenuItemsCarrySemanticIdentifiers() {
        for command in DesktopCommand.allCases {
            let item = DesktopMenuBuilder.item(command)
            XCTAssertEqual(item.propertyList as? String, command.rawValue)
            XCTAssertEqual(item.action, command.selector)
            if let (key, modifiers) = command.key {
                XCTAssertEqual((item as? UIKeyCommand)?.input, key)
                XCTAssertEqual((item as? UIKeyCommand)?.modifierFlags, modifiers)
            }
        }
    }

    @MainActor
    func testVisibleNavigationControllerIgnoresHiddenDetail() {
        let hidden = DesktopContextController()
        hidden.subscriptionID = UUID()
        let visible = UIViewController()
        let navigation = UINavigationController()
        navigation.setViewControllers([hidden, visible], animated: false)
        XCTAssertTrue(DesktopFocus.visibleController(navigation) === visible)
        XCTAssertNil(DesktopFocus.context(in: navigation))
        navigation.popViewController(animated: false)
        XCTAssertTrue(DesktopFocus.context(in: navigation) === hidden)
    }
    @MainActor
    func testMenuPresentsWithExplicitDependenciesInBothSizeClasses() async throws {
        for _ in 0..<50 {
            if AppState.shared != nil, DesktopFocus.window?.windowScene != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let app = try XCTUnwrap(AppState.shared)
        let originalWindow = try XCTUnwrap(DesktopFocus.window)
        let scene = try XCTUnwrap(originalWindow.windowScene)
        // No inherited app environment on the host: Menu must be self-contained
        // at the presentation boundary, including its mini-player and overlay.
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let host = DesktopHostingController(content: AnyView(
                MenuPresentationProbe(app: app)
                    .environment(\.horizontalSizeClass, sizeClass)
            ), handler: app.desktopCommands)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                originalWindow.makeKeyAndVisible()
            }
            for _ in 0..<30 {
                if host.presentedViewController != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let presented = try XCTUnwrap(host.presentedViewController,
                                          "Menu should present for \(sizeClass)")
            for _ in 0..<30 {
                if presented.viewIfLoaded?.window != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            presented.view.layoutIfNeeded()
            XCTAssertNotNil(presented.view.window, "Menu must finish attaching to its window")
            // Allow NavigationStack, MenuMiniPlayer and overlay updates to render.
            try await Task.sleep(for: .milliseconds(300))
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
    }

    @MainActor
    func testHostedResponderRoutesMenuCommandThroughLiveHostingController() async throws {
        // Exercise the actual SwiftUI UIApplicationDelegateAdaptor/responder chain,
        // rather than calling the handler directly. No library data is changed.
        for _ in 0..<30 {
            if AppState.shared != nil, DesktopFocus.window != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let app = try XCTUnwrap(AppState.shared)
        try await Task.sleep(for: .seconds(2))
        app.routingCoordinator.send(.openDesktop(.shortcuts))
        // Wait for actual presentation readiness, not a fixed cold-launch delay.
        for _ in 0..<100 {
            if DesktopFocus.context != nil, !DesktopFocus.hasModal { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(DesktopFocus.context, "Visible SwiftUI page should publish its command context")
        var received: [AppRouteCommand] = []
        let observation = app.routingCoordinator.commands.sink { received.append($0) }
        defer {
            observation.cancel()
            app.routingCoordinator.send(.openDesktop(.player))
        }
        func host(in controller: UIViewController) -> DesktopHostingController? {
            if let controller = controller as? DesktopHostingController { return controller }
            return controller.children.lazy.compactMap { host(in: $0) }.first
        }
        let root = try XCTUnwrap(DesktopFocus.window?.rootViewController)
        let controller = try XCTUnwrap(host(in: root))
        for command in DesktopCommand.allCases {
            XCTAssertTrue(controller.responds(to: command.selector))
            XCTAssertEqual(controller.canPerformAction(command.selector, withSender: nil), app.desktopCommands.allows(command))
            XCTAssertEqual(controller.canPerformAction(command.selector, withSender: NSObject()), app.desktopCommands.allows(command))
        }
        let delegate = AppDelegate()
        delegate.appState = app
        XCTAssertTrue(delegate.canPerformAction(DesktopCommand.settings.selector, withSender: nil))
        let bridgedCommand = UICommand(title: "Settings…", action: DesktopCommand.settings.selector)
        controller.validate(bridgedCommand)
        XCTAssertFalse(bridgedCommand.attributes.contains(.disabled), "Validation cannot require a propertyList")

        let command = DesktopMenuBuilder.item(.settings)
        XCTAssertTrue(UIApplication.shared.sendAction(command.action, to: nil, from: nil, for: nil),
                      "The live responder chain must find the hosting controller")
        XCTAssertEqual(received, [.openDesktop(.settings)])
        try await Task.sleep(for: .milliseconds(500))
        let back = DesktopMenuBuilder.item(.back)
        XCTAssertTrue(UIApplication.shared.sendAction(back.action, to: nil, from: NSObject(), for: nil))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(DesktopFocus.context?.allowsSpace, true, "Back must reveal the permanent Player")
        app.routingCoordinator.send(.openDesktop(.search))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(DesktopFocus.isEditing, "Find Podcasts should focus the search field")
        let subscriptions = DesktopMenuBuilder.item(.subscriptions)
        XCTAssertTrue(UIApplication.shared.sendAction(subscriptions.action, to: nil, from: subscriptions, for: nil))
        XCTAssertEqual(received.last, .openDesktop(.subscriptions), "Navigation remains available while searching")
        delegate.desktop_settings(nil)
        XCTAssertEqual(received.last, .openDesktop(.settings), "Delegate fallback dispatches without a UIKit sender")

        XCTAssertEqual(DesktopMenuBuilder.installedCommands, Set(DesktopCommand.allCases), "Main menu contains the full command catalogue")

    }

}

// Exercise the same adaptive presentation and explicit environment placement
// used by both PlayerView and PodcastsView, without any ambient app services.
private struct MenuPresentationProbe: View {
    let app: AppState
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .adaptiveNavigationPresentation(isPresented: $isPresented) {
                MenuSheetView().appEnvironment(app)
            }
            .task { isPresented = true }
    }
}
