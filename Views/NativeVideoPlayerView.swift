import AVKit
import SwiftUI

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
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: orientation)))
        }
        UIViewController.attemptRotationToDeviceOrientation()
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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

struct VideoPictureInPictureHost: UIViewRepresentable {
    let player: AVPlayer
    let startToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        context.coordinator.configure(with: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        context.coordinator.configure(with: view.playerLayer)
        context.coordinator.startIfNeeded(token: startToken)
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private var pictureInPictureController: AVPictureInPictureController?
        private var lastToken = 0

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
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
