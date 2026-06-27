import CarPlay
import UIKit

// ============================================================================
// AI CONTEXT - CarPlay/CarPlaySceneDelegate.swift
//
// PURPOSE: UIKit scene delegate for the CarPlay template application scene
// declared in project.yml/Info.plist. It bridges CarPlay lifecycle callbacks into
// CarPlayCoordinator and keeps the scene setup independent from the SwiftUI
// iPhone WindowGroup.
//
// CURRENT SCOPE: Phase 7 navigation-safe CarPlay lifecycle. On connect it gives
// CarPlay a root "Loading..." template immediately, then lets CarPlayCoordinator
// run Autohop's idempotent launch-readiness path before rendering Now Playing,
// Queue, or empty-state templates. On disconnect it clears the interface-
// controller reference and cancels pending readiness/refresh work. It
// intentionally performs no playback, feed, notification, or audio-session work.
//
// GOTCHA: The class name is referenced from Info.plist as
// "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate"; keep this class in the app
// target and do not rename it without updating project.yml and regenerating.
// ============================================================================

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let coordinator = CarPlayCoordinator()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        coordinator.connect(interfaceController: interfaceController)
    }
}

extension CarPlaySceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        coordinator.disconnect(interfaceController: interfaceController)
    }
}
