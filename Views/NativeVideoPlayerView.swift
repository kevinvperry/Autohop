import AVKit
import SwiftUI

// AI CONTEXT — Views/NativeVideoPlayerView.swift. Video playback UI for the
// Player page: AVPlayerViewController wrapper (full-screen + Picture in
// Picture) around PlaybackEngine's AVPlayer. VideoOrientationController is the
// global orientation gate — portrait-only app-wide, unlocked to landscape
// only while full-screen video is active (queried by AppDelegate's
// supportedInterfaceOrientationsFor). Orientation changes use the iOS 16+
// scene geometry API plus setNeedsUpdateOfSupportedInterfaceOrientations() on
// the active controller; do not reintroduce deprecated static rotation calls.
//
// BACKGROUND VIDEO / PIP: Two complementary mechanisms prevent AVPlayer from
// pausing when the app resigns active during inline video playback:
//   1. Coordinator.attachIfNeeded — establishes the parent-child UIViewController
//      relationship (addChild/didMove) so canStartPictureInPictureAutomaticallyFromInline
//      actually fires. SwiftUI's UIViewControllerRepresentable does NOT call addChild
//      automatically, orphaning the controller and silently disabling auto-PiP.
//   2. PlayerView observes scenePhase: when the scene goes .inactive during inline
//      video playback, it increments pictureInPictureStartToken, which triggers
//      VideoPictureInPictureHost.startIfNeeded → AVPictureInPictureController.startPictureInPicture().
// Do not remove either mechanism — they are complementary, not redundant: (1) makes
// the AVPlayerViewController's own auto-PiP work; (2) is the explicit fallback via
// the PlayerLayerView-backed controller for devices / scenarios where (1) isn't enough.
enum VideoOrientationController {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    static func allowVideoOrientations() {
        supportedOrientations = .allButUpsideDown
        requestOrientation(.landscapeRight)
    }

    static func restorePortrait() {
        supportedOrientations = .portrait
        requestOrientation(.portrait)
    }

    private static func requestOrientation(_ orientation: UIInterfaceOrientation) {
        guard let scene = activeWindowScene else { return }
        notifySupportedOrientationsChanged(in: scene)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: orientation))) { error in
            AppLogger.shared.warning("video.orientationUpdateFailed", "Could not update video orientation", metadata: [
                "orientation": "\(orientation.rawValue)",
                "error": String(describing: error)
            ])
        }
    }

    private static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func notifySupportedOrientationsChanged(in scene: UIWindowScene) {
        let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene.windows.first?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()

        if let root,
           let top = topViewController(from: root),
           top !== root {
            top.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = controller?.presentedViewController {
            return topViewController(from: presented)
        }
        return controller
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }
}

struct NativeVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let attached: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = attached ? player : nil
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        controller.updatesNowPlayingInfoCenter = false
        context.coordinator.recordAttachment(attached, surface: "AVPlayerViewController")
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let desiredPlayer = attached ? player : nil
        if controller.player !== desiredPlayer {
            controller.player = desiredPlayer
            context.coordinator.recordAttachment(attached, surface: "AVPlayerViewController")
        }
        // Establish the parent-child UIViewController relationship so
        // canStartPictureInPictureAutomaticallyFromInline actually fires on background.
        // SwiftUI's UIViewControllerRepresentable hosting does not call addChild /
        // didMove automatically; without it the AVPlayerViewController is orphaned
        // and iOS won't trigger auto-PiP on resign-active.
        context.coordinator.attachIfNeeded(controller)
    }

    final class Coordinator {
        private weak var attached: AVPlayerViewController?
        private var lastAttachmentState: Bool?

        func attachIfNeeded(_ controller: AVPlayerViewController) {
            guard attached !== controller else { return }
            guard let parent = controller.view.window?.rootViewController
                    ?? findHostingController(for: controller.view)
            else { return }
            guard controller.parent == nil else {
                attached = controller
                return
            }
            parent.addChild(controller)
            controller.didMove(toParent: parent)
            attached = controller
        }

        func recordAttachment(_ isAttached: Bool, surface: String) {
            guard lastAttachmentState != isAttached else { return }
            lastAttachmentState = isAttached
            AppLogger.shared.info(
                isAttached ? "video.surfaceAttached" : "video.surfaceDetached",
                isAttached ? "Video surface attached to AVPlayer" : "Video surface detached from AVPlayer",
                metadata: ["surface": surface]
            )
        }

        private func findHostingController(for view: UIView?) -> UIViewController? {
            var responder: UIResponder? = view
            while let r = responder {
                if let vc = r as? UIViewController { return vc }
                responder = r.next
            }
            return nil
        }
    }
}

struct VideoPictureInPictureHost: UIViewRepresentable {
    let player: AVPlayer
    let startToken: Int
    let attached: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = attached ? player : nil
        context.coordinator.configure(with: view.playerLayer)
        context.coordinator.recordAttachment(attached, surface: "AVPlayerLayer")
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = attached ? player : nil
        context.coordinator.configure(with: view.playerLayer)
        context.coordinator.recordAttachment(attached, surface: "AVPlayerLayer")
        if attached {
            context.coordinator.startIfNeeded(token: startToken)
        }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private var pictureInPictureController: AVPictureInPictureController?
        private var lastToken = 0
        private var lastAttachmentState: Bool?

        func configure(with playerLayer: AVPlayerLayer) {
            guard pictureInPictureController == nil,
                  AVPictureInPictureController.isPictureInPictureSupported()
            else { return }
            guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
            controller.delegate = self
            pictureInPictureController = controller
        }

        func startIfNeeded(token: Int) {
            guard token > 0, token != lastToken else { return }
            lastToken = token
            guard let controller = pictureInPictureController,
                  !controller.isPictureInPictureActive
            else { return }
            controller.startPictureInPicture()
        }

        func recordAttachment(_ isAttached: Bool, surface: String) {
            guard lastAttachmentState != isAttached else { return }
            lastAttachmentState = isAttached
            AppLogger.shared.info(
                isAttached ? "video.surfaceAttached" : "video.surfaceDetached",
                isAttached ? "Video surface attached to AVPlayer" : "Video surface detached from AVPlayer",
                metadata: ["surface": surface]
            )
        }
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
