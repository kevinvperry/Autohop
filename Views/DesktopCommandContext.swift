// AI CONTEXT — Navigation compatibility, 20 September 2026 (DesktopCommandContext.swift).
// PURPOSE: Prevent duplicate native/custom Back controls reported on iOS 27.
// COLLABORATOR: RootView.swift owns appNavigationBackButton: native Back on iOS
// 27+, branded ambient dismiss on older systems. Do not add a second leading Back
// or mutate the outer path; preserve the nearest parent and existing mini-player.
// EVIDENCE: Docs/IOS27_NAVIGATION_BACK_AUDIT.md and NavigationChromeTests.

// AI CONTEXT — Views/DesktopCommandContext.swift
// PURPOSE: UIKit responder host, visible-page context and keyboard reference.
// COLLABORATORS: DesktopCommands, AutohopApp, RootView and mini-player page modifiers.
// INVARIANTS: Traverse only visible navigation/presentation branches. During Mac menu
// tracking a visible normal window may cease being key; exclude hidden/overlay windows.
// Forward selectors with nil or bridged senders. Do not steal editor/control focus.
// Space is player-only and yields to editing, controls and modals. Reuse the live handler.
// LAYOUT: The outer representable fills the container, including system safe areas.
// The hosted UIKit view supplies safe-area insets to its SwiftUI content. Confining
// this host to the outer safe area clips edge-to-edge splash backgrounds on iPhone.
// Ignore container insets only; preserve keyboard avoidance.

import SwiftUI
import UIKit

/// A context lives in the displayed hosting controller, not a global "last show"
/// slot. Inspecting only the visible navigation/presentation branch prevents a
/// hidden detail page from supplying selection to another page's menu.
struct DesktopCommandContext: UIViewControllerRepresentable {
    var subscriptionID: UUID? = nil
    var episodeID: UUID? = nil
    var allowsSpace = false
    var back: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> DesktopContextController { DesktopContextController() }
    func updateUIViewController(_ controller: DesktopContextController, context: Context) {
        controller.subscriptionID = subscriptionID
        controller.episodeID = episodeID
        controller.allowsSpace = allowsSpace
        controller.back = back
    }
}

final class DesktopContextController: UIViewController {
    var subscriptionID: UUID?
    var episodeID: UUID?
    var allowsSpace = false
    var back: (() -> Void)?
    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
    }
}

@MainActor
enum DesktopFocus {
    static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        return commandWindow(in: scenes.flatMap(\.windows))
    }

    /// Menu tracking may temporarily clear isKeyWindow. Retain the visible app
    /// window, but never choose hidden windows or keyboard/overlay windows.
    static func commandWindow(in windows: [UIWindow]) -> UIWindow? {
        let visible = windows.filter { !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal && $0.rootViewController != nil }
        return visible.first(where: \.isKeyWindow) ?? visible.first
    }

    static func visibleController(_ root: UIViewController?) -> UIViewController? {
        guard let root else { return nil }
        if let presented = root.presentedViewController { return visibleController(presented) }
        if let nav = root as? UINavigationController { return visibleController(nav.visibleViewController) }
        if let tab = root as? UITabBarController { return visibleController(tab.selectedViewController) }
        return root
    }

    static func context(in root: UIViewController?) -> DesktopContextController? {
        guard let root = visibleController(root) else { return nil }
        if let context = root as? DesktopContextController { return context }
        for child in root.children.reversed() where child.viewIfLoaded?.window != nil {
            if let found = context(in: child) { return found }
        }
        return nil
    }

    static var context: DesktopContextController? { context(in: window?.rootViewController) }
    static var hasModal: Bool {
        func presented(_ root: UIViewController) -> Bool {
            root.presentedViewController != nil || root.children.contains(where: presented)
        }
        return window?.rootViewController.map(presented) ?? false
    }
    static var firstResponder: UIView? {
        func find(_ view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.flatMap(find)
    }
    static var isEditing: Bool { firstResponder is UITextInput }
}

struct DesktopShortcutsView: View {
    var body: some View {
        List {
            Section {
                Text("These shortcuts work while Autohop is active. Show and episode actions use the visible detail page. Close a dialog before navigating to another page.")
                Text("Space toggles playback on the Player when a text field or another control does not have keyboard focus. Standard Mac editing, window, Hide and Quit shortcuts remain available.")
            }
            Section("Application shortcuts") {
                ForEach(DesktopCommand.allCases.filter { $0.key != nil }, id: \.rawValue) { command in
                    HStack {
                        Text(command.title)
                        Spacer()
                        Text(command.shortcutLabel ?? "").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Keyboard Shortcuts")
        .responsiveInlineNavigationTitle("Keyboard Shortcuts")
        .appNavigationBackButton()
        .miniPlayerBar()
    }
}

struct DesktopPageContextModifier: ViewModifier {
    var subscriptionID: UUID?
    var episodeID: UUID?
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.background {
            DesktopCommandContext(subscriptionID: subscriptionID, episodeID: episodeID, back: { dismiss() })
                .frame(width: 0, height: 0)
        }
    }
}

/// Owns the real responder above the navigation stack. UIApplicationDelegateAdaptor
/// forwards delegate callbacks, but does not place its object in the responder chain.
final class DesktopHostingController: UIHostingController<AnyView> {
    let handler: DesktopCommandHandler
    init(content: AnyView, handler: DesktopCommandHandler) {
        self.handler = handler
        super.init(rootView: content)
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(content:handler:)") }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Provide a keyboard target on pages with no focused editor/control.
        if DesktopFocus.firstResponder == nil { becomeFirstResponder() }
        UIMenuSystem.main.setNeedsRebuild()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        DesktopMenuBuilder.build(builder)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard DesktopFocus.context?.allowsSpace == true,
              !DesktopFocus.hasModal, !DesktopFocus.isEditing,
              !(DesktopFocus.firstResponder is UIControl),
              handler.allows(.playPause) else { return super.keyCommands }
        return (super.keyCommands ?? []) + [UIKeyCommand(title: "Play/Pause",
            action: DesktopCommand.playPause.selector, input: " ", modifierFlags: [],
            propertyList: DesktopCommand.playPause.rawValue)]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if let command = DesktopCommand(selector: action) { return handler.allows(command) }
        return super.canPerformAction(action, withSender: sender)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        guard let action = DesktopCommand(selector: command.action) else { return }
        handler.validate(command, command: action)
    }

}

private struct DesktopCommandHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let handler: DesktopCommandHandler
    func makeUIViewController(context: Context) -> DesktopHostingController {
        DesktopHostingController(content: AnyView(content), handler: handler)
    }
    func updateUIViewController(_ controller: DesktopHostingController, context: Context) {
        controller.rootView = AnyView(content)
    }
}

extension View {
    func desktopCommandHost(handler: DesktopCommandHandler) -> some View {
        DesktopCommandHost(content: self, handler: handler)
            .ignoresSafeArea(.container)
    }
}

// Concrete selectors are required: one shared selector plus propertyList cannot
// be validated when the native menu bridge does not supply a UICommand sender.
extension DesktopHostingController {
    @objc func desktop_settings(_ sender: Any?) { handler.perform(.settings) }
    @objc func desktop_addFeed(_ sender: Any?) { handler.perform(.addFeed) }
    @objc func desktop_importSubscriptions(_ sender: Any?) { handler.perform(.importSubscriptions) }
    @objc func desktop_exportSubscriptions(_ sender: Any?) { handler.perform(.exportSubscriptions) }
    @objc func desktop_search(_ sender: Any?) { handler.perform(.search) }
    @objc func desktop_player(_ sender: Any?) { handler.perform(.player) }
    @objc func desktop_subscriptions(_ sender: Any?) { handler.perform(.subscriptions) }
    @objc func desktop_discover(_ sender: Any?) { handler.perform(.discover) }
    @objc func desktop_upNext(_ sender: Any?) { handler.perform(.upNext) }
    @objc func desktop_history(_ sender: Any?) { handler.perform(.history) }
    @objc func desktop_stats(_ sender: Any?) { handler.perform(.stats) }
    @objc func desktop_downloads(_ sender: Any?) { handler.perform(.downloads) }
    @objc func desktop_back(_ sender: Any?) { handler.perform(.back) }
    @objc func desktop_playPause(_ sender: Any?) { handler.perform(.playPause) }
    @objc func desktop_skipBack(_ sender: Any?) { handler.perform(.skipBack) }
    @objc func desktop_skipForward(_ sender: Any?) { handler.perform(.skipForward) }
    @objc func desktop_nextEpisode(_ sender: Any?) { handler.perform(.nextEpisode) }
    @objc func desktop_previousChapter(_ sender: Any?) { handler.perform(.previousChapter) }
    @objc func desktop_nextChapter(_ sender: Any?) { handler.perform(.nextChapter) }
    @objc func desktop_speed100(_ sender: Any?) { handler.perform(.speed100) }
    @objc func desktop_speed110(_ sender: Any?) { handler.perform(.speed110) }
    @objc func desktop_speed120(_ sender: Any?) { handler.perform(.speed120) }
    @objc func desktop_speed130(_ sender: Any?) { handler.perform(.speed130) }
    @objc func desktop_speed140(_ sender: Any?) { handler.perform(.speed140) }
    @objc func desktop_speed150(_ sender: Any?) { handler.perform(.speed150) }
    @objc func desktop_speed160(_ sender: Any?) { handler.perform(.speed160) }
    @objc func desktop_speed170(_ sender: Any?) { handler.perform(.speed170) }
    @objc func desktop_speed180(_ sender: Any?) { handler.perform(.speed180) }
    @objc func desktop_speed190(_ sender: Any?) { handler.perform(.speed190) }
    @objc func desktop_speed200(_ sender: Any?) { handler.perform(.speed200) }
    @objc func desktop_speed210(_ sender: Any?) { handler.perform(.speed210) }
    @objc func desktop_speed220(_ sender: Any?) { handler.perform(.speed220) }
    @objc func desktop_speed230(_ sender: Any?) { handler.perform(.speed230) }
    @objc func desktop_speed240(_ sender: Any?) { handler.perform(.speed240) }
    @objc func desktop_speed250(_ sender: Any?) { handler.perform(.speed250) }
    @objc func desktop_audioControls(_ sender: Any?) { handler.perform(.audioControls) }
    @objc func desktop_sleepTimer(_ sender: Any?) { handler.perform(.sleepTimer) }
    @objc func desktop_sleepSchedule(_ sender: Any?) { handler.perform(.sleepSchedule) }
    @objc func desktop_openShow(_ sender: Any?) { handler.perform(.openShow) }
    @objc func desktop_showSettings(_ sender: Any?) { handler.perform(.showSettings) }
    @objc func desktop_toggleSubscription(_ sender: Any?) { handler.perform(.toggleSubscription) }
    @objc func desktop_refreshShow(_ sender: Any?) { handler.perform(.refreshShow) }
    @objc func desktop_refreshAll(_ sender: Any?) { handler.perform(.refreshAll) }
    @objc func desktop_download(_ sender: Any?) { handler.perform(.download) }
    @objc func desktop_playNext(_ sender: Any?) { handler.perform(.playNext) }
    @objc func desktop_playLast(_ sender: Any?) { handler.perform(.playLast) }
    @objc func desktop_archive(_ sender: Any?) { handler.perform(.archive) }
    @objc func desktop_support(_ sender: Any?) { handler.perform(.support) }
    @objc func desktop_shortcuts(_ sender: Any?) { handler.perform(.shortcuts) }
    @objc func desktop_acknowledgements(_ sender: Any?) { handler.perform(.acknowledgements) }
}
